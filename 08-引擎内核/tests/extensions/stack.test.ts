/**
 * L4 · 地面堆叠（批122：`ResourceMarker.count`）
 *
 * ★ 这一组盯住的是**四类静默失效**，它们的共同点是"所有计数都自洽"：
 *
 *   ① **堆见底了却没销毁** ⇒ 节点留在画面上、名额不还，那一格永远刷不出新东西。
 *      反过来（没见底就销毁）更糟：剩下的一起消失，而背包只收到了 `taken` 个。
 *      两者都能靠"只验 `taken`"通过 —— 所以每条判据都同时读 `left` / 节点数 / 名额。
 *
 *   ② **叠堆的账目串到放置上** ⇒ 叠 3 个却让 `spawned`/`alive`/`occupied` 各 +1，
 *      于是上限提前撞满、去重索引里多出一格。这一路只有 `stacked` 能分辨
 *      （`merged` 标志对了但账目错了，是"标志位对了、效果没发生"的典型）。
 *
 *   ③ **产量的读取时机错了** ⇒ 采摘那一刻才查产量表，于是改配置会把**地上已有**的
 *      资源一起改掉。玩家昨天看到的那棵树今天变成 3 个木头，而新写的判据全绿
 *      （它们只验"新长出来的"）。
 *
 *   ④ **旧档读成空堆** ⇒ 新字段的默认值写在 `schema.defaults` 或零值里而不是
 *      类的初始化器里，`count` 读成 0；空堆既采不动也不会被销毁，
 *      于是"打开旧档 ⇒ 所有资源都变成采不动的装饰"。这条**只在打开旧档时出现**。
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
import { generateWorld, isPassable, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { WORLD_TASK_SCHEMA } from "../../src/extensions/worldgen/tasks.ts";
import {
  ResourceMarker,
  RESOURCE_TYPE,
  TASK_BAD_COUNT,
  TASK_NO_STACK,
  createWorldTaskModule,
  registerResourceComponent,
  type WorldTaskModuleHandle,
} from "../../src/extensions/worldgen/task-module.ts";
import { HARVEST_BAD_AMOUNT, HARVEST_NOTHING, harvestAt, peekResourceAt } from "../../src/extensions/worldgen/harvest.ts";
import { registerPlayerComponents, spawnPlayer } from "../../src/extensions/worldgen/spawn.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { addItem, makeInventory, registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import { dropIntoWorld, findStackCell } from "../../src/extensions/inventory/drop-to-world.ts";
import { loadScene, saveScene } from "../../src/core/scene/scene-io.ts";

const FD = 1 / 30;

function makeRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerPlayerComponents(reg);
  registerInventoryComponents(reg);
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
  readonly tasks: WorldTaskModuleHandle;
  readonly heroId: number;
  readonly registry: ComponentRegistry;
}

function makeWorld(opts: { maxResources?: number; yieldOf?: () => number } = {}): MadeWorld {
  const registry = makeRegistry();
  const scene = new Scene("stack", registry);
  const g = generateWorld({ seed: 11, width: 32, height: 24, maxSitesPerCell: 0 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  assert.ok(assembleWorld(g.value, scene).ok);

  const tasks = createWorldTaskModule({
    tasks: { schema: WORLD_TASK_SCHEMA, tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun: 4, biomes: ["grass", "forest"] }] },
    plan: g.value,
    scene,
    ...(opts.maxResources === undefined ? {} : { maxResources: opts.maxResources }),
    ...(opts.yieldOf === undefined ? {} : { yieldOf: opts.yieldOf }),
  });
  const init = tasks.init(makeCtx());
  assert.ok(init === undefined || (init as { ok?: boolean }).ok === true, "任务模块 init 失败");
  tasks.start?.();

  const spawn = spawnPlayer(scene, g.value);
  assert.ok(spawn.ok, spawn.ok ? "" : `出生失败：${spawn.error.message}`);
  assert.ok(makeInventory(scene, spawn.value.nodeId, 8, 40).ok);
  return { scene, plan: g.value, tasks, heroId: spawn.value.nodeId, registry };
}

/** 找一格"可通行 + 空闲"的格子，跳过前 `skip` 个（用来造"远处有一堆"）。 */
function freeCell(w: MadeWorld, skip = 0): number {
  let seen = 0;
  for (let c = 0; c < w.plan.kinds.length; c++) {
    if (!isPassable(w.plan.kinds[c]!)) continue;
    if (w.tasks.isOccupied(c)) continue;
    if (seen++ < skip) continue;
    return c;
  }
  throw new Error(`可通行空格不足（要跳过 ${String(skip)} 个）—— 判据前提不成立`);
}

