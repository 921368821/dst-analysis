/**
 * L3 · 意图（Intent）：把「谁在决定」与「怎么执行」切开
 *
 * ★★ 为什么需要这一层（批147 的起点，实测得出的）
 *
 * 在此之前玩家与 AI 走两条并行路径，各自的单位都不一样：
 *   · 玩家：`directionFromMap(map, snap)` 产出 `{dx, dz}`（**方向**），
 *     位移由 `player-controller` 的 `stepOf` 算；
 *   · AI：`MobBrain.Decision.cell`（**目标格**），位移由 `ai/move.ts` 直接
 *     `node.setLocalPosition`。
 *
 * 两套单位、两个执行点。后果不是「代码不好看」，而是三件具体的事：
 *   ① 想让 AI 复用玩家那套（对角线归一化、卡墙处理）得复制一遍；
 *   ② 联机要发「这个实体想干什么」时，没有统一的形状可发；
 *   ③ 回放与 AI 训练要记录同样的东西，也得各记一套。
 *
 * 所以这一层的产物只有两样：**意图类型**与**意图 → 位移的纯函数**。
 *
 * ★★ 为什么是纯函数，不是一个「执行器模块」
 *
 * 建模块要引入新的生命周期（谁先 update、失败怎么报、跨模块拿什么引用），
 * 而这里要归一化的只是「一步位移怎么算」这一步。纯函数的好处是可枚举的：
 * 判据能直接打、变异能直接打、不参与调度顺序、不持有状态。
 *
 * ★ 三个刻意的约束：
 *
 * ① **意图只是数据**：不带执行逻辑、不带实体引用、可序列化。
 *    这三条决定了同一份意图能同时服务于联机（发网络）、回放（存盘）、
 *    AI 训练（采样）—— 带一个函数引用或一个 `Node` 就全废了。
 *
 * ② **只有两种移动意图**：方向型（键盘 / 摇杆）与目标型（点击 / 寻路）。
 *    第三种「瞬移」不属于意图（那是权限，走传送 API），不在这里开。
 *
 * ③ **非法输入一律降级成零位移，不抛**：意图来自玩家也可能来自 AI，
 *    一个 NaN 不该让整个世界这一 tick 停摆。判据钉的是「降级成零」而不是「随便怎样」。
 */

import { planeLen } from "../../foundation/math/scalar.ts";
import type { NavGrid } from "../nav/nav-grid.ts";
import { stepAlong } from "../nav/move-along.ts";

/**
 * 移动意图。
 *
 * `move.dir` 与 `move.cell` 的区别是**谁负责寻路**：
 * 前者调用方已经知道方向（键盘、摇杆、手柄），后者只知道想去哪（点击移动、AI 追击）。
 * 混成一种会强迫所有调用方都走寻路，每次按键都算一遍 A*。
 */
export type MoveIntent =
  | { readonly kind: "move.dir"; readonly dx: number; readonly dz: number }
  | { readonly kind: "move.cell"; readonly cell: number };

/**
 * 意图源：任何能「在某个 tick 决定这个实体想干什么」的东西。
 *
 * 四个已知实现：玩家（输入设备）、AI（行为树）、回放（时间轴）、脚本 Bot（脚本层）。
 * `null` 表示这一 tick 什么都不想做 —— 与「想做但做不到」是两件事，不要混。
 */
export interface IntentSource {
  produce(tick: number): MoveIntent | null;
}

/** 一步位移的结果。`done` 只对目标型有意义（走完路径），方向型恒为 false。 */
export interface StepResult {
  readonly dx: number;
  readonly dz: number;
  readonly done: boolean;
}

/** 零位移。抽成常量是为了让「降级」这条路径只有一处，判据能指名。 */
export const STEP_ZERO: StepResult = { dx: 0, dz: 0, done: false };

/** 有限数且为正。`NaN` / `Infinity` / `<= 0` 一律不算。 */
function positive(n: number): boolean {
  return Number.isFinite(n) && n > 0;
}

/**
 * 方向意图 → 一步位移。
 *
 * ★ **对角线归一化在这里**（不是在调用方）：漏掉它的症状是「斜着走 41% 快」，
 *   而所有位置判据都会通过 —— 只有「走同样时间、位移长度相同」那条能抓。
 *   这条规则原先写在 `player-controller.stepOf` 里；批147 搬到这里，
 *   于是 AI 想走方向也能拿到同一份归一化，不必复制。
 */
export function dirStep(intent: MoveIntent, speed: number, dt: number): StepResult {
  if (intent.kind !== "move.dir") return STEP_ZERO;
  if (!positive(speed) || !positive(dt)) return STEP_ZERO;
  const { dx, dz } = intent;
  if (!Number.isFinite(dx) || !Number.isFinite(dz)) return STEP_ZERO;
  const len = planeLen(dx, dz);
  // 零向量不是错误，是「这个 tick 没推摇杆」
  if (len === 0) return STEP_ZERO;
  return { dx: (dx / len) * speed * dt, dz: (dz / len) * speed * dt, done: false };
}

/** 目标型意图的上下文：寻路状态与当前位置由调用方给（这层不持有它们）。 */
export interface CellStepContext {
  readonly grid: NavGrid;
  /** 已算好的格子路径（由调用方用导航网格算，意图层不负责寻路）。 */
  readonly path: readonly number[];
  readonly cursor: number;
  readonly x: number;
  readonly z: number;
  readonly speed: number;
  readonly dt: number;
}

/** 目标型结果比方向型多一个游标：路径走完与否是状态，得回传给调用方。 */
export interface CellStepResult extends StepResult {
  readonly cursor: number;
}

/**
 * 目标型意图 → 一步位移。
 *
 * ★ 这里**不寻路**。路径由调用方（`ai/move.ts`）用导航网格算好再交进来，
 *   理由是寻路有缓存与失效（目标变了、路被堵了），那是调用方的状态；
 *   意图层只回答「沿这条路径这一步该挪多少」。把寻路也塞进来，
 *   这个纯函数就得持有缓存，立刻变成有状态的东西。
 *
 * ★ 空路径返回「已走完」，不是零位移：`done: true` 让调用方清状态，
 *   否则它会每 tick 拿着一条空路径反复问一次。
 */
export function cellStep(intent: MoveIntent, ctx: CellStepContext): CellStepResult {
  if (intent.kind !== "move.cell") return { ...STEP_ZERO, cursor: ctx.cursor };
  if (!positive(ctx.speed) || !positive(ctx.dt)) return { ...STEP_ZERO, cursor: ctx.cursor };
  if (ctx.path.length === 0) return { dx: 0, dz: 0, done: true, cursor: ctx.cursor };
  // `intent.cell` 在这一步只作可读性用途：路径已经由调用方按它算好了。
  // ★ 保留这个字段而不是删掉：联机要发的是「想去哪」，路径是本机算的缓存。
  void intent.cell;
  const w = stepAlong(ctx.grid, ctx.path, ctx.cursor, ctx.x, ctx.z, ctx.speed, ctx.dt);
  return { dx: w.x - ctx.x, dz: w.z - ctx.z, done: w.done, cursor: w.cursor };
}
