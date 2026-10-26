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
 *    （一帧一条），而拖拽在批84 接上时发现**连批量都不需要**：过程只改位置、
 *    松手才产出一条 op（见 `gizmo.ts` 的 `endDrag`），天然就是一个原子条目。
 *
 * ★ 已知缺口（写在 `docs/PROGRESS.md`，这里留一行指针）：画布拖拽（gizmo）批84 已接；
 *   组件挂载/卸载的历史在批83 补上（本文件末尾那一节）；换父在批85 接了场景树拖放。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { Component, ComponentRegistry } from "../../core/scene/component.ts";
import type { Node, NodeId } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { recordOf, type NodeRecord } from "../../core/scene/scene-io.ts";
import { Sprite, SPRITE_TYPE } from "../render/sprite.ts";
import { worldToLocal } from "./gizmo.ts";
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

/**
 * 换父。合法性与「无变化」都在这里挡住，不让历史里出现空动作。
 *
 * ★★ **换父要保住世界位置**（批85）。`scene.reparent` 只改父子关系，
 *   `localPosition` 原样不动 —— 那意味着父一换，节点在画面上的位置就跳了：
 *   拖到别的节点下面本来只是"改层级"，结果它飞走了。编辑器的通行做法是
 *   「保留世界位置，重算局部位置」，这也与批84 的画布拖拽同一套换算。
 *
 * ★ 换算**先算再改结构**，不是改完再补救：
 *   一旦新父把某一轴压成 0 缩放，`worldToLocal` 无解，这时场景还一个字节没动，
 *   直接报错就是干净的。反过来（先 `reparent` 再算）会留下"父改了、位置没跟上"的半截状态，
 *   而它事后只能靠 undo 一条内部命令来收拾 —— 那是最难查的一类。
 *
 * ★ 只保**位置**，不保朝向与尺寸：2.5D 场景里节点有 `localRotation`/`localScale`，
 *   要完整保持世界变换就得做极分解，代价远大于收益。这条限制被写成判据
 *   （"父带旋转时位置保持、朝向被新父带偏"），而不是藏在注释里 ——
 *   否则下一个人会以为它保住了整个世界变换。
 */
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
  const target = scene.find(p);
  if (target === undefined) {
    return err(engineError(EDIT_BAD_PARENT, `目标父节点 #${String(p)} 不在场景里`));
  }
  const from = node.parent === null || node.parent.id === scene.rootId ? null : node.parent.id;
  if ((from ?? scene.rootId) === p) {
    return err(engineError(EDIT_BAD_PARENT, `${node.name} 已经挂在 #${String(p)} 下面了`));
  }
  // ★ 环形检查分两层，职责不同：
  //   核心层 `Node.addChild` 现在会**抛**（批81 补的）—— 那是最后一道防线，
  //   因为它是编程错误、抛出来只会崩掉调用方；
  //   编辑器这一层要在**崩之前**把它变成一条可以显示给人看的错误码，
  //   所以仍然自己查一次。判断复用 `Node.isAncestorOf`，免得两份上溯逻辑在
  //   「根节点算不算祖先」这种边界上漂开。
  if (target.id === nodeId || node.isAncestorOf(target)) {
    return err(engineError(EDIT_BAD_PARENT, `不能把 ${node.name} 挂到它自己或它的后代下面`));
  }

  // 世界位置在**改结构之前**取：改完再取就已经是"跳过去之后"的位置了。
  const world = node.worldPosition;
  const local = worldToLocal(target.worldTransform, world.x, world.y);
  if (local === undefined) {
    return err(
      engineError(
        EDIT_BAD_PARENT,
        `目标父节点 #${String(p)} 把坐标轴压成了 0，换父之后无法保持 ${node.name} 的世界位置`,
      ),
    );
  }
  const fromLocal = { x: node.localPosition.x, y: node.localPosition.y };
  const toLocal = { x: local.u, y: local.v };

  scene.reparent(nodeId, newParent);
  scene.flush();
  // ★ 用 `setLocalPosition`：直接赋 `localPosition` 不推进版本号，世界变换会继续用旧缓存 ——
  //   症状是"父换了、世界位置还是老的值"，而这正好是本函数要保证的那件事。
  const moved = scene.find(nodeId);
  if (moved === undefined) {
    return err(engineError(EDIT_BAD_NODE, `换父途中节点 #${String(nodeId)} 不见了`));
  }
  moved.setLocalPosition(toLocal.x, toLocal.y);
  return ok({
    op: new ReparentOp(scene, nodeId, node.name, from, newParent, fromLocal, toLocal),
    nodeId,
    warnings: () => [],
  });
}

