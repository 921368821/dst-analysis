/**
 * L4 · 编辑器：场景树快照
 *
 * 面板上那一列树是从场景现算的一份**快照**（不是长期持有的引用）：
 * 节点的父子关系会被 `reparent` 改、会被 `destroy` 删，
 * 拿引用去画树的后果是「树里有一行，点它却崩」。
 *
 * 两条不能省的定义：
 *
 * ① **子节点按 id 升序**。`Node.children` 是插入序，而插入序在
 *    「销毁后重建」「拖拽换父」之后与 id 序不一致 —— 每次都按 id 排，
 *    才能让同一份场景在任意两次刷新里长得一样（否则人眼睛跟丢）。
 *
 * ② **截断要有痕迹**（`truncated`）。资源节点上千个时面板不能一次全画，
 *    但「少画了」必须能被人看见，否则「树里没有那个节点」会被当成 bug 排查。
 */

import type { Node, NodeId } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";

export interface OutlineNode {
  readonly id: NodeId;
  readonly name: string;
  /** 该节点上挂的组件类型（按挂载顺序，**不排序** —— 顺序本身就是信息）。 */
  readonly types: readonly string[];
  readonly children: readonly OutlineNode[];
}

export interface OutlineOptions {
  /** 含这些类型的节点**连同子树**都不出现（例如默认藏掉 `render.sprite` 的装饰层）。 */
  readonly skipTypes?: readonly string[];
  readonly maxDepth?: number;
  readonly maxNodes?: number;
}

export interface OutlineResult {
  readonly root: OutlineNode;
  /** 真的装进快照的节点数。 */
  readonly count: number;
  /** 因为 `maxNodes` / `maxDepth` 少装了东西。 */
  readonly truncated: boolean;
}

/** 默认上限：4000 个节点全画一遍面板会卡到没法用，而 2048 已经远超手搭场景的量。 */
const DEFAULT_MAX_NODES = 2048;
const DEFAULT_MAX_DEPTH = 32;

export function buildOutline(scene: Scene, opts: OutlineOptions = {}): OutlineResult {
  const skip = new Set(opts.skipTypes ?? []);
  const maxDepth = opts.maxDepth ?? DEFAULT_MAX_DEPTH;
  const maxNodes = opts.maxNodes ?? DEFAULT_MAX_NODES;
  let count = 0;
  let truncated = false;

  const walk = (n: Node, depth: number): OutlineNode | null => {
    if (count >= maxNodes) {
      truncated = true;
      return null;
    }
    // 根不参与 skip：树总要有一个锚，否则 `outline` 会返回一个空壳而面板彻底空白
    if (depth > 0 && skip.size > 0 && n.components.some((c) => skip.has(c.type))) return null;
    count++;
    const kids: OutlineNode[] = [];
    if (depth < maxDepth) {
      const sorted = [...n.children].sort((a, b) => a.id - b.id);
      for (const k of sorted) {
        const kn = walk(k, depth + 1);
        if (kn !== null) kids.push(kn);
      }
    } else if (n.children.length > 0) {
      // 到了深度上限还有孩子：这是截断，不是「没有孩子」
      truncated = true;
    }
    return { id: n.id, name: n.name, types: n.components.map((c) => c.type), children: kids };
  };

  const root = walk(scene.root, 0) ?? {
    id: scene.root.id,
    name: scene.root.name,
    types: [] as readonly string[],
    children: [] as readonly OutlineNode[],
  };
  return { root, count, truncated };
}

export interface OutlineRow {
  readonly node: OutlineNode;
  readonly depth: number;
}

/** 深度优先摊平（面板一行一行画就是按这个序）。 */
export function flattenOutline(o: OutlineNode, depth = 0): OutlineRow[] {
  const rows: OutlineRow[] = [{ node: o, depth }];
  for (const c of o.children) rows.push(...flattenOutline(c, depth + 1));
  return rows;
}
