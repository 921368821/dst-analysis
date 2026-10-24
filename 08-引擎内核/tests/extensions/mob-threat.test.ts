/**
 * L4 · 仇恨接线：**打了就跑，跑不掉**
 *
 * 批69 之前，生物追人只靠"看见"。于是"打一下、退到视野外"就等于把仇恨清零 ——
 * 这不是设计，是"没有记忆"的副作用。这个文件验的就是那份记忆。
 *
 * ★ 每条判据都要有一个**对照组**或**前提断言**，否则"追到了"可能只是感知半径够大：
 *   · ① 的对照组是 `threat` 不传（同一份语料、同一个半径）→ 必须追不到；
 *   · ② 先断言"它确实在感知半径之外"，再断言"仍然被追"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { Attacker, registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { FactionMember, createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { HEALTH_TYPE, Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { createThreatTable, type ThreatTable } from "../../src/extensions/combat/threat.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { createMobBrain } from "../../src/extensions/mobs/mob-brain.ts";

interface Grid {
  cellAt(x: number, z: number): number;
  cellX(index: number): number;
  cellZ(index: number): number;
  isWalkable(cx: number, cz: number): boolean;
}

function rectGrid(w = 60, h = 60): Grid {
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
  return new Scene("threat-brain", reg);
}

function unit(
  scene: Scene,
  name: string,
  x: number,
  z: number,
  team: string,
  opts: { hp?: number; armed?: boolean } = {},
): number {
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
  return id;
}

const FOE_TABLE = () => {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
};

/** 造一个"打了就跑"的局面：猎狗在 (10,10)，猎物在 (30,30)（**远超**感知半径 8）。 */
function setup(opts: { decay?: number; aggro?: number; threat?: boolean; record?: boolean } = {}): {
  scene: Scene;
  hound: number;
  prey: number;
  table: ThreatTable | null;
  grid: Grid;
} {
  const scene = mkScene();
  const hound = unit(scene, "hound", 10.5, 10.5, "hunter");
  const prey = unit(scene, "rabbit", 30.5, 30.5, "prey");
  const table =
    opts.threat === false ? null : createThreatTable({ decayTicks: opts.decay ?? 100 });
  // 猎物打过猎狗一次（这就是"记忆"的全部来源）
  // ★ `record: false` 用于"目标被销毁"那条：那里要**自己**摆一条指向一次性节点的记录，
  //   否则这条长命的猎物会让"不追"永远不成立（踩过一次——判据红了，被测代码是对的）。
  if (opts.record !== false) table?.add(hound, prey, 2, 0);
  return { scene, hound, prey, table, grid: rectGrid() };
}

test("[仇恨] ★ 敌人在感知半径外，但记着仇 ⇒ 仍然追（对照组：不传仇恨表就追不到）", () => {
  const withThreat = setup();
  const brainA = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: withThreat.table ?? undefined });
  const dA = brainA.decide(withThreat.scene, withThreat.hound, 1, withThreat.grid);
  assert.equal(dA?.kind, "hunt", "记仇就该去追");
  assert.equal(dA?.targetNodeId, withThreat.prey);

  // 对照组：同一份场景、同一个半径，只是没有仇恨表
  const noThreat = setup({ threat: false });
  const brainB = createMobBrain({ factions: FOE_TABLE(), range: 8 });
  const dB = brainB.decide(noThreat.scene, noThreat.hound, 1, noThreat.grid);
  assert.notEqual(dB?.kind, "hunt", "没有仇恨表时它连看都看不见 —— 这条对照组证明是「记忆」起的作用");
});

test("[仇恨] 忘了之后就不再追（decay 的边界）", () => {
  const { scene, hound, prey, table, grid } = setup({ decay: 10 });
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: table ?? undefined });
  assert.equal(brain.decide(scene, hound, 9, grid)?.targetNodeId, prey, "第 9 tick 还该记着");
  const late = brain.decide(scene, hound, 10, grid);
  assert.notEqual(late?.kind, "hunt", "第 10 tick 该忘了（否则「跑远一点」永远甩不掉）");
});

