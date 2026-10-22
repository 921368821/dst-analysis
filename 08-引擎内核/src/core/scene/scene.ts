/**
 * L2 · 场景
 *
 * 场景 = 一棵节点树 + 按类型索引的组件表 + 一个确定性的步进入口。
 *
 * ★ 三条"不许省"的机制：
 *
 * ① **结构性修改必须走命令队列**，在 `flush()` 时才真正执行。
 *    原因：`onUpdate` 里遍历组件数组时增删组件，会让遍历跳过元素或重复执行
 *    （上一代引擎为此不得不"先取快照"，而那只是把问题挪到别处）。
 *    这里把命令排队、在步进边界统一执行，于是：
 *      · 遍历期间结构不变（安全）
 *      · 命令可记录 ⇒ 可重放、可撤销、可确定性（这是下一个能力的前提）
 *
 * ② **步进顺序固定**：按组件类型的注册顺序分组更新。
 *    不按"节点顺序"更新 —— 因为节点的添加顺序取决于加载顺序，
 *    而加载顺序将来可能并行化。按类型分组是**与数据布局一致的稳定序**。
 *    这也让"同一类型的组件批处理"（将来的 job 化）不需要改调用方。
 *
 * ③ **实体 id 单调递增且可显式指定**（存档恢复时保持原 id）。
 *    不做 id 复用：复用会让"旧引用突然指向新对象"，是最难查的一类 bug。
 */

import { Vec2 } from "../../foundation/math/index.ts";
import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import { Component, isFastForwardable, type ComponentRegistry } from "./component.ts";
import { Node, type NodeId } from "./node.ts";

export type SceneCommand =
  | { readonly kind: "spawn"; readonly node: Node; readonly parent: NodeId | null }
  | { readonly kind: "destroy"; readonly node: NodeId }
  | { readonly kind: "attach"; readonly node: NodeId; readonly component: Component }
  | { readonly kind: "detach"; readonly node: NodeId; readonly type: string }
  | { readonly kind: "reparent"; readonly node: NodeId; readonly parent: NodeId | null }
  | { readonly kind: "run"; readonly fn: () => void; readonly label: string };

/** `fastForward` 的结果。`skipped > 0` 不是错误，但**必须被告知**。 */
export interface FastForwardReport {
  readonly elapsed: number;
  readonly handled: number;
  readonly skipped: number;
  readonly skippedByType: ReadonlyMap<string, number>;
}

export interface SceneStats {
  readonly nodes: number;
  readonly components: number;
  readonly pendingCommands: number;
  readonly stepsRun: number;
  readonly componentUpdates: number;
}

export class Scene {
  readonly name: string;
  readonly root: Node;
  private readonly byId = new Map<NodeId, Node>();
  /** 类型 → 组件集合。用数组而非 Set：遍历要顺序稳定且可索引。 */
  private readonly byType = new Map<string, Component[]>();
  /** 类型更新顺序：按首次注册的稳定序（不是节点顺序）。 */
  private readonly typeOrder: string[] = [];

  private pending: SceneCommand[] = [];
  private _steps = 0;
  private _updates = 0;
  private _fastForwarded = 0;

  /** 组件注册表：编辑器"可挂哪些组件"、读档"遇到未知类型找谁"都读它。 */
  readonly components: ComponentRegistry;

  constructor(name: string, components: ComponentRegistry) {
    this.components = components;
    this.name = name;
    this.root = new Node("__root__", 1);
    this.byId.set(this.root.id, this.root);
  }

  // ---------------------------------------------------------------- 查询
  get rootId(): NodeId {
    return this.root.id;
  }

  find(id: NodeId): Node | undefined {
    return this.byId.get(id);
  }

  /** 按类型取全部组件（返回内部数组，**只读用**；要改请走命令）。 */
  componentsOf<T extends Component>(type: string): readonly T[] {
    return (this.byType.get(type) ?? []) as unknown as readonly T[];
  }

  countOf(type: string): number {
    return this.byType.get(type)?.length ?? 0;
  }

  // ---------------------------------------------------------------- 结构性修改（排队）
  spawn(name: string, parent: NodeId | null = this.root.id, id?: NodeId): Result<Node, EngineError> {
    if (this.byId.has(id ?? -1)) {
      return err({ code: "SCENE.DUPLICATE_ID", message: `节点 id ${id} 已存在` });
    }
    const node = new Node(name, id);
    this.pending.push({ kind: "spawn", node, parent });
    return ok(node);
  }

