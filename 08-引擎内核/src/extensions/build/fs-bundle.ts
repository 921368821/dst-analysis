/**
 * L4 · 构建产物 · 包文件系统（只读，`bundle:`）
 *
 * ★ 为什么在 L4 而不是 `src/backends/`：它确实实现的是 `IReadableFileSystem`（L1 接口），
 *   但它要用 `createBundleReader` 与 `PublishManifest` —— 那两个是 L4 的构建产物模型。
 *   分层闸门只许"依赖向下"，所以"实现 L1 接口却依赖 L4 数据"的模块只能待在 L4。
 *   代价是它不在 `src/backends/` 的工厂表里（`backends/index.ts` 不导出它），
 *   由宿主（`browser-entry.ts`）在决定"这次走包还是走直读"时直接 new —— 见 `bundle-source.ts`。
 *
 * 与 `fs-http` 是同一个问题的两种答案：**"资产在哪"**。
 *   · `fs-http` 把逻辑路径拼到一个 base URL 上，让静态服务器去找；
 *   · 这个后端把逻辑路径查成 manifest 里的资产 id，再从**内容寻址的包**里解出来。
 * 两者的接口完全一样（`IReadableFileSystem`），所以上层（导入管线、图集烘焙、脚本）
 * 一行都不用改 —— 这正是把读接口与写接口拆开（`IReadableFileSystem` vs `IFileSystem`）
 * 换来的好处：只读资源源在类型上就进不了需要写 .meta 的地方。
 *
 * ★★ 为什么它能 `canList = true`，而 `fs-http` 不能：
 *   静态服务器没有"列目录"这个操作（返回空数组会被误读成"目录是空的"）。
 *   而 manifest 本身就是一份完整清单 —— 包里的每个资产都登记在案，
 *   「这个目录下有什么」是可以**确定回答**的。这不是把 `canList` 宽松化，
 *   而是真的有这个信息。副作用是：从包加载时资产浏览器能工作，从 HTTP 直读时不能。
 *
 * ★ 路径归一化必须**只有一处**：`/assets/a.png`、`assets/a.png`、`assets//a.png`
 *   在各类调用方里都会出现（编辑器给的是带斜杠的、导入管线给的是相对的）。
 *   每个方法各写一遍归一化，就会出现"`exists` 说在、`readBinary` 说找不到"。
 *
 * ★ 与 `fs-http` 的另一处差异：这里**不做网络重试**。
 *   包取不到是部署问题（少传了一个 `.bin`），重试只会把"部署错了"变成"加载慢一点点然后失败"。
 *   错误码透传 `LOAD.*`，因为根因在构建产物而不是文件系统。
 */

import type { IReadableFileSystem, FileEntry, FileStat } from "../../platform/fs/fs.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { PublishManifest, PublishManifestAsset } from "./publish.ts";
import { createBundleReader, type BundleReader } from "./loader.ts";

export const FSBUNDLE_ERR = {
  /** manifest 里两个资产用同一个逻辑路径 —— 查 path 会有歧义（path 不参与 hash）。 */
  DUPLICATE_PATH: "FSBUNDLE.DUPLICATE_PATH",
  /** 这个路径不在 manifest 里。 */
  NOT_FOUND: "FSBUNDLE.NOT_FOUND",
  /** 路径是空的或归一化之后没有意义。 */
  BAD_PATH: "FSBUNDLE.BAD_PATH",
} as const;

export interface BundleFsOptions {
  readonly manifest: PublishManifest;
  /** 取一个包的字节（浏览器 `fetch` / Node 读文件）。失败请 throw。 */
  readonly fetchBundle: (hash: string) => Promise<Uint8Array>;
  /**
   * 相对路径的挂载点（默认 `"/"`）。
   *
   * ★ 为什么需要它：manifest 里的 `path` 是**站点路径**（`/assets/berry.png`，
   *   构建配置的 `assetRoot` 决定），而宿主的调用点给的是相对名（`berry.png`）。
   *   让后端认这个前缀，调用点就与 `fs-http` 完全同形（那边是 base URL 承担同一件事）；
   *   否则要么每个调用点判断"现在用的是哪个后端"（污染上层），要么把 URL base 改掉
   *   （会动到默认路径的行为）。两件都不该做。
   */
  readonly root?: string;
}

