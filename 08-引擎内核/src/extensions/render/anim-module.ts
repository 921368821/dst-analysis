/**
 * L4 · 动画模块（`render.animator`）
 *
 * 职责只有两件：
 *   ① 持有 `clipId → AnimationClip` 的**只读注册表**（数据，可被任意多实体共享）；
 *   ② 每帧遍历所有 `SpriteAnimator`，推进各自时钟，把采样出的帧名写进同节点的
 *      `Sprite.frame`。
 *
 * ★★ 模块里**没有"全局当前时间"字段**，也不许有：
 *   模块实例本身就是"每世界一份"（`createAnimModule()` 每个引擎/世界调用一次），
 *   而世界的暂停、变速、读档回放都只影响自己的实例。若把时间提到模块上，
 *   同一进程里的两个世界会共用一个时钟 —— 表现是"A 世界按暂停，B 世界的怪也在原地踏步"。
 *   每实体的 `timeMs` 在组件上（sprite-animator.ts），模块只是"驱动器"。
 *
 * ★ 为什么注册表只读（不提供 unregister / replace）：
 *   clip 是共享数据，实体只保存 id。允许替换的话，"某段动画播到一半素材被换掉"
 *   会让同一个世界里两个实体看到不同的时间轴长度，而 id 还是同一个 —— 无法归因。
 *   需要新版本就换 id（与资产 GUID 同思路）。
 *
 * ★ 没有 `onUpdate` 钩子（仓库约定）：宿主在 `scheduler.onStep` 里调 `update(tick, dt)`，
 *   与 `script-module.ts` 相同（见那里的原话）。判据/回放也可以直接调 `advance(dt)`。
 *
 * ★ 找不到 clip / 找不到 Sprite 必须 warn：
 *   "某个东西不动"是这类错误唯一的外部表现；静默跳过等于把根因藏起来。
 *   日志按节点 id / clipId 做 key，由 Logger 限流，不会刷屏。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Scene } from "../../core/scene/scene.ts";
import type { Node } from "../../core/scene/node.ts";
import { Services } from "../../core/tokens.ts";
import type { AnimationClip } from "./animation.ts";
import { effectiveLoopCount, sampleClip } from "./animation.ts";
import { Sprite } from "./sprite.ts";
import { SPRITE_ANIMATOR_TYPE, SpriteAnimator } from "./sprite-animator.ts";

/** `Sprite` 的组件类型。不在 sprite.ts 里导出常量（那个文件不归本任务改），所以在此处明确一次。 */
const SPRITE_TYPE = "render.sprite";

export interface AnimModuleOptions {
  /** 模块 id。默认 `render.animator`（与 `render.batch2d` 同风格：域.实现）。 */
  readonly id?: string;
  /** 启动时预注册的 clip（等价于逐个 `registerClip`）。 */
  readonly clips?: readonly AnimationClip[];
}

export interface AnimModuleHandle extends IModule {
  /** 注册一段 clip。同一个对象重复注册是幂等的；同 id 不同数据被拒绝（见文件头）。 */
  registerClip(clip: AnimationClip): Result<void, EngineError>;
  getClip(id: string): AnimationClip | undefined;
  /** 推进所有播放器 `dtSeconds` 秒（宿主/判据用）。 */
  advance(dtSeconds: number): void;
  /** 宿主在 `scheduler.onStep` 里的入口；`tick` 不参与时间轴（每实体时钟已足够）。 */
  update(tick: number, dt: number): void;
  /** 跳转某节点的播放进度，并立刻刷新它的 `Sprite.frame`。 */
  seek(nodeId: number, ms: number): void;
  play(nodeId: number): void;
  pause(nodeId: number): void;
  readonly clipCount: number;
  readonly playerCount: number;
  init(ctx: ModuleContext): Result<void, EngineError>;
  start(): void;
  dispose(): void;
  describe(): string;
}

