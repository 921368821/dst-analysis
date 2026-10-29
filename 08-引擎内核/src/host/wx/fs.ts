/**
 * L6 · 小游戏（wx）宿主 · 文件系统适配（`wx.getFileSystemManager()` → `IFileSystem`）
 *
 * 这一层存在的原因是 `localStorage` 在小游戏里**不存在**（`FORBIDDEN_IN_MINIGAME` 明写）。
 * 浏览器宿主的存档走 `localStorage`；小游戏只有文件系统，于是"存档"这件事要落到文件上。
 *
 * ★ 实现的是**完整 `IFileSystem`**（含写），不是只读那半 —— 存档必须能写。
 *   与 `fs-bundle`（只读、`canList = true`）的区别在这里：那个是资产源，这个是存档位。
 *
 * ★★ 三处**真实差异**（不写下来就会当成 bug 查一天）：
 *
 *   ① `readdirSync` **只给名字**，不给类型也不给大小。所以 `list` 必须对每个子项再
 *      `statSync` 一次（N+1 次同步调用）。这不是"实现得糙"：wx 的 manager 没有
 *      "列目录带元信息"这个操作。写成"默认是文件、isDirectory 恒 false"会让
 *      目录在资产浏览器里显示成 0 字节文件，而没有任何地方报错。
 *
 *   ② 错误是**抛异常 + `errMsg` 字符串**，没有错误码。所以"文件不存在"只能靠
 *      `errMsg` 里有没有 `no such file` 来判断 —— 这条判断只写一次（`classify`），
 *      否则三处各写一遍就会有一次写成"任何异常都当不存在"，于是权限错误被读成空文件。
 *
 *   ③ 写文件**不会自动建父目录**（浏览器里 localStorage 没有目录概念，很容易漏）。
 *      所以 `writeText` / `writeBinary` 必须先 `ensureDir(dirname)`。
 *      漏了这一步的症状是"第一次存档就失败，而第二次能成功"（目录被上一次的失败顺手建出来了）。
 *
 *   ④ 写存档**要走临时文件 + rename**（批132）：直接 `writeFileSync` 到目标路径时，
 *      "写到一半被杀进程 / 手机没电"留下的是**半份存档**，而半份存档比没有存档更坏 ——
 *      读档那边会把半截 JSON 当格式错，玩家看到的是「存档损坏」。
 *      与 `fs-node` 同一套语义（临时文件 → rename），差别只有一处、而且是真实的：
 *      **wx 没有 `fsync`**，所以"rename 是否已持久化"在这里连"靠文件系统日志"都谈不上，
 *      只能如实记着。原子性管的是"要么旧、要么新"，不管"是否已落到闪存"。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { FileEntry, FileStat, IFileSystem } from "../../platform/fs/fs.ts";
import { WX_ERR, type WxLike } from "./env.ts";

/** 小游戏的用户目录（`wx.env.USER_DATA_PATH`，真机上长这样）。 */
export const WX_USER_DATA_PATH = "wxfile://usr";

/** 只用到的 `FileSystemManager` 能力（同步版：这一层把它们包成 Promise）。 */
export interface WxFsManagerLike {
  readFileSync(path: string, encoding?: string): string | ArrayBuffer;
  writeFileSync(path: string, data: string | ArrayBuffer, encoding?: string): void;
  readdirSync(path: string): string[];
  statSync(path: string): WxStatLike;
  mkdirSync(path: string, recursive?: boolean): void;
  unlinkSync(path: string): void;
  rmdirSync(path: string, recursive?: boolean): void;
  accessSync(path: string): boolean;
  /** 可选：没有它就无法原子落盘（见 `atomicWrite`）。真机基础库从 1.9.9 起都有。 */
  renameSync?(oldPath: string, newPath: string): void;
}

/** wx 的 `Stat`：类型是**方法**，不是字段。 */
export interface WxStatLike {
  readonly size?: number;
  readonly lastModifiedTime?: number;
  isDirectory?(): boolean;
  isFile?(): boolean;
}

export interface WxFsOptions {
  /** 逻辑路径的根（默认 `wxfile://usr`）。 */
  readonly root?: string;
}

