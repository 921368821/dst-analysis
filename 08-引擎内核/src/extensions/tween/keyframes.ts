/**
 * L4 · 属性轨道：一条属性 × 多关键帧（ADR-0010 的「缺口①」）
 *
 * `tween.ts` 表达的是**一段**（from → to，一个 easing）。四件 UI 过渡里
 * "先放大到 1.06、再落到 1.0"这种手感写不出来 —— 要两段，而且第二段必须
 * 从第一段**某一时刻**的值接着走。用两个 `TweenSpec` 拼是错的方向：
 * 第二段的 `from` 得在运行时改（第一段的终点取决于你在哪一拍切过去），
 * 而 ADR-0010 ④ 已经定死了"`from`/`to` 必须显式、不读当前值"。
 *
 * 所以关键帧是**另一种轨道**，不是"多段补间接起来"：
 *   · 时间轴是一维的（`atMs` 严格递增），不是每段各有各的时长；
 *   · 值是关键帧上的**点**，段内插值只是它们之间的一条曲线；
 *   · easing 属于"**到达**某个关键帧的那一段"（右端点语义）。
 *
 * ★★ 为什么 easing 挂在**右端点**而不是左端点：
 *   写成左端点（"离开这一帧用什么曲线"）时，最后一个关键帧的 easing 永远用不到，
 *   而"这一段落得太硬"的人会去改**左**边那个键 —— 改完没有任何反应。
 *   这与 CSS `animation-timing-function`、以及大多数编辑器的时间轴一致：
 *   选一个键，设的是"怎么走到这个键"。
 *
 * ★★ 为什么第一个关键帧**必须**在 0 毫秒（而不是"从第一个键开始播"）：
 *   允许从 500ms 起步意味着 0..500 之间没有值 —— 而调用方在 0~499ms 期间
 *   采样到的是什么？夹到第一个值（"提前 500ms 就到了"）？还是 undefined
 *   （每个调用方都得判空）？两种解释都会有人写错。
 *   拒绝掉这个配置，代价是"要等 500ms 就先 delay"（`TweenTrack` 已经有 delay 的能力），
 *   收益是"任意时刻都有定义"这条性质结构上成立。
 *
 * ★ 本文件**不**做：循环（`loopCount`/`yoyo`）、速率（`speed`）。
 *   这两个在关键帧轨道上语义与分段轨道不同构（"循环一遍关键帧"等于按总时长重播，
 *   而分段轨道的 `yoyo` 是逐段翻向），混在一个字段里必然有一边的人理解错 ——
 *   与 ADR-0010 ② 同一条理由。
 *
 * ★ 本文件**也**不做多轨合成（批117 起改由 `composite.ts` 承担）：一条关键帧轨道
 *   只携带自己的算子（`KeyTrack.composite`），"同一属性上的几条轨道怎么折成一个值"
 *   是推进器与 `composeEntries` 的事。批76~116 期间这里是"等第二个消费者再定"，
 *   现在第二个消费者到了（压暗要乘不透明度），语义按业界的 `replace|add|multiply`
 *   定在 `composite.ts` 的文件头里。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { EASINGS, type EasingFn } from "./easing.ts";
import { COMPOSITE_OP, type CompositeOp } from "./composite.ts";

export const KEYFRAME_ERR = {
  /** 少于 2 个关键帧（一个点构不成"轨道"）。 */
  TOO_FEW: "TWEEN.TOO_FEW_KEYS",
  /** 时间轴没有从 0 起步（见文件头 ★★）。 */
  NO_ORIGIN: "TWEEN.TRACK_NO_ORIGIN",
  /** `atMs` 没有严格递增（相等也不行：同一时刻两个值没有定义）。 */
  UNSORTED: "TWEEN.TRACK_UNSORTED",
  /** `atMs` 非有限或为负。 */
  BAD_AT: "TWEEN.TRACK_BAD_AT",
  /** 关键帧的值非有限。 */
  BAD_VALUE: "TWEEN.TRACK_BAD_VALUE",
  /** 引用了不存在的 easing 名。 */
  UNKNOWN_EASING: "TWEEN.UNKNOWN_EASING",
} as const;

