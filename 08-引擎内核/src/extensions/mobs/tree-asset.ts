/**
 * L4 · 决策树资产（`.tree.json`）—— 树从「代码里的常量」变成「一个文件」
 *
 * 批154 让「配 AI」等于写一棵树，但那棵树还是 `mob-tree.ts` 里的一个 `export const`。
 * 策划想给猎狗加一条「先吃地上的肉再追人」，仍然要改源码、跑测试、发版。
 * 这个文件解决的是最后一段：**树能不能像一张图那样被存、被改、被引用**。
 *
 * ★★ 四个决定：
 *
 * ① **树的身份是 `AssetId`（GUID 字符串），不是内联 JSON**。
 *    场景里的字段是 `FieldType.Asset`，存的是 id —— 于是：
 *      · 不用给场景层加新的字段类型（嵌套对象进 schema 会连带改序列化、零值、编辑器控件）；
 *      · 一份树被一群生物共享，改一处全群生效（内联的话「调所有猎狗」要逐只改）；
 *      · 资产系统能算「谁用了它」（`AssetDatabase.dependents`），删树之前有人拦。
 *    代价是运行期要一次 id → 树的同步解析，那正是 `tree-library.ts` 的存在理由。
 *
 * ② **序列化是规范的（canonical）**：键序固定、缩进 2、末尾换行。
 *    同一棵树导两次必须逐字节相同 —— 否则「树没被改动」这件事在 git 里看不出来，
 *    而且资产导入的 `sourceHash` 每次都会变（等于每次都要重导入）。
 *    `AiNode` 的字段是可选的，所以**键序不能靠对象字面量顺序**：这里逐字段重排。
 *
 * ③ **校验只有一份，就是 `AiAgent.create`**（未知 op / 重复 id / 深度 / 形状）。
 *    这里只多做两件事：门面（format/version 闸门）与**把错误码换成资产语义**。
 *    写第二份校验规则的后果是两份漂移：一边放行的树另一边跑不起来，
 *    而症状是「编辑器里看着没问题，进游戏第一拍就抛」。
 *
 * ④ **版本比它新就拒绝**（`AI_TREE.BAD_VERSION`），与 `scene-io` 的 `format` 闸门同一条理由：
 *    新格式的字段旧代码读不懂，静默按缺省处理会把「策划配的那条分支」变成没有。
 *    宁可打不开，也不要打开成另一个样子。
 */

import { AiAgent, type AiNode, type AiOps } from "../ai/behavior.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { AssetId } from "../../core/asset/asset.ts";
import { MOB_OPS } from "./mob-tree.ts";

/** 资产文件后缀。与 `asset-list.ts` 的 `.json` 分类不冲突（最长后缀优先，这里只是识别用）。 */
export const TREE_FILE_SUFFIX = ".tree.json";

/** 资产里的 `format` 标记。**不是** `AssetType`（那是导入管线的分类，见 `asset.ts`）。 */
export const TREE_FORMAT = "aitree";

/** 格式版本。加字段就要 +1，并在这里留一条迁移说明。 */
export const TREE_FORMAT_VERSION = 1;

/** 资产本身是坏的（不是 JSON / 缺字段 / 形状不对）。 */
export const AI_TREE_BAD_ASSET = "AI_TREE.BAD_ASSET";
/** 版本比本代码新（见文件头 ④）。 */
export const AI_TREE_BAD_VERSION = "AI_TREE.BAD_VERSION";
/** 路径推不出一个合法的树 id（批156，见 `treeAssetIdFromPath`）。 */
export const AI_TREE_BAD_PATH = "AI_TREE.BAD_PATH";

/** 这个路径是不是一份决策树资产（编辑器打开/资产清单用）。 */
export function isTreeAssetPath(path: string): boolean {
  return path.toLowerCase().endsWith(TREE_FILE_SUFFIX);
}

