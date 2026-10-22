/**
 * L4 · 资产导入 · `.meta` sidecar
 *
 * ★ 为什么身份放在**独立 sidecar** 里，而不是塞进源文件：
 *   PNG/FBX 这类二进制格式没有地方放 GUID；就算能放，改一次 id 就要重写整个
 *   二进制（校验和、体积、diff 全变）。sidecar 把"身份"和"内容"解耦：
 *   内容随便改，`.meta` 不动；`.meta` 跟文件一起移动，id 就不会丢。
 *
 * ★ 身份规则（整个导入管线的根，必须记牢）：
 *   · **首次**导入：id = `stableIdFromPath(相对路径)` —— 同一路径可复现，
 *     所以"误删 .meta 后重新生成"不会把整个工程的引用打散；
 *   · **之后**：一切以 `.meta` 为准 —— 路径改名、移动目录，id 都不变。
 *   这两个需求（可复现 / 可迁移）只在"首次"冲突，所以用一个文件把它们分开：
 *   初次可推导，之后只认 `.meta`。
 *
 * ★ `.meta` 里**不存** sourceHash / dependencies：
 *   那些是"某次导入的产物"，写在这里会让 sidecar 每导一次就变，
 *   于是 git diff 里"移动文件"与"内容变化"混在一起。
 *   产物放 `library/imported/<id>.json`（见 pipeline.ts）。
 *
 * ★ id 冲突**不静默加后缀**：`a.png` 与 `b.png` 撞 id 时给一个 `id-1`
 *   看着"解决了"，但实际上让身份变得不可预测 —— 谁先扫描谁拿原 id，
 *   `readdir` 顺序一变引用就换人。宁可报错让人清理。
 */

import type { AssetId } from "../../core/asset/asset.ts";
import { stableIdFromPath } from "../../core/asset/asset.ts";
import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import type { IFileSystem } from "../../platform/fs/fs.ts";

/** `.meta` 的磁盘形状。字段顺序固定（写出时手拼，保证逐字节可复现）。 */
export interface MetaRecord {
  readonly id: AssetId;
  readonly type: string;
  readonly importerVersion: number;
  readonly settings: Readonly<Record<string, unknown>>;
}

/** 小写 base36，1~40 位。`stableIdFromPath` 产出 8 位，手写 id 也在这个范围内。 */
const ID_RE = /^[a-z0-9]{1,40}$/;

/** `<源文件全名>.meta`：`assets/grass.png` → `assets/grass.png.meta`。 */
export function metaPathOf(sourcePath: string): string {
  return sourcePath + ".meta";
}

/**
 * 从源路径取"相对逻辑路径"，用于首次派生 id。
 * 去掉 scheme（`mem:`/`node:`）与前导 `/`：id 只跟工程内位置有关，
 * 不跟"挂在哪个盘/哪个前缀"有关。
 */
export function relativePathOf(sourcePath: string): string {
  let p = sourcePath.replace(/\\/g, "/");
  const m = /^[a-zA-Z]+:/.exec(p);
  if (m !== null) p = p.slice(m[0].length);
  return p.replace(/^\/+/, "");
}

function badMeta(path: string, message: string, field?: string): EngineError {
  return engineError("IMPORT.BAD_META", `${path}: ${message}`, {
    path,
    ...(field === undefined ? {} : { field }),
  });
}

function parseMeta(path: string, text: string): Result<MetaRecord, EngineError> {
  let raw: unknown;
  try {
    raw = JSON.parse(text) as unknown;
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    return err(badMeta(path, `JSON 解析失败（${why}）`));
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return err(badMeta(path, "顶层必须是 JSON 对象"));
  }
  const o = raw as Record<string, unknown>;

  const id = o["id"];
  if (id === undefined) return err(badMeta(path, "缺字段 \"id\"", "id"));
  if (typeof id !== "string") return err(badMeta(path, "字段 \"id\" 必须是字符串", "id"));
  if (!ID_RE.test(id)) {
    return err(
      badMeta(path, `字段 "id" 的值 "${id}" 不匹配 /^[a-z0-9]{1,40}$/（身份必须是稳定的小写 base36）`, "id"),
    );
  }

  const type = o["type"];
  if (type === undefined) return err(badMeta(path, "缺字段 \"type\"", "type"));
  if (typeof type !== "string" || type.length === 0) {
    return err(badMeta(path, "字段 \"type\" 必须是非空字符串", "type"));
  }

  const version = o["importerVersion"];
  if (version === undefined) return err(badMeta(path, "缺字段 \"importerVersion\"", "importerVersion"));
  if (typeof version !== "number" || !Number.isInteger(version) || version < 0) {
    return err(badMeta(path, "字段 \"importerVersion\" 必须是非负整数", "importerVersion"));
  }

  const settings = o["settings"];
  if (settings === undefined) return err(badMeta(path, "缺字段 \"settings\"", "settings"));
  if (typeof settings !== "object" || settings === null || Array.isArray(settings)) {
    return err(badMeta(path, "字段 \"settings\" 必须是 JSON 对象", "settings"));
  }

  return ok({
    id,
    type,
    importerVersion: version,
    settings: settings as Record<string, unknown>,
  });
}

