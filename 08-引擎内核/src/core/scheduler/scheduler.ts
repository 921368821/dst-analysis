/**
 * L2 · 固定步长调度器
 *
 * ★★ 这是整个引擎的**时间唯一真相**。它只做一件事：把"真实经过的时间"
 *    换成"整数个固定步"，并对齐所有边界情况。
 *
 * 为什么必须有它（而不是 `requestAnimationFrame` 里直接跑 `step(dt)`）：
 *   ① **可变 dt 让物理与 AI 不可复现**。同一段操作在 144Hz 和 60Hz 上结果不同，
 *      回放对不上、判据只能靠容差、联机不同步。
 *   ② **卡顿会放大错误**。一次 200ms 的 GC 停顿喂给物理一个 0.2s 的步长，
 *      角色会穿墙。固定步长把"穿墙"变成"多跑几步"。
 *   ③ **暂停/加速/单帧调试**都需要一个"把时间当参数"的地方，而不是散在各处的 dt。
 *
 * 三条边界规则（都是上一代引擎真实踩过的）：
 *
 * ① **上限 + 记账**：一帧最多追 `maxStepsPerFrame` 步。超出的时间**丢弃**，
 *    但 `droppedSteps` 必须累计并暴露 —— 静默丢时间会让"玩家觉得卡了但日志一切正常"。
 *    （上一代引擎在"切标签页回来"时跑过 18000 步然后整帧掉到 2fps，
 *     而序列化的问题在于没人知道发生了这件事。）
 * ② **幂等**：`stepTo(tick)` 对 `tick <= current` 直接返回 0。原版饥荒的
 *    `if tick <= last_tick_seen then return end` 就是这个 —— 引擎回调与逻辑拍
 *    解耦之后，重复调用一定会发生，没有这个保护会重复推进世界。
 * ③ **alpha 用于渲染插值**：渲染在两次固定步之间用 `alpha` 插值，
 *    这样 30Hz 模拟在 60Hz 屏幕上不抖。alpha 与 tick 无关，**不参与逻辑**。
 */

import { clamp } from "../../foundation/math/scalar.ts";

export interface SchedulerConfig {
  /** 固定步长（秒）。饥荒风格默认 1/30；物理要求高时可到 1/60。 */
  readonly fixedDt: number;
  /** 一帧最多推进几步（防止死亡螺旋）。 */
  readonly maxStepsPerFrame?: number;
  /** 单帧接受的最大真实时间（秒）—— 超过视为"刚切回来"，直接截断。 */
  readonly maxFrameDt?: number;
  /** 初始时间缩放（1 = 正常）。 */
  readonly timeScale?: number;
}

export interface SchedulerStats {
  readonly tick: number;
  /** 逻辑时间（秒）= tick * fixedDt。**不是**真实经过时间。 */
  readonly time: number;
  /** 本帧实际跑的步数。 */
  readonly lastSteps: number;
  /** 累计被丢弃的步数（帧预算不够）。非 0 就说明有卡顿，应当诊断。 */
  readonly droppedSteps: number;
  /** 累计执行的步数（不因暂停清零，用于诊断）。 */
  readonly totalSteps: number;
  readonly timeScale: number;
  readonly paused: boolean;
  /** 渲染插值系数 [0,1)。 */
  readonly alpha: number;
}

export type StepFn = (tick: number, dt: number) => void;

export class FixedStepScheduler {
  readonly fixedDt: number;
  private readonly maxSteps: number;
  private readonly maxFrameDt: number;

  private _tick = 0;
  private _time = 0;
  private _accumulator = 0;
  private _timeScale: number;
  private _paused = false;
  private _dropped = 0;
  private _total = 0;
  private _lastSteps = 0;
  private _alpha = 0;
  /** 记录"已经回调过的最大 tick"，幂等保护用。 */
  private _served = -1;

  private readonly steps: StepFn[] = [];

  constructor(cfg: SchedulerConfig) {
    if (!(cfg.fixedDt > 0)) throw new RangeError("fixedDt 必须 > 0");
    this.fixedDt = cfg.fixedDt;
    this.maxSteps = cfg.maxStepsPerFrame ?? 5;
    this.maxFrameDt = cfg.maxFrameDt ?? 0.25;
    this._timeScale = cfg.timeScale ?? 1;
  }

