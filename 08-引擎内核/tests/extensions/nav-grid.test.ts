/**
 * L4 · 导航网格：可通行栅格 + A*
 *
 * ★ 这份判据里最要紧的三类是：
 *   ① **路径合法性**（每一格都能站、相邻两步符合邻居规则、不切角）；
 *   ② **最优性**（拿一份独立的 Dijkstra 当参照，A* 的代价不许比它高）；
 *   ③ **确定性**（两次寻路给出同一串格子 —— 回放只认字节）。
 *   只验"能找到一条路"是不够的：能走到但绕地球一圈也算"成功"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { NavGrid, STRAIGHT_COST, DIAGONAL_COST } from "../../src/extensions/nav/nav-grid.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";

/** `#` = 不可站，其余任意字符 = 可站。行数 = 高度，列数 = 宽度。 */
function gridOf(rows: readonly string[]): NavGrid {
  const height = rows.length;
  const width = rows[0]!.length;
  const mask = new Uint8Array(width * height);
  for (let z = 0; z < height; z++) {
    const row = rows[z]!;
    assert.equal(row.length, width, `第 ${String(z)} 行宽度与第一行不一致`);
    for (let x = 0; x < width; x++) mask[z * width + x] = row[x] === "#" ? 0 : 1;
  }
  return new NavGrid(width, height, mask);
}

/** 断言一串格子构成一条合法路径：每格可站、相邻、且不切角。 */
function assertPathValid(grid: NavGrid, cells: readonly number[]): void {
  for (const c of cells) assert.equal(grid.isWalkableIndex(c), true, `路径里有不可站的格子 ${String(c)}`);
  for (let i = 1; i < cells.length; i++) {
    const a = cells[i - 1]!;
    const b = cells[i]!;
    const ax = grid.cellX(a);
    const az = grid.cellZ(a);
    const dx = grid.cellX(b) - ax;
    const dz = grid.cellZ(b) - az;
    assert.ok(Math.abs(dx) <= 1 && Math.abs(dz) <= 1, `第 ${String(i)} 步不是相邻格：${String(a)} → ${String(b)}`);
    assert.ok(dx !== 0 || dz !== 0, "路径里出现了原地不动的重复格");
    if (dx !== 0 && dz !== 0) {
      assert.ok(
        grid.isWalkable(ax + dx, az) && grid.isWalkable(ax, az + dz),
        `第 ${String(i)} 步切角了：${String(a)} → ${String(b)}（两个正交邻格必须都可站）`,
      );
    }
  }
}

/** 独立参照实现：朴素 Dijkstra（无启发式、同样禁止切角）。用来验 A* 的最优性。 */
function dijkstraCost(grid: NavGrid, from: number, to: number): number {
  const dist = new Map<number, number>([[from, 0]]);
  const done = new Set<number>();
  for (;;) {
    let cur = -1;
    let best = Infinity;
    for (const [cell, d] of dist) {
      if (done.has(cell)) continue;
      if (d < best || (d === best && cell < cur)) {
        best = d;
        cur = cell;
      }
    }
    if (cur < 0) return Infinity;
    if (cur === to) return best;
    done.add(cur);
    const cx = grid.cellX(cur);
    const cz = grid.cellZ(cur);
    for (let dz = -1; dz <= 1; dz++) {
      for (let dx = -1; dx <= 1; dx++) {
        if (dx === 0 && dz === 0) continue;
        if (!grid.isWalkable(cx + dx, cz + dz)) continue;
        if (dx !== 0 && dz !== 0 && (!grid.isWalkable(cx + dx, cz) || !grid.isWalkable(cx, cz + dz))) continue;
        const n = grid.indexOf(cx + dx, cz + dz);
        const nd = best + (dx !== 0 && dz !== 0 ? DIAGONAL_COST : STRAIGHT_COST);
        const old = dist.get(n);
        if (old === undefined || nd < old) dist.set(n, nd);
      }
    }
  }
}