/** 逻辑路径归一化：补前导斜杠、压重复斜杠、去尾部斜杠（根除外）。 */
function normalize(input: string): Result<string, EngineError> {
  if (input.length === 0) {
    return err(engineError(FSBUNDLE_ERR.BAD_PATH, "路径是空串"));
  }
  let s = input.replace(/\\/g, "/");
  if (!s.startsWith("/")) s = `/${s}`;
  s = s.replace(/\/+/g, "/");
  if (s.length > 1 && s.endsWith("/")) s = s.slice(0, -1);
  return ok(s);
}

export class BundleFileSystem implements IReadableFileSystem {
  readonly scheme = "bundle";
  /** 见文件头：manifest 就是清单，所以这里**真的**能列目录。 */
  readonly canList = true;

  private readonly byPath = new Map<string, PublishManifestAsset>();
  private readonly dirs = new Set<string>(["/"]);
  private readonly reader: BundleReader;
  private readonly root: string;

  constructor(opts: BundleFsOptions, reader?: BundleReader) {
    const rootR = normalize(opts.root ?? "/");
    if (!rootR.ok) throw new Error(`${FSBUNDLE_ERR.BAD_PATH}：root=${String(opts.root)}`);
    this.root = rootR.value;
    for (const a of opts.manifest.assets) {
      const p = normalize(a.path);
      if (!p.ok) throw new Error(`${FSBUNDLE_ERR.BAD_PATH}：${a.path}`);
      if (this.byPath.has(p.value)) {
        throw new Error(`${FSBUNDLE_ERR.DUPLICATE_PATH}：两个资产都用 ${p.value}（path 不参与 hash，查起来有歧义）`);
      }
      this.byPath.set(p.value, a);
      // 所有祖先目录都记下来（`/` 已在集合里）
      let cut = p.value.lastIndexOf("/");
      while (cut > 0) {
        this.dirs.add(p.value.slice(0, cut));
        cut = p.value.slice(0, cut).lastIndexOf("/");
      }
    }
    this.reader = reader ?? createBundleReader({ manifest: opts.manifest, fetchBundle: opts.fetchBundle });
  }

  /**
   * 唯一一处路径归一化：绝对路径原样，相对路径挂到  下。
   *
   * ★ 四个入口（read / exists / stat / list）都走这里。各写一遍的后果是
   *   「exists 说在、readBinary 说找不到」—— 而那种症状会被归因成包坏了。
   */
  private resolve(input: string): Result<string, EngineError> {
    const p = normalize(input);
    if (!p.ok) return p;
    if (input.startsWith("/")) return p;
    return normalize(this.root === "/" ? p.value : `${this.root}${p.value}`);
  }

  /** 读了多少次包（判据用：同一个包只该取一次）。 */
  stats(): { fetches: number; hits: number; requests: number } {
    const s = this.reader.stats();
    return { fetches: s.fetches, hits: s.hits, requests: s.requests };
  }

