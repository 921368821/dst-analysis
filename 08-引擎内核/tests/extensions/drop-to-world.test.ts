/**
 * L4 · 背包 → 世界（丢弃到地面的组合层）
 *
 * ★ 这一组判据盯住三种**静默**失效：
 *   ① **先出包再找格** ⇒ 放不下去时物品已经没了：背包少了、世界没多，
 *      计数全部自洽，画面上只是"东西不见了"；
 *   ② 放下的资源不进去重索引 ⇒ 下一次再生在同一格再叠一个（画面看不出来，
 *      只有 countOf 会涨），或者 `occupied !== alive` 这种一次就能算出来的对账断裂；
 *   ③ 未知种类被写进 `ResourceMarker.kind`（类型上是 SiteKind）⇒ 一个"能放下、
 *      采不动/刷不出"的僵尸资源点。
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
  TASK_BAD_CELL,
  TASK_BAD_TERRAIN,
  TASK_CAP,
  TASK_CELL_TAKEN,
  createWorldTaskModule,
  registerResourceComponent,
  type WorldTaskModuleHandle,
} from "../../src/extensions/worldgen/task-module.ts";
import { registerPlayerComponents, spawnPlayer } from "../../src/extensions/worldgen/spawn.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { addItem, countItem, makeInventory, registerInventoryComponents, stacksOf } from "../../src/extensions/inventory/inventory.ts";
import { DROP_NO_SPACE, DROP_UNKNOWN_KIND, dropIntoWorld, findFreeCells } from "../../src/extensions/inventory/drop-to-world.ts";
import { pickupNearby } from "../../src/extensions/inventory/pickup.ts";

const FD = 1 / 30;

function makeRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerPlayerComponents(reg);
  registerInventoryComponents(reg);
  // 出生节点带 Sprite（spawnPlayer 会挂）—— 不注册的话"玩家没有身体"
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

/** 一条链：生成 → 装配 → 任务模块（不跑 update：这一组判据要自己控制什么时候刷）。 */
function makeWorld(maxResources?: number): { scene: Scene; plan: WorldPlan; tasks: WorldTaskModuleHandle; heroId: number } {
  const scene = new Scene("drop", makeRegistry());
  const g = generateWorld({ seed: 7, width: 32, height: 24, maxSitesPerCell: 0 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  assert.ok(assembleWorld(g.value, scene).ok);

  const tasks = createWorldTaskModule({
    tasks: { schema: WORLD_TASK_SCHEMA, tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun: 3, biomes: ["grass", "forest"] }] },
    plan: g.value,
    scene,
    ...(maxResources === undefined ? {} : { maxResources }),
  });
  const init = tasks.init(makeCtx());
  assert.ok(init === undefined || (init as { ok?: boolean }).ok === true, "任务模块 init 失败");
  tasks.start?.();

  const spawn = spawnPlayer(scene, g.value);
  assert.ok(spawn.ok, spawn.ok ? "" : `出生失败：${spawn.error.message}`);
  const bag = makeInventory(scene, spawn.value.nodeId, 8, 40);
  assert.ok(bag.ok, bag.ok ? "" : `背包建不起来：${bag.error.code}`);
  return { scene, plan: g.value, tasks, heroId: spawn.value.nodeId };
}

function heroPos(scene: Scene, heroId: number): { x: number; z: number } {
  const n = scene.find(heroId);
  assert.ok(n !== undefined, "玩家不在场景里");
  return { x: n!.worldPosition.x, z: n!.worldPosition.y };
}

/** 找一格不可通行地形（BAD_TERRAIN 判据要用）。 */
function findImpassableCell(plan: WorldPlan): number {
  for (let c = 0; c < plan.kinds.length; c++) {
    if (!isPassable(plan.kinds[c]!)) return c;
  }
  throw new Error("这张图没有不可通行格，判据前提不成立");
}

// ── ① 闭环 ─────────────────────────────────────────────────────

