/**
 * L4 · 补间的第二个消费者：`TweenPlayer`（组件 + 每 tick 推进）
 *
 * `tween.ts` 交付了"时刻 → 一个数"的**纯采样**，但没有任何东西持有"现在是第几毫秒"。
 * 那个缺口正是本文件补的：把"某条轨道播到哪了"变成**实体自己的状态**。
 *
 * ★★ 为什么进度挂在轨道上，不挂在 `TweenSpec` 上（与 `SpriteAnimator` 同一条纪律）：
 *   同一段"淡入"会被很多界面共享（背包开启、提示弹出、面板切换）。
 *   进度若写进 spec，A 界面暂停 B 界面也停、A 重播 B 也回到起点 ——
 *   而 spec 已经是 `Object.freeze` 的共享数据，物理上也写不进去。
 *   所以：spec = 不可变资产，`timeMs` = 每实例状态，`TweenPlayer` = 一组进度。
 *
 * ★★ 为什么目标只是「不透明 id + 属性名」，而不是 `UiNode`：
 *   补间层一旦认识 UI，第二类目标（相机缩放、音量、光照强度）就得再写一套。
 *   这里只回答"哪个对象、哪个属性、现在是多少"，**值域的解释留给应用侧**：
 *   `opacity` 要钳到 0..1、`scale` 不能为负 —— 那是 UI 的语义，不是补间的语义。
 *   好处是这一层可以完全脱离 UI 单测：不需要字体、不需要皮肤、不需要 GPU。
 *
 * ★★ 为什么轨道**不进 schema**（存档里没有它）：
 *   ① schema 只能表达标量 / 字符串 / 字符串数组，表达不了"轨道列表"；
 *   ② 更要紧的是语义 —— "打开背包时淡入到一半"存下来没有意义。读档回来时
 *      目标节点可能已经不存在（界面被销毁），那会变成一条永远推进不了的轨道。
 *   所以 `playing` 进 schema（它是"这组过渡要不要继续"的开关，存下来有意义），
 *   轨道本身是运行时状态，`reset()` 负责把它清干净。
 *
 * ★ 时长按**逻辑步**指定，不按毫秒（`ticksToMs`）：与 `hitstop` 的
 *   `HITSTOP_*_TICKS`、战斗的 `cooldownTicks` 同一条口径。按毫秒写死的话，
 *   同一个"淡入 0.2 秒"在 144Hz 与 30Hz 上帧数差 4 倍，顿帧期间还会被拉长。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { makeTween, sampleTween, type TweenSpec, type TweenSpecInput } from "./tween.ts";
import { KeyTrack, makeTrack, type Keyframe, type TrackSpec } from "./keyframes.ts";

/** 组件类型常量（模块注册表与场景共用，避免两处手写字符串）。 */
export const TWEEN_PLAYER_TYPE = "tween.player";

export const TWEEN_PLAYER_ERR = {
  /** 同一 player 里轨道 id 重复（后加的那条永远不会被单独找到）。 */
  DUPLICATE_TRACK: "TWEEN.DUPLICATE_TRACK",
  /** 轨道不存在。 */
  NO_TRACK: "TWEEN.NO_TRACK",
} as const;

/** 关键帧轨道的构造入参（`spec` 换成 `keys`，其余与 `TweenTrackInput` 同形）。 */
export interface KeyTrackInput {
  readonly id: string;
  readonly targetId: string;
  readonly prop: string;
  readonly keys: readonly Keyframe[];
  readonly playing?: boolean;
  readonly autoplay?: boolean;
}

/** 一条轨道的构造入参。 */
export interface TweenTrackInput {
  /** 轨道名，同一 player 内唯一（撤销/停止/查值都用它）。 */
  readonly id: string;
  /** 目标对象的不透明标识（UI 里就是 `UiNode.id`）。 */
  readonly targetId: string;
  /** 属性名，由应用侧解释（UI 侧见 `UI_TWEEN_PROP`）。 */
  readonly prop: string;
  /** 补间本身（`makeTween` 的入参，构造时校验）。 */
  readonly spec: TweenSpecInput;
  /** 是否推进（默认 true；false = 挂上去先不动，等 `play()`）。 */
  readonly playing?: boolean;
  /** `reset()` 之后是否接着播（默认 true）。 */
  readonly autoplay?: boolean;
}

