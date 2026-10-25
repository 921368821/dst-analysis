/**
 * L4 · 生物本能：追谁、走去哪、以及**同一 tick 只感知一次**
 *
 * ★ 四条最容易写成假绿的：
 *   ① "追最近的"要用**两个距离不同的敌人**验。只有一个敌人时，
 *      "追第一个找到的"与"追最近的"结果一样。
 *   ② "友军不追"必须验，否则把阵营过滤删掉也全绿 —— 而那一删，
 *      混战里就变成所有人乱打（批65 刚补上的东西从这里漏回来）。
 *   ③ "中立要追"也必须验：把过滤写成"只要**有阵营**就跳过"，
 *      会让所有没编队的生物变成摆设。
 *   ④ 缓存的判据要**跨模块**验（`move` 问一次、`combat` 再问一次），
 *      只验"同一个调用连问两次"的话，缓存只对连续调用生效也能过 ——
 *      而那正好是真实调用序列里不会出现的情形。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { Attacker, registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { FactionMember, createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { createMobBrain } from "../../src/extensions/mobs/mob-brain.ts";

interface Grid {
  cellAt(x: number, z: number): number;
  cellX(index: number): number;
  cellZ(index: number): number;
  isWalkable(cx: number, cz: number): boolean;
}

/** 一个矩形全可走（除了外围一圈）的假网格 —— 判据不依赖世界生成的随机结果。 */
function rectGrid(w = 40, h = 40): Grid {
  return {
    cellAt: (x, z) => {
      const cx = Math.floor(x);
      const cz = Math.floor(z);
      if (cx < 0 || cx >= w || cz < 0 || cz >= h) return -1;
      return cz * w + cx;
    },
    cellX: (i) => i % w,
    cellZ: (i) => (i - (i % w)) / w,
    isWalkable: (cx, cz) => cx > 0 && cx < w - 1 && cz > 0 && cz < h - 1,
  };
}

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  return new Scene("brain", reg);
}

interface Unit {
  readonly id: number;
}

function unit(
  scene: Scene,
  name: string,
  x: number,
  z: number,
  team: string,
  opts: { hp?: number; armed?: boolean } = {},
): Unit {
  const n = scene.spawnAt(name, x, z);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  const id = n.value.id;
  const h = new Health();
  h.hp = opts.hp ?? 5;
  h.maxHp = opts.hp ?? 5;
  scene.attach(id, () => h);
  const f = new FactionMember();
  f.team = team;
  scene.attach(id, () => f);
  if (opts.armed !== false) {
    const a = new Attacker();
    a.damage = 1;
    a.range = 1.6;
    a.cooldownTicks = 10;
    scene.attach(id, () => a);
  }
  scene.flush();
  return { id };
}

const FOE_TABLE = () => {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
};

test("[生物·本能] 视野里有两个敌人：追**最近**的那个（不是第一个找到的）", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  unit(scene, "rabbit-far", 17.5, 10.5, "prey"); // 先放远的
  const near = unit(scene, "rabbit-near", 12.5, 10.5, "prey"); // 后放近的
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const d = brain.decide(scene, me.id, 1, rectGrid());
  assert.equal(d?.kind, "hunt");
  assert.equal(d?.targetNodeId, near.id, "必须先看完全部候选再取最近的");
  assert.equal(d?.cell, 10 * 40 + 12, "目标格 = 猎物所在格");
});

test("[生物·本能] 视野里只有友军：不追，去漫游", () => {
  const scene = mkScene();
  const me = unit(scene, "hound-a", 10.5, 10.5, "hunter");
  unit(scene, "hound-b", 11.5, 10.5, "hunter");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const d = brain.decide(scene, me.id, 1, rectGrid());
  assert.equal(d?.kind, "wander", "友军不是猎物");
  assert.equal(d?.targetNodeId, -1);
});

test("[生物·本能] 中立的生物**要追**（没编队 ≠ 免战牌）", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  const stray = unit(scene, "stray", 11.5, 10.5, "");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const d = brain.decide(scene, me.id, 1, rectGrid());
  assert.equal(d?.kind, "hunt");
  assert.equal(d?.targetNodeId, stray.id, "把「有阵营就跳过」写进过滤会让所有中立生物变摆设");
});

test("[生物·本能] 超出 leash：不追（哪怕在感知半径里）", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 2.5, 2.5, "hunter");
  unit(scene, "rabbit", 12.5, 2.5, "prey"); // 10 格远
  const wide = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  assert.equal(wide.decide(scene, me.id, 1, rectGrid())?.kind, "hunt", "前置条件：不设 leash 时会追");
  const leashed = createMobBrain({ factions: FOE_TABLE(), range: 20, leashCells: 4 });
  assert.equal(leashed.decide(scene, me.id, 1, rectGrid())?.kind, "wander", "追出 4 格就放弃");
});

test("[生物·本能] 没有攻击组件的生物不感知、不追（和平生物）", () => {
  const scene = mkScene();
  const me = unit(scene, "rabbit", 10.5, 10.5, "prey", { armed: false });
  unit(scene, "hound", 11.5, 10.5, "hunter");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const d = brain.decide(scene, me.id, 1, rectGrid());
  assert.equal(d?.kind, "wander");
  assert.equal(brain.senseCount, 0, "和平生物连感知都不该做（每一 tick 都是白扫一遍全树）");
});

