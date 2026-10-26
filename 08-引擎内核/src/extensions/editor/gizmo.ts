/**
 * L4 · 编辑器：画布拖拽（gizmo）
 *
 * 三件事：**点谁**（命中测试）、**跟着谁走**（拖拽增量）、**怎么撤销**（位置 op）。
 *
 * ★ 三件里最容易写错的是第二件，因为它要做一次**世界 → 局部**的换算，
 *   而编辑里 99% 的节点挂在根下（父是 identity），于是写错也看不出来：
 *
 *     世界点 → 局部点：  local = P⁻¹ · world      （P = 父节点的世界变换）
 *
 *   漏掉 P⁻¹ 的症状是「拖一个子节点，它跳到别处，偏移量正好是父节点的世界位置」。
 *   所以在所有父都躺在原点的场景里，这个 bug 永远不会出现 —— 判据必须
 *   **特意造一个父节点带偏移、再带旋转**的夹具。
 *
 * ★ 为什么不用 `matrix.inverse()`：核心层的 `Affine2` 只提供正变换。
 *   这里用**基向量解方程**代替求逆（不新增核心 API，也不受"父被压成 0 缩放"时的除零影响）：
 *
 *     P 的两列就是「局部 u 轴 / v 轴在世界里的方向」，解 2×2 线性方程即可。
 *
 * ★ 为什么拖拽结束时才产生一条 op：拖拽过程中每一帧都是新位置，逐帧压历史的话
 *   按一次撤销只退回**一个像素**。这与 `undo-ops.ts` 里「不做相邻操作合并、
 *   但拖拽该用批量」的判断一致 —— 但这里连批量都不需要：**整个过程只在结束时产出一条**，
 *   天然就是一个原子条目。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { NodeId } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { UNDO_OP_FAILED, type EditorOp } from "./undo-stack.ts";

/** 拖拽目标不成立（节点不存在、父把坐标轴压成 0、拖的不是自己的节点）。 */
export const EDIT_BAD_DRAG = "EDIT.BAD_DRAG";

/** 命中半径（世界单位）。默认半格多一点：太小点不中，太大会选到旁边的箱子。 */
export const DEFAULT_PICK_RADIUS = 0.55;

export interface PickOptions {
  readonly radius?: number;
}

/**
 * 世界点 → **最上层**的节点。
 *
 * 排序三级，每一级都有理由：`zIndex` 降序（画面上压着别人的那个才是人看见的那个）→
 * 到光标的距离升序（同一层里选离得近的）→ id 升序（**确定性**：重叠时不能靠遍历顺序碰运气，
 * 那会让"双击同一个位置两次选中不同节点"）。
 */
export function pickAt(scene: Scene, wx: number, wz: number, opts: PickOptions = {}): NodeId | undefined {
  const r = opts.radius ?? DEFAULT_PICK_RADIUS;
  const r2 = r * r;
  type Hit = { id: NodeId; z: number; d2: number };
  const hits: Hit[] = [];
  scene.root.walk((n) => {
    // 根节点不是可拖的东西（它是"场景本身"）；隐藏的也不该被点中。
    if (n.id === scene.rootId || !n.active) return;
    const p = n.worldPosition;
    const dx = p.x - wx;
    const dy = p.y - wz;
    const d2 = dx * dx + dy * dy;
    if (d2 <= r2) hits.push({ id: n.id, z: n.zIndex, d2 });
  });
  if (hits.length === 0) return undefined;
  hits.sort((a, b) => (b.z !== a.z ? b.z - a.z : a.d2 !== b.d2 ? a.d2 - b.d2 : a.id - b.id));
  return hits[0]?.id;
}

/**
 * 一次拖拽的固定信息：按下时算一次，过程里**不再变**。
 *
 * 存的是父变换的六个分量而不是"父节点引用"：拖拽期间父被删掉时，
 * 手里这份数仍然能把世界位移换算成局部位移（不会因为中途抛异常把画面卡住）。
 * `det` 是线性部分的行列式 —— 0 表示父把某一轴压成了 0，换算无解。
 */
export interface DragState {
  readonly nodeId: NodeId;
  /** 按下点相对节点局部的偏移。抓哪拖哪：拖住箱子角，箱子就不该中心对齐光标。 */
  readonly grabU: number;
  readonly grabV: number;
  readonly fromX: number;
  readonly fromY: number;
  readonly m00: number;
  readonly m01: number;
  readonly m02: number;
  readonly m10: number;
  readonly m11: number;
  readonly m12: number;
  readonly det: number;
}

/** 父节点的世界变换（根的话是恒等）。 */
function parentTransformOf(scene: Scene, nodeId: NodeId):
  | { m00: number; m01: number; m02: number; m10: number; m11: number; m12: number }
  | undefined {
  const n = scene.find(nodeId);
  if (n === undefined) return undefined;
  const p = n.parent;
  if (p === null) return { m00: 1, m01: 0, m02: 0, m10: 0, m11: 1, m12: 0 };
  const t = p.worldTransform;
  return { m00: t.m00, m01: t.m01, m02: t.m02, m10: t.m10, m11: t.m11, m12: t.m12 };
}

