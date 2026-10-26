/**
 * L4 · 编辑器：资产列表（资产浏览器的一半）
 *
 * 这一层只回答一个问题：**「哪些文件是可用的资产，它们各自长什么样」**。
 * 另一半（面板画出来、点一下加进场景）在 `editor-entry.ts` 里。
 *
 * ★ 五条定义，每条都对应一个真实会出错的假象：
 *
 * ① **列表必须来自一份显式清单，不能靠扫目录。**
 *    浏览器端的资源后端是 `HttpFileSystem`，它的 `canList = false`
 *    （HTTP 没有「列出目录」这个操作，见 `backends/fs-http/fs.ts`）。
 *    所以页面**不可能**自己去列 `web/assets`。清单是唯一诚实的来源，
 *    代价是它**会过期** —— 于是判据里有一条拿真目录对账
 *    （`tests/extensions/editor-assets.test.ts`），加一个文件忘了写清单就红。
 *    没有那条对账，清单就是一份「看着像真的」的假数据。
 *
 * ② **`.meta` sidecar 不是资产。**
 *    导入管线会给每个源文件写 `x.png.meta`。把它当资产列出来，
 *    列表里每张图会出现两次，而其中一条点下去什么都不会发生。
 *
 * ③ **身份沿用 `stableIdFromPath`，不另立一套。**
 *    与导入管线同一个规则，才能保证「面板里显示的 id」= 「导入后真正的 id」。
 *    两处各写一套的差异只在跨会话/跨机器才显形（同一个文件在两个地方是两个资产），
 *    属于最难查的那一类。
 *
 * ④ **`inAtlas`（有没有对应帧）必须由这一层算出来。**
 *    编辑器当前只挂了一张程序化图集（6 帧），而 `web/assets` 里有 14 个文件。
 *    不标出来的话，用户点了「加入场景」的结果是**什么都没有**，
 *    而画面上没有任何痕迹 —— 他会去查渲染、查相机、查层级，最后才发现是没帧。
 *    列表里就标「无帧」，创建时也拒（`addSpriteNodeWithUndo`）。
 *
 * ⑤ **排序必须确定。**
 *    `readdir` 的顺序因平台/文件系统而异；靠它决定面板顺序的后果是
 *    「每次打开顺序都不一样」（人跟丢）以及「判据靠顺序就变成碰运气」。
 *    一律按**路径**排（大小写不敏感，再按原文）—— 面板是个文件浏览器，
 *    人按他记得的那个文件名去找，不是按"资产名"。
 *
 * ★ 一条**没写**的检查，理由要留在代码里：这里**不检测 id 碰撞**。
 *   `meta.ts` 遇到 id 撞车会拒绝（「宁可报错让人清理」），但那条规则在**导入**侧：
 *   它面对的是"整个工程扫下来的路径"，而这里面对的是十来个资产。
 *   而且 `stableIdFromPath` 是未做终混的 FNV-1a —— 每一步都是双射，
 *   实测在几万组不同长度路径里也构造不出碰撞对（32 位空间上一个真实工程够不着）。
 *   写一段永远进不去的分支，等于给后来的自己留一条"看起来安全"的路：
 *   它会让人以为碰撞被处理过了，而实际上谁都没见过它跑起来。
 *   真需要时（资产上万、或换掉哈希），先造出碰撞用例再加。
 */

import type { AssetId } from "../../core/asset/asset.ts";
import { stableIdFromPath } from "../../core/asset/asset.ts";
import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";

/** 列表/清单读坏了。与 `EDIT.BAD_DOC` 分开：一个坏的是场景，一个坏的是清单。 */
export const EDIT_BAD_ASSET_LIST = "EDIT.BAD_ASSET_LIST";

/** 清单版本。比它新就拒绝 —— 与 `scene-io` 的 `format` 闸门同一条理由。 */
export const ASSET_MANIFEST_VERSION = 1;

export type AssetKind = "texture" | "text" | "atlas" | "font";

