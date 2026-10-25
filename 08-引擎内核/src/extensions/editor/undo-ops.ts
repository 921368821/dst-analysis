/**
 * L4 · 编辑器：可撤销操作（撤销栈的**消费者**）
 *
 * `undo-stack.ts` 只管历史怎么排；「一步操作怎么反向执行」在这里。
 *
 * ★ 三条决定，每条都有理由：
 *
 * ① **结构性操作按「子树快照」反向，不按「重算」反向**。
 *    删一个节点之后想把它变回来，唯一可靠的办法是**删之前**把它（连同子树）
 *    的完整记录拍下来。想靠 `nodeId` 去别处找回原值是不行的 —— 节点已经
 *    `_markDestroyed()`，组件也 `onDetach()` 过了。
 *    于是 `deleteNodeWithUndo` 把「先拍快照、再删」这个**顺序**封装起来：
 *    顺序写反了快照就是空的，而代码看起来仍然「在做事」。
 *
 * ② **反向操作一律走 `setField` / `scene` 的公开入口**，不直接改字段。
 *    撤销是「照历史重放一个值」，但那值来自可能被手改过的历史文本；
 *    走 `setField` 意味着它还要再过一遍类型校验 —— 历史坏了会报错，
 *    而不是把 `"abc"` 塞进 Int 字段然后让别处莫名其妙地崩。
 *
 * ③ **不做「相邻操作合并」**。属性面板用 `change` 事件提交，每次提交都是
 *    人有意的一次改动 ⇒ 本来就该一次退一步。真正需要合并的是画布拖拽
 *    （一帧一条），而拖拽还没做 —— 到那时正确的做法是**批量**
 *    （`beginBatch` / `commitBatch`，按下鼠标到松开算一个原子条目），
 *    而不是引入一层「按 mergeKey 猜哪两条是一伙的」。
 *
 * ★ 已知缺口（写在 `docs/PROGRESS.md`，这里留一行指针）：组件的挂载/卸载
 *   还没有反向实现；画布拖拽（gizmo）与多场景存读也还没接。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { Node, NodeId } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { recordOf, type NodeRecord } from "../../core/scene/scene-io.ts";
import { setField } from "./property-model.ts";
import { UNDO_OP_FAILED, type EditorOp } from "./undo-stack.ts";

/** 节点不存在（或不允许对该节点做这个操作，比如删根）。 */
export const EDIT_BAD_NODE = "EDIT.BAD_NODE";
/** 名字为空。 */
export const EDIT_BAD_NAME = "EDIT.BAD_NAME";
/** 换父的目标不合法（自己 / 自己的后代 / 与当前相同）。 */
export const EDIT_BAD_PARENT = "EDIT.BAD_PARENT";

// ---------------------------------------------------------------- 子树快照

/** 一棵子树的记录（id 升序，确定性）。 */
export interface SubtreeSnapshot {
  readonly rootId: NodeId;
  readonly name: string;
  /** 子树根的父节点（`null` = 挂在场景根下）。 */
  readonly parent: NodeId | null;
  readonly records: readonly NodeRecord[];
}

/**
 * 拍一棵子树的快照。`undefined` = 节点不存在。
 *
 * 用 `walk` 而不是「按父链递归」：`walk` 的顺序是**添加序**（确定），
 * 之后再按 id 排序，于是同一个子树任意两次快照逐字段相同 ——
 * 判据才能比对快照本身，而不只是「重建出来的节点数对」。
 */
export function snapshotSubtree(scene: Scene, rootId: NodeId): SubtreeSnapshot | undefined {
  const node = scene.find(rootId);
  if (node === undefined) return undefined;
  const records: NodeRecord[] = [];
  node.walk((n) => records.push(recordOf(scene, n)));
  records.sort((a, b) => a.id - b.id);
  return {
    rootId: node.id,
    name: node.name,
    parent: node.parent === null || node.parent.id === scene.rootId ? null : node.parent.id,
    records,
  };
}

export interface RestoreReport {
  /** 真的建回来的节点数。 */
  readonly made: number;
  /**
   * 没能完全按原样还原的地方（父节点不在了、组件类型未注册、字段缺失）。
   *
   * ★ 不许静默：撤销之后世界「差不多回来了」是最难查的状态 ——
   *   人会以为撤销坏了，而实际上是一条警告被吞了。
   */
  readonly warnings: readonly string[];
}