/**
 * 换父。`from`/`to` 都按「`null` = 场景根」记录，与 `NodeRecord.parent` 同口径。
 *
 * ★ 位置也要记：换父会**重算** `localPosition`（为了保住世界位置），
 *   所以只记父子关系的话，撤销回来的是"原父 + 为新父算出来的局部坐标" ——
 *   层级对了、位置错了，而且错得很像"当初就是这样"。这与批83 组件那条
 *   「重做拿回同一个实例」是同一类：**状态要么一起回，要么别回**。
 */
class ReparentOp implements EditorOp {
  private readonly scene: Scene;
  private readonly nodeId: NodeId;
  private readonly name: string;
  private readonly from: NodeId | null;
  private readonly to: NodeId | null;
  private readonly fromLocal: { readonly x: number; readonly y: number };
  private readonly toLocal: { readonly x: number; readonly y: number };

  constructor(
    scene: Scene,
    nodeId: NodeId,
    name: string,
    from: NodeId | null,
    to: NodeId | null,
    fromLocal: { readonly x: number; readonly y: number },
    toLocal: { readonly x: number; readonly y: number },
  ) {
    this.scene = scene;
    this.nodeId = nodeId;
    this.name = name;
    this.from = from;
    this.to = to;
    this.fromLocal = fromLocal;
    this.toLocal = toLocal;
  }

  get label(): string {
    return `移动 ${this.name}`;
  }

  apply(): Result<void, EngineError> {
    return this.move(this.to, this.toLocal);
  }

  revert(): Result<void, EngineError> {
    return this.move(this.from, this.fromLocal);
  }

  private move(p: NodeId | null, local: { readonly x: number; readonly y: number }): Result<void, EngineError> {
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
    const node = this.scene.find(this.nodeId);
    if (node === undefined) {
      return err(engineError(UNDO_OP_FAILED, `节点 #${String(this.nodeId)}（${this.name}）不在了`));
    }
    // 父换回去之后局部坐标也要换回去 —— 见类注释最后一段。
    node.setLocalPosition(local.x, local.y);
    return ok(undefined);
  }
}

// ---------------------------------------------------------------- 组件挂载 / 卸载

/** 组件类型未注册 / 工厂返回 undefined / 同类型已挂着一个 / 那个类型本来就没挂。 */
export const EDIT_BAD_COMP = "EDIT.BAD_COMP";

/**
 * 组件挂/卸的共享实现（**实例由 op 持有**）。
 *
 * ★★ 这一节只有一条真正容易写错的事：**重做必须拿回同一个实例**。
 *   如果重做时 `registry.create(type)` 新建一个，组件的状态（血量、计时器、
 *   指向别的实体的引用）全部回到出厂值 —— 而 UI 上「组件回来了」、字段也都在，
 *   所以从界面完全看不出问题。所以 op 持着实例，
 *   `scene.attach(nodeId, () => this.comp)` 把**这一个**挂回去。
 *
 * ★ 连带的一条组件约定：`onAttach` 会**跑第二次**（卸下再挂回）。
 *   所以它只能做「接入」，不能当「初始化」用 —— 在 `onAttach` 里写
 *   `this.hp = this.maxHp` 的组件，撤销一次卸载就把血量治好了。
 *   这不归撤销层管（它不该替组件决定哪些字段算状态），但必须写在这里，
 *   否则下一个人会以为是撤销"没保住状态"。
 */
class ComponentOp implements EditorOp {
  private readonly scene: Scene;
  private readonly nodeId: NodeId;
  private readonly comp: Component;
  /** `true` = 这条历史是「挂上」（apply 挂、revert 卸）；`false` 反过来。 */
  private readonly attachFirst: boolean;

  constructor(scene: Scene, nodeId: NodeId, comp: Component, attachFirst: boolean) {
    this.scene = scene;
    this.nodeId = nodeId;
    this.comp = comp;
    this.attachFirst = attachFirst;
  }

  get label(): string {
    return `${this.attachFirst ? "挂上" : "卸下"} ${this.comp.type}`;
  }

  apply(): Result<void, EngineError> {
    return this.attachFirst ? this.doAttach() : this.doDetach();
  }

  revert(): Result<void, EngineError> {
    return this.attachFirst ? this.doDetach() : this.doAttach();
  }

