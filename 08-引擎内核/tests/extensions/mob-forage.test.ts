/**
 * L4 · 拾荒：会捡东西、会饿、饿了会吃（批166，ONLINE-READINESS-PLAN 的 P3 收尾）
 *
 * ★ 这一批刻意**没有**给所有生物挂背包。`mob-world.ts` ② 那条语义
 *   （猎狗打死兔子 ⇒ 猎狗没有背包 ⇒ `LOOT.NO_OWNER` ⇒ 计入 `lootNoRecipient`，
 *   与"包满了"必须分开）是设计，不是缺陷。于是能力由**模板**选择：
 *   写了 `carry` / `hunger` 的生物才有这两件事，没写的生物一个组件都不多。
 *
 * ★ 三条最容易写成假绿的：
 *   ① 只断言"它能捡到东西"：捡的是什么、捡的是不是最近的那一格、包满时有没有
 *      静默继续试 —— 这三件事都不影响"捡到了"。
 *   ② 只断言"饿了就吃"：不验**阈值边界**（正好 50% 算不算饿）与"包里有熟肉时
 *      先吃哪一样"，实现里把 `<` 写成 `<=`、把营养最低写成最高都照样绿。
 *   ③ 只验新功能、不验**老世界没变**：给所有生物挂背包的实现也能让上面全绿，
 *      而那一刻猎狗的语义已经被改掉了。所以这里有一条"没写 carry 的生物
 *      一个组件都不多"，以及一条"拾荒者打死猎物，战利品进它自己的包"。
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
import {
  INVENTORY_TYPE,
  addItem,
  countItem,
  registerInventoryComponents,
} from "../../src/extensions/inventory/inventory.ts";
import { HUNGER_TYPE, Hunger, registerHungerComponent } from "../../src/extensions/survival/hunger.ts";
import { normalizeFoodTable, type FoodTable } from "../../src/extensions/survival/food.ts";
import { ResourceMarker, registerResourceComponent } from "../../src/extensions/worldgen/task-module.ts";
import { registerLootComponent } from "../../src/extensions/combat/loot.ts";
import { validateTemplate, MOB_BAD_TEMPLATE } from "../../src/extensions/mobs/mob-template.ts";
import { spawnMob } from "../../src/extensions/mobs/spawn-mob.ts";
import { createMobBrain, type MobFacts } from "../../src/extensions/mobs/mob-brain.ts";
import { chooseFromFacts } from "../../src/extensions/mobs/mob-facts.ts";
import { createMobTree } from "../../src/extensions/mobs/mob-tree.ts";
import { forageIntentOf, runForagePass } from "../../src/extensions/mobs/mob-forage.ts";
import { createMobWorldModule } from "../../src/extensions/mobs/mob-world.ts";
import { INTENT_NO_FOOD_TABLE } from "../../src/extensions/actions/executor.ts";

const BASE = {
  frame: "rabbit",
  width: 0.8,
  height: 0.8,
  radius: 0.3,
  maxHp: 4,
  damage: 0,
  range: 1.4,
  cooldownTicks: 20,
  speed: 0.6,
  team: "scav",
  loot: [],
};

const PLAIN = { ...BASE, kind: "plain" };
const BAGGED = { ...BASE, kind: "bagged", carry: { stacks: 3, stack: 10 }, hunger: 100 };
const SCAVENGER = { ...BASE, kind: "scavenger", damage: 1, speed: 2.0, team: "hunter", carry: { stacks: 4, stack: 10 }, hunger: 100 };
const RABBIT = { ...BASE, kind: "rabbit", team: "prey", loot: [{ kind: "meat", count: 2 }] };

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
  return new Scene("forage", reg);
}

function makeCtx(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  return {
    log: { channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }) } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  } as unknown as ModuleContext;
}

/** 一块真世界：导航网格 + 前 n 个可走格 + 至少一个**不可走**格（崖下/水上的那丛草）。 */
function realWorld(seed: number, n: number): { grid: NavGrid; cells: number[]; blocked: number } {
  const g = generateWorld({ seed, width: 22, height: 16, maxSitesPerCell: 0 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");
  const gr = NavGrid.fromPlan(g.value);
  assert.equal(gr.ok, true);
  if (!gr.ok) throw new Error("unreachable");
  const grid = gr.value;
  const cells: number[] = [];
  let blocked = -1;
  for (let i = 0; i < grid.total; i++) {
    if (grid.isWalkableIndex(i)) {
      if (cells.length < n) cells.push(i);
    } else if (blocked < 0) blocked = i;
  }
  assert.ok(cells.length >= n, `世界里要有至少 ${String(n)} 个可走格`);
  assert.notEqual(blocked, -1, "世界里要至少有一格不可走（否则「崖下那丛草」那条判据没有语料）");
  return { grid, cells, blocked };
}

function mkFactions() {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
}

/** 造一只裸生物（不经过 `mob-world`，判据要能单独验感知与执行）。 */
function addMob(scene: Scene, grid: NavGrid, cell: number, name: string): number {
  const c = grid.centerOf(cell);
  const r = scene.spawnAt(name, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  scene.flush();
  return r.value.id;
}

/**
 * 把饱食度调到 `value`。
 *
 * ★ **已有组件就改，不再 attach**：`spawnMob` 已经给写了 `hunger` 的模板挂过一份，
 *   再 `attach` 会 push 第二份，而 `get()` 永远返回第一份 —— 于是"我明明设成 10% 了"
 *   而事实里读到 100%。批165 的 M1073 就是栽在这里，这次换了个位置又踩一次。
 */
function addHunger(scene: Scene, id: number, value: number, max = 100): void {
  const node = scene.find(id);
  assert.notEqual(node, undefined, "前置：节点要在场景里");
  const existing = node?.get<Hunger>(HUNGER_TYPE);
  if (existing !== undefined) {
    existing.max = max;
    existing.value = value;
    return;
  }
  const h = new Hunger();
  h.max = max;
  h.value = value;
  assert.equal(scene.attach(id, () => h).ok, true);
  scene.flush();
}

/** 在某一格上放一丛资源（`harvestInto` 只认 `game.resource` 组件，不需要任务模块）。 */
function addBerry(scene: Scene, grid: NavGrid, cell: number, count = 1): number {
  const c = grid.centerOf(cell);
  const r = scene.spawnAt(`berry@${String(cell)}`, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  const id = r.value.id;
  const m = new ResourceMarker();
  m.cell = cell;
  m.kind = "berry";
  m.count = count;
  assert.equal(scene.attach(id, () => m).ok, true);
  scene.flush();
  return id;
}

const FOOD: FoodTable = (() => {
  const r = normalizeFoodTable({ berry: { nutrition: 15 }, meat: { nutrition: 25, health: 5 } });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
})();

const componentsOfType = (scene: Scene, type: string, id: number): number =>
  scene.componentsOf(type).filter((c) => c.node?.id === id).length;

// ── ① 模板：能力由模板选择，不是所有生物都有 ─────────────────────────

test("[模板] ★ 没写 `carry` / `hunger` ⇒ 一个组件都不多（猎狗的语义不许被默认值接管）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(101, 2);
  const r = spawnMob(scene, PLAIN, grid.centerOf(cells[0]!).x, grid.centerOf(cells[0]!).z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  assert.equal(componentsOfType(scene, INVENTORY_TYPE, r.value.nodeId), 0, "没写 carry 的生物不该有背包");
  assert.equal(componentsOfType(scene, HUNGER_TYPE, r.value.nodeId), 0, "没写 hunger 的生物不该有饱食组件");
  assert.equal(r.value.inventory, null);
  assert.equal(r.value.hunger, null);
});

test("[模板] 写了两样就两样都真的挂上，容量与饱食上限照抄", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(102, 2);
  const c = grid.centerOf(cells[0]!);
  const r = spawnMob(scene, BAGGED, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const id = r.value.nodeId;
  // ★ 数**实例数**而不是 `get()`：`Node.attach` 会 push 第二份同类型组件，
  //   而 `get()` 永远返回第一个 —— 叠了两份在 `get()` 上完全看不出来（批165 踩过）
  assert.equal(componentsOfType(scene, INVENTORY_TYPE, id), 1);
  assert.equal(componentsOfType(scene, HUNGER_TYPE, id), 1);
  assert.equal(r.value.inventory?.maxStacks, 3);
  assert.equal(r.value.inventory?.maxStack, 10);
  assert.equal(r.value.hunger?.max, 100);
  assert.equal(r.value.hunger?.value, 100, "出生时饱食必须满：默认值要选安全的一侧");
});

test("[模板] ★ 已校验的模板再过一遍不变（`respawnPrey` 会把 `respawnTpl` 交回 `spawnMob`）", () => {
  // ★ **两种模板都要过**：写了 carry 的那份往返时带的是对象，没写的那份带的是 `null`。
  //   只验前者的话，"缺省"的两种写法（`undefined` / `null`）里漏掉一种也照样绿 ——
  //   而漏掉 `null` 的后果是"再生出来的每一只都报 BAD_TEMPLATE，出生那批全绿"。
  for (const tpl of [PLAIN, BAGGED]) {
    const once = validateTemplate(tpl);
    assert.equal(once.ok, true, once.ok ? "" : once.error.message);
    if (!once.ok) return;
    const twice = validateTemplate(once.value);
    assert.equal(twice.ok, true, twice.ok ? "" : `${tpl.kind} 第二次校验失败：${twice.error.message}`);
    if (!twice.ok) return;
    assert.deepEqual(twice.value, once.value, "校验不是幂等的 ⇒ 再生出来的每一只都会报 BAD_TEMPLATE，而出生那批全绿");
  }
});

test("[模板] `carry` 的坏值逐条报错（0 格 / 小数 / 数组）", () => {
  for (const [bad, why] of [
    [{ stacks: 0, stack: 10 }, "stacks=0"],
    [{ stacks: 2, stack: 1.5 }, "stack 是小数"],
    [[2, 10], "carry 是数组"],
  ] as const) {
    const r = validateTemplate({ ...BASE, kind: "x", carry: bad });
    assert.equal(r.ok, false, `${why} 应该被拒绝`);
    if (r.ok) continue;
    assert.equal(r.error.code, MOB_BAD_TEMPLATE, why);
  }
});

// ── ② 事实：饿不饿、有没有东西可捡 ───────────────────────────────

test("[事实] 没有饱食组件 ⇒ 事实里**没有** `hungry` 这个字段（不是 false）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(103, 3);
  const id = addMob(scene, grid, cells[0]!, "plain");
  // ★ 前提：**身边真的有东西可捡**。不放这一丛的话，「没有背包 ⇒ 没有 forageCell」
  //   会因为"半径内本来就没东西"而通过 —— 把判据喂成一条恒真的断言（批164/165 都踩过）
  addBerry(scene, grid, cells[1]!, 1);
  const brain = createMobBrain({ factions: mkFactions(), range: 8, food: FOOD });
  brain.decide(scene, id, 1, grid);
  const f = brain.facts(id);
  assert.notEqual(f, undefined);
  if (f === undefined) return;
  assert.equal("hungry" in f, false, "没有饱食组件却给出了 hungry ⇒ 老世界的行为不再是逐字节不变");
  assert.equal("foodKind" in f, false);
  assert.equal("forageCell" in f, false, "没有背包却去找东西捡 ⇒ 猎狗会开始捡肉");
});

test("[事实] ★ 阈值边界：49% 算饿、50% 不算（`<` 不是 `<=`）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(104, 4);
  const brain = createMobBrain({ factions: mkFactions(), range: 8, food: FOOD, hungryBelowPercent: 50 });

  const a = addMob(scene, grid, cells[0]!, "a");
  addHunger(scene, a, 49);
  const b = addMob(scene, grid, cells[1]!, "b");
  addHunger(scene, b, 50);

  brain.decide(scene, a, 1, grid);
  brain.decide(scene, b, 1, grid);
  const fa = brain.facts(a);
  const fb = brain.facts(b);
  assert.equal(fa?.hungerPct, 49);
  assert.equal(fa?.hungry, true, "49% 应该算饿");
  assert.equal(fb?.hungerPct, 50);
  assert.equal(fb?.hungry, false, "50% 不该算饿 —— 把 `<` 写成 `<=` 时这一条会红");
});

test("[事实] ★ 只捡**最近的**、而且必须走得过去（崖下那丛草不许让它走一辈子）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(105, 12);

  // ★★ 语料要自己造：「崖下那丛草」必须是**最近**的那一个，否则把可走性过滤删掉
  //   也照样绿（离得远的东西本来就不会赢）。所以先找一处「可走格紧挨着不可走格」，
  //   把怪放在可走那一格、把崖下那丛放在不可走那一格 —— 它距离 1 格，比其它都近。
  let mobCell = -1;
  let cliffCell = -1;
  for (const c of cells) {
    const cx = grid.cellX(c);
    const cz = grid.cellZ(c);
    for (const [dx, dz] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) {
      if (grid.isWalkable(cx + dx, cz + dz)) continue;
      const idx = grid.cellAt(cx + dx + 0.5, cz + dz + 0.5);
      if (idx < 0) continue;
      mobCell = c;
      cliffCell = idx;
      break;
    }
    if (mobCell >= 0) break;
  }
  assert.notEqual(mobCell, -1, "语料：世界里要有一处「可走格紧挨着不可走格」");

  // 另外两丛放在更远的地方（切比雪夫距离 >= 2，避免和崖下那丛打平）
  const cheb = (a: number, b: number): number =>
    Math.max(Math.abs(grid.cellX(a) - grid.cellX(b)), Math.abs(grid.cellZ(a) - grid.cellZ(b)));
  const farOnes = cells.filter((c) => c !== mobCell && cheb(c, mobCell) >= 2).sort((a, b) => cheb(a, mobCell) - cheb(b, mobCell) || a - b);
  const nearCell = farOnes[0];
  const farCell = farOnes[1];
  assert.notEqual(nearCell, undefined, "语料：还需要两个更远的可走格");
  assert.notEqual(farCell, undefined);
  if (nearCell === undefined || farCell === undefined) return;

  const mc = grid.centerOf(mobCell);
  const bagged = spawnMob(scene, BAGGED, mc.x, mc.z);
  assert.equal(bagged.ok, true, bagged.ok ? "" : bagged.error.code);
  if (!bagged.ok) return;
  const sid = bagged.value.nodeId;

  const near = addBerry(scene, grid, nearCell);
  const far = addBerry(scene, grid, farCell);
  const cliff = addBerry(scene, grid, cliffCell);
  const brain = createMobBrain({ factions: mkFactions(), range: 12, food: FOOD, forageRadius: 40 });
  brain.decide(scene, sid, 1, grid);
  const f = brain.facts(sid);
  assert.notEqual(f, undefined);
  if (f === undefined) return;
  assert.equal(f.forageCell, nearCell, "必须挑最近的那一格");
  assert.equal(f.forageNode, near, "节点 id 也要是最近那一个");
  assert.notEqual(f.forageNode, far, "远的那个不许赢");
  assert.notEqual(f.forageNode, cliff, "不可走的格不许当目标（否则它会朝崖下走一辈子）");
  assert.equal(grid.isWalkableIndex(f.forageCell ?? -1), true, "选中格必须可走");
});

// ── ③ 树：新分支与规范一致 ────────────────────────────────────────

const FACTS_BASE: MobFacts = {
  agentId: 7,
  tick: 10,
  selfCell: 12,
  aggressive: false,
  grudge: null,
  visible: [],
  wanderCell: 30,
};

test("[树] ★ 六组新语料：树与 `chooseFromFacts` 逐条一致（含 `eat` 带 item）", () => {
  const tree = createMobTree();
  const corpus: MobFacts[] = [
    { ...FACTS_BASE, hungry: true, foodKind: "berry" },
    { ...FACTS_BASE, hungry: true, foodKind: "berry", forageCell: 20, forageNode: 41 },
    { ...FACTS_BASE, hungry: true },
    { ...FACTS_BASE, hungry: false, foodKind: "berry" },
    { ...FACTS_BASE, forageCell: 20, forageNode: 41 },
    { ...FACTS_BASE, forageCell: -1, forageNode: -1 },
  ];
  for (const f of corpus) {
    const want = chooseFromFacts(f);
    const got = tree.decide(f);
    assert.deepEqual(got, want, `同一份事实两种答案：${JSON.stringify(f)}`);
  }
  const eat = tree.decide(corpus[0]!);
  assert.equal(eat?.kind, "eat");
  assert.equal(eat?.item, "berry", "吃哪一种是决策，不是执行细节");
  assert.equal(eat?.cell, FACTS_BASE.selfCell, "吃的目标格必须是自己站的格（否则它会一边吃一边走）");
});

test("[树] ★ 饿了但包里没吃的 ⇒ 不进入吃分支（一路落到漫游）", () => {
  const tree = createMobTree();
  const d = tree.decide({ ...FACTS_BASE, hungry: true, foodKind: undefined });
  assert.equal(d?.kind, "wander", "没有可吃的东西却给出 eat ⇒ 执行器会每拍报 NOT_HELD");
});

// ── ④ 执行：捡与吃真的改了世界 ────────────────────────────────────

test("[纯函数] `forageIntentOf`：追/漫游不归它管，eat 缺 item 时不许拼出一条 `use`", () => {
  assert.equal(forageIntentOf({ kind: "hunt", targetNodeId: 3, cell: 3, reason: "sight" }, 1, 5, 1.2), null);
  assert.equal(forageIntentOf({ kind: "wander", targetNodeId: -1, cell: 3, reason: "wander" }, 1, 5, 1.2), null);
  const p = forageIntentOf({ kind: "forage", targetNodeId: 9, cell: 9, reason: "forage" }, 1, 5, 1.2);
  assert.deepEqual(p, { kind: "pickup", actor: 1, tick: 5, origin: "ai", radius: 1.2 });
  const eat = forageIntentOf({ kind: "eat", targetNodeId: -1, cell: 9, reason: "eat", item: "meat" }, 1, 5, 1.2);
  assert.deepEqual(eat, { kind: "use", actor: 1, tick: 5, origin: "ai", item: "meat" });
  assert.equal(
    forageIntentOf({ kind: "eat", targetNodeId: -1, cell: 9, reason: "eat" }, 1, 5, 1.2),
    null,
    "没有 item 的 eat 拼出一条 use ⇒ 会被判 BAD_SHAPE，一条配置错误伪装成「它捡不到东西」",
  );
});

test("[执行] ★ 捡：东西进包、资源节点消失、`foraged` 数的是**件数**", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(106, 3);
  const c = grid.centerOf(cells[0]!);
  const r = spawnMob(scene, BAGGED, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const id = r.value.nodeId;
  const berryCell = cells[0]!;
  const berry = addBerry(scene, grid, berryCell, 3);
  const brain = createMobBrain({ factions: mkFactions(), range: 8, food: FOOD });
  const rep = runForagePass({
    scene,
    ids: [id],
    decide: (a, t) => brain.decide(scene, a, t, grid),
    tick: 1,
    food: FOOD,
  });
  // ★ `foraged` 的口径是**堆数**（与 `ActionOutcome.applied` 一致），不是件数：
  //   一丛 3 个算"捡了一次"。件数由背包读（下面那条 `countItem`）
  assert.equal(rep.foraged, 1, "一丛 berry 算一次拾取");
  assert.equal(countItem(scene, id, "berry"), 3);
  assert.equal(scene.find(berry), undefined, "捡完资源节点必须消失（否则下一拍还会「看见」它）");
  assert.equal(rep.failed + rep.retried, 0);
});

test("[执行] ★ 吃：饱食度上升、物品 -1、`ate` 只数次数", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(107, 3);
  const c = grid.centerOf(cells[0]!);
  const r = spawnMob(scene, BAGGED, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const id = r.value.nodeId;
  addHunger(scene, id, 10); // 10% ⇒ 饿
  assert.equal(addItem(scene, id, "berry", 2).ok, true);
  const brain = createMobBrain({ factions: mkFactions(), range: 8, food: FOOD });
  const rep = runForagePass({
    scene,
    ids: [id],
    decide: (a, t) => brain.decide(scene, a, t, grid),
    tick: 1,
    food: FOOD,
  });
  assert.equal(rep.ate, 1, "一次一趟只吃一个");
  assert.equal(countItem(scene, id, "berry"), 1);
  const h = scene.find(id)?.get<Hunger>(HUNGER_TYPE);
  assert.equal(h?.value, 25, "10 + 15（berry 的营养）");
});

test("[执行] ★ 包满 ≠ 出错：计 `retried`，不计 `failed`", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(108, 3);
  const c = grid.centerOf(cells[0]!);
  const r = spawnMob(scene, { ...BASE, kind: "tight", carry: { stacks: 1, stack: 40 } }, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const id = r.value.nodeId;
  assert.equal(addItem(scene, id, "wood", 5).ok, true, "先占满唯一那格");
  addBerry(scene, grid, cells[0]!, 1);
  const brain = createMobBrain({ factions: mkFactions(), range: 8, food: FOOD });
  const rep = runForagePass({
    scene,
    ids: [id],
    decide: (a, t) => brain.decide(scene, a, t, grid),
    tick: 1,
    food: FOOD,
  });
  assert.equal(rep.foraged, 0);
  assert.equal(rep.retried, 1, "背包满要单独计：它会自己好（吃掉一个就有位置）");
  assert.equal(rep.failed, 0, "背包满不是配置错误");
});

test("[执行] ★ 没有食物表却要它吃 ⇒ 计 `failed` 并留下错误码", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(109, 3);
  const c = grid.centerOf(cells[0]!);
  const r = spawnMob(scene, BAGGED, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const id = r.value.nodeId;
  addHunger(scene, id, 5);
  assert.equal(addItem(scene, id, "berry", 1).ok, true);
  // ★ 大脑给了食物表（它能"知道"berry 能吃），执行器没给 —— 这正是真实的配置漏项
  const brain = createMobBrain({ factions: mkFactions(), range: 8, food: FOOD });
  const rep = runForagePass({
    scene,
    ids: [id],
    decide: (a, t) => brain.decide(scene, a, t, grid),
    tick: 1,
  });
  assert.equal(rep.ate, 0);
  assert.equal(rep.failed, 1);
  assert.equal(rep.lastError, INTENT_NO_FOOD_TABLE);
});

// ── ⑤ 世界：新怪有背包，战利品进了它自己的包；猎狗的语义一个字没改 ─────

test("[世界] ★ 拾荒者（模板自带背包）打死猎物 ⇒ 战利品进它自己的包，`lootNoRecipient` 不增", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(2718, 4);
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT, SCAVENGER],
    spots: [
      { template: 1, cell: cells[0]! },
      { template: 0, cell: cells[1]! },
    ],
    range: 16,
    seed: 5,
    food: FOOD,
  });
  const init = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(init?.ok, true, "模块初始化必须同步成功");
  const killer = mod.nodeIds[0];
  assert.equal(typeof killer, "number");
  if (typeof killer !== "number") return;
  assert.equal(mod.templateOf(killer), "scavenger", "前置：第一个出生的是拾荒者");
  for (let t = 0; t < 200 && mod.stats.kills === 0; t++) mod.update(t, 1 / 30);
  assert.equal(mod.stats.kills, 1, `200 tick 内拾荒者必须打死兔子（实际 ${String(mod.stats.kills)}）`);
  assert.equal(mod.stats.lootGranted, 2, "兔子掉 2 块肉，全进拾荒者的包");
  assert.equal(mod.stats.lootNoRecipient, 0, "它有背包 ⇒ 「没人能收」不该增加");
  assert.equal(countItem(scene, killer, "meat"), 2);
});

