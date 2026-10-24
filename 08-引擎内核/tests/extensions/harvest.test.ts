/**
 * L4 · 采集闭环测试（资源 → 被拿走 → 名额还回来 → 能再长）
 *
 * 这一批之前，世界里只有"长出来"，没有"被拿走"。而"采不走"和"采了名额不还"
 * 两种失效在画面上**都看不出来**：
 *   · 前者：砍完了树还在那儿（其实是节点没销毁）；
 *   · 后者：这片林子砍空之后再也不生长了（其实是去重索引没释放那一格）。
 * 所以判据必须同时盯住**场景侧**与**索引侧**，而且要用"能不能再长出来"来收尾 ——
 * 只验"节点没了"的判据，对第二种失效完全无感。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { Logger } from "../../src/foundation/log/logger.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import { generateWorld, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import {
  SITE_TYPE,
  TERRAIN_TYPE,
  SiteMarker,
  assembleWorld,
  registerWorldComponents,
} from "../../src/extensions/worldgen/assemble.ts";
import { WORLD_TASK_SCHEMA } from "../../src/extensions/worldgen/tasks.ts";
import {
  RESOURCE_TYPE,
  ResourceMarker,
  createWorldTaskModule,
  registerResourceComponent,
  type WorldTaskModuleHandle,
} from "../../src/extensions/worldgen/task-module.ts";
import { HARVEST_BAD_CELL, HARVEST_NOTHING, harvestAt } from "../../src/extensions/worldgen/harvest.ts";

const FD = 1 / 30;

function ctx(): ModuleContext {
  return {
    log: new Logger(() => 0),
    events: new EventBus<Record<string, unknown>>(),
    services: new ServiceRegistry(),
    platform: {} as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
}

/** `maxSitesPerCell = 0`：地图上没有计划投放点，于是每一次刷都看得清清楚楚。 */
function makeWorld(seed = 7, width = 32, height = 24, maxSitesPerCell = 0): { scene: Scene; plan: WorldPlan } {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed, width, height, maxSitesPerCell });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  assert.ok(assembleWorld(g.value, scene).ok);
  return { scene, plan: g.value };
}

function makeModule(scene: Scene, plan: WorldPlan, picksPerRun: number, maxResources?: number): WorldTaskModuleHandle {
  const mod = createWorldTaskModule({
    tasks: { schema: WORLD_TASK_SCHEMA, tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun, biomes: ["grass"] }] },
    plan,
    scene,
    maxResources,
  });
  const r = mod.init(ctx());
  assert.ok(!(r instanceof Promise));
  assert.ok(r === undefined || r.ok, r !== undefined && !r.ok ? `init 失败：${r.error.code}` : "");
  mod.start?.();
  return mod;
}

function resources(scene: Scene): ResourceMarker[] {
  return [...scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)];
}

// ── ① 采走 ────────────────────────────────────────────────────

test("★ 采走一个再生资源：节点从场景里消失，返回种类与来源", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 3);
  mod.update(10, FD);
  const before = resources(scene);
  assert.equal(before.length, 3);
  const target = before[0]!;
  const nodeId = target.node!.id;

  const r = harvestAt(scene, target.cell, { onRelease: (c) => mod.releaseCell(c) });
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(r.value.cell, target.cell);
  assert.equal(r.value.kind, target.kind);
  assert.equal(r.value.source, "resource");
  assert.equal(scene.countOf(RESOURCE_TYPE), 2, "组件还在 —— 采了等于没采");
  assert.equal(scene.find(nodeId), undefined, "节点还在场景索引里");
});

test("计划自带的投放点也能采（source = site）", () => {
  const { scene } = makeWorld(7, 32, 24, 2);
  const site = [...scene.componentsOf<SiteMarker>(SITE_TYPE)][0]!;
  const before = scene.countOf(SITE_TYPE);
  const r = harvestAt(scene, site.cell);
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(r.value.source, "site");
  assert.equal(scene.countOf(SITE_TYPE), before - 1);
  // 地形不该被误伤
  assert.ok(scene.countOf(TERRAIN_TYPE) > 0);
});

