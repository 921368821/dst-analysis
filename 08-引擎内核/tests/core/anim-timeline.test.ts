/**
 * L4 · 动画时间轴判据
 *
 * 守两类缺陷：
 *  ① **时间轴本身算错**：边界（0 / 每帧起点 / 恰好 total / 超出）、零时长帧、
 *     负时间、有限循环的 done、倒放绕回。这类错误的表现都是"动画看起来在动，
 *     但停在了不该停的帧上"，没有逐点判据根本发现不了。
 *  ② **时间状态被放到了共享数据上**：同一份 clip 在两个世界里必须以各自的 dt
 *     推进。这是本任务的核心约束 —— 如果 `timeMs` 被放进 clip / 图集 / 模块级
 *     单例，下面的"双世界隔离"会立刻变红（而且症状在真实游戏里是"A 世界暂停，
 *     B 世界跟着停"，极难归因）。
 *
 * ★ 反例不是"把期望写错"，而是构造一个**只有正确实现才会通过的输入**：
 *   首帧 0ms + 有限循环的 clip（见"零时长帧"用例）。不跳过空区间的实现会在
 *   t=0 / t=total 返回第一帧，这条就红。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import type { EngineError, Result } from "../../src/foundation/result.ts";
import { Logger, LogLevel, MemorySink } from "../../src/foundation/log/logger.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { BackendRegistry } from "../../src/platform/registry.ts";
import { createPlatform } from "../../src/platform/platform.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { SystemClock } from "../../src/foundation/time/clock.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import {
  clipFromApngResult,
  makeAnimationClip,
  sampleClip,
  type AnimationClip,
} from "../../src/extensions/render/animation.ts";
import { SpriteAnimator } from "../../src/extensions/render/sprite-animator.ts";
import { createAnimModule, type AnimModuleHandle } from "../../src/extensions/render/anim-module.ts";
import { buildAtlasFromApng, clipFromApngResult as clipFromAtlas } from "../../src/extensions/render/atlas-from-apng.ts";
import { decodeApng } from "../../src/extensions/asset-import/decode/apng.ts";

const DIR = fileURLToPath(new URL("../fixtures/png/", import.meta.url));

function must<T>(r: Result<T, EngineError>): T {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function read(name: string): Uint8Array {
  return new Uint8Array(readFileSync(DIR + name));
}

/** 测试用 clip：a 100ms / b 200ms / c 500ms，默认无限循环（total=800）。 */
function walkClip(loopCount = 0): AnimationClip {
  return must(
    makeAnimationClip({
      id: "walk",
      frames: ["a", "b", "c"],
      durationsMs: [100, 200, 500],
      loopCount,
    }),
  );
}

// ---------------------------------------------------------------- 世界 harness

interface World {
  readonly scene: Scene;
  readonly mod: AnimModuleHandle;
  readonly sink: MemorySink;
}

function makeWorld(): World {
  const components = new ComponentRegistry();
  // Sprite 的 schema 由渲染层注册；这里手动登记，模拟真实宿主
  components.register(new Sprite().schema, () => new Sprite());
  components.register(new SpriteAnimator().schema, () => new SpriteAnimator());
  const scene = new Scene("world", components);

  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");

  const sink = new MemorySink();
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Info);
  log.addSink(sink);

  const backends = new BackendRegistry();
  registerNullBackends(backends);
  const platform = createPlatform({
    id: "test",
    interactive: false,
    registry: backends,
    clock: new SystemClock(),
  });
  if (!platform.ok) throw new Error("测试平台起不来：" + platform.error.message);

  const ctx: ModuleContext = {
    log,
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: platform.value,
    random: new XorShift128(1),
    module: () => undefined,
  };

  const mod = createAnimModule();
  const r = mod.init(ctx);
  if (!r.ok) throw new Error("动画模块起不来：" + r.error.message);
  mod.start();

  return { scene, mod, sink };
}

interface Player {
  readonly nodeId: number;
  readonly sprite: Sprite;
  readonly animator: SpriteAnimator;
}