/** 取 manager。取不到就是 `WX.NO_FS` —— 没有文件系统等于没有存档位，早失败。 */
export function acquireFsManager(wx: WxLike): Result<WxFsManagerLike, EngineError> {
  if (typeof wx.getFileSystemManager !== "function") {
    return err(engineError(WX_ERR.NO_FS, "当前 wx 没有 getFileSystemManager"));
  }
  const mgr = wx.getFileSystemManager() as WxFsManagerLike | null | undefined;
  if (mgr === null || mgr === undefined || typeof mgr.readFileSync !== "function") {
    return err(engineError(WX_ERR.NO_FS, "getFileSystemManager 没有返回可用的 manager"));
  }
  return ok(mgr);
}

function msgOf(e: unknown): string {
  if (typeof e === "string") return e;
  if (e !== null && typeof e === "object") {
    const m = (e as { errMsg?: unknown }).errMsg;
    if (typeof m === "string") return m;
    const m2 = (e as { message?: unknown }).message;
    if (typeof m2 === "string") return m2;
  }
  return String(e);
}

/**
 * 把 wx 抛的异常分类成引擎错误码。
 *
 * ★ **只在这里判断一次**。四类，按 errMsg 关键字：
 *   不存在 / 权限 / 目录已存在（对 `ensureDir` 是成功） / 其余（IO）。
 *   顺序不能颠：权限错误的文案里也可能出现路径，先判"不存在"会把权限错误读成空文件。
 */
function classify(e: unknown, path: string): EngineError {
  const m = msgOf(e);
  const low = m.toLowerCase();
  if (low.includes("no such file") || low.includes("not exist") || low.includes("enoent")) {
    return engineError("FS.NOT_FOUND", `文件不存在：${path}（${m}）`);
  }
  if (low.includes("permission") || low.includes("denied") || low.includes("eacces")) {
    return engineError("FS.PERMISSION", `没有权限：${path}（${m}）`);
  }
  return engineError("FS.IO", `文件系统调用失败：${path}（${m}）`);
}

/** 目录已存在：对 `ensureDir` 而言是成功，对 `mkdirSync` 而言是异常。 */
function isAlreadyExists(e: unknown): boolean {
  const low = msgOf(e).toLowerCase();
  return low.includes("already exist") || low.includes("eexist");
}

/** 压重复斜杠、去尾部斜杠（根除外）。与 `fs-bundle` 的归一化同一条纪律：只写一处。 */
function joinPath(root: string, input: string): string {
  const rel = input.replace(/^\/+/, "");
  const parts = [root.replace(/\/+$/, ""), ...rel.split("/")].filter((s) => s.length > 0 && s !== ".");
  const out: string[] = [];
  for (const p of parts) out.push(p);
  return out.join("/");
}

function parentOf(abs: string): string {
  const at = abs.lastIndexOf("/");
  return at <= 0 ? "" : abs.slice(0, at);
}

export class WxFileSystem implements IFileSystem {
  readonly scheme = "wx";
  readonly canList = true;
  private readonly root: string;
  /**
   * 临时文件名里的序号。
   *
   * ★ 为什么需要它：`save.json.tmp` 这种固定名在"两次写重叠"时会互相踩
   *   （`writeText` 是 async 的，两个 await 之间别的代码能插进来）。
   *   序号 +1 让每次写自己的临时文件互不相干 —— 与 `fs-node` 同一条理由。
   */
  private tmpSeq = 0;

  constructor(
    private readonly mgr: WxFsManagerLike,
    options: WxFsOptions = {},
  ) {
    this.root = options.root ?? WX_USER_DATA_PATH;
  }

  /** 逻辑路径 → wx 的绝对路径。空串报 `FS.BAD_PATH`（不是拼出一个"根目录"）。 */
  private abs(path: string): Result<string, EngineError> {
    if (path.length === 0 || path.trim().length === 0) {
      return err(engineError("FS.BAD_PATH", "路径是空串"));
    }
    return ok(joinPath(this.root, path));
  }

