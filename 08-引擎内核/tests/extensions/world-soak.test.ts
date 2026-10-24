/**
 * L4 · 长跑（"刷 → 采"跑几百轮之后，世界里不该剩下任何东西）
 *
 * ★ 为什么单轮判据不够：`harvest.test.ts` 的 9 条都是**一轮**的 —— 采一个、验两块状态。
 *   而长跑里才会出现的是**累积类**的失效：
 *     · 场景侧没回收（`destroy` 排了命令但 `flush` 没跑到）⇒ 节点数一路涨；
 *     · 索引侧没清（某一轮释放漏了）⇒ 那一格永久被占，越玩越荒；
 *     · 账目侧（`alive` / `released`）漂移 ⇒ 上限判断失准，静默变成"无限刷"或"再也不刷"。
 *   这三类在**任何单轮判据**里都看不出来，因为第一轮永远是对的。
 *
 * ★ 判据的写法：用"**回到基线**"，不用"小于某个数"。
 *   节点数涨到 200 也满足"小于 10 万"，而它明显是泄漏。
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
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { WORLD_TASK_SCHEMA } from "../../src/extensions/worldgen/tasks.ts";
import {
  RESOURCE_TYPE,
  ResourceMarker,
  createWorldTaskModule,
  registerResourceComponent,
  type WorldTaskModuleHandle,
} from "../../src/extensions/worldgen/task-module.ts";
import { HARVEST_NOTHING, harvestAt } from "../../src/extensions/worldgen/harvest.ts";

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

function makeWorld(seed = 11, width = 24, height = 18): { scene: Scene; plan: WorldPlan; baseNodes: number } {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed, width, height, maxSitesPerCell: 0 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  assert.ok(assembleWorld(g.value, scene).ok);
  return { scene, plan: g.value, baseNodes: scene.stats().nodes };
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

/** 采光当前世界里所有再生资源，返回采掉的格子。 */
function harvestAll(scene: Scene, mod: WorldTaskModuleHandle): number[] {
  const cells: number[] = [];
  for (const r of resources(scene)) {
    const h = harvestAt(scene, r.cell, { onRelease: (c) => mod.releaseCell(c) });
    assert.ok(h.ok, h.ok ? "" : `采集失败：${h.error.code} ${h.error.message}`);
    cells.push(r.cell);
  }
  return cells;
}

// ── ① 循环 300 轮：一切都回到基线 ─────────────────────────────

test("★★ 300 轮「刷 → 全采」：节点数回到基线、alive 归零、spawned === released", () => {
  const { scene, plan, baseNodes } = makeWorld();
  const mod = makeModule(scene, plan, 3);

  const everUsed = new Set<number>();
  for (let round = 1; round <= 300; round++) {
    mod.update(round * 10, FD);
    for (const c of harvestAll(scene, mod)) everUsed.add(c);

    assert.equal(scene.countOf(RESOURCE_TYPE), 0, `第 ${round} 轮采完还有剩`);
    assert.equal(mod.stats().alive, 0, `第 ${round} 轮 alive 没归零`);
    // ★ 账目 vs 索引：两套状态必须同步。用账目推账目等于没对账，所以读的是索引本身
    assert.equal(mod.stats().occupied, 0, `第 ${round} 轮索引里还剩 ${mod.stats().occupied} 格（漏释放）`);
    // ★ 节点数必须**回到基线**：涨着的就是"destroy 排了但没 flush"或"根本没 destroy"
    assert.equal(scene.stats().nodes, baseNodes, `第 ${round} 轮节点数 ${scene.stats().nodes} ≠ 基线 ${baseNodes}（泄漏）`);
  }

  const s = mod.stats();
  assert.equal(s.spawned, s.released, `刷了 ${s.spawned} 个、还了 ${s.released} 个名额 —— 账目漂移`);
  assert.ok(s.spawned >= 300, `300 轮只刷出 ${s.spawned} 个 —— 循环没真的跑起来`);
  // ★ 索引侧：所有用过的格子都必须空出来，否则那几格以后永远刷不出东西
  for (const c of everUsed) {
    assert.equal(mod.isOccupied(c), false, `格子 ${c} 仍被占用（跑过 ${300} 轮之后）`);
  }
});

