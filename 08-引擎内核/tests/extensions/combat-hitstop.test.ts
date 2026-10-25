/**
 * L4 · 顿帧（hitstop）：「打中了」把世界冻住几个逻辑步
 *
 * ★ 这一组的判据全部走**真实链路**：combat-module 的 `onHit` → 策略 → 调度器冻结。
 *   单元测 `trigger()` 只能证"它调了 freeze"，证不了"命中真的会让世界停下来" ——
 *   而后者才是这个模块存在的理由。
 *
 * 三条只有集成才暴露的形状：
 *   ① **触发那一步照常跑完**（伤害/闪色在那一步里应用），下一步才开始冻；
 *   ② **策略拿得到它做判断需要的全部字段**（`dead` / `applied` / `overkill`）——
 *      少给一个，宿主就只能靠"最近一次命中是谁"这种外部状态猜（批65 的老问题）；
 *   ③ **非法策略值拒绝且不夹取** —— 夹取到 0 会让"配了 3.5 步"看起来像没配，
 *      夹取到 1 会让每次非法配置都真冻一下，而没人知道为什么。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { FixedStepScheduler } from "../../src/core/scheduler/scheduler.ts";
import { registerAttackerComponent, Attacker } from "../../src/extensions/combat/attack.ts";
import { registerHealthComponent, Health } from "../../src/extensions/combat/health.ts";
import { createCombatModule, type HitInfo } from "../../src/extensions/combat/combat-module.ts";
import { HITSTOP_BAD_MODULE, HITSTOP_BAD_TICKS, createHitstopModule } from "../../src/extensions/combat/hitstop.ts";

function makeCtx(scene: Scene, sched: FixedStepScheduler | null): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  if (sched !== null) services.provide(Services.Scheduler, sched, "test");
  return {
    log: { channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }) } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  } as unknown as ModuleContext;
}

interface Fixture {
  readonly scene: Scene;
  readonly sched: FixedStepScheduler;
  readonly preyId: number;
  /** 猎人的节点 id（判据不能猜：由场景分配）。 */
  readonly attackerId: number;
  /** 宿主那一侧：把战斗模块挂在调度器上（与浏览器宿主的 onStep 同一形状）。 */
  readonly drive: (frames: number) => void;
  readonly hitstop: ReturnType<typeof createHitstopModule>;
}

/**
 * 造"调度器 + 战斗模块 + 顿帧模块"三件套。
 * ★ 战斗模块通过 `sched.onStep` 驱动，而不是直接 `update()`：
 *   顿帧的触发点就在这一步里面，直接 update 会绕过调度器、证不到"世界真的停了"。
 * ★ 默认给攻击者 5 tick 冷却：冷却是 0 的话它每 tick 都命中、每 tick 都重新冻结，
 *   "冻结结束"就永远观察不到（那不是 bug，是连击的真相 —— 但要观察结束就得让它停手）。
 */
function mk(policy: (info: HitInfo) => number, cooldownTicks = 5): Fixture {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  const scene = new Scene("hitstop", reg);
  const a = scene.spawnAt("hunter", 0, 0);
  const b = scene.spawnAt("prey", 1, 0);
  assert.equal(a.ok && b.ok, true);
  if (!a.ok || !b.ok) throw new Error("unreachable");
  scene.flush();
  const atk = new Attacker();
  atk.damage = 2;
  atk.range = 3;
  atk.cooldownTicks = cooldownTicks;
  assert.ok(scene.attach(a.value.id, () => atk).ok);
  const hp = new Health();
  hp.maxHp = 10;
  hp.hp = 10;
  assert.ok(scene.attach(b.value.id, () => hp).ok);
  scene.flush();

  const sched = new FixedStepScheduler({ fixedDt: 1 / 30, maxStepsPerFrame: 10 });
  const combat = createCombatModule({
    decide: () => b.value.id,
    onHit: (info) => {
      void hitstop.trigger(info);
    },
  });
  const ci = combat.init(makeCtx(scene, sched)) as { ok: boolean } | undefined;
  assert.equal(ci?.ok, true);
  const hitstop = createHitstopModule({ policy });
  const r = hitstop.init(makeCtx(scene, sched)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, true);

  sched.onStep((tick, dt) => combat.update(tick, dt));
  return {
    scene,
    sched,
    preyId: b.value.id,
    attackerId: a.value.id,
    drive: (frames) => {
      for (let i = 0; i < frames; i++) sched.advance(1 / 60);
    },
    hitstop,
  };
}

test("★ 命中让世界当场冻住：触发那一步照常跑完，下一步一步不走", () => {
  const f = mk(() => 3);
  f.drive(2); // 60Hz 两帧 = 一个 30Hz 步 ⇒ tick 1（这一步里命中并冻结）
  assert.equal(f.sched.tick, 1, "触发那一步必须跑完（伤害在那一步里生效）");
  assert.equal(f.sched.frozen, true, "下一步开始冻");
  assert.equal(f.hitstop.stats.triggers, 1);

  const tickAtFreeze = f.sched.tick;
  f.drive(6); // 冻结期：6 帧 ≈ 3 个逻辑步的时长，一步都不该走
  assert.equal(f.sched.tick, tickAtFreeze, "冻结期间 tick 不许动");
  assert.equal(f.sched.stats().totalFreezeTicks, 3, "3 步冻结应被全额收掉");

  f.drive(2); // 冻结结束，恢复推进
  assert.ok(f.sched.tick > tickAtFreeze, "到期后必须恢复");
  assert.equal(f.sched.frozen, false);
});

