/**
 * L4 · 世界全链路（一次把十一个批次拼起来跑）
 *
 * 这一串批次各自都有判据，但它们**从来没有在一条链上一次跑过**：
 *   生成 → 装配 → 任务表 → 重生资源 → 可见化 → 出生落地 → 存档 → 读档 → 再可见化。
 *
 * ★★ 为什么"每一段都绿"还不够：这个项目已经踩到过两次同类问题 ——
 *   `spriteToRenderItem` 那个"搬运漏字段"（组件绿、batch 绿、画面错位），
 *   以及 `pivotX` 那个"旧档压成 0"（新档全绿、旧档全错）。
 *   两次都不是某一段写错了，而是**段与段之间的约定**没人验。
 *
 * 所以这里只验"接口对得上"，不重复验各段内部的规则：
 *   ① 全链路两次（独立场景）指纹相同；
 *   ② 存档往返之后，玩家、Sprite、地形、资源的**全部字段**都还在；
 *   ③ 读档之后再跑一次可见化，必须是**纯跳过**（幂等跨越序列化边界仍然成立）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { loadScene, saveScene } from "../../src/core/scene/scene-io.ts";
import { FixedStepScheduler } from "../../src/core/scheduler/scheduler.ts";
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
  TerrainArea,
  assembleWorld,
  registerWorldComponents,
  sceneDigest,
} from "../../src/extensions/worldgen/assemble.ts";
import { WORLD_TASK_SCHEMA } from "../../src/extensions/worldgen/tasks.ts";
import {
  RESOURCE_TYPE,
  ResourceMarker,
  createWorldTaskModule,
  registerResourceComponent,
} from "../../src/extensions/worldgen/task-module.ts";
import { PLAYER_TYPE, PlayerSpawn, registerPlayerComponent, spawnPlayer } from "../../src/extensions/worldgen/spawn.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";
import { buildProceduralAtlas } from "../../src/extensions/render/atlas.ts";
import { attachWorldVisuals } from "../../src/extensions/render/world-visuals.ts";

const FD = 1 / 30;

function makeRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerPlayerComponent(reg);
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

/**
 * 一条链：生成 → 装配 → 刷一批再生资源 → 可见化 → 出生落地。
 * 返回场景与计划（计划里带着"这一局该长什么样"的全部信息）。
 */
function fullChain(seed = 7, width = 32, height = 24): { scene: Scene; plan: WorldPlan } {
  const scene = new Scene("world", makeRegistry());
  const g = generateWorld({ seed, width, height, maxSitesPerCell: 2 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);

  const a = assembleWorld(g.value, scene);
  assert.ok(a.ok, a.ok ? "" : `装配失败：${a.error.code} ${a.error.message}`);

  const mod = createWorldTaskModule({
    tasks: { schema: WORLD_TASK_SCHEMA, tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun: 3, biomes: ["grass", "forest"] }] },
    plan: g.value,
    scene,
  });
  const init = mod.init(makeCtx());
  assert.ok(!(init instanceof Promise));
  assert.ok(init === undefined || init.ok, init !== undefined && !init.ok ? `任务模块 init 失败：${init.error.code}` : "");
  mod.start?.();
  mod.update(10, FD);

  const vis = attachWorldVisuals(scene, [...buildProceduralAtlas().frames.keys()]);
  assert.ok(vis.ok, vis.ok ? "" : `可见化失败：${vis.error.code} ${vis.error.message}`);

  const spawn = spawnPlayer(scene, g.value);
  assert.ok(spawn.ok, spawn.ok ? "" : `出生失败：${spawn.error.code} ${spawn.error.message}`);

  return { scene, plan: g.value };
}

test("★ 全链路两次（两张独立场景）指纹完全相同", () => {
  const a = fullChain(7, 32, 24);
  const b = fullChain(7, 32, 24);
  const da = sceneDigest(a.scene);
  const db = sceneDigest(b.scene);
  assert.ok(da.ok && db.ok);
  if (!da.ok || !db.ok) return;
  assert.equal(da.value, db.value, "同种子同计划跑两遍，场景指纹不同 —— 某一段引入了执行历史/随机");

  // 顺带确认这条链真的产出了四类东西（否则"指纹相同"可能只是"两边都空"）
  assert.ok(a.scene.countOf(TERRAIN_TYPE) > 0, "没有地形");
  assert.ok(a.scene.countOf(SITE_TYPE) > 0, "没有投放点");
  assert.ok(a.scene.countOf(PLAYER_TYPE) === 1, "没有玩家");
  assert.ok(a.scene.countOf(SPRITE_TYPE) > 0, "没有精灵");
  assert.equal(a.scene.countOf(RESOURCE_TYPE), 0, "maxSitesPerCell=2 时地图已铺满，再生一个都不该刷（去重生效）");
});

