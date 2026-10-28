/**
 * L4 · 补间 · 单个标量补间（纯数据 + 纯采样）
 *
 * 与 `render/animation.ts`（帧序列时间轴）是**同一套时间观的两种离散度**：
 *   帧时间轴：时刻 → 第几帧（离散选择）
 *   这里：时刻 → 一个数（连续插值）
 * 两者的采样都是纯函数、都不持状态、都不许缓存"上次时间"—— 纪律同源，
 * 因为共用一个消费者群（渲染 / UI / 回放 / 调试面板各自采样，必须互相不可见）。
 *
 * ★★ 为什么 `from`/`to` 必须**显式给出**，不能在采样时读"当前值"：
 *   读当前值等于让起点随调用时机漂移。同一个补间，第一次从 0 播到 100，
 *   第二次如果从 80 开始（因为上一次没播完），实际就变成了 80→100 ——
 *   而配置里写的还是 0→100。这种 bug 的症状是"动画时长一样、但幅度越来越小"，
 *   极难归因。所以两端是构造参数，采样只回答"此刻该是哪个值"。
 *
 * ★ 为什么 `delay` 只作用于**第一次**，循环内不重复：
 *   delay 的语义是"这段动画什么时候开始"，不是"每轮之间停多久"。
 *   循环内重复 delay 会让一段 duration=100/delay=100 的循环动画节奏变成
 *   停 100、走 100、停 100 —— 与 CSS `animation-delay` 也不一致。
 *   真要"每轮停一下"应该由调用方把停顿做成另一段补间，或者用 `holdMs` 那样的
 *   显式字段（本批不做，记在缺口里）。
 *
 * ★ `done` 与终值：有限循环播完后**停在 to**，不是停在采样值。
 *   浮点上 `easing(1)` 可能给出 to±1e-16，直接采用会让"播完了但位置差一点"，
 *   而 `done=true` 时调用方通常就停止刷新了 —— 那个误差会永久留在实体上。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import { getEasing, type EasingFn } from "./easing.ts";

export const TWEEN_ERR = {  BAD_DURATION: "TWEEN.BAD_DURATION",
  BAD_DELAY: "TWEEN.BAD_DELAY",
  BAD_SPEED: "TWEEN.BAD_SPEED",
  BAD_LOOP: "TWEEN.BAD_LOOP",
  BAD_ENDPOINT: "TWEEN.BAD_ENDPOINT",
  UNKNOWN_EASING: "TWEEN.UNKNOWN_EASING",
  NON_FINITE_TIME: "TWEEN.NON_FINITE_TIME",
} as const;

/** 不可变的补间描述（纯数据，可被任意多实体共享）。 */
export interface TweenSpec {
  /** 稳定 id（存档/组件引用它）。 */
  readonly id: string;
  /** 起点值。 */
  readonly from: number;
  /** 终点值。 */
  readonly to: number;
  /** 一段的时长（毫秒）。必须 > 0。 */
  readonly durationMs: number;
  /** 缓动名（`EASINGS` 的键，或 `cubic-bezier(a,b,c,d)`）。 */
  readonly easing: string;
  /**
   * 构造期解析出来的曲线（冻结、无状态，可被多实体共享）。
   *
   * ★ 为什么把函数也放进 spec，而不是采样时按 `easing` 再查一次表：
   *   ① `cubic-bezier(...)` 不在表里 —— 采样时查表得到 `undefined`，
   *      空值断言会在第一帧崩（这正是批118 之前 `EASINGS[spec.easing]!` 的形状）；
   *   ② 每帧解析一次正则/跑一次反解构造，纯属浪费；
   *   ③ 最要紧的是**一致性**：同一份 spec 在两次采样之间不该有"重新解释"的机会。
   *   函数本身不可变、不持状态，所以 spec 仍然是可共享的纯数据。
   */
  readonly ease: EasingFn;
  /** 首次开始前的等待（毫秒）。>= 0，只在第一次生效（见文件头）。 */
  readonly delayMs: number;
  /** 播放速率倍率。1 = 正常，< 0 = 倒放，0 = 冻结。 */
  readonly speed: number;
  /** 循环次数：0 = 无限循环；>= 1 = 有限次。 */
  readonly loopCount: number;
  /** 循环内是否往返（true 时偶数轮正向、奇数轮反向）。 */
  readonly yoyo: boolean;
}