/** 一个关键帧。`easing` 作用在"**走到**这一帧"的那一段上（第一帧的 easing 不生效）。 */
export interface Keyframe {
  readonly atMs: number;
  readonly value: number;
  readonly easing?: string;
}

/** 构造入参。 */
export interface TrackSpecInput {
  readonly id: string;
  readonly keys: readonly Keyframe[];
}

/** 不可变的关键帧轨道（可被任意多实例共享，与 `TweenSpec` 同一条纪律）。 */
export interface TrackSpec {
  readonly id: string;
  readonly keys: readonly Keyframe[];
  /** 总时长 = 最后一个关键帧的时刻。 */
  readonly durationMs: number;
}

/** 采样结果。 */
export interface KeySample {
  /** 当前值。 */
  readonly value: number;
  /** 落在第几段（`keys[segment] → keys[segment + 1]`）。到达末帧时等于 `keys.length - 2`。 */
  readonly segment: number;
  /** 段内归一化进度 [0,1)。到达末帧时为 1。 */
  readonly progress: number;
  /** 已经走到（或越过）最后一个关键帧。 */
  readonly done: boolean;
}

/** 取 easing；名字不认识时抛（配置错误，构造期就该拦住，见 `makeTrack`）。 */
function easingOf(name: string | undefined): EasingFn {
  if (name === undefined) return EASINGS.linear as EasingFn;
  const fn = EASINGS[name];
  if (fn === undefined) throw new Error(`未知缓动：${name}`);
  return fn as EasingFn;
}

/**
 * 校验并构造关键帧轨道。
 *
 * ★ 一切校验都在这里做（不在采样期）：坏配置留到采样期时，
 *   症状是"某一帧 UI 跳了一下"，而时间点取决于玩家什么时候点开界面。
 */
export function makeTrack(input: TrackSpecInput): Result<TrackSpec, EngineError> {
  const keys = input.keys;
  if (keys.length < 2) {
    return err(
      engineError(KEYFRAME_ERR.TOO_FEW, `关键帧至少要有 2 个（收到 ${String(keys.length)} 个）`, { id: input.id }),
    );
  }
  const first = keys[0] as Keyframe;
  if (!Number.isFinite(first.atMs) || first.atMs < 0) {
    return err(engineError(KEYFRAME_ERR.BAD_AT, `第一个关键帧的 atMs 非法：${String(first.atMs)}`, { id: input.id }));
  }
  if (first.atMs !== 0) {
    return err(
      engineError(KEYFRAME_ERR.NO_ORIGIN, `第一个关键帧必须在 0ms（收到 ${String(first.atMs)}ms）`, {
        id: input.id,
        atMs: first.atMs,
      }),
    );
  }
  let prev = first.atMs;
  for (const [i, k] of keys.entries()) {
    if (!Number.isFinite(k.atMs) || k.atMs < 0) {
      return err(
        engineError(KEYFRAME_ERR.BAD_AT, `第 ${String(i)} 个关键帧的 atMs 非法：${String(k.atMs)}`, { id: input.id }),
      );
    }
    if (i > 0 && !(k.atMs > prev)) {
      return err(
        engineError(
          KEYFRAME_ERR.UNSORTED,
          `第 ${String(i)} 个关键帧的 atMs=${String(k.atMs)} 必须严格大于前一个 ${String(prev)}`,
          { id: input.id },
        ),
      );
    }
    if (!Number.isFinite(k.value)) {
      return err(
        engineError(KEYFRAME_ERR.BAD_VALUE, `第 ${String(i)} 个关键帧的值非有限：${String(k.value)}`, { id: input.id }),
      );
    }
    if (i > 0 && k.easing !== undefined && EASINGS[k.easing] === undefined) {
      return err(
        engineError(KEYFRAME_ERR.UNKNOWN_EASING, `第 ${String(i)} 个关键帧引用了未知缓动：${k.easing}`, {
          id: input.id,
        }),
      );
    }
    prev = k.atMs;
  }
  // 冻结一份：入参数组是可变的，而 `TrackSpec` 承诺不可变（共享的前提）。
  const frozen: Keyframe[] = keys.map((k) =>
    k.easing === undefined ? { atMs: k.atMs, value: k.value } : { atMs: k.atMs, value: k.value, easing: k.easing },
  );
  return ok({ id: input.id, keys: Object.freeze(frozen), durationMs: prev });
}

