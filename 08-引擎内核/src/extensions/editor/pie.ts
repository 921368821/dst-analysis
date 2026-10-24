/**
 * L4 · 编辑器：PIE（Play-In-Editor）时钟
 *
 * 编辑器的「试玩」不是 `setInterval(step, 33)`。这一层只回答一个问题：
 * **这一帧应该推进几个 tick**。宿主拿着这个数字去调 `scene.step`。
 *
 * 四条语义，每条都是判据（它们看起来都对，但错了之后表现得很像「性能问题」）：
 *
 * ① **暂停时不累积**。暂停 10 秒再播放，不该补跑 300 tick。
 *    累积器不清零的话，恢复的那一帧会「跳」一下 —— 而人只会觉得「恢复时卡了一下」。
 *
 * ② **单步之后回到暂停**。`step(1)` 的语义是「暂停着走一步」。
 *    忘了置暂停的话，点了单步就等于点了播放，而按钮上写的还是「单步」。
 *
 * ③ **单帧最多跑 `maxStepTicks` 个 tick**，被夹掉的时间**丢掉**而不是留着补。
 *    留着补的话，卡一下就永远跑得比实时快（累积器里存着永远还不完的债）。
 *
 * ④ 累积器用 tick 为单位并带 `EPS`。用「秒」或「不加容差」累积时，
 *    某些帧率下每帧的 tick 增量是无限小数，累加结果**永远差一点点**到整数：
 *    实测 144fps（`1/144×30 = 0.20833333333333334`）下跑满 1 秒只得到
 *    29.999999999999996 ⇒ **少一个 tick**，速度是 29/30，而画面上只表现为「有点慢」。
 *
 *    ⚠️ 这一条最初写成「60fps 下会掉」，是**错的**：`1/60×30` 恰好等于 0.5，
 *    60fps 下两帧正好一个 tick，怎么测都是对的。教训：拿一个「刚好能整除」的
 *    帧率去验浮点累积，等于没验 —— 判据必须挑会露馅的那个输入（144fps）。
 */

/** 累积器的浮点容差：只用来吸收「本来是整数、算出来差 1e-16」的情况。 */
const EPS = 1e-9;

/** 单步排队的上限（脚本连点/粘贴大数字时不要卡死主线程）。 */
const MAX_PENDING = 600;

export interface PieOptions {
  /** 逻辑帧率（与 `scene.step` 的固定步一致，默认 30）。 */
  readonly hz?: number;
  /** 单帧最多跑几个 tick（掉帧兜底，默认 4 ⇒ 最慢仍跑 4×hz 的逻辑速度）。 */
  readonly maxStepTicks?: number;
}

export interface PieStats {
  readonly playing: boolean;
  /** 已推进的 tick 总数（单步也算）。 */
  readonly tick: number;
  /** 排队待跑的单步数。 */
  readonly pending: number;
  /** 因为 `maxStepTicks` 被夹掉的帧数（不是 tick 数）。 */
  readonly clampedFrames: number;
  /** 累积器里未走完的 tick（调试用：正常时永远 < 1）。 */
  readonly backlog: number;
}

export class Pie {
  private readonly hz: number;
  private readonly maxStepTicks: number;
  private playing = false;
  private accTicks = 0;
  private pendingTicks = 0;
  private tickCount = 0;
  private clamped = 0;

  constructor(opts: PieOptions = {}) {
    const hz = opts.hz ?? 30;
    this.hz = hz > 0 ? hz : 30;
    const m = opts.maxStepTicks ?? 4;
    this.maxStepTicks = m >= 1 ? Math.floor(m) : 1;
  }

  get isPlaying(): boolean {
    return this.playing;
  }

  play(): void {
    this.playing = true;
  }

  pause(): void {
    this.playing = false;
    // 见 ①：暂停那一刻把欠的时间丢掉
    this.accTicks = 0;
  }

  toggle(): boolean {
    if (this.playing) this.pause();
    else this.play();
    return this.playing;
  }

  /** 排队单步（默认 1 tick）。**单步 = 暂停着走**，见 ②。 */
  step(n = 1): void {
    const k = Math.max(0, Math.floor(n));
    this.pendingTicks = Math.min(this.pendingTicks + k, MAX_PENDING);
    this.playing = false;
    this.accTicks = 0;
  }

  /**
   * 推进一帧，返回**本次应该跑几个 tick**（0..maxStepTicks）。
   * 约定：宿主必须把这个数字**原样**交给 `scene.step`，否则 `stats().tick` 与场景不同步。
   */
  advance(dtSec: number): number {
    let ticks = 0;
    if (this.pendingTicks > 0) {
      ticks = this.pendingTicks;
      this.pendingTicks = 0;
    } else if (this.playing) {
      const dt = dtSec > 0 ? dtSec : 0;
      this.accTicks += dt * this.hz;
      const due = Math.floor(this.accTicks + EPS);
      this.accTicks -= due;
      ticks = due;
      if (due > this.maxStepTicks) {
        ticks = this.maxStepTicks;
        this.clamped++;
        // 见 ③：被夹掉的时间丢掉，不留债
        this.accTicks = 0;
      }
    } else {
      // 见 ①：暂停中不累积
      this.accTicks = 0;
    }
    this.tickCount += ticks;
    return ticks;
  }

  stats(): PieStats {
    return {
      playing: this.playing,
      tick: this.tickCount,
      pending: this.pendingTicks,
      clampedFrames: this.clamped,
      backlog: this.accTicks,
    };
  }
}

export function createPie(opts: PieOptions = {}): Pie {
  return new Pie(opts);
}
