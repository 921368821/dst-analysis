/**
 * L4 · 关卡流程：过场幕布（落幕 → 换世界 → 起幕）
 *
 * 跳场景原本是**硬切**：一 tick 之内整份世界被换掉，玩家看到的只是"画面突然变了个样"。
 * 真实游戏里的换关几乎总是黑的过渡一下，原因不只是好看 —— 它给了玩家
 * **"我离开了刚才那里"** 这个信息。硬切会让两片相似的地图看起来像同一个人瞬移了。
 *
 * ★★ 这一层的实质内容只有一条不变量，其余全是为它服务的：
 *
 *   **世界换掉的那一刻，幕布必须是落满的；幕布落满之前，世界一个字节都不许动。**
 *
 *   所以 `advance()` 在"落幕走完"的那一拍**同时**做两件事：把阶段切成 `in`
 *   （幕布从满开始往上起），并把 `fire` 交出去让调用方去换世界。调用方换完之后
 *   渲染一帧时 `curtainAlpha` 已经是 1 —— 换世界那一帧被幕布整个盖住。
 *
 * ★ 于是**失败不需要单独的分支**：换世界失败（门锁了、目标场景坏了）时，
 *   世界没动，而状态机**已经**在 `in` 里了 —— 幕布自己淡回来，玩家看到的是
 *   一次没有内容的黑闪。这比"失败要记得把幕布撤掉"便宜得多，也少一条
 *   走不到的分支（本项目的老账：**没有执行机会的分支，是静默丢东西最舒服的住处**）。
 *
 * ★ 为什么按 **tick** 不按帧：幕布是"多长"的问题，而帧率是宿主的实现细节。
 *   按帧数消耗的话，60Hz 上是 0.5 秒、144Hz 上是 0.2 秒 —— 同一份工程在两台机器上
 *   观感不同，而两边的代码一个字都没差（M304 的教训）。时长一律写 tick，由调度器
 *   按 `fixedDt` 换成真实时间。
 *
 * ★ 为什么落幕 12 tick、起幕 18 tick 而不对称：遮得快、露得慢是剪辑的惯例 ——
 *   遮的时候玩家已经决定要走了，快一点不难受；露的时候他在认新地方，太急会"看不清"。
 *   两个数都是**逻辑步**，各自的理由都在这里，别在别处再写死一个。
 *
 * ★ 这一层不碰场景、不碰 DOM：只认"过了几拍"。所以它能在 Node 里逐拍钉住，
 *   而"幕布真的盖住了画面"那件事交给渲染层（`render-module.ts` 的全屏幕布）。
 */

import type { PortalSpec } from "./portal.ts";

/**
 * 幕布在动的时候又有人要跳。
 *
 * ★ 单独一个码而不是静默忽略：出这个码说明**两次触发挨得太近**
 *   （0.2 秒内走进了两扇门，或者落地那扇门没被 `reseed` 记住）。
 *   静默忽略的表现是"走进门没反应"，玩家会以为门坏了。
 */
export const FLOW_BUSY = "FLOW.BUSY";

/** 落幕用几拍（逻辑步）。 */
export const CURTAIN_OUT_TICKS = 12;
/** 起幕用几拍。比落幕长，理由见文件头。 */
export const CURTAIN_IN_TICKS = 18;

/** 幕布落下之后要做的事：跳到哪一份场景、从哪扇门过来（`null` = 调试手势）。 */
export interface CurtainTarget {
  readonly scene: string;
  readonly via: PortalSpec | null;
}

export type CurtainPhase = "idle" | "out" | "in";

/**
 * 幕布的状态。**纯值**：每一次推进都返回一个新对象，不就地改。
 *
 * ★ 为什么不可变：判据要能"逐拍存一份快照再回头比"。可变状态在测试里只能看到
 *   最终值，而"它在第 13 拍还是满的、第 14 拍开始掉"这种形状是这一层的全部意义。
 */
export interface CurtainState {
  readonly phase: CurtainPhase;
  /** 本阶段已经过了几拍（`idle` 恒 0）。 */
  readonly elapsed: number;
  /** 落幕后要执行的那一跳（只有 `out` 阶段有）。 */
  readonly target: CurtainTarget | null;
  /** 真的把跳转交出去过几次。正常情况下**永远 ≤ 1**，多了就是有人重复 fire。 */
  readonly fired: number;
  /** 被取消过几次（停播 / 面板硬跳）。 */
  readonly cancelled: number;
  /** 因为"幕布正在动"被拒过几次。**不静默**：这个数在涨就是关卡设计有问题。 */
  readonly refused: number;
}

/** 一切从这儿开始：没有幕布、没有待办。 */
export const CURTAIN_IDLE: CurtainState = {
  phase: "idle",
  elapsed: 0,
  target: null,
  fired: 0,
  cancelled: 0,
  refused: 0,
};