/** 构造入参：只要求必填项，其余有默认值。 */
export interface TweenSpecInput {
  readonly id: string;
  readonly from: number;
  readonly to: number;
  readonly durationMs: number;
  readonly easing?: string;
  readonly delayMs?: number;
  readonly speed?: number;
  readonly loopCount?: number;
  readonly yoyo?: boolean;
}

/** 采样结果（纯值）。 */
export interface TweenSample {
  /** 当前值。 */
  readonly value: number;
  /** 单段内的归一化进度 [0,1]（不含 delay、不含循环）。 */
  readonly progress: number;
  /** 第几次循环（从 0 开始）。 */
  readonly loop: number;
  /** 有限循环且已播完。无限循环永远 false。 */
  readonly done: boolean;
  /** 当前是否还处在首次 delay 内（此时 `value` 恒等于 `from`）。 */
  readonly waiting: boolean;
}

/**
 * 校验并构造补间。
 *
 * ★ 为什么"两端必须有限"也要在这里拒绝：
 *   from/to 是配置字段，NaN 会一路传播到实体坐标，而症状是"这个控件不动了"。
 *   与 `makeAnimationClip` 拒绝零总时长是同一条理由：在数据入口炸，
 *   比让错误在下游变成噪声便宜。
 */
export function makeTween(input: TweenSpecInput): Result<TweenSpec, EngineError> {
  if (!Number.isFinite(input.from) || !Number.isFinite(input.to)) {
    return err(
      engineError(TWEEN_ERR.BAD_ENDPOINT, `补间两端必须是有限数：from=${String(input.from)} to=${String(input.to)}`, {
        id: input.id,
      }),
    );
  }
  if (!Number.isFinite(input.durationMs) || input.durationMs <= 0) {
    return err(
      engineError(TWEEN_ERR.BAD_DURATION, `durationMs 必须是 > 0 的有限数：${String(input.durationMs)}`, {
        id: input.id,
      }),
    );
  }
  const delayMs = input.delayMs ?? 0;
  if (!Number.isFinite(delayMs) || delayMs < 0) {
    return err(engineError(TWEEN_ERR.BAD_DELAY, `delayMs 必须是非负有限数：${String(delayMs)}`, { id: input.id }));
  }
  const speed = input.speed ?? 1;
  if (!Number.isFinite(speed)) {
    return err(engineError(TWEEN_ERR.BAD_SPEED, `speed 必须是有限数：${String(speed)}`, { id: input.id }));
  }
  const loopCount = input.loopCount ?? 0;
  if (!Number.isInteger(loopCount) || loopCount < 0) {
    return err(
      engineError(TWEEN_ERR.BAD_LOOP, `loopCount 必须是非负整数：${String(loopCount)}（0 = 无限循环）`, {
        id: input.id,
      }),
    );
  }
  const easing = input.easing ?? "quadInOut";
  const e = getEasing(easing);
  if (!e.ok) {
    return err(engineError(TWEEN_ERR.UNKNOWN_EASING, e.error.message, { id: input.id, easing }));
  }
  return ok(
    Object.freeze({
      id: input.id,
      from: input.from,
      to: input.to,
      durationMs: input.durationMs,
      easing,
      ease: e.value,
      delayMs,
      speed,
      loopCount,
      yoyo: input.yoyo ?? false,
    }),
  );
}

/**
 * 一段补间的换算后时长：`durationMs / |speed|`。
 *
 * ★ speed=0 时按 1 倍算，**不返回 Infinity**：除零得 Infinity 会让采样里
 *   "循环号 = floor(t / Infinity) = 0" 恒成立，于是 speed=0 与 speed=1
 *   在同一 timeMs 上给出不同结果（一个永远 from、一个正常走）。
 *   冻结的成因在**调用方**（`timeMs += dt * speed` ⇒ 加 0），不在采样里。
 */
function effectiveDuration(spec: TweenSpec): number {
  const s = Math.abs(spec.speed);
  return spec.durationMs / (s === 0 ? 1 : s);
}

