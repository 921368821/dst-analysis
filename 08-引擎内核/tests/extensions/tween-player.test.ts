/**
 * `TweenPlayer` 判据：组件化的补间（进度按轨道存、按 tick 推进）
 *
 * 这一层和 `tween.test.ts`（纯采样）分工不同：那边验"时刻 → 值"的数学，
 * 这边验**谁持有时间**、**什么时候不推进**、**值变没变**。三条最容易写错的地方：
 *   ① 速率被乘了两次（调用方 `timeMs += dt*speed` 与采样里的 `duration/|speed|`
 *      同时生效 ⇒ 实际速度是 speed²）；
 *   ② 播完之后继续累加时间（几百秒后浮点精度掉了，"重播"起点会漂）；
 *   ③ 静止的过渡每帧都报"值变了"（宿主据此标脏 ⇒ 整棵 UI 每帧重排）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { advancePlayer, ticksToMs, TweenPlayer, TWEEN_PLAYER_ERR, TWEEN_PLAYER_TYPE } from "../../src/extensions/tween/tween-player.ts";
import { TWEEN_ERR } from "../../src/extensions/tween/tween.ts";

/** 造一个只有一条轨道的 player。`linear` 便于手算断言值。 */
function playerWith(
  spec: { from: number; to: number; durationMs: number; easing?: string; speed?: number; loopCount?: number; delayMs?: number },
  opts: { id?: string; playing?: boolean; autoplay?: boolean } = {},
): TweenPlayer {
  const p = new TweenPlayer();
  const r = p.addTrack({
    id: opts.id ?? "t0",
    targetId: "panel",
    prop: "opacity",
    spec: { id: "fade", easing: "linear", ...spec },
    playing: opts.playing,
    autoplay: opts.autoplay,
  });
  if (!r.ok) throw new Error(`夹具自身失败：${r.error.code} ${r.error.message}`);
  return p;
}

test("组件类型常量与 schema 一致（两处手写会漂）", () => {
  const p = new TweenPlayer();
  assert.equal(p.schema.type, TWEEN_PLAYER_TYPE);
  assert.deepEqual(Object.keys(p.schema.fields), ["playing"]);
});

test("★ 一步推进按 dt 走：100ms 的补间走 25ms 到 25%", () => {
  const p = playerWith({ from: 0, to: 100, durationMs: 100 });
  const s = advancePlayer(p, 25);
  assert.equal(s.length, 1);
  assert.equal(s[0]?.value, 25);
  assert.equal(s[0]?.targetId, "panel");
  assert.equal(s[0]?.prop, "opacity");
});

test("★★ 速率只乘一次：speed=2 走 25ms 应该是半程（不是满程）", () => {
  // 双乘的实现会得到 100（timeMs=50 且 perLoop=50 ⇒ progress=1），
  // 只乘一次才是 50（timeMs=50、perLoop=100 ⇒ progress=0.5）。
  const p = playerWith({ from: 0, to: 100, durationMs: 100, speed: 2 });
  const s = advancePlayer(p, 25);
  assert.equal(s[0]?.value, 50, `speed 被乘了两次（拿到 ${String(s[0]?.value)}）`);
});

test("★ speed=0 冻结：时间不推进，值停在 from", () => {
  const p = playerWith({ from: 0, to: 100, durationMs: 100, speed: 0 });
  advancePlayer(p, 50);
  const s = advancePlayer(p, 50);
  assert.equal(s[0]?.value, 0);
});

test("★ 倒放：时间照常往前走、值从终点往回走（速率归采样层，不归推进方）", () => {
  const p = playerWith({ from: 0, to: 100, durationMs: 100, speed: -1 });
  // 倒放的起点（时间 0）是**终点值** —— 与 `sampleTween(s,0) = 100` 同一口径
  assert.equal(advancePlayer(p, 0)[0]?.value, 100, "时间 0 是倒放的起点（值 = to）");
  const s = advancePlayer(p, 30);
  assert.equal(p.track("t0")?.timeMs, 30, "时间照常往前走（不是负的）");
  assert.equal(s[0]?.value, 70, "走了 30ms ⇒ 值从 100 往回走到 70");
});

test("★★ 有限循环播完后不再累加时间（浮点不会无界增长）", () => {
  const p = playerWith({ from: 0, to: 10, durationMs: 100, loopCount: 1 });
  for (let i = 0; i < 12; i++) advancePlayer(p, 10);
  const t = p.track("t0");
  assert.ok(t !== undefined);
  const at = t.timeMs;
  assert.equal(advancePlayer(p, 10)[0]?.done, true);
  assert.equal(t.timeMs, at, `播完后还在累加：${String(at)} → ${String(t.timeMs)}`);
  assert.equal(at, 100, "恰好停在终点，不该过冲");
});

test("★★ changed 只在值真的变了时为 true（宿主靠它决定要不要重排）", () => {
  const p = playerWith({ from: 0, to: 100, durationMs: 100, loopCount: 1 });
  assert.equal(advancePlayer(p, 10)[0]?.changed, true, "第一次采样一定是「变了」");
  assert.equal(advancePlayer(p, 0)[0]?.changed, false, "dt=0 ⇒ 值没变");
  advancePlayer(p, 100); // 走到终点
  assert.equal(advancePlayer(p, 100)[0]?.changed, false, "已经停在终点，值不再变");
});