/**
 * 一条正在跑的轨道。
 *
 * ★ `timeMs` 是**这一条**的进度，不是 player 的：一组过渡里，"背景先淡、字后淡"
 *   靠的是不同的 `delayMs`，而"某个字卡住了"要靠单独 `pause()`。
 *   共用一个时钟的话，第二条能力就不存在了。
 */
export class TweenTrack {
  readonly id: string;
  readonly targetId: string;
  readonly prop: string;
  readonly spec: TweenSpec;
  /** 本轨道自己的进度（毫秒，可被 `seek` 直接改）。 */
  timeMs = 0;
  /** 是否推进时间。false 时仍可按当前 `timeMs` 采样（`seek` 之后能立刻看到结果）。 */
  playing: boolean;
  readonly autoplay: boolean;
  /** 上一次采样出来的值（判断"这一步真的变了吗"）。`NaN` = 还没采过。 */
  lastValue = Number.NaN;

  constructor(id: string, targetId: string, prop: string, spec: TweenSpec, playing: boolean, autoplay: boolean) {
    this.id = id;
    this.targetId = targetId;
    this.prop = prop;
    this.spec = spec;
    this.playing = playing;
    this.autoplay = autoplay;
  }

  /** 回到起点，并按 `autoplay` 决定是否继续播。 */
  reset(): void {
    this.timeMs = 0;
    this.lastValue = Number.NaN;
    this.playing = this.autoplay;
  }

  /**
   * 跳到指定毫秒。
   * ★ 负数夹到 0（与 `sampleTween` 的"负时间 = 还没开始"一致）；
   *   非有限数直接抛 —— 那是调用方的编程错误，不是可配置字段。
   */
  seek(ms: number): void {
    if (!Number.isFinite(ms)) {
      throw new TypeError(`TweenTrack.seek 的 ms 必须是有限数（收到 ${String(ms)}）`);
    }
    this.timeMs = ms < 0 ? 0 : ms;
  }
}

/** 一步推进的产物：某个目标上的某个属性现在应该是多少。 */
export interface TrackSample {
  readonly id: string;
  readonly targetId: string;
  readonly prop: string;
  readonly value: number;
  /** 这条轨道（有限循环）已经播完。 */
  readonly done: boolean;
  /**
   * 与上一次采样相比**值真的变了**。
   * ★ 调用方据此决定要不要标脏：静止的过渡不该每帧重排一遍 UI。
   */
  readonly changed: boolean;
}

export class TweenPlayer extends Component {
  /**
   * 整组开关。
   * ★ 它单独存在于 schema 里，是为了让存档能表达"这组过渡停在暂停态"——
   *   而轨道本身不进 schema（见文件头 ★★）。
   */
  playing = true;

  /** 运行时轨道（顺序 = 添加顺序，推进也按这个序）。 */
  readonly tracks: TweenTrack[] = [];

  /**
   * 关键帧轨道（ADR-0010 缺口①）。
   *
   * ★★ 为什么与 `tracks` **分成两个数组**，而不是让 `TweenTrack.spec` 变成可空：
   *   分段轨道的 `spec` 在十几处被直接读（`speed`、`loopCount`、`durationMs`），
   *   变成可空之后每个读点都要判空 —— 而漏判的地方**不会报错**，只会静默按关键帧
   *   轨道处理（`speed` 当成 0 ⇒ 永不推进）。两个类型不同的数组让"这是哪种轨道"
   *   在类型层面就成立，推进器里一个 `for` 循环各管一种。
   */
  readonly keyTracks: KeyTrack[] = [];

  readonly schema: ComponentSchema = {
    type: TWEEN_PLAYER_TYPE,
    fields: {
      playing: FieldType.Bool,
    },
    defaults: {
      playing: true,
    },
  };