function heroPos(scene: Scene, heroId: number): { x: number; z: number } {
  const n = scene.find(heroId);
  assert.ok(n !== undefined, "玩家不在场景里");
  return { x: n!.worldPosition.x, z: n!.worldPosition.y };
}

function marks(scene: Scene): ResourceMarker[] {
  return [...scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)];
}

// ── ① 部分采集与见底 ─────────────────────────────────────────

test("★★ 部分采集：一堆 5 个、这次只要 2 个 ⇒ 拿走 2、剩 3、节点还在、名额**没还**", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  const placed = w.tasks.placeResource(cell, "berry", 0, 5);
  assert.ok(placed.ok, placed.ok ? "" : placed.error.code);

  const h = harvestAt(w.scene, cell, { amount: 2, onRelease: (c) => w.tasks.releaseCell(c) });
  assert.ok(h.ok, h.ok ? "" : h.error.code);
  assert.equal(h.value.taken, 2);
  assert.equal(h.value.left, 3);
  // ★ 同时读三个观测量：这一堆真的少了 ∧ 节点还在 ∧ 名额没还。
  //   只看 `left` 的话，"把 count 改成 3 却顺手销毁了节点"照样绿。
  assert.equal(marks(w.scene).find((m) => m.cell === cell)?.count, 3, "堆里的数量没跟着减");
  assert.equal(w.scene.countOf(RESOURCE_TYPE), 1, "还没见底就把节点销毁了 —— 剩下 3 个一起消失");
  assert.ok(w.tasks.isOccupied(cell), "还没见底就还了名额 —— 再生会在这格再长一个，画面上就是两个叠着");
  assert.equal(w.tasks.stats().released, 0, "released 计数不该动");
});

test("★★ 见底：一堆 2 个、这次要 99 个 ⇒ 拿走 2、剩 0、节点销毁、名额**还了**", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  assert.ok(w.tasks.placeResource(cell, "berry", 0, 2).ok);

  const h = harvestAt(w.scene, cell, { amount: 99, onRelease: (c) => w.tasks.releaseCell(c) });
  assert.ok(h.ok, h.ok ? "" : h.error.code);
  assert.equal(h.value.taken, 2, "要 99 个但只有 2 个 —— 只能给 2 个（多给就是凭空生资源）");
  assert.equal(h.value.left, 0);
  assert.equal(w.scene.countOf(RESOURCE_TYPE), 0, "见底了节点还在画面上");
  assert.equal(w.tasks.isOccupied(cell), false, "见底了名额没还 —— 那一格永远刷不出新东西");
  assert.equal(w.tasks.stats().released, 1);
  assert.equal(w.tasks.stats().alive, 0, "alive 没跟着减 —— 上限会提前撞满");
});

test("★★ 连采三次（每次 2 个）于一堆 5 个：2 / 2 / 1，第三次才见底", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  assert.ok(w.tasks.placeResource(cell, "berry", 0, 5).ok);
  const rel = (c: number): boolean => w.tasks.releaseCell(c);

  const taken: number[] = [];
  const left: number[] = [];
  const alive: number[] = [];
  for (let i = 0; i < 3; i++) {
    const h = harvestAt(w.scene, cell, { amount: 2, onRelease: rel });
    assert.ok(h.ok, h.ok ? "" : `第 ${String(i + 1)} 次：${h.error.code}`);
    taken.push(h.value.taken);
    left.push(h.value.left);
    alive.push(w.scene.countOf(RESOURCE_TYPE));
  }
  // ★ 三个数组一起断言，而不是只断最后一个 `left === 0`：
  //   "每次都从 5 重算" 的实现会给出 taken = [2,2,2] / left = [3,3,3]，
  //   而最后再补一刀"见底"也能凑出 left = 0 —— 只有中间的样本能分辨。
  assert.deepEqual(taken, [2, 2, 1], "第三次只剩 1 个，不该还能给 2 个");
  assert.deepEqual(left, [3, 1, 0]);
  assert.deepEqual(alive, [1, 1, 0], "节点应该活过前两次、第三次才消失");
  assert.equal(w.tasks.stats().released, 1, "只有见底那一次才该还名额");
  // 采空之后同一格再采：必须是 NOTHING（不是"空堆"这种第三态）
  const again = harvestAt(w.scene, cell, { onRelease: rel });
  assert.ok(!again.ok);
  if (!again.ok) assert.equal(again.error.code, HARVEST_NOTHING);
});