test("★★ 存档往返之后，四类组件的**全部字段**都还在（指纹不变）", () => {
  const { scene } = fullChain(7, 24, 18);
  const before = sceneDigest(scene);
  assert.ok(before.ok);

  const snap = saveScene(scene);
  const scene2 = new Scene("world", makeRegistry());
  const loaded = loadScene(scene2, snap, scene2.components);
  assert.ok(loaded.ok, loaded.ok ? "" : `读档失败：${loaded.error.code}`);
  if (!loaded.ok) return;
  assert.deepEqual(loaded.value.missingFields, [], "读档报了缺字段 —— 有组件的新字段没进 schema");

  const after = sceneDigest(scene2);
  assert.ok(after.ok);
  if (!before.ok || !after.ok) return;
  assert.equal(after.value, before.value, "存档往返后指纹变了 —— 有字段没被写进存档或没被读回来");

  // 逐项抽查：玩家、地形、投放点、资源
  const player = [...scene2.componentsOf<PlayerSpawn>(PLAYER_TYPE)];
  assert.equal(player.length, 1);
  assert.equal(player[0]!.cell, [...scene.componentsOf<PlayerSpawn>(PLAYER_TYPE)][0]!.cell);
  assert.ok(player[0]!.node!.get<Sprite>(SPRITE_TYPE) !== undefined, "玩家读回来没有身体");

  const terrains = [...scene2.componentsOf<TerrainArea>(TERRAIN_TYPE)];
  assert.ok(terrains.length > 0);
  for (const t of terrains) {
    const sp = t.node!.get<Sprite>(SPRITE_TYPE)!;
    assert.equal(sp.width, t.w);
    assert.equal(sp.height, t.h);
    assert.equal(sp.pivotX, 0);
  }
  assert.ok([...scene2.componentsOf<SiteMarker>(SITE_TYPE)].length > 0);
  assert.ok([...scene2.componentsOf<ResourceMarker>(RESOURCE_TYPE)].every((r) => r.node !== null));
});

test("★ 读档之后再跑一次可见化：纯跳过（幂等跨越序列化边界仍然成立）", () => {
  const { scene } = fullChain(7, 24, 18);
  const snap = saveScene(scene);
  const scene2 = new Scene("world", makeRegistry());
  assert.ok(loadScene(scene2, snap, scene2.components).ok);
  const before = scene2.countOf(SPRITE_TYPE);
  // ★ `skipped` 只数**可视化桥管的**节点（地形 / 投放点 / 再生资源）。
  //   玩家也是 `render.sprite`，但它由 `spawnPlayer` 挂 —— 所以两者不能直接相等，
  //   差的那 1 个正是玩家（第一次写这条判据时就差了 1，514 vs 515）。
  const managed =
    scene2.countOf(TERRAIN_TYPE) + scene2.countOf(SITE_TYPE) + scene2.countOf(RESOURCE_TYPE);
  assert.equal(before, managed + 1, "这里假定场景里恰好只有玩家一个非托管精灵");

  const again = attachWorldVisuals(scene2, [...buildProceduralAtlas().frames.keys()]);
  assert.ok(again.ok);
  assert.equal(again.value.terrain, 0, "读档后又挂了一遍地形 —— 组件数会翻倍");
  assert.equal(again.value.sites, 0);
  assert.equal(again.value.resources, 0);
  assert.equal(again.value.skipped, managed);
  assert.equal(scene2.countOf(SPRITE_TYPE), before);
});

