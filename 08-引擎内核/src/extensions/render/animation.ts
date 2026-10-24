/**
 * L4 · 渲染 · 动画时间轴（纯数据 + 纯采样）
 *
 * 这里只回答两个问题：
 *   ① 一段动画"由哪些帧、各显示多久、循环几次"组成 —— `AnimationClip`；
 *   ② 给定一个时刻，"现在该显示第几帧" —— `sampleClip`。
 *
 * ★★ 为什么 clip 里没有 atlas / GPU 句柄 / 计时器：
 *   动画数据是**资产**，会被多个世界、多个实体共享。一旦把"播放进度"放进 clip，
 *   两个世界就共用一个时钟：A 世界暂停，B 世界的同一段动作也会停。
 *   所以 clip 只存**帧名字符串**（与 `Sprite.frame` 同一命名空间）+ 时长表，
 *   播放进度由每个实体自己的 `SpriteAnimator.timeMs` 承担（见 sprite-animator.ts）。
 *   这和 `Sprite` 只存 `atlasId`/`frame`、不存 `TextureHandle` 是同一条纪律。
 *
 * ★ 为什么帧名允许重复：
 *   APNG 的 timeline 本身就是"帧序列 + 每帧时长"，同一个合成画面可以在不同位置
 *   出现多次（例如"闭眼 100ms、睁眼 30ms、闭眼 100ms"）。强制唯一会逼调用方
 *   拆成"唯一帧表 + 下标时间表"，多一层映射就多一处可以写错的地方。
 *   重复名在图集里仍只是同一个矩形，采样返回同一个字符串 —— 没有额外语义。
 *
 * ★ 为什么采样是纯函数、且不持有"上次时间"：
 *   采样一旦有状态，"两次采样之间发生了什么"就依赖调用顺序；而引擎里同一帧
 *   可能有多个消费者（渲染、调试面板、回放校验）各自采样。纯函数让它们
 *   互相不可见。模块里也不许缓存"上次采样时间"来偷懒 —— 那会让 seek 之后
 *   的第一帧取决于缓存的陈旧值。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";

/** 不可变的动画片段（纯数据）。 */
export interface AnimationClip {
  /** 稳定 id（存档/组件引用它，不是对象引用）。 */
  readonly id: string;
  /** 帧名，按播放顺序；可重复（见文件头）。 */
  readonly frames: readonly string[];
  /** 每帧显示时长（毫秒），与 `frames` 同序且同长。 */
  readonly durationsMs: readonly number[];
  /** 循环次数：0 = 无限循环（与 PNG acTL.num_plays 同义）。 */
  readonly loopCount: number;
  /** 一轮总时长（毫秒）。构造时算好：采样在每帧热路径上，不该每次 reduce。 */
  readonly totalDurationMs: number;
}

/** 构造入参：`totalDurationMs` 由构造器算，不接受外部传入（避免两处不一致）。 */
export interface AnimationClipInput {
  readonly id: string;
  readonly frames: readonly string[];
  readonly durationsMs: readonly number[];
  /** 缺省 0 = 无限循环。 */
  readonly loopCount?: number;
}

/**
 * 校验并构造 clip。
 *
 * ★ 为什么"总时长为 0"必须在这里拒绝，而不是让采样返回第 0 帧：
 *   采样要把时间对总时长取模/相除，总时长为 0 时那是除零。放行的话，
 *   症状是 NaN 帧号 → `frames[NaN]` → undefined → 渲染层报"帧名不存在"，
 *   根因（素材有一帧时长为 0 / 解码出全零延迟）会被这层噪声盖掉。
 */
