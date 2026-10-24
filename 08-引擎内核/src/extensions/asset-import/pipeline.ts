/**
 * L4 · 资产导入 · 管线
 *
 * 一轮导入做四件事：**扫描 → 建身份 → 增量判定 → 注册**。
 *
 * ★ 为什么是**两遍**，不是一遍边扫边导：
 *   图集的依赖写成 `"textures": ["grass.png"]`（相对路径），要把它变成 AssetId
 *   就必须先知道"这个路径的 id 是什么"。而 id 来自 `.meta`，`.meta` 又要先
 *   给每个源文件建好。所以：
 *     ① 第一遍：递归收集源文件 + `ensureMeta`，构建 `path → id` 表；
 *     ② 第二遍：按路径**排序**逐个导入（顺序确定，产物可复现）。
 *   一遍做不了 —— 除非允许"依赖先于 id 解析"，那就得在导入器里再扫一遍目录。
 *
 * ★ 增量判定看两样东西：`sourceHash`（内容）与 `importerVersion`（逻辑）。
 *   任一变了就重导。产物缓存在 `library/imported/<id>.json`：
 *   用 id 命名而不是路径 —— 文件移动后缓存还能命中（这正是 id 不变的意义）。
 *
 * ★ 单个失败**不中断整轮**：一个坏 PNG 不能让整工程导不进来。
 *   失败收进 `failed`，其余照常；`run` 返回 `ok(report)`。
 *   这不是"吞错"：错误码与路径都在报告里，调用方（编辑器/构建脚本）
 *   可以决定"有失败就红"，而不是让管线替它决定。
 *
 * ★ 产物 JSON 固定写法（字段顺序 + 2 空格缩进 + 末尾换行）：
 *   同样的输入必须产出**同样的字节**，否则"增量导入"在 git 里表现为
 *   每次构建都改一堆文件，diff 噪声会让人关掉这个功能。
 */

import type { AssetDatabase, AssetId } from "../../core/asset/asset.ts";
import type { ChannelLogger } from "../../foundation/log/logger.ts";
import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import type { IFileSystem } from "../../platform/fs/fs.ts";
import { contentHash } from "./hash.ts";
import type { ImporterRegistry, ImportContext, ImportedArtifact, SourceImporter } from "./importer.ts";
import type { MetaRecord } from "./meta.ts";
import { ensureMeta, MetaIdTable, writeMeta } from "./meta.ts";

export interface ImportFailure {
  readonly path: string;
  readonly code: string;
  readonly message: string;
}

/**
 * 导入产物缓存目录（相对资产根）。
 *
 * ★ 为什么把它导出：构建发布要**跳过**这个目录。
 *   它是"导入器的输出"，不是"资产"。构建时把它当资产扫，会得到
 *   `BUILD.UNREGISTERED_ASSET`（一次性把整个构建卡住），或者更糟 ——
 *   有人顺手给缓存文件也建个 id，于是**缓存进产物**，包会随缓存命中情况变。
 */
export const IMPORT_LIBRARY_REL = "library/imported";

export interface ImportReport {
  readonly scanned: number;
  /** 新建 `.meta` 的个数。 */
  readonly created: number;
  /** 真正重导的个数。 */
  readonly imported: number;
  /** hash 与 importerVersion 都没变、直接用缓存的个数。 */
  readonly skipped: number;
  /** 源文件已删除、本轮从注册表里清掉的幽灵条目数。 */
  readonly removed: number;
  readonly failed: readonly ImportFailure[];
  readonly registered: number;
  readonly durationMs: number;
}

/** 空设置：导入器目前不吃 `.meta` 里的 settings，但格式留好接口。 */
const EMPTY_SETTINGS: Readonly<Record<string, unknown>> = Object.freeze({});

// ------------------------------------------------------------------ 路径

function normalizeSlashes(p: string): string {
  return p.replace(/\\/g, "/");
}