test("★★ 闭环：丢 1 个到脚下 ⇒ 世界多一堆 + 背包少一个 + 名额被占（三块状态一起变）", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId);
  assert.ok(addItem(scene, heroId, "berry", 3).ok);
  const resBefore = scene.countOf(RESOURCE_TYPE);
  const t0 = tasks.stats();

  const r = dropIntoWorld(scene, heroId, "berry", 1, { x: p.x, z: p.z, plan, tasks, bornTick: 42 });
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(r.value.dropped, 1);
  assert.equal(r.value.merged, false, "地上本来没有同类堆 —— 这一发必须是新建（叠堆的账目完全不同）");
  assert.equal(r.value.count, 1);

  // 世界侧：真的多了一个节点，且标记的字段全对（种类 / 格子 / 出生 tick / 存量）
  assert.equal(scene.countOf(RESOURCE_TYPE), resBefore + 1, "世界侧没有多出资源");
  const marks = [...scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)];
  const mine = marks.find((m) => m.cell === r.value.cell);
  assert.ok(mine !== undefined, "丢下去的格子找不到资源标记");
  assert.equal(mine!.kind, "berry");
  assert.equal(mine!.bornTick, 42, "出生 tick 必须由调用方给（回放时不能变成当前时钟）");
  assert.equal(mine!.count, 1, "丢 1 个应该长出一堆 1 个");
  // 背包侧
  assert.equal(countItem(scene, heroId, "berry"), 2);
  // 账目侧：去重索引与 alive 一起动（少改任何一样的症状是"再生会在同一格再叠一个"）
  const t1 = tasks.stats();
  assert.equal(t1.alive, t0.alive + 1);
  assert.equal(t1.spawned, t0.spawned + 1);
  assert.equal(t1.occupied, t0.occupied + 1);
  assert.equal(t1.stacked, t0.stacked, "新建一堆不该记进 stacked（那是残留的合并计数）");
  assert.ok(tasks.isOccupied(r.value.cell), "丢下去的格子没占住 —— 再生会往同一格再叠一个");
});

test("★★ 丢 2 个 = 一堆 2 个（只占 1 格）：批122 起地面堆叠，不再散成 2 张图", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId);
  assert.ok(addItem(scene, heroId, "rock", 2).ok);
  const resBefore = scene.countOf(RESOURCE_TYPE);
  const t0 = tasks.stats();
  const r = dropIntoWorld(scene, heroId, "rock", 2, { x: p.x, z: p.z, plan, tasks, bornTick: 7 });
  assert.ok(r.ok, r.ok ? "" : r.error.message);
  assert.equal(r.value.count, 2, "丢 2 个必须是一堆 2 个");
  assert.equal(scene.countOf(RESOURCE_TYPE), resBefore + 1, "丢 2 个只该新增 1 个节点（多了就是没合并）");
  const mine = [...scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)].find((m) => m.cell === r.value.cell);
  assert.equal(mine?.count, 2, "堆里的数量与报告不符");
  assert.equal(countItem(scene, heroId, "rock"), 0);
  assert.equal(stacksOf(scene, heroId).length, 0, "整堆丢完应该一个不剩（含空壳销毁）");
  // ★ 只验"背包少了 2 个"抓不到这类错：新建一堆却报 merged=true 时，三块状态**全都自洽**，
  //   只有账目能分辨（叠堆不动 spawned/alive/occupied，只动 stacked）。
  const t1 = tasks.stats();
  assert.equal(t1.spawned, t0.spawned + 1);
  assert.equal(t1.alive, t0.alive + 1);
  assert.equal(t1.occupied, t0.occupied + 1);
  assert.equal(t1.stacked, t0.stacked, "新建一堆不该记进 stacked");
});

test("★★ 丢下去的还能再捡回来（背包 → 世界 → 背包，整圈闭合且数量一个不少）", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId);
  assert.ok(addItem(scene, heroId, "rock", 2).ok);
  const r = dropIntoWorld(scene, heroId, "rock", 2, { x: p.x, z: p.z, plan, tasks, bornTick: 7 });
  assert.ok(r.ok, r.ok ? "" : r.error.message);

  // 半径拾取把它们捡回来（走的是世界那一侧的真实入口，不是直接调 addItem）
  const pick = pickupNearby(scene, p.x, p.z, 1.5, heroId, { onRelease: (c) => tasks.releaseCell(c) });
  assert.ok(pick.ok, pick.ok ? "" : pick.error.message);
  // ★ 一堆就是一堆：捡的次数是 1，拿回来的量是 2。写成 2 次的话，
  //   "堆叠没生效、又退回到散开" 这种回退照样会绿。
  assert.equal(pick.value.picked.length, 1, "一堆 2 个应该一次捡完（不该拆成两次）");
  assert.equal(countItem(scene, heroId, "rock"), 2, "捡回来的数量不对 —— 丢 2 个必须能捡回 2 个");
  assert.equal(scene.countOf(RESOURCE_TYPE), 0, "捡光了节点还在 —— 见底了没销毁");
  assert.equal(tasks.stats().occupied, 0, "捡光了名额没还 —— 那一格永远刷不出新东西");
});