export function makeAnimationClip(input: AnimationClipInput): Result<AnimationClip, EngineError> {
  if (input.frames.length === 0) {
    return err(engineError("ANIM.EMPTY_CLIP", "动画没有帧（空帧表），无法构成时间轴", { id: input.id }));
  }
  if (input.durationsMs.length !== input.frames.length) {
    return err(
      engineError(
        "ANIM.LENGTH_MISMATCH",
        `帧数与时长数不一致：${input.frames.length} 帧 / ${input.durationsMs.length} 个时长`,
        { id: input.id },
      ),
    );
  }
  for (let i = 0; i < input.durationsMs.length; i++) {
    const d = input.durationsMs[i]!;
    if (!Number.isFinite(d) || d < 0) {
      return err(
        engineError("ANIM.BAD_DURATION", `第 ${i} 帧时长非法：${String(d)}（必须是 >= 0 的有限数）`, {
          id: input.id,
          index: i,
        }),
      );
    }
  }

  const loopCount = input.loopCount ?? 0;
  // loopCount 没有单独的 ANIM.* 码在需求里，但它是采样乘法的输入：
  // NaN 会让 `t >= total*k` 恒为 false（永远不会 done），负数会让循环号变负。
  // 在这里拒绝，比让错误传播到 HUD 上的"循环 -3 次"便宜得多。
  if (!Number.isInteger(loopCount) || loopCount < 0) {
    return err(
      engineError("ANIM.BAD_LOOP", `loopCount 必须是非负整数：${String(loopCount)}（0 = 无限循环）`, {
        id: input.id,
      }),
    );
  }

  // 左到右累加：浮点求和不满足结合律，固定顺序才能让两次构造逐项相同
  let total = 0;
  for (const d of input.durationsMs) total += d;
  if (total <= 0) {
    return err(
      engineError("ANIM.ZERO_DURATION", "所有帧时长都是 0：采样会除零/卡死，拒绝构造", { id: input.id }),
    );
  }

  // ★ 冻结而不是只靠 readonly 类型：clip 会被多个世界共享，运行时一次
  //   `(clip.frames as string[]).push(...)` 就能同时改掉所有世界的动画。
  //   readonly 只在编译期有效，跨世界共享需要运行期也挡住。
  const frames = Object.freeze([...input.frames]);
  const durationsMs = Object.freeze([...input.durationsMs]);
  return ok(
    Object.freeze({
      id: input.id,
      frames,
      durationsMs,
      loopCount,
      totalDurationMs: total,
    }),
  );
}

/** 采样结果（纯值，不含任何引用）。 */
export interface ClipSample {
  readonly frame: string;
  readonly index: number;
  /** 第几次循环（从 0 开始）。有限循环播完后是最后一次的下标。 */
  readonly loop: number;
  /** 有限循环且已播完：true。无限循环永远是 false。 */
  readonly done: boolean;
}

/**
 * 有效循环次数：`override >= 0` 时覆盖 clip 的 loopCount，否则（含 -1）用 clip 的。
 *
 * ★ 为什么是"宽容"而不是抛：`loopOverride` 是组件字段，可能被脚本/编辑器写成
 *   128.5 或 NaN。采样在每实体热路径上，为一个坏字段让整帧崩掉，会把
 *   "这个实体循环次数写错了"升级成"游戏卡住"。退回 clip 的循环次数是可播放的，
 *   而且字段来源（`SpriteAnimator.loopOverride`）在 schema 里已经是 Int。
 *   （对比：`timeMs` 非有限会抛 —— 那不是字段配置问题，而是宿主把 NaN 传进了
 *   时间轴，继续算只会把 NaN 永久写进实体。）
 */
export function effectiveLoopCount(clip: AnimationClip, override: number): number {
  return Number.isInteger(override) && override >= 0 ? override : clip.loopCount;
}

/**
 * 采样：`timeMs` 时刻应显示哪一帧。
 *
 * ★ 负时间按 0 处理，**不环绕**：
 *   负时间的语义是"还没开始"（例如 `timeMs` 从 0 减去一点 dt 的浮点误差，
 *   或者 seek 到了起点之前）。如果对它取模，-1ms 会变成"最后一帧"，
 *   动画会先闪一下结尾再回开头 —— 这不是"倒放"，是假的环绕。
 *   真正需要倒放时，调用方把 speed 设为负并让时间从正值往下走；
 *   无限循环下的负数由模块绕回（见 anim-module.ts），采样函数本身不做时间管理。
 *
 * ★ 零时长帧：用**累积起点**查找，不做除法。
 *   直觉实现是 `index = floor(t / durations[index])`，这会碰到除零；
 *   而"落在哪个累积区间"与除法是同一个几何事实：从 0 累加，第一个
 *   `local < accEnd` 的帧就是答案；时长为 0 的帧区间为空（accEnd 不前进），
 *   自然被跳过。总时长 > 0 由构造期保证，所以一定能找到一帧。
 *
 * ★ 非有限时间抛 TypeError，不返回 Result：
 *   这是**调用方的编程错误**（宿主把 NaN/Infinity 当 dt 传进来），按仓库约定
 *   "不变量被破坏 → throw"。返回一个假帧会让 NaN 静默扩散成"某个动画卡住"。
 */
