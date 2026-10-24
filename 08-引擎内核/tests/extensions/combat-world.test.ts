/**
 * L4 · 战斗接线：在**真实生成的世界**里追上并打死一个目标
 *
 * ★ 为什么必须有一条接线判据：血量与攻击各自的判据都是手搭的两三个节点的场景 ——
 *   那证明的是"逻辑对"，证明不了"导航 + 移动 + 攻击 + 击杀销毁"这四段拼起来能用。
 *   这个项目踩过一次"模块各自全绿、接缝全错"（JPEG 的 13 个 SOF 与导入器旧清单）。
 *
 * ★ 同时钉住两个"只在多模块下才暴露"的顺序问题：
 *   ① 击杀必须**先统计再销毁**（否则 kills 不涨，或者 onKill 读不到目标）；
 *   ② 目标被销毁之后，还锁着它的攻击者必须**报错**（`COMBAT.NO_TARGET`），
 *      而不是每 tick 静默失败 —— 那正是"AI 锁着尸体"的唯一线索。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { NavGrid } from "../../src/extensions/nav/nav-grid.ts";
import { Mover, MOVER_TYPE, createMoveModule, registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { Attacker, registerAttackerComponent } from "../../src/extensions/combat/attack.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { createCombatModule } from "../../src/extensions/combat/combat-module.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";

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

test("[战斗·接线] 真世界里追上并打死：击杀计数、命中次数、节点真的消失", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  registerMoverComponent(reg);
  const scene = new Scene("hunt", reg);
  const g = generateWorld({ seed: 2718, width: 26, height: 18, maxSitesPerCell: 1 });
  assert.equal(g.ok, true, g.ok ? "" : g.error.code);
  if (!g.ok) throw new Error("unreachable");
  assert.equal(assembleWorld(g.value, scene).ok, true);

  const gridR = NavGrid.fromPlan(g.value);
  assert.equal(gridR.ok, true);
  if (!gridR.ok) throw new Error("unreachable");
  const grid = gridR.value;

  // 起点：第一块可站地；终点：同一连通分量里曼哈顿距离最远的格（确定）
  let start = -1;
  for (let i = 0; i < grid.total; i++) {
    if (grid.isWalkableIndex(i)) {
      start = i;
      break;
    }
  }
  assert.ok(start >= 0);
  const comp = grid.componentOf(start);
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
  assert.ok(bestD >= 8, `终点太近（${String(bestD)}），接线判据没意义`);

  const spawn = grid.centerOf(start);
  const hunter = scene.spawnAt("hunter", spawn.x, spawn.z);
  const preyAt = grid.centerOf(goal);
  const rabbit = scene.spawnAt("rabbit", preyAt.x, preyAt.z);
  assert.equal(hunter.ok && rabbit.ok, true);
  if (!hunter.ok || !rabbit.ok) throw new Error("unreachable");

  const mover = new Mover();
  mover.speed = 3;
  scene.attach(hunter.value.id, () => mover);
  const atk = new Attacker();
  atk.damage = 2;
  atk.range = 1.2;
  atk.cooldownTicks = 5;
  scene.attach(hunter.value.id, () => atk);
  const hp = new Health();
  hp.hp = 6;
  hp.maxHp = 6;
  scene.attach(rabbit.value.id, () => hp);
  scene.flush();

  const rabbitId = rabbit.value.id;
  const moveMod = createMoveModule({ grid, decide: () => goal });
  const combatMod = createCombatModule({ decide: () => rabbitId });
  initOk(moveMod, makeCtx(scene));
  initOk(combatMod, makeCtx(scene));

  let killedAtTick = -1;
  for (let t = 1; t <= 3000; t++) {
    moveMod.update(t, 1 / 30);
    combatMod.update(t, 1 / 30);
    if (combatMod.stats.kills > 0) {
      killedAtTick = t;
      break;
    }
  }

  assert.ok(killedAtTick > 0, `3000 tick 内没打死（命中 ${String(combatMod.stats.hits)} · 射程外 ${String(combatMod.stats.outOfRange)}）`);
  assert.equal(combatMod.stats.kills, 1);
  assert.equal(combatMod.stats.hits, 3, "6 点血 / 每下 2 点 = 3 次命中");
  assert.ok(combatMod.stats.outOfRange > 0, "走过去的过程中应该在射程外试过（否则说明攻击模块根本不检查距离）");
  const gone = scene.find(rabbitId);
  assert.ok(gone === null || gone === undefined, "击杀后节点必须从场景里消失（否则 AI 会继续锁定尸体）");
  assert.ok(scene.find(hunter.value.id) !== null, "猎人自己不能被顺手删掉");
});

test("[战斗·接线] 目标被杀之后，还锁着它的攻击者会报 NO_TARGET（不是静默失败）", () => {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  const scene = new Scene("stale", reg);
  const a = scene.spawnAt("hunter", 0.5, 0.5);
  const t = scene.spawnAt("rabbit", 1.0, 0.5);
  assert.equal(a.ok && t.ok, true);
  if (!a.ok || !t.ok) throw new Error("unreachable");
  const atk = new Attacker();
  atk.damage = 1;
  atk.cooldownTicks = 0;
  scene.attach(a.value.id, () => atk);
  const hp = new Health();
  hp.hp = 1;
  hp.maxHp = 1;
  scene.attach(t.value.id, () => hp);
  scene.flush();

  const targetId = t.value.id;
  const mod = createCombatModule({ decide: () => targetId });
  initOk(mod, makeCtx(scene));

  mod.update(1, 0.1);
  assert.equal(mod.stats.kills, 1);
  assert.equal(scene.find(targetId) ?? null, null, "击杀后节点必须消失");

  // 目标没了，decide 还返回旧 id —— 必须被记成错误，而不是"打空了"
  mod.update(2, 0.1);
  assert.equal(mod.stats.errors, 1, "锁着死目标必须报错");
  assert.equal(mod.stats.lastError, "COMBAT.NO_TARGET");
  assert.equal(mod.stats.kills, 1, "不能重复计击杀");
});

test("[战斗·接线] destroyOnKill=false：节点留着但血是 0（尸体语义留给玩法）", () => {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  const scene = new Scene("corpse", reg);
  const a = scene.spawnAt("hunter", 0.5, 0.5);
  const t = scene.spawnAt("rabbit", 1.0, 0.5);
  assert.equal(a.ok && t.ok, true);
  if (!a.ok || !t.ok) throw new Error("unreachable");
  const atk = new Attacker();
  atk.damage = 4;
  atk.cooldownTicks = 0;
  scene.attach(a.value.id, () => atk);
  const hp = new Health();
  hp.hp = 4;
  hp.maxHp = 4;
  scene.attach(t.value.id, () => hp);
  scene.flush();

  let killSawHp = -1;
  const mod = createCombatModule({
    decide: () => t.value.id,
    destroyOnKill: false,
    onKill: (id) => {
      killSawHp = scene.find(id)?.get<Health>("combat.health")?.hp ?? -1;
    },
  });
  initOk(mod, makeCtx(scene));
  mod.update(1, 0.1);

  assert.equal(mod.stats.kills, 1);
  assert.equal(killSawHp, 0, "onKill 在销毁前调用，应该读到血已经归零");
  const still = scene.find(t.value.id);
  assert.ok(still !== null && still !== undefined, "destroyOnKill=false 时节点要留着");
  assert.equal(still!.get<Health>("combat.health")!.hp, 0);
  assert.equal(scene.countOf(MOVER_TYPE), 0, "这个场景里没有 mover（确认统计没串模块）");
});