/**
 * 词法归一：消掉 `.`，按栈消掉 `..`。
 * ★ 这是导入管线**自己的**职责，不能指望 fs：内存盘刻意**拒绝** `..`
 *   （越界必须被拒绝，而不是被"聪明"地解析成别处）。所以在交给 fs 之前，
 *   必须先把"相对当前源文件"的引用解析成工程内绝对逻辑路径。
 *   真的越出根（`..` 比目录还多）时保留 `..` 段 —— 让 fs 去报 PATH_ESCAPE，
 *   而不是悄悄夹到根（那会读到错误的文件，且没人知道）。
 */
export function normalizePath(p: string): string {
  let s = normalizeSlashes(p);
  let scheme = "";
  const m = /^([a-zA-Z]+):/.exec(s);
  if (m !== null) {
    scheme = m[1]! + ":";
    s = s.slice(m[0].length);
  }
  const absolute = s.startsWith("/");
  const out: string[] = [];
  for (const seg of s.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      if (out.length > 0) out.pop();
      else out.push("..");
      continue;
    }
    out.push(seg);
  }
  return scheme + (absolute ? "/" : "") + out.join("/");
}

function dirOf(file: string): string {
  const p = normalizeSlashes(file);
  const i = p.lastIndexOf("/");
  return i < 0 ? "" : p.slice(0, i);
}

/** 相对**源文件所在目录**解析（支持 `../`），返回工程内逻辑路径。 */
export function resolveSiblingPath(sourcePath: string, relPath: string): string {
  const base = dirOf(sourcePath);
  const joined = relPath.startsWith("/") ? relPath : `${base}/${relPath}`;
  return normalizePath(joined);
}

function joinPath(a: string, b: string): string {
  return normalizePath(`${a}/${b}`);
}

// ------------------------------------------------------------------ 产物序列化

