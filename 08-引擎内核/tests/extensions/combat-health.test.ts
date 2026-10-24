/**
 * L4 · 生命值：整数血量、归零夹住、死不再被打
 *
 * ★ 这份判据里最要紧的是第 3 条与第 9 条：
 *   ③ 打尸体必须**报错**（不是静默 0）—— 否则"目标选择锁着死节点"永远暴露不出来；
 *   ⑨ 失败必须**一点状态不动** —— 否则"扣了一部分才失败"会让血量慢慢漂。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import {
  COMBAT_BAD_AMOUNT,
  COMBAT_INVULNERABLE,
  COMBAT_NO_HEALTH,
  COMBAT_NO_TARGET,
  COMBAT_TARGET_DEAD,
  HEALTH_TYPE,
  Health,
  damage,
  heal,
  isDead,
  registerHealthComponent,
} from "../../src/extensions/combat/health.ts";

function world() {
  const reg = new ComponentRegistry();
  registerHealthComponent(reg);
  const scene = new Scene("combat", reg);
  return { scene, reg };
}

function withHealth(scene: Scene, name: string, hp: number, maxHp = hp): number {
  const n = scene.spawnAt(name, 0.5, 0.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  const made = scene.attach(n.value.id, () => {
    const h = new Health();
    h.hp = hp;
    h.maxHp = maxHp;
    return h;
  });
  assert.equal(made.ok, true);
  scene.flush();
  return n.value.id;
}

test("[战斗·血] 扣血：数值、applied、overkill 三者自洽", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 10);
  const r = damage(scene, id, 3);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value.before, 10);
  assert.equal(r.value.after, 7);
  assert.equal(r.value.applied, 3);
  assert.equal(r.value.overkill, 0);
  assert.equal(r.value.dead, false);
  assert.equal(scene.find(id)!.get<Health>(HEALTH_TYPE)!.hp, 7);
});

test("[战斗·血] 溢出伤害：血量夹在 0，overkill 记下超出多少", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 2);
  const r = damage(scene, id, 5);
  assert.equal(r.ok, true);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value.after, 0, "血量不许变负 —— 负数会让不同平台上的『死了没有』分叉");
  assert.equal(r.value.applied, 2, "applied 是实际扣掉的，不是请求值");
  assert.equal(r.value.overkill, 3);
  assert.equal(r.value.dead, true);
});

test("[战斗·血] ★ 打已经归零的目标要报错，不能静默返回 0", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 1);
  assert.equal(damage(scene, id, 1).ok, true);
  const again = damage(scene, id, 1);
  assert.equal(again.ok, false);
  if (again.ok) throw new Error("unreachable");
  assert.equal(again.error.code, COMBAT_TARGET_DEAD, "打尸体通常是目标选择出错，必须能看见");
});

test("[战斗·血] 伤害必须是正整数（0 / 负 / 小数 / NaN 全拒）", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 10);
  for (const bad of [0, -1, 1.5, 0.1, Number.NaN, Number.POSITIVE_INFINITY]) {
    const r = damage(scene, id, bad);
    assert.equal(r.ok, false, `${String(bad)} 应该被拒`);
    if (r.ok) throw new Error("unreachable");
    assert.equal(r.error.code, COMBAT_BAD_AMOUNT);
  }
  assert.equal(scene.find(id)!.get<Health>(HEALTH_TYPE)!.hp, 10, "拒绝的调用一点血都不该扣");
});

test("[战斗·血] 节点不存在 / 没有血量组件：两种错误分得清", () => {
  const { scene } = world();
  const missing = damage(scene, 9999, 1);
  assert.equal(missing.ok, false);
  if (missing.ok) throw new Error("unreachable");
  assert.equal(missing.error.code, COMBAT_NO_TARGET);

  const bare = scene.spawnAt("bare", 0.5, 0.5);
  assert.equal(bare.ok, true);
  if (!bare.ok) throw new Error("unreachable");
  scene.flush();
  const noHp = damage(scene, bare.value.id, 1);
  assert.equal(noHp.ok, false);
  if (noHp.ok) throw new Error("unreachable");
  assert.equal(noHp.error.code, COMBAT_NO_HEALTH);
});

test("[战斗·血] 无敌帧：窗口内拒绝且不掉血，窗口一过就能打", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 10);
  const first = damage(scene, id, 2, { tick: 10, invulnTicks: 5 });
  assert.equal(first.ok, true, first.ok ? "" : first.error.code);
  assert.equal(scene.find(id)!.get<Health>(HEALTH_TYPE)!.hp, 8);

  const blocked = damage(scene, id, 2, { tick: 12 });
  assert.equal(blocked.ok, false);
  if (blocked.ok) throw new Error("unreachable");
  assert.equal(blocked.error.code, COMBAT_INVULNERABLE);
  assert.equal(scene.find(id)!.get<Health>(HEALTH_TYPE)!.hp, 8, "无敌帧内不许掉血");

  const after = damage(scene, id, 2, { tick: 15 });
  assert.equal(after.ok, true, "tick 正好等于截止时应该能打（< 才无敌）");
  if (!after.ok) throw new Error("unreachable");
  assert.equal(after.value.after, 6);
});

test("[战斗·血] 归零后回血不复活（复活要有单独的语义）", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 3);
  assert.equal(damage(scene, id, 3).ok, true);
  assert.equal(isDead(scene.find(id)!.get<Health>(HEALTH_TYPE)!), true);

  const r = heal(scene, id, 5);
  assert.equal(r.ok, false);
  if (r.ok) throw new Error("unreachable");
  assert.equal(r.error.code, COMBAT_TARGET_DEAD);
  assert.equal(scene.find(id)!.get<Health>(HEALTH_TYPE)!.hp, 0);
});

test("[战斗·血] 回血夹到上限，返回值是实际回了多少", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 8, 10);
  const r = heal(scene, id, 5);
  assert.equal(r.ok, true);
  if (!r.ok) throw new Error("unreachable");
  assert.equal(r.value, 2, "上限 10，回了 2 点；不是 5");
  assert.equal(scene.find(id)!.get<Health>(HEALTH_TYPE)!.hp, 10);
});

test("[战斗·血] ★ 失败一点状态都不动（不扣血、不设无敌）", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 4);
  // 先制造一次失败：小数伤害
  assert.equal(damage(scene, id, 0.5, { tick: 1, invulnTicks: 99 }).ok, false);
  const h = scene.find(id)!.get<Health>(HEALTH_TYPE)!;
  assert.equal(h.hp, 4);
  assert.equal(h.invulnUntil, -1, "失败的调用不该顺手设无敌帧");
});

test("[战斗·血] 扣血不销毁节点（销毁是玩法决定，不是这一层）", () => {
  const { scene } = world();
  const id = withHealth(scene, "dummy", 1);
  assert.equal(damage(scene, id, 1).ok, true);
  const n = scene.find(id);
  assert.ok(n !== undefined && n !== null, "血量模块不该删节点 —— 那会让『算错血』和『死太早』纠缠");
  assert.equal(scene.stats().nodes >= 1, true);
});