/**
 * 按记录重建。三遍：建节点 → 设父子 → 挂组件（与 `loadScene` 同构）。
 *
 * `fallbackParent` 用于「原来的父节点已经不在了」的情况：挂到它下面并记一条警告。
 */
export function restoreRecords(
  scene: Scene,
  records: readonly NodeRecord[],
  fallbackParent: NodeId | null,
): RestoreReport {
  const warnings: string[] = [];
  const built = new Map<NodeId, Node>();
  const sorted = [...records].sort((a, b) => a.id - b.id);

  // 第一遍：建节点（显式 id —— 撤销必须把 id 还回去，否则场景里所有引用都断了）
  for (const r of sorted) {
    if (scene.find(r.id) !== undefined) {
      warnings.push(`节点 #${r.id} 已经在场景里（跳过重建，沿用它）`);
      continue;
    }
    const n = scene.spawnImmediate(r.name, scene.rootId, r.id);
    // ★ 一律走 setter：直接赋 `localPosition` 不推进版本号，世界变换会用旧缓存
    n.setLocalPosition(r.x, r.y);
    n.setLocalRotation(r.rot);
    n.setLocalScale(r.sx, r.sy);
    n.zIndex = r.zIndex;
    n.active = r.active;
    n.layer = r.layer;
    n.markTransformDirty();
    built.set(r.id, n);
  }

  // 第二遍：父子
  for (const r of sorted) {
    const n = built.get(r.id);
    if (n === undefined) continue;
    if (r.parent === null) {
      const p = fallbackParent === null ? scene.root : scene.find(fallbackParent);
      (p ?? scene.root).addChild(n);
      continue;
    }
    const p = built.get(r.parent) ?? scene.find(r.parent);
    if (p === undefined) {
      warnings.push(`节点 #${r.id} 的原父节点 #${r.parent} 不在了（挂到根下）`);
      scene.root.addChild(n);
      continue;
    }
    p.addChild(n);
  }

  // 第三遍：组件
  for (const r of sorted) {
    const n = built.get(r.id) ?? scene.find(r.id);
    if (n === undefined) continue;
    for (const cr of r.components) {
      if (!scene.components.has(cr.type)) {
        warnings.push(`节点 #${r.id} 的组件 ${cr.type} 未注册（没还原）`);
        continue;
      }
      const c = scene.components.create(cr.type);
      if (c === undefined) {
        warnings.push(`节点 #${r.id} 的组件 ${cr.type} 工厂返回空（没还原）`);
        continue;
      }
      const res = c.load(cr.data);
      for (const f of res.missing) warnings.push(`#${r.id}.${cr.type}.${f} 缺失（用了默认值）`);
      scene.attach(n.id, () => c);
    }
  }
  scene.flush();
  return { made: built.size, warnings };
}

// ---------------------------------------------------------------- 字段

/** 改一个字段。`before`/`after` 都是**已经 coerce 过**的值（来自 `setField`）。 */
export class FieldOp implements EditorOp {
  readonly nodeId: NodeId;
  readonly type: string;
  readonly key: string;
  readonly before: unknown;
  readonly after: unknown;
  private readonly scene: Scene;

  constructor(scene: Scene, nodeId: NodeId, type: string, key: string, before: unknown, after: unknown) {
    this.scene = scene;
    this.nodeId = nodeId;
    this.type = type;
    this.key = key;
    this.before = before;
    this.after = after;
  }

  get label(): string {
    return `改 ${this.type}.${this.key}`;
  }

  apply(): Result<void, EngineError> {
    return this.write(this.after);
  }

  revert(): Result<void, EngineError> {
    return this.write(this.before);
  }

  private write(v: unknown): Result<void, EngineError> {
    const r = setField(this.scene, this.nodeId, this.type, this.key, v);
    if (!r.ok) {
      return err(engineError(UNDO_OP_FAILED, `写回 ${this.type}.${this.key} 失败：${r.error.message}`));
    }
    return ok(undefined);
  }
}

export function makeFieldOp(
  scene: Scene,
  nodeId: NodeId,
  type: string,
  key: string,
  before: unknown,
  after: unknown,
): EditorOp {
  return new FieldOp(scene, nodeId, type, key, before, after);
}

// ---------------------------------------------------------------- 结构性

/**
 * 子树操作：前向/反向就是「销毁它」与「按快照重建它」这两件事的组合。
 *
 * `restoreOnRevert` 决定哪一边是重建：
 * - 新建节点：撤销 = 销毁、重做 = 重建（`false`）
 * - 删除节点：撤销 = 重建、重做 = 销毁（`true`）
 */
