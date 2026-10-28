/**
 * L4 · 尸体（批123：死了以后地上留一具）
 *
 * ★ 这一组盯住的是**五类静默失效**（每一类的共同点都是"计数自洽、画面上看不出"）：
 *
 *   ① **尸体进了资源账** ⇒ 杀一只怪吃掉一个资源名额，几千只之后森林再也不长。
 *      那一刻没有任何报错（`alive` 就是满的），所以判据必须**同时读两套账**
 *      （资源模块的 spawned/alive/occupied 一个都不许动）。
 *
 *   ② **腐烂用"剩余 tick"而不是绝对时刻** ⇒ 读档把腐烂时刻往后推一个存档周期，
 *      于是"存一下再读"变成保鲜手段。判据必须是端到端的：真存档 → 读档 →
 *      时刻不变 ∧ 继续走到点仍然消失。
 *
 *   ③ **配表顺序进了存档** ⇒ 同一张表写成 `[肉, 皮]` 与 `[皮, 肉]` 产出两份不同的
 *      存档，跨宿主的逐字节比对随机红。判据造两种写法，比 `items` 逐项相同。
 *
 *   ④ **先扣尸体、后进包** ⇒ 背包满时"尸体空了、背包没多"，而地上只是少了一具尸体。
 *      多条目时更隐蔽：第一种进得去、第二种满，于是"拿了一半"看起来像成功。
 *      判据同时验"背包回到原样"和"尸体一点没少"。
 *
 *   ⑤ **到点那一 tick 差一** ⇒ `tick > decayAtTick` 与 `>=` 的区别只在**一 tick**，
 *      只在"正好走到那一 tick"的判据里可见；跑一万 tick 的粗判据看不出来。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { Logger } from "../../src/foundation/log/logger.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import { generateWorld, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { WORLD_TASK_SCHEMA } from "../../src/extensions/worldgen/tasks.ts";
import {
  RESOURCE_TYPE,
  createWorldTaskModule,
  registerResourceComponent,
  type WorldTaskModuleHandle,
} from "../../src/extensions/worldgen/task-module.ts";
import { registerPlayerComponents, spawnPlayer } from "../../src/extensions/worldgen/spawn.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { addItem, countItem, makeInventory, registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { loadScene, saveScene } from "../../src/core/scene/scene-io.ts";
import { LOOT_BAD_ITEMS } from "../../src/extensions/combat/loot.ts";
import {
  CORPSE_BAD_DECAY,
  CORPSE_EMPTY,
  CORPSE_NONE,
  CORPSE_NO_SPACE,
  CORPSE_TYPE,
  corpseAt,
  createCorpseModule,
  decodeItems,
  encodeItems,
  registerCorpseComponent,
  spawnCorpse,
  takeFromCorpse,
} from "../../src/extensions/combat/corpse.ts";
import { normalizeLoot } from "../../src/extensions/combat/loot.ts";

function makeRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerPlayerComponents(reg);
  registerInventoryComponents(reg);
  registerCorpseComponent(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}

function makeCtx(): ModuleContext {
  return {
    log: new Logger(() => 0),
    events: new EventBus<Record<string, unknown>>(),
    services: new ServiceRegistry(),
    platform: {} as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
}

interface MadeWorld {
  readonly scene: Scene;
  readonly plan: WorldPlan;
  readonly nav: NavGrid;
  readonly tasks: WorldTaskModuleHandle;
  readonly heroId: number;
  readonly registry: ComponentRegistry;
}

function makeWorld(opts: { maxResources?: number } = {}): MadeWorld {
  const registry = makeRegistry();
  const scene = new Scene("corpse", registry);
  const g = generateWorld({ seed: 11, width: 32, height: 24, maxSitesPerCell: 0 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  assert.ok(assembleWorld(g.value, scene).ok);

  const tasks = createWorldTaskModule({
    tasks: { schema: WORLD_TASK_SCHEMA, tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun: 4, biomes: ["grass", "forest"] }] },
    plan: g.value,
    scene,
    ...(opts.maxResources === undefined ? {} : { maxResources: opts.maxResources }),
  });
  const init = tasks.init(makeCtx());
  assert.ok(init === undefined || (init as { ok?: boolean }).ok === true, "任务模块 init 失败");
  tasks.start?.();

  const nav = NavGrid.fromPlan(g.value);
  assert.ok(nav.ok, nav.ok ? "" : `导航网格建不起来：${nav.error.code}`);

  const spawn = spawnPlayer(scene, g.value);
  assert.ok(spawn.ok, spawn.ok ? "" : `出生失败：${spawn.error.message}`);
  assert.ok(makeInventory(scene, spawn.value.nodeId, 8, 40).ok);
  return { scene, plan: g.value, nav: nav.value, tasks, heroId: spawn.value.nodeId, registry };
}

/** 第 `skip` 个可走格子（跳过前面的，用来造"两具尸体挨着"）。 */
function walkableCell(w: MadeWorld, skip = 0): number {
  let seen = 0;
  for (let c = 0; c < w.plan.kinds.length; c++) {
    if (!w.nav.isWalkableIndex(c)) continue;
    if (seen++ < skip) continue;
    return c;
  }
  throw new Error(`可走格不足（要跳过 ${String(skip)} 个）—— 判据前提不成立`);
}