/**
 * 采样：`timeMs` 时刻补间的值与状态。
 *
 * ★ 时间轴分三段，顺序不能换：
 *     ① delay 段      → value = from，waiting = true
 *     ② 有限循环播完  → value = to，done = true（**必须在取模之前判**）
 *     ③ 取模到单段内  → 按 easing 插值
 *   ②先于③：若先取模，`timeMs` 超过 `duration*loopCount` 的部分会被绕回第一段，
 *   症状是"动画明明播完了却从头再闪一下"。
 *
 * ★ yoyo 的往返轮：奇数轮把进度翻过来再用**同一条** easing（`easing(1-p)`）。
 *   反向不是把 easing 换成它的镜像函数 —— 那会得到另一条曲线，
 *   "去"和"回"就不再对称。翻进度则保证去回严格对称，只是方向相反。
 *   播完时停在**最后一轮的终点**：最后一轮编号是 `loopCount-1`，
 *   奇数 ⇒ 反向 ⇒ 停在 `from`（不是无条件的 `to`）。
 *
 * ★ speed 只做两件事：缩放一段的换算时长（`durationMs/|speed|`）、以及在
 *   `speed<0` 时把进度取反（倒放）。它**不**在调用方之外再缩放一次 ——
 *   调用方负责 `timeMs += dt * speed`。`speed=0` 时采样不特殊处理：
 *   除零得 Infinity 会让循环号恒 0，与 speed=1 行为分叉；冻结的成因在
 *   调用方加的是 0，不在采样里。
 */
export function sampleTween(spec: TweenSpec, timeMs: number): TweenSample {
  if (!Number.isFinite(timeMs)) {
    throw new TypeError(`sampleTween 的 timeMs 必须是有限数（收到 ${String(timeMs)}）`);
  }
  // 负时间 = 还没开始（与 sampleClip 同口径）：夹到 0，不环绕。
  const t = timeMs < 0 ? 0 : timeMs;

  if (t < spec.delayMs) {
    return { value: spec.from, progress: 0, loop: 0, done: false, waiting: true };
  }

  const local0 = t - spec.delayMs;
  const perLoop = effectiveDuration(spec);

  if (spec.loopCount > 0 && local0 >= perLoop * spec.loopCount) {
    // 有限循环播完：停在**最后一轮的终点**。
    // ★ yoyo 开着时那不是 `to`：最后一轮的编号是 loopCount-1，
    //   它是奇数 ⇒ 反向轮 ⇒ 终点是 from。无条件停 to 会让一段
    //   "0→100 往返 4 次"的动画停在 100，而肉眼看到的最后状态是 0。
    const lastIsReverse = spec.yoyo && (spec.loopCount - 1) % 2 === 1;
    return {
      value: lastIsReverse ? spec.from : spec.to,
      progress: 1,
      loop: spec.loopCount - 1,
      done: true,
      waiting: false,
    };
  }

  const loop = spec.loopCount === 0
    ? Math.floor(local0 / perLoop)
    : Math.min(Math.floor(local0 / perLoop), spec.loopCount - 1);
  const local = local0 - loop * perLoop;
  // ★ 循环边界：local 精确为 0 且不是第 0 轮时，这是"上一轮刚播完"的那一刻，
  //   进度取 1（终点）而不是 0。取 0 会让一段 0→100 的补间在 t=duration 时
  //   突然回到 0（症状：动画每到整秒就闪一下起点）。
  //   帧时间轴没有这个问题（循环回到第 0 帧是它要的），补间有，因为 from≠to。
  //
  // ★ 同一时刻的"方向"也必须按**上一轮**算：t=duration 时轮号已经是 1，
  //   若 yoyo 开着就判成反向轮，于是给出 from 而不是 to。
  //   用 effectiveLoop 回退一轮，两者才同时正确。
  const atLoopStart = local === 0 && loop > 0;
  const effectiveLoop = atLoopStart ? loop - 1 : loop;
  const p = atLoopStart ? 1 : local / perLoop;

  // 反向的两个来源：speed<0（倒放）与 yoyo 的奇数轮。两者是**异或**关系：
  // 同时成立时互相抵消（倒着走的往返轮 = 正向轮）。
  const reversed = spec.speed < 0 !== (spec.yoyo && effectiveLoop % 2 === 1);
  const progress = reversed ? 1 - p : p;

  const value = spec.from + (spec.to - spec.from) * spec.ease(progress);
  return { value, progress: p, loop, done: false, waiting: false };
}
/** 一段补间从 `from` 走到 `to` 需要的总时长（不含循环、不含 delay）。 */
export function tweenDurationMs(spec: TweenSpec): number {
  return effectiveDuration(spec);
}

/** 补间在 `timeMs` 是否已经结束（有限循环才可能为 true）。 */
export function tweenIsDone(spec: TweenSpec, timeMs: number): boolean {
  return sampleTween(spec, timeMs).done;
}
