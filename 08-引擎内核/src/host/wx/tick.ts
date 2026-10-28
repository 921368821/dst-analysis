/**
 * L6 · 小游戏（wx）宿主 · 帧源
 *
 * ★★ 这一条最容易被做成"再写一个循环"，而正确的做法是**复用 `ITickSource`**（L3）：
 *   小游戏与浏览器只差"从哪拿 rAF"，不差"帧怎么驱动"。`RafTickSource` 直接读
 *   `globalThis.requestAnimationFrame`（小游戏里没有这个全局），所以我们不复制它的循环，
 *   只把取 rAF 的那一步换掉 —— 于是"一帧跑几个 tick""dt 怎么切分""暂停时怎么办"
 *   这些**已经在 L3 定死并判过**的语义，一条都不用重写。
 *
 * ★ 两条与浏览器不同的地方，都必须在这里吸收掉：
 *   ① 小游戏的 rAF 挂在 **canvas** 上（`canvas.requestAnimationFrame`），不是全局函数；
 *      老版本可能挂在 `wx` 上。两条都要认，取不到就是 `WX.NO_SCHEDULER`。
 *   ② 回调**不一定传时间戳**（浏览器 rAF 一定传）。所以 dt 一律用注入的 `now()` 算，
 *      绝不读回调参数 —— 读参数在真机上拿到 `undefined` 会让 dt 变成 NaN，
 *      而 NaN 传进固定步长累加器的症状是"画面突然停住"，没有任何报错。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { ITickSource } from "../../runtime/tick-source.ts";
import { WX_ERR, type WxCanvasLike, type WxLike } from "./env.ts";

/** 一个可用的帧调度（`requestAnimationFrame` + 可选的取消）。 */
export interface WxRafSource {
  requestAnimationFrame(cb: () => void): number;
  cancelAnimationFrame?(id: number): void;
  /** 这个 rAF 是从哪儿取的（`canvas` / `wx`），仅用于诊断与判据。 */
  readonly from: string;
}

/**
 * 取一个可用的 rAF：canvas 优先，其次 `wx`。
 *
 * ★ 为什么 canvas 优先：小游戏里 canvas 的 rAF 与上屏同步（就是渲染节拍），
 *   而 `wx.requestAnimationFrame` 在老版本里可能是"同一帧里跑多个回调"的实现。
 *   两者都存在时选 canvas，是为了与浏览器上的语义尽量一致。
 */
export function pickRaf(
  wx: WxLike,
  canvas: WxCanvasLike,
): Result<WxRafSource, EngineError> {
  const onCanvas = canvas.requestAnimationFrame;
  if (typeof onCanvas === "function") {
    const caf = canvas.cancelAnimationFrame;
    return ok({
      from: "canvas",
      requestAnimationFrame: (cb) => onCanvas.call(canvas, cb),
      ...(typeof caf === "function" ? { cancelAnimationFrame: (id: number) => caf.call(canvas, id) } : {}),
    });
  }
  const onWx = wx.requestAnimationFrame;
  if (typeof onWx === "function") {
    const caf = wx.cancelAnimationFrame;
    return ok({
      from: "wx",
      requestAnimationFrame: (cb) => onWx.call(wx, cb),
      ...(typeof caf === "function" ? { cancelAnimationFrame: (id: number) => caf.call(wx, id) } : {}),
    });
  }
  return err(
    engineError(WX_ERR.NO_SCHEDULER, "canvas 与 wx 上都没有 requestAnimationFrame"),
  );
}

/**
 * 用 wx 的 rAF 驱动的帧源。
 *
 * `now` 由调用方注入（毫秒，单调即可）：判据可以直接控制"过了多久"，
 * 不需要真的等 —— 这是 `RafTickSource` 当初把 `now` 抽出来的同一个理由。
 */
export class WxTickSource implements ITickSource {
  readonly id: string;
  private handle = 0;
  private fn: ((realDtSec: number) => void) | null = null;
  private last = 0;
  private _running = false;

  constructor(
    private readonly raf: WxRafSource,
    private readonly now: () => number,
  ) {
    this.id = `wx-raf:${raf.from}`;
  }

  start(fn: (realDtSec: number) => void): void {
    if (this._running) return;
    this.fn = fn;
    this.last = this.now();
    this._running = true;
    this.handle = this.raf.requestAnimationFrame(this.loop);
  }

  stop(): void {
    this._running = false;
    if (this.handle !== 0) this.raf.cancelAnimationFrame?.(this.handle);
    this.handle = 0;
  }

  get running(): boolean {
    return this._running;
  }

  /**
   * ★ 一定是箭头函数字段而不是方法：它要被当作回调交出去，
   *   而 wx 的 rAF 不保证调用者（`this` 会丢）。绑一次比在构造里 `bind` 更好读。
   */
  private readonly loop = (): void => {
    if (!this._running) return;
    const t = this.now();
    const dt = (t - this.last) / 1000;
    this.last = t;
    this.fn?.(dt);
    // ★ stop() 可能在 fn 里被调用（例如游戏切场景时停播）：此时不能再排下一帧。
    if (this._running) this.handle = this.raf.requestAnimationFrame(this.loop);
  };
}