/** 生成"同节点 = Sprite + SpriteAnimator"，并 flush 进场景的类型索引。 */
function addPlayer(
  w: World,
  clipId: string,
  opts: { speed?: number; loopOverride?: number; playing?: boolean; frame?: string } = {},
): Player {
  const node = w.scene.spawnImmediate("player");
  const sprite = new Sprite();
  sprite.frame = opts.frame ?? "";
  const animator = new SpriteAnimator();
  animator.clipId = clipId;
  if (opts.speed !== undefined) animator.speed = opts.speed;
  if (opts.loopOverride !== undefined) animator.loopOverride = opts.loopOverride;
  if (opts.playing !== undefined) animator.playing = opts.playing;

  assert.ok(w.scene.attach(node.id, () => sprite).ok, "挂 Sprite 失败");
  assert.ok(w.scene.attach(node.id, () => animator).ok, "挂 SpriteAnimator 失败");
  w.scene.flush();
  return { nodeId: node.id, sprite, animator };
}

// ---------------------------------------------------------------- clip 构造

test("makeAnimationClip：四类错误码各一条（+ 非整数 loopCount 也拒绝）", () => {
  const cases: ReadonlyArray<{ what: string; input: Parameters<typeof makeAnimationClip>[0]; code: string }> = [
    {
      what: "空帧表",
      input: { id: "x", frames: [], durationsMs: [], loopCount: 0 },
      code: "ANIM.EMPTY_CLIP",
    },
    {
      what: "帧数与时长数不一致",
      input: { id: "x", frames: ["a", "b"], durationsMs: [100], loopCount: 0 },
      code: "ANIM.LENGTH_MISMATCH",
    },
    {
      what: "NaN 时长",
      input: { id: "x", frames: ["a"], durationsMs: [Number.NaN], loopCount: 0 },
      code: "ANIM.BAD_DURATION",
    },
    {
      what: "负时长",
      input: { id: "x", frames: ["a"], durationsMs: [-1], loopCount: 0 },
      code: "ANIM.BAD_DURATION",
    },
    {
      what: "全零时长",
      input: { id: "x", frames: ["a", "b"], durationsMs: [0, 0], loopCount: 0 },
      code: "ANIM.ZERO_DURATION",
    },
    {
      what: "loopCount 非整数",
      input: { id: "x", frames: ["a"], durationsMs: [10], loopCount: 1.5 },
      code: "ANIM.BAD_LOOP",
    },
  ];

  for (const c of cases) {
    const r = makeAnimationClip(c.input);
    assert.equal(r.ok, false, `${c.what} 应当失败`);
    if (!r.ok) assert.equal(r.error.code, c.code, `${c.what} 的错误码不对：${r.error.message}`);
  }
});

test("makeAnimationClip：重复帧名允许（同一块图可以被时间轴引用多次）", () => {
  const c = must(
    makeAnimationClip({ id: "blink", frames: ["eye", "eye", "open"], durationsMs: [50, 50, 100], loopCount: 0 }),
  );
  assert.equal(c.totalDurationMs, 200);
  assert.equal(sampleClip(c, 75).frame, "eye");
  assert.equal(sampleClip(c, 75).index, 1, "时间落在第二段，即使帧名与第一段相同");
  assert.equal(sampleClip(c, 150).frame, "open");
});

test("makeAnimationClip：clip 是不可变数据（跨世界共享，运行期也不许改）", () => {
  const c = walkClip();
  assert.ok(Object.isFrozen(c));
  assert.ok(Object.isFrozen(c.frames));
  assert.ok(Object.isFrozen(c.durationsMs));
  assert.throws(() => (c.frames as unknown as string[]).push("x"), TypeError);
});

// ---------------------------------------------------------------- 采样边界

test("sampleClip：t=0 / 每帧起点 / 恰好 total / 超出 total（无限循环）", () => {
  const c = walkClip(0);
  const at = (t: number) => sampleClip(c, t);

  assert.deepEqual(at(0), { frame: "a", index: 0, loop: 0, done: false });
  assert.deepEqual(at(99.999), { frame: "a", index: 0, loop: 0, done: false });
  assert.deepEqual(at(100), { frame: "b", index: 1, loop: 0, done: false }, "100 是 b 的起点");
  assert.deepEqual(at(299.999), { frame: "b", index: 1, loop: 0, done: false });
  assert.deepEqual(at(300), { frame: "c", index: 2, loop: 0, done: false }, "300 是 c 的起点");
  assert.deepEqual(at(799.999), { frame: "c", index: 2, loop: 0, done: false });

  // 恰好等于总时长：第二轮的第 0 帧，不是"停在最后一帧"（无限循环）
  assert.deepEqual(at(800), { frame: "a", index: 0, loop: 1, done: false });
  // 超出若干轮：时间按总时长取模，loop 记录轮次
  assert.deepEqual(at(1700), { frame: "b", index: 1, loop: 2, done: false });
  assert.equal(at(Number.MAX_SAFE_INTEGER / 1e6).done, false, "无限循环永远不 done");
});

