/**
 * 关键帧轨道判据（ADR-0010 缺口①）
 *
 * 这一层的核心性质只有一条：**任意时刻都有定义，且在每个关键帧上精确等于帧值**。
 * 围绕它有三类容易写坏的地方：
 *   ① 边界（0 / 末帧 / 恰好落在某个中间帧）—— 特判写两处就必然有一处忘了夹取；
 *   ② easing 挂在**到达**那一帧上 —— 写成离开帧时，最后一帧的 easing 永远不生效，
 *      而"这一段落得太硬"的人会去改左边那个键，改完没反应；
 *   ③ 播完之后继续累加时间 —— 几百秒后浮点精度掉到 1ms 以下，重播起点会漂
 *      （与分段轨道同一条纪律）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { KEYFRAME_ERR, KeyTrack, makeTrack, sampleTrack, type TrackSpec } from "../../src/extensions/tween/keyframes.ts";
import { advancePlayer, TWEEN_PLAYER_ERR, TweenPlayer } from "../../src/extensions/tween/tween-player.ts";

/** 造一条三段轨道：0ms→0，100ms→10，200ms→0。线性。 */
function threeKeys(easing?: readonly (string | undefined)[]): TrackSpec {
  const r = makeTrack({
    id: "t",
    keys: [
      { atMs: 0, value: 0 },
      easing === undefined ? { atMs: 100, value: 10 } : { atMs: 100, value: 10, easing: easing[0] as string },
      easing === undefined ? { atMs: 200, value: 0 } : { atMs: 200, value: 0, easing: easing[1] as string },
    ],
  });
  if (!r.ok) throw new Error(`夹具轨道构造失败：${r.error.code}`);
  return r.value;
}

// ── ① 构造期校验 ────────────────────────────────────────────

test("少于两个关键帧直接拒绝（一个点构不成轨道）", () => {
  const r = makeTrack({ id: "t", keys: [{ atMs: 0, value: 1 }] });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, KEYFRAME_ERR.TOO_FEW);
});

test("★ 第一个关键帧必须在 0ms（否则 0..起播 之间没有定义）", () => {
  const r = makeTrack({ id: "t", keys: [{ atMs: 500, value: 1 }, { atMs: 900, value: 2 }] });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, KEYFRAME_ERR.NO_ORIGIN);
});

test("★ atMs 必须严格递增：相等也要拒（同一时刻两个值没有定义）", () => {
  const equal = makeTrack({ id: "t", keys: [{ atMs: 0, value: 1 }, { atMs: 100, value: 2 }, { atMs: 100, value: 3 }] });
  assert.equal(equal.ok, false);
  assert.equal(equal.ok ? "" : equal.error.code, KEYFRAME_ERR.UNSORTED);
  const back = makeTrack({ id: "t", keys: [{ atMs: 0, value: 1 }, { atMs: 200, value: 2 }, { atMs: 100, value: 3 }] });
  assert.equal(back.ok, false);
  assert.equal(back.ok ? "" : back.error.code, KEYFRAME_ERR.UNSORTED);
});

test("atMs 为负 / 非有限，值为非有限，都拒绝", () => {
  const neg = makeTrack({ id: "t", keys: [{ atMs: 0, value: 1 }, { atMs: -5, value: 2 }] });
  assert.equal(neg.ok ? "" : neg.error.code, KEYFRAME_ERR.BAD_AT);
  const nan = makeTrack({ id: "t", keys: [{ atMs: 0, value: 1 }, { atMs: Number.NaN, value: 2 }] });
  assert.equal(nan.ok ? "" : nan.error.code, KEYFRAME_ERR.BAD_AT);
  const val = makeTrack({ id: "t", keys: [{ atMs: 0, value: 1 }, { atMs: 50, value: Number.POSITIVE_INFINITY }] });
  assert.equal(val.ok ? "" : val.error.code, KEYFRAME_ERR.BAD_VALUE);
});

test("引用了不存在的缓动名 ⇒ 构造期就拒绝（不留到采样期）", () => {
  const r = makeTrack({ id: "t", keys: [{ atMs: 0, value: 0 }, { atMs: 50, value: 1, easing: "noSuchEasing" }] });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, KEYFRAME_ERR.UNKNOWN_EASING);
});

