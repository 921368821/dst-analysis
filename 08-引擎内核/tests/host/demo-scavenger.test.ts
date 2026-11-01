/**
 * L4 · 演示世界里的拾荒者（批167）
 *
 * 这一条判据只回答一个问题：**这一批做的事情在真机上看得见吗**。
 *
 * ★★ 为什么非要有它：批166 把能力做齐了 —— 模板字段、感知事实、树的两条分支、
 *   一趟执行、20 条判据、16 条变异，全绿。但 `DEMO_MOB_TEMPLATES` 里**没有这一只**，
 *   于是"AI 会捡东西"在演示页上根本不存在。这个缺口用模块级判据**永远发现不了**，
 *   因为它们验的是模块，不是"这一局装了谁"。
 *   与批126 的 `demo-ecology`、批123 的 `attack-target-policy` 同一条纪律：
 *   **产品决定（这一局长什么样）也必须有判据**。
 *
 * ★ 同时钉住两条"老世界没变"：
 *   ① 猎狗与兔子身上**一个背包组件都没有**（否则 `mob-world.ts` ② 的语义被
 *      `carry` 的默认值接管，而所有计数都自洽）；
 *   ② 猎狗打死兔子时 `lootNoRecipient` 仍然在涨（战利品没人收，设计如此）。
 *      只验新功能的话，"给所有生物挂背包"的实现也能让上面全绿。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { registerFactionComponent } from "../../src/extensions/combat/faction.ts";
import { registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { registerFacingComponent } from "../../src/extensions/motion/facing.ts";
import { registerDirSpriteComponent } from "../../src/extensions/render/dir-sprite.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import {
  INVENTORY_TYPE,
  countItem,
  registerInventoryComponents,
} from "../../src/extensions/inventory/inventory.ts";
import { HUNGER_TYPE, Hunger, registerHungerComponent } from "../../src/extensions/survival/hunger.ts";
import { normalizeFoodTable, type FoodTable } from "../../src/extensions/survival/food.ts";
import { ResourceMarker, registerResourceComponent } from "../../src/extensions/worldgen/task-module.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { SpatialHashWorld, makeSceneAccessor } from "../../src/extensions/physics/physics.ts";
import { createMobWorldModule, type MobWorldHandle } from "../../src/extensions/mobs/mob-world.ts";
import {
  DEMO_HOUNDS,
  DEMO_MOB_TEMPLATES,
  DEMO_RABBITS,
  DEMO_SCAVENGERS,
  createDemoFactions,
  isDemoBystander,
  pickDemoMobSpots,
} from "../../src/host/demo-mobs.ts";

/** 与宿主同一个种子与尺寸（演示页的 `WORLD_SEED` / `WORLD_W` / `WORLD_H`）。 */
const SEED = 20261023;
const W = 32;
const H = 24;

const ASSETS = fileURLToPath(new URL("../../web/assets/", import.meta.url));

/** 与宿主同序（`DIRECTION_FRAMES`）。 */
const LETTERS = ["e", "se", "s", "sw", "w", "nw", "n", "ne"] as const;

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerFactionComponent(reg);
  registerMoverComponent(reg);
  registerFacingComponent(reg);
  registerDirSpriteComponent(reg);
  registerInventoryComponents(reg);
  registerHungerComponent(reg);
  registerResourceComponent(reg);
  registerLootComponent(reg);
  if (!reg.has("render.sprite")) reg.register(new Sprite().schema, () => new Sprite());
  return new Scene("demo-scav", reg);
}