class SubtreeOp implements EditorOp {
  readonly label: string;
  readonly report: (rep: RestoreReport) => void;
  private readonly scene: Scene;
  private readonly snap: SubtreeSnapshot;
  private readonly restoreOnRevert: boolean;

  constructor(
    scene: Scene,
    label: string,
    snap: SubtreeSnapshot,
    restoreOnRevert: boolean,
    report: (rep: RestoreReport) => void = () => undefined,
  ) {
    this.scene = scene;
    this.label = label;
    this.snap = snap;
    this.restoreOnRevert = restoreOnRevert;
    this.report = report;
  }

  apply(): Result<void, EngineError> {
    return this.restoreOnRevert ? this.destroy() : this.restore();
  }

  revert(): Result<void, EngineError> {
    return this.restoreOnRevert ? this.restore() : this.destroy();
  }

  private destroy(): Result<void, EngineError> {
    if (this.scene.find(this.snap.rootId) === undefined) {
      return err(
        engineError(UNDO_OP_FAILED, `节点 #${String(this.snap.rootId)}（${this.snap.name}）已经不在了`),
      );
    }
    this.scene.destroy(this.snap.rootId);
    this.scene.flush();
    return ok(undefined);
  }

  private restore(): Result<void, EngineError> {
    const rep = restoreRecords(this.scene, this.snap.records, this.snap.parent);
    this.report(rep);
    if (rep.made === 0) {
      return err(engineError(UNDO_OP_FAILED, `${this.snap.name} 一个节点都没建出来`));
    }
    return ok(undefined);
  }
}

/** 最近一次结构性还原的报告（宿主拿它提示「有东西没完全还原」）。 */
export interface StructOpBundle {
  readonly op: EditorOp;
  /** 这条操作针对的节点（宿主据此选中它 / 在树里定位它）。 */
  readonly nodeId: NodeId;
  /** 还原时产生的警告（撤销/重做之后才可能有内容）。 */
  readonly warnings: () => readonly string[];
}

/**
 * 从一组选中 id 里挑出**最上层**的那些（去掉「祖先也被选中」的子孙）。
 *
 * ★ 为什么必须挑：多选里同时有父与子时，删父已经把子一起删了，
 *   紧接着删子会失败 —— 而失败发生在批量中途，于是整批回滚，
 *   人看到的是「按了删除，什么都没发生，但报了个错」。这属于**看起来像 bug 的正确行为**。
 */
export function topmostIds(scene: Scene, ids: readonly NodeId[]): NodeId[] {
  const picked = new Set(ids);
  return ids.filter((id) => {
    let cur = scene.find(id)?.parent ?? null;
    while (cur !== null) {
      if (picked.has(cur.id)) return false;
      cur = cur.parent;
    }
    return true;
  });
}

/**
 * 新建一个空节点（并压进历史）。
 *
 * 名字为空白直接拒绝：树里出现一行空白行，人点不到它也认不出它，
 * 只会当成「树渲染坏了」。
 */
export function createNodeWithUndo(
  scene: Scene,
  name: string,
  parent: NodeId | null = null,
): Result<StructOpBundle, EngineError> {
  const trimmed = name.trim();
  if (trimmed === "") return err(engineError(EDIT_BAD_NAME, "节点名不能为空"));
  if (parent !== null && scene.find(parent) === undefined) {
    return err(engineError(EDIT_BAD_NODE, `父节点 #${String(parent)} 不在场景里`));
  }
  const p = parent ?? scene.rootId;
  const node = scene.spawnImmediate(trimmed, p);
  scene.flush();
  const snap = snapshotSubtree(scene, node.id);
  if (snap === undefined) return err(engineError(EDIT_BAD_NODE, "新建之后立刻找不到该节点"));
  let warnings: readonly string[] = [];
  const op = new SubtreeOp(scene, `新建 ${trimmed}`, snap, false, (rep) => {
    warnings = rep.warnings;
  });
  return ok({ op, nodeId: node.id, warnings: () => warnings });
}

/**
 * 删一个节点（连同子树），并返回可撤销的操作。
 *
 * ★ 这个函数存在的唯一理由是**顺序**：快照必须在 `destroy` **之前**拍。
 *   如果让调用方自己先删再压 op，快照就是空的 —— 而代码看起来仍然像在工作
 *   （撤销会「成功」但什么都没回来）。判据钉的是「撤销之后子树完整回来」。
 */