test("总时长 = 最后一个关键帧的时刻", () => {
  assert.equal(threeKeys().durationMs, 200);
});

test("构造后冻结：改入参数组不影响已构造的 spec", () => {
  const keys = [{ atMs: 0, value: 0 }, { atMs: 100, value: 10 }];
  const r = makeTrack({ id: "t", keys });
  assert.ok(r.ok);
  const spec = r.ok ? r.value : ({} as TrackSpec);
  keys[1]!.value = 999;
  assert.equal(sampleTrack(spec, 50).value, 5, "冻结点值仍是 10 ⇒ 中点 5");
});

// ── ② 采样 ──────────────────────────────────────────────────

test("★ 每个关键帧时刻的值**精确**等于该帧的值（含中间帧，两侧都验）", () => {
  const spec = threeKeys();
  for (const k of spec.keys) {
    assert.equal(sampleTrack(spec, k.atMs).value, k.value, `落在 ${String(k.atMs)}ms 时应等于帧值`);
    if (k.atMs > 0) {
      // 从左侧逼近：极限必须收敛到同一个值（否则边界上有 1 帧的跳）
      const left = sampleTrack(spec, k.atMs - 0.001).value;
      assert.ok(Math.abs(left - k.value) < 1e-2, `左侧极限应逼近 ${String(k.value)}，实际 ${String(left)}`);
    }
  }
});

test("段内线性插值：三段轨道的 50ms / 150ms 分别是半程", () => {
  const spec = threeKeys();
  assert.equal(sampleTrack(spec, 50).value, 5);
  assert.equal(sampleTrack(spec, 150).value, 5);
  assert.equal(sampleTrack(spec, 100).segment, 1, "恰好落在中间帧时属于**离开**的那一段");
});

test("ms < 0 ⇒ 第一帧的值（还没开始，不是 0），且未完成", () => {
  const spec = threeKeys();
  const s = sampleTrack(spec, -500);
  assert.equal(s.value, 0);
  assert.equal(s.done, false);
  assert.equal(s.progress, 0);
});

test("★ 越过末帧不外插：值停在末帧，done = true", () => {
  const spec = threeKeys();
  const s = sampleTrack(spec, 100000);
  assert.equal(s.value, 0);
  assert.equal(s.done, true);
  assert.equal(s.progress, 1);
});

test("非有限 ms 直接抛（调用方的编程错误，不是可配置字段）", () => {
  assert.throws(() => sampleTrack(threeKeys(), Number.NaN), TypeError);
  assert.throws(() => sampleTrack(threeKeys(), Number.POSITIVE_INFINITY), TypeError);
});

test("★ easing 作用在**到达**那一帧的段上：第一段用 keys[1].easing", () => {
  const linear = threeKeys();
  const eased = threeKeys(["quadIn", undefined]);
  assert.equal(sampleTrack(linear, 50).value, 5);
  // quadIn(0.5) = 0.25 ⇒ 0 + 10×0.25 = 2.5（与线性的 5 明显不同）
  assert.equal(sampleTrack(eased, 50).value, 2.5);
  // 第二段未指定 ⇒ 线性；160ms 是 60% ⇒ 10 + (0-10)×0.6 = 4
  assert.equal(sampleTrack(eased, 160).value, 4);
});

test("★ 第一帧上写的 easing **不生效**（它没有\"到达自己\"的段）", () => {
  const r = makeTrack({
    id: "t",
    keys: [
      { atMs: 0, value: 0, easing: "quadIn" },
      { atMs: 100, value: 10 },
    ],
  });
  assert.ok(r.ok);
  const spec = r.ok ? r.value : ({} as TrackSpec);
  assert.equal(sampleTrack(spec, 50).value, 5, "第一段仍按第二帧的 linear 走");
});