function mkCtx(scene: Scene): ModuleContext {
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

/** 与玩家按 E 吃的是同一张表的形状（这里只要 berry 与 meat 两条就够）。 */
const FOOD: FoodTable = (() => {
  const r = normalizeFoodTable({ berry: { nutrition: 15 }, meat: { nutrition: 25, health: 5 } });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
})();

interface Run {
  readonly mod: MobWorldHandle;
  readonly scene: Scene;
  readonly grid: NavGrid;
}

function buildDemoWorld(): Run {
  const scene = mkScene();
  const gen = generateWorld({ seed: SEED, width: W, height: H, maxSitesPerCell: 0 });
  assert.equal(gen.ok, true, gen.ok ? "" : gen.error.code);
  if (!gen.ok) throw new Error("unreachable");
  const gr = NavGrid.fromPlan(gen.value);
  assert.equal(gr.ok, true);
  if (!gr.ok) throw new Error("unreachable");
  const grid = gr.value;

  let playerCell = -1;
  for (let i = 0; i < grid.total; i++) {
    if (!grid.isWalkableIndex(i)) continue;
    if (Math.hypot(grid.cellX(i) - W / 2, grid.cellZ(i) - H / 2) < 3) {
      playerCell = i;
      break;
    }
  }
  assert.notEqual(playerCell, -1, "世界里要有中心附近的可走格");

  const spots = pickDemoMobSpots(
    grid,
    { hounds: DEMO_HOUNDS, rabbits: DEMO_RABBITS, scavengers: DEMO_SCAVENGERS },
    playerCell,
  );
  const mod = createMobWorldModule({
    grid,
    factions: createDemoFactions(),
    templates: DEMO_MOB_TEMPLATES,
    spots,
    range: 14,
    seed: SEED,
    wanderEvery: 18,
    threatDecayTicks: 150,
    aggroCells: 16,
    physics: mkPhysics(scene),
    food: FOOD,
  });
  const r = mod.init(mkCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "模块初始化必须同步成功");
  return { mod, scene, grid };
}

const idsOf = (run: Run, kind: string): number[] => run.mod.nodeIds.filter((id) => run.mod.templateOf(id) === kind);

/** 在某一格上放一丛浆果（`harvestInto` 只认 `game.resource`，不需要任务模块）。 */
function addBerry(run: Run, cell: number, count = 3): number {
  const c = run.grid.centerOf(cell);
  const r = run.scene.spawnAt(`berry@${String(cell)}`, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  const m = new ResourceMarker();
  m.cell = cell;
  m.kind = "berry";
  m.count = count;
  assert.equal(run.scene.attach(r.value.id, () => m).ok, true);
  run.scene.flush();
  return r.value.id;
}

// ── ① 素材：帧真的在磁盘上，而且名字与模板逐字一致 ────────────────────

test("[素材] 每只生物的单帧与八向帧都在 web/assets 里（名字写错 ⇒ 它在走但看不见）", () => {
  for (const tpl of DEMO_MOB_TEMPLATES) {
    assert.ok(existsSync(`${ASSETS}${tpl.frame}.png`), `缺少 ${tpl.frame}.png（模板写了这个 frame）`);
    for (const l of LETTERS) {
      assert.ok(
        existsSync(`${ASSETS}${tpl.frame}_${l}.png`),
        `缺少 ${tpl.frame}_${l}.png —— 那个方向的怪会回落成单帧，看起来像"卡住了"`,
      );
    }
  }
});

// ── ② 这一局里真的有拾荒者，而且只有它带背包 ────────────────────────

test("[配表] 世界里真的有拾荒者（不是只写在模板表里）", () => {
  const run = buildDemoWorld();
  assert.equal(run.mod.nodeIds.length, DEMO_HOUNDS + DEMO_RABBITS + DEMO_SCAVENGERS, "三种活物都要出生");
  assert.equal(idsOf(run, "scavenger").length, DEMO_SCAVENGERS, "模板表里有，抽样里没位置 —— 世界里就是没有它");
});

test("[配表] ★ 猎狗与兔子身上一个背包组件都没有（`lootNoRecipient` 的语义靠这个）", () => {
  const run = buildDemoWorld();
  const bagged: string[] = [];
  for (const id of run.mod.nodeIds) {
    const kind = run.mod.templateOf(id);
    const hasBag = run.scene.find(id)?.get(INVENTORY_TYPE) !== undefined;
    if (hasBag) bagged.push(String(kind));
  }
  assert.deepEqual(
    bagged.sort(),
    Array.from({ length: DEMO_SCAVENGERS }, () => "scavenger").sort(),
    `只有拾荒者该有背包，实际有背包的是 ${bagged.join(" / ")}`,
  );
});

// ── ③ 世界真的在跑这条链：捡 → 进包；饿 → 吃 ─────────────────────────

test("★★ 演示世界里的拾荒者真的会捡（地上放浆果 ⇒ 包里有、统计在涨）", () => {
  const run = buildDemoWorld();
  const scavs = idsOf(run, "scavenger");
  assert.equal(scavs.length, DEMO_SCAVENGERS);
  // 每只脚下放一丛，食量 3 —— 走过去的路上就该捡到
  for (const id of scavs) {
    const n = run.scene.find(id);
    assert.notEqual(n, undefined, "拾荒者要在场景里");
    if (n === undefined) continue;
    const cell = run.grid.cellAt(n.worldPosition.x, n.worldPosition.y);
    assert.ok(cell >= 0, "它得站在一个格里");
    addBerry(run, cell, 3);
  }
  assert.equal(run.mod.stats.foraged, 0, "前置：还没跑，统计应该是 0");

  for (let tick = 0; tick < 120; tick++) run.mod.update(tick, 1 / 30);
  const s = run.mod.stats;
  assert.ok(s.foraged > 0, `120 拍里一次都没捡 —— 能力齐了但世界里没接上（foraged=${String(s.foraged)}）`);
  const total = scavs.reduce((a, id) => a + countItem(run.scene, id, "berry"), 0);
  assert.ok(total > 0, "统计涨了但包里没有浆果 ⇒ 捡的不是这一丛，或者捡完又丢了");
});

test("★★ 饿到阈值以下 ⇒ 它会吃掉包里的东西（不是只会捡）", () => {
  const run = buildDemoWorld();
  const scavs = idsOf(run, "scavenger");
  for (const id of scavs) {
    const n = run.scene.find(id);
    if (n === undefined) continue;
    const cell = run.grid.cellAt(n.worldPosition.x, n.worldPosition.y);
    if (cell >= 0) addBerry(run, cell, 3);
  }
  // 先让它捡到东西
  for (let tick = 0; tick < 120; tick++) run.mod.update(tick, 1 / 30);
  assert.ok(run.mod.stats.foraged > 0, "前置：得先捡到东西，否则下面一条测的是「没得吃」");

  // ---- 现在把它推到饿（★ 改既有组件，不再 attach：attach 会叠第二份，
  //      而 `get()` 永远返回第一份 —— 批165 M1073 / 批166 各踩过一次）
  const id0 = scavs[0];
  assert.notEqual(id0, undefined);
  if (id0 === undefined) return;
  const h = run.scene.find(id0)?.get<Hunger>(HUNGER_TYPE);
  assert.notEqual(h, undefined, "拾荒者该有饱食组件（模板写了 hunger）");
  if (h === undefined) return;
  h.value = 10;
  const before = h.value;
  const ateTicks = run.mod.stats.ate;

  for (let tick = 120; tick < 200; tick++) run.mod.update(tick, 1 / 30);
  assert.ok(run.mod.stats.ate > ateTicks, `饿了 80 拍还没吃（ate=${String(run.mod.stats.ate)}）—— 会捡不会吃`);
  assert.ok(h.value > before, `吃了但饱食度没涨（${String(before)} → ${String(h.value)}）`);
});

// ── ④ 老世界没被改：战利品仍然"没人收" ──────────────────────────────

test("★★ 猎狗打死兔子仍然计 `lootNoRecipient`（给新生物挂背包没有动老语义）", () => {
  const run = buildDemoWorld();
  // 跑够久让猎狗真的吃到兔子（`demo-ecology` 实测 344 拍归零）
  for (let tick = 0; tick < 420; tick++) run.mod.update(tick, 1 / 30);
  const s = run.mod.stats;
  assert.ok(s.kills > 0, `猎狗该真的在打（击杀 ${String(s.kills)}）—— 否则下面那条白验`);
  assert.ok(
    s.lootNoRecipient > 0,
    `击杀 ${String(s.kills)} 只却没有一次"没人收战利品" —— 猎狗的背包是被人偷偷挂上了？`,
  );
  assert.equal(s.lootLost, 0, "`lootLost` 是「包满了」，拾荒者的包没满过");
});

// ── ⑤ 重生落点：旁观者不占位 ────────────────────────────────────────

test("[重生] ★ 只有旁观者不占重生格（`isDemoBystander` 的语义本身）", () => {
  // ★★ 为什么这条是**纯函数**判据，而不是"世界里还空不空"：
  //   两件事都实测过。把旁观者算进阻挡集，确实会让重生时间线整条分叉
  //   （`everyTicks` 还是 90 时满地图空 57 拍）；但间隔调到 75 之后，
  //   那点损失被余量吸收，`zeroTicks` 仍然是 0 ——
  //   于是**世界级的判据对这条改动没有分辨力**（M1100 第一版正是假绿）。
  //   这一条直接验规则本身。它看起来琐碎，但它是这条规则唯一的定义处：
  //   收集点有两处（宿主与生态判据），都调它。
  assert.equal(isDemoBystander("scavenger"), true, "旁观者不该占重生格 —— 它不吃兔子，兔子生成在它旁边没事");
  assert.equal(isDemoBystander("hound"), false, "会打架的必须占位：兔子生成在它脸上 = 生成即被杀");
  // ★ 兔子也返回 false（= 占位）是**保守的老行为**，不是语义要求。
  //   改成 false 变 true 会让候选集变大、重生时间线分叉，但那与"谁该占位"无关 ——
  //   所以这里只要求它不被误判成旁观者。
  assert.equal(isDemoBystander("rabbit"), false, "只有拾荒者是旁观者");
  assert.equal(
    isDemoBystander(null),
    false,
    "查不到的节点不是旁观者 —— 把 null 当旁观者会让所有死掉的怪从阻挡集里漏掉（兔子重生在猎狗脸上）",
  );
});
