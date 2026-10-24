/**
 * L4 · SpriteAnimator 组件（`render.spriteAnimator`）
 *
 * 把"某个节点正在播哪段动画、播到第几毫秒"变成**实体自己的状态**。
 *
 * ★★ 为什么时钟在组件上，而不是动画模块/图集上（本任务的核心约束）：
 *   同一份素材（clip + 图集）会被多个世界、多个实体共享。若把 `timeMs` 放进
 *   `AnimationClip`，两个世界就共用一个进度：A 世界暂停，B 世界同一动作也停；
 *   A 世界 seek(0)，B 世界回到第一帧。而"同一素材、两个世界以不同节奏播放"
 *   正是存档/回放/分屏预览的常规需求。所以：
 *     · clip = 不可变资产（animation.ts）
 *     · timeMs = 每实体状态（这里）
 *     · 模块 = 只读注册表 + 每帧推进（anim-module.ts，每世界一份实例）
 *
 * ★ 为什么字段里没有帧名缓存：
 *   当前帧由 `sampleClip(clip, timeMs)` 算出后写进同节点的 `Sprite.frame`。
 *   多存一个 `currentFrame` 只会制造"它和 timeMs 谁是真的"的问题，并且在
 *   seek / speed 改动后需要同步两处 —— 这正是"看起来支持"的典型来源。
 *
 * ★ `loopOverride` 为什么是每实体的：
 *   同一段"死亡"动画，普通怪要循环播放做待机，Boss 的登场只播一次就停在最后
 *   一帧。素材本身只有一份（acTL 里写死 loopCount），"这次只播一次"是实例选择，
 *   不是资产属性。字段值 -1 = 用 clip 的 loopCount；>=0 覆盖（0 也能覆盖成无限）。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";

/** 组件类型常量：模块注册表与场景共用，避免两处手写字符串。 */
export const SPRITE_ANIMATOR_TYPE = "render.spriteAnimator";

export class SpriteAnimator extends Component {
  /** 播放哪段 clip（`AnimationClip.id`，不是对象引用 —— 同 `Sprite.atlasId`）。 */
  clipId = "";
  /**
   * 本实体自己的播放进度（毫秒）。
   * ★ 允许 > total：采样用总时长取模，保留时间可以让 HUD 看到"播到第几轮"。
   *   一次性动画播完后由模块夹在终点，避免长时间挂着做无意义的浮点累加。
   */
  timeMs = 0;
  /** 播放速率：1 = 正常，< 0 = 倒放，0 = 冻结（时间不动）。 */
  speed = 1;
  /** 是否推进时间。false 时仍会按当前 timeMs 刷新帧（seek 后能立刻看到）。 */
  playing = true;
  /** -1 = 用 clip 的 loopCount；>= 0 覆盖它。 */
  loopOverride = -1;
  /**
   * `reset()` 时是否自动恢复播放。
   * ★ 边界：模块**不监听 onAttach 来"自动开始"** —— 新挂载的实体是否播放由
   *   `playing` 字段（默认 true）与序列化数据决定。`autoplay` 只被 `reset()`
   *   查询，语义是"重置回初始状态时要不要接着播"。
   */
  autoplay = true;

  readonly schema: ComponentSchema = {
    type: SPRITE_ANIMATOR_TYPE,
    fields: {
      clipId: FieldType.String,
      timeMs: FieldType.Float,
      speed: FieldType.Float,
      playing: FieldType.Bool,
      loopOverride: FieldType.Int,
      autoplay: FieldType.Bool,
    },
    // defaults 与字段声明保持一致：新组件的 save() 必须能写出可读回的值
    defaults: {
      clipId: "",
      timeMs: 0,
      speed: 1,
      playing: true,
      loopOverride: -1,
      autoplay: true,
    },
  };

  /** 回到起点，并按 `autoplay` 决定是否继续播。 */
  reset(): void {
    this.timeMs = 0;
    this.playing = this.autoplay;
  }

  /**
   * 跳到指定毫秒。
   * ★ 负数夹到 0：与 `sampleClip` 的"负时间 = 还没开始"保持一致。
   *   保留负值只会让倒放动画在起点前空转一段（时间要先爬回 0 才动画面），
   *   而"跳到 -100ms"在时间轴上没有对应画面可显示。
   * ★ 非有限数直接抛：这是调用方的编程错误，不是可配置字段（见 animation.ts）。
   */
  seek(ms: number): void {
    if (!Number.isFinite(ms)) {
      throw new TypeError(`SpriteAnimator.seek 的 ms 必须是有限数（收到 ${String(ms)}）`);
    }
    this.timeMs = ms < 0 ? 0 : ms;
  }
}