  /**
   * 加一条轨道。构造期就把 spec 校验掉（坏配置不许留到采样期）。
   *
   * ★ 重复 id 直接拒绝：`track(id)` 只能返回第一条，第二条就成了
   *   "加进去了但永远停不下来"的幽灵 —— 而它的症状是"关掉界面后还有东西在动"。
   */
  addTrack(input: TweenTrackInput): Result<TweenTrack, EngineError> {
    if (this.tracks.some((t) => t.id === input.id)) {
      return err(
        engineError(TWEEN_PLAYER_ERR.DUPLICATE_TRACK, `轨道 id 重复：${input.id}（同一 player 内必须唯一）`, {
          id: input.id,
        }),
      );
    }
    const made = makeTween(input.spec);
    if (!made.ok) return made as Result<never, EngineError>;
    const track = new TweenTrack(
      input.id,
      input.targetId,
      input.prop,
      made.value,
      input.playing ?? true,
      input.autoplay ?? true,
    );
    this.tracks.push(track);
    return ok(track);
  }

  track(id: string): TweenTrack | undefined {
    return this.tracks.find((t) => t.id === id);
  }

  /**
   * 加一条关键帧轨道。
   * ★ id 在**两种轨道之间**也必须唯一：`pause(id)`/`play(id)` 是按 id 找的，
   *   同名会让"停下的那条"与"以为停下的那条"不是同一条。
   */
  addKeyTrack(input: KeyTrackInput): Result<KeyTrack, EngineError> {
    if (this.track(input.id) !== undefined || this.keyTrack(input.id) !== undefined) {
      return err(
        engineError(TWEEN_PLAYER_ERR.DUPLICATE_TRACK, `轨道 id 重复：${input.id}（同一 player 内必须唯一）`, {
          id: input.id,
        }),
      );
    }
    const made = makeTrack({ id: input.id, keys: input.keys });
    if (!made.ok) return made as Result<never, EngineError>;
    const spec: TrackSpec = made.value;
    const track = new KeyTrack(
      input.id,
      input.targetId,
      input.prop,
      spec,
      input.playing ?? true,
      input.autoplay ?? true,
    );
    this.keyTracks.push(track);
    return ok(track);
  }

  keyTrack(id: string): KeyTrack | undefined {
    return this.keyTracks.find((t) => t.id === id);
  }

  /** 按 id 停一条轨道（界面收起时用：进度留着，只是不再推进）。 */
  pause(id: string): Result<void, EngineError> {
    const t = this.track(id) ?? this.keyTrack(id);
    if (t === undefined) return err(engineError(TWEEN_PLAYER_ERR.NO_TRACK, `没有轨道 ${id}`));
    t.playing = false;
    return ok(undefined);
  }

  play(id: string): Result<void, EngineError> {
    const t = this.track(id) ?? this.keyTrack(id);
    if (t === undefined) return err(engineError(TWEEN_PLAYER_ERR.NO_TRACK, `没有轨道 ${id}`));
    t.playing = true;
    return ok(undefined);
  }

  /** 清空所有轨道（换界面时用）。 */
  clear(): void {
    this.tracks.length = 0;
    this.keyTracks.length = 0;
  }

  /** 所有轨道回到起点。 */
  reset(): void {
    for (const t of this.tracks) t.reset();
    for (const t of this.keyTracks) t.reset();
  }

  /** 是否还有轨道在推进（诊断/性能用：全静止就不必每帧走一遍）。 */
  get moving(): boolean {
    if (!this.playing) return false;
    if (this.tracks.some((t) => t.playing && !sampleTween(t.spec, t.timeMs).done)) return true;
    return this.keyTracks.some((t) => t.playing && !t.sample().done);
  }
}

/**
 * 把补间的**逻辑步时长**换算成毫秒。
 *
 * ★ 为什么要有这个函数：所有时长都按 tick 指定（见文件头 ★），
 *   而 `TweenSpec.durationMs` 用的是毫秒。换算只此一处，宿主不会各写一个 `* 33.33`。
 * ★ 非整数 / 非有限步数直接抛：那是配置错误，静默取整会让"配了 3.5 步"
 *   看起来像配了 3 步（与 `hitstop` 拒绝小数步数是同一条理由）。
 */