/** 路径归一：反斜杠 → `/`，丢掉空段与 `.`（**保留** `..` —— 它要被拒绝，不是被吃掉）。 */
function normalizePath(p: string): string {
  return p
    .trim()
    .replace(/\\/g, "/")
    .split("/")
    .filter((s) => s.length > 0 && s !== ".")
    .join("/");
}

/**
 * 资产路径 → 树 id（批156）。**树的身份就是它在资产根下的路径**。
 *
 * ★★ 五个决定：
 *
 * ① **不哈希**（与 `core/asset` 的 `stableIdFromPath` 不同）。那边要的是"稳定且唯一"，
 *    这边多一条：**id 要能被人在组件的 `tree` 字段里读懂**。`p1k2j3h` 与
 *    `ai/hound` 在配置面板上没有可比性 —— 前者只能靠资产选择器点出来，
 *    而本仓库的编辑器对面这个字段给的是一个**文本框**（`FieldType.Asset` → `asset` 控件）。
 *    代价与 `stableIdFromPath` 一样写在这里：**改了路径就换了 id**，
 *    引用它的生物会以 `missing`（`treeFallbacks` + 面板 `miss <id>`）被数出来，
 *    而不是静默失效 —— 这正是批155 那套降级三件套存在的理由。
 *
 * ② **一律小写**。`Hound.tree.json` 与 `hound.tree.json` 在 Windows 上是同一个文件，
 *    而 id 是**字符串相等**语义。不归一的话同一棵树会有两个 id，
 *    其中一个永远解析不到 —— 症状是"我明明有这个文件，它却说没有"。
 *
 * ③ **`root` 剥掉，且必须真的匹配**。给了根而路径不在它下面 ⇒ 报错，
 *    不是"照原样当 id"：那会让 id 里带上 `web/assets/`，配置的人永远猜不到要写什么。
 *
 * ④ **空 id 拒绝**。根目录下直接放一个 `.tree.json` 推出来是空串，
 *    而空串在组件里表示"没配"（见 `tree-library.ts` 的 `DEFAULT_TREE_ASSET`）。
 *    两者合成一个的话，那棵树的引用状态就永远不可见了。
 *
 * ⑤ **`..` 拒绝**。id 里出现 `..` 说明这份文件在资产根外面 ——
 *    要么调用方算错了相对路径，要么有人在拼一个能读到别处的路径。
 */
export function treeAssetIdFromPath(path: string, root = ""): Result<AssetId, EngineError> {
  const p = normalizePath(path);
  const r = normalizePath(root);
  if (p.length === 0) {
    return err(engineError(AI_TREE_BAD_PATH, "树资产的路径是空的"));
  }
  let rel = p;
  if (r.length > 0) {
    // 见文件头 ③
    if (p === r) {
      return err(engineError(AI_TREE_BAD_PATH, `「${path}」是资产根本身，不是一份文件`, { path, root }));
    }
    if (!p.startsWith(`${r}/`)) {
      return err(engineError(AI_TREE_BAD_PATH, `「${path}」不在资产根「${root}」下`, { path, root }));
    }
    rel = p.slice(r.length + 1);
  }
  if (!rel.toLowerCase().endsWith(TREE_FILE_SUFFIX)) {
    return err(
      engineError(AI_TREE_BAD_PATH, `「${path}」不是决策树资产（要以 ${TREE_FILE_SUFFIX} 结尾）`, { path }),
    );
  }
  const id = rel.slice(0, rel.length - TREE_FILE_SUFFIX.length);
  // 见文件头 ④
  if (id.length === 0) {
    return err(
      engineError(AI_TREE_BAD_PATH, `「${path}」推出来是空 id —— 空串表示「没配」，不能当树的身份`, { path }),
    );
  }
  // 见文件头 ⑤
  if (id.split("/").some((s) => s === "..")) {
    return err(engineError(AI_TREE_BAD_PATH, `「${path}」推出的 id 里有「..」—— 这份文件在资产根外面`, { path }));
  }
  // 见文件头 ②
  return ok(id.toLowerCase());
}