export function deleteNodeWithUndo(scene: Scene, nodeId: NodeId): Result<StructOpBundle, EngineError> {
  if (nodeId === scene.rootId) {
    return err(engineError(EDIT_BAD_NODE, "不能删除场景根节点"));
  }
  const node = scene.find(nodeId);
  if (node === undefined) return err(engineError(EDIT_BAD_NODE, `节点 #${String(nodeId)} 不在场景里`));
  const snap = snapshotSubtree(scene, nodeId);
  if (snap === undefined) return err(engineError(EDIT_BAD_NODE, `节点 #${String(nodeId)} 拍不到快照`));
  scene.destroy(nodeId);
  scene.flush();
  let warnings: readonly string[] = [];
  const op = new SubtreeOp(scene, `删除 ${node.name}`, snap, true, (rep) => {
    warnings = rep.warnings;
  });
  return ok({ op, nodeId, warnings: () => warnings });
}

/** 换父。合法性与「无变化」都在这里挡住，不让历史里出现空动作。 */
export function reparentWithUndo(
  scene: Scene,
  nodeId: NodeId,
  newParent: NodeId | null,
): Result<StructOpBundle, EngineError> {
  if (nodeId === scene.rootId) {
    return err(engineError(EDIT_BAD_NODE, "不能移动场景根节点"));
  }
  const node = scene.find(nodeId);
  if (node === undefined) return err(engineError(EDIT_BAD_NODE, `节点 #${String(nodeId)} 不在场景里`));
  const p = newParent ?? scene.rootId;
  if (scene.find(p) === undefined) {
    return err(engineError(EDIT_BAD_PARENT, `目标父节点 #${String(p)} 不在场景里`));
  }
  const from = node.parent === null || node.parent.id === scene.rootId ? null : node.parent.id;
  if ((from ?? scene.rootId) === p) {
    return err(engineError(EDIT_BAD_PARENT, `${node.name} 已经挂在 #${String(p)} 下面了`));
  }
  // ★ 环形检查：`Node.addChild` **没有**这个守卫，把节点挂进自己的后代里
  //   会造出一个环，之后 `walk` 直接栈溢出（而那时离出事的地方已经很远了）。
  //   核心层该补的地方记在 PROGRESS 里；这一层先挡住编辑器这条路径。
  let cur: Node | null = scene.find(p) ?? null;
  while (cur !== null) {
    if (cur.id === nodeId) {
      return err(engineError(EDIT_BAD_PARENT, `不能把 ${node.name} 挂到它自己或它的后代下面`));
    }
    cur = cur.parent;
  }

  scene.reparent(nodeId, newParent);
  scene.flush();
  return ok({
    op: new ReparentOp(scene, nodeId, node.name, from, newParent),
    nodeId,
    warnings: () => [],
  });
}

/** 换父。`from`/`to` 都按「`null` = 场景根」记录，与 `NodeRecord.parent` 同口径。 */
class ReparentOp implements EditorOp {
  private readonly scene: Scene;
  private readonly nodeId: NodeId;
  private readonly name: string;
  private readonly from: NodeId | null;
  private readonly to: NodeId | null;

  constructor(scene: Scene, nodeId: NodeId, name: string, from: NodeId | null, to: NodeId | null) {
    this.scene = scene;
    this.nodeId = nodeId;
    this.name = name;
    this.from = from;
    this.to = to;
  }

  get label(): string {
    return `移动 ${this.name}`;
  }

  apply(): Result<void, EngineError> {
    return this.move(this.to);
  }

  revert(): Result<void, EngineError> {
    return this.move(this.from);
  }

  private move(p: NodeId | null): Result<void, EngineError> {
    if (this.scene.find(this.nodeId) === undefined) {
      return err(engineError(UNDO_OP_FAILED, `节点 #${String(this.nodeId)}（${this.name}）不在了`));
    }
    // 目标父节点可能在这条历史与现在之间被删掉了 —— 报错而不是挂到根下：
    // 「悄悄挂到根下」会让树结构和人记忆里的完全不一样，而他只是按了一次撤销。
    if (p !== null && this.scene.find(p) === undefined) {
      return err(engineError(UNDO_OP_FAILED, `目标父节点 #${String(p)} 不在了，无法还原 ${this.name} 的位置`));
    }
    this.scene.reparent(this.nodeId, p);
    this.scene.flush();
    return ok(undefined);
  }
}
