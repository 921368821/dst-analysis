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

/** 这个路径是不是一份决策树资产（编辑器打开/资产清单用）。 */
export function isTreeAssetPath(path: string): boolean {
  return path.toLowerCase().endsWith(TREE_FILE_SUFFIX);
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