test("[世界] ★ 猎狗（模板没写 carry）打死兔子 ⇒ 仍然 `lootNoRecipient`（老语义一条都不许动）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(2719, 4);
  const HOUND = { ...BASE, kind: "hound", damage: 1, speed: 2.0, team: "hunter" };
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT, HOUND],
    spots: [
      { template: 1, cell: cells[0]! },
      { template: 0, cell: cells[1]! },
    ],
    range: 16,
    seed: 5,
  });
  const init = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(init?.ok, true);
  for (let t = 0; t < 200 && mod.stats.kills === 0; t++) mod.update(t, 1 / 30);
  assert.equal(mod.stats.kills, 1);
  assert.equal(mod.stats.lootNoRecipient, 1, "猎狗没有背包：没人能收，这是设计如此");
  assert.equal(mod.stats.lootLost, 0, "「没人能收」与「包满了」必须分开计数");
});

test("[世界] 没给食物表 / 没写 carry 的世界：捡与吃的统计恒为 0（不给就不改变任何事）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(2720, 3);
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT],
    spots: cells.map((cell) => ({ template: 0, cell })),
    range: 10,
    seed: 3,
  });
  const init = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(init?.ok, true);
  for (let t = 0; t < 40; t++) mod.update(t, 1 / 30);
  assert.equal(mod.stats.foraged, 0);
  assert.equal(mod.stats.ate, 0);
  assert.equal(mod.stats.foraging, 0);
  assert.equal(mod.stats.eating, 0);
  assert.equal(mod.stats.forageFailed, 0);
});