/**
 * 规范化的节点对象。
 *
 * ★ 逐字段重排而不是 `JSON.stringify(node)`：`AiNode` 的 `op`/`ticks`/`children` 都是可选的，
 *   谁先写谁就先出现在字节里 —— 于是「同一棵树」在两个文件里 diff 出一堆无关改动。
 */
function canonicalNode(node: AiNode): Record<string, unknown> {
  const out: Record<string, unknown> = { id: node.id, kind: node.kind };
  if (node.op !== undefined) out.op = node.op;
  if (node.ticks !== undefined) out.ticks = node.ticks;
  if (node.children !== undefined) out.children = node.children.map(canonicalNode);
  return out;
}

/**
 * 树 → 资产文本（**规范形式**）。
 *
 * 不做校验：调用方多半刚从 `parseTreeAsset` 或 `AiAgent.create` 拿到树。
 * 真要校验，走 `checkTree`（导出给 `tree-library` 用）。
 */
export function serializeTreeAsset(tree: AiNode): string {
  const doc = { format: TREE_FORMAT, version: TREE_FORMAT_VERSION, root: canonicalNode(tree) };
  // 结尾换行：文件进版本库，最后一行没有换行符时多数 diff 工具会留一个 `\ No newline` 噪音
  return JSON.stringify(doc, null, 2) + "\n";
}

/**
 * 校验一棵树（形状 + op + id 唯一 + 深度）。
 *
 * ★ 唯一的规则源是 `AiAgent.create`（见文件头 ③）：这里只是把它的 `Result` 透出去。
 *   不复制一份判断逻辑 —— 那是最容易漂移的一类重复。
 */
export function checkTree(tree: AiNode, ops: AiOps = MOB_OPS): Result<AiNode, EngineError> {
  const created = AiAgent.create(tree, ops);
  if (!created.ok) return err(created.error);
  return ok(tree);
}

function bad(message: string, detail?: Readonly<Record<string, unknown>>): Result<never, EngineError> {
  return err(engineError(AI_TREE_BAD_ASSET, message, detail));
}

/**
 * 资产文本 → 树。
 *
 * `ops` 决定「哪些 op 名是合法的」：树里写了本工程没有的 op ⇒ `AI.UNKNOWN_OP`。
 * 这一条**必须在这里**发生（装载时），而不是等某只怪第 500 拍走到那条分支才炸。
 */
export function parseTreeAsset(text: string, ops: AiOps = MOB_OPS): Result<AiNode, EngineError> {
  let raw: unknown;
  try {
    raw = JSON.parse(text) as unknown;
  } catch (e) {
    return bad(`决策树资产不是合法 JSON：${e instanceof Error ? e.message : String(e)}`);
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return bad(`决策树资产必须是对象，收到 ${Array.isArray(raw) ? "数组" : typeof raw}`);
  }
  const doc = raw as { format?: unknown; version?: unknown; root?: unknown };
  if (doc.format !== TREE_FORMAT) {
    return bad(`format 必须是「${TREE_FORMAT}」，收到 ${JSON.stringify(doc.format)}`);
  }
  // 见文件头 ④
  if (typeof doc.version !== "number" || !Number.isInteger(doc.version) || doc.version < 1) {
    return bad(`version 必须是正整数，收到 ${JSON.stringify(doc.version)}`);
  }
  if (doc.version > TREE_FORMAT_VERSION) {
    return err(
      engineError(
        AI_TREE_BAD_VERSION,
        `决策树资产的版本 ${String(doc.version)} 比本代码支持的 ${String(TREE_FORMAT_VERSION)} 新 —— 拒绝打开（按旧格式读会丢字段）`,
        { version: doc.version, supported: TREE_FORMAT_VERSION },
      ),
    );
  }
  if (typeof doc.root !== "object" || doc.root === null || Array.isArray(doc.root)) {
    return bad("缺少 root 节点");
  }
  return checkTree(doc.root as AiNode, ops);
}
