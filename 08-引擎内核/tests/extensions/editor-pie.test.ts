/**
 * L4 · 编辑器：PIE 时钟
 *
 * ★ 这四条语义看起来"显然对"，但写错的代价长得很像"性能问题"：
 *   暂停恢复后跳一帧、单步等于播放、卡顿后永久超速、60fps 下只跑一半 tick。
 *   所以每一条都配一条判据，并且都配一条变异。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { createPie } from "../../src/extensions/editor/pie.ts";

test("[编辑器·PIE] 默认暂停：不播放时一帧也不推进", () => {
  const pie = createPie({ hz: 30 });
  assert.equal(pie.isPlaying, false, "编辑器进页面就该是暂停的");
  assert.equal(pie.advance(1), 0);
  assert.equal(pie.stats().tick, 0);
});

test("[编辑器·PIE] 播放后 1/30 秒正好 1 tick", () => {
  const pie = createPie({ hz: 30 });
  pie.play();
  assert.equal(pie.advance(1 / 30), 1);
  assert.equal(pie.stats().tick, 1);
});

test("[编辑器·PIE] ★ 帧率与 tick 同频：30 帧不能丢 tick", () => {
  const pie = createPie({ hz: 30 });
  pie.play();
  let total = 0;
  for (let i = 0; i < 30; i++) total += pie.advance(1 / 30);
  assert.equal(total, 30, `30 帧 × 1/30 秒必须正好 30 tick，实际 ${String(total)}（差一点点就会周期性地少跑）`);
});

test("[编辑器·PIE] 60fps 下也是 30 tick/秒", () => {
  const pie = createPie({ hz: 30 });
  pie.play();
  let total = 0;
  for (let i = 0; i < 60; i++) total += pie.advance(1 / 60);
  assert.equal(total, 30, `60 帧 × 1/60 秒应得 30 tick，实际 ${String(total)}`);
});

test("[编辑器·PIE] ★ 144fps 下也是 30 tick/秒（浮点容差真正起作用的地方）", () => {
  // 1/144×30 = 0.20833333333333334，144 次累加得 29.999999999999996 ⇒ 少一个 tick。
  // ★ 为什么不用 60fps 测：1/60×30 恰好是 0.5，两帧正好一个 tick ——
  //   拿一个「刚好能整除」的帧率验浮点累积，等于没验（这一条最初就是这么写错的）。
  const pie = createPie({ hz: 30, maxStepTicks: 4 });
  pie.play();
  let total = 0;
  for (let i = 0; i < 144; i++) total += pie.advance(1 / 144);
  assert.equal(total, 30, `144 帧 × 1/144 秒应得 30 tick，实际 ${String(total)}（缺容差时只得 29）`);
});

test("[编辑器·PIE] ★ 暂停期间不累积：恢复时不许补跑", () => {
  const pie = createPie({ hz: 30 });
  pie.play();
  assert.equal(pie.advance(1 / 30), 1);
  pie.pause();
  assert.equal(pie.advance(10), 0, "暂停中推进 10 秒不该跑");
  assert.equal(pie.stats().backlog, 0, "暂停中累积器必须是 0");
  pie.play();
  assert.equal(pie.advance(0), 0, "恢复的第一帧不许补跑暂停期的时间（否则画面上是『恢复时跳一下』）");
});

test("[编辑器·PIE] ★ 单步 = 暂停着走一步，之后仍是暂停", () => {
  const pie = createPie({ hz: 30 });
  pie.play();
  pie.step(2);
  assert.equal(pie.isPlaying, false, "点了单步就不该还在播放");
  assert.equal(pie.advance(0), 2, "排队的单步要一次跑完");
  assert.equal(pie.advance(1), 0, "单步跑完不能自动变回播放");
  assert.equal(pie.stats().tick, 2);
});

test("[编辑器·PIE] 单步排队有上限（连点/误输入不卡死主线程）", () => {
  const pie = createPie();
  pie.step(100000);
  assert.equal(pie.advance(0), 600);
  assert.equal(pie.stats().pending, 0);
});

test("[编辑器·PIE] ★ 掉帧兜底：单帧最多 4 tick，且被夹掉的时间丢掉", () => {
  const pie = createPie({ hz: 30, maxStepTicks: 4 });
  pie.play();
  // 卡了 0.5 秒 ⇒ 本可以跑 15 tick
  assert.equal(pie.advance(0.5), 4, "单帧必须夹住");
  assert.equal(pie.stats().clampedFrames, 1);
  assert.equal(pie.advance(0), 0, "被夹掉的时间不许留债 —— 否则卡一次之后会永远跑得比实时快");
  // 恢复正常节奏后不该突然加速
  assert.equal(pie.advance(1 / 30), 1);
  assert.equal(pie.advance(1 / 30), 1);
});

test("[编辑器·PIE] dt 为 0 / 负数 / NaN 都不崩且不推进", () => {
  const pie = createPie({ hz: 30 });
  pie.play();
  assert.equal(pie.advance(0), 0);
  assert.equal(pie.advance(-5), 0);
  assert.equal(pie.advance(Number.NaN), 0);
  assert.equal(pie.stats().tick, 0);
  assert.equal(pie.advance(1 / 30), 1, "异常帧之后还能正常跑");
});

test("[编辑器·PIE] toggle 在播放/暂停之间切换", () => {
  const pie = createPie();
  assert.equal(pie.toggle(), true);
  assert.equal(pie.isPlaying, true);
  assert.equal(pie.toggle(), false);
  assert.equal(pie.isPlaying, false);
});
