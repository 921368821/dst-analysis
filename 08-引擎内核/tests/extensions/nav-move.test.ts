/**
 * L4 · 沿路径行走：剩余距离结转、不冲过头、坏输入不崩
 *
 * ★ 这份判据的核心那一条是「路点密度不该影响速度」：
 *   朴素写法每到一个路点就把剩余预算丢掉，于是**斜走段比直走段慢**
 *   （斜走相邻格中心间距 1.414，直走 1.0 —— 每段末尾丢得更多）。
 *   画面上只表现为"有点拖沓"，任何位置判据都不会红。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { nearestIndexOnPath, pathLength, stepAlong } from "../../src/extensions/nav/move-along.ts";

function open(width: number, height: number): NavGrid {
  return new NavGrid(width, height, new Uint8Array(width * height).fill(1));
}

test("[行走] 直走一格：位移、游标、moved 三者自洽", () => {
  const grid = open(6, 1);
  const r = stepAlong(grid, [0, 1, 2, 3], 0, 0.5, 0.5, 2, 0.5);
  assert.equal(r.x, 1.5, "speed 2 × dt 0.5 = 1 格");
  assert.equal(r.z, 0.5);
  assert.equal(r.moved, 1);
  assert.equal(r.cursor, 2, "已经站在第 1 格上，下一个是 2");
  assert.equal(r.done, false);
});

test("[行走] 起点就是第一个路点：不白花预算（不会先「原地对齐」半格）", () => {
  const grid = open(4, 1);
  // 站在 0 号格中心，路径 [0,1]，一个 tick 刚好走一格
  const r = stepAlong(grid, [0, 1], 0, 0.5, 0.5, 1, 1);
  assert.equal(r.x, 1.5, `应该正好走到 1 号格中心，实际 ${String(r.x)}`);
  assert.equal(r.cursor, 2);
  assert.equal(r.done, true);
});

test("[行走] ★ 路点密度不影响速度：密路点与疏路点用时相同", () => {
  const grid = open(12, 1);
  const dense = [0, 1, 2, 3, 4, 5, 6, 7, 8];
  const sparse = [0, 4, 8];
  const speed = 3;
  const dt = 0.1; // 每 tick 0.3 格

  const run = (path: readonly number[]): { ticks: number; x: number } => {
    let x = 0.5;
    let cursor = 0;
    let ticks = 0;
    for (let i = 0; i < 500; i++) {
      const r = stepAlong(grid, path, cursor, x, 0.5, speed, dt);
      x = r.x;
      cursor = r.cursor;
      ticks++;
      if (r.done) break;
    }
    return { ticks, x };
  };

  const a = run(dense);
  const b = run(sparse);
  assert.equal(a.ticks, b.ticks, `密路点用了 ${String(a.ticks)} tick，疏路点用了 ${String(b.ticks)} —— 剩余距离没结转`);
  assert.ok(Math.abs(a.x - b.x) < 1e-9, `终点不一致：${String(a.x)} vs ${String(b.x)}`);
});

test("[行走] 预算远超路径长度：停在终点，不冲过头", () => {
  const grid = open(4, 1);
  const r = stepAlong(grid, [0, 1, 2], 0, 0.5, 0.5, 100, 1);
  assert.equal(r.x, 2.5);
  assert.equal(r.moved, 2, "moved 只算真的走过的距离，不含虚耗");
  assert.equal(r.done, true);
  assert.equal(r.cursor, 3);
});

test("[行走] dt=0 / speed<=0：不动、不推进游标", () => {
  const grid = open(4, 1);
  for (const [speed, dt] of [
    [2, 0],
    [0, 1],
    [-3, 1],
  ] as const) {
    const r = stepAlong(grid, [0, 1, 2], 1, 0.9, 0.5, speed, dt);
    assert.equal(r.moved, 0, `speed=${String(speed)} dt=${String(dt)} 不该动`);
    assert.equal(r.cursor, 1, "游标不该变");
    assert.equal(r.x, 0.9);
  }
});

test("[行走] 坐标是 NaN：原地不动，也不假装走完了", () => {
  const grid = open(4, 1);
  const r = stepAlong(grid, [0, 1, 2], 1, Number.NaN, 0.5, 2, 0.5);
  assert.equal(r.moved, 0);
  assert.equal(r.cursor, 1);
  assert.equal(r.done, false);
  assert.ok(Number.isNaN(r.x));
});

test("[行走] nearestIndexOnPath：平手取更大下标（被推挤后不往回走一格）", () => {
  const grid = open(3, 1);
  // 站在 (1.0, 0.5)：到 0 号（0.5）与 1 号（1.5）距离都是 0.5
  const idx = nearestIndexOnPath(grid, [0, 1, 2], 1.0, 0.5);
  assert.equal(idx, 1, "平手必须取更大下标，否则人物会退回路点再前进");
});

test("[行走] pathLength：3-4-5 三角形的两段之和", () => {
  const grid = open(5, 6);
  // (0,0) → (3,0) → (3,4)：3 + 4
  const len = pathLength(grid, [grid.indexOf(0, 0), grid.indexOf(3, 0), grid.indexOf(3, 4)]);
  assert.equal(len, 7);
  // 带起点偏移：从 (0.5,0.5) 出发到 (0,0) 中心距离 0
  assert.equal(pathLength(grid, [grid.indexOf(0, 0)], 0.5, 0.5), 0);
});

test("[行走] 小步多跑与大步少跑落到同一个点（不累积漂移）", () => {
  const grid = open(10, 1);
  const path = [0, 1, 2, 3, 4, 5];

  let many = { x: 0.5, cursor: 0 };
  for (let i = 0; i < 100; i++) {
    const r = stepAlong(grid, path, many.cursor, many.x, 0.5, 5, 0.0125);
    many = { x: r.x, cursor: r.cursor };
  }
  const once = stepAlong(grid, path, 0, 0.5, 0.5, 5, 1);
  assert.ok(Math.abs(many.x - once.x) < 1e-9, `100 小步到 ${String(many.x)}，一大步到 ${String(once.x)}`);
  assert.equal(many.cursor, once.cursor);
});