test("空地上采集报 HARVEST.NOTHING，且场景一点都没动", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 1);
  mod.update(10, FD);
  const used = new Set(resources(scene).map((r) => r.cell));
  // 找一个肯定空着的可通行格
  let empty = -1;
  for (let i = 0; i < plan.kinds.length; i++) {
    if (plan.kinds[i] === "grass" && !used.has(i)) {
      empty = i;
      break;
    }
  }
  assert.ok(empty >= 0, "找不到空格，判据没有分辨力");

  const nodesBefore = scene.stats().nodes;
  const r = harvestAt(scene, empty);
  assert.ok(!r.ok);
  if (r.ok) return;
  assert.equal(r.error.code, HARVEST_NOTHING);
  assert.equal(scene.stats().nodes, nodesBefore, "报错了却动了场景");
});

test("非法格子下标报 HARVEST.BAD_CELL（不让 -1 / 小数 悄悄匹配到某格）", () => {
  const { scene } = makeWorld();
  for (const bad of [-1, 1.5, Number.NaN]) {
    const r = harvestAt(scene, bad);
    assert.ok(!r.ok, `${String(bad)} 居然被接受了`);
    if (!r.ok) assert.equal(r.error.code, HARVEST_BAD_CELL);
  }
});

// ── ② 名额释放 ────────────────────────────────────────────────

test("★★ 采走之后名额被释放：那一格不再算「占用」，且 alive 减一", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 3);
  mod.update(10, FD);
  const cell = resources(scene)[0]!.cell;
  assert.ok(mod.isOccupied(cell), "刚刷出来的格子居然是空的 —— 索引没建");
  assert.equal(mod.stats().alive, 3);

  const r = harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) });
  assert.ok(r.ok);
  assert.equal(mod.isOccupied(cell), false, "格子仍被占用 —— 这一格以后再也刷不出东西");
  assert.equal(mod.stats().alive, 2, "alive 没减 —— 上限不会腾出来");
  assert.equal(mod.stats().released, 1);
});

test("★★ 上限按「活着的」算：采走一个之后，原来被上限挡住的又能刷了", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 4, 2); // 上限 2
  mod.update(10, FD);
  assert.equal(mod.stats().spawned, 2);
  assert.equal(mod.stats().skippedCap, 2, "超出的 2 个没被计数");

  mod.update(20, FD);
  assert.equal(mod.stats().spawned, 2, "到了上限还在刷");

  const cell = resources(scene)[0]!.cell;
  assert.ok(harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) }).ok);
  mod.update(30, FD);
  assert.equal(mod.stats().spawned, 3, "腾出名额之后仍然刷不出来 —— 上限还在按累计数算");
  assert.ok(mod.stats().alive <= 2);
});

test("释放一个没被占用的格子返回 false（不抛、不把 alive 减成负数）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 1);
  mod.update(10, FD);
  const alive = mod.stats().alive;
  assert.equal(mod.releaseCell(999999), false);
  assert.equal(mod.stats().alive, alive);
  assert.equal(mod.stats().released, 0);
});

test("重复采集同一格：第二次报 HARVEST.NOTHING（不会把别的节点也删掉）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 3);
  mod.update(10, FD);
  const cell = resources(scene)[0]!.cell;
  assert.ok(harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) }).ok);
  const count = scene.countOf(RESOURCE_TYPE);
  const second = harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) });
  assert.ok(!second.ok);
  if (!second.ok) assert.equal(second.error.code, HARVEST_NOTHING);
  assert.equal(scene.countOf(RESOURCE_TYPE), count, "第二次采集又删了一个");
});

// ── ③ 闭环：能再长 ────────────────────────────────────────────

test("★★ 闭环：砍空之后这片地还能重新长出来（同一个 seed 下 tick 继续走）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 2);
  // 连刷几轮，每次刷完立刻全采掉 —— 模拟"玩家一路砍"
  let totalSpawned = 0;
  for (let round = 1; round <= 5; round++) {
    mod.update(round * 10, FD);
    const now = resources(scene);
    for (const r of now) {
      const h = harvestAt(scene, r.cell, { onRelease: (c) => mod.releaseCell(c) });
      assert.ok(h.ok, h.ok ? "" : `第 ${round} 轮采集失败：${h.error.code}`);
    }
    totalSpawned += now.length;
    assert.equal(scene.countOf(RESOURCE_TYPE), 0, `第 ${round} 轮采完还有剩`);
  }
  assert.ok(totalSpawned >= 8, `五轮只长出了 ${totalSpawned} 个 —— 后几轮被"已占用"挡住了？`);
  assert.equal(mod.stats().released, totalSpawned, "释放次数与采走数量对不上");
  assert.equal(mod.stats().alive, 0);
});