  /**
   * 写临时文件 → rename（`fs-node` 的同款语义，去掉 `fsync`：wx 没有）。
   *
   * ★★ 失败路径必须**删掉临时文件**：否则一次写失败就在存档目录里留一个
   *   `save.json.tmp-3`，而 `list()` 会把它当普通文件列出来（`readdirSync` 只给名字，
   *   没有"这是临时文件"这个信息）—— 资产浏览器里从此多一个看不懂的条目。
   *
   * ★ 关于"rename 到已存在的目标"：wx 的文档没有把"覆盖"写死。所以这里**先直接 rename**，
   *   只有在报「已存在」时才退化成 unlink + rename。代价是那一步里有一瞬间**没有存档**，
   *   但这仍然是"要么旧、要么新、要么没有"，而不是"半个" —— 三者里唯一不可恢复的只有"半个"。
   */
  private atomicWrite(
    target: string,
    logical: string,
    write: (tmp: string) => void,
  ): Result<void, EngineError> {
    const rename = this.mgr.renameSync;
    if (typeof rename !== "function") {
      // ★ 不退化成直接写：静默退化等于这个修复从来没生效过，而失败是要人看见的。
      return err(
        engineError(
          "FS.IO",
          `当前 wx 的 FileSystemManager 没有 renameSync —— 存档无法原子落盘：${logical}（拒绝退化成直接写：半份存档比没有更坏）`,
        ),
      );
    }
    const tmp = `${target}.tmp-${String(++this.tmpSeq)}`;
    try {
      write(tmp);
    } catch (e) {
      this.dropTmp(tmp);
      return err(classify(e, logical));
    }
    try {
      rename.call(this.mgr, tmp, target);
      return ok(undefined);
    } catch (e) {
      if (isAlreadyExists(e)) {
        // 目标已存在且该实现不覆盖：删掉旧的再 rename（见上面 ★ 的取舍）。
        try {
          this.mgr.unlinkSync(target);
          rename.call(this.mgr, tmp, target);
          return ok(undefined);
        } catch (e2) {
          this.dropTmp(tmp);
          return err(classify(e2, logical));
        }
      }
      this.dropTmp(tmp);
      return err(classify(e, logical));
    }
  }

  /** 删临时文件。清理失败**不许**盖掉真正的原因（所以吞掉异常）。 */
  private dropTmp(tmp: string): void {
    try {
      this.mgr.unlinkSync(tmp);
    } catch {
      /* 临时文件没建出来 / 已经不在：都无所谓 */
    }
  }

  async readText(path: string): Promise<Result<string, EngineError>> {
    const a = this.abs(path);
    if (!a.ok) return a;
    try {
      const out = this.mgr.readFileSync(a.value, "utf8");
      if (typeof out !== "string") {
        return err(
          engineError("FS.NOT_UTF8", `readFileSync 返回的不是字符串（编码参数被忽略）：${path}`),
        );
      }
      return ok(out);
    } catch (e) {
      return err(classify(e, path));
    }
  }

  async readBinary(path: string): Promise<Result<Uint8Array, EngineError>> {
    const a = this.abs(path);
    if (!a.ok) return a;
    try {
      const out = this.mgr.readFileSync(a.value);
      if (typeof out === "string") {
        return err(
          engineError("FS.IO", `readFileSync 返回了字符串（缺编码参数时应当是 ArrayBuffer）：${path}`),
        );
      }
      return ok(new Uint8Array(out));
    } catch (e) {
      return err(classify(e, path));
    }
  }

  async exists(path: string): Promise<boolean> {
    const a = this.abs(path);
    if (!a.ok) return false;
    try {
      return this.mgr.accessSync(a.value) === true;
    } catch {
      // ★ accessSync 在部分版本对"不存在"是抛异常而不是返回 false，两种都要当 false。
      return false;
    }
  }

