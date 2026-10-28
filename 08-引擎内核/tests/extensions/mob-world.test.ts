/**
 * L4 · 生物群接线：在**真实生成的世界**里放出会走、会打、会掉的活物
 *
 * ★ 这条文件存在的理由与 `combat-world.test.ts` 一样：各自模块全绿，接缝全错 ——
 *   这一个项目已经踩过一次（JPEG 的 13 个 SOF 与导入器旧清单）。
 *   这里的"接缝"是四处：导航网格 → 大脑 → 移动/战斗 → 战利品发给谁。
 *
 * ★ 两条容易写成假绿的：
 *   ① "会动"不能只断言"位置变了"：把生物放在水里也会变（被推挤/穿墙）。
 *      必须**每 tick 都验**它站在可走格上。
 *   ② "战利品发对了人"要验**两种击杀者**：有背包的（进包）与没背包的
 *      （`lootNoRecipient`，不是 `lootLost`）。只验前者的话，把 `NO_OWNER`
 *      也计成 `lost` 的实现照样绿，而那一刻玩家看到的是"包满了"。
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
import { countItem, makeInventory, registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { createMobWorldModule } from "../../src/extensions/mobs/mob-world.ts";
import { CORPSE_TYPE, Corpse, registerCorpseComponent, corpseAt } from "../../src/extensions/combat/corpse.ts";
import {
  LOOT_BAD_ITEMS,
  LOOT_TYPE,
  LootHolding,
  lootOfNode,
  registerLootComponent,
} from "../../src/extensions/combat/loot.ts";

const RABBIT = {
  kind: "rabbit",
  frame: "rabbit",
  width: 0.8,
  height: 0.8,
  radius: 0.3,
  maxHp: 2,
  damage: 0,
  range: 1.4,
  cooldownTicks: 20,
  speed: 0.6,
  team: "prey",
  loot: [{ kind: "meat", count: 2 }],
};

const HOUND = {
  kind: "hound",
  frame: "hound",
  width: 1.0,
  height: 1.0,
  radius: 0.35,
  maxHp: 6,
  damage: 1,
  range: 1.6,
  cooldownTicks: 5,
  speed: 3.0,
  team: "hunter",
  loot: [{ kind: "hide", count: 1 }],
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
  registerCorpseComponent(reg);
  // ★ 批123：`spawnMob` 会把模板的战利品表挂成组件（`game.loot`）——
  //   不注册的话 attach 失败，而失败发生在 `init` 里，报出来像"世界没装配好"。
  registerLootComponent(reg);
  if (!reg.has("render.sprite")) reg.register(new Sprite().schema, () => new Sprite());
  return new Scene("mobs", reg);
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

function initOk(mod: { init(ctx: ModuleContext): unknown }, ctx: ModuleContext): void {
  const r = mod.init(ctx) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "模块初始化必须同步成功");
}

/** 一块真实生成的世界 + 它的导航网格 + 前 n 个可走格。 */
function realWorld(seed: number, n: number): { grid: NavGrid; cells: number[] } {
  const g = generateWorld({ seed, width: 22, height: 16, maxSitesPerCell: 0 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");
  const gr = NavGrid.fromPlan(g.value);
  assert.equal(gr.ok, true);
  if (!gr.ok) throw new Error("unreachable");
  const grid = gr.value;
  const cells: number[] = [];
  for (let i = 0; i < grid.total && cells.length < n; i++) if (grid.isWalkableIndex(i)) cells.push(i);
  assert.ok(cells.length >= n, `世界里要有至少 ${String(n)} 个可走格`);
  return { grid, cells };
}

/** 场景里的节点数（含根）。 */
function countNodes(scene: Scene): number {
  let n = 0;
  scene.root.walk(() => {
    n++;
  });
  return n;
}

function mkFactions() {
  const f = createFactions();
  f.setStance("hunter", "prey", "foe");
  return f;
}

test("[生物·世界] 放出来就有：数量对、每只都站在可走格上", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(4242, 6);
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT, HOUND],
    spots: cells.map((cell, i) => ({ template: i % 2, cell })),
    range: 12,
    seed: 9,
  });
  initOk(mod, makeCtx(scene));
  assert.equal(mod.stats.mobs, 6);
  let checked = 0;
  scene.root.walk((n) => {
    // ★ `root.walk` 会把根节点自己也走一遍，而根在 (0,0) —— 它通常正好是海。
    //   不跳过它，判据会报「1 站在不可走的格上」（节点 1 就是根）。
    if (n === scene.root) return;
    const p = n.worldPosition;
    const cell = grid.cellAt(p.x, p.y);
    assert.notEqual(cell, -1, `${String(n.id)} 跑出地图了`);
    assert.equal(grid.isWalkableIndex(cell), true, `${String(n.id)} 站在不可走的格上`);
    checked++;
  });
  assert.equal(checked, 6);
});