test("★★ 整堆丢（45 个）：只占 1 格、堆里 45 个、名额只动 1（不是外扩找 45 格）", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId);
  assert.ok(addItem(scene, heroId, "reed", 45).ok);
  const resBefore = scene.countOf(RESOURCE_TYPE);
  const r = dropIntoWorld(scene, heroId, "reed", 45, { x: p.x, z: p.z, plan, tasks, bornTick: 7 });
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(r.value.count, 45);
  assert.equal(scene.countOf(RESOURCE_TYPE), resBefore + 1, "45 个占了不止 1 个节点");
  assert.equal(tasks.stats().occupied, 1, "45 个只该占住 1 格名额");
  assert.equal(countItem(scene, heroId, "reed"), 0);
  // 捡回来也是 45 个（不是 1 个 —— 那才是"批量丢东西"最怕的静默丢失）
  const pick = pickupNearby(scene, p.x, p.z, 1.5, heroId, { onRelease: (c) => tasks.releaseCell(c) });
  assert.ok(pick.ok, pick.ok ? "" : pick.error.message);
  assert.equal(countItem(scene, heroId, "reed"), 45, "丢 45 个却捡不回 45 个 —— 剩下的凭空消失了");
});

// ── ② 顺序契约（失败时两边都不动）─────────────────────────────

test("★★ 包里不够 ⇒ 在任何修改之前失败：世界没多、背包没少", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId);
  assert.ok(addItem(scene, heroId, "berry", 2).ok);
  const resBefore = scene.countOf(RESOURCE_TYPE);
  const t0 = tasks.stats();

  const r = dropIntoWorld(scene, heroId, "berry", 5, { x: p.x, z: p.z, plan, tasks, bornTick: 1 });
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, "INVENTORY.NOT_ENOUGH");
  assert.equal(scene.countOf(RESOURCE_TYPE), resBefore, "报「不够」却还是往世界里放了东西");
  assert.equal(countItem(scene, heroId, "berry"), 2, "报「不够」却还是扣了背包");
  assert.equal(tasks.stats().occupied, t0.occupied, "名额被占了又没放资源");
});

test("★★ 没有空地 ⇒ DROP.NO_SPACE，物品还在包里（先找格再出包的证据）", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId);
  assert.ok(addItem(scene, heroId, "berry", 1).ok);
  // 把玩家周围（含自动外扩的 2 圈）所有可通行格全占掉 ⇒ 一定找不到格
  const cx = Math.floor(p.x);
  const cz = Math.floor(p.z);
  let filled = 0;
  for (let dz = -5; dz <= 5; dz++) {
    for (let dx = -5; dx <= 5; dx++) {
      const gx = cx + dx;
      const gz = cz + dz;
      if (gx < 0 || gx >= plan.width || gz < 0 || gz >= plan.height) continue;
      const cell = gz * plan.width + gx;
      if (!isPassable(plan.kinds[cell]!) || tasks.isOccupied(cell)) continue;
      assert.ok(tasks.placeResource(cell, "tree", 0).ok, "前置占格失败");
      filled++;
    }
  }
  assert.ok(filled > 0, "周围一格可通行格都没有 —— 判据前提不成立");

  const r = dropIntoWorld(scene, heroId, "berry", 1, { x: p.x, z: p.z, plan, tasks, bornTick: 1 });
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, DROP_NO_SPACE);
  assert.equal(countItem(scene, heroId, "berry"), 1, "没空地却把东西丢了 —— 顺序反了（先出包再找格）");
});