function posOf(w: MadeWorld, cell: number): { x: number; z: number } {
  const c = w.nav.centerOf(cell);
  return { x: c.x, z: c.z };
}

// ── ① 生成与落点 ─────────────────────────────────────────────

test("★★ 生成一具尸体：节点进场景、字段写对、位置是格中心", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 2 }, { kind: "hide", count: 1 }], {
    ground: w.nav,
    x: p.x,
    z: p.z,
    nowTick: 100,
    decayTicks: 600,
  });
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  assert.equal(r.value.cell, cell, "落点不是死亡格");
  assert.deepEqual(r.value.items, [{ kind: "hide", count: 1 }, { kind: "meat", count: 2 }], "物品清单没按 kind 升序");
  assert.equal(r.value.decayAtTick, 700, "腐烂时刻不是 now + decayTicks");

  const c = corpseAt(w.scene, cell);
  assert.ok(c !== null, "场景里找不到那具尸体");
  assert.equal(c!.node!.id, r.value.nodeId);
  assert.deepEqual(c!.items, ["hide:1", "meat:2"], `items 字段是 ${JSON.stringify(c!.items)}`);
  // ★ 位置也要验：`cell` 字段对、坐标错的话尸体画在别处，而所有计数都对
  const n = w.scene.find(r.value.nodeId);
  assert.ok(n !== undefined);
  assert.equal(n!.localPosition.x, p.x);
  assert.equal(n!.localPosition.y, p.z);
});

