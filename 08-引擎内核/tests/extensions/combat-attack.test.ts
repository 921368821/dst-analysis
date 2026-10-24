/**
 * L4 · 攻击：够得着才打、打完要等、失败不动状态
 *
 * ★ 两条最容易写成假绿的：
 *   ① **冷却失败不能消费冷却** —— 只断言"第二次被拒"是看不出这一点的，
 *      要断言 `lastHitTick` 一点没变（否则"打空一次"会让真正能打的那一 tick 也打不出去）；
 *   ② **射程边界**要两侧各验一次（正好等于射程能打、超一点点不能），
 *      只验"远处打不到"的话，把判定写成 `dist2 < range*range` 也能过。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { HEALTH_TYPE, Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import {
  ATTACKER_TYPE,
  Attacker,
  COMBAT_COOLDOWN,
  COMBAT_NO_ATTACKER,
  COMBAT_OUT_OF_RANGE,
  COMBAT_SELF,
  attack,
  registerAttackerComponent,
} from "../../src/extensions/combat/attack.ts";

interface Setup {
  readonly scene: Scene;
  readonly aId: number;
  readonly tId: number;
  readonly atk: Attacker;
  readonly hp: Health;
}

function setup(
  ax: number,
  az: number,
  tx: number,
  tz: number,
  cfg: { damage?: number; range?: number; cooldownTicks?: number; hp?: number } = {},
): Setup {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  registerAttackerComponent(reg);
  const scene = new Scene("atk", reg);

  const an = scene.spawnAt("hunter", ax, az);
  assert.equal(an.ok, true);
  if (!an.ok) throw new Error("unreachable");
  const atk = new Attacker();
  atk.damage = cfg.damage ?? 2;
  atk.range = cfg.range ?? 2;
  atk.cooldownTicks = cfg.cooldownTicks ?? 10;
  scene.attach(an.value.id, () => atk);

  const tn = scene.spawnAt("rabbit", tx, tz);
  assert.equal(tn.ok, true);
  if (!tn.ok) throw new Error("unreachable");
  const hp = new Health();
  hp.hp = cfg.hp ?? 10;
  hp.maxHp = cfg.hp ?? 10;
  scene.attach(tn.value.id, () => hp);
  scene.flush();

  return { scene, aId: an.value.id, tId: tn.value.id, atk, hp };
}

test("[战斗·攻击] 射程内命中：扣血 + 记下 lastHitTick", () => {
  const s = setup(0.5, 0.5, 2.0, 0.5);
  const r = attack(s.scene, s.aId, s.tId, { tick: 10 });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value.report.after, 8);
  assert.equal(r.value.cooldownChecked, true);
  assert.equal(s.atk.lastHitTick, 10);
  assert.ok(Math.abs(r.value.distance - 1.5) < 1e-9);
  // 组件类型名同源：注册用的名字与查询用的名字必须是同一个常量
  assert.equal(s.scene.find(s.tId)!.get<Health>(HEALTH_TYPE)!.hp, 8);
  assert.equal(s.scene.countOf(ATTACKER_TYPE), 1);
});

test("[战斗·攻击] ★ 超射程：报错、血不动、冷却也不被消费", () => {
  const s = setup(0.5, 0.5, 5.5, 0.5);
  const r = attack(s.scene, s.aId, s.tId, { tick: 10 });
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, COMBAT_OUT_OF_RANGE);
  assert.equal(s.hp.hp, 10, "打不到就不该掉血");
  assert.equal(
    s.atk.lastHitTick,
    Number.NEGATIVE_INFINITY,
    "失败的攻击不该消费冷却 —— 否则『走过去的路上试打一次』会让真正到位的下一 tick 也打不出去",
  );
});

test("[战斗·攻击] 射程边界两侧各验一次", () => {
  // 正好等于射程：能打（判定用 `dist2 > range²`，等于不算超）
  const on = setup(0.5, 0.5, 2.5, 0.5);
  assert.equal(attack(on.scene, on.aId, on.tId, { tick: 1 }).ok, true, "距离正好等于射程时应该能打");

  // 超一点点：不能打
  const off = setup(0.5, 0.5, 2.5001, 0.5);
  const r = attack(off.scene, off.aId, off.tId, { tick: 1 });
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, COMBAT_OUT_OF_RANGE);
});

test("[战斗·攻击] 冷却：窗口内拒绝，到点放行", () => {
  const s = setup(0.5, 0.5, 1.5, 0.5);
  assert.equal(attack(s.scene, s.aId, s.tId, { tick: 10 }).ok, true);

  const early = attack(s.scene, s.aId, s.tId, { tick: 15 });
  assert.equal(early.ok, false);
  if (early.ok) throw new Error("unreachable");
  assert.equal(early.error.code, COMBAT_COOLDOWN);
  assert.equal(s.hp.hp, 8, "冷却中打不出去，血也不该掉");

  const onTime = attack(s.scene, s.aId, s.tId, { tick: 20 });
  assert.equal(onTime.ok, true, "正好隔 cooldownTicks 应该能打");
  assert.equal(s.hp.hp, 6);
});

test("[战斗·攻击] 不传 tick 就不检查冷却，并且报告里写明", () => {
  const s = setup(0.5, 0.5, 1.5, 0.5);
  const a = attack(s.scene, s.aId, s.tId);
  const b = attack(s.scene, s.aId, s.tId);
  assert.equal(a.ok && b.ok, true, "不传 tick 时不看冷却（供单点判据/编辑器试打）");
  if (!a.ok || !b.ok) throw new Error("unreachable");
  assert.equal(a.value.cooldownChecked, false, "没检查就要在报告里说清楚 —— 不能让人以为验过");
  assert.equal(s.hp.hp, 6);
});

test("[战斗·攻击] 自己打自己：报错，不是静默忽略", () => {
  const s = setup(0.5, 0.5, 0.5, 0.5);
  const r = attack(s.scene, s.aId, s.aId, { tick: 1 });
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, COMBAT_SELF);
});

test("[战斗·攻击] 攻击者不在场景里 / 没有组件：都报 NO_ATTACKER", () => {
  const s = setup(0.5, 0.5, 1.5, 0.5);
  const ghost = attack(s.scene, 9999, s.tId, { tick: 1 });
  assert.equal(ghost.ok, false);
  if (ghost.ok) throw new Error("unreachable");
  assert.equal(ghost.error.code, COMBAT_NO_ATTACKER);

  // 目标节点没有 Attacker 组件 —— 拿它当攻击者
  const asAttacker = attack(s.scene, s.tId, s.aId, { tick: 1 });
  assert.equal(asAttacker.ok, false);
  if (asAttacker.ok) throw new Error("unreachable");
  assert.equal(asAttacker.error.code, COMBAT_NO_ATTACKER);
});

test("[战斗·攻击] 目标已死：拒绝，且血还是 0", () => {
  const s = setup(0.5, 0.5, 1.5, 0.5, { damage: 5, hp: 5 });
  assert.equal(attack(s.scene, s.aId, s.tId, { tick: 1 }).ok, true);
  assert.equal(s.hp.hp, 0);
  const again = attack(s.scene, s.aId, s.tId, { tick: 100 });
  assert.equal(again.ok, false);
  if (again.ok) throw new Error("unreachable");
  assert.equal(again.error.code, "COMBAT.TARGET_DEAD");
});

test("[战斗·攻击] 配表非法（伤害 0 / 射程 0 / 冷却 -1）：拒绝且不掉血", () => {
  for (const cfg of [{ damage: 0 }, { range: 0 }, { cooldownTicks: -1 }] as const) {
    const s = setup(0.5, 0.5, 1.5, 0.5, cfg);
    const r = attack(s.scene, s.aId, s.tId, { tick: 1 });
    assert.equal(r.ok, false, `${JSON.stringify(cfg)} 应该被拒`);
    if (r.ok) throw new Error("unreachable");
    assert.equal(r.error.code, COMBAT_NO_ATTACKER);
    assert.equal(s.hp.hp, 10);
  }
});

test("[战斗·攻击] 无敌帧透传：连击被挡在 damage 那一层", () => {
  const s = setup(0.5, 0.5, 1.5, 0.5, { cooldownTicks: 0 });
  const first = attack(s.scene, s.aId, s.tId, { tick: 10, invulnTicks: 5 });
  assert.equal(first.ok, true, first.ok ? "" : first.error.code);
  const blocked = attack(s.scene, s.aId, s.tId, { tick: 12 });
  assert.equal(blocked.ok, false);
  if (blocked.ok) throw new Error("unreachable");
  assert.equal(blocked.error.code, "COMBAT.INVULNERABLE");
  assert.equal(s.hp.hp, 8);
});