export function sampleClip(
  clip: AnimationClip,
  timeMs: number,
  loopCountOverride = -1,
): ClipSample {
  if (!Number.isFinite(timeMs)) {
    throw new TypeError(`sampleClip 的 timeMs 必须是有限数（收到 ${String(timeMs)}）`);
  }
  const loopCount = effectiveLoopCount(clip, loopCountOverride);
  const total = clip.totalDurationMs;
  // 负时间 = 还没开始（见上）
  const t = timeMs < 0 ? 0 : timeMs;

  if (loopCount === 0) {
    const loop = Math.floor(t / total);
    const index = indexAt(clip, t - loop * total);
    return { frame: clip.frames[index]!, index, loop, done: false };
  }

  if (t >= total * loopCount) {
    // 有限循环播完：停在"最后一帧"。
    // ★ 取**最后一个时长 > 0** 的帧，而不是字面 `frames.length - 1`：
    //   末尾的 0ms 帧从未上过屏，停在它上面等于显示一张从未出现过的图。
    const index = lastDisplayableIndex(clip);
    return { frame: clip.frames[index]!, index, loop: loopCount - 1, done: true };
  }

  const loop = Math.floor(t / total);
  const index = indexAt(clip, t - loop * total);
  return { frame: clip.frames[index]!, index, loop, done: false };
}

/** 落在 `[0, total)` 内的 `local` 对应哪一帧（零时长帧自然跳过）。 */
function indexAt(clip: AnimationClip, local: number): number {
  let acc = 0;
  for (let i = 0; i < clip.durationsMs.length; i++) {
    const d = clip.durationsMs[i]!;
    // 0ms 帧的区间是空的：不累加、不比较，直接看下一帧
    if (d <= 0) continue;
    acc += d;
    if (local < acc) return i;
  }
  // total > 0 保证上面必然命中；走到这里是"clip 被运行时篡改"级别的 bug
  return clip.frames.length - 1;
}

function lastDisplayableIndex(clip: AnimationClip): number {
  for (let i = clip.durationsMs.length - 1; i >= 0; i--) {
    if (clip.durationsMs[i]! > 0) return i;
  }
  return clip.frames.length - 1;
}

/**
 * `buildAtlasFromApng` 返回值的**结构子集**。
 *
 * ★ 用结构化接口而不是 import `ApngAtlasResult`：
 *   `atlas-from-apng.ts` 会 re-export 本函数（便捷入口），若这里反向 import
 *   它的类型，两个文件之间就有环。类型子集也让本函数可以被任何"帧名 + 时长 +
 *   循环数"的来源复用（APNG 之外还有序列帧资产），不必伪造一个图集。
 */
export interface FrameTimelineSource {
  readonly frameNames: readonly string[];
  readonly frameDurationsMs: readonly number[];
  readonly loopCount: number;
}

/**
 * 从"拼好的图集结果"生成 clip。
 *
 * ★ 刻意**不接收** `atlas` 字段：clip 只认帧名字符串。把 `AtlasData` 放进来
 *   等于把像素（几十 MB）塞进可序列化的动画组件引用里，而且同一份帧数据
 *   会因为世界不同而被复制。渲染模块按 `Sprite.atlasId` 自己找图集。
 */
export function clipFromApngResult(
  result: FrameTimelineSource,
  id: string,
): Result<AnimationClip, EngineError> {
  return makeAnimationClip({
    id,
    frames: result.frameNames,
    durationsMs: result.frameDurationsMs,
    loopCount: result.loopCount,
  });
}
