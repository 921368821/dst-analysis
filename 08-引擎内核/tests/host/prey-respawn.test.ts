/**
 * L4 · 猎物重生的落点规则（批126）：可走 / 离玩家不远不近 / 不压在活物身上 / 可复现。
 *
 * ★ 为什么这四条要一条一条逼：它们坏掉的表现**完全一样** ——"地图上偶尔没兔子"。
 *   在那片 32×24 的随机地形里靠肉眼分不清"规则写错"与"这一轮运气差"，
 *   所以每条都造一份**只有一个合法格**的语料，让"规则没生效"立刻变成红。
 *
 * ★ 与 `attack-target-policy.test.ts` 同一个理由：玩法判断抽成纯函数之后，
 *   才能在没有浏览器的地方被逼到死角。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { blockAround, pickPreyCell, pickPreyCellAround } from "../../src/host/prey-respawn.ts";

function mkGrid(): NavGrid {
  const g = generateWorld({ seed: 4242, width: 16, height: 12, maxSitesPerCell: 0 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");
  const r = NavGrid.fromPlan(g.value);
  assert.equal(r.ok, true);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
}

function walkables(grid: NavGrid): number[] {
  const out: number[] = [];
  for (let i = 0; i < grid.total; i++) if (grid.isWalkableIndex(i)) out.push(i);
  return out;
}

/** 找一个有足够可走格的世界（地形全水的话判据自己会红，不该静默跳过）。 */
function mkWorld(): { grid: NavGrid; walk: number[] } {
  const grid = mkGrid();
  const walk = walkables(grid);
  assert.ok(walk.length > 40, `夹具要有足够可走格，实际 ${String(walk.length)}`);
  return { grid, walk };
}

const cheb = (grid: NavGrid, a: number, b: number): number =>
  Math.max(Math.abs(grid.cellX(a) - grid.cellX(b)), Math.abs(grid.cellZ(a) - grid.cellZ(b)));

test("★★ 落点必须可走、在距离窗口内、且不在被占的格上", () => {
  const { grid, walk } = mkWorld();
  const player = walk[0]!;
  const live = walk.slice(1, 4);
  const cfg = { minCells: 2, maxCells: 6, blockCells: 1, seed: 7 };
  for (let tick = 0; tick < 25; tick++) {
    const cell = pickPreyCellAround(grid, player, live, tick, cfg);
    if (cell < 0) continue; // 这一轮没地方：下面单独有判据
    assert.equal(grid.isWalkableIndex(cell), true, `第 ${String(tick)} 拍落在不可走格 ${String(cell)}`);
    const d = cheb(grid, cell, player);
    assert.ok(d >= cfg.minCells && d <= cfg.maxCells, `离玩家 ${String(d)} 格，越出 [${String(cfg.minCells)}, ${String(cfg.maxCells)}]`);
    for (const c of live) {
      const dl = cheb(grid, cell, c);
      assert.ok(dl > cfg.blockCells, `落点离活物 ${String(dl)} 格（要求 > ${String(cfg.blockCells)}）`);
    }
  }
});

test("★★★ 被占的格真的被排除：整张图只剩一格可用 ⇒ 必须给那一格", () => {
  // ★ 这条是分辨力的来源：如果 `blocked` 被忽略，结果会是"随机一格"，
  //   而"随机一格"在这份语料里 99% 不等于那一格。
  const { grid, walk } = mkWorld();
  const player = walk[0]!;
  // 目标格：离玩家 3 格、可走
  const target = walk.find((c) => cheb(grid, c, player) === 3);
  assert.notEqual(target, undefined, "夹具要有一格离玩家 3 格的路");
  if (target === undefined) throw new Error("unreachable");
  const blocked = new Set<number>(walk.filter((c) => c !== target));
  const got = pickPreyCell({ grid, playerCell: player, blocked, minCells: 3, maxCells: 3, salt: 1, seed: 7 });
  assert.equal(got, target, "唯一可用的格必须被选中");
});

test("★★ 玩家脚下那一圈不许重生（即使距离窗口只覆盖它）", () => {
  const { grid, walk } = mkWorld();
  const player = walk[0]!;
  // 窗口 0~0：只有玩家自己那一格满足距离。而它被 `blockAround(player,1)` 封掉 ⇒ 无解。
  const got = pickPreyCellAround(grid, player, [], 5, { minCells: 0, maxCells: 0, blockCells: 2, seed: 7 });
  assert.equal(got, -1, "贴脸重生必须被挡住");
  // 对照：窗口挪到 2~2 就有解（证明上面那条是"被玩家那一圈挡住"，不是"窗口过窄"）。
  // ★ 不能用 1~1 当对照：`blockAround(player, 1)` 封的正好就是距离 1 那一圈 ——
  //   两者重叠，对照会跟着一起 -1（这条注释就是那次红的原因）。
  const near = pickPreyCellAround(grid, player, [], 5, { minCells: 2, maxCells: 2, blockCells: 2, seed: 7 });
  assert.ok(near >= 0 && cheb(grid, near, player) === 2, `2 格外该有解，实际 ${String(near)}`);
});

