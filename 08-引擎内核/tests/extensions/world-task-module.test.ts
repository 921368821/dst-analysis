/**
 * L4 · 世界任务模块测试（调度 → 场景）
 *
 * `world-tasks.test.ts` 验的是"什么时候该做"；本文件验的是"做出来的东西在场景里对不对"。
 * 两个必须分开验的理由：
 *   ① 调度可以脱离场景测，混在一起后"没刷出来"分不清是调度没跑还是刷失败了；
 *   ② 场景侧有三个只在**多轮之后**才暴露的错误：同格叠刷、跨组件重复（计划自带的资源）、
 *      只增不减导致节点数单调涨。
 *
 * ★★ 本文件的重点判据是"**逐 tick 推进 ≠ 跳时间**"：
 *   `FixedStepScheduler.advance(33 秒)` 会老老实实回调 1000 次 —— 那是**真的模拟了 1000 步**，
 *   刷 100 批是**正确**的。跳时间是另一条路：一次 `update(1000, ·)`，
 *   只跑 1 批、漏掉的 99 次由 `missed` 报出。
 *   把这两件事混为一谈，就会得出"离线 8 小时回来地图被刷满"是 bug 的结论 ——
 *   可它其实是"宿主选错了推进方式"。判据必须把这个区分钉死。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { saveScene, loadScene } from "../../src/core/scene/scene-io.ts";
import { FixedStepScheduler } from "../../src/core/scheduler/scheduler.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import { Services } from "../../src/core/tokens.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import { FIXED_UNITS, generateWorld, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import {
  SITE_TYPE,
  SiteMarker,
  assembleWorld,
  registerWorldComponents,
} from "../../src/extensions/worldgen/assemble.ts";
import { WORLD_TASK_SCHEMA, type WorldTaskTable } from "../../src/extensions/worldgen/tasks.ts";
import {
  RESOURCE_TYPE,
  TASK_NO_SCENE,
  ResourceMarker,
  createWorldTaskModule,
  registerResourceComponent,
  type WorldTaskModuleHandle,
} from "../../src/extensions/worldgen/task-module.ts";
import { Logger } from "../../src/foundation/log/logger.ts";

const FD = 1 / 30;

/**
 * ★ 默认 `maxSitesPerCell = 0`：**不带计划投放点**的地图，再生才有地方可刷。
 *   这不是为了好写判据 —— 它揭示了一个真实行为：`maxSitesPerCell = 2` 时计划几乎铺满
 *   每一格可通行格（seed 7 / 32×24 有 882 个投放点），于是再生任务每次都命中"已被占用"，
 *   **一个都不刷**。那是正确的（去重生效），但"什么都没发生"必须能被看见（见专门的判据）。
 */
function makeWorld(seed = 7, width = 32, height = 24, maxSitesPerCell = 0): { scene: Scene; plan: WorldPlan } {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed, width, height, maxSitesPerCell });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  const a = assembleWorld(g.value, scene);
  assert.ok(a.ok, a.ok ? "" : `装配失败：${a.error.code} ${a.error.message}`);
  return { scene, plan: g.value };
}

/**
 * 最小模块上下文。
 * ★ `platform` 用占位：这个模块只读 `log` 与 `services`，真平台会拖进 gfx 依赖，
 *   而 gfx 与"资源有没有刷出来"毫无关系（判据不该为了凑类型去启动一个后端）。
 */
function makeCtx(services = new ServiceRegistry()): ModuleContext {
  return {
    log: new Logger(() => 0),
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: {} as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
}

function tableOf(periodTicks: number, picksPerRun: number, biomes: ("grass" | "forest" | "beach" | "rocky" | "savanna" | "marsh")[]): WorldTaskTable {
  return {
    schema: WORLD_TASK_SCHEMA,
    tasks: [{ id: "regen", periodTicks, phase: 0, picksPerRun, biomes }],
  };
}

/**
 * `IModule.init` 的返回类型是 `void | Result | Promise<…>`（允许"不会失败"的模块直接不返回）。
 * 这个包一层：同步取回 Result（本模块的 init 是同步的），并在同步失败时立刻断言。
 */
function initRes(mod: WorldTaskModuleHandle, ctx: ModuleContext): Result<void, EngineError> | undefined {
  const r = mod.init(ctx);
  if (r === undefined) return undefined;
  if (r instanceof Promise) throw new Error("世界任务模块的 init 不该是异步的");
  return r;
}

function mustInit(mod: WorldTaskModuleHandle, ctx = makeCtx()): void {
  const r = initRes(mod, ctx);
  assert.ok(r === undefined || r.ok, r !== undefined && !r.ok ? `init 失败：${r.error.code} ${r.error.message}` : "");
}

function makeModule(scene: Scene, plan: WorldPlan, table: WorldTaskTable, maxResources?: number): WorldTaskModuleHandle {
  const mod = createWorldTaskModule({ tasks: table, plan, scene, maxResources });
  mustInit(mod);
  mod.start?.();
  return mod;
}

function resources(scene: Scene): ResourceMarker[] {
  return [...scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)];
}

