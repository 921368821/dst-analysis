/**
 * L4 · 决策树的编辑模型（纯函数）—— 批157
 *
 * 批155 让树能存成文件、能按 id 被引用；批156 让宿主把文件装进库。到这里为止，
 * 改树的方式仍然是**打开 `.tree.json` 用文本编辑器敲 JSON** —— 而 JSON 里没有一行
 * 提示「这个 sequence 空了会装不上」。这个文件是「策划能改 AI」的最后一段：
 * **在面板上增删拖拽节点，并且当场知道哪里装不上**。
 *
 * ★★ 四个决定：
 *
 * ① **编辑不拦坏树，判据只报不修**（与 `tree-asset.ts` 的装载路径刻意相反）。
 *    装载必须硬失败（坏树进库 ⇒ 某只怪第 500 拍才炸），但**编辑**必须允许中间态：
 *    「加一个 selector，再往里放两个分支」在时间上必然经过「selector 没有子节点」那一瞬。
 *    每一步都硬校验的话，这个最自然的动作根本做不出来（只能先加个占位叶子再删）。
 *    专业引擎的节点图也是这个分工：图里可以留红线，**跑之前**才要求合法。
 *    所以这里：结构操作只管结构，合法性由 `treeIssue` 报出、由导出前的
 *    `checkTree` 把关。
 *
 * ② **合法性规则不复制一份**。`treeIssue` 的全部判断来自 `checkTree`（→ `AiAgent.create`），
 *    这里只多做一件事：把错误里的 `detail.path`（`root.children[1].children[0]` 这种串）
 *    映射回**下标路径**，好让面板把那一行标红。
 *    ★ 映射靠字符串相等，所以两边的路径写法必须一致 —— `pathText` 就是那个约定的实现，
 *      判据里钉住「校验器消息以 `pathText` 开头」这条跨模块契约（见 tests ⑥）。
 *      写第二份校验规则的后果是两份漂移：一边放行另一边拒绝，而症状是
 *      「面板上说没问题，进游戏第一拍就抛」。
 *
 * ③ **结构操作对原树一律不改**（每次返回新根，未受影响的子树按引用共享）。
 *    撤销栈因此可以只存根快照：树是几十个节点的纯数据，快照比命令对象便宜得多，
 *    也不会出现「命令重放顺序错了一格」这类只在大树上才暴露的 bug。
 *    编辑器的撤销栈就建在这个性质上（`editor-entry.ts` 里那个 `treeUndo`）。
 *
 * ④ **移动要按「目标父」而不是「目标下标」定位**，并且在摘掉源节点之后**修正下标**
 *    （`pathAfterRemoval`）。这是拖拽最常见的一类错：源码里先算好的目标下标在
 *    源节点被摘掉之后就偏了一格 —— 表现为「往右拖一格，它却落到了两格外」，
 *    而且只在源在目标左边时错。按引用定位也不行：摘节点会重建它到根的那条链，
 *    而「同父内换序」正好让目标父就在那条链上（重建后引用已经不是原来那个）。
 */

import type { AiNode, AiNodeKind, AiOps } from "../ai/behavior.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { MOB_OPS } from "./mob-tree.ts";
import { checkTree } from "./tree-asset.ts";

/** 根节点不能删、也不能被移进自己（见 `removeNode` / `moveNode`）。 */
export const TREE_EDIT_ROOT = "TREE_EDIT.ROOT";
/** 目标是自己的子孙 ⇒ 移过去会成环（见 `moveNode`）。 */
export const TREE_EDIT_CYCLE = "TREE_EDIT.CYCLE";
/** 路径指不到节点（面板拿着过期路径，或调用方算错了）。 */
export const TREE_EDIT_BAD_PATH = "TREE_EDIT.BAD_PATH";

/** 从根往下走的下标路径：根 = `[]`，`[0]` = 根的第 1 个子节点。 */
export type TreePath = readonly number[];

export interface TreeRow {
  readonly path: TreePath;
  readonly depth: number;
  /** 在它父亲里的序号（= `path` 最后一段；根为 -1）。 */
  readonly index: number;
  readonly node: AiNode;
}

/** 面板上那一行的主文案（ASCII，见 `mob-inspector.ts` ③ 的同一条理由）。 */
export function labelOf(node: AiNode): string {
  if (node.op !== undefined) return `${node.kind}:${node.op}`;
  if (node.ticks !== undefined) return `${node.kind}:${String(node.ticks)}`;
  return node.kind;
}