/**
 * 后缀 → 类别。**必须与 `asset-import/importers/*` 注册的后缀集合一致**
 * （判据里有一条拿 `ImporterRegistry.extensions()` 双向核对）。
 *
 * ★ 顺序无关：查表时**最长后缀优先**，与 `ImporterRegistry.find` 同一条规则。
 *   否则 `.atlas.json` 会先被 `.json` 吃掉，图集在面板里显示成文本资产。
 */
const KIND_BY_EXT: ReadonlyMap<string, AssetKind> = new Map([
  [".png", "texture"],
  [".jpg", "texture"],
  [".jpeg", "texture"],
  [".fnt", "font"],
  [".txt", "text"],
  [".json", "text"],
  [".lua", "text"],
  [".md", "text"],
  [".atlas.json", "atlas"],
]);

/** 最长后缀优先。找不到 → `undefined`（= 不是资产）。 */
export function classifyExtension(path: string): { readonly kind: AssetKind; readonly ext: string } | undefined {
  const p = path.toLowerCase();
  let best: string | undefined;
  for (const ext of KIND_BY_EXT.keys()) {
    if (p.endsWith(ext) && (best === undefined || ext.length > best.length)) best = ext;
  }
  if (best === undefined) return undefined;
  const kind = KIND_BY_EXT.get(best);
  return kind === undefined ? undefined : { kind, ext: best };
}

/** 文件名部分（去掉目录）。 */
function baseOf(path: string): string {
  const i = path.lastIndexOf("/");
  return i < 0 ? path : path.slice(i + 1);
}

/**
 * 资产名（也是它在图集里的帧名）：去掉**最长已知后缀**后的文件名。
 * `tree.png` → `tree`；`world.atlas.json` → `world`。
 */
export function assetNameOf(path: string): string {
  const kind = classifyExtension(path);
  if (kind === undefined) return baseOf(path);
  const base = baseOf(path);
  const trimmed = base.slice(0, base.length - kind.ext.length);
  return trimmed === "" ? base : trimmed;
}

export interface AssetEntry {
  readonly id: AssetId;
  /** 清单/目录里的相对路径（`ui/skin.png` 这种）。 */
  readonly path: string;
  /** 名字，同时是帧名。 */
  readonly name: string;
  readonly kind: AssetKind;
  /** 当前图集里有没有同名帧。`false` = 加不进场景（这一层就把话说清楚）。 */
  readonly inAtlas: boolean;
}

export type SkipReason = "sidecar" | "unknown-ext" | "duplicate-path" | "bad-path";

export interface SkippedAsset {
  readonly path: string;
  readonly reason: SkipReason;
}

export interface AssetCatalog {
  readonly entries: readonly AssetEntry[];
  readonly skipped: readonly SkippedAsset[];
}

export interface CatalogOptions {
  /** 图集里现有的帧名。省略 = 不知道，于是全部按「无帧」处理（不猜）。 */
  readonly frameNames?: Iterable<string>;
}

/** 路径合法性：相对、非空、不含 `..` 段、不以 `/` 开头。 */
function pathProblem(path: string): string | null {
  if (path.trim() === "") return "空路径";
  if (path.startsWith("/")) return "不许是绝对路径";
  if (/^[a-zA-Z]:/.test(path)) return "不许带盘符";
  for (const seg of path.split("/")) {
    if (seg === "..") return "不许含 .. 段";
  }
  return null;
}

/**
 * 把**一堆路径**整理成资产目录。
 *
 * 为什么不接 `IFileSystem`：页面拿不到目录（见文件头 ①），Node 侧那条路也没有
 * 调用方。函数只吃"路径列表"，两侧（清单 / 目录扫描）走同一条整理规则，
 * 于是「清单说有哪些」与「磁盘上有哪些」的差异只剩在**入参**上，可以直接对账。
 */