  /** 立即建好（加载/编辑器用）。**游戏逻辑里请用 spawn（走队列）**。 */
  spawnImmediate(name: string, parent: NodeId | null = this.root.id, id?: NodeId): Node {
    const node = new Node(name, id);
    this.attachNodeTo(node, parent);
    return node;
  }

  destroy(id: NodeId): void {
    this.pending.push({ kind: "destroy", node: id });
  }

  attach<T extends Component>(nodeId: NodeId, make: () => T): Result<T, EngineError> {
    const c = make();
    if (!this.components.has(c.type)) {
      return err({
        code: "SCENE.UNKNOWN_COMPONENT",
        message: `组件类型 ${c.type} 未注册（先 components.register）`,
      });
    }
    this.pending.push({ kind: "attach", node: nodeId, component: c });
    return ok(c as T);
  }

  detach(nodeId: NodeId, type: string): void {
    this.pending.push({ kind: "detach", node: nodeId, type });
  }

  reparent(nodeId: NodeId, newParent: NodeId | null): void {
    this.pending.push({ kind: "reparent", node: nodeId, parent: newParent });
  }

  /** 排队一个任意回调（在同一处 flush 执行 ⇒ 顺序确定）。 */
  enqueue(fn: () => void, label = "custom"): void {
    this.pending.push({ kind: "run", fn, label });
  }

  get pendingCount(): number {
    return this.pending.length;
  }

  /**
   * 执行排队命令。
   * ★ 用**队列置换**而不是边遍历边 shift：命令里可能再 spawn（入新队列），
   *   那样本帧不会无限膨胀，且顺序严格按投递序。
   */
  flush(): number {
    if (this.pending.length === 0) return 0;
    const run = this.pending;
    this.pending = [];
    let n = 0;
    for (const cmd of run) {
      switch (cmd.kind) {
        case "spawn":
          if (!cmd.node.isDestroyed) this.attachNodeTo(cmd.node, cmd.parent);
          break;
        case "destroy": {
          const node = this.byId.get(cmd.node);
          if (node !== undefined && node.parent !== null) this.detachNode(node, true);
          break;
        }
        case "attach": {
          const node = this.byId.get(cmd.node);
          if (node !== undefined) this.attachTo(node, cmd.component);
          break;
        }
        case "detach": {
          const node = this.byId.get(cmd.node);
          const c = node?.get(cmd.type);
          if (node !== undefined && c !== undefined) this.detachFrom(node, c);
          break;
        }
        case "reparent": {
          const node = this.byId.get(cmd.node);
          const parent = cmd.parent === null ? this.root : this.byId.get(cmd.parent);
          if (node !== undefined && parent !== undefined) {
            parent.addChild(node);
            node.markTransformDirty();
          }
          break;
        }
        case "run":
          cmd.fn();
          break;
      }
      n++;
    }
    return n;
  }

  // ---------------------------------------------------------------- 步进
  /**
   * 推进一个固定步。
   * 顺序：flush（结构命令）→ 逐类型更新组件 → 再 flush（更新期投递的命令）
   * 两次 flush 是必须的：更新里投递的"销毁自己"不该延迟到下一帧。
   */
  step(tick: number, dt: number): void {
    this.flush();
    for (const type of this.typeOrder) {
      const list = this.byType.get(type);
      if (list === undefined || list.length === 0) continue;
      // 快照长度：本步内新增的组件不参与（它们是"下一步生效"）
      const n = list.length;
      for (let i = 0; i < n; i++) {
        const c = list[i];
        if (c === undefined || c.node === null) continue;
        const active = c.enabled && c.node.activeInHierarchy;
        c._setActive(active);
        if (active) {
          c.onUpdate(tick, dt);
          this._updates++;
        }
      }
    }
    this.flush();
    this._steps++;
  }