test("★★ 撞全局上限 ⇒ 世界没多、背包没少（放置的失败不被吞成「丢成功」）", () => {
  const { scene, plan, tasks, heroId } = makeWorld(1); // maxResources = 1
  const p = heroPos(scene, heroId);
  // 先把唯一的名额用掉 —— ★ 必须放**不同种类**：放 berry 的话，接下来丢 berry
  // 会走"合并"那条路（不耗名额），于是这条判据根本碰不到上限。
  const free = findFreeCells(plan, tasks, p.x, p.z, 1, 3);
  assert.ok(free !== null, "玩家周围没有空地，判据前提不成立");
  assert.ok(tasks.placeResource(free![0]!, "tree", 0).ok, "前置占格失败");
  assert.ok(addItem(scene, heroId, "berry", 5).ok);

  const r = dropIntoWorld(scene, heroId, "berry", 5, { x: p.x, z: p.z, plan, tasks, bornTick: 1 });
  assert.ok(!r.ok, "名额已经用完了，居然还放下来了");
  if (!r.ok) assert.equal(r.error.code, TASK_CAP);
  assert.equal(countItem(scene, heroId, "berry"), 5, "放置失败却扣了背包（顺序反了：先出包再放下）");
  assert.equal(scene.countOf(RESOURCE_TYPE), 1, "放置失败却往世界里加了东西");
  assert.equal(tasks.stats().alive, 1, "放置失败却改了 alive");
});

test("★★ 世界不认识的种类 ⇒ DROP.UNKNOWN_KIND（不许把非法值写进 SiteKind 字段）", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId);
  // 跨版本存档可能带进来这个世界没有的种类
  assert.ok(addItem(scene, heroId, "diamond", 1).ok);
  const resBefore = scene.countOf(RESOURCE_TYPE);
  const r = dropIntoWorld(scene, heroId, "diamond", 1, { x: p.x, z: p.z, plan, tasks, bornTick: 1 });
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, DROP_UNKNOWN_KIND);
  assert.equal(scene.countOf(RESOURCE_TYPE), resBefore, "未知种类也放下去了");
  assert.equal(countItem(scene, heroId, "diamond"), 1, "未知种类被扣走了");
});

// ── ③ placeResource 的世界侧契约 ──────────────────────────────

test("★ 放置的四类拒绝：越界 / 不可通行 / 已占用 / 全局上限（码各不相同）", () => {
  const { scene, plan, tasks } = makeWorld(1); // maxResources = 1：第二个就一定撞上限
  const bad = tasks.placeResource(-1, "tree", 0);
  assert.ok(!bad.ok && bad.error.code === TASK_BAD_CELL, `越界没报 BAD_CELL：${bad.ok ? "" : bad.error.code}`);
  const big = tasks.placeResource(plan.width * plan.height, "tree", 0);
  assert.ok(!big.ok && big.error.code === TASK_BAD_CELL, "等于 size 也算越界");

  const water = findImpassableCell(plan);
  const terrain = tasks.placeResource(water, "tree", 0);
  assert.ok(!terrain.ok && terrain.error.code === TASK_BAD_TERRAIN, `不可通行格没报 BAD_TERRAIN：${terrain.ok ? "" : terrain.error.code}`);

  // 找一格可通行且空闲的
  let free = -1;
  for (let c = 0; c < plan.kinds.length; c++) {
    if (isPassable(plan.kinds[c]!) && !tasks.isOccupied(c)) {
      free = c;
      break;
    }
  }
  assert.ok(free >= 0, "这张图没有可通行空格，判据前提不成立");
  const ok1 = tasks.placeResource(free, "tree", 5);
  assert.ok(ok1.ok, ok1.ok ? "" : `第一发失败：${ok1.error.code}`);
  const taken = tasks.placeResource(free, "tree", 5);
  assert.ok(!taken.ok && taken.error.code === TASK_CELL_TAKEN, `重复放置没报 CELL_TAKEN：${taken.ok ? "" : taken.error.code}`);
  const cap = tasks.placeResource(free + 1, "tree", 5);
  assert.ok(!cap.ok && cap.error.code === TASK_CAP, `上限没报 CAP：${cap.ok ? "" : cap.error.code}`);
  // 资源放在格子中心（与再生同一条坐标路径）
  const node = scene.find(ok1.value);
  assert.ok(node !== undefined, "放置成功的节点不在场景里");
  const wp = node!.worldPosition;
  assert.ok(Math.abs(wp.x - (free % plan.width) - 0.5) < 1e-9, "x 不在格子中心");
  assert.ok(Math.abs(wp.y - Math.floor(free / plan.width) - 0.5) < 1e-9, "z 不在格子中心");
});