export function ticksToMs(ticks: number, fixedDtMs: number): number {
  if (!Number.isInteger(ticks) || ticks <= 0) {
    throw new TypeError(`ticksToMs 的 ticks 必须是正整数（收到 ${String(ticks)}）`);
  }
  if (!Number.isFinite(fixedDtMs) || fixedDtMs <= 0) {
    throw new TypeError(`ticksToMs 的 fixedDtMs 必须是正的有限数（收到 ${String(fixedDtMs)}）`);
  }
  return ticks * fixedDtMs;
}

/**
 * 推进一组轨道一步，返回本步的采样。
 *
 * ★★ 语义（四条，都有反例支撑）：
 *   ① `dtMs` 必须非负有限 —— 负的 dt 等于让时间倒流，而 `sampleTween` 对负时间是
 *      "夹到 0"（还没开始），于是"倒退"会表现成"回到起点后卡住"，极难归因。
 *   ② `player.playing === false` 时**一条都不推进**，但仍返回当前采样（值不变）：
 *      暂停期间界面不该停在"上一帧的值"，而应停在"这个时刻应有的值"。
 *   ③ 已 `done` 的轨道**不再累加时间**（有限循环播完停在终点）。继续累加会让
 *      `timeMs` 无界增长，几百秒后浮点精度掉到 1ms 以下，"重播"时起点会漂。
 *   ④ `changed` 只在值真的变了时为 true —— 这是宿主 `invalidate()` 的依据。
 *      没有它，静止的过渡会让整棵 UI 每帧重排（布局 O(节点数)，看着没事，
 *      但文本缓存会跟着失效，最后表现为"UI 一直很卡但看不出在动什么"）。
 */
export function advancePlayer(player: TweenPlayer, dtMs: number): TrackSample[] {
  if (!Number.isFinite(dtMs) || dtMs < 0) {
    throw new TypeError(`advancePlayer 的 dtMs 必须是非负有限数（收到 ${String(dtMs)}）`);
  }
  const out: TrackSample[] = [];
  for (const t of player.tracks) {
    const wasDone = sampleTween(t.spec, t.timeMs).done;
    // ★★ 这里**只加原始 dt，绝不乘 `spec.speed`**。
    //   `sampleTween` 已经把一段的换算时长写成 `durationMs / |speed|`，
    //   并在 `speed < 0` 时把进度取反 —— 速率是采样层的事。
    //   两边各乘一次的结果是 speed²：speed=2 时 25ms 就播完一整段，
    //   而"动作比配的更快"这种症状会被当成输入延迟查一整天。
    //   （实测：批76 第一版就是这么写的，判据 `speed=2 走 25ms 应是半程`
    //    当场所红 —— 而它的实现看起来"完全符合 tween.ts 注释里那句话"。）
    //
    // ★ `speed === 0` 单独判：采样层对 speed=0 按 1 倍处理（那是为了避免
    //   `durationMs/0 = Infinity` 让循环号恒 0 的分叉），所以"冻结"必须由
    //   推进方表达成"时间不走"。乘 0 与判 0 等价，但判 0 不会让人误以为
    //   速率还该在别处再乘一次。
    if (player.playing && t.playing && !wasDone && t.spec.speed !== 0) {
      t.timeMs += dtMs;
      if (t.timeMs < 0) t.timeMs = 0;
    }
    const s = sampleTween(t.spec, t.timeMs);
    const changed = Number.isNaN(t.lastValue) || s.value !== t.lastValue;
    t.lastValue = s.value;
    out.push({ id: t.id, targetId: t.targetId, prop: t.prop, value: s.value, done: s.done, changed });
  }
  // ★ 关键帧轨道排在后面：同一属性被两种轨道同时写时，**后者胜**。
  //   这不是"混合解析器"（那要按属性语义决定乘/加/覆盖），只是一条确定的顺序，
  //   让"同一个 player 里两种轨道并存"至少有一个可预测的结果。
  for (const t of player.keyTracks) {
    const wasDone = t.sample().done;
    if (player.playing && t.playing && !wasDone) {
      t.timeMs += dtMs;
      if (t.timeMs < 0) t.timeMs = 0;
    }
    const s = t.sample();
    const changed = Number.isNaN(t.lastValue) || s.value !== t.lastValue;
    t.lastValue = s.value;
    out.push({ id: t.id, targetId: t.targetId, prop: t.prop, value: s.value, done: s.done, changed });
  }
  return out;
}
