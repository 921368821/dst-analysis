/**
 * L4 · 饱食度：肉有用了
 *
 * ★ 四条最容易写成假绿的：
 *   ① 只验"吃了一口从 30 变成 60"不够 —— 上限夹取不生效的实现在这条上照样绿。
 *      要有一条"吃到上限"的判据，并且要求 `wasted` **说得清**。
 *   ② "先判满再扣物品"必须在 `food.test.ts` 里验（那是两层交界），
 *      这一层只验 `feed` 自己允许溢出但如实报告。
 *   ③ 归零 ≠ 死：要有一条判据断言"归零之后节点还在、血量一点没动"。
 *   ④ `drain` 与 `feed(-n)` 分开写，所以负数/零在两个入口都要各验一遍。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import {
  HUNGER_BAD_AMOUNT,
  HUNGER_NO_COMPONENT,
  HUNGER_NO_OWNER,
  HUNGER_TYPE,
  Hunger,
  drain,
  feed,
  isStarving,
  makeHunger,
  registerHungerComponent,
} from "../../src/extensions/survival/hunger.ts";

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHungerComponent(reg);
  return new Scene("hunger", reg);
}

function mkNode(scene: Scene): number {
  const n = scene.spawnAt("hero", 5.5, 5.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  scene.flush();
  return n.value.id;
}

test("[饱食] 组件注册名与查询名同源", () => {
  assert.equal(new Hunger().schema.type, HUNGER_TYPE);
  const reg = new ComponentRegistry();
  registerHungerComponent(reg);
  assert.equal(reg.has(HUNGER_TYPE), true);
});

test("[饱食] makeHunger 省略 start 就是满值（默认值必须站在安全的一侧）", () => {
  const scene = mkScene();
  const id = mkNode(scene);
  const r = makeHunger(scene, id, 80);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const h = scene.find(id)?.get<Hunger>(HUNGER_TYPE);
  assert.ok(h !== undefined);
  assert.deepEqual([h.value, h.max], [80, 80], "省略 start ⇒ 满值");
  assert.equal(isStarving(h), false);
});

test("[饱食] makeHunger 拒绝非法上限 / 越界初始值（各报自己的码）", () => {
  const scene = mkScene();
  const id = mkNode(scene);
  for (const bad of [0, -1, 1.5, Number.NaN]) {
    const r = makeHunger(scene, id, bad as number);
    assert.equal(r.ok, false, `上限 ${String(bad)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, HUNGER_BAD_AMOUNT);
  }
  const over = makeHunger(scene, id, 10, 11);
  assert.equal(over.ok, false);
  if (!over.ok) assert.equal(over.error.code, HUNGER_BAD_AMOUNT, "初始值超过上限应被拒绝，而不是夹取");
});

test("[饱食] makeHunger 对不存在的节点报 HUNGER.NO_OWNER", () => {
  const scene = mkScene();
  const r = makeHunger(scene, 999, 10);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, HUNGER_NO_OWNER);
});

test("[饱食] ★ 吃到上限：夹到 max，溢出部分如实报告（不是静默吞掉）", () => {
  const scene = mkScene();
  const id = mkNode(scene);
  makeHunger(scene, id, 100, 90);
  const r = feed(scene, id, 30);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(
    [r.value.before, r.value.after, r.value.applied, r.value.wasted],
    [90, 100, 10, 20],
    "吃 30 点、只装得下 10 点 ⇒ applied=10 / wasted=20",
  );
});

test("[饱食] 营养值必须是正整数（0 / 负数 / 小数 / NaN 全部拒绝）", () => {
  const scene = mkScene();
  const id = mkNode(scene);
  makeHunger(scene, id, 100, 10);
  for (const bad of [0, -3, 0.5, Number.NaN]) {
    const r = feed(scene, id, bad as number);
    assert.equal(r.ok, false, `营养值 ${String(bad)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, HUNGER_BAD_AMOUNT);
  }
  const h = scene.find(id)?.get<Hunger>(HUNGER_TYPE);
  assert.equal(h?.value, 10, "被拒绝的 feed 不该改值");
});

test("[饱食] 没装组件的节点：feed 报 HUNGER.NO_COMPONENT（不是静默成功）", () => {
  const scene = mkScene();
  const id = mkNode(scene);
  const r = feed(scene, id, 5);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, HUNGER_NO_COMPONENT);
});

test("[饱食] ✅ drain 夹到 0，且归零**不等于**死（组件只是一个数字）", () => {
  const scene = mkScene();
  const id = mkNode(scene);
  makeHunger(scene, id, 100, 3);
  const r = drain(scene, id, 10);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual([r.value.after, r.value.applied], [0, 3], "扣 10 点只剩 3 点 ⇒ applied=3");
  const h = scene.find(id)?.get<Hunger>(HUNGER_TYPE);
  assert.ok(h !== undefined);
  assert.equal(isStarving(h), true);
  assert.equal(scene.find(id)?.active, true, "归零之后节点必须还在（世界怎么变是玩法的事）");
});

test("[饱食] drain 也拒绝非正整数（与 feed 同一个入口纪律）", () => {
  const scene = mkScene();
  const id = mkNode(scene);
  makeHunger(scene, id, 100, 50);
  for (const bad of [0, -1, 2.5]) {
    const r = drain(scene, id, bad as number);
    assert.equal(r.ok, false, `衰减量 ${String(bad)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, HUNGER_BAD_AMOUNT);
  }
});