test("[生物·世界] ★ 会动，而且**每一 tick 都站在可走格上**", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(777, 5);
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT],
    spots: cells.map((cell) => ({ template: 0, cell })),
    range: 12,
    seed: 31,
    wanderEvery: 12,
  });
  initOk(mod, makeCtx(scene));

  const start = new Map<number, { x: number; z: number }>();
  scene.root.walk((n) => {
    if (n !== scene.root) start.set(n.id, { x: n.worldPosition.x, z: n.worldPosition.y });
  });

  let moved = 0;
  for (let t = 0; t < 400; t++) {
    mod.update(t, 1 / 30);
    scene.root.walk((n) => {
      if (n === scene.root) return;
      const p = n.worldPosition;
      const cell = grid.cellAt(p.x, p.y);
      assert.equal(grid.isWalkableIndex(cell), true, `tick ${String(t)}：${String(n.id)} 走进了不可走的格`);
      const s = start.get(n.id);
      if (s !== undefined && Math.hypot(p.x - s.x, p.y - s.z) > 0.5) moved++;
    });
  }
  assert.ok(moved > 0, "400 tick 里一只都没挪动 —— 大脑/移动没接上");
  assert.equal(mod.stats.kills, 0, "只有兔子，不该有击杀");
});

test("[生物·世界] ★ 猎狗追上兔子并打死（真世界、真寻路）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(2718, 8);
  // 猎狗与兔子相邻：第一下就能打到，剩下的交给追击
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
  initOk(mod, makeCtx(scene));
  for (let t = 0; t < 200 && mod.stats.kills === 0; t++) mod.update(t, 1 / 30);
  assert.equal(mod.stats.kills, 1, `200 tick 内猎狗必须打死兔子（实际杀掉 ${String(mod.stats.kills)}）`);
  assert.equal(mod.stats.mobs, 1, "被吃掉的兔子必须从名单里消失");
});

test("[生物·世界] 击杀者有背包 ⇒ 战利品进包（肉终于有来源）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(31415, 4);
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
  initOk(mod, makeCtx(scene));
  // 猎狗就是"击杀者"：给它一个背包（spots[0] 是猎狗 ⇒ nodeIds 升序的第一个）
  const houndId = mod.nodeIds[0];
  assert.equal(typeof houndId, "number", "前置条件：先找到那只猎狗");
  if (typeof houndId !== "number") return;
  assert.equal(mod.templateOf(houndId), "hound", "前置条件：第一个出生的必须是猎狗");
  assert.equal(makeInventory(scene, houndId).ok, true);

  for (let t = 0; t < 200 && mod.stats.kills === 0; t++) mod.update(t, 1 / 30);
  assert.equal(mod.stats.kills, 1);
  assert.equal(mod.stats.lootGranted, 2, "兔子掉 2 块肉");
  assert.equal(mod.stats.lootLost, 0);
  assert.equal(mod.stats.lootNoRecipient, 0);
  assert.equal(countItem(scene, houndId, "meat"), 2);
});