/** 深度优先、父在子前（面板从上到下的顺序就是它）。 */
export function flattenTree(root: AiNode): TreeRow[] {
  const out: TreeRow[] = [];
  const walk = (node: AiNode, path: TreePath, depth: number): void => {
    out.push({ path, depth, index: path.length === 0 ? -1 : path[path.length - 1]!, node });
    const kids = node.children ?? [];
    for (let i = 0; i < kids.length; i++) walk(kids[i]!, [...path, i], depth + 1);
  };
  walk(root, [], 0);
  return out;
}

export function nodeAt(root: AiNode, path: TreePath): AiNode | undefined {
  let cur: AiNode | undefined = root;
  for (const i of path) {
    cur = cur.children?.[i];
    if (cur === undefined) return undefined;
  }
  return cur;
}

/**
 * 下标路径 → 校验器用的那条串（`root` / `root.children[0].children[2]`）。
 *
 * ★ 这就是 `behavior.ts` 里的写法（见文件头 ②）：两边必须是同一份约定，
 *   而它是**唯一**能让「校验器的报错」与「面板上的某一行」对上号的东西。
 */
export function pathText(path: TreePath): string {
  let s = "root";
  for (const i of path) s += `.children[${String(i)}]`;
  return s;
}

/** `pathText` 的反向：解析不出来、或那一段真的不存在 ⇒ null（不谎称指到某一格）。 */
export function pathFromText(root: AiNode, text: string): TreePath | null {
  if (text === "root") return [];
  if (!text.startsWith("root.")) return null;
  const parts = text.slice("root.".length).split(".");
  const out: number[] = [];
  for (const p of parts) {
    const m = /^children\[(\d+)\]$/.exec(p);
    if (m === null) return null;
    out.push(Number(m[1]));
  }
  return nodeAt(root, out) === undefined ? null : out;
}