test("★★ 尸体**不进**资源账：spawned / alive / occupied 一个都不动", () => {
  const w = makeWorld();
  const before = w.tasks.stats();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  assert.ok(
    spawnCorpse(w.scene, [{ kind: "meat", count: 1 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 }).ok,
  );
  const after = w.tasks.stats();
  // ★ 两套账一起读：只验"尸体生成了"的话，走 placeResource 也绿
  assert.equal(after.spawned, before.spawned, "生成尸体动了 spawned —— 资源账被污染了");
  assert.equal(after.alive, before.alive, "生成尸体动了 alive —— 杀怪会吃光资源名额，森林再也不长");
  assert.equal(w.tasks.isOccupied(cell), false, "尸体占了资源的去重索引 —— 那一格再也不会长东西");
  assert.equal(w.scene.countOf(RESOURCE_TYPE), 0, "尸体被当成资源挂了 ResourceMarker");
});

test("★★ 死亡格上已经有一具 ⇒ 落到旁边的空格（同距离取小 cell）", () => {
  const w = makeWorld();
  const a = walkableCell(w);
  const pa = posOf(w, a);
  const first = spawnCorpse(w.scene, [{ kind: "meat", count: 1 }], { ground: w.nav, x: pa.x, z: pa.z, nowTick: 0 });
  assert.ok(first.ok, first.ok ? "" : first.error.code);

  const second = spawnCorpse(w.scene, [{ kind: "hide", count: 1 }], { ground: w.nav, x: pa.x, z: pa.z, nowTick: 0 });
  assert.ok(second.ok, second.ok ? "" : second.error.code);
  assert.notEqual(second.value.cell, a, "两具尸体落在同一格 —— 拾取时没法分辨拿的是哪一具");

  // ★★ 同距离必须取**小 cell** —— 期望值由独立实现（暴力枚举 + 排序）算，不调被测函数。
  //   只比"两次生成是否相同"的话，把环扫方向倒过来仍然绿，而版本间的回放已经对不上了。
  const cx = Math.floor(pa.x);
  const cz = Math.floor(pa.z);
  const candidates: Array<{ cell: number; d: number }> = [];
  for (let gz = 0; gz < w.plan.height; gz++) {
    for (let gx = 0; gx < w.plan.width; gx++) {
      const d = Math.max(Math.abs(gx - cx), Math.abs(gz - cz));
      if (d > 2) continue;
      const cand = gz * w.plan.width + gx;
      if (!w.nav.isWalkableIndex(cand)) continue;
      if (cand === a) continue;
      candidates.push({ cell: cand, d });
    }
  }
  candidates.sort((x, y) => (x.d !== y.d ? x.d - y.d : x.cell - y.cell));
  assert.ok(candidates.length > 0, "锚点周围没有第二个候选格 —— 判据前提不成立");
  assert.equal(second.value.cell, candidates[0]!.cell, "环内顺序不是「同距离取小 cell」");
});

test("★ 死亡位置不可走 ⇒ 外扩到可走格（尸体不会落在海里）", () => {
  const w = makeWorld();
  // 找一个不可走格，且它旁边有可走格
  let water = -1;
  for (let c = 0; c < w.plan.kinds.length; c++) {
    if (w.nav.isWalkableIndex(c)) continue;
    const cx = c % w.plan.width;
    const cz = (c - cx) / w.plan.width;
    let near = false;
    for (let dz = -1; dz <= 1 && !near; dz++) {
      for (let dx = -1; dx <= 1 && !near; dx++) {
        const gx = cx + dx;
        const gz = cz + dz;
        if (gx < 0 || gx >= w.plan.width || gz < 0 || gz >= w.plan.height) continue;
        if (w.nav.isWalkableIndex(gz * w.plan.width + gx)) near = true;
      }
    }
    if (near) {
      water = c;
      break;
    }
  }
  assert.ok(water >= 0, "找不到「不可走但旁边能走」的格子 —— 判据前提不成立");
  const pw = w.nav.centerOf(water);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 1 }], { ground: w.nav, x: pw.x, z: pw.z, nowTick: 0 });
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  assert.notEqual(r.value.cell, water);
  assert.ok(w.nav.isWalkableIndex(r.value.cell), "尸体落在了不可走的格子上");
});

test("★ 周围没有空地 ⇒ CORPSE.NO_SPACE，场景里不多节点", () => {
  const registry = makeRegistry();
  const scene = new Scene("tiny", registry);
  // 3×3，只有正中可走：放下一具之后第二具必然无处可去
  const mask = new Uint8Array(9);
  mask[4] = 1;
  const grid = new NavGrid(3, 3, mask);
  const p = grid.centerOf(4);
  const first = spawnCorpse(scene, [{ kind: "meat", count: 1 }], { ground: grid, x: p.x, z: p.z, nowTick: 0, searchCells: 1 });
  assert.ok(first.ok, first.ok ? "" : first.error.code);
  const before = scene.stats().nodes;
  const second = spawnCorpse(scene, [{ kind: "hide", count: 1 }], { ground: grid, x: p.x, z: p.z, nowTick: 0, searchCells: 1 });
  assert.equal(second.ok, false);
  assert.equal(second.ok ? "" : second.error.code, CORPSE_NO_SPACE);
  assert.equal(scene.stats().nodes, before, "报错时场景里多了节点（半具尸体）");
});

test("★ 空表 / 烂时长不合法：都在世界动过之前失败", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const before = w.scene.stats().nodes;

  const empty = spawnCorpse(w.scene, [], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 });
  assert.equal(empty.ok, false);
  assert.equal(empty.ok ? "" : empty.error.code, CORPSE_EMPTY, "空表必须报 CORPSE_EMPTY（空尸体只会让玩家白跑）");

  for (const bad of [-1, 1.5, NaN]) {
    const r = spawnCorpse(w.scene, [{ kind: "meat", count: 1 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0, decayTicks: bad });
    assert.equal(r.ok, false, `腐烂时长 ${String(bad)} 应该被拒绝`);
    assert.equal(r.ok ? "" : r.error.code, CORPSE_BAD_DECAY);
  }
  assert.equal(w.scene.stats().nodes, before, "失败路径留下了节点");
});