test("sampleClip：零时长帧被跳过（首帧 0ms 时 t=0 得第二帧）", () => {
  const c = must(
    makeAnimationClip({ id: "zero-first", frames: ["a", "b"], durationsMs: [0, 100], loopCount: 0 }),
  );
  assert.equal(c.totalDurationMs, 100);

  // ★ 反例守的缺陷：若实现不跳过零时长帧（例如直接按 frames 下标均分，
  //   或用 0ms 帧做 `floor(t / duration)`），t=0 会返回 "a" —— 一条永不上屏的帧。
  assert.deepEqual(sampleClip(c, 0), { frame: "b", index: 1, loop: 0, done: false });
  assert.equal(sampleClip(c, 99.999).frame, "b");
  // 第二轮同样跳过首帧
  assert.deepEqual(sampleClip(c, 100), { frame: "b", index: 1, loop: 1, done: false });

  // 中间的空区间也不能"占位"
  const mid = must(
    makeAnimationClip({ id: "zero-mid", frames: ["a", "b", "c"], durationsMs: [100, 0, 100], loopCount: 0 }),
  );
  assert.equal(sampleClip(mid, 99.999).frame, "a");
  assert.equal(sampleClip(mid, 100).frame, "c", "b 是 0ms，100ms 应直接进入 c");
});

test("反例：首帧 0ms + 有限循环（按 total 累积、而不是按 loopCount 截断才会过）", () => {
  const c = must(
    makeAnimationClip({ id: "zero-first-once", frames: ["a", "b"], durationsMs: [0, 100], loopCount: 1 }),
  );
  assert.equal(c.totalDurationMs, 100);

  // ★ 实现若不跳过零时长帧，t=0 会返回 "a"，这里立刻红。
  // ★ 实现若把"播完"判据写成"帧下标 >= loopCount"（而不是 `t >= total*k`），
  //   在 t=100 会返回 "a"（下标 0）而不是 done 的 "b"，同样红。
  assert.deepEqual(sampleClip(c, 0), { frame: "b", index: 1, loop: 0, done: false });
  assert.deepEqual(sampleClip(c, 100), { frame: "b", index: 1, loop: 0, done: true });
  assert.deepEqual(sampleClip(c, 100.001), { frame: "b", index: 1, loop: 0, done: true });
});

test("sampleClip：负时间 = 还没开始（取第 0 帧，不环绕到结尾）", () => {
  const c = walkClip(0);
  assert.deepEqual(sampleClip(c, -1), { frame: "a", index: 0, loop: 0, done: false });
  assert.deepEqual(sampleClip(c, -99999), { frame: "a", index: 0, loop: 0, done: false });
});

test("sampleClip：有限循环播完 done=true 并停在最后一帧；t=total*k-0.001 时还没完", () => {
  const c = walkClip(2);
  assert.deepEqual(sampleClip(c, 1599.999), { frame: "c", index: 2, loop: 1, done: false });
  assert.deepEqual(sampleClip(c, 1600), { frame: "c", index: 2, loop: 1, done: true });
  assert.deepEqual(sampleClip(c, 9600), { frame: "c", index: 2, loop: 1, done: true }, "超出后仍停在最后一帧");

  const once = walkClip(1);
  assert.equal(sampleClip(once, 799.999).done, false);
  assert.equal(sampleClip(once, 800).done, true);
  assert.equal(sampleClip(once, 800).loop, 0);

  // 无限循环同样位置不 done
  assert.equal(sampleClip(walkClip(0), 9600).done, false);
});

test("sampleClip：loopCountOverride 可以覆盖 clip 的循环次数（0 也能覆盖成无限）", () => {
  const infinite = walkClip(0);
  assert.deepEqual(sampleClip(infinite, 1600, 1), { frame: "c", index: 2, loop: 0, done: true });
  const once = walkClip(1);
  assert.deepEqual(sampleClip(once, 800, 0), { frame: "a", index: 0, loop: 1, done: false });
  // -1 = 用 clip 的
  assert.equal(sampleClip(once, 800, -1).done, true);
});