export function buildAssetCatalog(paths: readonly string[], opts: CatalogOptions = {}): AssetCatalog {
  const frames = opts.frameNames === undefined ? undefined : new Set(opts.frameNames);
  const skipped: SkippedAsset[] = [];
  const seenPath = new Set<string>();
  const entries: AssetEntry[] = [];

  for (const raw of paths) {
    const path = raw.replace(/\\/g, "/");
    const problem = pathProblem(path);
    if (problem !== null) {
      skipped.push({ path: raw, reason: "bad-path" });
      continue;
    }
    // ② sidecar：先判，否则 `x.png.meta` 会以 `unknown-ext` 的名义被记一条，
    //   看着像"有个怪文件"，其实那是导入管线自己的产物。
    if (path.toLowerCase().endsWith(".meta")) {
      skipped.push({ path, reason: "sidecar" });
      continue;
    }
    const cls = classifyExtension(path);
    if (cls === undefined) {
      skipped.push({ path, reason: "unknown-ext" });
      continue;
    }
    if (seenPath.has(path)) {
      skipped.push({ path, reason: "duplicate-path" });
      continue;
    }
    seenPath.add(path);

    const id = stableIdFromPath(path);
    const name = assetNameOf(path);
    entries.push({ id, path, name, kind: cls.kind, inAtlas: frames === undefined ? false : frames.has(name) });
  }

  // ⑤ 确定性排序：按路径（不区分大小写），再按原文兜底（大小写不同才用到）。
  //    按路径而不是按名字：面板是"文件浏览器"，人按他记得的那个文件去找，
  //    而子目录里的 `a/zzz.png` 名字是 `zzz` —— 按名字排会让它跑到 `tree` 后面，
  //    看起来像列表坏了。
  entries.sort((a, b) => {
    const ap = a.path.toLowerCase();
    const bp = b.path.toLowerCase();
    if (ap !== bp) return ap < bp ? -1 : 1;
    return a.path < b.path ? -1 : a.path > b.path ? 1 : 0;
  });

  return { entries, skipped };
}

/**
 * 解析资产清单。
 *
 * ★ 严格到什么程度：`version` 必须**等于**当前值（更新的版本拒绝 ——
 *   它可能带来这一层不认识的字段语义，静默按旧规则读会得到一份"缺了一半"的列表）；
 *   `assets` 里必须全是字符串。**不**拒绝重复项与怪路径 —— 那些交给
 *   `buildAssetCatalog` 记进 `skipped`，一条坏行不该让整个面板空白。
 */
export function parseAssetManifest(text: string): Result<readonly string[], EngineError> {
  const clean = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  let raw: unknown;
  try {
    raw = JSON.parse(clean);
  } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    return err(engineError(EDIT_BAD_ASSET_LIST, `资产清单不是合法 JSON：${why}`));
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return err(engineError(EDIT_BAD_ASSET_LIST, "资产清单必须是一个对象"));
  }
  const obj = raw as Record<string, unknown>;
  const version = obj["version"];
  if (typeof version !== "number" || !Number.isInteger(version)) {
    return err(engineError(EDIT_BAD_ASSET_LIST, "资产清单缺 version（或不是整数）"));
  }
  if (version !== ASSET_MANIFEST_VERSION) {
    return err(
      engineError(
        EDIT_BAD_ASSET_LIST,
        `资产清单版本 ${String(version)} 与编辑器认识的 ${String(ASSET_MANIFEST_VERSION)} 不一致`
          + (version > ASSET_MANIFEST_VERSION ? "（清单比编辑器新，拒绝按旧规则读）" : "（清单太旧，请重新生成）"),
      ),
    );
  }
  const assets = obj["assets"];
  if (!Array.isArray(assets)) {
    return err(engineError(EDIT_BAD_ASSET_LIST, "资产清单缺 assets 数组"));
  }
  const out: string[] = [];
  for (let i = 0; i < assets.length; i++) {
    const v = assets[i];
    if (typeof v !== "string") {
      return err(engineError(EDIT_BAD_ASSET_LIST, `assets[${String(i)}] 不是字符串（${typeof v}）`));
    }
    out.push(v);
  }
  return ok(out);
}

/** 清单 + 图集帧名 → 可直接画的面板数据。坏清单原样把错误码交回去，不吞。 */
export function catalogFromManifest(
  text: string,
  opts: CatalogOptions = {},
): Result<AssetCatalog, EngineError> {
  const paths = parseAssetManifest(text);
  if (!paths.ok) return paths;
  return ok(buildAssetCatalog(paths.value, opts));
}