// ── ② 复用 loot 表（同一套校验与排序） ───────────────────────

test("★★ 同一张表的两种写法 ⇒ items 逐项相同（顺序不进存档）", () => {
  const w = makeWorld();
  const a = walkableCell(w, 0);
  const b = walkableCell(w, 1);
  const pa = posOf(w, a);
  const pb = posOf(w, b);
  const r1 = spawnCorpse(w.scene, [{ kind: "meat", count: 2 }, { kind: "hide", count: 1 }], { ground: w.nav, x: pa.x, z: pa.z, nowTick: 0 });
  const r2 = spawnCorpse(w.scene, [{ kind: "hide", count: 1 }, { kind: "meat", count: 2 }], { ground: w.nav, x: pb.x, z: pb.z, nowTick: 0 });
  assert.ok(r1.ok && r2.ok, "两次生成都应该成功");
  assert.deepEqual(corpseAt(w.scene, a)!.items, corpseAt(w.scene, b)!.items, "配表书写顺序进了存档 —— 跨宿主逐字节比对会随机红");
});

test("★★ 重复 kind 合并（与 grantLoot 同一口径），不是覆盖", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 1 }, { kind: "meat", count: 2 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 });
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  assert.deepEqual(r.value.items, [{ kind: "meat", count: 3 }], "重复 kind 没有相加 —— 与 normalizeLoot 的口径不一致");
});

test("★ kind 里带冒号也能正确往返（解码用 lastIndexOf）", () => {
  const enc = encodeItems([{ kind: "a:b", count: 4 }]);
  assert.deepEqual(enc, ["a:b:4"]);
  const dec = decodeItems(enc);
  assert.ok(dec.ok, dec.ok ? "" : dec.error.code);
  assert.deepEqual(dec.value, [{ kind: "a:b", count: 4 }]);
});

test("★ 坏存档读不出来要报错，不静默丢", () => {
  for (const bad of ["meat", "meat:", ":2", "meat:0", "meat:2.0", "meat:-1", "meat:x"]) {
    const r = decodeItems([bad]);
    assert.equal(r.ok, false, `「${bad}」应该被拒绝`);
    assert.equal(r.ok ? "" : r.error.code, LOOT_BAD_ITEMS);
  }
});

test("★ count = 0 由 normalizeLoot 拒绝（复用不是另写一套校验）", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const norm = normalizeLoot([{ kind: "meat", count: 0 }]);
  assert.equal(norm.ok, false);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 0 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, norm.ok ? "" : norm.error.code, "尸体这条路没有走 loot 的那套校验");
});

// ── ③ 腐烂 ──────────────────────────────────────────────────

test("★★ 第 decayAtTick-1 tick 还在、第 decayAtTick tick 消失（差一就红）", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 1 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 50, decayTicks: 10 });
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  const mod = createCorpseModule({ scene: w.scene });
  assert.ok(mod.init(makeCtx()).ok, "模块 init 失败");
  mod.start();

  mod.update(59, 1 / 30);
  assert.equal(w.scene.countOf(CORPSE_TYPE), 1, "还没到点就烂了");
  assert.equal(mod.stats.decayed, 0);

  mod.update(60, 1 / 30);
  assert.equal(w.scene.countOf(CORPSE_TYPE), 0, "到点那一 tick 还没烂（差一）");
  assert.equal(mod.stats.decayed, 1, "烂了但计数没涨");
  assert.equal(w.scene.find(r.value.nodeId), undefined, "节点还留在场景里（只删了组件）");
});

test("★★ decayTicks = 0 ⇒ 跑一万 tick 也不消失（「永不腐烂」的哨兵）", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 1 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 });
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  assert.equal(r.value.decayAtTick, 0, "没传 decayTicks 时应该是 0（永不）而不是某个默认时长");
  const mod = createCorpseModule({ scene: w.scene });
  assert.ok(mod.init(makeCtx()).ok, "模块 init 失败");
  mod.start();
  for (let t = 1; t <= 10000; t += 500) mod.update(t, 1 / 30);
  assert.equal(w.scene.countOf(CORPSE_TYPE), 1, "decayTicks = 0 的尸体消失了 —— 战利品被时钟吃掉");
  assert.equal(mod.stats.decayed, 0);
});