  private doAttach(): Result<void, EngineError> {
    const node = this.scene.find(this.nodeId);
    if (node === undefined) {
      return err(
        engineError(EDIT_BAD_NODE, `节点 #${String(this.nodeId)} 已经不在了，${this.comp.type} 挂不回去`),
      );
    }
    const existing = node.get(this.comp.type);
    // 幂等：已经就是这个实例，什么都不用做。**是别的实例**则拒绝 ——
    // 覆盖掉它等于悄悄销毁了一个不属于这条历史的组件。
    if (existing === this.comp) return ok(undefined);
    if (existing !== undefined) {
      return err(
        engineError(
          EDIT_BAD_COMP,
          `节点 #${String(this.nodeId)} 上已经有一个 ${this.comp.type} 了（同类型只允许一个）`,
        ),
      );
    }
    // ★ 传工厂而不是实例：这是内核留的口子，让「重新挂同一个实例」成为可能。
    this.scene.attach(this.nodeId, () => this.comp);
    this.scene.flush();
    // ★ 命令是排队执行的，失败也不抛 —— 唯一可靠的判法是回头看一眼。
    if (this.scene.find(this.nodeId)?.get(this.comp.type) !== this.comp) {
      return err(engineError(UNDO_OP_FAILED, `把 ${this.comp.type} 挂回去没有生效`));
    }
    return ok(undefined);
  }

  private doDetach(): Result<void, EngineError> {
    const node = this.scene.find(this.nodeId);
    if (node === undefined) {
      return err(engineError(EDIT_BAD_NODE, `节点 #${String(this.nodeId)} 已经不在了，没有 ${this.comp.type} 可卸`));
    }
    const current = node.get(this.comp.type);
    // ★ 节点上那个同类型的组件**不是**这条历史记的那一个 ⇒ 历史已失效。
    //   此时按类型去摘会摘掉别人（`scene.detach` 就是按类型找的），
    //   症状是「撤销一个卸载，结果卸掉了另一个组件」。
    if (current !== this.comp) {
      return err(
        engineError(EDIT_BAD_COMP, `节点 #${String(this.nodeId)} 上的 ${this.comp.type} 不是这条历史里的那一个`),
      );
    }
    this.scene.detach(this.nodeId, this.comp.type);
    this.scene.flush();
    if (this.scene.find(this.nodeId)?.get(this.comp.type) !== undefined) {
      return err(engineError(UNDO_OP_FAILED, `把 ${this.comp.type} 卸下来没有生效`));
    }
    return ok(undefined);
  }
}

/**
 * 给节点挂一个组件（并压进历史）。
 *
 * 为什么先查 `register / create` 再动场景：`scene.attach` 是排队命令，
 * 命令在 `flush()` 时执行，而那里**不返回错误**。类型没注册时它只会
 * 「什么都没发生」—— 人看到的是一行什么都没多出来的面板。
 */
export function attachComponentWithUndo(
  scene: Scene,
  registry: ComponentRegistry,
  nodeId: NodeId,
  type: string,
): Result<StructOpBundle, EngineError> {
  const node = scene.find(nodeId);
  if (node === undefined) return err(engineError(EDIT_BAD_NODE, `节点 #${String(nodeId)} 不在场景里`));
  const already = node.get(type);
  if (already !== undefined) {
    return err(engineError(EDIT_BAD_COMP, `节点 #${String(nodeId)} 上已经有一个 ${type} 了`));
  }
  // ★ 这里**不**单独查 `registry.has(type)`：`create` 对未注册类型返回 `undefined`，
  //   两种原因的可观察结果完全一样，多一个分支就多一处会漂的措辞。
  //   （批83 先写了那行，M374 跑出来是**假绿** —— 删掉它才是对的修法。）
  const comp = registry.create(type);
  if (comp === undefined) return err(engineError(EDIT_BAD_COMP, `组件类型 ${type} 没有注册`));
  scene.attach(nodeId, () => comp);
  scene.flush();
  if (node.get(type) !== comp) {
    return err(engineError(UNDO_OP_FAILED, `挂上 ${type} 没有生效（节点可能刚被销毁）`));
  }
  return ok({ op: new ComponentOp(scene, nodeId, comp, true), nodeId, warnings: () => [] });
}

/**
 * 从节点上卸一个组件（并压进历史）。
 *
 * ★ 卸载**不销毁实例**：op 持有它，撤销就是把它原样挂回去。
 *   这正是「撤销卸载之后血量还是刚才那么多」唯一可能的实现方式。
 */
export function detachComponentWithUndo(
  scene: Scene,
  nodeId: NodeId,
  type: string,
): Result<StructOpBundle, EngineError> {
  const node = scene.find(nodeId);
  if (node === undefined) return err(engineError(EDIT_BAD_NODE, `节点 #${String(nodeId)} 不在场景里`));
  const comp = node.get(type);
  if (comp === undefined) {
    return err(engineError(EDIT_BAD_COMP, `节点 #${String(nodeId)} 上没有 ${type}`));
  }
  scene.detach(nodeId, type);
  scene.flush();
  if (node.get(type) !== undefined) {
    return err(engineError(UNDO_OP_FAILED, `卸下 ${type} 没有生效`));
  }
  return ok({ op: new ComponentOp(scene, nodeId, comp, false), nodeId, warnings: () => [] });
}