  async list(dir: string): Promise<Result<readonly FileEntry[], EngineError>> {
    const a = this.abs(dir);
    if (!a.ok) return a;
    try {
      const names = this.mgr.readdirSync(a.value);
      const out: FileEntry[] = [];
      for (const name of names) {
        // ★ N+1：readdirSync 只给名字，类型与大小只能逐个 stat（见文件头 ①）。
        const st = this.mgr.statSync(joinPath(a.value, name));
        const isDirectory = typeof st.isDirectory === "function" ? st.isDirectory() : false;
        out.push({
          name,
          path: joinPath(dir, name),
          isDirectory,
          size: isDirectory ? 0 : (st.size ?? 0),
        });
      }
      // ★ 排序在这里做，不指望 manager 的顺序：目录在前、同级按名字升序。
      //   不排序的话资产浏览器的行序会随文件系统而变 —— 而那正是"截图对不上"的来源。
      out.sort((x, y) => {
        if (x.isDirectory !== y.isDirectory) return x.isDirectory ? -1 : 1;
        return x.name < y.name ? -1 : x.name > y.name ? 1 : 0;
      });
      return ok(out);
    } catch (e) {
      return err(classify(e, dir));
    }
  }

  async stat(path: string): Promise<Result<FileStat, EngineError>> {
    const a = this.abs(path);
    if (!a.ok) return a;
    try {
      const st = this.mgr.statSync(a.value);
      const isDirectory = typeof st.isDirectory === "function" ? st.isDirectory() : false;
      return ok({
        size: st.size ?? 0,
        // 0 表示"实现不提供"，与接口文档一致（别用 -1 冒充）。
        mtimeMs: st.lastModifiedTime ?? 0,
        isDirectory,
      });
    } catch (e) {
      return err(classify(e, path));
    }
  }

  async writeText(path: string, text: string): Promise<Result<void, EngineError>> {
    const a = this.abs(path);
    if (!a.ok) return a;
    const ready = this.ensureParent(a.value);
    if (ready !== null) return ready;
    return this.atomicWrite(a.value, path, (tmp) => {
      this.mgr.writeFileSync(tmp, text, "utf8");
    });
  }

  async writeBinary(path: string, data: Uint8Array): Promise<Result<void, EngineError>> {
    const a = this.abs(path);
    if (!a.ok) return a;
    const ready = this.ensureParent(a.value);
    if (ready !== null) return ready;
    return this.atomicWrite(a.value, path, (tmp) => {
      // ★ 复制一份再交给 manager：wx 的 writeFileSync 在某些版本里会**持有**这个 buffer，
      //   调用方随后复用同一块内存（存档缓冲池）就会把已写入的内容改掉。
      const copy = new Uint8Array(data.length);
      copy.set(data);
      this.mgr.writeFileSync(tmp, copy.buffer as ArrayBuffer);
    });
  }

  async remove(path: string): Promise<Result<void, EngineError>> {
    const a = this.abs(path);
    if (!a.ok) return a;
    try {
      const st = this.mgr.statSync(a.value);
      const isDirectory = typeof st.isDirectory === "function" ? st.isDirectory() : false;
      if (isDirectory) this.mgr.rmdirSync(a.value, true);
      else this.mgr.unlinkSync(a.value);
      return ok(undefined);
    } catch (e) {
      return err(classify(e, path));
    }
  }

  async ensureDir(dir: string): Promise<Result<void, EngineError>> {
    const a = this.abs(dir);
    if (!a.ok) return a;
    return this.mkdirp(a.value, dir);
  }

  private mkdirp(abs: string, shown: string): Result<void, EngineError> {
    try {
      this.mgr.mkdirSync(abs, true);
      return ok(undefined);
    } catch (e) {
      if (isAlreadyExists(e)) return ok(undefined);
      return err(classify(e, shown));
    }
  }

  /** 写文件前把父目录建好；父目录为空（写在根上）时返回 null 表示"没事"。 */
  private ensureParent(abs: string): Result<void, EngineError> | null {
    const parent = parentOf(abs);
    if (parent.length === 0) return null;
    const r = this.mkdirp(parent, parent);
    return r.ok ? null : r;
  }
}

/** 工厂：判据与 `createWxHost` 都走这里（构造期的校验只有一处）。 */
export function createWxFileSystem(
  wx: WxLike,
  options: WxFsOptions = {},
): Result<IFileSystem, EngineError> {
  const mgr = acquireFsManager(wx);
  if (!mgr.ok) return mgr;
  return ok(new WxFileSystem(mgr.value, options));
}