test("★ peek 能看到这一堆的数量（背包满时调用方要靠它决定「还能拿几个」）", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  assert.ok(w.tasks.placeResource(cell, "reed", 0, 7).ok);
  const p = peekResourceAt(w.scene, cell);
  assert.ok(p !== null);
  assert.equal(p!.kind, "reed");
  assert.equal(p!.count, 7);
  assert.equal(p!.source, "resource");
});

test("★ 存档被伪造出 count = 0 时按 1 处理（空堆既采不动也不会被销毁，是拆不掉的装饰）", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  assert.ok(w.tasks.placeResource(cell, "berry", 0, 3).ok);
  const m = marks(w.scene).find((x) => x.cell === cell);
  assert.ok(m !== undefined);
  m!.count = 0;

  const h = harvestAt(w.scene, cell, { onRelease: (c) => w.tasks.releaseCell(c) });
  assert.ok(h.ok, h.ok ? "" : "count = 0 的堆采不动 —— 它永远留在地上了");
  assert.equal(h.value.taken, 1, "按 1 处理：给不出 0 个的采集");
  assert.equal(h.value.left, 0);
  assert.equal(w.scene.countOf(RESOURCE_TYPE), 0, "这样它才可能被打扫干净");
});

test("★ 这次采几个传 0 / 负数 ⇒ HARVEST.BAD_AMOUNT，且场景一点没动", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  assert.ok(w.tasks.placeResource(cell, "berry", 0, 4).ok);
  for (const bad of [0, -1, Number.NaN]) {
    const h = harvestAt(w.scene, cell, { amount: bad });
    assert.ok(!h.ok, `amount = ${String(bad)} 居然成功了`);
    if (!h.ok) assert.equal(h.error.code, HARVEST_BAD_AMOUNT, `amount = ${String(bad)} 的错误码不对`);
  }
  assert.equal(marks(w.scene).find((m) => m.cell === cell)?.count, 4, "报错路径改了 count");
  assert.ok(w.tasks.isOccupied(cell));
});

// ── ② 合并与账目 ─────────────────────────────────────────────

test("★★ 两次丢同类 ⇒ 落在同一格、数量累加、节点数不变、merged = true", () => {
  const w = makeWorld();
  const p = heroPos(w.scene, w.heroId);
  assert.ok(addItem(w.scene, w.heroId, "berry", 5).ok);

  const r1 = dropIntoWorld(w.scene, w.heroId, "berry", 2, { x: p.x, z: p.z, plan: w.plan, tasks: w.tasks, bornTick: 1 });
  assert.ok(r1.ok, r1.ok ? "" : r1.error.message);
  assert.equal(r1.value.merged, false, "地上本来没有同类堆");
  const t1 = w.tasks.stats();

  const r2 = dropIntoWorld(w.scene, w.heroId, "berry", 3, { x: p.x, z: p.z, plan: w.plan, tasks: w.tasks, bornTick: 2 });
  assert.ok(r2.ok, r2.ok ? "" : r2.error.message);
  assert.equal(r2.value.merged, true, "半径内已有同类堆时必须叠上去，而不是在脚下新建一个碎堆");
  assert.equal(r2.value.cell, r1.value.cell, "两次丢同类落在了不同格 —— 没有合并");
  assert.equal(r2.value.nodeId, r1.value.nodeId, "换了节点 —— 那不是合并，是销毁重建");
  assert.equal(r2.value.count, 5);
  assert.equal(w.scene.countOf(RESOURCE_TYPE), 1, "第二发新建了节点");

  // ★ 叠堆的账目：三个"造节点"的计数一个都不许动，只有 stacked 动。
  //   只验 merged / count 的话，"叠堆顺手把 spawned++" 这种错完全看不见 —— 而它会让
  //   全局上限提前撞满（spawned 涨、alive 不涨的话更糟：会被当成"有个节点不见了"）。
  const t2 = w.tasks.stats();
  assert.equal(t2.spawned, t1.spawned, "叠堆不该动 spawned（没有新节点）");
  assert.equal(t2.alive, t1.alive, "叠堆不该动 alive");
  assert.equal(t2.occupied, t1.occupied, "叠堆不该动去重索引");
  assert.equal(t2.stacked, 3, `叠进去 3 个，stacked = ${String(t2.stacked)} —— 这个数不对，合并就完全不可观察了`);
});

