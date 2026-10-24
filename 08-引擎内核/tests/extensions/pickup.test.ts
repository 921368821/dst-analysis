/**
 * L4 · 半径拾取测试（T355）
 *
 * 拾取把三层接在一起：**世界资源 → 背包 → 名额归还**。它有三个各自独立的失效方式，
 * 每一种在画面上都只表现为"按了 G 没什么反应"：
 *  ① 顺序错（先摘后进包）⇒ 背包满了会**凭空消失**资源；
 *  ② 背包满了还继续试 ⇒ 玩家看不出为什么只捡到一半；
 *  ③ 名额不还 ⇒ 采走的格子永远不再长（这一条只能靠"还能再长"收尾）。
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
import type { Result, EngineError } from "../../src/foundation/result.ts";
import { addItem, countItem, makeInventory, registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { pickupNearby } from "../../src/extensions/inventory/pickup.ts";

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

function makeWorld(seed = 7): { scene: Scene; plan: WorldPlan } {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerInventoryComponents(reg);
  const scene = new Scene("world", reg);
  const g = generateWorld({ seed, width: 32, height: 24, maxSitesPerCell: 0 });
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
  // `IModule.init` 的返回类型是 `ModuleHookResult`（含 Promise 的联合），这里只走同步路径
  const r = mod.init(ctx()) as Result<void, EngineError> | undefined;
  assert.ok(r === undefined || r.ok, r === undefined || r.ok ? "" : `init 失败：${r.error.code}`);
  mod.start?.();
  return mod;
}

function resources(scene: Scene): ResourceMarker[] {
  return [...scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)];
}

/** 玩家节点：只要有个位置，拾取会自己算距离。 */
function addOwner(scene: Scene, x = 0, z = 0, maxStacks = 8): number {
  const r = scene.spawn("owner", null);
  assert.ok(r.ok);
  scene.flush();
  scene.find(r.value.id)!.setLocalPosition(x, z);
  const inv = makeInventory(scene, r.value.id, maxStacks);
  assert.ok(inv.ok, inv.ok ? "" : `${inv.error.code} ${inv.error.message}`);
  return r.value.id;
}

// ── ① 顺序与报告 ──────────────────────────────────────────────

test("★ 半径内的资源全部进背包，且世界那一侧同步减少（两块状态一起变）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 3);
  mod.update(10, FD);
  const before = resources(scene).length;
  const owner = addOwner(scene, 0, 0);
  // 站在第一堆资源的位置上，半径开大一点确保覆盖全部
  const p = resources(scene)[0]!.node!.worldPosition;
  scene.find(owner)!.setLocalPosition(p.x, p.y);

  let released = 0;
  const r = pickupNearby(scene, p.x, p.y, 999, owner, {
    onRelease: (c) => {
      released += mod.releaseCell(c) ? 1 : 0;
      return true;
    },
  });
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  const out = r.value;
  assert.equal(out.inRange, before, `半径 999 应该覆盖全部 ${before} 个`);
  assert.equal(out.picked.length, before);
  assert.equal(out.remaining, 0);
  assert.equal(out.failed, null);
  assert.equal(scene.countOf(RESOURCE_TYPE), 0, "资源全被拾走了，组件却还在");
  assert.equal(released, before, `名额归还了 ${released} 次，应为 ${before} 次`);
  const total = out.picked.reduce((a, x) => a + x.total, 0);
  assert.ok(total >= before, `背包里的总数 ${total} 少于拾取次数 ${before}`);
  // 背包真的能按种类数出来
  const kinds = new Set(out.picked.map((x) => x.kind));
  for (const k of kinds) assert.ok(countItem(scene, owner, k) > 0, `${k} 不在背包里`);
});

test("★★ 按「最近优先」拾取（同距离用 nodeId 兜底，保证可回放）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 6);
  mod.update(10, FD);
  const owner = addOwner(scene, 0, 0);
  const list = resources(scene)
    .map((m) => ({ cell: m.cell, p: m.node!.worldPosition, id: m.node!.id }))
    .sort((a, b) => a.id - b.id);
  assert.ok(list.length >= 3, "资源太少，判据分辨力不足");

  // 站在离所有资源都很远的地方，只给一个"刚好覆盖前两个"的半径
  const cx = list[0]!.p.x;
  const cz = list[0]!.p.y;
  const r = pickupNearby(scene, cx, cz, 999, owner, { max: 2 });
  assert.ok(r.ok);
  assert.equal(r.value.picked.length, 2, "单次上限没生效");
  assert.ok(r.value.remaining > 0, "`remaining` 没算出来 —— 玩家看不出为什么只捡了一部分");
  // 第一个被拾的必须是从 (cx,cz) 看最近的那一个
  const nearest = [...list].sort((a, b) => {
    const da = (a.p.x - cx) ** 2 + (a.p.y - cz) ** 2;
    const db = (b.p.x - cx) ** 2 + (b.p.y - cz) ** 2;
    return da !== db ? da - db : a.id - b.id;
  })[0]!;
  assert.equal(r.value.picked[0]!.cell, nearest.cell, "第一个拾的不是最近的那个");
});