  async readBinary(path: string): Promise<Result<Uint8Array, EngineError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    const asset = this.byPath.get(p.value);
    if (asset === undefined) {
      // 目录在这里报 NOT_FOUND 而不是"空字节"：读目录是调用方的错，装作读到了更糟。
      return err(
        engineError(
          FSBUNDLE_ERR.NOT_FOUND,
          `${p.value} 不在 manifest 里（已登记 ${String(this.byPath.size)} 个资产）`,
          { path: p.value },
        ),
      );
    }
    return this.reader.get(asset.id);
  }

  async readText(path: string): Promise<Result<string, EngineError>> {
    const b = await this.readBinary(path);
    if (!b.ok) return b;
    try {
      // 与 fs-http 同一条纪律：fatal:true。返回替换字符会把「编码错了」伪装成「内容就这样」。
      return ok(new TextDecoder("utf-8", { fatal: true }).decode(b.value));
    } catch (e) {
      return err(engineError("FS.NOT_UTF8", `不是合法 UTF-8：${path}（${e instanceof Error ? e.message : String(e)}）`));
    }
  }

  async exists(path: string): Promise<boolean> {
    const p = this.resolve(path);
    if (!p.ok) return false;
    return this.byPath.has(p.value) || this.dirs.has(p.value);
  }

  async stat(path: string): Promise<Result<FileStat, EngineError>> {
    const p = this.resolve(path);
    if (!p.ok) return p;
    const asset = this.byPath.get(p.value);
    if (asset !== undefined) {
      // mtimeMs = 0：manifest 里没有时间戳，0 的约定是「实现不提供」（见 FileStat 注释）。
      return ok({ size: asset.size, mtimeMs: 0, isDirectory: false });
    }
    if (this.dirs.has(p.value)) {
      return ok({ size: 0, mtimeMs: 0, isDirectory: true });
    }
    return err(engineError(FSBUNDLE_ERR.NOT_FOUND, `${p.value} 不存在`, { path: p.value }));
  }

  /**
   * 列**直接子项**（目录在前、同级按名字升序 —— 顺序固定，判据才能逐项比）。
   *
   * ★ 不递归：递归列举会让"资产浏览器展开一个目录"变成"把几千个路径一次性读进来"，
   *   而调用方通常只想要下一层。
   */
  async list(dir: string): Promise<Result<readonly FileEntry[], EngineError>> {
    const d = this.resolve(dir);
    if (!d.ok) return d;
    if (!this.dirs.has(d.value) && !this.byPath.has(d.value)) {
      return err(engineError(FSBUNDLE_ERR.NOT_FOUND, `${d.value} 不存在`, { path: d.value }));
    }
    const prefix = d.value === "/" ? "/" : `${d.value}/`;
    const children = new Set<string>();
    const files: FileEntry[] = [];
    for (const [path, asset] of this.byPath) {
      if (!path.startsWith(prefix)) continue;
      const rest = path.slice(prefix.length);
      const slash = rest.indexOf("/");
      if (slash < 0) {
        files.push({ name: rest, path, isDirectory: false, size: asset.size });
      } else {
        children.add(rest.slice(0, slash));
      }
    }
    const dirEntries: FileEntry[] = [...children]
      .sort()
      .map((name) => ({ name, path: `${prefix}${name}`, isDirectory: true, size: 0 }));
    files.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return ok([...dirEntries, ...files]);
  }
}

/**
 * 后端工厂（与 `httpFsBackend` 同形）。
 *
 * ★ `probe` 必须显式给 manifest：没有清单就没有"目录"，这个后端不能靠探测环境决定自己是否可用。
 */
export const bundleFsBackend = {
  id: "bundle",
  scheme: "bundle",
  probe(options?: unknown): boolean {
    const o = options as BundleFsOptions | undefined;
    return o !== undefined && o.manifest !== undefined && typeof o.fetchBundle === "function";
  },
  create(options?: unknown): Result<IReadableFileSystem, EngineError> {
    const o = options as BundleFsOptions | undefined;
    if (o === undefined || o.manifest === undefined) {
      return err(engineError("FS.BAD_OPTIONS", "BundleFileSystem 必须给 manifest（构建产物里的 manifest.json）"));
    }
    try {
      return ok(new BundleFileSystem(o));
    } catch (e) {
      return err(engineError("FS.BAD_OPTIONS", e instanceof Error ? e.message : String(e)));
    }
  },
} as const;