test("[生物·世界] 击杀者没有背包 ⇒ 计 `lootNoRecipient`，**不是** `lootLost`", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(31415, 4);
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
  initOk(mod, makeCtx(scene));
  for (let t = 0; t < 200 && mod.stats.kills === 0; t++) mod.update(t, 1 / 30);
  assert.equal(mod.stats.kills, 1);
  assert.equal(mod.stats.lootNoRecipient, 1, "猎狗没有背包：没人能收，这是设计如此");
  assert.equal(mod.stats.lootLost, 0, "「没人能收」与「包满了」必须分开计数");
  assert.equal(mod.stats.lastLootError, "LOOT.NO_OWNER");
});

test("[生物·世界] 出生点引用了不存在的模板：报错且不静默少放几只", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(99, 2);
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT],
    spots: [{ template: 0, cell: cells[0]! }, { template: 5, cell: cells[1]! }],
    range: 12,
  });
  const r = mod.init(makeCtx(scene)) as { ok: boolean; error?: { code: string } } | undefined;
  assert.equal(r?.ok, false);
  assert.equal(r?.error?.code, "MOB_WORLD.BAD_MODULE");
});

test("[生物·世界] 模板不合法 ⇒ 整体失败（世界里不留半个生物）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(99, 2);
  const before = countNodes(scene);
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [{ ...RABBIT, maxHp: 0 }],
    spots: [{ template: 0, cell: cells[0]! }],
    range: 12,
  });
  const r = mod.init(makeCtx(scene)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, false);
  const after = countNodes(scene);
  assert.equal(after, before, "模板错时不该留下半个生物");
});

/**
 * ★★ 玩家手动攻击也要被记住（`noteHit`）。
 *
 * 玩家的攻击走 `attack()`，**不经过** `combat-module`。所以"记仇"如果只接在
 * combat-module 的 `onHit` 上，那么"我打它一下"在它记忆里等于没发生 ——
 * 而所有"生物打生物"的判据都是绿的。这条判据专门钉住那个**外侧**入口。
 */
test("[生物·世界] ★★ 玩家的手动命中也会被记恨：打了就跑跑不掉", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(777, 2);
  // 只有一只猎狗（它会记仇），玩家 = 一个带攻击组件的节点
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT, HOUND],
    spots: [{ template: 1, cell: cells[0]! }],
    range: 12,
    seed: 3,
    threatDecayTicks: 100,
    aggroCells: 0,
  });
  initOk(mod, makeCtx(scene));
  const before = mod.stats.threatEntries;
  assert.equal(before, 0, "初始没人记仇");

  const mobId = mod.nodeIds[0]!;
  const player = scene.spawnAt("hero", 50.5, 50.5);
  assert.equal(player.ok, true);
  if (!player.ok) return;
  scene.flush();
  const playerId = player.value.id;

  assert.equal(mod.noteHit({ attackerId: playerId, targetId: mobId, applied: 3, tick: 1 }), true, "记仇入口要能写进去");
  assert.equal(mod.stats.threatEntries, 1);
  assert.equal(mod.stats.threatTargets, 1);

  // 记仇之后它会朝玩家走（玩家在 50.5,50.5，远超感知半径 12）
  // ★★ 断言必须是"到玩家的距离**变小**"，不能是"它动过"或"它的坐标 > 0"：
  //   后两者在出生那一刻就成立（这里第一版就写成了 `x>0 && y>0`，假绿）。
  const dist2 = (a: number, b: number): number => {
    const na = scene.find(a);
    const nb = scene.find(b);
    if (na === undefined || nb === undefined) return Number.POSITIVE_INFINITY;
    const dx = na.worldPosition.x - nb.worldPosition.x;
    const dz = na.worldPosition.y - nb.worldPosition.y;
    return dx * dx + dz * dz;
  };
  const start = dist2(mobId, playerId);
  for (let t = 2; t < 40; t++) mod.update(t, 0.016);
  const now = dist2(mobId, playerId);
  assert.ok(
    now < start - 0.25,
    `记仇之后它必须朝玩家靠近：距离平方 ${start.toFixed(2)} → ${now.toFixed(2)}`,
  );
});