export interface CurtainSpec {
  readonly outTicks: number;
  readonly inTicks: number;
}

export const DEFAULT_CURTAIN_SPEC: CurtainSpec = {
  outTicks: CURTAIN_OUT_TICKS,
  inTicks: CURTAIN_IN_TICKS,
};

/**
 * 拍数下限是 1。
 *
 * ★ 传 0 不是"硬切"，传 0 是**写错了**：想要硬切就不装幕布（`alpha` 恒 0）。
 *   这里夹到 1 而不是抛，是因为它只影响观感、不影响正确性 —— 为一帧的观感
 *   让整场试玩炸掉不成比例。但**夹这一下必须在同一处**：`curtainAlpha` 与
 *   `advanceCurtain` 各夹一次的话，两边对"落满在哪一拍"会有两个答案，
 *   而症状是"世界在幕布还没落满时被换掉"—— 看得见却查不到。
 */
function outTicksOf(spec: CurtainSpec): number {
  return Math.max(1, Math.floor(spec.outTicks));
}

function inTicksOf(spec: CurtainSpec): number {
  return Math.max(1, Math.floor(spec.inTicks));
}

/**
 * 幕布现在有多不透明（0 = 世界原样，1 = 全遮）。
 *
 * `out` 从 0 涨到 1，`in` 从 1 掉到 0。两者都是**线性**的：一条幕布的可信度取决于
 * 它的**时机**（什么时候落满、什么时候起完），而不是曲线好不好看；一旦引入缓动，
 * "落满在第几拍"就变成了一个需要重新算的数，而判据是按拍写的。
 */
export function curtainAlpha(state: CurtainState, spec: CurtainSpec): number {
  if (state.phase === "out") {
    return Math.min(1, state.elapsed / outTicksOf(spec));
  }
  if (state.phase === "in") {
    return Math.max(0, 1 - state.elapsed / inTicksOf(spec));
  }
  return 0;
}

/**
 * 请求一次跳转（幕布开始落）。
 *
 * 已经有过场在跑 ⇒ **不接**，只把 `refused` 加一，其余状态一个字都不动。
 * 排队不是更难，而是**更坏**：幕布已经盖住了画面，第二次换世界没有任何视觉证据，
 * 玩家会发现自己"莫名其妙到了第三个地方"—— 那正是过场要消灭的体验。
 */
export function requestCurtain(
  state: CurtainState,
  target: CurtainTarget,
): { readonly state: CurtainState; readonly accepted: boolean } {
  if (state.phase !== "idle") {
    return { state: { ...state, refused: state.refused + 1 }, accepted: false };
  }
  // `idle` 的两个字段天然是 0/null，直接展开即可；三个计数器原样带过去
  return { state: { ...state, phase: "out", elapsed: 0, target }, accepted: true };
}

/**
 * 推进一拍。
 *
 * 返回的 `fire` 非空 ⇒ **现在**去换世界。注意返回的 `state` 已经是 `in` 阶段了：
 * 换失败也不会卡在"等一个永远不会来的下一拍"（见文件头）。
 */
export function advanceCurtain(
  state: CurtainState,
  spec: CurtainSpec,
): { readonly state: CurtainState; readonly fire: CurtainTarget | null } {
  if (state.phase === "out") {
    const next = state.elapsed + 1;
    if (next < outTicksOf(spec)) {
      return { state: { ...state, elapsed: next }, fire: null };
    }
    // 落满的这一拍：幕布交给 `in`（alpha 仍是 1），世界交给调用方去换
    const target = state.target;
    return {
      state: { ...state, phase: "in", elapsed: 0, target: null, fired: state.fired + 1 },
      fire: target,
    };
  }
  if (state.phase === "in") {
    const next = state.elapsed + 1;
    if (next < inTicksOf(spec)) {
      return { state: { ...state, elapsed: next }, fire: null };
    }
    return { state: { ...state, phase: "idle", elapsed: 0 }, fire: null };
  }
  return { state, fire: null };
}

/**
 * 撤掉幕布（立即回到 `idle`，alpha 归 0）。
 *
 * ★ 两个调用时机，理由不同但结论一样：
 *   ① **停播**：世界要回滚成工程里那一份，幕布再留半秒就是"停播之后黑一下屏"；
 *   ② **面板硬跳**：那是调试手势（"让我看看那一关"），它本来就绕开门锁，
 *      没有理由为一个不看画面的人演一段过场。
 */
export function cancelCurtain(state: CurtainState): CurtainState {
  if (state.phase === "idle") return state;
  return { ...CURTAIN_IDLE, fired: state.fired, cancelled: state.cancelled + 1, refused: state.refused };
}