test("★★ 存档往返：腐烂时刻不变，继续走到点仍然消失（读档不保鲜）", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 2 }, { kind: "hide", count: 1 }], {
    ground: w.nav,
    x: p.x,
    z: p.z,
    nowTick: 1000,
    decayTicks: 600,
  });
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  const snap = saveScene(w.scene);

  const registry = makeRegistry();
  const scene2 = new Scene("corpse-2", registry);
  const rep = loadScene(scene2, snap, registry);
  assert.ok(rep.ok, rep.ok ? "" : `读档失败：${rep.error.code}`);
  assert.deepEqual(rep.value.missingFields, [], "新档不该缺字段");

  const loaded = corpseAt(scene2, cell);
  assert.ok(loaded !== null, "读档把尸体读丢了");
  assert.equal(loaded!.decayAtTick, 1600, "腐烂时刻变了 —— 存的是「还剩多少」而不是「哪一刻」");
  assert.deepEqual(loaded!.items, ["hide:1", "meat:2"], `读回来的物品清单是 ${JSON.stringify(loaded!.items)}`);

  // ★ 端到端：读档后接着走，仍然在第 1600 tick 消失
  const mod = createCorpseModule({ scene: scene2 });
  assert.ok(mod.init(makeCtx()).ok, "模块 init 失败");
  mod.start();
  mod.update(1599, 1 / 30);
  assert.equal(scene2.countOf(CORPSE_TYPE), 1, "读档之后提前烂了");
  mod.update(1600, 1 / 30);
  assert.equal(scene2.countOf(CORPSE_TYPE), 0, "读档之后烂不掉 —— 腐烂计时丢了");
});

test("★ 一 tick 烂掉多具：全部消失、计数一次涨够", () => {
  const w = makeWorld();
  const cells = [walkableCell(w, 0), walkableCell(w, 50), walkableCell(w, 100)];
  for (const c of cells) {
    const p = posOf(w, c);
    assert.ok(spawnCorpse(w.scene, [{ kind: "meat", count: 1 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0, decayTicks: 5 }).ok);
  }
  const mod = createCorpseModule({ scene: w.scene });
  assert.ok(mod.init(makeCtx()).ok, "模块 init 失败");
  mod.start();
  mod.update(4, 1 / 30);
  assert.equal(mod.stats.corpses, 3);
  mod.update(5, 1 / 30);
  assert.equal(mod.stats.corpses, 0, "到点一 tick 应该全烂掉");
  assert.equal(mod.stats.decayed, 3);
});

// ── ④ 取东西 ────────────────────────────────────────────────

test("★★ 全取：背包多了、尸体节点没了、两账一致", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 2 }, { kind: "hide", count: 1 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 });
  assert.ok(r.ok, r.ok ? "" : r.error.code);

  const t = takeFromCorpse(w.scene, cell, w.heroId);
  assert.ok(t.ok, t.ok ? "" : t.error.code);
  assert.equal(t.value.takenCount, 3);
  assert.equal(t.value.leftCount, 0);
  assert.equal(t.value.emptied, true);
  // ★ 三块状态一起读：背包真的多了 ∧ 尸体节点没了 ∧ 那一格取不到了
  assert.equal(countItem(w.scene, w.heroId, "meat"), 2);
  assert.equal(countItem(w.scene, w.heroId, "hide"), 1);
  assert.equal(w.scene.find(r.value.nodeId), undefined, "拿空了节点还在（幽灵尸体）");
  assert.equal(corpseAt(w.scene, cell), null);
});

test("★★ 只取一种：另一种留着、节点还在", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  const r = spawnCorpse(w.scene, [{ kind: "meat", count: 2 }, { kind: "hide", count: 1 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 });
  assert.ok(r.ok, r.ok ? "" : r.error.code);

  const t = takeFromCorpse(w.scene, cell, w.heroId, { kind: "meat" });
  assert.ok(t.ok, t.ok ? "" : t.error.code);
  assert.equal(t.value.emptied, false);
  assert.deepEqual(t.value.left, [{ kind: "hide", count: 1 }]);
  assert.equal(countItem(w.scene, w.heroId, "meat"), 2);
  assert.equal(countItem(w.scene, w.heroId, "hide"), 0, "没点名的种类也进包了");
  assert.deepEqual(corpseAt(w.scene, cell)!.items, ["hide:1"]);

  const again = takeFromCorpse(w.scene, cell, w.heroId, { kind: "meat" });
  assert.equal(again.ok, false);
  assert.equal(again.ok ? "" : again.error.code, CORPSE_NONE, "尸体里已经没有 meat 了，必须报错而不是静默给 0");
});

