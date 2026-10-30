/**
 * L3 · 意图层：玩家与 AI 共用「意图 → 位移」
 *
 * ★ 这份判据要守的不是「函数能跑」，而是**两条路径真的走同一段代码**：
 *   批147 之前，玩家在 `player-controller.stepOf` 里归一化对角线、AI 在 `ai/move.ts`
 *   里直接 `setLocalPosition` —— 两套单位、两个执行点。挪到 `motion/intent.ts` 之后，
 *   判据必须能分别指名「归一化只有一份」「降级只有一份」「与 stepAlong 逐字段等价」。
 *
 * ★ 为什么第 6 条要逐字段比 `stepAlong` 而不是只比坐标：
 *   `cellStep` 内部就是 `stepAlong` 加一层包装，中间要算 `dx = w.x - x`。
 *   只比坐标会漏掉「游标回传错了」——而游标错了的症状是「走完的路又走一遍」，
 *   坐标在第一个 tick 上完全正确。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { stepAlong } from "../../src/extensions/nav/move-along.ts";
import { cellStep, dirStep, type MoveIntent } from "../../src/extensions/motion/intent.ts";

function open(width: number, height: number): NavGrid {
  return new NavGrid(width, height, new Uint8Array(width * height).fill(1));
}

function dir(dx: number, dz: number): MoveIntent {
  return { kind: "move.dir", dx, dz };
}

test("[意图] ★ 对角线归一化只有一份：斜走与直走的位移长度相同", () => {
  const straight = dirStep(dir(1, 0), 3, 0.5);
  const diagonal = dirStep(dir(1, 1), 3, 0.5);
  const lenS = Math.hypot(straight.dx, straight.dz);
  const lenD = Math.hypot(diagonal.dx, diagonal.dz);
  assert.equal(lenS, 1.5, "speed 3 × dt 0.5 = 1.5");
  assert.ok(
    Math.abs(lenD - lenS) < 1e-12,
    `斜走位移长度应与直走相同（直 ${String(lenS)} / 斜 ${String(lenD)}）—— 不相等说明归一化丢了，斜着走快 41%`,
  );
});

test("[意图] 归一化保留方向：同一方向不同长度的意图产出同一位移", () => {
  const unit = dirStep(dir(1, 0), 2, 1);
  const long = dirStep(dir(7, 0), 2, 1);
  assert.equal(long.dx, unit.dx, "摇杆推到底和推一半，速度不该变");
  assert.equal(long.dz, unit.dz);
});

test("[意图] 非法输入降级成零位移，不抛", () => {
  // 意图可能来自玩家也可能来自 AI，一个 NaN 不该让整个世界停摆 —— 但也不能乱走
  const bad = [
    dirStep(dir(1, 0), 0, 1),
    dirStep(dir(1, 0), 3, 0),
    dirStep(dir(1, 0), 3, -1),
    dirStep(dir(1, 0), -3, 1),
    dirStep(dir(Number.NaN, 0), 3, 1),
    dirStep(dir(0, Number.POSITIVE_INFINITY), 3, 1),
  ];
  for (const r of bad) {
    assert.equal(r.dx, 0, "非法输入必须降级成零位移");
    assert.equal(r.dz, 0);
  }
});

test("[意图] 零向量是「没推摇杆」，不是「走一格」", () => {
  const r = dirStep(dir(0, 0), 3, 0.5);
  assert.equal(r.dx, 0);
  assert.equal(r.dz, 0);
  assert.equal(r.done, false, "方向型永远不宣布到达");
});

test("[意图] ★ 空路径要回 done=true：否则调用方每 tick 拿空路径重问一次", () => {
  const grid = open(3, 3);
  const r = cellStep({ kind: "move.cell", cell: 0 }, {
    grid,
    path: [],
    cursor: 0,
    x: 0.5,
    z: 0.5,
    speed: 2,
    dt: 0.5,
  });
  assert.equal(r.done, true);
  assert.equal(r.dx, 0);
  assert.equal(r.cursor, 0);
});

test("[意图] ★ cellStep 与 stepAlong 逐字段等价（含游标）", () => {
  const grid = open(8, 1);
  // 三个采样点：起点前、路中、快到终点。只比一个点会漏掉「游标回传错了」
  const samples: Array<readonly [number, number, number]> = [
    [0, 0.5, 0.5],
    [1, 1.5, 0.5],
    [2, 2.5, 0.5],
  ];
  for (const [cursor, x, z] of samples) {
    const path = [0, 1, 2, 3, 4];
    const w = stepAlong(grid, path, cursor, x, z, 2, 0.5);
    const r = cellStep({ kind: "move.cell", cell: 4 }, { grid, path, cursor, x, z, speed: 2, dt: 0.5 });
    assert.equal(r.cursor, w.cursor, `cursor=${String(cursor)} 时游标不一致`);
    assert.equal(r.done, w.done, `cursor=${String(cursor)} 时 done 不一致`);
    assert.ok(Math.abs(r.dx - (w.x - x)) < 1e-12, `cursor=${String(cursor)} 时 dx 不一致`);
    assert.ok(Math.abs(r.dz - (w.z - z)) < 1e-12, `cursor=${String(cursor)} 时 dz 不一致`);
  }
});

test("[意图] 类型错配不给位移：方向函数收到目标型、目标函数收到方向型都当零", () => {
  const asDir = cellStep({ kind: "move.dir", dx: 1, dz: 0 }, {
    grid: open(2, 2),
    path: [0, 1],
    cursor: 0,
    x: 0.5,
    z: 0.5,
    speed: 3,
    dt: 1,
  });
  assert.equal(asDir.dx, 0, "cellStep 不该执行方向意图");
  assert.equal(asDir.done, false);

  const asCell = dirStep({ kind: "move.cell", cell: 3 }, 3, 1);
  assert.equal(asCell.dx, 0, "dirStep 不该执行目标型意图");
  assert.equal(asCell.dz, 0);
});