// ── ⑥ 三处「接线」与优先级：只验模块内部的判据拦不住"根本没接上" ──────────

test("[事实] ★ 包里同时有草与熟肉 ⇒ 先吃**营养最低**的那个（AI 不许把好东西当零食）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(110, 3);
  const c = grid.centerOf(cells[0]!);
  const r = spawnMob(scene, BAGGED, c.x, c.z);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const id = r.value.nodeId;
  addHunger(scene, id, 10);
  assert.equal(addItem(scene, id, "cooked_meat", 1).ok, true);
  assert.equal(addItem(scene, id, "berry", 1).ok, true);
  const TABLE: FoodTable = (() => {
    const n = normalizeFoodTable({ berry: { nutrition: 15 }, cooked_meat: { nutrition: 40, health: 10 } });
    assert.equal(n.ok, true, n.ok ? "" : n.error.code);
    if (!n.ok) throw new Error("unreachable");
    return n.value;
  })();
  const brain = createMobBrain({ factions: mkFactions(), range: 8, food: TABLE });
  brain.decide(scene, id, 1, grid);
  const f = brain.facts(id);
  assert.equal(f?.foodKind, "berry", "熟肉是花功夫做的，AI 先啃草才不显得在糟蹋东西");
});

test("[树] ★ 追击优先于拾取：看得见敌人时不去捡草", () => {
  const tree = createMobTree();
  const f: MobFacts = {
    ...FACTS_BASE,
    aggressive: true,
    visible: [{ nodeId: 55, cell: 13, dist2: 1 }],
    forageCell: 20,
    forageNode: 41,
  };
  const want = chooseFromFacts(f);
  const got = tree.decide(f);
  assert.equal(want?.kind, "hunt");
  assert.deepEqual(got, want, "树与规范的优先级必须一致");
  assert.equal(got?.kind, "hunt", "有敌人在眼前却去捡草 —— 画面上像 bug，而不是像策略");
});

test("[世界] ★ 世界真的在跑这条链：捡到的进包、统计跟着涨（接线，不是模块内部）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(111, 3);
  const cell = cells[0]!;
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [BAGGED],
    spots: [{ template: 0, cell }],
    range: 8,
    seed: 7,
    food: FOOD,
  });
  const init = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(init?.ok, true);
  const id = mod.nodeIds[0];
  assert.equal(typeof id, "number");
  if (typeof id !== "number") return;
  // 怪脚下就有一丛，食量够它吃两顿
  addBerry(scene, grid, cell, 3);
  mod.update(0, 1 / 30);
  assert.equal(mod.stats.foraged, 1, "世界里的怪必须真的去捡（模块内部全绿但没接线，就是这种错）");
  assert.equal(countItem(scene, id, "berry"), 3);

  addHunger(scene, id, 10);
  mod.update(1, 1 / 30);
  assert.equal(mod.stats.eating, 1, "饿着的怪这一拍应该决定吃东西");
  assert.equal(mod.stats.ate, 1);
  const h = scene.find(id)?.get<Hunger>(HUNGER_TYPE);
  assert.equal(h?.value, 25, "10 + 15");
});