/**
 * 读 `.meta`。**不存在返回 ok(null)**，不是错误 —— "还没有导入过"是正常状态。
 * 存在但读不出来（权限/编码）或内容不合法 → `IMPORT.BAD_META`。
 */
export async function readMeta(
  fs: IFileSystem,
  sourcePath: string,
): Promise<Result<MetaRecord | null, EngineError>> {
  const mp = metaPathOf(sourcePath);
  if (!(await fs.exists(mp))) return ok(null);
  const r = await fs.readText(mp);
  if (!r.ok) {
    return err(badMeta(mp, `读取失败（${r.error.message}）`));
  }
  return parseMeta(mp, r.value);
}

/**
 * 写 `.meta`：**单行 + 末尾换行**。
 * 单行让"一个资产一行"在 diff 里成立；末尾换行是 POSIX 文本文件的约定，
 * 否则 `git diff` 会显示 "\ No newline at end of file"。
 */
export async function writeMeta(
  fs: IFileSystem,
  sourcePath: string,
  rec: MetaRecord,
): Promise<Result<void, EngineError>> {
  const text =
    `{"id":${JSON.stringify(rec.id)},` +
    `"type":${JSON.stringify(rec.type)},` +
    `"importerVersion":${JSON.stringify(rec.importerVersion)},` +
    `"settings":${JSON.stringify(rec.settings)}}\n`;
  return fs.writeText(metaPathOf(sourcePath), text);
}

export interface EnsureMetaResult {
  readonly record: MetaRecord;
  /** true = 这次新建了 `.meta`（报告的 `created` 用它）。 */
  readonly created: boolean;
}

/**
 * 确保 `.meta` 存在。
 * ★ 存在时**原样沿用整个记录**（尤其是 id）：即使源文件被改名到别的目录，
 *   id 也不重新派生 —— 这正是"移动/改名保 id"的实现点。
 *   新建时才用 `stableIdFromPath(相对路径)`。
 */
export async function ensureMeta(
  fs: IFileSystem,
  sourcePath: string,
  type: string,
  settings: Readonly<Record<string, unknown>>,
): Promise<Result<EnsureMetaResult, EngineError>> {
  const cur = await readMeta(fs, sourcePath);
  if (!cur.ok) return err(cur.error);
  if (cur.value !== null) return ok({ record: cur.value, created: false });

  const record: MetaRecord = {
    id: stableIdFromPath(relativePathOf(sourcePath)),
    type,
    importerVersion: 1,
    settings,
  };
  const w = await writeMeta(fs, sourcePath, record);
  if (!w.ok) return err(w.error);
  return ok({ record, created: true });
}

/**
 * 一轮扫描内的 id 占用表。
 * 单独抽出来是因为"冲突"只有跨文件的视角才看得见 —— 单个 `.meta` 自己永远合法。
 */
export class MetaIdTable {
  private readonly byId = new Map<AssetId, string>();

  claim(id: AssetId, sourcePath: string): Result<void, EngineError> {
    const prev = this.byId.get(id);
    if (prev !== undefined && prev !== sourcePath) {
      return err(
        engineError(
          "IMPORT.ID_COLLISION",
          `id 冲突：${id} 同时被 ${prev} 与 ${sourcePath} 使用（不自动加后缀：那会让身份不可预测）`,
          { id, first: prev, second: sourcePath },
        ),
      );
    }
    this.byId.set(id, sourcePath);
    return ok(undefined);
  }

  get size(): number {
    return this.byId.size;
  }

  /** 这个 id 在本轮扫描结果里是否还存在（增量命中前的依赖存活检查）。 */
  has(id: AssetId): boolean {
    return this.byId.has(id);
  }
}