test("[生物·世界] 记仇可以整体关掉（threatDecayTicks: 0）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(778, 2);
  const mod = createMobWorldModule({
    grid,
    factions: mkFactions(),
    templates: [RABBIT, HOUND],
    spots: [{ template: 1, cell: cells[0]! }],
    range: 12,
    seed: 3,
    threatDecayTicks: 0,
  });
  initOk(mod, makeCtx(scene));
  const player = scene.spawnAt("hero", 50.5, 50.5);
  assert.equal(player.ok, true);
  if (!player.ok) return;
  scene.flush();
  const r = mod.noteHit({ attackerId: player.value.id, targetId: mod.nodeIds[0]!, applied: 3, tick: 1 });
  assert.equal(r, false, "关掉记仇时 noteHit 要老实返回 false（不能假装记下了）");
  assert.equal(mod.stats.threatEntries, 0);
});

// ── 批123：死亡留尸体 ────────────────────────────────────────

/**
 * 打到出第一次击杀为止，返回那一 tick（尸体时刻要用它算）。
 * ★ 不写死"第几 tick 会打死"：那是配表的副产品，写死之后调一次数值就要改判据。
 */
function killOnce(mod: { update(t: number, d: number): void; stats: { kills: number } }): number {
  for (let t = 0; t < 400; t++) {
    mod.update(t, 1 / 30);
    if (mod.stats.kills > 0) return t;
  }
  return -1;
}

test("[生物·尸体] 开着尸体模式 ⇒ 原地留一具（肉在里面），击杀者背包**没多**", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(31415, 4);
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
    corpse: { ground: grid, decayTicks: 600 },
  });
  initOk(mod, makeCtx(scene));
  const houndId = mod.nodeIds[0]!;
  assert.equal(mod.templateOf(houndId), "hound", "前置条件：第一个出生的必须是猎狗");
  // 猎狗有背包 —— 有背包才谈得上"这一次**没有**进包"
  assert.equal(makeInventory(scene, houndId).ok, true);

  const killTick = killOnce(mod);
  assert.ok(killTick >= 0, "400 tick 内没有发生击杀 —— 判据前提不成立");
  assert.equal(mod.stats.corpsesSpawned, 1, "击杀之后地上没有尸体");
  // ★ 两套账一起读：只验"有尸体"的话，"尸体 + 同时进包"（双份掉落）照样绿
  assert.equal(mod.stats.lootGranted, 0, "开了尸体模式却还把战利品发给了击杀者 —— 双份掉落");
  assert.equal(scene.countOf(CORPSE_TYPE), 1);

  // 尸体里就是那张 loot 表（兔子掉 2 块肉），且腐烂时刻 = 死亡 tick + 600
  let found: Corpse | null = null;
  for (const c of scene.componentsOf<Corpse>(CORPSE_TYPE)) found = c;
  assert.ok(found !== null, "场景里找不到尸体组件");
  const body = found as unknown as Corpse;
  assert.deepEqual(body.items, ["meat:2"], `尸体里是 ${JSON.stringify(body.items)}`);
  assert.equal(body.decayAtTick, killTick + 600, "腐烂时刻不是「死亡那一 tick + 时长」");
  assert.ok(corpseAt(scene, body.cell) !== null, "按格子找不到那具尸体");
});

test("[生物·尸体] 尸体放不下 ⇒ 退回进背包（掉不许凭空消失）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(31415, 4);
  // ★ 一个 3×3 且**全不可走**的假地面：无论死在哪，外扩两圈也落不进去。
  //   不用"可走但越界"来造——那取决于生物死在地图的哪个角，判据会随种子漂。
  const tiny = new NavGrid(3, 3, new Uint8Array(9));
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
    corpse: { ground: tiny },
  });
  initOk(mod, makeCtx(scene));
  const houndId = mod.nodeIds[0]!;
  assert.equal(makeInventory(scene, houndId).ok, true);

  const killTick = killOnce(mod);
  assert.ok(killTick >= 0);
  assert.equal(mod.stats.corpsesSpawned, 0, "地面不对却还是生成了尸体");
  assert.equal(mod.stats.corpsesFailed, 1, "放不下要**记一笔**，不是静默");
  assert.equal(mod.stats.lastCorpseError, "CORPSE.NO_SPACE");
  assert.equal(scene.countOf(CORPSE_TYPE), 0);
  // ★ 关键：退回老路 —— 2 块肉进了击杀者背包。只验 corpsesFailed 的话，
  //   "放不下就把东西扔掉"这条最坏的实现照样绿。
  assert.equal(mod.stats.lootGranted, 2, "放不下的时候战利品必须退回背包，不许消失");
  assert.equal(countItem(scene, houndId, "meat"), 2);
});