test("★★ 不同种类不合并（同一位置丢 berry 与 tree ⇒ 两堆，两种的 kind 都对）", () => {
  const w = makeWorld();
  const p = heroPos(w.scene, w.heroId);
  assert.ok(addItem(w.scene, w.heroId, "berry", 1).ok);
  assert.ok(addItem(w.scene, w.heroId, "tree", 1).ok);

  const rb = dropIntoWorld(w.scene, w.heroId, "berry", 1, { x: p.x, z: p.z, plan: w.plan, tasks: w.tasks, bornTick: 1 });
  const rt = dropIntoWorld(w.scene, w.heroId, "tree", 1, { x: p.x, z: p.z, plan: w.plan, tasks: w.tasks, bornTick: 2 });
  assert.ok(rb.ok && rt.ok);
  assert.equal(rt.value.merged, false, "把 tree 叠进了 berry 堆 —— 那会让 berry 凭空消失");
  assert.notEqual(rt.value.cell, rb.value.cell);
  const kinds = marks(w.scene).map((m) => m.kind).sort();
  assert.deepEqual(kinds, ["berry", "tree"], "两种东西必须都在场上");
  assert.equal(w.scene.countOf(RESOURCE_TYPE), 2);
});

test("★★ 合并优先于新建：脚下空着、但半径内有同类堆 ⇒ 叠过去（不留碎堆）", () => {
  const w = makeWorld();
  const p = heroPos(w.scene, w.heroId);
  const hx = Math.floor(p.x);
  const hz = Math.floor(p.z);
  // 找一格离玩家 2 格、可通行、空闲 —— 在"外扩 2 圈"的覆盖范围里
  let far = -1;
  for (let dz = -2; dz <= 2 && far < 0; dz++) {
    for (let dx = -2; dx <= 2 && far < 0; dx++) {
      if (Math.max(Math.abs(dx), Math.abs(dz)) !== 2) continue;
      const gx = hx + dx;
      const gz = hz + dz;
      if (gx < 0 || gx >= w.plan.width || gz < 0 || gz >= w.plan.height) continue;
      const c = gz * w.plan.width + gx;
      if (!isPassable(w.plan.kinds[c]!) || w.tasks.isOccupied(c)) continue;
      far = c;
    }
  }
  assert.ok(far >= 0, "玩家 2 格内没有空地 —— 判据前提不成立");
  assert.ok(w.tasks.placeResource(far, "berry", 0, 4).ok);

  assert.ok(addItem(w.scene, w.heroId, "berry", 1).ok);
  const r = dropIntoWorld(w.scene, w.heroId, "berry", 1, { x: p.x, z: p.z, plan: w.plan, tasks: w.tasks, bornTick: 1 });
  assert.ok(r.ok, r.ok ? "" : r.error.message);
  assert.equal(r.value.merged, true, "脚下虽然空着，但已经有同类堆了 —— 不该在脚下再造一个碎堆");
  assert.equal(r.value.cell, far);
  assert.equal(r.value.count, 5);
  assert.equal(w.scene.countOf(RESOURCE_TYPE), 1, "碎堆被造出来了");
});

