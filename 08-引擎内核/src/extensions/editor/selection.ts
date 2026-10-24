/**
 * L4 · 编辑器：选中集（阶段 4 的第一块）
 *
 * 编辑器最先要有的不是面板，而是「**当前选中什么**」这件事的可靠定义。
 * 三个容易写错的点，各自都是判据：
 *
 * ① `ids()` 必须**升序**，不是点击顺序。属性面板按它出行；
 *    按点击顺序的话「点第三个时整行重排」，人点不到自己想点的那一行。
 *
 * ② `toggle` 把 primary 删掉时，primary 要**回落到剩下的最小 id**。
 *    悬空 primary 的后果是：右侧面板还显示着上一轮的内容，而标题写着「未选中」。
 *
 * ③ 必须能 `prune`：节点每帧都可能被销毁（击杀 / 采集 / 再生）。
 *    选中集里留着已死 id 的话，下一次「删除选中」删的是一个不存在的节点，
 *    错误被吞掉之后就表现成「按了没反应」。
 *
 * ★ 这一层不碰 DOM、不碰 Scene —— 于是它能在 Node 里被逐条判据钉住，
 *   而页面只负责把 `snapshot()` 画出来。
 */

import type { NodeId } from "../../core/scene/node.ts";

/** 选中集快照：`ids` 升序，`primary` 是属性面板要显示的那一个。 */
export interface SelectionSnapshot {
  readonly ids: readonly NodeId[];
  readonly primary: NodeId | null;
}

export class Selection {
  private readonly set = new Set<NodeId>();
  private primaryId: NodeId | null = null;

  /** 单选（替换整个选中集）。 */
  select(id: NodeId): void {
    this.set.clear();
    this.set.add(id);
    this.primaryId = id;
  }

  /** 加入选中集（不动其它）。 */
  add(id: NodeId): void {
    this.set.add(id);
    this.primaryId = id;
  }

  /** 反选：返回**操作后**是否在选中集里。 */
  toggle(id: NodeId): boolean {
    if (this.set.has(id)) {
      this.set.delete(id);
      if (this.primaryId === id) this.primaryId = this.lowest();
      return false;
    }
    this.set.add(id);
    this.primaryId = id;
    return true;
  }

  clear(): void {
    this.set.clear();
    this.primaryId = null;
  }

  has(id: NodeId): boolean {
    return this.set.has(id);
  }

  get size(): number {
    return this.set.size;
  }

  get primary(): NodeId | null {
    return this.primaryId;
  }

  /** 升序快照（新数组：调用方排序/删除不该改到内部状态）。 */
  ids(): NodeId[] {
    return [...this.set].sort((a, b) => a - b);
  }

  /**
   * 清掉已经不在场景里的 id，返回**被清掉的**（调用方据此提示「选中项消失了」）。
   * `isAlive` 由宿主提供（`(id) => scene.find(id) !== undefined`），
   * 这一层不依赖 Scene，于是它也能给「还没装配世界」的编辑器空架子用。
   */
  prune(isAlive: (id: NodeId) => boolean): NodeId[] {
    const gone: NodeId[] = [];
    for (const id of this.ids()) {
      if (!isAlive(id)) {
        this.set.delete(id);
        gone.push(id);
      }
    }
    if (this.primaryId !== null && !this.set.has(this.primaryId)) this.primaryId = this.lowest();
    return gone;
  }

  snapshot(): SelectionSnapshot {
    return { ids: this.ids(), primary: this.primaryId };
  }

  private lowest(): NodeId | null {
    const s = this.ids();
    return s.length === 0 ? null : s[0]!;
  }
}

export function createSelection(): Selection {
  return new Selection();
}