test("[导航] fromPlan：可站格数等于群系表里可通行格数", () => {
  const g = generateWorld({ seed: 4242, width: 20, height: 16 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");

  const grid = NavGrid.fromPlan(g.value);
  assert.equal(grid.ok, true, grid.ok ? "" : grid.error.code);
  if (!grid.ok) throw new Error("unreachable");

  assert.equal(grid.value.width, 20);
  assert.equal(grid.value.height, 16);
  assert.equal(grid.value.total, 320);

  // 逐格对照：计划的 kinds[i] 与网格的 isWalkableIndex 必须一一对应。
  // ★ 这里**刻意写死一份独立的群系表**：若两边都调 `isPassable`，这条判据就变成同义反复
  //   （它只证明"同一个函数被调了两次"）。硬写一份，群系表被改动时这里会先红。
  const IMPASSABLE = new Set(["ocean", "cliff"]);
  let walkable = 0;
  for (let i = 0; i < g.value.kinds.length; i++) {
    const kind: string = g.value.kinds[i]!;
    const expect: boolean = !IMPASSABLE.has(kind);
    assert.equal(
      grid.value.isWalkableIndex(i),
      expect,
      `第 ${String(i)} 格群系 ${kind} 的可通行判定不符`,
    );
    if (expect) walkable++;
  }
  assert.equal(grid.value.stats().walkable, walkable);
  assert.equal(grid.value.stats().blocked, 320 - walkable);
});

test("[导航] fromScene 与 fromPlan 给出同一份掩码（场景字段没被写错）", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  const scene = new Scene("nav", reg);
  const g = generateWorld({ seed: 909, width: 18, height: 14 });
  assert.equal(g.ok, true);
  if (!g.ok) throw new Error("unreachable");
  assert.equal(assembleWorld(g.value, scene).ok, true);

  const fromPlan = NavGrid.fromPlan(g.value);
  const fromScene = NavGrid.fromScene(scene, 18, 14);
  assert.equal(fromPlan.ok, true);
  assert.equal(fromScene.ok, true);
  if (!fromPlan.ok || !fromScene.ok) throw new Error("unreachable");

  // ★ 两条独立来源（计划的群系表 / 场景的 passable 字段）必须一致。
  //   装配时把 passable 写死成 true 这类错误，只有这样交叉验证才抓得到。
  assert.deepEqual([...fromScene.value.toMask()], [...fromPlan.value.toMask()]);
});

test("[导航] fromScene：漏格要报错，不能当成不可走", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  const scene = new Scene("gap", reg);
  const g = generateWorld({ seed: 5, width: 8, height: 8 });
  assert.equal(g.ok, true);
  if (!g.ok) throw new Error("unreachable");
  assert.equal(assembleWorld(g.value, scene).ok, true);

  // 声称地图比实际大 —— 右侧两列没有地形覆盖
  const r = NavGrid.fromScene(scene, 10, 8);
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, "NAV.BAD_GRID");
  assert.match(r.error.message, /没有地形覆盖/);
});

test("[导航] 坐标换算：1 世界单位 = 1 格，中心是 +0.5", () => {
  const grid = gridOf(["...", "...", "..."]);
  assert.deepEqual(grid.centerOf(0), { x: 0.5, z: 0.5 });
  assert.deepEqual(grid.centerOf(4), { x: 1.5, z: 1.5 }, "下标 4 在 3 格宽的地图上是 (1,1)");
  assert.equal(grid.cellAt(0.5, 0.5), 0);
  assert.equal(grid.cellAt(1.99, 0.01), 1);
  assert.equal(grid.cellAt(3.0, 0.5), -1, "越界必须是 -1，不是夹到边上");
  assert.equal(grid.cellAt(-0.1, 0.5), -1);
  assert.equal(grid.indexOf(0.5, 0), -1, "非整数格坐标不是合法格子");
});

test("[导航] nearestWalkable：取真的最近的，平手取下标小的", () => {
  // 一整列水，中心 (1,1)：左右两个邻格距离都是 1 ⇒ 平手取下标小的那个
  const grid = gridOf([".#.", ".#.", ".#."]);
  const hit = grid.nearestWalkable(1, 1, 3);
  assert.equal(hit, grid.indexOf(0, 1), `平手应取下标小的（得到 ${String(hit)}）`);

  // 半径不够时返回 -1（不能默默给一个很远的格）
  const far = gridOf([".###.", ".###.", ".###.", ".###.", ".###."]);
  assert.equal(far.nearestWalkable(2, 2, 1), -1, "周围一圈全是水，半径 1 应该找不到");
  assert.equal(far.nearestWalkable(2, 2, 2), far.indexOf(0, 2));
});