  /** 订阅每一步。返回退订函数。 */
  onStep(fn: StepFn): () => void {
    this.steps.push(fn);
    return () => {
      const i = this.steps.indexOf(fn);
      if (i >= 0) this.steps.splice(i, 1);
    };
  }

  /**
   * 推进。返回本帧实际执行的步数。
   * `realDtSec` 是**真实**经过的秒数（来自 IClock 的差值），不是逻辑时间。
   */
  advance(realDtSec: number): number {
    if (!(realDtSec >= 0)) {
      // 时钟回退是宿主 bug（ManualClock 已拒绝负值，SystemClock 理论上单调）。
      // 这里不抛，因为抛在渲染循环里会让整帧崩掉；但要明确返回 0 并留痕。
      return 0;
    }
    if (this._paused) {
      this._lastSteps = 0;
      // 暂停时 alpha 不变：恢复后不会出现"角色往前跳一下"
      return 0;
    }

    const clamped = Math.min(realDtSec, this.maxFrameDt);
    this._accumulator += clamped * this._timeScale;

    let steps = 0;
    while (this._accumulator >= this.fixedDt && steps < this.maxSteps) {
      this._accumulator -= this.fixedDt;
      steps++;
    }

    // 超过预算的部分：丢弃并记账（不许静默）
    if (this._accumulator >= this.fixedDt) {
      const leftover = Math.floor(this._accumulator / this.fixedDt);
      this._dropped += leftover;
      this._accumulator -= leftover * this.fixedDt;
    }

    for (let i = 0; i < steps; i++) {
      this._tick++;
      this._time = this._tick * this.fixedDt;
      this.runStep(this._tick, this.fixedDt);
    }

    this._lastSteps = steps;
    this._alpha = this._accumulator / this.fixedDt;
    return steps;
  }

  /**
   * 直接跳到某个 tick（编辑器"运行到此处"、回放快进用）。
   * ★ 幂等：`target <= 当前 tick` 返回 0，不重放。
   */
  stepTo(targetTick: number): number {
    if (targetTick <= this._tick) return 0;
    const n = targetTick - this._tick;
    for (let i = 0; i < n; i++) {
      this._tick++;
      this._time = this._tick * this.fixedDt;
      this.runStep(this._tick, this.fixedDt);
    }
    this._lastSteps = n;
    return n;
  }

  /** 单步（编辑器单帧调试）。返回新 tick。 */
  stepOnce(): number {
    return this.stepTo(this._tick + 1);
  }

  private runStep(tick: number, dt: number): void {
    // 幂等保护：同一个 tick 绝不回调两次
    if (tick <= this._served) return;
    this._served = tick;
    this._total++;
    for (const fn of this.steps) fn(tick, dt);
  }

  set paused(v: boolean) {
    this._paused = v;
    if (!v) {
      // 恢复时清空累积：暂停期间的真实时间不该被补跑
      this._accumulator = 0;
    }
  }
  get paused(): boolean {
    return this._paused;
  }

  set timeScale(v: number) {
    // 0 会让世界完全停住但仍在 tick —— 那是 paused 的语义，不是缩放
    this._timeScale = clamp(v, 0.01, 16);
  }
  get timeScale(): number {
    return this._timeScale;
  }

  get tick(): number {
    return this._tick;
  }
  get time(): number {
    return this._time;
  }
  get alpha(): number {
    return this._alpha;
  }

  /** 存档/回放：把 tick 设回来（**不执行**中间的步）。 */
  resetTo(tick: number, served = tick): void {
    this._tick = tick;
    this._time = tick * this.fixedDt;
    this._served = served;
    this._accumulator = 0;
    this._alpha = 0;
    this._lastSteps = 0;
  }

  stats(): SchedulerStats {
    return {
      tick: this._tick,
      time: this._time,
      lastSteps: this._lastSteps,
      droppedSteps: this._dropped,
      totalSteps: this._total,
      timeScale: this._timeScale,
      paused: this._paused,
      alpha: this._alpha,
    };
  }
}