test("★ 中间帧真的参与了曲线：删掉中间帧后中点值不同", () => {
  const withMid = threeKeys();
  const withoutMid = makeTrack({ id: "t", keys: [{ atMs: 0, value: 0 }, { atMs: 200, value: 0 }] });
  assert.ok(withoutMid.ok);
  const flat = withoutMid.ok ? withoutMid.value : ({} as TrackSpec);
  assert.equal(sampleTrack(flat, 100).value, 0, "两点之间是平的");
  assert.equal(sampleTrack(withMid, 100).value, 10, "三点之间在 100ms 处是峰");
});

// ── ③ KeyTrack 运行态 ───────────────────────────────────────

test("KeyTrack.reset 回到 0 并按 autoplay 决定是否继续播", () => {
  const spec = threeKeys();
  const t = new KeyTrack("k", "panel", "opacity", spec, false, true);
  t.seek(120);
  assert.equal(t.sample().value, 8);
  t.reset();
  assert.equal(t.timeMs, 0);
  assert.equal(t.playing, true, "autoplay=true ⇒ reset 后接着播");
  const p = new KeyTrack("k2", "panel", "opacity", spec, true, false);
  p.reset();
  assert.equal(p.playing, false, "autoplay=false ⇒ reset 后停住");
});

test("KeyTrack.seek 负数夹 0，非有限抛", () => {
  const t = new KeyTrack("k", "panel", "opacity", threeKeys(), true, true);
  t.seek(-99);
  assert.equal(t.timeMs, 0);
  assert.throws(() => t.seek(Number.NaN), TypeError);
});

// ── ④ 与 TweenPlayer 的接线 ─────────────────────────────────

test("addKeyTrack：id 与分段轨道**共用**同一个唯一域", () => {
  const p = new TweenPlayer();
  assert.ok(p.addTrack({ id: "same", targetId: "a", prop: "opacity", spec: { id: "s", from: 0, to: 1, durationMs: 100 } }).ok);
  const dup = p.addKeyTrack({ id: "same", targetId: "a", prop: "opacity", keys: [{ atMs: 0, value: 0 }, { atMs: 50, value: 1 }] });
  assert.equal(dup.ok, false);
  assert.equal(dup.ok ? "" : dup.error.code, TWEEN_PLAYER_ERR.DUPLICATE_TRACK);
  // 关键帧之间也不能重名
  assert.ok(p.addKeyTrack({ id: "k1", targetId: "a", prop: "scale", keys: [{ atMs: 0, value: 0 }, { atMs: 50, value: 1 }] }).ok);
  const dup2 = p.addKeyTrack({ id: "k1", targetId: "a", prop: "scale", keys: [{ atMs: 0, value: 0 }, { atMs: 50, value: 1 }] });
  assert.equal(dup2.ok, false);
});

test("advancePlayer 推进关键帧轨道：按 dt 累加，值与 progress 对得上", () => {
  const p = new TweenPlayer();
  assert.ok(p.addKeyTrack({ id: "k", targetId: "panel", prop: "scale", keys: [{ atMs: 0, value: 1 }, { atMs: 100, value: 2 }] }).ok);
  const s1 = advancePlayer(p, 50);
  assert.equal(s1.length, 1);
  assert.equal(s1[0]?.value, 1.5);
  assert.equal(s1[0]?.done, false);
  const s2 = advancePlayer(p, 60);
  assert.equal(s2[0]?.value, 2, "越过后停在末值（不外插）");
  assert.equal(s2[0]?.done, true);
});

test("★ 播完之后不再累加时间（避免浮点精度把重播起点带漂）", () => {
  const p = new TweenPlayer();
  const made = p.addKeyTrack({ id: "k", targetId: "panel", prop: "scale", keys: [{ atMs: 0, value: 1 }, { atMs: 100, value: 2 }] });
  assert.ok(made.ok);
  // ★ 越过总时长的那一步会把 dt 整个记上（与分段轨道同一行为；夹到总时长是另一种口径，
  //   两种轨道必须一致，否则"播完了时间停在哪"要按轨道类型分别解释）。
  advancePlayer(p, 200);
  const after = p.keyTracks[0]!.timeMs;
  assert.equal(after, 200);
  // 真正要守的性质是**冻结**：之后无论推多少都不再增长 ⇒ 不会无界漂。
  for (let i = 0; i < 100; i++) advancePlayer(p, 40);
  assert.equal(p.keyTracks[0]!.timeMs, after, "再推四千毫秒也不涨");
  assert.equal(p.keyTracks[0]!.sample().value, 2, "时间越界但值仍停在末帧（不外插）");
});