test("策略返回 0 = 不冻（正常答案，不是错误）", () => {
  const f = mk(() => 0);
  f.drive(2);
  assert.equal(f.sched.frozen, false, "策略说不冻就不冻");
  assert.equal(f.sched.tick, 1, "世界照常推进");
  assert.equal(f.hitstop.stats.skipped, 1);
  assert.equal(f.hitstop.stats.triggers, 0);
  assert.equal(f.hitstop.stats.lastTicks, 0);
});

test("★ 非法策略值（3.5 / -1 / NaN）拒绝并入账，且**不夹取**", () => {
  // 夹取到 0 ⇒ "配了 3.5 步"看起来像没配；夹取到 1 ⇒ 每次都真冻一下没人知道为什么
  const f = mk(() => 3.5);
  f.drive(2);
  assert.equal(f.sched.frozen, false, "非法值不许冻");
  assert.equal(f.hitstop.stats.rejected, 1);
  assert.equal(f.hitstop.stats.triggers, 0);

  const g = mk(() => -1);
  g.drive(2);
  assert.equal(g.sched.frozen, false);
  assert.equal(g.hitstop.stats.rejected, 1);
});

test("非法值给出稳定错误码，且信息里带上那个坏值", () => {
  const f = mk(() => Number.NaN);
  const sched = f.sched;
  // 直接打一次 trigger 拿错误（走 onHit 的路径上返回值被丢弃，这里单独验）
  const mod = createHitstopModule({ policy: () => Number.NaN });
  assert.equal((mod.init(makeCtx(f.scene, sched)) as { ok: boolean } | undefined)?.ok, true);
  const r = mod.trigger({
    attackerId: 1,
    targetId: 2,
    before: 10,
    after: 8,
    applied: 2,
    overkill: 0,
    dead: false,
    tick: 1,
  });
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, HITSTOP_BAD_TICKS);
    assert.ok(r.error.message.includes("NaN"), "错误信息里要带上坏值，否则配表错了都不知道填了什么");
  }
  assert.equal(mod.stats.rejected, 1);
});

test("★ 策略拿得到它做判断需要的字段：玩家命中与击杀可以不同步长", () => {
  // 批65 的老问题换了个形式：回调少给一个参数，调用方就得自己重构状态。
  // 这里验"dead / applied / overkill / attackerId 都拿得到"—— 缺任何一个，
  // 宿主的策略就只能靠外部状态猜，而猜的那个版本在群战里必然错。
  const seen: HitInfo[] = [];
  let hunterId = -1; // ★ 不猜节点 id：由场景分配，建完之后再填进来
  const f = mk((info) => {
    seen.push(info);
    return info.dead ? 10 : info.attackerId === hunterId ? 3 : 0;
  });
  hunterId = f.attackerId;
  f.drive(2);
  assert.equal(seen.length, 1, "每次命中策略都被问一次");
  const h = seen[0]!;
  assert.equal(h.applied, 2);
  assert.equal(h.before, 10);
  assert.equal(h.after, 8);
  assert.equal(h.overkill, 0);
  assert.equal(h.dead, false);
  assert.equal(h.tick, 1);
  assert.equal(f.sched.freezeTicks, 3, "非击杀命中按 3 步冻");
});

test("连击取最长剩余：3 步后再来 1 步不会缩短，来 5 步才延长", () => {
  const f = mk(() => 3);
  f.drive(2);
  assert.equal(f.sched.freezeTicks, 3);
  // 同一 tick 里再打一下（冷却 0）：第二个 trigger 只延长不缩短
  const mod = f.hitstop;
  const before = mod.stats.triggers;
  void mod.trigger({
    attackerId: 1,
    targetId: f.preyId,
    before: 8,
    after: 7,
    applied: 1,
    overkill: 0,
    dead: false,
    tick: 1,
  });
  assert.equal(f.sched.freezeTicks, 3, "更短的重复触发不该缩短（累加会得到 6）");
  assert.equal(mod.stats.triggers, before + 1);
  assert.equal(mod.stats.extended, 1, "本来就在冻 ⇒ 记一次延长");
});

test("init 拿不到调度器：返回 BAD_MODULE，且不算一次拒绝", () => {
  const reg = new ComponentRegistry();
  const scene = new Scene("nosched", reg);
  const mod = createHitstopModule({ policy: () => 3 });
  const r = mod.init(makeCtx(scene, null)) as { ok: boolean } | undefined;
  assert.equal(r?.ok, false);
  // init 之前的 trigger：接线 bug，单独一条码，不混进 rejected（那是配表错的桶）
  const t = mod.trigger({
    attackerId: 1,
    targetId: 2,
    before: 10,
    after: 8,
    applied: 2,
    overkill: 0,
    dead: false,
    tick: 1,
  });
  assert.equal(t.ok, false);
  if (!t.ok) assert.equal(t.error.code, HITSTOP_BAD_MODULE);
  assert.equal(mod.stats.rejected, 0, "接线 bug 不进配表错的桶");
});

test("stats 透传调度器状态（宿主一处读齐，不用摸调度器）", () => {
  const f = mk(() => 4);
  assert.equal(f.hitstop.stats.frozen, false);
  assert.equal(f.hitstop.stats.freezeTicks, 0);
  f.drive(2);
  assert.equal(f.hitstop.stats.frozen, true);
  assert.equal(f.hitstop.stats.freezeTicks, 4);
  assert.equal(f.hitstop.stats.lastTicks, 4);
});