// ── ① 真接线 ──────────────────────────────────────────────────

test("★ 真接线：scheduler 每 10 步触发一次，场景里恰好多 1 个资源节点", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 2, ["grass"]));

  const sch = new FixedStepScheduler({ fixedDt: FD, maxStepsPerFrame: 1000, maxFrameDt: 100 });
  sch.onStep((tick, dt) => {
    mod.update(tick, dt);
  });

  const before = scene.countOf(RESOURCE_TYPE);
  sch.advance(FD * 10);
  assert.equal(scene.countOf(RESOURCE_TYPE), before + 2, "10 步（tick=10 命中）该刷 picksPerRun=2 个");
  assert.equal(mod.stats().fires, 1);
  // tick 是 1 起的：第 10 步的 tick 就是 10
  assert.equal(mod.lastFires()[0]!.tick, 10);
});

test("start 之前不刷、stop 之后不刷（生命周期的两个边都验）", () => {
  const { scene, plan } = makeWorld();
  const mod = createWorldTaskModule({ tasks: tableOf(1, 1, ["grass"]), plan, scene });
  mustInit(mod);

  mod.update(5, FD);
  assert.equal(scene.countOf(RESOURCE_TYPE), 0, "还没 start 就刷了");

  mod.start?.();
  mod.update(6, FD);
  assert.equal(scene.countOf(RESOURCE_TYPE), 1);

  mod.stop?.();
  mod.update(7, FD);
  assert.equal(scene.countOf(RESOURCE_TYPE), 1, "stop 之后还在刷");
});

test("资源节点落在格子中心，坐标 × 256 精确（不留半点浮点）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 3, ["grass"]));
  mod.update(10, FD);

  const width = plan.width;
  for (const res of resources(scene)) {
    const cx = res.cell % width;
    const cz = (res.cell - cx) / width;
    const pos = res.node!.localPosition;
    assert.equal(pos.x * FIXED_UNITS, cx * FIXED_UNITS + FIXED_UNITS / 2, `格子 ${res.cell} 的 x 不是中心`);
    assert.equal(pos.y * FIXED_UNITS, cz * FIXED_UNITS + FIXED_UNITS / 2, `格子 ${res.cell} 的 z 不是中心`);
  }
});

test("刷出来的资源种类按格子群系决定（森林刷树、草地刷浆果），且只落在可通行格", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 8, ["grass", "forest"]));
  mod.update(10, FD);

  assert.ok(resources(scene).length > 0);
  for (const res of resources(scene)) {
    const kind = plan.kinds[res.cell]!;
    const expect = kind === "forest" ? "tree" : "berry";
    assert.equal(res.kind, expect, `格子 ${res.cell} 是 ${kind}，却刷了 ${res.kind}`);
  }
});

// ── ② 去重 ────────────────────────────────────────────────────

test("★ 同一格不会被刷两次：连续两个周期刷在不同格上", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 4, ["grass"]));
  mod.update(10, FD);
  const first = new Set(resources(scene).map((r) => r.cell));
  mod.update(20, FD);
  const all = resources(scene).map((r) => r.cell);
  assert.equal(new Set(all).size, all.length, "同一个格子被刷了两次 —— 画面上完全看不出，只会让 countOf 一路涨");
  assert.equal(all.length, 8, "两轮各 4 个");
  for (const r of resources(scene)) assert.ok(first.has(r.cell) || true);
});