// ── ② 不采集：有界但不静默丢弃 ────────────────────────────────

test("★ 500 轮「只刷不采」：alive 不超过上限、节点数有界、skippedCap 如数增长", () => {
  const { scene, plan, baseNodes } = makeWorld();
  const mod = makeModule(scene, plan, 4, 6); // 上限 6

  for (let round = 1; round <= 500; round++) {
    mod.update(round * 10, FD);
    assert.ok(mod.stats().alive <= 6, `第 ${round} 轮 alive = ${mod.stats().alive} > 上限 6`);
  }

  const s = mod.stats();
  assert.equal(s.alive, 6, "到上限之后应该正好停在 6");
  assert.equal(s.spawned, 6);
  assert.equal(s.occupied, 6, "索引格数与活着的资源数对不上（两套状态漂移）");
  assert.ok(s.skippedCap > 0, "超上限的一个都没记 —— 静默丢弃了");
  // 节点数 = 基线 + 活着的资源。多一点就是泄漏，少一点就是漏刷
  assert.equal(scene.stats().nodes, baseNodes + 6);
});

// ── ③ 同一格连采：第一次之后都是 NOTHING，且账目不再变 ────────

test("同一格连采 100 次：只有第一次成功，alive / released 各只变一次", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 2);
  mod.update(10, FD);
  const cell = resources(scene)[0]!.cell;

  assert.ok(harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) }).ok);
  const after = mod.stats();
  const nodesAfterFirst = scene.stats().nodes;

  for (let i = 0; i < 99; i++) {
    const r = harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) });
    assert.ok(!r.ok);
    if (!r.ok) assert.equal(r.error.code, HARVEST_NOTHING);
  }

  const now = mod.stats();
  assert.equal(now.alive, after.alive, "重复采集把 alive 又减了");
  assert.equal(now.released, after.released, "重复采集把 released 又加了");
  assert.equal(scene.stats().nodes, nodesAfterFirst, "重复采集动了场景");
});

// ── ⑤ 读档后接模块：索引必须认得出"已经在场景里的资源" ────────

test("★ 资源已经在场景里时才建索引（读档路径）：一格都不该被盖上去", () => {
  const { scene, plan } = makeWorld();
  // 第一个模块先刷出 3 个，然后**换一个模块**（模拟"读档后新建模块"：
  // 新模块的索引是空的，必须先扫场景）
  const first = makeModule(scene, plan, 3);
  first.update(10, FD);
  assert.equal(resources(scene).length, 3);
  const cells = new Set(resources(scene).map((r) => r.cell));

  const second = makeModule(scene, plan, 3);
  second.update(10, FD); // 同一批格子：全都不该刷

  const s = second.stats();
  assert.equal(s.spawned, 0, `读档后新模块又刷了 ${s.spawned} 个 —— 索引没扫到已经在场景里的资源`);
  assert.equal(s.skippedExisting, 3, "去重没生效");
  assert.equal(s.occupied, 3, "索引里只有 3 格（那 3 个已有资源）");
  assert.equal(resources(scene).length, 3, "资源被盖了一层");
  for (const c of cells) assert.ok(second.isOccupied(c));
});


test("★ 同 seed 同一串「刷 / 采」操作 ⇒ 两次运行的账目与场景指纹完全一致", () => {
  const run = (): string => {
    const { scene, plan } = makeWorld(23, 20, 16);
    const mod = makeModule(scene, plan, 3);
    const log: string[] = [];
    for (let round = 1; round <= 20; round++) {
      mod.update(round * 10, FD);
      const cells = harvestAll(scene, mod);
      log.push(`${round}:${cells.join(",")}`);
    }
    const s = mod.stats();
    return `${log.join("|")}#${s.spawned}/${s.alive}/${s.released}/${s.skippedExisting}/${s.skippedCap}#${scene.stats().nodes}`;
  };
  assert.equal(run(), run(), "同样的操作序列给出了不同的结果 —— 采集路径里有不确定性");
});