test("sampleClip：NaN / Infinity 抛 TypeError（纯函数不返回假帧）", () => {
  const c = walkClip(0);
  assert.throws(() => sampleClip(c, Number.NaN), TypeError);
  assert.throws(() => sampleClip(c, Number.POSITIVE_INFINITY), TypeError);
  assert.throws(() => sampleClip(c, Number.NEGATIVE_INFINITY), TypeError);
});

// ---------------------------------------------------------------- 双世界隔离

test("双世界隔离：同一 clip、两个 Scene / 两个模块，各自 dt 推进互不影响", () => {
  const shared = walkClip(0);
  const wA = makeWorld();
  const wB = makeWorld();
  assert.ok(wA.mod.registerClip(shared).ok);
  assert.ok(wB.mod.registerClip(shared).ok, "同一份 clip 对象可以注册到两个世界（它是数据）");

  const a = addPlayer(wA, "walk");
  const b = addPlayer(wB, "walk");

  // A 推 1 次 250ms；B 推 3 次共 750ms（不同 dt 序列）
  wA.mod.advance(0.25);
  wB.mod.advance(0.25);
  wB.mod.advance(0.25);
  wB.mod.advance(0.25);

  assert.equal(a.sprite.frame, sampleClip(shared, 250).frame, "A 的帧必须等于用 250ms 独立采样的结果");
  assert.equal(b.sprite.frame, sampleClip(shared, 750).frame, "B 的帧必须等于用 750ms 独立采样的结果");
  assert.equal(a.sprite.frame, "b");
  assert.equal(b.sprite.frame, "c");
  assert.notEqual(a.sprite.frame, b.sprite.frame, "两个世界播同一素材，进度必须不同");
  assert.equal(a.animator.timeMs, 250);
  assert.equal(b.animator.timeMs, 750);

  // A 回到开头：不能影响 B
  wA.mod.seek(a.nodeId, 0);
  assert.equal(a.sprite.frame, "a", "seek 应立刻刷新帧（不用等下一帧）");
  assert.equal(b.sprite.frame, "c", "A seek(0) 之后 B 必须还在原处");
  assert.equal(b.animator.timeMs, 750);
});

test("确定性：同样的 dt 序列跑两遍，帧序列逐项相同", () => {
  const seq = [0.016, 0.033, 0.1, 0.25, 0.5, 0.001];
  const run = (): string[] => {
    const w = makeWorld();
    assert.ok(w.mod.registerClip(walkClip(0)).ok);
    const p = addPlayer(w, "walk");
    const frames: string[] = [];
    for (const dt of seq) {
      w.mod.advance(dt);
      frames.push(p.sprite.frame);
    }
    return frames;
  };
  const first = run();
  const second = run();
  assert.deepEqual(first, second);
  // 防止判据退化成"所有帧都相同"（那样任何死实现都能过）
  assert.ok(new Set(first).size > 1, `帧序列没有变化，判据失效：${first.join(",")}`);
});

// ---------------------------------------------------------------- 每实体覆盖 / 倒放

test("loopOverride=1：本来无限循环的 clip 在实例上只播一次并停在最后一帧", () => {
  const c = walkClip(0);
  const w = makeWorld();
  assert.ok(w.mod.registerClip(c).ok);
  const p = addPlayer(w, "walk", { loopOverride: 1 });

  // 1600ms 时，无限循环会回到第 0 帧 —— 先证明"素材本身会绕回去"
  assert.equal(sampleClip(c, 1600).frame, "a");

  w.mod.advance(1.6);
  assert.equal(p.sprite.frame, "c", "override=1 后 1600ms 必须停在最后一帧，而不是回到 a");
  w.mod.advance(10);
  assert.equal(p.sprite.frame, "c", "播完后继续推进仍停在最后一帧");
});

test("倒放（speed<0）在无限循环下绕过起点：-50ms 绕到 750ms 的最后一帧", () => {
  const w = makeWorld();
  assert.ok(w.mod.registerClip(walkClip(0)).ok);
  const p = addPlayer(w, "walk", { speed: -1 });

  w.mod.seek(p.nodeId, 100);
  assert.equal(p.sprite.frame, "b", "100ms 是 b 的起点");

  w.mod.advance(0.15); // 100 - 150 = -50 → 绕回 750
  assert.ok(Math.abs(p.animator.timeMs - 750) < 1e-6, `时间应绕到 750，实际 ${p.animator.timeMs}`);
  // ★ 没有"负时间绕回"的实现会得到 -50ms → sampleClip 夹 0 → 帧 a，这条会红
  assert.equal(p.sprite.frame, "c", "750ms 属于 c；倒放必须能绕过起点");
});

