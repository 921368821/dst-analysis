/**
 * L3 · 帧源（把"谁在驱动帧"抽象出来）
 *
 * 三种实现：
 *   RafTickSource      浏览器 requestAnimationFrame（真实交付形态）
 *   IntervalTickSource Node 定时器（headless 跑判据）
 *   ManualTickSource   手动 tick（单帧调试 / 回放逐帧）
 *
 * ★ 为什么不让 GameApp 直接调 `requestAnimationFrame`：
 *   那样 headless 判据就跑不起来，只能靠"起个浏览器"或"假装有 rAF"。
 *   上一代引擎为此在测试桩里手写了一整套 DOM/rAF —— 那套桩后来又成了
 *   假绿灯的来源（桩和浏览器的语义差制造过三次假否定）。
 *   ⇒ 把"驱动"抽象成一个接口，桩就不需要了：用 ManualTickSource。
 */

export interface ITickSource {
  /** 开始驱动。`fn` 每帧调一次，参数是**真实经过的秒数**。 */
  start(fn: (realDtSec: number) => void): void;
  stop(): void;
  readonly running: boolean;
  readonly id: string;
}

export class RafTickSource implements ITickSource {
  readonly id = "raf";
  private handle = 0;
  private fn: ((dt: number) => void) | null = null;
  private last = 0;
  private _running = false;

  constructor(private readonly now: () => number) {}

  start(fn: (realDtSec: number) => void): void {
    if (this._running) return;
    this.fn = fn;
    this.last = this.now();
    this._running = true;
    const raf = (globalThis as { requestAnimationFrame?: (cb: (t: number) => void) => number })
      .requestAnimationFrame;
    if (raf === undefined) throw new Error("当前环境没有 requestAnimationFrame —— 用 IntervalTickSource");
    const loop = (): void => {
      if (!this._running) return;
      const t = this.now();
      const dt = (t - this.last) / 1000;
      this.last = t;
      this.fn?.(dt);
      this.handle = raf(loop);
    };
    this.handle = raf(loop);
  }

  stop(): void {
    this._running = false;
    const caf = (globalThis as { cancelAnimationFrame?: (h: number) => void }).cancelAnimationFrame;
    if (this.handle !== 0 && caf !== undefined) caf(this.handle);
    this.handle = 0;
  }

  get running(): boolean {
    return this._running;
  }
}

export class IntervalTickSource implements ITickSource {
  readonly id = "interval";
  private timer: ReturnType<typeof setInterval> | null = null;
  private last = 0;
  private _running = false;

  constructor(
    private readonly now: () => number,
    private readonly intervalMs = 1000 / 60,
  ) {}

  start(fn: (realDtSec: number) => void): void {
    if (this._running) return;
    this._running = true;
    this.last = this.now();
    this.timer = setInterval(() => {
      const t = this.now();
      const dt = (t - this.last) / 1000;
      this.last = t;
      fn(dt);
    }, this.intervalMs);
  }

  stop(): void {
    this._running = false;
    if (this.timer !== null) clearInterval(this.timer);
    this.timer = null;
  }

  get running(): boolean {
    return this._running;
  }
}

/** 手动：`pump(dt)` 由调用方驱动。判据与"单帧调试"用它。 */
export class ManualTickSource implements ITickSource {
  readonly id = "manual";
  private fn: ((dt: number) => void) | null = null;
  private _running = false;

  start(fn: (realDtSec: number) => void): void {
    this.fn = fn;
    this._running = true;
  }

  stop(): void {
    this.fn = null;
    this._running = false;
  }

  get running(): boolean {
    return this._running;
  }

  /** 推一帧。**只有当 start 过才有效**（与真实帧源语义一致）。 */
  pump(realDtSec: number): boolean {
    if (!this._running || this.fn === null) return false;
    this.fn(realDtSec);
    return true;
  }
}