test("跳出时间的那条路：一次 update(1000) 只刷 1 批（与逐 tick 区分），且世界仍然一致", () => {
  // 这一段放进 E2E 是因为"跳时间"是**宿主**会做的事（切后台回来），
  // 而它一旦被当成逐 tick 补齐，资源就会被刷满整张图 —— 那种事只在整条链上看得出来。
  const scene = new Scene("world", makeRegistry());
  const g = generateWorld({ seed: 3, width: 32, height: 24, maxSitesPerCell: 0 });
  assert.ok(g.ok);
  assert.ok(assembleWorld(g.value, scene).ok);

  const mod = createWorldTaskModule({
    tasks: { schema: WORLD_TASK_SCHEMA, tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun: 2, biomes: ["grass"] }] },
    plan: g.value,
    scene,
  });
  mod.init(makeCtx());
  mod.start?.();
  mod.update(1000, FD);
  assert.equal(mod.stats().fires, 1);
  assert.equal(mod.stats().spawned, 2);
  assert.equal(mod.lastFires()[0]!.missed, 99);

  const vis = attachWorldVisuals(scene, [...buildProceduralAtlas().frames.keys()]);
  assert.ok(vis.ok);
  assert.equal(vis.value.resources, 2, "刷出来的 2 个资源没有全部得到精灵");
});

test("★★ 内容指纹与呈现无关：挂视觉前后指纹相同（但改世界内容必须变）", () => {
  // 这条是**全链路判据逼出来的**：装配完能算指纹，一挂 Sprite 就算不出来了
  // （`r/g/b` 是 0..1 浮点，进不了内容指纹）。修法是让指纹排除 `render.*`，
  // 语义上也对：换美术风格不该让世界内容 id 全失效。
  const scene = new Scene("world", makeRegistry());
  const g = generateWorld({ seed: 9, width: 24, height: 18, maxSitesPerCell: 1 });
  assert.ok(g.ok);
  assert.ok(assembleWorld(g.value, scene).ok);

  const bare = sceneDigest(scene);
  assert.ok(bare.ok, bare.ok ? "" : `装配后就算不出指纹：${bare.error.code} ${bare.error.message}`);

  const vis = attachWorldVisuals(scene, [...buildProceduralAtlas().frames.keys()]);
  assert.ok(vis.ok);
  const dressed = sceneDigest(scene);
  assert.ok(dressed.ok, dressed.ok ? "" : `挂上视觉后算不出指纹：${dressed.error.code} ${dressed.error.message}`);
  if (!bare.ok || !dressed.ok) return;
  assert.equal(dressed.value, bare.value, "挂视觉改变了世界指纹 —— 换美术会让内容 id 全失效");

  // 反向：改**内容**必须让指纹变（否则"排除 render"可能排除过头了）
  const site = [...scene.componentsOf<SiteMarker>(SITE_TYPE)][0]!;
  (site as unknown as { kind: string }).kind = "flint";
  const changed = sceneDigest(scene);
  assert.ok(changed.ok);
  if (!changed.ok) return;
  assert.notEqual(changed.value, bare.value, "改了投放点种类，指纹没变 —— 内容被一起排除了");
});

/** 让调度器真的推进（保留一处"逐 tick"的用法，证明它和跳时间不是一回事）。 */
test("逐 tick 推进时资源确实会累积（这是模拟，不是重复刷）", () => {
  const scene = new Scene("world", makeRegistry());
  const g = generateWorld({ seed: 5, width: 32, height: 24, maxSitesPerCell: 0 });
  assert.ok(g.ok);
  assert.ok(assembleWorld(g.value, scene).ok);
  const mod = createWorldTaskModule({
    tasks: { schema: WORLD_TASK_SCHEMA, tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun: 2, biomes: ["grass"] }] },
    plan: g.value,
    scene,
  });
  mod.init(makeCtx());
  mod.start?.();
  const sch = new FixedStepScheduler({ fixedDt: FD, maxStepsPerFrame: 1000, maxFrameDt: 100 });
  sch.onStep((tick, dt) => {
    mod.update(tick, dt);
  });
  for (let i = 0; i < 30; i++) sch.advance(FD);
  assert.equal(mod.stats().fires, 3, "30 步 / 周期 10 = 3 次触发");
  assert.equal(scene.countOf(RESOURCE_TYPE), mod.stats().spawned);
  assert.ok(mod.stats().spawned > 0, "一个都没刷 —— 这条判据没有分辨力");
});