test("speed=0 冻结时间；playing=false 不推进但仍按当前时间刷新帧", () => {
  const w = makeWorld();
  assert.ok(w.mod.registerClip(walkClip(0)).ok);
  const frozen = addPlayer(w, "walk", { speed: 0 });
  w.mod.advance(5);
  assert.equal(frozen.animator.timeMs, 0);
  assert.equal(frozen.sprite.frame, "a");

  const paused = addPlayer(w, "walk", { playing: false });
  w.mod.advance(0.5);
  assert.equal(paused.animator.timeMs, 0);
  w.mod.seek(paused.nodeId, 400);
  assert.equal(paused.sprite.frame, "c", "暂停时 seek 也必须刷新帧");
  w.mod.advance(0.5);
  assert.equal(paused.animator.timeMs, 400, "暂停时不推进时间");
});

// ---------------------------------------------------------------- 模块诊断

test("describe / clipCount / playerCount 与注册、挂载数量一致", () => {
  const w = makeWorld();
  assert.ok(w.mod.registerClip(walkClip(0)).ok);
  assert.ok(
    w.mod
      .registerClip(
        must(makeAnimationClip({ id: "idle", frames: ["i0", "i1"], durationsMs: [200, 200], loopCount: 0 })),
      )
      .ok,
  );
  addPlayer(w, "walk");
  addPlayer(w, "walk");
  addPlayer(w, "idle");

  assert.equal(w.mod.clipCount, 2);
  assert.equal(w.mod.playerCount, 3);
  assert.equal(w.mod.describe(), "动画：2 个 clip / 3 个播放器");
});

test("registerClip：同对象重复注册幂等，同 id 不同数据被拒绝", () => {
  const w = makeWorld();
  const c = walkClip(0);
  assert.ok(w.mod.registerClip(c).ok);
  assert.ok(w.mod.registerClip(c).ok, "同一个对象重复注册应幂等");

  const impostor = walkClip(1);
  const r = w.mod.registerClip(impostor);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "ANIM.DUPLICATE_CLIP");
  assert.equal(w.mod.getClip("walk"), c, "注册表不能被替换");
});

// ---------------------------------------------------------------- warn（不许静默跳过）

test("找不到 clip：warn 到 render 通道并指出 clipId（不是静默不动）", () => {
  const w = makeWorld();
  const p = addPlayer(w, "ghost");
  w.mod.advance(0.1);

  const warns = w.sink.byChannel("render").filter((r) => r.level >= LogLevel.Warn);
  assert.ok(
    warns.some((r) => r.message.includes("ghost")),
    `必须 warn 出缺失的 clipId，实际日志：${warns.map((r) => r.message).join(" | ")}`,
  );
  assert.equal(p.sprite.frame, "", "没有 clip 时不能凭空写帧");
});

test("找不到同节点 Sprite：warn 并指出节点（clip 有了但没人消费）", () => {
  const w = makeWorld();
  assert.ok(w.mod.registerClip(walkClip(0)).ok);
  const node = w.scene.spawnImmediate("no-sprite");
  const animator = new SpriteAnimator();
  animator.clipId = "walk";
  assert.ok(w.scene.attach(node.id, () => animator).ok);
  w.scene.flush();

  w.mod.advance(0.1);
  const warns = w.sink.byChannel("render").filter((r) => r.level >= LogLevel.Warn);
  assert.ok(
    warns.some((r) => r.message.includes("render.sprite") && r.fields?.["node"] === node.id),
    `必须 warn 出缺 Sprite 的节点，实际日志：${warns.map((r) => r.message).join(" | ")}`,
  );
});

test("seek/play/pause 找不到节点：warn（这些 API 不能被静默忽略）", () => {
  const w = makeWorld();
  w.mod.seek(999, 0);
  w.mod.play(999);
  w.mod.pause(999);
  const warns = w.sink.byChannel("render").filter((r) => r.level >= LogLevel.Warn);
  assert.equal(warns.length, 3);
  for (const r of warns) assert.equal(r.fields?.["node"], 999);
});

