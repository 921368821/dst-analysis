/**
 * L4 · AI 移动：目标格 → 路径 → 真实位移
 *
 * ★ 这份判据里三条最容易写成"看起来绿"的：
 *   ① **到达后不再算路** —— 只断言"他到了"是看不出每 tick 都在跑 A* 的，必须数 `paths`；
 *   ② **不可达要退避** —— 只断言"他没动"同样看不出每 tick 都在失败算路；
 *   ③ **别在走的过程中踩进水里** —— 只断言终点对不够，要逐 tick 抽位置。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { MOVER_TYPE, Mover, createMoveModule, registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { SpatialHashWorld } from "../../src/extensions/physics/physics.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";

function makeCtx(scene: Scene | null): ModuleContext {
  const services = new ServiceRegistry();
  if (scene !== null) services.provide(Services.Scene, scene, "test");
  return {
    log: { channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }) } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  } as unknown as ModuleContext;
}

/**
 * `init` 的静态类型是 `ModuleHookResult`（模块允许异步初始化）。
 * 这两个模块都是同步的，判据里显式取 `ok` —— 顺手也是一种断言：
 * 谁把它改成异步，这里会先红（异步起会让"跑了几 tick"取决于微任务时序）。
 */
function initOk(mod: { init(ctx: ModuleContext): unknown }, ctx: ModuleContext): void {
  const r = mod.init(ctx) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true, "模块初始化必须同步成功");
}

/** 造一个只有一条横向走廊的场景，代理放在第 0 格中心。 */
function corridor(width: number) {
  const reg = new ComponentRegistry();
  registerMoverComponent(reg);
  const scene = new Scene("move", reg);
  const grid = new NavGrid(width, 1, new Uint8Array(width).fill(1));
  const node = scene.spawnAt("agent", 0.5, 0.5);
  assert.equal(node.ok, true);
  if (!node.ok) throw new Error("unreachable");
  const made = scene.attach(node.value.id, () => new Mover());
  assert.equal(made.ok, true);
  scene.flush();
  return { scene, grid, nodeId: node.value.id, mover: made.value as Mover };
}

test("[AI 移动] 走到目标格并停在格中心", () => {
  const { scene, grid, nodeId, mover } = corridor(8);
  mover.speed = 2;
  const mod = createMoveModule({ grid, decide: () => 5 });
  initOk(mod, makeCtx(scene));

  for (let t = 1; t <= 40; t++) mod.update(t, 0.1);
  const node = scene.find(nodeId);
  assert.ok(node !== null);
  const p = node!.worldPosition;
  assert.ok(Math.abs(p.x - 5.5) < 1e-9, `应停在 5 号格中心 x=5.5，实际 ${String(p.x)}`);
  assert.ok(Math.abs(p.y - 0.5) < 1e-9);
  assert.equal(mover.goalCell, 5);
  assert.equal(mover.arrived, true);
  assert.equal([...scene.componentsOf(MOVER_TYPE)].length, 1, "代理必须挂在 ai.mover 之下（注册名与查询名同源）");
});

test("[AI 移动] ★ 到达之后不再算路（不是每 tick 都跑 A*）", () => {
  const { scene, grid, mover } = corridor(8);
  mover.speed = 5;
  const mod = createMoveModule({ grid, decide: () => 4 });
  initOk(mod, makeCtx(scene));

  for (let t = 1; t <= 20; t++) mod.update(t, 0.1);
  const afterArrive = mod.stats.paths;
  assert.equal(afterArrive, 1, `走到 4 号格应该只算一次路，实际 ${String(afterArrive)} 次`);

  // 目标没变，再跑 50 tick：一次路都不该再算
  for (let t = 21; t <= 70; t++) mod.update(t, 0.1);
  assert.equal(mod.stats.paths, afterArrive, "站在目标上还在反复算路 —— CPU 在无事可做时最忙");
  assert.ok(mod.stats.idle > 0);
});