/** 世界点 → 局部点（基向量解 2×2 方程）。`det === 0` 时返回 `undefined`。 */
export function worldToLocal(
  basis: { m00: number; m01: number; m02: number; m10: number; m11: number; m12: number },
  wx: number,
  wz: number,
): { u: number; v: number } | undefined {
  const det = basis.m00 * basis.m11 - basis.m01 * basis.m10;
  // ★ 用相对量而非 0：det 的量级取决于父的缩放。1e-12 是"明显退化"的界线，
  //   而不是"很小但合法"—— 父被压成 0.001 倍仍然可换算，压成 0 才无解。
  if (!Number.isFinite(det) || Math.abs(det) < 1e-12) return undefined;
  const dx = wx - basis.m02;
  const dy = wz - basis.m12;
  return {
    u: (basis.m11 * dx - basis.m01 * dy) / det,
    v: (-basis.m10 * dx + basis.m00 * dy) / det,
  };
}

/** 开始拖拽。`wx/wz` 是按下点的世界坐标。 */
export function beginDrag(scene: Scene, nodeId: NodeId, wx: number, wz: number): Result<DragState, EngineError> {
  if (nodeId === scene.rootId) return err(engineError(EDIT_BAD_DRAG, "不能拖动场景根节点"));
  const n = scene.find(nodeId);
  if (n === undefined) return err(engineError(EDIT_BAD_DRAG, `节点 #${String(nodeId)} 不在场景里`));
  const basis = parentTransformOf(scene, nodeId);
  if (basis === undefined) return err(engineError(EDIT_BAD_DRAG, `节点 #${String(nodeId)} 的父变换取不到`));
  const det = basis.m00 * basis.m11 - basis.m01 * basis.m10;
  const local = worldToLocal(basis, wx, wz);
  if (local === undefined) {
    return err(
      engineError(EDIT_BAD_DRAG, `节点 #${String(nodeId)} 的父节点把坐标轴压成了 0（det=${String(det)}），没法换算`),
    );
  }
  return ok({
    nodeId,
    grabU: local.u - n.localPosition.x,
    grabV: local.v - n.localPosition.y,
    fromX: n.localPosition.x,
    fromY: n.localPosition.y,
    ...basis,
    det,
  });
}

/** 拖动到世界点 → 新的**局部**位置（`snap > 0` 时吸附到格）。 */
export function dragTarget(state: DragState, wx: number, wz: number, snap = 0): { x: number; y: number } {
  const local = worldToLocal(state, wx, wz);
  // 表达式里 det 已经被 `beginDrag` 验过非 0，这里不会走到 undefined；
  // 兜底成"不动"而不是 NaN —— NaN 会一路渗进存档和渲染，是最难查的一类。
  if (local === undefined) return { x: state.fromX, y: state.fromY };
  let x = local.u - state.grabU;
  let y = local.v - state.grabV;
  if (snap > 0) {
    x = Math.round(x / snap) * snap;
    y = Math.round(y / snap) * snap;
  }
  return { x, y };
}

/** 位置变了就产出一条可撤销 op；没变就 `undefined`（不留"什么都没发生"的历史条目）。 */
export function endDrag(
  scene: Scene,
  state: DragState,
  x: number,
  y: number,
): Result<EditorOp | undefined, EngineError> {
  const n = scene.find(state.nodeId);
  if (n === undefined) {
    return err(engineError(EDIT_BAD_DRAG, `拖拽过程中节点 #${String(state.nodeId)} 被删掉了`));
  }
  if (x === state.fromX && y === state.fromY) return ok(undefined);
  const label = `移动 ${n.name}`;
  return ok(new MoveOp(scene, state.nodeId, label, state.fromX, state.fromY, x, y));
}

/**
 * 位置 op。
 *
 * ★ 走 `setLocalPosition`（它会 `markTransformDirty`），不直接赋 `localPosition` ——
 *   后者不推进版本号，世界变换会继续用旧缓存：症状是「撤销了，逻辑坐标回去了，
 *   但画面上还在新位置」，而且下一次别的操作触发重算时才突然跳回去。
 *   （`scene-io` 读档那一段为同一个理由写了同样的注释。）
 */
class MoveOp implements EditorOp {
  private readonly scene: Scene;
  private readonly nodeId: NodeId;
  private readonly fromX: number;
  private readonly fromY: number;
  private readonly toX: number;
  private readonly toY: number;
  private readonly name: string;

  constructor(
    scene: Scene,
    nodeId: NodeId,
    label: string,
    fromX: number,
    fromY: number,
    toX: number,
    toY: number,
  ) {
    this.scene = scene;
    this.nodeId = nodeId;
    this.name = label;
    this.fromX = fromX;
    this.fromY = fromY;
    this.toX = toX;
    this.toY = toY;
  }

  get label(): string {
    return this.name;
  }

  apply(): Result<void, EngineError> {
    return this.move(this.toX, this.toY);
  }

  revert(): Result<void, EngineError> {
    return this.move(this.fromX, this.fromY);
  }

  private move(x: number, y: number): Result<void, EngineError> {
    const n = this.scene.find(this.nodeId);
    if (n === undefined) {
      return err(engineError(UNDO_OP_FAILED, `节点 #${String(this.nodeId)} 不在了，位置改不回去`));
    }
    n.setLocalPosition(x, y);
    return ok(undefined);
  }
}