test("[仇恨] ★ 记仇**优先于**感知：视野里有个更近的，也先追打过我的那个", () => {
  const { scene, hound, prey, table, grid } = setup();
  // 在猎狗身边放一个"更近的敌人"（视野内）
  const near = unit(scene, "rabbit-near", 12.5, 10.5, "prey");
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: table ?? undefined });
  const d = brain.decide(scene, hound, 1, grid);
  assert.equal(d?.targetNodeId, prey, `应追打过我的那个（${String(prey)}），实际 ${String(d?.targetNodeId)}`);
  assert.notEqual(d?.targetNodeId, near);
});

test("[仇恨] 打得更狠的人优先", () => {
  const { scene, hound, prey, table, grid } = setup();
  const hitter = unit(scene, "rabbit-hitter", 28.5, 30.5, "prey");
  table?.add(hound, hitter, 9, 0);
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: table ?? undefined });
  assert.equal(brain.decide(scene, hound, 1, grid)?.targetNodeId, hitter);
  assert.ok(prey > 0);
});

test("[仇恨] ★ 目标死了（hp 归零但节点还在）⇒ 不追（尸体不该钉住一群人）", () => {
  const { scene, hound, prey, table, grid } = setup();
  const hp = scene.find(prey)?.get<Health>(HEALTH_TYPE);
  assert.ok(hp !== undefined, "前提：猎物有血量组件");
  if (hp === undefined) return;
  hp.hp = 0;
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: table ?? undefined });
  assert.notEqual(brain.decide(scene, hound, 1, grid)?.kind, "hunt");
});

test("[仇恨] ★ 目标被销毁 ⇒ 不追（否则会朝一个不存在的 id 走一辈子）", () => {
  const { scene, hound, table, grid } = setup({ record: false });
  const prey = scene.spawnAt("gone", 30.5, 30.5);
  assert.equal(prey.ok, true);
  if (!prey.ok) return;
  scene.flush();
  table?.add(hound, prey.value.id, 5, 0);
  scene.destroy(prey.value.id);
  scene.flush();
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: table ?? undefined });
  const d = brain.decide(scene, hound, 1, grid);
  assert.notEqual(d?.kind, "hunt", "目标不在场景里就不该被追");
});

test("[仇恨] ★ 友军记了仇也不追（阵营优先于仇恨）", () => {
  const { scene, hound, table, grid } = setup();
  const buddy = unit(scene, "hound-buddy", 30.5, 28.5, "hunter");
  table?.add(hound, buddy, 9, 0); // 误伤自己人
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: table ?? undefined });
  const d = brain.decide(scene, hound, 1, grid);
  assert.notEqual(d?.targetNodeId, buddy, "不能追友军（追了就是内讧）");
});

test("[仇恨] 超出记仇半径（格）⇒ 放弃", () => {
  const { scene, hound, table, grid } = setup();
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, aggroCells: 10, threat: table ?? undefined });
  // 猎物在 (30.5,30.5)，离 (10.5,10.5) 约 28 格 > 10
  assert.notEqual(brain.decide(scene, hound, 1, grid)?.kind, "hunt");
});

test("[仇恨] 和平生物（没有攻击组件）被打了也只漫游", () => {
  const { scene, table, grid } = setup();
  const peaceful = unit(scene, "bird", 5.5, 5.5, "hunter", { armed: false });
  table?.add(peaceful, 999, 5, 0);
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: table ?? undefined });
  const d = brain.decide(scene, peaceful, 1, grid);
  assert.notEqual(d?.kind, "hunt", "没有攻击组件的生物不该因为被打了就变成猎手");
});

test("[仇恨] forget 之后立刻放弃（击杀时宿主会调它）", () => {
  const { scene, hound, prey, table, grid } = setup();
  const brain = createMobBrain({ factions: FOE_TABLE(), range: 8, threat: table ?? undefined });
  assert.equal(brain.decide(scene, hound, 1, grid)?.targetNodeId, prey);
  table?.forget(prey);
  // 同一 tick 有缓存，换一个 tick 再问
  assert.notEqual(brain.decide(scene, hound, 2, grid)?.kind, "hunt");
});