test("★★ findStackCell：同距离取小格、种类不匹配不算、超出覆盖范围不算（回放依赖确定性）", () => {
  const w = makeWorld();
  const a = freeCell(w, 0);
  const b = freeCell(w, 1);
  assert.ok(w.tasks.placeResource(a, "berry", 0, 1).ok);
  assert.ok(w.tasks.placeResource(b, "reed", 0, 1).ok);
  const ax = a % w.plan.width;
  const az = (a - ax) / w.plan.width;

  // 以 a 自己那一格为锚点：最近的 berry 就是 a
  assert.equal(findStackCell(w.scene, w.plan, ax + 0.5, az + 0.5, "berry", 3), a);
  // 同一位置问 reed：只能找到 b（或 null），绝不许返回 a
  const reedAt = findStackCell(w.scene, w.plan, ax + 0.5, az + 0.5, "reed", 3);
  assert.notEqual(reedAt, a, "把 reed 的落点指到了 berry 堆上");
  // 图里没有 flint ⇒ null（不是"随便给一个"）
  assert.equal(findStackCell(w.scene, w.plan, ax + 0.5, az + 0.5, "flint", 3), null);
  // 确定性：同样输入两次必须同结果
  assert.equal(
    findStackCell(w.scene, w.plan, ax + 0.5, az + 0.5, "berry", 3),
    findStackCell(w.scene, w.plan, ax + 0.5, az + 0.5, "berry", 3),
  );
  // 覆盖范围：把锚点挪到图的另一头，a 就够不着了
  assert.equal(findStackCell(w.scene, w.plan, w.plan.width - 0.5, w.plan.height - 0.5, "berry", 0), null);
});

test("★ stackResource 的拒绝：空格 / 种类不同 / 数量非法（三个码各不相同）", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  const empty = w.tasks.stackResource(cell, "berry", 1);
  assert.ok(!empty.ok && empty.error.code === TASK_NO_STACK, `空格子上叠堆没报 NO_STACK：${empty.ok ? "" : empty.error.code}`);

  assert.ok(w.tasks.placeResource(cell, "berry", 0, 1).ok);
  const wrongKind = w.tasks.stackResource(cell, "tree", 1);
  assert.ok(!wrongKind.ok && wrongKind.error.code === TASK_NO_STACK, "种类不同居然叠上了");

  const badN = w.tasks.stackResource(cell, "berry", 0);
  assert.ok(!badN.ok && badN.error.code === TASK_BAD_COUNT, `n = 0 没报 BAD_COUNT：${badN.ok ? "" : badN.error.code}`);
  // 三次失败都不许改动那一堆
  assert.equal(marks(w.scene).find((m) => m.cell === cell)?.count, 1);
});

// ── ③ 产量在出生时冻结 ───────────────────────────────────────

test("★★ 产量出生时冻结：改了 yieldOf 之后，地上已有的那批 count 不变、新刷的用新值", () => {
  let rate = 1;
  const w = makeWorld({ yieldOf: () => rate });
  for (let tick = 10; tick <= 100; tick += 10) w.tasks.update(tick, FD);
  const first = marks(w.scene);
  assert.ok(first.length >= 4, `第一批只刷出 ${String(first.length)} 个 —— 判据分辨力不足`);
  for (const m of first) assert.equal(m.count, rate, `${m.kind} 的 count 不是出生产量 ${String(rate)}`);

  // 出生过的那几个记下来，改配置后再刷一轮
  const born = new Set(first.map((m) => m.node?.id ?? -1));
  rate = 3;
  for (let tick = 110; tick <= 400; tick += 10) w.tasks.update(tick, FD);
  const all = marks(w.scene);
  assert.ok(all.length > first.length, "第二轮一个都没刷出来 —— 判据分辨力不足");
  for (const m of all) {
    const isOld = born.has(m.node?.id ?? -2);
    assert.equal(m.count, isOld ? 1 : 3, `节点 ${String(m.node?.id)} 的 count 不对（旧=${String(isOld)}）—— 产量被采的时候才查表了`);
  }
});

test("★ yieldOf 返回 0 / 负数 / NaN ⇒ 兜到 1（不许种出空堆）", () => {
  for (const bad of [0, -5, Number.NaN, 2.7]) {
    const w = makeWorld({ yieldOf: () => bad });
    for (let tick = 10; tick <= 100; tick += 10) w.tasks.update(tick, FD);
    const all = marks(w.scene);
    assert.ok(all.length > 0, `yieldOf = ${String(bad)} 时一个都没刷出来`);
    const want = bad === 2.7 ? 2 : 1;
    for (const m of all) {
      assert.equal(m.count, want, `yieldOf = ${String(bad)} 时种出了 count = ${String(m.count)} 的堆`);
    }
    // 而且它必须**采得动**（空堆采不动 = 永远拆不掉的装饰）
    const h = harvestAt(w.scene, all[0]!.cell, { onRelease: (c) => w.tasks.releaseCell(c) });
    assert.ok(h.ok, `yieldOf = ${String(bad)} 种出的堆采不动`);
  }
});