function isPrefix(a: TreePath, b: TreePath): boolean {
  if (a.length > b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

/** 深拷贝（只走 `AiNode` 的三个可选字段；不用 `structuredClone`，它在某些宿主里没有）。 */
export function cloneNode(node: AiNode): AiNode {
  const out: { -readonly [K in keyof AiNode]: AiNode[K] } = { id: node.id, kind: node.kind };
  if (node.op !== undefined) out.op = node.op;
  if (node.ticks !== undefined) out.ticks = node.ticks;
  if (node.children !== undefined) out.children = node.children.map(cloneNode);
  return out;
}

function badPath(path: TreePath): Result<never, EngineError> {
  return err(engineError(TREE_EDIT_BAD_PATH, `树里没有 ${pathText(path)} 这个位置`, { path: pathText(path) }));
}

/**
 * 在 `parentPath` 下插入一个子节点（`at` 省略 = 末尾）。
 *
 * ★ 不做合法性判断（文件头 ①）：往叶子下面挂子节点是**允许的中间态**，
 *   面板会把它标红、导出会被 `checkTree` 挡住。这一层只回答「插到哪」。
 */
export function addChild(
  root: AiNode,
  parentPath: TreePath,
  child: AiNode,
  at?: number,
): Result<AiNode, EngineError> {
  const parent = nodeAt(root, parentPath);
  if (parent === undefined) return badPath(parentPath);
  const kids = parent.children ?? [];
  const i = at === undefined ? kids.length : Math.max(0, Math.min(at, kids.length));
  const next: AiNode = { ...parent, children: [...kids.slice(0, i), child, ...kids.slice(i)] };
  return replaceAt(root, parentPath, next);
}

/** 把 `path` 那一格换成 `next`（内部用；调用方保证 `path` 存在）。 */
function replaceAt(root: AiNode, path: TreePath, next: AiNode): Result<AiNode, EngineError> {
  if (path.length === 0) return ok(next);
  const slot = path[0]!;
  const kid = root.children?.[slot];
  if (kid === undefined) return badPath(path);
  const r = replaceAt(kid, path.slice(1), next);
  if (!r.ok) return r;
  const kids = [...(root.children ?? [])];
  kids[slot] = r.value;
  return ok({ ...root, children: kids });
}

/** 删掉 `path` 及其整棵子树。根不能删（删了就没有树了）。 */
export function removeNode(root: AiNode, path: TreePath): Result<AiNode, EngineError> {
  if (path.length === 0) return err(engineError(TREE_EDIT_ROOT, "根节点不能删（可以换它的 kind）"));
  const parentPath = path.slice(0, -1);
  const parent = nodeAt(root, parentPath);
  if (parent === undefined) return badPath(path);
  const slot = path[path.length - 1]!;
  const kids = parent.children ?? [];
  if (kids[slot] === undefined) return badPath(path);
  const next: AiNode = { ...parent, children: kids.filter((_, i) => i !== slot) };
  return replaceAt(root, parentPath, next);
}

/**
 * 从 `from` 摘掉一个节点之后，路径 `to` 在新树里的位置（文件头 ④）。
 *
 * 只有「同父且排在源之后」这一种情形需要减一；目标是源的祖先或别的分支时不变。
 */
export function pathAfterRemoval(from: TreePath, to: TreePath): TreePath {
  const parent = from.slice(0, -1);
  if (to.length <= parent.length) return to;
  for (let i = 0; i < parent.length; i++) if (to[i] !== parent[i]) return to;
  const sourceSlot = from[from.length - 1]!;
  const slot = to[parent.length]!;
  if (slot <= sourceSlot) return to;
  const out = [...to];
  out[parent.length] = slot - 1;
  return out;
}

/**
 * 把 `from` 移到 `to` 之下（`at` 省略 = 末尾）。
 *
 * 拒绝「移进自己」：`to` 是 `from` 的子孙（或就是它自己）时成环。
 * ★ 注意方向：`to` 是 `from` 的**祖先**是合法的 —— 那正是「同父内换序」。
 */
export function moveNode(
  root: AiNode,
  from: TreePath,
  to: TreePath,
  at?: number,
): Result<AiNode, EngineError> {
  if (from.length === 0) return err(engineError(TREE_EDIT_ROOT, "根节点不能移动"));
  if (isPrefix(from, to)) {
    return err(
      engineError(TREE_EDIT_CYCLE, `不能把 ${pathText(from)} 移到它自己（或它的子孙）下面`, {
        from: pathText(from),
        to: pathText(to),
      }),
    );
  }
  const moved = nodeAt(root, from);
  if (moved === undefined) return badPath(from);
  const targetParent = nodeAt(root, to);
  if (targetParent === undefined) return badPath(to);

  const pruned = removeNode(root, from);
  if (!pruned.ok) return pruned;
  const dest = pathAfterRemoval(from, to);
  const parent = nodeAt(pruned.value, dest);
  if (parent === undefined) return badPath(dest);
  const kids = parent.children ?? [];
  const i = at === undefined ? kids.length : Math.max(0, Math.min(at, kids.length));
  const next: AiNode = { ...parent, children: [...kids.slice(0, i), moved, ...kids.slice(i)] };
  return replaceAt(pruned.value, dest, next);
}

export interface TreePatch {
  readonly id?: string;
  /** 换节点种类（叶子之间、容器之间都能换；换完的合法性由 `treeIssue` 报）。 */
  readonly kind?: AiNodeKind;
  /** `do` / `check` 的行为名。 */
  readonly op?: string;
  /** `wait` 的 tick 数。 */
  readonly ticks?: number;
}

/**
 * 改一个节点的字段（id / kind / op / ticks）。子节点原样保留。
 *
 * ★ **kind 可以换**。不给换的话，「加一个节点再把它改成 do」这个动作就做不出来 ——
 *   只能靠工具栏上一个"新建时用哪种 kind"的选择器，而它在「新建」与「改现有」
 *   两处的语义不同（选中一行时那个选择器到底是模板还是结果？），比现在更难用。
 *   换完形状可能不合法（`do` 带着孩子），那正是面板红字要说的事（文件头 ①）。
 */
export function patchNode(root: AiNode, path: TreePath, patch: TreePatch): Result<AiNode, EngineError> {
  const node = nodeAt(root, path);
  if (node === undefined) return badPath(path);
  const next: { -readonly [K in keyof AiNode]: AiNode[K] } = {
    id: patch.id === undefined ? node.id : patch.id,
    kind: patch.kind === undefined ? node.kind : patch.kind,
  };
  const op = patch.op === undefined ? node.op : patch.op;
  if (op !== undefined) next.op = op;
  const ticks = patch.ticks === undefined ? node.ticks : patch.ticks;
  if (ticks !== undefined) next.ticks = ticks;
  if (node.children !== undefined) next.children = node.children;
  return replaceAt(root, path, next);
}

export interface TreeIssue {
  /** `AI.*` / `AI_TREE.*`：原样透出，不在这里重编号。 */
  readonly code: string;
  /** 校验器原文（人读的那一句）。 */
  readonly message: string;
  /** 消息里那个位置串（`root.children[1]`）；拿不到时为空串。 */
  readonly pathText: string;
  /** 映射回的下标路径；映射不到 = null（**不**谎称指到某一格）。 */
  readonly path: TreePath | null;
}

/**
 * 这棵树现在装不装得上。`null` = 装得上。
 *
 * ★ 只报**第一条**：校验器本来就是短路返回（第一个坏节点就停），
 *   而面板一次标一行比"标出一堆、其中大部分是同一个原因的下游"更有用。
 *   修掉第一条之后下一次调用会报下一条 —— 这是编辑器里"改一点、红字往上挪"的节奏。
 */
export function treeIssue(root: AiNode, ops: AiOps = MOB_OPS): TreeIssue | null {
  const r = checkTree(root, ops);
  if (r.ok) return null;
  const e = r.error;
  const detail = e.detail as { path?: unknown } | undefined;
  const text = typeof detail?.path === "string" ? detail.path : "";
  return {
    code: e.code,
    message: e.message,
    pathText: text,
    path: text === "" ? null : pathFromText(root, text),
  };
}

export interface TreeAdvice {
  readonly path: TreePath;
  readonly message: string;
}

/**
 * 「装得上，但大概不是你想要的」—— **不是**规则，所以不可能在这里拦住谁。
 *
 * ★ 为什么这两条只能是建议：它们都是**玩法语义**上的可疑，不是树结构的非法。
 *   一个只有单个孩子的 `sequence` 与直接挂那个孩子，跑起来完全等价（多一层游标而已），
 *   `wait 0` 也只是「本拍立即成功」——两者都能跑、都可能是故意的（比如留着位置待编辑）。
 *   把它们塞进 `AiAgent.create` 会让「合法的树」这个集合变小，而改动它的代价是
 *   所有现存资产都要重审；写在这里，面板黄字提示、人可以不理。
 */
export function treeAdvice(root: AiNode): TreeAdvice[] {
  const out: TreeAdvice[] = [];
  for (const row of flattenTree(root)) {
    const n = row.node;
    const kids = n.children ?? [];
    if ((n.kind === "sequence" || n.kind === "selector") && kids.length === 1) {
      out.push({ path: row.path, message: `${n.kind} 只有一个子节点 —— 这一层等于没有` });
    }
    if (n.kind === "wait" && n.ticks === 0) {
      out.push({ path: row.path, message: "wait 0 本拍立即成功，等于空语句" });
    }
  }
  return out;
}

export type TreeMarker = "none" | "bad" | "warn";

/** 面板要画的一行（纯数据；DOM 由 `editor-entry.ts` 拼）。 */
export interface TreeRowView {
  readonly path: TreePath;
  readonly depth: number;
  readonly index: number;
  readonly id: string;
  readonly kind: AiNodeKind;
  readonly detail: string;
  readonly kids: number;
  readonly marker: TreeMarker;
}

function samePath(a: TreePath, b: TreePath): boolean {
  return isPrefix(a, b) && a.length === b.length;
}

/**
 * 行模型。`bad` 优先于 `warn`：同一个节点既是第一条错又是建议时，
 * 面板只能有一行红字（两条都标会让人以为有两个问题）。
 */
export function treeRows(
  root: AiNode,
  issue: TreeIssue | null = treeIssue(root),
  advice: readonly TreeAdvice[] = treeAdvice(root),
): TreeRowView[] {
  const warned = new Set(advice.map((a) => pathText(a.path)));
  return flattenTree(root).map((r) => {
    const marker: TreeMarker =
      issue?.path !== null && issue?.path !== undefined && samePath(issue.path, r.path)
        ? "bad"
        : warned.has(pathText(r.path))
          ? "warn"
          : "none";
    return {
      path: r.path,
      depth: r.depth,
      index: r.index,
      id: r.node.id,
      kind: r.node.kind,
      detail: r.node.op !== undefined ? r.node.op : r.node.ticks !== undefined ? String(r.node.ticks) : "",
      kids: (r.node.children ?? []).length,
      marker,
    };
  });
}

/** 面板顶部那一行状态文案（红字 / 黄字 / 绿字共用一份，免得三处各写一半）。 */
export function treeStatusText(issue: TreeIssue | null, advice: readonly TreeAdvice[]): string {
  if (issue !== null) return `${issue.code}：${issue.message}`;
  if (advice.length > 0) return `装得上 · ${String(advice.length)} 条提醒`;
  return "装得上 · 没有提醒";
}