/**
 * 采样：`ms` 时刻的值（纯函数，不缓存"上次时间"—— 与 `sampleTween` 同源）。
 *
 * 三条边界，都是"看起来显然、写起来容易差一点"的地方：
 *   ① `ms < 0` ⇒ 第一个关键帧的值（"还没开始"，不是 0）；
 *   ② `ms >= duration` ⇒ 最后一个关键帧的值，且 `done = true`（**不外插**：
 *      外插会让"播完之后画面还在慢慢漂"，而没人会去查一个已经播完的轨道）；
 *   ③ `ms` 恰等于某个关键帧时刻 ⇒ 值**精确**等于该帧的值（见下面 `progress = 0` 的用法）。
 */
export function sampleTrack(spec: TrackSpec, ms: number): KeySample {
  if (!Number.isFinite(ms)) {
    throw new TypeError(`sampleTrack 的 ms 必须是有限数（收到 ${String(ms)}）`);
  }
  const keys = spec.keys;
  const n = keys.length;
  if (ms <= 0) return { value: (keys[0] as Keyframe).value, segment: 0, progress: 0, done: false };
  if (ms >= spec.durationMs) {
    return { value: (keys[n - 1] as Keyframe).value, segment: n - 2, progress: 1, done: true };
  }
  // 线性扫（关键帧通常 < 10 个；二分会在 n 很小时引入更多分支，而分支是 bug 的住处）。
  let i = 0;
  while (i < n - 2 && (keys[i + 1] as Keyframe).atMs <= ms) i++;
  const a = keys[i] as Keyframe;
  const b = keys[i + 1] as Keyframe;
  const span = b.atMs - a.atMs;
  // 恰在 `a` 上时 progress = 0 ⇒ `easing(0) = 0` ⇒ 值精确等于 `a.value`。
  // ★ 不要写成"`ms <= a.atMs` 就特判返回 a.value"：那会让一个点在两处实现，
  //   而两边只要有一边忘了夹取，边界上就会出现一次 1 帧的跳。
  const t = span <= 0 ? 1 : (ms - a.atMs) / span;
  const eased = easingOf(b.easing)(t < 0 ? 0 : t > 1 ? 1 : t);
  return { value: a.value + (b.value - a.value) * eased, segment: i, progress: t, done: false };
}

/** 关键帧轨道的运行态（进度在这里，不在 `TrackSpec` 上 —— 与 `TweenTrack` 同一条纪律）。 */
export class KeyTrack {
  readonly id: string;
  readonly targetId: string;
  readonly prop: string;
  readonly spec: TrackSpec;
  timeMs = 0;
  playing: boolean;
  readonly autoplay: boolean;
  /** 合成算子（作用于同一属性上排在它前面的轨道，见 `composite.ts`）。 */
  readonly composite: CompositeOp;

  constructor(
    id: string,
    targetId: string,
    prop: string,
    spec: TrackSpec,
    playing: boolean,
    autoplay: boolean,
    composite: CompositeOp = COMPOSITE_OP.Replace,
  ) {
    this.id = id;
    this.targetId = targetId;
    this.prop = prop;
    this.spec = spec;
    this.playing = playing;
    this.autoplay = autoplay;
    this.composite = composite;
  }

  reset(): void {
    this.timeMs = 0;
    this.playing = this.autoplay;
  }

  seek(ms: number): void {
    if (!Number.isFinite(ms)) {
      throw new TypeError(`KeyTrack.seek 的 ms 必须是有限数（收到 ${String(ms)}）`);
    }
    this.timeMs = ms < 0 ? 0 : ms;
  }

  sample(): KeySample {
    return sampleTrack(this.spec, this.timeMs);
  }
}