test("[导航] A* 直线：格数与代价都对得上", () => {
  const grid = gridOf(["...........", "...........", "..........."]);
  const r = grid.findPath(grid.indexOf(0, 1), grid.indexOf(10, 1));
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value.cells.length, 11, "11 格应该产生 11 个路点");
  assert.equal(r.value.cost, 10 * STRAIGHT_COST);
  assert.equal(r.value.snapped, false);
  assertPathValid(grid, r.value.cells);
});

test("[导航] A* 斜线：代价用 14 而不是 10 或 14.14", () => {
  const grid = gridOf([".....", ".....", ".....", ".....", "....."]);
  const r = grid.findPath(grid.indexOf(0, 0), grid.indexOf(4, 4));
  assert.equal(r.ok, true);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value.cells.length, 5);
  assert.equal(r.value.cost, 4 * DIAGONAL_COST);
  assertPathValid(grid, r.value.cells);
});

test("[导航] A* 绕墙：走缺口，且代价等于独立 Dijkstra 的最优代价", () => {
  const grid = gridOf([
    "..........",
    ".####.###.",
    ".####.###.",
    ".####.###.",
    "..........",
  ]);
  const from = grid.indexOf(0, 0);
  const to = grid.indexOf(9, 4);
  const r = grid.findPath(from, to);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  assertPathValid(grid, r.value.cells);
  assert.equal(r.value.cost, dijkstraCost(grid, from, to), "A* 代价必须与朴素 Dijkstra 相同（启发式不能破坏最优性）");
});

test("[导航] 禁止切角：两块礁石的斜缝不能穿过去", () => {
  // (2,0) → (1,1)：斜穿的必经两格 (1,0)/(2,1) 里 (1,0) 是水 ⇒ 必须绕一步
  const grid = gridOf([".#.", "#..", "..."]);
  const a = grid.indexOf(2, 0);
  const b = grid.indexOf(1, 1);
  const r = grid.findPath(a, b);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  assertPathValid(grid, r.value.cells);
  assert.ok(r.value.cost > DIAGONAL_COST, `斜缝应该绕路（得到代价 ${String(r.value.cost)}）`);
  assert.equal(r.value.cost, dijkstraCost(grid, a, b));
});

test("[导航] 被水隔断：报 NO_PATH，并且不带一条自相矛盾的路径", () => {
  const grid = gridOf(["..#..", "..#..", "..#.."]);
  const r = grid.findPath(grid.indexOf(0, 0), grid.indexOf(4, 0));
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, "NAV.NO_PATH");
  assert.match(r.error.message, /没有可走的路/);
});

test("[导航] 连通分量与寻路口径一致（分量相同 ⟺ 找得到路）", () => {
  const grid = gridOf([
    "..#..",
    "..#..",
    "..#..",
    "..#..",
    "..#..",
  ]);
  // 一整列水把地图切成左右两块
  const left = grid.indexOf(1, 1);
  const right = grid.indexOf(3, 1);
  assert.notEqual(grid.componentOf(left), grid.componentOf(right));
  assert.equal(grid.findPath(left, right).ok, false, "分量不同必须寻不到路");

  const a = grid.indexOf(0, 0);
  const b = grid.indexOf(1, 2);
  assert.equal(grid.componentOf(a), grid.componentOf(b));
  assert.equal(grid.findPath(a, b).ok, true, "分量相同必须找得到路");
  assert.equal(grid.componentCount, 2);
});

test("[导航] 斜缝在分量口径里也不连通（两份规则不能分叉）", () => {
  // 2x2：只有 (0,0) 与 (1,1) 可走，斜穿被禁止 ⇒ 两个分量
  const grid = gridOf([".#", "#."]);
  const a = grid.indexOf(0, 0);
  const b = grid.indexOf(1, 1);
  assert.equal(grid.isWalkableIndex(a) && grid.isWalkableIndex(b), true, "两格本身都要能站");
  assert.notEqual(grid.componentOf(a), grid.componentOf(b), "切角被禁止时，这两格必须属于不同分量");
  assert.equal(grid.findPath(a, b).ok, false);
});