function serializeArtifact(a: ImportedArtifact): string {
  // 手写对象字面量而不是展开 a：字段顺序必须固定，展开的顺序依赖别人。
  const obj = {
    type: a.type,
    importerVersion: a.importerVersion,
    sourceHash: a.sourceHash,
    byteLength: a.byteLength,
    dependencies: a.dependencies,
    data: a.data,
  };
  return JSON.stringify(obj, null, 2) + "\n";
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

// ------------------------------------------------------------------ 管线

interface ScanUnit {
  readonly path: string;
  readonly importer: SourceImporter;
  readonly record: MetaRecord;
}

function failureOf(path: string, e: EngineError): ImportFailure {
  return { path, code: e.code, message: e.message };
}

export class AssetImportPipeline {
  private readonly artifacts = new Map<AssetId, ImportedArtifact>();

  constructor(
    private readonly fs: IFileSystem,
    private readonly db: AssetDatabase,
    private readonly registry: ImporterRegistry,
    private readonly log: ChannelLogger,
  ) {}

  /** 本轮最近一次导入的产物（失败/跳过的资产不在这里，用 `db.meta` 看身份）。 */
  artifactOf(id: AssetId): ImportedArtifact | undefined {
    return this.artifacts.get(id);
  }

  async run(root: string): Promise<Result<ImportReport, EngineError>> {
    const t0 = Date.now();
    this.artifacts.clear();

    const found: string[] = [];
    const walked = await this.walk(root, found);
    if (!walked.ok) return err(walked.error);
    // 顺序确定：产物、日志、失败列表都不依赖 readdir 的返回顺序。
    found.sort();

    const failed: ImportFailure[] = [];
    const idTable = new MetaIdTable();
    const idByPath = new Map<string, AssetId>();
    const units: ScanUnit[] = [];
    let created = 0;

    // ---- 第一遍：建身份 ----
    for (const p of found) {
      const importer = this.registry.find(p);
      if (importer === undefined) {
        // 不静默跳过：未知格式必须出现在报告里，否则"导入了 3 个文件"会让人以为全集是 3。
        failed.push({
          path: p,
          code: "IMPORT.NO_IMPORTER",
          message: `${p}: 没有导入器处理这个扩展名（已注册：${this.registry.extensions().join(", ") || "(空)"}）`,
        });
        continue;
      }

      const em = await ensureMeta(this.fs, p, importer.id, EMPTY_SETTINGS);
      if (!em.ok) {
        failed.push(failureOf(p, em.error));
        continue;
      }
      if (em.value.created) created++;

      const rec = em.value.record;
      const claim = idTable.claim(rec.id, p);
      if (!claim.ok) {
        failed.push(failureOf(p, claim.error));
        continue;
      }
      idByPath.set(p, rec.id);
      units.push({ path: p, importer, record: rec });
    }

    // ---- 第二遍：导入 + 注册 ----
    const libraryDir = joinPath(root, IMPORT_LIBRARY_REL);
    let imported = 0;
    let skipped = 0;
    let registered = 0;

    for (const u of units) {
      const bytesR = await this.fs.readBinary(u.path);
      if (!bytesR.ok) {
        // 扫描与读取之间文件被删了：记为失败，不影响其他文件。
        failed.push(failureOf(u.path, bytesR.error));
        continue;
      }
      const bytes = bytesR.value;
      const sourceHash = contentHash(bytes);
      const cachePath = joinPath(libraryDir, `${u.record.id}.json`);
      const cached = await this.readCache(cachePath);

      let artifact: ImportedArtifact;
      /**
       * ★ 缓存命中还必须确认**依赖仍然活着**：
       *   产物只记录"上次解析出来的 id 列表"，而依赖文件可能已经被删掉/换了身份。
       *   只看源文件 hash 的话，图集会一直命中旧缓存，缺依赖永远不报 ——
       *   这正是"删了一张贴图，构建依然全绿，运行到加载才崩"的来源。
       */
      const dependenciesAlive =
        cached !== undefined && cached.dependencies.every((dep) => idTable.has(dep));
      if (
        cached !== undefined &&
        dependenciesAlive &&
        cached.sourceHash === sourceHash &&
        cached.importerVersion === u.importer.version
      ) {
        // 内容和导入逻辑都没变：不调导入器，直接用上次的产物。
        artifact = cached;
        skipped++;
      } else {
        const ir = await u.importer.import(u.path, bytes, u.record.settings, this.contextFor(u.path, root, idByPath));
        if (!ir.ok) {
          failed.push(failureOf(u.path, ir.error));
          continue;
        }
        // ★ 三个"外部事实"由管线以**字节/注册表**为准覆盖：
        //   sourceHash / byteLength 必须与磁盘字节一致（否则增量永远不命中），
        //   importerVersion 必须与 registry 里当前的 version 一致（否则缓存永远失效）。
        //   导入器自己填也行，但这些值只有一个权威来源，不该有两份实现各算一遍。
        artifact = {
          ...ir.value,
          sourceHash,
          byteLength: bytes.byteLength,
          importerVersion: u.importer.version,
        };

        const mk = await this.fs.ensureDir(libraryDir);
        if (!mk.ok) {
          failed.push(failureOf(u.path, mk.error));
          continue;
        }
        const wr = await this.fs.writeText(cachePath, serializeArtifact(artifact));
        if (!wr.ok) {
          failed.push(failureOf(u.path, wr.error));
          continue;
        }
        imported++;
      }

      this.artifacts.set(u.record.id, artifact);

      // `.meta` 里的 importerVersion 同步为**实际使用的版本**（首次是 1）。
      // 不这么做的话，升级导入器后 sidecar 会一直显示创建时的版本，误导排查。
      let rec = u.record;
      if (rec.importerVersion !== artifact.importerVersion) {
        const updated: MetaRecord = {
          id: rec.id,
          type: rec.type,
          importerVersion: artifact.importerVersion,
          settings: rec.settings,
        };
        const wm = await writeMeta(this.fs, u.path, updated);
        if (wm.ok) rec = updated;
        else this.log.warn("`.meta` 版本同步失败（不影响本轮导入）", { path: u.path, code: wm.error.code });
      }

      const reg = this.db.register({
        id: rec.id,
        type: artifact.type,
        path: u.path,
        importerVersion: artifact.importerVersion,
        sourceHash: artifact.sourceHash,
        dependencies: artifact.dependencies,
        byteLength: artifact.byteLength,
      });
      if (!reg.ok) {
        failed.push(failureOf(u.path, reg.error));
        continue;
      }
      registered++;
    }

    // ---- 清理幽灵注册：源文件被删了，注册表里还留着它 ----
    // ★ 只在"本轮至少有一个资产成功注册"时才清理。否则"root 写错 → 扫到 0 个"
    //   会变成"把整个资产库从注册表里抹掉"，而正确表现是"什么都没发生"。
    //   清理失败（还被依赖/还有句柄）进 failed，让调用方看见，而不是悄悄留着。
    const live = new Set<AssetId>();
    for (const u of units) live.add(u.record.id);
    let removed = 0;
    if (registered > 0) {
      for (const d of this.db.describe()) {
        if (live.has(d.id)) continue;
        const r = this.db.unregister(d.id);
        if (r.ok) {
          removed++;
          this.artifacts.delete(d.id);
        } else {
          failed.push(failureOf(d.path, r.error));
        }
      }
    }

    return ok({
      scanned: found.length,
      created,
      imported,
      skipped,
      removed,
      failed,
      registered,
      durationMs: Date.now() - t0,
    });
  }

  // ---------------------------------------------------------------- 内部

  private contextFor(
    sourcePath: string,
    root: string,
    ids: ReadonlyMap<string, AssetId>,
  ): ImportContext {
    return {
      fs: this.fs,
      root,
      log: this.log,
      resolveSibling: (rel) => resolveSiblingPath(sourcePath, rel),
      lookupId: (rel) => ids.get(resolveSiblingPath(sourcePath, rel)),
    };
  }

  /** 递归收集源文件。跳过 `.meta`、隐藏文件/目录、`library/`、`node_modules/`。 */
  private async walk(dir: string, out: string[]): Promise<Result<void, EngineError>> {
    const listed = await this.fs.list(dir);
    if (!listed.ok) return err(listed.error);

    for (const e of listed.value) {
      if (e.isDirectory) {
        if (this.skipDir(e.name)) continue;
        const r = await this.walk(e.path, out);
        if (!r.ok) return r;
      } else {
        if (this.skipFile(e.name)) continue;
        out.push(e.path);
      }
    }
    return ok(undefined);
  }

  private skipDir(name: string): boolean {
    // `.` 开头 = 隐藏（.git/.cache/.svn）；library = 我们自己的产物目录。
    // node_modules 不跳过的话，一次导入会把整个依赖树当成资产。
    return name.startsWith(".") || name === "library" || name === "node_modules";
  }

  private skipFile(name: string): boolean {
    return name.startsWith(".") || name.toLowerCase().endsWith(".meta");
  }

  /**
   * 读产物缓存。读不出来/格式不对都按"没有缓存"处理并 warn：
   * 缓存是**派生物**，坏了就重导，不该让整个管线失败。
   * （与 `.meta` 相反：`.meta` 是身份来源，坏了必须报 BAD_META 而不是重新生成。）
   */
  private async readCache(path: string): Promise<ImportedArtifact | undefined> {
    if (!(await this.fs.exists(path))) return undefined;
    const r = await this.fs.readText(path);
    if (!r.ok) {
      this.log.warn("产物缓存读不出来，按需要重导处理", { path, code: r.error.code });
      return undefined;
    }

    let raw: unknown;
    try {
      raw = JSON.parse(r.value) as unknown;
    } catch {
      this.log.warn("产物缓存不是合法 JSON，按需要重导处理", { path });
      return undefined;
    }
    if (!isPlainObject(raw)) {
      this.log.warn("产物缓存顶层不是对象，按需要重导处理", { path });
      return undefined;
    }

    const type = raw["type"];
    const version = raw["importerVersion"];
    const hash = raw["sourceHash"];
    const byteLength = raw["byteLength"];
    const deps = raw["dependencies"];
    const data = raw["data"];
    if (
      typeof type !== "string" ||
      typeof version !== "number" ||
      !Number.isInteger(version) ||
      typeof hash !== "string" ||
      typeof byteLength !== "number" ||
      !Array.isArray(deps) ||
      !deps.every((d): d is string => typeof d === "string") ||
      !isPlainObject(data)
    ) {
      this.log.warn("产物缓存字段不完整，按需要重导处理", { path });
      return undefined;
    }

    return {
      type,
      importerVersion: version,
      sourceHash: hash,
      byteLength,
      dependencies: deps,
      data,
    };
  }
}