test("[生物·尸体] 不开尸体模式 ⇒ 老行为（进包、没有尸体）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(31415, 4);
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
  initOk(mod, makeCtx(scene));
  assert.equal(makeInventory(scene, mod.nodeIds[0]!).ok, true);
  assert.ok(killOnce(mod) >= 0);
  // ★ 这一条钉的是"默认不变"：加选项时把默认行为顺手改掉，是本项目最容易犯的错
  assert.equal(mod.stats.lootGranted, 2);
  assert.equal(mod.stats.corpsesSpawned, 0);
  assert.equal(scene.countOf(CORPSE_TYPE), 0);
});

test("[生物·尸体] 战利品表挂在**实体身上**（不是模块旁表：读档换了场景也查得到）", () => {
  const scene = mkScene();
  const { grid, cells } = realWorld(31415, 3);
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
  initOk(mod, makeCtx(scene));
  const hound = mod.nodeIds[0]!;
  const rabbit = mod.nodeIds[1]!;
  // ★ 读**场景里的组件**：`lootOfNode` 不经过生物模块，所以"模块没起来"
  //   与"这只生物没有战利品"不会混成一个现象。
  const meet = lootOfNode(scene, rabbit);
  assert.ok(meet.ok, meet.ok ? "" : meet.error.code);
  assert.deepEqual(meet.ok ? meet.value : null, [{ kind: "meat", count: 2 }], "兔子的战利品表不对");
  const hide = lootOfNode(scene, hound);
  assert.ok(hide.ok, hide.ok ? "" : hide.error.code);
  assert.deepEqual(hide.ok ? hide.value : null, [{ kind: "hide", count: 1 }]);
  // ★ 没有组件 ⇒ null（不是空数组）：空数组会让调用方"生成了空尸体"再报一次错，
  //   而 null 能一句话区分"这东西没有战利品"与"读不出来"（后者是 `!ok`）。
  assert.equal(lootOfNode(scene, 999999).ok, true);
  const none = lootOfNode(scene, 999999);
  assert.equal(none.ok ? none.value : "ERR", null);
});

test("[生物·尸体] 表读不出来 ⇒ 不发东西、记 lastLootError（不静默当成「没有掉落」）", () => {
  // ★ 这一条盯的是"静默丢"：把 `!lootR.ok` 当成 `null` 的实现，
  //   在正常语料上完全绿 —— 只有存档被改坏（或版本升级改了编码）时才暴露，
  //   而那正是玩家丢东西却没有任何日志的时刻。
  const scene = mkScene();
  const { grid, cells } = realWorld(31415, 2);
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
  initOk(mod, makeCtx(scene));
  const rabbit = mod.nodeIds[1]!;
  const c = scene.find(rabbit)?.get<LootHolding>(LOOT_TYPE);
  assert.ok(c instanceof LootHolding, "兔子身上没有 game.loot");
  if (!(c instanceof LootHolding)) return;
  c.items = ["meat"]; // 少了「:数量」——decodeItems 拒绝
  assert.equal(makeInventory(scene, mod.nodeIds[0]!).ok, true);
  assert.ok(killOnce(mod) >= 0);
  assert.equal(mod.stats.lootGranted, 0, "表读不出来却还是发了东西？");
  assert.equal(mod.stats.lastLootError, LOOT_BAD_ITEMS, `lastLootError 是「${mod.stats.lastLootError}」`);
});
