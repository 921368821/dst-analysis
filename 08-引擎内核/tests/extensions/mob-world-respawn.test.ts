/**
 * L4 · 猎物再生的**机制**（批126）：什么时候补、补多少、补的那只有没有体。
 *
 * ★ 与 `demo-ecology.test.ts` 分工：那个验的是"这个世界玩一分钟还有没有猎物"
 *   （世界的性质）；这个验的是"规则本身每一处都对"（窗口节流 / 上限 / 没地方 /
 *   配置错误）。混在一起的话，生态那条一红就不知道该查配表还是查实现。
 *
 * ★ 两条最容易写成假绿：
 *   ① 只断言 `respawned > 0`：补在**不可走格上**、补成**另一种生物**、
 *      补完**没有物理体**，它都还 > 0。所以要同时读"落在哪格 / 什么 kind / 有没有体"。
 *   ② 只数"现在有几只"：`max` 写反（当成下限）时，兔子会越补越多而判据照绿 ——
 *      要先造出"已经到上限"的语料，再看它一只是不是都不补。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { createFactions, registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { registerDirSpriteComponent } from "../../src/extensions/render/dir-sprite.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { SpatialHashWorld, makeSceneAccessor } from "../../src/extensions/physics/physics.ts";
import {
  MOB_WORLD_BAD_MODULE,
  createMobWorldModule,
  type MobRespawnOptions,
  type MobWorldHandle,
} from "../../src/extensions/mobs/mob-world.ts";

const RABBIT = {
  kind: "rabbit",
  frame: "rabbit",
  width: 0.8,
  height: 0.8,
  radius: 0.3,
  maxHp: 4,
  damage: 0,
  range: 1.4,
  cooldownTicks: 20,
  speed: 0.6,
  team: "prey",
  loot: [],
};

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  registerInventoryComponents(reg);
  registerLootComponent(reg);
  if (!reg.has("render.sprite")) reg.register(new Sprite().schema, () => new Sprite());
  return new Scene("respawn", reg);
}

function makeCtx(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  return {
    log: {
      channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }),
    },
    events: { emit: () => undefined, on: () => () => undefined },
    services,
    platform: {},
    random: { next: () => 0 },
    module: () => undefined,
  } as unknown as ModuleContext;
}

function mkPhysics(scene: Scene): SpatialHashWorld {
  return new SpatialHashWorld(
    makeSceneAccessor((id) => {
      const n = scene.find(id);
      if (n === undefined) return undefined;
      return {
        id: n.id,
        worldPosition: () => n.worldPosition,
        setLocalPosition: (x: number, y: number) => n.setLocalPosition(x, y),
      };
    }),
  );
}

function cellsOf(n: number): { grid: NavGrid; cells: number[] } {
  const g = generateWorld({ seed: 8181, width: 18, height: 14, maxSitesPerCell: 0 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");
  const gr = NavGrid.fromPlan(g.value);
  assert.equal(gr.ok, true);
  if (!gr.ok) throw new Error("unreachable");
  const grid = gr.value;
  const cells: number[] = [];
  for (let i = 0; i < grid.total && cells.length < n; i++) if (grid.isWalkableIndex(i)) cells.push(i);
  assert.ok(cells.length >= n, `需要 ${String(n)} 个可走格`);
  return { grid, cells };
}

function mkMod(
  scene: Scene,
  grid: NavGrid,
  cells: readonly number[],
  physics: SpatialHashWorld,
  respawn?: MobRespawnOptions,
): MobWorldHandle {
  const mod = createMobWorldModule({
    grid,
    factions: createFactions(),
    templates: [RABBIT],
    spots: cells.map((cell) => ({ template: 0, cell })),
    range: 10,
    seed: 3,
    wanderEvery: 6,
    physics,
    ...(respawn === undefined ? {} : { respawn }),
  });
  const r = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "模块初始化必须同步成功");
  mod.update(0, 1 / 30);
  return mod;
}

const preyCount = (mod: MobWorldHandle): number => mod.nodeIds.length;

test("★ 没给 respawn ⇒ 老行为：打光之后不再有（这条是下面每条的对照）", () => {
  const scene = mkScene();
  const { grid, cells } = cellsOf(3);
  const physics = mkPhysics(scene);
  const mod = mkMod(scene, grid, cells, physics);
  for (const id of mod.nodeIds) scene.destroy(id);
  scene.flush();
  for (let tick = 1; tick <= 300; tick++) mod.update(tick, 1 / 30);
  assert.equal(mod.stats.respawned, 0);
  assert.equal(preyCount(mod), 0);
});

test("★★★ 打光之后按窗口补回来：落在指定格、kind 对、**同一拍就有物理体**", () => {
  const scene = mkScene();
  const { grid, cells } = cellsOf(3);
  const physics = mkPhysics(scene);
  let pickTo = cells[2]!;
  let asked = 0;
  const mod = mkMod(scene, grid, cells, physics, {
    everyTicks: 10,
    kind: "rabbit",
    max: 4,
    template: "rabbit",
    pickCell: () => {
      asked++;
      return pickTo;
    },
  });
  // ★ 增量口径：`mkMod` 那一拍（tick 0）本身就可能补过一只 ——
  //   窗口计时从 -inf 起算，所以"第一拍就问"是设计如此，不是 bug。
  //   用绝对值断言的话，这条会变成"验 mkMod 干了什么"，而不是"清空之后补得对"。
  const base = mod.stats.respawned;
  for (const id of mod.nodeIds.slice()) scene.destroy(id);
  scene.flush();
  for (let tick = 1; tick <= 10; tick++) mod.update(tick, 1 / 30);

  assert.equal(mod.stats.respawned - base, 1, "10 拍里（窗口 10）只该补一只 —— 一个窗口最多一只");
  assert.ok(asked >= 1, "pickCell 该被问过");
  assert.equal(mod.stats.lastRespawnCell, pickTo, "落点必须是宿主给的那一格");
  assert.equal(mod.stats.lastRespawnError, "");
  assert.equal(preyCount(mod), 1);

  const born = mod.nodeIds[0]!;
  const node = scene.find(born);
  assert.notEqual(node, undefined, "补出来的节点要真的在场景里");
  if (node === undefined) throw new Error("unreachable");
  // ★ 序号不必是 1：`mkMod` 那一拍可能已经补过一只（见上面的 base）。要验的是
  //   **命名空间**（`mob#r<n>`）与出生点那批（`mob#0..N`）分得开 —— 撞名会让
  //   "按名字找节点"的存档与 Lua 脚本找到另一只。
  assert.match(node.name, /^mob#r\d+$/, `重生节点要能与出生点那批区分，实际叫 ${node.name}`);
  assert.equal(mod.templateOf(born), "rabbit");
  // ★ 同一拍就要有体：`respawnPrey` 在 `syncBodies` **之前**，否则新生的那只
  //   会白白等一拍（33ms）—— 正是批125 修掉的那种空窗。
  assert.equal(physics.has(born), true, "补出来的那一只必须当场就有物理体");
  assert.equal(mod.stats.bodies, mod.stats.mobs, "体数与活物数必须一致（新生的那只算在内）");
});

test("★★ 到上限就一只都不补（`max` 不是下限）", () => {
  const scene = mkScene();
  const { grid, cells } = cellsOf(2);
  const physics = mkPhysics(scene);
  let picks = 0;
  const mod = mkMod(scene, grid, cells, physics, {
    everyTicks: 5,
    kind: "rabbit",
    max: 2,
    template: "rabbit",
    pickCell: () => {
      picks++;
      return cells[0]!;
    },
  });
  // 前半段：已经两只（= 上限），一只都不该补
  for (let tick = 1; tick <= 100; tick++) mod.update(tick, 1 / 30);
  assert.equal(mod.stats.respawned, 0, "已经两只了（= 上限），不该再补");
  assert.equal(picks, 0, "到了上限连落点都不该问（问一次就是一次全图扫描）");
  assert.equal(preyCount(mod), 2);

  // 后半段：**打光之后才补，且只补到上限为止**
  for (const id of mod.nodeIds.slice()) scene.destroy(id);
  scene.flush();
  for (let tick = 101; tick <= 400; tick++) mod.update(tick, 1 / 30);
  assert.equal(preyCount(mod), 2, `补到上限就该停，实际 ${String(preyCount(mod))} 只`);
  const atEnd = mod.stats.respawned;
  assert.ok(atEnd >= 2, `该补过（补了 ${String(atEnd)} 只）`);
  for (let tick = 401; tick <= 500; tick++) mod.update(tick, 1 / 30);
  assert.equal(mod.stats.respawned, atEnd, "到上限之后一只都不许再补（max 不是下限）");
});

test("★★ 没地方可补（pickCell 返回 -1）⇒ 不补、不报错，下一个窗口还能补", () => {
  const scene = mkScene();
  const { grid, cells } = cellsOf(2);
  const physics = mkPhysics(scene);
  let allow = false;
  const mod = mkMod(scene, grid, cells, physics, {
    everyTicks: 10,
    kind: "rabbit",
    max: 3,
    template: "rabbit",
    pickCell: () => (allow ? cells[1]! : -1),
  });
  for (const id of mod.nodeIds.slice()) scene.destroy(id);
  scene.flush();
  for (let tick = 1; tick <= 50; tick++) mod.update(tick, 1 / 30);
  assert.equal(mod.stats.respawned, 0, "没地方时不该补");
  assert.equal(mod.stats.lastRespawnError, "", "没地方不是错误（不该报错码）");
  assert.equal(preyCount(mod), 0);

  allow = true;
  const base = mod.stats.respawned;
  // ★ 只推进**一个窗口**：推 40 拍会一路补到上限（3 只），那时断言 1 只就成了
  //   "验我自己的算术"而不是"验窗口放开之后能补"。
  for (let tick = 51; tick <= 61; tick++) mod.update(tick, 1 / 30);
  assert.equal(mod.stats.respawned - base, 1, "放开之后下一个窗口该补上一只");
  assert.equal(preyCount(mod), 1);
});

test("★★ 窗口真的在节流：补一只之后要再等 `everyTicks` 才问下一次", () => {
  const scene = mkScene();
  const { grid, cells } = cellsOf(1);
  const physics = mkPhysics(scene);
  const tickAsked: number[] = [];
  const mod = mkMod(scene, grid, cells, physics, {
    everyTicks: 30,
    kind: "rabbit",
    max: 99,
    template: "rabbit",
    pickCell: (tick) => {
      tickAsked.push(tick);
      return cells[0]!;
    },
  });
  for (let tick = 1; tick <= 100; tick++) mod.update(tick, 1 / 30);
  assert.ok(tickAsked.length >= 2, `100 拍里窗口 30 该问至少 2 次，实际 ${String(tickAsked.length)}`);
  for (let i = 1; i < tickAsked.length; i++) {
    const gap = tickAsked[i]! - tickAsked[i - 1]!;
    assert.ok(gap >= 30, `第 ${String(i)} 次与上一次只隔 ${String(gap)} 拍（窗口 30）`);
  }
});

test("★★ 配置错误在 init 当场报（别等第十秒「少了一只兔子」）", () => {
  const caseOf = (rp: MobRespawnOptions): { ok: boolean; code?: string } => {
    const scene = mkScene();
    const { grid, cells } = cellsOf(1);
    const mod = createMobWorldModule({
      grid,
      factions: createFactions(),
      templates: [RABBIT],
      spots: [{ template: 0, cell: cells[0]! }],
      range: 10,
      seed: 3,
      respawn: rp,
    });
    const r = mod.init(makeCtx(scene)) as { ok: boolean; error?: { code: string } } | undefined;
    return r === undefined ? { ok: true } : { ok: r.ok, ...(r.error === undefined ? {} : { code: r.error.code }) };
  };
  const pick = (): number => 0;
  assert.equal(caseOf({ everyTicks: 0, kind: "rabbit", max: 2, template: "rabbit", pickCell: pick }).code, MOB_WORLD_BAD_MODULE);
  assert.equal(caseOf({ everyTicks: 10, kind: "rabbit", max: 0, template: "rabbit", pickCell: pick }).code, MOB_WORLD_BAD_MODULE);
  assert.equal(caseOf({ everyTicks: 10, kind: "rabbit", max: 2, template: "hound", pickCell: pick }).code, MOB_WORLD_BAD_MODULE);
  // 合法配置必须过得去（否则上面三条可能只是"所有配置都失败"）
  assert.equal(caseOf({ everyTicks: 10, kind: "rabbit", max: 2, template: "rabbit", pickCell: pick }).ok, true);
});