test("[导航] 确定性：同输入同输出，两次寻路逐格相同", () => {
  const grid = gridOf([
    "...........",
    ".#########.",
    "...........",
    ".#########.",
    "...........",
  ]);
  const from = grid.indexOf(1, 0);
  const to = grid.indexOf(9, 4);
  const a = grid.findPath(from, to);
  const b = grid.findPath(from, to);
  assert.equal(a.ok && b.ok, true);
  if (!a.ok || !b.ok) throw new Error("unreachable");
  assert.deepEqual(a.value.cells, b.value.cells);
  assert.equal(a.value.expanded, b.value.expanded);

  // 另建一份同样的网格：结果也必须相同（没藏状态）
  const grid2 = gridOf([
    "...........",
    ".#########.",
    "...........",
    ".#########.",
    "...........",
  ]);
  const c = grid2.findPath(from, to);
  assert.equal(c.ok, true);
  if (!c.ok) throw new Error("unreachable");
  assert.deepEqual(a.value.cells, c.value.cells);
});

test("[导航] 起点等于终点：一格、代价 0、不展开", () => {
  const grid = gridOf(["...", "..."]);
  const c = grid.indexOf(1, 1);
  const r = grid.findPath(c, c);
  assert.equal(r.ok, true);
  if (!r.ok) throw new Error("unreachable");
  assert.deepEqual(r.value.cells, [c]);
  assert.equal(r.value.cost, 0);
  assert.equal(r.value.expanded, 0);
});

test("[导航] 下标越界是错误（不是「这里走不了」）", () => {
  const grid = gridOf(["...", "..."]);
  for (const [from, to] of [
    [-1, 0],
    [0, 6],
    [6, 0],
    [0, -3],
  ] as const) {
    const r = grid.findPath(from, to);
    assert.equal(r.ok, false);
    if (r.ok) throw new Error("unreachable");
    assert.equal(r.error.code, "NAV.OUT_OF_RANGE", `${String(from)} → ${String(to)} 应报越界`);
  }
});

test("[导航] 起终点不可站：吸附到最近空格，并在结果里标出来", () => {
  const grid = gridOf(["..#..", ".....", "....."]);
  const r = grid.findPath(grid.indexOf(2, 0), grid.indexOf(3, 2));
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value.snapped, true, "吸附了就必须标出来（静默吸附会让人以为走到了指定格）");
  assert.notEqual(r.value.from, grid.indexOf(2, 0));
  assert.equal(grid.isWalkableIndex(r.value.from), true);
  assert.equal(grid.isWalkableIndex(r.value.to), true);
  assertPathValid(grid, r.value.cells);
});

test("[导航] 附近连落脚点都没有：报 BLOCKED", () => {
  const grid = gridOf(["#####", "#####"]);
  const r = grid.findPath(0, 4, { snapRadius: 2 });
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, "NAV.BLOCKED");
});

test("[导航] 启发式真的在起作用（不是偷偷退化成 Dijkstra）", () => {
  const rows: string[] = [];
  for (let z = 0; z < 64; z++) rows.push(".".repeat(64));
  const grid = gridOf(rows);
  const r = grid.findPath(grid.indexOf(0, 0), grid.indexOf(63, 63));
  assert.equal(r.ok, true);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value.cost, 63 * DIAGONAL_COST);
  // 无启发式时这条对角线的展开数会接近全图（4096）；octile 应把它压到很小
  assert.ok(
    r.value.expanded < 400,
    `展开 ${String(r.value.expanded)} 个节点 —— 启发式没生效（朴素实现约 4000）`,
  );
});

test("[导航] 构造非法参数抛 RangeError（程序员错误不能静默）", () => {
  assert.throws(() => new NavGrid(0, 3, new Uint8Array(0)), RangeError);
  assert.throws(() => new NavGrid(2, 2, new Uint8Array(3)), RangeError);
  assert.throws(() => new NavGrid(2.5, 2, new Uint8Array(5)), RangeError);
});

test("[导航] toMask 返回副本：改它不影响网格", () => {
  const grid = gridOf(["...", "..."]);
  const mask = grid.toMask();
  mask[0] = 0;
  assert.equal(grid.isWalkableIndex(0), true);
});