test("★ 一次最多拿几个：剩下的留在尸体里", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  assert.ok(spawnCorpse(w.scene, [{ kind: "meat", count: 5 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 }).ok);
  const t = takeFromCorpse(w.scene, cell, w.heroId, { amount: 2 });
  assert.ok(t.ok, t.ok ? "" : t.error.code);
  assert.equal(t.value.takenCount, 2);
  assert.deepEqual(corpseAt(w.scene, cell)!.items, ["meat:3"]);
});

test("★★ 背包满 ⇒ 一样都不进、尸体一点没少（先看→先进包→最后扣的证据）", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  assert.ok(spawnCorpse(w.scene, [{ kind: "meat", count: 2 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 }).ok);
  // 一个格子、每堆 1 个：塞满之后就再也放不下
  // ★ 用一个**普通节点**当背包（不 spawnPlayer）：世界里的玩家已经有一份背包了，
  //   再造一个"玩家"会让判据依赖 `spawnPlayer` 的约束，而这一条要验的是背包满。
  const bagNode = w.scene.spawn("bag", null);
  assert.ok(bagNode.ok);
  // ★ `spawn` 是排队的（结构性修改），不 flush 就 `find` 不到它
  w.scene.flush();
  const bagId = bagNode.value.id;
  assert.ok(makeInventory(w.scene, bagId, 1, 1).ok);
  assert.ok(addItem(w.scene, bagId, "hide", 1).ok, "先把唯一那格占掉");

  const before = corpseAt(w.scene, cell)!.items.slice();
  const t = takeFromCorpse(w.scene, cell, bagId);
  assert.equal(t.ok, false, "背包满了却报成功");
  assert.deepEqual(corpseAt(w.scene, cell)!.items, before, "尸体少了东西 —— 顺序反了（先扣后进包）");
  assert.equal(countItem(w.scene, bagId, "meat"), 0);
});

test("★★ 多条目拿一半失败 ⇒ 已进包的退回（全成或全不成）", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const p = posOf(w, cell);
  // 排序后是 hide 在前、meat 在后：hide 进得去，meat 两个需要两格
  assert.ok(spawnCorpse(w.scene, [{ kind: "hide", count: 1 }, { kind: "meat", count: 2 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 }).ok);
  // 两格、每堆 1 个：hide 占一格，meat 要两格 ⇒ 第二项失败
  const bagNode = w.scene.spawn("bag", null);
  assert.ok(bagNode.ok);
  // ★ `spawn` 是排队的（结构性修改），不 flush 就 `find` 不到它
  w.scene.flush();
  const bagId = bagNode.value.id;
  assert.ok(makeInventory(w.scene, bagId, 2, 1).ok);

  const before = corpseAt(w.scene, cell)!.items.slice();
  const t = takeFromCorpse(w.scene, cell, bagId);
  assert.equal(t.ok, false, "第二项放不下却报了成功");
  assert.equal(countItem(w.scene, bagId, "hide"), 0, "第一项没有退回 —— 背包比尸体多了一件");
  assert.deepEqual(corpseAt(w.scene, cell)!.items, before, "尸体被扣过了");
});

test("★ 没有尸体 / 没有那个种类：都报 CORPSE.NONE，不静默返回空", () => {
  const w = makeWorld();
  const cell = walkableCell(w);
  const none = takeFromCorpse(w.scene, cell, w.heroId);
  assert.equal(none.ok, false);
  assert.equal(none.ok ? "" : none.error.code, CORPSE_NONE);

  const p = posOf(w, cell);
  assert.ok(spawnCorpse(w.scene, [{ kind: "meat", count: 1 }], { ground: w.nav, x: p.x, z: p.z, nowTick: 0 }).ok);
  const wrong = takeFromCorpse(w.scene, cell, w.heroId, { kind: "hide" });
  assert.equal(wrong.ok, false);
  assert.equal(wrong.ok ? "" : wrong.error.code, CORPSE_NONE);
  assert.deepEqual(corpseAt(w.scene, cell)!.items, ["meat:1"], "点错种类也把东西扣掉了");
});
