/**
 * L0 · 时钟与秒表
 *
 * ★ 这里只有一个抽象：**"现在几点"从哪来**。
 *
 * 为什么要把 `now()` 做成接口而不是直接 `Date.now()`：
 *   ① headless 判据要能"拨表"（跑 10 分钟的回放不用等 10 分钟）；
 *   ② 确定性回放要求时间可注入 —— 上一代引擎里 `Date.now()` 混进模拟逻辑
 *      导致回放对不上，最后是靠"禁止在模拟层调它"的人工纪律撑住的，
 *      而纪律没有机器守护时必然失守（本工程已反复验证）。
 *   ③ 测试里"等 5 秒"变成"推进 5000 ms"，快且不 flaky。
 *
 * 注意：这是**墙钟**（wall clock），不是游戏时间。游戏时间是 tick 数，
 * 由 core/scheduler 拥有 —— 两者绝不能混（混了就会出现"暂停后 dt 暴涨"
 * 或"卡顿导致跳帧"）。
 */

export interface IClock {
  /** 单调毫秒。实现必须保证**不回退**（`performance.now` / `process.hrtime`）。 */
  now(): number;
}

export class SystemClock implements IClock {
  /** 高精度优先；没有就降级到 Date.now（可能回退，但只在极老环境）。 */
  private readonly impl: () => number;

  constructor() {
    const perf = (globalThis as { performance?: { now?: () => number } }).performance;
    if (perf && typeof perf.now === "function") {
      const p = perf;
      this.impl = () => p.now!();
    } else {
      this.impl = () => Date.now();
    }
  }

  now(): number {
    return this.impl();
  }
}

/** 手动时钟：判据专用。`advance(ms)` 是唯一的时间来源。 */
export class ManualClock implements IClock {
  private t: number;

  constructor(startMs = 0) {
    this.t = startMs;
  }

  now(): number {
    return this.t;
  }

  advance(ms: number): void {
    if (ms < 0) throw new RangeError("ManualClock.advance 不接受负值：" + ms);
    this.t += ms;
  }

  set(ms: number): void {
    this.t = ms;
  }
}

/**
 * 秒表：测量一段代码耗时。
 *
 * ★ 与 `performance.now()` 的差别只在"用注入的时钟"。
 *   用在性能判据里时，**必须**传 `SystemClock`（ManualClock 量不出耗时）。
 */
export class Stopwatch {
  private startedAt = 0;
  private elapsed = 0;
  private running = false;

  constructor(private readonly clock: IClock) {}

  start(): this {
    if (!this.running) {
      this.startedAt = this.clock.now();
      this.running = true;
    }
    return this;
  }

  stop(): number {
    if (this.running) {
      this.elapsed += this.clock.now() - this.startedAt;
      this.running = false;
    }
    return this.elapsed;
  }

  reset(): this {
    this.startedAt = 0;
    this.elapsed = 0;
    this.running = false;
    return this;
  }

  get elapsedMs(): number {
    return this.running ? this.elapsed + (this.clock.now() - this.startedAt) : this.elapsed;
  }
}