  /**
   * 跳时间结算（`LongUpdate` 语义）。
   *
   * 场景：存档 → 离线 8 小时 → 读档。不能真的跑 864000 个 tick，
   * 所以让**实现了 `IFastForwardable` 的组件**按解析式结算 elapsed 秒。
   *
   * ★ 关键设计：**报告跳过了多少**。没实现该接口的组件（例如 AI、
   *   状态机）在跳过的时段里"什么都没发生" —— 这必须是一个**可见的事实**，
   *   而不是"看起来读档成功了"。调用方据此决定"要不要改成循环 step"。
   */
  fastForward(elapsedSec: number): FastForwardReport {
    if (!(elapsedSec >= 0)) {
      throw new RangeError(`fastForward 不接受负的 elapsed：${elapsedSec}`);
    }
    let handled = 0;
    let skipped = 0;
    const skippedByType = new Map<string, number>();
    for (const type of this.typeOrder) {
      const list = this.byType.get(type);
      if (list === undefined) continue;
      for (const c of list) {
        if (c.node === null) continue;
        if (isFastForwardable(c)) {
          c.onFastForward(elapsedSec);
          handled++;
        } else {
          skipped++;
          skippedByType.set(type, (skippedByType.get(type) ?? 0) + 1);
        }
      }
    }
    this._fastForwarded += elapsedSec;
    return { elapsed: elapsedSec, handled, skipped, skippedByType };
  }

  /** 累计跳过的秒数（诊断：用来判断"这个存档是不是被跳过太多次"）。 */
  get totalFastForwarded(): number {
    return this._fastForwarded;
  }

  // ---------------------------------------------------------------- 内部
  private attachNodeTo(node: Node, parentId: NodeId | null): void {
    const parent = parentId === null ? this.root : this.byId.get(parentId);
    if (parent === undefined) {
      throw new Error(`spawn 的父节点 ${parentId} 不存在（命令已入队，父节点可能已被销毁）`);
    }
    parent.addChild(node);
    // 整棵子树登记（spawn 出来的节点可能已带子）
    node.walk((n) => {
      this.byId.set(n.id, n);
      for (const c of n.components) this.indexComponent(c);
    });
  }

  private attachTo(node: Node, c: Component): void {
    node.attach(c);
    this.indexComponent(c);
  }

  private detachFrom(node: Node, c: Component): void {
    this.unindexComponent(c);
    node.detach(c);
  }

  private detachNode(node: Node, recursive: boolean): void {
    // ★★ 必须**先**从父的 children 数组里摘掉。
    //   第一版只在 `recursive === false` 的分支里摘，于是：
    //     · `clear()`（走 recursive=true）之后 `root.children` 还留着旧节点；
    //     · `root.walk` 会继续遍历这些"已销毁"的节点 ⇒ `saveScene` 把它们写进存档；
    //     · 紧接着读档时新建同 id 节点 ⇒ children 里出现两个同 id（判据抓到的 2 → 3）。
    //   教训：`_markDestroyed` 只负责"对象自身失效"，**不负责脱离容器**。
    node.parent?.removeChild(node);
    node.walk((n) => {
      for (const c of [...n.components]) this.unindexComponent(c);
      this.byId.delete(n.id);
    });
    if (recursive) node._markDestroyed();
  }

  private indexComponent(c: Component): void {
    let list = this.byType.get(c.type);
    if (list === undefined) {
      list = [];
      this.byType.set(c.type, list);
      this.typeOrder.push(c.type);
    }
    list.push(c);
  }

  private unindexComponent(c: Component): void {
    const list = this.byType.get(c.type);
    if (list === undefined) return;
    const i = list.indexOf(c);
    if (i >= 0) list.splice(i, 1);
  }

  stats(): SceneStats {
    let comps = 0;
    for (const l of this.byType.values()) comps += l.length;
    return {
      nodes: this.byId.size,
      components: comps,
      pendingCommands: this.pending.length,
      stepsRun: this._steps,
      componentUpdates: this._updates,
    };
  }

  /** 清空（切场景/读档前）。不走命令 —— 它的语义就是"立刻什么都没了"。 */
  clear(): void {
    for (const child of [...this.root.children]) {
      this.detachNode(child, true);
    }
    this.pending = [];
  }

  /** 新建一个带标准变换的节点（便捷）。 */
  spawnAt(name: string, x: number, z: number, parent: NodeId | null = this.root.id): Result<Node, EngineError> {
    const r = this.spawn(name, parent);
    if (r.ok) r.value.setLocalPosition(x, z);
    return r;
  }

  /** 世界坐标（便利方法，供 2.5D 用）。 */
  worldPositionOf(id: NodeId): Vec2 | undefined {
    return this.byId.get(id)?.worldPosition;
  }
}