test("★★ player.playing=false 时一条都不推进，但仍返回当前采样", () => {
  const p = playerWith({ from: 0, to: 100, durationMs: 100 });
  p.playing = false;
  const s = advancePlayer(p, 50);
  assert.equal(p.track("t0")?.timeMs, 0, "暂停期间时间不该走");
  assert.equal(s.length, 1, "暂停也要返回采样（否则界面停在上一帧的值）");
  assert.equal(s[0]?.value, 0);
});

test("★ pause 只停那一条：另一条照走（证明不是整组开关）", () => {
  const p = new TweenPlayer();
  for (const id of ["a", "b"]) {
    const r = p.addTrack({ id, targetId: id, prop: "opacity", spec: { id, from: 0, to: 100, durationMs: 100, easing: "linear" } });
    assert.ok(r.ok);
  }
  assert.ok(p.pause("a").ok);
  const s = advancePlayer(p, 25);
  assert.equal(s.find((x) => x.id === "a")?.value, 0);
  assert.equal(s.find((x) => x.id === "b")?.value, 25);
  assert.ok(p.play("a").ok);
  assert.equal(advancePlayer(p, 25).find((x) => x.id === "a")?.value, 25);
});

test("★ 重复轨道 id 被拒绝（第二条会变成停不下来的幽灵）", () => {
  const p = playerWith({ from: 0, to: 1, durationMs: 100 });
  const dup = p.addTrack({ id: "t0", targetId: "x", prop: "opacity", spec: { id: "z", from: 0, to: 1, durationMs: 100 } });
  assert.equal(dup.ok, false);
  if (!dup.ok) assert.equal(dup.error.code, TWEEN_PLAYER_ERR.DUPLICATE_TRACK);
  assert.equal(p.tracks.length, 1);
});

test("★ 坏 spec 在 addTrack 就炸（不留到采样期）", () => {
  const p = new TweenPlayer();
  const bad = p.addTrack({ id: "z", targetId: "x", prop: "opacity", spec: { id: "z", from: 0, to: 1, durationMs: 0 } });
  assert.equal(bad.ok, false);
  if (!bad.ok) assert.equal(bad.error.code, TWEEN_ERR.BAD_DURATION);
  assert.equal(p.tracks.length, 0, "失败的轨道不该留在表里");
});

test("★ 未知轨道的 pause/play 报错码，不静默", () => {
  const p = new TweenPlayer();
  const r = p.pause("nope");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, TWEEN_PLAYER_ERR.NO_TRACK);
});

test("reset 回到起点，并按 autoplay 决定是否继续播", () => {
  const p = playerWith({ from: 0, to: 100, durationMs: 100 }, { autoplay: false });
  advancePlayer(p, 50);
  p.reset();
  assert.equal(p.track("t0")?.timeMs, 0);
  assert.equal(p.track("t0")?.playing, false, "autoplay=false ⇒ 重置后不播");
  assert.equal(advancePlayer(p, 10)[0]?.value, 0);
});

test("seek 负数夹到 0，非有限数抛 TypeError", () => {
  const p = playerWith({ from: 0, to: 100, durationMs: 100 });
  const t = p.track("t0");
  assert.ok(t !== undefined);
  t.seek(-50);
  assert.equal(t.timeMs, 0);
  assert.throws(() => {
    t.seek(Number.NaN);
  }, TypeError);
});

test("★ advancePlayer 的 dtMs 非法直接抛（负 dt 会让时间倒流，症状极难归因）", () => {
  const p = playerWith({ from: 0, to: 1, durationMs: 100 });
  assert.throws(() => advancePlayer(p, -1), TypeError);
  assert.throws(() => advancePlayer(p, Number.NaN), TypeError);
});

test("★ ticksToMs 把逻辑步换成毫秒（时长只按 tick 指定的唯一入口）", () => {
  assert.equal(ticksToMs(6, 1000 / 30), 200);
  assert.equal(ticksToMs(1, 16), 16);
  assert.throws(() => ticksToMs(0, 16), TypeError);
  assert.throws(() => ticksToMs(1.5, 16), TypeError);
  assert.throws(() => ticksToMs(3, 0), TypeError);
  assert.throws(() => ticksToMs(3, Number.NaN), TypeError);
});

test("clear 清空轨道；moving 反映还有没有东西在动", () => {
  const p = playerWith({ from: 0, to: 100, durationMs: 100, loopCount: 1 });
  assert.equal(p.moving, true);
  advancePlayer(p, 200);
  assert.equal(p.moving, false, "播完就不该再算「在动」");
  p.clear();
  assert.equal(p.tracks.length, 0);
  assert.equal(p.moving, false);
});

test("★ 反向用例：延迟段内推进不出值（delay 仍只作用于第一次）", () => {
  const p = playerWith({ from: 5, to: 100, durationMs: 100, delayMs: 40 });
  assert.equal(advancePlayer(p, 20)[0]?.value, 5, "delay 段内停在 from");
  // 累计 60ms ⇒ 越过 delay 40ms ⇒ 单段内走了 20ms ⇒ 5 + 95×0.2 = 24
  assert.equal(advancePlayer(p, 40)[0]?.value, 24, "越过 delay 之后按 20ms 计");
});