// ---------------------------------------------------------------- 资产 → 节点（批86）

/** 资产在图集里没有对应帧 —— 「点了没反应」的那一类，必须变成一条看得见的错误。 */
export const EDIT_NO_FRAME = "EDIT.NO_FRAME";

export interface SpriteNodeSpec {
  /** 节点名（通常就是资产名）。 */
  readonly name: string;
  /** 图集里的帧名。 */
  readonly frame: string;
  /** 父节点，`null` = 场景根。 */
  readonly parent?: NodeId | null;
  /** 落在哪个局部坐标上。省略 = 原点。 */
  readonly position?: { readonly x: number; readonly y: number };
  /**
   * 当前图集里有没有这一帧。**必填**。
   *
   * ★ 不给默认值（比如「默认认为有」）：那样"图集没接上"就会静默造出一个
   *   永远画不出来的节点 —— 世界树里看得见、画布上什么都没有，
   *   而渲染模块只会 warn 一次（还可能被日志级别吞掉）。
   */
  readonly hasFrame: (frame: string) => boolean;
}

/**
 * 从一个资产建一个带精灵的节点，**一条**历史。
 *
 * ★ 为什么不是「先 `createNodeWithUndo` 再 `attachComponentWithUndo`」：
 *   那样是**两条**历史，撤销一次只退掉组件、留下一个空节点 ——
 *   而人看到的操作是「加了一个图标」，他按一次撤销时期望的是它整个消失。
 *   所以这里自己拍快照：建节点 → 挂精灵 → 设帧 → **然后**拍子树快照，
 *   一条 `SubtreeOp` 管两头（撤销删树、重做连帧一起回来）。
 *
 * ★ 顺序不能反：快照必须在挂完组件之后拍，否则重做回来的是一个没精灵的空节点
 *   （画面症状与"资产没加载"完全一样）。
 */
export function addSpriteNodeWithUndo(
  scene: Scene,
  registry: ComponentRegistry,
  spec: SpriteNodeSpec,
): Result<StructOpBundle, EngineError> {
  const trimmed = spec.name.trim();
  if (trimmed === "") return err(engineError(EDIT_BAD_NAME, "节点名不能为空"));
  const frame = spec.frame.trim();
  if (frame === "") {
    return err(engineError(EDIT_NO_FRAME, `${trimmed} 没有帧名（资产路径解析不出名字）`));
  }
  if (!spec.hasFrame(frame)) {
    return err(
      engineError(
        EDIT_NO_FRAME,
        `图集里没有帧 "${frame}" —— ${trimmed} 加进去也画不出来（编辑器还没接图片导入，见 docs/PROGRESS.md §五）`,
      ),
    );
  }
  const parent = spec.parent ?? null;
  if (parent !== null && scene.find(parent) === undefined) {
    return err(engineError(EDIT_BAD_NODE, `父节点 #${String(parent)} 不在场景里`));
  }

  const node = scene.spawnImmediate(trimmed, parent ?? scene.rootId);
  if (spec.position !== undefined) node.setLocalPosition(spec.position.x, spec.position.y);
  const comp: Component | undefined = registry.create(SPRITE_TYPE);
  if (comp === undefined) {
    scene.destroy(node.id);
    scene.flush();
    return err(engineError(EDIT_BAD_COMP, `组件类型 ${SPRITE_TYPE} 没有注册`));
  }
  (comp as Sprite).frame = frame;
  scene.attach(node.id, () => comp);
  scene.flush();
  const sprite = node.get<Sprite>(SPRITE_TYPE);
  if (sprite === undefined || sprite.frame !== frame) {
    scene.destroy(node.id);
    scene.flush();
    return err(engineError(UNDO_OP_FAILED, `挂上 ${SPRITE_TYPE} 没有生效`));
  }

  const snap = snapshotSubtree(scene, node.id);
  if (snap === undefined) {
    scene.destroy(node.id);
    scene.flush();
    return err(engineError(EDIT_BAD_NODE, "新建之后立刻找不到该节点"));
  }
  let warnings: readonly string[] = [];
  const op = new SubtreeOp(scene, `加入 ${trimmed}`, snap, false, (rep) => {
    warnings = rep.warnings;
  });
  return ok({ op, nodeId: node.id, warnings: () => warnings });
}