test("[生物·本能] ★ 同一 tick 跨模块各问一次，只感知一次", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  unit(scene, "rabbit", 11.5, 10.5, "prey");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const grid = rectGrid();
  const a = brain.decide(scene, me.id, 7, grid); // move 模块
  const b = brain.decide(scene, me.id, 7, grid); // combat 模块
  assert.deepEqual(a, b, "同一 tick 必须给出同一个答案");
  assert.equal(brain.senseCount, 1, `实际感知 ${String(brain.senseCount)} 次（>1 = 缓存没生效 ⇒ 二十只生物就是每帧几十次全树扫描）`);
  brain.decide(scene, me.id, 8, grid);
  assert.equal(brain.senseCount, 2, "下一 tick 必须重新感知（目标会动）");
});

test("[生物·本能] 漫游是 (seed,id,epoch) 的纯函数：两个实例给出同一格", () => {
  // ★ 为什么比 20 轮而不是 2 轮：改成 `Math.random()` 之后，两次调用映射到
  //   **同一格**的概率约 1/80（span = 2*4+1 = 9 ⇒ 80 个有效偏移）。
  //   只比两次 ⇒ 1.25% 的概率让变异「看起来没被抓住」—— M243 在全量跑里
  //   就这么假绿过一次：单跑必过、全量偶发，是最难查的那一类。
  //   这正是 M188（单点断言恰好落在陆地）的**随机版**：判据的通过与
  //   实现无关，只取决于这一次的运气。比 20 轮后假绿概率降到 (1/80)^19。
  const scene = mkScene();
  const me = unit(scene, "rabbit", 20.5, 20.5, "prey", { armed: false });
  const grid = rectGrid();
  for (let round = 0; round < 20; round++) {
    const b1 = createMobBrain({ factions: FOE_TABLE(), range: 5, seed: 4242 });
    const b2 = createMobBrain({ factions: FOE_TABLE(), range: 5, seed: 4242 });
    const c1 = b1.decide(scene, me.id, 100, grid)?.cell;
    const c2 = b2.decide(scene, me.id, 100, grid)?.cell;
    assert.equal(c1, c2, `第 ${String(round)} 轮：同种子同 id 同 epoch 必须走同一格（回放依赖这条）`);
    assert.equal(typeof c1, "number");
  }
});

test("[生物·本能] 漫游：不同个体不会挤向同一格", () => {
  const scene = mkScene();
  const grid = rectGrid();
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 5, seed: 7, wanderRadiusCells: 4 });
  const cells = new Set<number>();
  const ids: number[] = [];
  for (let i = 0; i < 20; i++) ids.push(unit(scene, `r${String(i)}`, 20.5, 20.5, "prey", { armed: false }).id);
  for (const id of ids) {
    const c = brain.decide(scene, id, 100, grid)?.cell;
    if (typeof c === "number") cells.add(c);
  }
  assert.ok(
    cells.size >= 15,
    `20 个个体只散到 ${String(cells.size)} 个格 —— 全都朝一个方向走，画面上像一队人`,
  );
});

test("[生物·本能] 漫游格一定可走（扫 200 个 epoch）", () => {
  const scene = mkScene();
  // ★ 放在**地图中间**：贴着边界放的话，半径 5 会够到界外，
  //   于是「找不到可走格」是正常结果，而判据会把它当成 bug（最初就是这么写错的）。
  const me = unit(scene, "rabbit", 20.5, 20.5, "prey", { armed: false });
  const grid = rectGrid(40, 40);
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 5, seed: 99, wanderRadiusCells: 5 });
  let checked = 0;
  for (let e = 0; e < 200; e++) {
    const d = brain.decide(scene, me.id, e * 24, grid);
    if (d === null) continue;
    const cx = grid.cellX(d.cell);
    const cz = grid.cellZ(d.cell);
    assert.equal(grid.isWalkable(cx, cz), true, `epoch ${String(e)} 选到了不可走的格 (${String(cx)},${String(cz)})`);
    checked++;
  }
  assert.equal(checked, 200, "站在地图中间时不该有「找不到可走格」");
});

test("[生物·本能] 目标被打死（节点销毁）之后回到漫游，不追尸体", () => {
  const scene = mkScene();
  const me = unit(scene, "hound", 10.5, 10.5, "hunter");
  const prey = unit(scene, "rabbit", 11.5, 10.5, "prey");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 20 });
  const grid = rectGrid();
  assert.equal(brain.decide(scene, me.id, 1, grid)?.kind, "hunt");
  scene.destroy(prey.id);
  scene.flush();
  assert.equal(brain.decide(scene, me.id, 2, grid)?.kind, "wander", "感知是每 tick 重算的，而不是把 id 记下来");
});

test("[生物·本能] 构造参数非法：抛 RangeError（不是静默用默认值）", () => {
  const f = FOE_TABLE();
  assert.throws(() => createMobBrain({ factions: f, range: 0 }), RangeError);
  assert.throws(() => createMobBrain({ factions: f, range: 5, wanderRadiusCells: 0 }), RangeError);
  assert.throws(() => createMobBrain({ factions: f, range: 5, wanderEvery: 0 }), RangeError);
  assert.throws(() => createMobBrain({ factions: f, range: 5, leashCells: -1 }), RangeError);
});