// ---------------------------------------------------------------- 真实 APNG 全链

test("真实 APNG：decode → 图集 → clip → 采样，帧名/时长/循环与解码器一致", () => {
  const decoded = must(decodeApng(read("apng-none-source.png")));
  const built = must(buildAtlasFromApng(decoded.frames, decoded.width, decoded.height, decoded.loopCount));
  const clip = must(clipFromApngResult(built, "apng-none-source"));

  assert.equal(clip.frames.length, decoded.frames.length, "clip 帧数必须等于解码器帧数");
  assert.deepEqual(clip.frames, built.frameNames, "clip 的帧名必须就是图集里的帧名");
  assert.equal(
    clip.totalDurationMs,
    built.frameDurationsMs.reduce((a, b) => a + b, 0),
    "总时长必须等于 frameDurationsMs 之和",
  );
  assert.equal(clip.totalDurationMs, 800);
  assert.equal(clip.loopCount, 0, "acTL.num_plays=0 = 无限循环");

  // 每个帧起点采到的就是对应帧
  let acc = 0;
  for (let i = 0; i < clip.frames.length; i++) {
    assert.equal(sampleClip(clip, acc).frame, clip.frames[i]!, `第 ${i} 帧起点采错`);
    acc += built.frameDurationsMs[i]!;
  }
  // 一轮结束后回到第 0 帧，轮次 +1
  assert.deepEqual(sampleClip(clip, 800), { frame: clip.frames[0]!, index: 0, loop: 1, done: false });

  // 走一遍模块：150ms 落在第二帧（100~300ms）
  const w = makeWorld();
  assert.ok(w.mod.registerClip(clip).ok);
  const p = addPlayer(w, "apng-none-source");
  w.mod.advance(0.15);
  assert.equal(p.sprite.frame, clip.frames[1]!);
});

test("真实 APNG（有限循环）：loopCount=3、一轮 300ms，900ms 后 done 且停在最后一帧", () => {
  const decoded = must(decodeApng(read("apng-background-over.png")));
  assert.equal(decoded.loopCount, 3);
  const built = must(buildAtlasFromApng(decoded.frames, decoded.width, decoded.height, decoded.loopCount));
  const clip = must(clipFromApngResult(built, "apng-background-over"));

  assert.equal(clip.totalDurationMs, 300);
  assert.equal(sampleClip(clip, 899.999).done, false, "第 3 轮末尾还没播完");
  assert.equal(sampleClip(clip, 900).done, true, "3 轮 = 900ms 才结束");
  assert.equal(sampleClip(clip, 900).frame, clip.frames[clip.frames.length - 1]!);
  assert.equal(sampleClip(clip, 900).loop, 2, "3 次循环的最后一次下标是 2");
});

test("atlas-from-apng 的便捷导出就是 animation 里的实现（没有第二份逻辑）", () => {
  assert.equal(clipFromAtlas, clipFromApngResult);
});

// ---------------------------------------------------------------- 组件 schema

test("SpriteAnimator：schema 覆盖全部字段（否则存档会丢播放进度）", () => {
  const a = new SpriteAnimator();
  const keys = Object.keys(a.schema.fields);
  for (const k of ["clipId", "timeMs", "speed", "playing", "loopOverride", "autoplay"]) {
    assert.ok(keys.includes(k), `schema 缺少字段 ${k}`);
  }
  a.clipId = "walk";
  a.timeMs = 123;
  a.speed = -1;
  const saved = a.save();
  assert.equal(saved["clipId"], "walk");
  assert.equal(saved["timeMs"], 123);
  assert.equal(saved["speed"], -1);
  assert.equal(saved["loopOverride"], -1, "-1 必须能被存档原样写出（不是空值）");
});

test("SpriteAnimator：reset 按 autoplay 决定是否继续播；seek 夹住负数", () => {
  const a = new SpriteAnimator();
  a.autoplay = false;
  a.timeMs = 500;
  a.playing = true;
  a.reset();
  assert.equal(a.timeMs, 0);
  assert.equal(a.playing, false, "autoplay=false 时 reset 不应自动播放");

  a.autoplay = true;
  a.reset();
  assert.equal(a.playing, true);

  a.seek(-100);
  assert.equal(a.timeMs, 0, "负 seek 与采样语义一致：尚未开始");
  assert.throws(() => a.seek(Number.NaN), TypeError);
});