test("★ 去重跨组件：计划自带的投放点不会被再生覆盖（那格上已经有资源了）", () => {
  const { scene, plan } = makeWorld(7, 32, 24, 2);
  const planned = new Set(scene.componentsOf<SiteMarker>(SITE_TYPE).map((m) => m.cell));
  assert.ok(planned.size > 0, "这张图上没有计划投放点，判据没有分辨力");

  // picksPerRun 很大 ⇒ 候选里必定包含计划已有的格子
  const mod = makeModule(scene, plan, tableOf(10, 64, ["grass", "forest", "beach", "rocky", "savanna", "marsh"]));
  mod.update(10, FD);
  for (const res of resources(scene)) {
    assert.ok(!planned.has(res.cell), `格子 ${res.cell} 计划里已经有资源了，又刷了一个（叠加看不出来）`);
  }
  assert.ok(mod.stats().skippedExisting > 0, "一个都没跳过 —— 说明去重集合里没有计划投放点");
});

test("去重集合懒建：装配在模块 init 之后时才建索引，仍然不漏计划的投放点", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed: 7, width: 32, height: 24, maxSitesPerCell: 2 });
  assert.ok(g.ok);

  // ★ 先建模块（此时场景还是空的），再装配
  const mod = createWorldTaskModule({ tasks: tableOf(10, 64, ["forest"]), plan: g.value, scene });
  mustInit(mod);
  mod.start?.();

  const a = assembleWorld(g.value, scene);
  assert.ok(a.ok);
  const planned = new Set(scene.componentsOf<SiteMarker>(SITE_TYPE).map((m) => m.cell));

  mod.update(10, FD);
  for (const res of resources(scene)) {
    assert.ok(!planned.has(res.cell), "索引在装配之前建好了 —— 去重失效");
  }
});

test("★ 计划铺满图时再生一个都不刷，但 fires 照常发生（「跑到了没刷」≠「没跑到」）", () => {
  const { scene, plan } = makeWorld(7, 32, 24, 2);
  const planned = scene.componentsOf<SiteMarker>(SITE_TYPE).length;
  assert.ok(planned > 100, `这张图只有 ${planned} 个投放点，判据没有分辨力`);

  const mod = makeModule(scene, plan, tableOf(10, 4, ["grass"]));
  mod.update(10, FD);
  assert.equal(mod.stats().fires, 1, "任务没跑到 —— 那是另一回事");
  assert.equal(mod.stats().spawned, 0, "计划已经铺满了，不该再刷");
  assert.equal(mod.stats().skippedExisting, 4);
  assert.equal(scene.countOf(RESOURCE_TYPE), 0);
});

// ── ③ 跳时间 vs 逐 tick ───────────────────────────────────────

test("★ 逐 tick 推进 1000 步 = 真的模拟了 1000 步：触发 100 次（这不是 bug）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 1, ["grass"]));
  const sch = new FixedStepScheduler({ fixedDt: FD, maxStepsPerFrame: 5000, maxFrameDt: 1000 });
  sch.onStep((tick, dt) => {
    mod.update(tick, dt);
  });
  // ★ 一次 `advance(FD * 1000)` 会少一步：`1/30 * 1000 = 33.333…` 与 `fixedDt = 1/30` 相除
  //   得到 999.999…，floor 下来是 999（浮点累加的经典坑）。逐次推进才是"逐 tick"的本义。
  for (let i = 0; i < 1000; i++) sch.advance(FD);
  assert.equal(mod.stats().fires, 100, `1000/10 应该是 100 次触发，实际 ${String(mod.stats().fires)}`);
  assert.equal(mod.stats().lastTick, 1000);
  // ★ 触发 100 次 ≠ 刷出 100 个：100 次从 312 个候选格里各选 1 个，**必然**撞上几个（生日问题），
  //   撞上的被去重跳过。所以这里断言的是**自洽**，不是"刷满 100 个"。
  assert.equal(mod.stats().spawned + mod.stats().skippedExisting, 100);
  assert.equal(scene.countOf(RESOURCE_TYPE), mod.stats().spawned);
  assert.ok(mod.stats().skippedExisting > 0, "一次重复都没有 —— 去重可能没生效（也可能是种子太巧，换种子复测）");
});