// ── ④ 存档：新字段的默认值必须来自类初始化器 ────────────────

test("★★ 旧档（没有 count 字段）读回来是 1、不是 0：否则旧档里所有资源都变成采不动的装饰", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  assert.ok(w.tasks.placeResource(cell, "berry", 5, 4).ok);
  const snap = saveScene(w.scene);

  // 把新字段从存档里**删掉**，模拟"批122 之前写出来的档"
  const older = JSON.parse(JSON.stringify(snap)) as {
    format: number;
    name: string;
    nodes: Array<{ components?: Array<{ type?: unknown; data?: Record<string, unknown> }> }>;
  };
  let stripped = 0;
  for (const n of older.nodes) {
    for (const c of n.components ?? []) {
      if (c.type !== RESOURCE_TYPE) continue;
      const data = c.data ?? {};
      assert.equal(data["count"], 4, "存档里没有 count（新字段没进 schema，或 save() 没按 schema 走？）");
      delete data["count"];
      stripped++;
    }
  }
  assert.equal(stripped, 1, "没剥到资源组件 —— 判据前提不成立");

  const registry = makeRegistry();
  const scene2 = new Scene("stack-old", registry);
  const rep = loadScene(scene2, older as unknown as ReturnType<typeof saveScene>, registry);
  assert.ok(rep.ok, rep.ok ? "" : `读旧档失败：${rep.error.code}`);
  assert.equal(
    rep.value.missingFields.length,
    1,
    `缺字段报告不对（应该只有 count 一条）：${rep.value.missingFields.join(" / ")}`,
  );
  // 形状是 `#<nodeId>.<type>.<field>` —— 用正则匹配尾段，不把节点 id 写死
  assert.match(rep.value.missingFields[0]!, /\.world\.resource\.count$/, "旧档的缺字段必须被报出来（否则没人知道格式变过）");

  const m = marks(scene2).find((x) => x.cell === cell);
  assert.ok(m !== undefined, "旧档里的资源读丢了");
  assert.equal(m!.count, 1, `旧档读回来 count = ${String(m!.count)} —— 0 就是空堆，旧档里所有资源都采不动`);
  // ★ 只验字段还不够：要验它**采得动**。count 读成 0 时 harvestAt 会返回 taken = 0
  //   而 `ok` 依然是 true（在兜底之前），于是"字段对不对"和"能不能玩"是两件事。
  const h = harvestAt(scene2, cell, {});
  assert.ok(h.ok, h.ok ? "" : h.error.code);
  assert.equal(h.value.taken, 1, "旧档里的资源采不动");
  assert.equal(h.value.left, 0);
});

test("★★ 新档往返：count 原样回来（含 7 这种不是 1/2 的值）", () => {
  const w = makeWorld();
  const cell = freeCell(w);
  assert.ok(w.tasks.placeResource(cell, "reed", 0, 7).ok);
  const snap = saveScene(w.scene);

  const registry = makeRegistry();
  const scene2 = new Scene("stack-new", registry);
  const rep = loadScene(scene2, snap, registry);
  assert.ok(rep.ok, rep.ok ? "" : `读档失败：${rep.error.code}`);
  assert.deepEqual(rep.value.missingFields, [], "新档不该缺字段");
  assert.equal(marks(scene2).find((x) => x.cell === cell)?.count, 7);
  // 字段进了 schema 就必须进字节：否则"存了但没写盘"只能靠读回来才发现
  assert.equal(peekResourceAt(scene2, cell)?.count, 7);
});

test("★ 存档里的 count 不会被去重索引当成「多一个资源」（occupied 与节点数对得上）", () => {
  const w = makeWorld();
  const a = freeCell(w, 0);
  const b = freeCell(w, 1);
  assert.ok(w.tasks.placeResource(a, "berry", 0, 9).ok);
  assert.ok(w.tasks.placeResource(b, "reed", 0, 3).ok);
  const t = w.tasks.stats();
  assert.equal(t.occupied, 2, "两格就该两个名额");
  assert.equal(t.alive, 2, "alive 按节点数算，不按物品数算（否则 12 个物品会撞满上限）");
  assert.equal(t.spawned, 2);
});