test("[AI 移动] 目标不可达：退避窗口内只失败一次，窗口过了会重试", () => {
  // 一整列不可走，目标在对岸
  const mask = new Uint8Array(9).fill(1);
  mask[4] = 0;
  const grid = new NavGrid(9, 1, mask);
  const reg = new ComponentRegistry();
  registerMoverComponent(reg);
  const scene = new Scene("blocked", reg);
  const node = scene.spawnAt("agent", 0.5, 0.5);
  assert.equal(node.ok, true);
  scene.attach(node.value.id, () => new Mover());
  scene.flush();

  const mod = createMoveModule({ grid, decide: () => 8, retryTicks: 30 });
  initOk(mod, makeCtx(scene));

  for (let t = 1; t <= 10; t++) mod.update(t, 0.1);
  assert.equal(mod.stats.unreachable, 1, "退避窗口内不许每 tick 都重算（20 只怪就是 20 倍开销）");

  for (let t = 11; t <= 40; t++) mod.update(t, 0.1);
  assert.equal(mod.stats.unreachable, 2, "窗口过了要重试一次（目标可能已经能过去了）");
});

test("[AI 移动] decide 返回 null：原地待命，不产生路径", () => {
  const { scene, grid, nodeId, mover } = corridor(6);
  const mod = createMoveModule({ grid, decide: () => null });
  initOk(mod, makeCtx(scene));
  for (let t = 1; t <= 10; t++) mod.update(t, 0.1);

  const p = scene.find(nodeId)!.worldPosition;
  assert.equal(p.x, 0.5);
  assert.equal(mod.stats.paths, 0);
  assert.equal(mover.path.length, 0);
  assert.equal(mod.stats.idle, 1, "idle 是这一 tick 的空转数（只有一个代理）");
});

test("[AI 移动] 卡住要有出口：连续没挪动就丢路径重算", () => {
  const { scene, grid, mover } = corridor(8);
  // 速度小到每 tick 挪动远小于 stuckEps（模拟被物理挤住）
  mover.speed = 1e-9;
  const mod = createMoveModule({ grid, decide: () => 6, stuckTicks: 3 });
  initOk(mod, makeCtx(scene));

  mod.update(1, 0.1);
  mod.update(2, 0.1);
  assert.equal(mover.stuckTicks, 2, "连续两次没挪动应累计起来");

  // 第三次到阈值：当场丢路径、计数归零、记一次"卡住"
  mod.update(3, 0.1);
  assert.equal(mod.stats.stuck, 1, "到了阈值就要丢路径");
  assert.equal(mover.path.length, 0);
  assert.equal(mover.stuckTicks, 0);

  // 丢了以后下一 tick 会重算：不是"卡死以后再也不动"
  mod.update(4, 0.1);
  assert.equal(mod.stats.paths, 2);
});

test("[AI 移动] 目标中途变化：重算一次并走到新目标", () => {
  const { scene, grid, nodeId } = corridor(10);
  const mod = createMoveModule({ grid, decide: (_id, tick) => (tick <= 5 ? 9 : 2) });
  initOk(mod, makeCtx(scene));

  for (let t = 1; t <= 5; t++) mod.update(t, 0.1);
  const first = mod.stats.paths;
  for (let t = 6; t <= 60; t++) mod.update(t, 0.1);

  assert.ok(mod.stats.paths >= first + 1, "目标变了必须重算");
  const p = scene.find(nodeId)!.worldPosition;
  assert.ok(Math.abs(p.x - 2.5) < 1e-9, `最终应停在 2 号格，实际 ${String(p.x)}`);
});

test("[AI 移动] pathOf 返回副本", () => {
  const { scene, grid, nodeId } = corridor(6);
  const mod = createMoveModule({ grid, decide: () => 5 });
  initOk(mod, makeCtx(scene));
  mod.update(1, 0.1);
  const p = mod.pathOf(nodeId);
  assert.ok(p.length > 0);
  (p as number[])[0] = 999;
  assert.notEqual(mod.pathOf(nodeId)[0], 999);
});