test("★★★ 活物周围 `blockCells` 格真的被封：只差一格就必须 -1", () => {
  // ★ 这条钉的是 `pickPreyCellAround` 里那个 for 循环（`pickPreyCell` 自己的
  //   `blocked` 另有判据）。漏掉它 = 兔子生成在猎狗旁边 = 生成即被杀 ——
  //   而 `respawned` 照涨、地图照空，从数字上完全看不出来。
  const { grid, walk } = mkWorld();
  const player = walk[0]!;
  const target = walk.find((c) => cheb(grid, c, player) === 5);
  assert.notEqual(target, undefined, "夹具要有一格离玩家 5 格的路");
  if (target === undefined) throw new Error("unreachable");
  // 除了 target 全都是活物 ⇒ target 必然紧贴某个活物 ⇒ 必须拒绝
  const live = walk.filter((c) => c !== target);
  const got = pickPreyCellAround(grid, player, live, 3, { minCells: 5, maxCells: 5, blockCells: 1, seed: 7 });
  assert.equal(got, -1, "唯一没被活物占的格紧贴着活物，不该被选中（兔子会一出生就被咬死）");
  // 对照：把活物挪远（只留远处的几只），同一个窗口就该有解 ——
  // 证明上面那条不是"窗口 5~5 本来就没解"。
  const far = walk.filter((c) => cheb(grid, c, player) >= 9);
  assert.ok(far.length > 0, "夹具要有远处的格");
  const ok2 = pickPreyCellAround(grid, player, far, 3, { minCells: 5, maxCells: 5, blockCells: 1, seed: 7 });
  assert.ok(ok2 >= 0, "活物都在远处时，5 格外该有解");
});

test("★ 无解就返回 -1（不抛、不退回第一个可走格）", () => {
  const { grid, walk } = mkWorld();
  const player = walk[0]!;
  // 全图封死
  const all = new Set<number>(walk);
  assert.equal(pickPreyCell({ grid, playerCell: player, blocked: all, minCells: 0, maxCells: 99, salt: 1, seed: 7 }), -1);
  // 窗口写反（min > max）也不许"自动纠正"
  assert.equal(pickPreyCell({ grid, playerCell: player, blocked: new Set(), minCells: 5, maxCells: 2, salt: 1, seed: 7 }), -1);
});

test("★★ 可复现：同参数同格；换 salt 会换格（不长期钉在一个点）", () => {
  const { grid, walk } = mkWorld();
  const player = walk[0]!;
  const q = { grid, playerCell: player, blocked: new Set<number>(), minCells: 2, maxCells: 8, seed: 7 };
  const a = pickPreyCell({ ...q, salt: 3 });
  const b = pickPreyCell({ ...q, salt: 3 });
  assert.equal(a, b, "同参数必须给同一格（回放与截图比对都依赖）");
  const seen = new Set<number>();
  for (let salt = 0; salt < 20; salt++) seen.add(pickPreyCell({ ...q, salt }));
  assert.ok(seen.size >= 3, `20 个 salt 只覆盖 ${String(seen.size)} 格 —— 落点被钉死了`);
});

test("★ blockAround 封的是**切比雪夫方框**（含斜角），且越界不抛", () => {
  const { grid, walk } = mkWorld();
  const center = walk[Math.floor(walk.length / 2)]!;
  const out = new Set<number>();
  blockAround(grid, center, 1, out);
  assert.equal(out.size, 9, "3×3 方框应该是 9 格（含斜角）");
  // 斜角那一格必须在（只用曼哈顿距离的实现会漏掉它）
  const cx = grid.cellX(center);
  const cz = grid.cellZ(center);
  for (const [dx, dz] of [
    [-1, -1],
    [1, -1],
    [-1, 1],
    [1, 1],
  ] as const) {
    const x = cx + dx;
    const z = cz + dz;
    if (x < 0 || z < 0) continue;
    const i = z * grid.width + x;
    if (i >= grid.total) continue;
    assert.equal(out.has(i), true, `斜角 (${String(dx)},${String(dz)}) 没被封 —— 兔子会从斜角被咬死`);
  }
  // 边界格也不许把下标绕到下一行
  const corner = 0;
  const out2 = new Set<number>();
  assert.doesNotThrow(() => blockAround(grid, corner, 2, out2));
  for (const i of out2) assert.ok(i >= 0 && i < grid.total, `越界下标 ${String(i)}`);
  assert.equal(out2.has(grid.width - 1), false, "第一行最右一格不该被左上角的方框封到（下标绕行）");
});