test("★★ 丢下去的资源参与去重：之后再生不会在那一格再叠一个", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId);
  assert.ok(addItem(scene, heroId, "berry", 1).ok);
  const r = dropIntoWorld(scene, heroId, "berry", 1, { x: p.x, z: p.z, plan, tasks, bornTick: 3 });
  assert.ok(r.ok, r.ok ? "" : r.error.message);
  const cell = r.value.cell;
  const before = scene.countOf(RESOURCE_TYPE);

  // 让任务表跑几个周期（它自己会挑格子；如果去重漏了我们的格子，这里会 +1）
  for (let tick = 10; tick <= 200; tick += 10) tasks.update(tick, FD);
  const after = scene.countOf(RESOURCE_TYPE);
  assert.ok(after > before, "再生一次都没刷出来 —— 判据分辨力不足（换个 seed 或调 picksPerRun）");
  const marks = [...scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)];
  const onCell = marks.filter((m) => m.cell === cell);
  assert.equal(onCell.length, 1, `格子 ${cell} 上有 ${onCell.length} 个资源 —— 丢下去的那个没进去重索引`);
});

// ── ④ 选格：由近到远且确定 ────────────────────────────────────

test("★★ findFreeCells：由近到远、同格优先、跳过占用与不可通行", () => {
  const { scene, plan, tasks, heroId } = makeWorld();
  const p = heroPos(scene, heroId); // 出生格必然可通行且空闲
  const cx = Math.floor(p.x);
  const cz = Math.floor(p.z);
  const heroCell = cz * plan.width + cx;

  const got = findFreeCells(plan, tasks, p.x, p.z, 1, 3);
  assert.ok(got !== null, "玩家周围 3 格内没有空地（这张图不该这么挤）");
  assert.equal(got![0], heroCell, "第一优先必须是玩家自己那一格");

  // 占掉它 ⇒ 落到相邻格（仍在 3 格内）
  assert.ok(tasks.placeResource(heroCell, "tree", 0).ok);
  const got2 = findFreeCells(plan, tasks, p.x, p.z, 1, 3);
  assert.ok(got2 !== null);
  assert.notEqual(got2![0], heroCell, "占掉了还返回同一格");
  const gx = got2![0]! % plan.width;
  const gz = (got2![0]! - gx) / plan.width;
  assert.ok(Math.abs(gx - cx) <= 3 && Math.abs(gz - cz) <= 3, "候选格不在 3 格范围内");
  assert.ok(isPassable(plan.kinds[got2![0]!]!), "候选格不可通行 —— 选格漏查了地形");

  // ★ 单点断言会碰运气（那一圈第一个候选恰好是陆地时，抽掉检查也不变行为）。
  //   全图扫描：以每个可通行格为锚点，返回的每一个格子都必须可通行 ——
  //   挨着水的锚点下，漏查地形必然返回水格。
  let swept = 0;
  for (let c = 0; c < plan.kinds.length; c++) {
    if (!isPassable(plan.kinds[c]!)) continue;
    const ax = (c % plan.width) + 0.5;
    const az = Math.floor(c / plan.width) + 0.5;
    const got = findFreeCells(plan, tasks, ax, az, 3, 3);
    if (got === null) continue;
    for (const cell of got) {
      assert.ok(isPassable(plan.kinds[cell]!), `锚点 ${c} 选到了不可通行格 ${cell} —— 选格漏查地形`);
      swept++;
    }
  }
  assert.ok(swept > 50, `扫描面不足（只验了 ${swept} 格）—— 换个 seed 或加 picks`);

  // 确定性：同样的输入永远给出同样的格（回放依赖这条）
  assert.deepEqual(findFreeCells(plan, tasks, p.x, p.z, 1, 3), got2, "同一输入两次结果不同 —— 顺序性断了");
});