// ── ② 背包满：不许把资源凭空摘掉 ───────────────────────────────

test("★★ 背包满时：一个都不进包、也一个都不摘，并且**说出来**（不是静默半成功）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 3);
  mod.update(10, FD);
  const owner = addOwner(scene, 0, 0, 1); // 只放得下 1 堆
  // ★ 用一件**世界里不会产出**的物品把唯一的堆占满：这样判据不依赖"这张地图恰好有几种资源"。
  //   （第一版就是这么写的，结果这张种子只出一种资源，判据自己变成了空转。）
  const filler = addItem(scene, owner, "test.filler", 1);
  assert.ok(filler.ok, filler.ok ? "" : `${filler.error.code}`);

  const beforeRes = scene.countOf(RESOURCE_TYPE);
  const beforeBag = countItem(scene, owner, "test.filler");
  const p = resources(scene)[0]!.node!.worldPosition;
  const r = pickupNearby(scene, p.x, p.y, 999, owner, { max: 4, onRelease: (c) => mod.releaseCell(c) });
  assert.ok(r.ok);
  assert.equal(r.value.picked.length, 0, "背包满了还往里塞");
  assert.ok(r.value.failed !== null, "失败了却没报出来 —— 玩家只会看到「按了没反应」");
  assert.equal(r.value.failed!.code, "INVENTORY.FULL");
  assert.equal(r.value.inRange > 0, true, "半径里应该有资源（否则这条判据测的是「附近没东西」）");
  assert.equal(scene.countOf(RESOURCE_TYPE), beforeRes, "背包满了却把资源摘掉了 —— 树倒了、玩家什么都没拿到，而计数全自洽");
  assert.equal(countItem(scene, owner, "test.filler"), beforeBag, "失败的那次不该动背包");
});

// ── ③ 边界与正常空结果 ────────────────────────────────────────

test("★ 半径外明明有资源也不拾（「没有」与「不在半径内」不能混）", () => {
  const { scene, plan } = makeWorld();
  // ★ 必须先让世界里**真的有**资源：第一版这里没刷资源，于是"半径不生效"也全绿 ——
  //   判据的空转判定不是"断言写得对不对"，而是"场景里到底有没有东西"。
  const mod = makeModule(scene, plan, 3);
  mod.update(10, FD);
  assert.ok(resources(scene).length > 0, "先决条件：世界里得有资源");
  const owner = addOwner(scene, 500, 500);
  const r = pickupNearby(scene, 500, 500, 1.5, owner);
  assert.ok(r.ok);
  assert.equal(r.value.inRange, 0, "半径 1.5 之外的东西被算进来了 —— 站在空地按一下就把整张图吸干");
  assert.equal(r.value.picked.length, 0);
  assert.equal(r.value.failed, null, "「附近什么都没有」不该被报成失败");
  assert.ok(resources(scene).length > 0, "资源被远距离拾走了");
});

test("半径非法（负数）立刻报错，不静默当成 0", () => {
  const { scene } = makeWorld();
  const owner = addOwner(scene);
  const r = pickupNearby(scene, 0, 0, -1, owner);
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, "PICKUP.BAD_RADIUS");
});

test("没有背包的拥有者：报 INVENTORY.NO_OWNER，而不是「拾了但不知道给谁」", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 2);
  mod.update(10, FD);
  const stray = scene.spawn("stray", null);
  assert.ok(stray.ok);
  scene.flush();
  const p = resources(scene)[0]!.node!.worldPosition;
  const r = pickupNearby(scene, p.x, p.y, 999, stray.value.id, { onRelease: (c) => mod.releaseCell(c) });
  assert.ok(r.ok);
  assert.equal(r.value.picked.length, 0);
  assert.equal(r.value.failed?.code, "INVENTORY.NO_OWNER");
  assert.equal(scene.countOf(RESOURCE_TYPE), resources(scene).length, "资源不该被摘");
});

// ── ④ 收尾：采空的格子还能再长（名额真的还回去了） ─────────────

test("★★ 拾空之后还能再长出来（名额归还的最终验收）", () => {
  const { scene, plan } = makeWorld();
  const mod = makeModule(scene, plan, 4);
  mod.update(10, FD);
  const owner = addOwner(scene, 0, 0, 16);
  const p = resources(scene)[0]!.node!.worldPosition;
  const r = pickupNearby(scene, p.x, p.y, 999, owner, { onRelease: (c) => mod.releaseCell(c) });
  assert.ok(r.ok);
  assert.equal(scene.countOf(RESOURCE_TYPE), 0, "先决条件：整片都拾空了");
  const st0 = mod.stats();
  assert.equal(st0.alive, 0);
  assert.equal(st0.occupied, 0, "名额没还回去 —— 这片林子以后再也不长了");
  // 再跑一轮再生：必须能长出来
  mod.update(20, FD);
  const st1 = mod.stats();
  assert.ok(st1.alive > 0, "拾空之后再也没长出来（索引没释放）");
  assert.ok(resources(scene).length > 0);
});