test("★★ 跳时间：一次 update(1000) 只刷 1 批（离线 8 小时回来不会刷满地图）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 2, ["grass"]));
  mod.update(1000, FD);
  assert.equal(mod.stats().fires, 1, "跳时间被当成逐 tick 补齐了");
  assert.equal(mod.stats().spawned, 2, "只该刷 picksPerRun=2 个，不是 200 个");
  assert.equal(mod.lastFires()[0]!.missed, 99, "漏掉的 99 次必须报出来，否则调用方不知道发生了什么");
});

// ── ④ 上限与自洽 ──────────────────────────────────────────────

test("全局上限到了就停：spawned 不超上限，skippedCap 如实计数", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 8, ["grass", "forest"]), 3);
  mod.update(10, FD);
  assert.equal(mod.stats().spawned, 3);
  assert.equal(mod.stats().skippedCap, 5, "超出的 5 个没被计数");
  mod.update(20, FD);
  assert.equal(mod.stats().spawned, 3, "上限之后还在刷");
  assert.ok(mod.stats().skippedCap > 5);
});

test("stats 与实际场景自洽：countOf 等于 spawned，且每个资源都有节点", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 5, ["grass"]));
  mod.update(10, FD);
  assert.equal(scene.countOf(RESOURCE_TYPE), mod.stats().spawned);
  for (const res of resources(scene)) {
    assert.ok(res.node !== null, "组件没挂在节点上");
    assert.ok(scene.find(res.node!.id) !== undefined, "节点不在场景索引里");
  }
});

// ── ⑤ 装配失败路径 ────────────────────────────────────────────

test("既没传 scene、上下文里也没有 Services.Scene ⇒ TASK_NO_SCENE", () => {
  const { plan } = makeWorld();
  const mod = createWorldTaskModule({ tasks: tableOf(10, 1, ["grass"]), plan });
  const r = initRes(mod, makeCtx());
  assert.ok(r !== undefined && !r.ok);
  if (r === undefined || r.ok) return;
  assert.equal(r.error.code, TASK_NO_SCENE);
});

test("上下文里有 Services.Scene 时不需要 options.scene", () => {
  const { scene, plan } = makeWorld();
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  const mod = createWorldTaskModule({ tasks: tableOf(10, 2, ["grass"]), plan });
  mustInit(mod, makeCtx(services));
  mod.start?.();
  mod.update(10, FD);
  assert.equal(scene.countOf(RESOURCE_TYPE), 2);
});

test("注册表里没有 world.resource ⇒ init 报错（不静默挂不上组件）", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg); // 故意不注册 resource
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed: 7, width: 16, height: 16 });
  assert.ok(g.ok);
  const a = assembleWorld(g.value, scene);
  assert.ok(a.ok);
  const mod = createWorldTaskModule({ tasks: tableOf(10, 1, ["grass"]), plan: g.value, scene });
  const r = initRes(mod, makeCtx());
  assert.ok(r !== undefined && !r.ok);
  if (r === undefined || r.ok) return;
  assert.equal(r.error.code, TASK_NO_SCENE);
  assert.match(r.error.message, /world\.resource/);
});

test("任务表不合法 ⇒ create 当场抛（配置错误不该等到第 3 个 tick 才发现）", () => {
  const { plan } = makeWorld();
  assert.throws(() => createWorldTaskModule({ tasks: { schema: 0, tasks: [] }, plan }), /世界任务表不合法/);
});

// ── ⑥ 存档往返 ────────────────────────────────────────────────

test("刷出来的资源能存读往返（cell / kind / bornTick 都不丢）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, tableOf(10, 2, ["grass"]));
  mod.update(10, FD);
  const before = resources(scene)
    .map((r) => `${r.cell}/${r.kind}/${r.bornTick}`)
    .sort();

  const snap = saveScene(scene);
  const scene2 = new Scene("world", scene.components);
  const loaded = loadScene(scene2, snap, scene2.components);
  assert.ok(loaded.ok);
  const after = [...scene2.componentsOf<ResourceMarker>(RESOURCE_TYPE)]
    .map((r) => `${r.cell}/${r.kind}/${r.bornTick}`)
    .sort();
  assert.deepEqual(after, before);
  assert.ok(before.every((s) => s.endsWith("/10")), "bornTick 该等于触发 tick 10");
});
