/**
 * L2 · 帧宿主接口（渲染阶段的落点）
 *
 * ★ 定义在 L2 而不是 L3：它是**内核契约**（"引擎每帧必须有一个渲染阶段"），
 *   由 L3 的 GameApp 实现。反过来放会让 core 依赖 runtime。
 *
 * ★ 为什么渲染是**独立的阶段**而不是一个事件：
 *   事件是"发生了什么，谁关心谁订阅"。而渲染是"每个宿主都必须执行的一步"。
 *   用事件的话会出现两个无法区分的情况：
 *     · 没有任何渲染器订阅（画面该黑，但应该**报出来**）
 *     · 渲染器都在，但这一帧没触发（bug）
 *   更糟的是，"渲染器抛错"会被 EventBus 的错误隔离吞掉，画面黑掉而日志安静。
 *
 *   所以：`onRender(fn)` 是一个**注册阶段**的接口，`GameApp` 在 `frame()` 里
 *   无条件执行所有已注册的渲染器，并对**抛错**逐个记录（带帧号）。
 *
 * ★ `alpha` 的含义：两次固定步之间的插值系数。渲染用它让 30Hz 模拟在 60Hz 屏幕上不抖。
 *   它**只给渲染**，不参与逻辑（参与逻辑就会破坏确定性）。
 */

export interface FrameInfo {
  /** 第几帧（从 1 开始，单调递增）。 */
  readonly frame: number;
  /** 这一帧的真实耗时（秒）。 */
  readonly realDtSec: number;
  /** 这一帧跑了几个固定步（0 表示这一帧没到步进时间）。 */
  readonly steps: number;
  /** 渲染插值系数 [0,1)。 */
  readonly alpha: number;
  /** 当前逻辑 tick。 */
  readonly tick: number;
}

export type RenderFn = (info: FrameInfo) => void;

export interface IFrameHost {
  /** 注册渲染器。返回注销函数。 */
  onRender(fn: RenderFn): () => void;
  /** 已注册的渲染器数量（诊断：0 个意味着画面不会更新）。 */
  readonly rendererCount: number;
}