test("[AI 移动] 确定性：两次独立运行，位置与统计完全相同", () => {
  const run = () => {
    const { scene, grid, nodeId } = corridor(12);
    const mod = createMoveModule({ grid, decide: () => 11 });
    initOk(mod, makeCtx(scene));
    for (let t = 1; t <= 25; t++) mod.update(t, 0.1);
    const p = scene.find(nodeId)!.worldPosition;
    return { x: p.x, y: p.y, paths: mod.stats.paths };
  };
  assert.deepEqual(run(), run());
});

test("[AI 移动] ★ 接线：在真实生成的世界里走，全程不踩水、能走到对岸", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerMoverComponent(reg);
  const scene = new Scene("nav-world", reg);
  const g = generateWorld({ seed: 31415, width: 28, height: 20, maxSitesPerCell: 1 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");
  assert.equal(assembleWorld(g.value, scene).ok, true);

  const gridR = NavGrid.fromPlan(g.value);
  assert.equal(gridR.ok, true, gridR.ok ? "" : gridR.error.code);
  if (!gridR.ok) throw new Error("unreachable");
  const grid = gridR.value;

  // 起点：第一块可走的陆地（按下标升序，确定）
  let start = -1;
  for (let i = 0; i < grid.total; i++) {
    if (grid.isWalkableIndex(i)) {
      start = i;
      break;
    }
  }
  assert.ok(start >= 0, "生成的世界里应该至少有可走的地");
  const comp = grid.componentOf(start);

  // 终点：同一连通分量里曼哈顿距离最远的格（平手取下标小的 ⇒ 确定）
  let goal = start;
  let bestD = -1;
  for (let i = 0; i < grid.total; i++) {
    if (grid.componentOf(i) !== comp) continue;
    const d = Math.abs(grid.cellX(i) - grid.cellX(start)) + Math.abs(grid.cellZ(i) - grid.cellZ(start));
    if (d > bestD) {
      bestD = d;
      goal = i;
    }
  }
  assert.ok(bestD >= 10, `终点太近（曼哈顿 ${String(bestD)}），这条接线判据没意义`);

  const spawn = grid.centerOf(start);
  const node = scene.spawnAt("agent", spawn.x, spawn.z);
  assert.equal(node.ok, true);
  if (!node.ok) throw new Error("unreachable");
  const mover = new Mover();
  mover.speed = 2;
  scene.attach(node.value.id, () => mover);
  scene.flush();

  const mod = createMoveModule({ grid, decide: () => goal });
  initOk(mod, makeCtx(scene));

  let arrived = false;
  let water = 0;
  for (let t = 1; t <= 4000; t++) {
    mod.update(t, 1 / 30);
    const p = scene.find(node.value.id)!.worldPosition;
    const cell = grid.cellAt(p.x, p.y);
    if (cell < 0 || !grid.isWalkableIndex(cell)) water++;
    if (mover.arrived) {
      arrived = true;
      break;
    }
  }
  assert.equal(arrived, true, `走了 4000 tick 还没到（路径 ${String(mod.stats.paths)} 次算路）`);
  assert.equal(water, 0, `有 ${String(water)} 个 tick 站到了不可走的格子上 —— 路径合法性破了`);
  assert.equal(mod.stats.unreachable, 0);
  const p = scene.find(node.value.id)!.worldPosition;
  const end = grid.centerOf(goal);
  assert.ok(Math.abs(p.x - end.x) < 1e-9 && Math.abs(p.y - end.z) < 1e-9, "终点格中心没对上");
});

// ── ⑥ 连续碰撞接线（ADR-0013）────────────────────────────────

/**
 * ★★ 这一条守的是**接线**，不是纯函数 —— `sweepMove` 自己那套判据
 * （`physics-sweep.test.ts`）全绿也说明不了"AI 走路的时候喊了它"。
 *
 * 夹具特意让「一 tick 的位移 (0.5) > 墙厚 (0.1)」：这时起终点都不重叠，
 * `resolve()` 永远推不回来 —— 那正是「这只怪偶尔穿过箱子」。
 * 判据先跑一遍**不注入** sweep 的对照，证明这个夹具真的会穿过去
 * （不然"夹住了"可能只是因为走得慢）。
 */
test("★★ 连续碰撞接线：一 tick 跨得比薄墙厚 ⇒ 夹在墙前；不注入 sweep 就会穿过去", () => {
  const WALL_X = 4;
  const WALL_HALF = 0.05;
  const BODY_R = 0.5;
  /** 圆心能到达的最远处 = 墙面 − 半径（墙面在 4 − 0.05）。 */
  const CONTACT = WALL_X - WALL_HALF - BODY_R;

  function run(injectSweep: boolean): { maxX: number; blocked: number; arrived: boolean } {
    const w = corridor(16);
    w.mover.speed = 30; // dt = 1/60 ⇒ 每拍 0.5 世界单位
    const pos = new Map<number, { x: number; z: number }>([
      [w.nodeId, { x: 0.5, z: 0.5 }],
      [999, { x: WALL_X, z: 0.5 }],
    ]);
    const world = new SpatialHashWorld({
      get: (id) => pos.get(id),
      set: (id, x, z) => {
        pos.set(id, { x, z });
      },
    });
    // ★ 必须真的 add 进世界：候选集来自空间哈希，只在访问器里塞坐标的话世界是空的。
    world.add({ nodeId: w.nodeId, radius: BODY_R, isStatic: false });
    world.add({ nodeId: 999, radius: BODY_R, isStatic: true, halfExtents: { x: WALL_HALF, z: 5 } });

    const mod = createMoveModule({
      grid: w.grid,
      decide: () => 15,
      ...(injectSweep ? { sweep: (id: number, dx: number, dz: number) => world.sweepMove(id, dx, dz) } : {}),
    });
    initOk(mod, makeCtx(w.scene));

    let maxX = 0.5;
    for (let t = 1; t <= 200; t++) {
      // 物理世界的位置访问器要跟场景同步（引擎里这一步由"写回 body 位置"的系统做）
      const p = w.scene.find(w.nodeId)!.worldPosition;
      pos.set(w.nodeId, { x: p.x, z: p.y });
      mod.update(t, 1 / 60);
      maxX = Math.max(maxX, w.scene.find(w.nodeId)!.worldPosition.x);
      if (w.mover.arrived) break;
    }
    return { maxX, blocked: mod.stats.blocked, arrived: w.mover.arrived };
  }

  const without = run(false);
  assert.ok(
    without.maxX > WALL_X + BODY_R,
    `夹具没有分辨力：不扫掠时必须穿过墙（最远 x=${String(without.maxX)} > ${String(WALL_X + BODY_R)}）`,
  );

  const withSweep = run(true);
  assert.ok(
    withSweep.maxX <= CONTACT + 1e-9,
    `圆心不该越过 ${String(CONTACT)}，实际最远 ${String(withSweep.maxX)}`,
  );
  assert.ok(withSweep.blocked > 0, "扫掠一次都没被调用 —— 接线没接上（纯函数再绿也不作数）");
  assert.equal(withSweep.arrived, false, "被挡住时不许宣布到达（`r.done` 说的只是预算走完了这条路）");
});

test("★ 连续碰撞接线：被挡住时不推进游标（否则会贴着墙把剩下的路空走完）", () => {
  const w = corridor(16);
  w.mover.speed = 30;
  const pos = new Map<number, { x: number; z: number }>([
    [w.nodeId, { x: 0.5, z: 0.5 }],
    [999, { x: 4, z: 0.5 }],
  ]);
  const world = new SpatialHashWorld({
    get: (id) => pos.get(id),
    set: (id, x, z) => {
      pos.set(id, { x, z });
    },
  });
  world.add({ nodeId: w.nodeId, radius: 0.5, isStatic: false });
  world.add({ nodeId: 999, radius: 0.5, isStatic: true, halfExtents: { x: 0.05, z: 5 } });

  const mod = createMoveModule({
    grid: w.grid,
    decide: () => 15,
    sweep: (id: number, dx: number, dz: number) => world.sweepMove(id, dx, dz),
  });
  initOk(mod, makeCtx(w.scene));

  const cursorAt: number[] = [];
  for (let t = 1; t <= 40; t++) {
    const p = w.scene.find(w.nodeId)!.worldPosition;
    pos.set(w.nodeId, { x: p.x, z: p.y });
    mod.update(t, 1 / 60);
    cursorAt.push(w.mover.cursor);
  }
  // 撞上之后游标不再增长：40 拍里它有很长一段时间停在同一个值上。
  assert.ok(
    new Set(cursorAt).size < cursorAt.length,
    `游标每拍都在前进（${cursorAt.join(",")}）—— 那是"贴着墙空走到终点"`,
  );
  // 而且它**没有**走到路径末端（末端 = path.length）
  assert.ok(w.mover.cursor < w.mover.path.length, `游标走到了末端 ${String(w.mover.cursor)}/${String(w.mover.path.length)}`);
  // 卡住检测要接得住：被挡住的代理最终会丢路径重算一次（不是永远僵在那里）
  assert.ok(mod.stats.blocked > 0);
});

/**
 * ★★ 这一条是给 M521/M522 准备的：**预算大到一拍走完整条路**。
 *
 * 只有这种局面里 `r.done` 才会在"被挡住的那一拍"为 true，于是两个错法各有症状：
 *   · 被挡住还推进游标 ⇒ 下一拍 `r.done` 为真而位移是 0，游标已到末端 ⇒ 宣布到达；
 *   · 被挡住也宣布到达 ⇒ 第一拍就到达，而人其实贴在墙上。
 * 慢速夹具（上两条）里这两件事都碰不到 —— 预算一拍走不完，`r.done` 一直是 false。
 */
test("★★ 被物理挡住时不许宣布到达：预算大到一拍走完整条路也一样", () => {
  const w = corridor(8);
  w.mover.speed = 30; // dt = 0.5 ⇒ 一拍 15 世界单位，整条路都在一拍之内
  const WALL_X = 4.5; // 正好压在目标格中心上：圆心最近只能到 3.95
  const pos = new Map<number, { x: number; z: number }>([
    [w.nodeId, { x: 0.5, z: 0.5 }],
    [999, { x: WALL_X, z: 0.5 }],
  ]);
  const world = new SpatialHashWorld({
    get: (id) => pos.get(id),
    set: (id, x, z) => {
      pos.set(id, { x, z });
    },
  });
  world.add({ nodeId: w.nodeId, radius: 0.5, isStatic: false });
  world.add({ nodeId: 999, radius: 0.5, isStatic: true, halfExtents: { x: 0.05, z: 5 } });

  const mod = createMoveModule({
    grid: w.grid,
    decide: () => 4,
    sweep: (id: number, dx: number, dz: number) => world.sweepMove(id, dx, dz),
  });
  initOk(mod, makeCtx(w.scene));

  for (let t = 1; t <= 60; t++) {
    const p = w.scene.find(w.nodeId)!.worldPosition;
    pos.set(w.nodeId, { x: p.x, z: p.y });
    mod.update(t, 0.5);
    assert.equal(w.mover.arrived, false, `第 ${String(t)} 拍宣布到达了，而它贴在墙上`);
  }
  const p = w.scene.find(w.nodeId)!.worldPosition;
  assert.ok(p.x <= WALL_X - 0.05 - 0.5 + 1e-9, `圆心越过了接触点：x=${String(p.x)}`);
  assert.ok(mod.stats.blocked > 0, "一次都没被挡住 —— 夹具没咬住扫掠");
});