test("changed 只在值真的变了时为 true（宿主据此决定要不要重排）", () => {
  const p = new TweenPlayer();
  assert.ok(p.addKeyTrack({ id: "k", targetId: "panel", prop: "scale", keys: [{ atMs: 0, value: 1 }, { atMs: 100, value: 2 }] }).ok);
  assert.equal(advancePlayer(p, 10)[0]?.changed, true, "第一次必报变化（从 NaN 起算）");
  // 已经 done 的轨道继续推：值不变 ⇒ changed=false
  advancePlayer(p, 500);
  assert.equal(advancePlayer(p, 16)[0]?.changed, false);
});

test("player.playing=false ⇒ 一条都不推进，但仍返回当前值", () => {
  const p = new TweenPlayer();
  assert.ok(p.addKeyTrack({ id: "k", targetId: "panel", prop: "scale", keys: [{ atMs: 0, value: 1 }, { atMs: 100, value: 2 }] }).ok);
  p.playing = false;
  assert.equal(advancePlayer(p, 500)[0]?.value, 1, "没推进 ⇒ 仍是起点");
  assert.equal(p.keyTracks[0]!.timeMs, 0);
});

test("pause / play 按 id 能找到关键帧轨道；clear 两种都清；reset 两种都回起点", () => {
  const p = new TweenPlayer();
  assert.ok(p.addKeyTrack({ id: "k", targetId: "panel", prop: "scale", keys: [{ atMs: 0, value: 1 }, { atMs: 100, value: 2 }] }).ok);
  assert.ok(p.addTrack({ id: "seg", targetId: "panel", prop: "opacity", spec: { id: "s", from: 0, to: 1, durationMs: 100 } }).ok);
  assert.ok(p.pause("k").ok);
  assert.equal(p.keyTrack("k")?.playing, false);
  assert.ok(p.play("k").ok);
  assert.equal(p.keyTrack("k")?.playing, true);
  advancePlayer(p, 50);
  p.reset();
  assert.equal(p.keyTracks[0]!.timeMs, 0);
  assert.equal(p.tracks[0]!.timeMs, 0);
  p.clear();
  assert.equal(p.keyTracks.length, 0);
  assert.equal(p.tracks.length, 0);
});

test("moving：关键帧轨道未播完时 true，播完后 false", () => {
  const p = new TweenPlayer();
  assert.ok(p.addKeyTrack({ id: "k", targetId: "panel", prop: "scale", keys: [{ atMs: 0, value: 1 }, { atMs: 100, value: 2 }] }).ok);
  assert.equal(p.moving, true);
  advancePlayer(p, 100);
  assert.equal(p.moving, false);
});

test("同一属性上两种轨道并存 ⇒ 合成成一条，分段在前、关键帧在后（默认 replace = 覆盖）", () => {
  const p = new TweenPlayer();
  assert.ok(p.addTrack({ id: "seg", targetId: "panel", prop: "scale", spec: { id: "s", from: 0, to: 1, durationMs: 100, easing: "linear" } }).ok);
  assert.ok(p.addKeyTrack({ id: "k", targetId: "panel", prop: "scale", keys: [{ atMs: 0, value: 5 }, { atMs: 100, value: 5 }] }).ok);
  const out = advancePlayer(p, 50);
  // ★ 批117 起数组粒度是 (目标, 属性)：同一属性只出**一条**，`id` 是最后写它的那条。
  assert.deepEqual(out.map((s) => s.id), ["k"], "同一属性合成成一条（阶梯上有两条，屏幕上只有一个值）");
  assert.equal(out[0]!.value, 5, "默认 replace ⇒ 关键帧轨道盖掉分段轨道（0.5 被丢掉）");
  assert.equal(p.track("seg")?.composite, "replace", "不写 composite 时缺省是 replace（批76 行为不变）");
});