export function createAnimModule(opts: AnimModuleOptions = {}): AnimModuleHandle {
  let ctxRef: ModuleContext | null = null;
  /** 只读注册表：clip 不可变，实体只引用 id。 */
  const clips = new Map<string, AnimationClip>();

  function warn(message: string, fields?: Record<string, unknown>): void {
    ctxRef?.log.channel("render").warn(message, fields);
  }

  function sceneOf(): Scene | undefined {
    return ctxRef?.services.get(Services.Scene);
  }

  function registerClip(clip: AnimationClip): Result<void, EngineError> {
    const existing = clips.get(clip.id);
    if (existing !== undefined) {
      if (existing === clip) return ok(undefined);
      return err(
        engineError(
          "ANIM.DUPLICATE_CLIP",
          `clip id 重复：${clip.id}（注册表只读，不允许用另一份数据替换；新版本请换 id）`,
          { id: clip.id },
        ),
      );
    }
    clips.set(clip.id, clip);
    return ok(undefined);
  }

  /**
   * 推进单个播放器。
   * ★ 顺序是"先查 clip 再推时间"：没有 clip 就不知道该按多长绕回，先推会得到一个
   *   无法解释的 timeMs（下一帧注册了 clip 后会从一个奇怪的位置开始）。
   */
  function stepOne(c: SpriteAnimator, dtSeconds: number): void {
    const node = c.node;
    if (node === null) {
      warn(`动画：SpriteAnimator 不在任何节点上（clipId=${JSON.stringify(c.clipId)}）`, {
        clipId: c.clipId,
      });
      return;
    }
    // 显式禁用/失活 = 冻结，是用户意图，不是配置错误 —— 不 warn。
    if (!c.enabled || !node.activeInHierarchy) return;

    const clip = clips.get(c.clipId);
    if (clip === undefined) {
      warn(`动画：clip 不存在 ${JSON.stringify(c.clipId)}（节点 ${node.id} 停在当前帧）`, {
        node: node.id,
        clipId: c.clipId,
      });
      return;
    }

    if (c.playing) integrate(c, clip, dtSeconds);
    // 即使暂停也要按当前 timeMs 刷新一次：seek / 换 clip 之后画面必须立刻对，
    // 而帧名是"算出来的"，不是缓存的。
    writeFrame(c, node, clip);
  }

  /**
   * 时间积分 + 边界处理。
   *
   * ★ 无限循环且时间为负时绕回 `[0, total)`：
   *   这是倒放（speed < 0）能"绕过起点"的唯一位置。`sampleClip` 对负时间按 0
   *   处理（语义是"还没开始"），所以采样函数自己不会环绕；时间轴管理归模块。
   *   不绕的话，倒放会在 0 处永远卡住 —— 素材明明是循环的，却只能播半轮。
   * ★ 有限循环夹在 `[0, total*k]`：
   *   播完后不夹的话，挂机几小时后 timeMs 会累加到浮点精度开始丢毫秒，
   *   而且这个数字对采样没有意义（`sampleClip` 到终点就不再变）。
   *   夹住后，之后把 loopOverride 调大仍能从终点继续播放，状态不丢。
   */
  function integrate(c: SpriteAnimator, clip: AnimationClip, dtSeconds: number): void {
    c.timeMs += dtSeconds * 1000 * c.speed;
    const total = clip.totalDurationMs;
    const loops = effectiveLoopCount(clip, c.loopOverride);

    if (loops === 0) {
      if (c.timeMs < 0) c.timeMs = ((c.timeMs % total) + total) % total;
      return;
    }
    if (c.timeMs < 0) {
      c.timeMs = 0;
      return;
    }
    const end = total * loops;
    if (c.timeMs > end) c.timeMs = end;
  }

  function writeFrame(c: SpriteAnimator, node: Node, clip: AnimationClip): void {
    const sprite = node.get<Sprite>(SPRITE_TYPE);
    if (sprite === undefined) {
      warn(`动画：节点 ${node.id} 没有 render.sprite，帧名无处可写（clipId=${JSON.stringify(c.clipId)}）`, {
        node: node.id,
        clipId: c.clipId,
      });
      return;
    }
    // 采样参数就是"clip + 本实体时间 + 本实体循环覆盖"，没有第二份采样逻辑
    const sample = sampleClip(clip, c.timeMs, c.loopOverride);
    sprite.frame = sample.frame;
  }

  function animatorOf(nodeId: number, action: string): SpriteAnimator | undefined {
    const scene = sceneOf();
    const node = scene?.find(nodeId);
    const c = node?.get<SpriteAnimator>(SPRITE_ANIMATOR_TYPE);
    if (c === undefined) {
      warn(
        `动画：${action} 找不到节点 ${nodeId} 上的 SpriteAnimator（` +
          `${node === undefined ? "节点不存在" : "节点未挂该组件"}）`,
        { node: nodeId, action },
      );
    }
    return c;
  }

  function seek(nodeId: number, ms: number): void {
    const c = animatorOf(nodeId, "seek");
    if (c === undefined) return;
    c.seek(ms);
    const clip = clips.get(c.clipId);
    if (clip === undefined) {
      warn(`动画：seek 后找不到 clip ${JSON.stringify(c.clipId)}（节点 ${nodeId} 帧名未更新）`, {
        node: nodeId,
        clipId: c.clipId,
      });
      return;
    }
    const node = c.node;
    if (node !== null) writeFrame(c, node, clip);
  }

  function setPlaying(nodeId: number, playing: boolean): void {
    const c = animatorOf(nodeId, playing ? "play" : "pause");
    if (c !== undefined) c.playing = playing;
  }

  function advance(dtSecondsValue: number): void {
    const ctx = ctxRef;
    if (ctx === null) return; // init 之前没有 log 可用，也就没有世界可推进
    if (!Number.isFinite(dtSecondsValue)) {
      // 宿主把 NaN/Infinity 当 dt：推进会让 timeMs 永久变成 NaN，必须先挡住
      ctx.log.channel("render").warn(
        `动画：advance 收到非有限 dt（${String(dtSecondsValue)}），本帧不推进`,
        undefined,
        null,
      );
      return;
    }
    const scene = ctx.services.get(Services.Scene);
    if (scene === undefined) {
      ctx.log.channel("render").warn("动画模块缺少 core.scene 服务，无法推进（接线缺失）", undefined, null);
      return;
    }
    const list = scene.componentsOf<SpriteAnimator>(SPRITE_ANIMATOR_TYPE);
    for (const c of list) stepOne(c, dtSecondsValue);
  }

  function countPlayers(): number {
    return sceneOf()?.componentsOf<SpriteAnimator>(SPRITE_ANIMATOR_TYPE).length ?? 0;
  }

  const mod: AnimModuleHandle = {
    id: opts.id ?? "render.animator",
    deps: [],

    init(ctx: ModuleContext): Result<void, EngineError> {
      ctxRef = ctx;
      if (!ctx.services.has(Services.Scene)) {
        ctxRef = null;
        return err(
          engineError("ANIM.NO_SCENE", "动画模块需要 core.scene 服务：没有世界可推进（接线缺失，不静默运行）"),
        );
      }
      for (const clip of opts.clips ?? []) {
        const r = registerClip(clip);
        if (!r.ok) {
          ctxRef = null;
          return r;
        }
      }
      ctx.log.channel("render").info(`动画模块就绪：注册 ${clips.size} 个 clip`);
      return ok(undefined);
    },

    /** 世界已建好：登记组件类型（只动注册表，不动节点树）。 */
    start(): void {
      const scene = sceneOf();
      if (scene !== undefined && !scene.components.has(SPRITE_ANIMATOR_TYPE)) {
        scene.components.register(new SpriteAnimator().schema, () => new SpriteAnimator());
      }
    },

    dispose(): void {
      // 只清自己的注册表；组件状态在场景里，归场景/存档管
      clips.clear();
      ctxRef = null;
    },

    describe(): string {
      return `动画：${clips.size} 个 clip / ${countPlayers()} 个播放器`;
    },

    registerClip,
    getClip(id: string): AnimationClip | undefined {
      return clips.get(id);
    },
    advance,
    update(_tick: number, dt: number): void {
      advance(dt);
    },
    seek,
    play(nodeId: number): void {
      setPlaying(nodeId, true);
    },
    pause(nodeId: number): void {
      setPlaying(nodeId, false);
    },

    get clipCount(): number {
      return clips.size;
    },
    get playerCount(): number {
      return countPlayers();
    },
  };

  return mod;
}
