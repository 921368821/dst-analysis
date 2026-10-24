/**
 * L4 · 进食：把"背包里的肉"换成"饱食度"
 *
 * ★ 五条最容易写成假绿的：
 *   ① **"先判满再扣物品"只能靠"吃饱了去吃"这条判据抓住**。反过来（先扣再判）
 *      的实现在"吃得下"的语料上完全正常 —— 而玩家看到的是"吃东西会吞东西"。
 *      断言必须是**数量不变**，不是"报了个错"。
 *   ② 未知 kind 也要断言**物品数量不变**：静默跳过的实现不会报错。
 *   ③ 回血要单验：`nutrition` 对、`health` 没接上的实现，在"只看饱食度"的
 *      判据上照样绿。
 *   ④ 死人不能吃：`heal()` 对尸体是报错的，所以"能吃的尸体"会走一条半死半活的路径。
 *   ⑤ 配表的非法值要**逐个字段点名**：只断言"有个错"的话，把 nutrition 的校验
 *      写成"必须存在"也能过。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { Health, registerHealthComponent } from "../../src/extensions/combat/health.ts";
import { addItem, countItem, makeInventory, registerInventoryComponents } from "../../src/extensions/inventory/inventory.ts";
import {
  FOOD_BAD_TABLE,
  FOOD_DEAD,
  FOOD_FULL,
  FOOD_NOT_HELD,
  FOOD_UNKNOWN_KIND,
  eat,
  normalizeFoodTable,
} from "../../src/extensions/survival/food.ts";
import { HUNGER_TYPE, makeHunger, registerHungerComponent, type Hunger } from "../../src/extensions/survival/hunger.ts";

const TABLE = { meat: { nutrition: 25, health: 5 }, berry: { nutrition: 10 } } as const;

function mkScene(): Scene {
  const reg = new ComponentRegistry();
  registerHungerComponent(reg);
  registerHealthComponent(reg);
  registerInventoryComponents(reg);
  return new Scene("food", reg);
}

function mkHero(scene: Scene, hp = 10, hungerStart = 40): number {
  const n = scene.spawnAt("hero", 5.5, 5.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  scene.flush();
  const id = n.value.id;
  const h = new Health();
  h.hp = hp;
  h.maxHp = 10;
  scene.attach(id, () => h);
  scene.flush();
  makeInventory(scene, id);
  makeHunger(scene, id, 100, hungerStart);
  return id;
}

function hungerOf(scene: Scene, id: number): number {
  const h = scene.find(id)?.get<Hunger>(HUNGER_TYPE);
  return h?.value ?? -1;
}

test("[食物] normalizeFoodTable：合法表原样通过（health 可省略）", () => {
  const r = normalizeFoodTable(TABLE);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(r.value, { berry: { nutrition: 10 }, meat: { nutrition: 25, health: 5 } });
});

test("[食物] normalizeFoodTable：空表报错（空表几乎一定是忘了填）", () => {
  const r = normalizeFoodTable({});
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, FOOD_BAD_TABLE);
});

test("[食物] normalizeFoodTable：nutrition 非正整数，错误信息里**点名到字段**", () => {
  for (const bad of [0, -1, 1.5, Number.NaN, undefined, "25"]) {
    const r = normalizeFoodTable({ meat: { nutrition: bad } });
    assert.equal(r.ok, false, `nutrition=${String(bad)} 应被拒绝`);
    if (!r.ok) {
      assert.equal(r.error.code, FOOD_BAD_TABLE);
      assert.equal(r.error.detail?.field, "meat.nutrition", `错误必须点名字段，实际 ${JSON.stringify(r.error.detail)}`);
    }
  }
});

test("[食物] normalizeFoodTable：health 给了就必须是正整数（0 也算写错）", () => {
  for (const bad of [0, -2, 0.5]) {
    const r = normalizeFoodTable({ meat: { nutrition: 5, health: bad } });
    assert.equal(r.ok, false, `health=${String(bad)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.detail?.field, "meat.health");
  }
});

test("[食物] normalizeFoodTable：不是对象 / 是数组 / 项不是对象 都拒绝", () => {
  for (const bad of [null, 42, "meat", [1, 2]]) {
    const r = normalizeFoodTable(bad);
    assert.equal(r.ok, false, `${JSON.stringify(bad)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, FOOD_BAD_TABLE);
  }
  const r2 = normalizeFoodTable({ meat: 25 });
  assert.equal(r2.ok, false, "项是数字（把 nutrition 直接写在项上）应被拒绝");
});

test("[食物] eat：正常吃一个 ⇒ 扣 1 个、饱食 +25、顺带回血", () => {
  const scene = mkScene();
  const id = mkHero(scene, 4, 40);
  addItem(scene, id, "meat", 2);
  const r = eat(scene, id, "meat", TABLE);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual([r.value.hungerBefore, r.value.hungerAfter, r.value.healed], [40, 65, 5]);
  assert.equal(countItem(scene, id, "meat"), 1, "吃一个应该只少一个");
  assert.equal(hungerOf(scene, id), 65);
  assert.equal(scene.find(id)?.get<Health>("combat.health")?.hp, 9, "4 + 5 点回血");
});

test("[食物] ★ 吃饱了再吃：报 FOOD_FULL，且**物品一个都不少**（顺序不能反）", () => {
  const scene = mkScene();
  const id = mkHero(scene, 10, 100);
  addItem(scene, id, "meat", 3);
  const r = eat(scene, id, "meat", TABLE);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, FOOD_FULL);
  assert.equal(countItem(scene, id, "meat"), 3, "吃饱了不该消耗物品（先判满、再扣，见文件头 ①）");
  assert.equal(hungerOf(scene, id), 100);
});

test("[食物] 不在表里的 kind：报 FOOD_UNKNOWN_KIND，物品与饱食都不动", () => {
  const scene = mkScene();
  const id = mkHero(scene, 10, 40);
  addItem(scene, id, "rope", 1);
  const r = eat(scene, id, "rope", TABLE);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, FOOD_UNKNOWN_KIND);
  assert.equal(countItem(scene, id, "rope"), 1);
  assert.equal(hungerOf(scene, id), 40);
});

test("[食物] 身上没有这个东西：报 FOOD_NOT_HELD，饱食不变", () => {
  const scene = mkScene();
  const id = mkHero(scene, 10, 40);
  const r = eat(scene, id, "meat", TABLE);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, FOOD_NOT_HELD);
  assert.equal(hungerOf(scene, id), 40);
});

test("[食物] 死人不能吃（报 FOOD_DEAD，物品不扣）", () => {
  const scene = mkScene();
  const id = mkHero(scene, 10, 40);
  addItem(scene, id, "meat", 1);
  const h = scene.find(id)?.get<Health>("combat.health");
  assert.ok(h !== undefined);
  if (h !== undefined) h.hp = 0;
  const r = eat(scene, id, "meat", TABLE);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, FOOD_DEAD);
  assert.equal(countItem(scene, id, "meat"), 1, "尸体不该消耗食物");
});

test("[食物] 不回血的食物（省略 health）：healed=0，血量不动", () => {
  const scene = mkScene();
  const id = mkHero(scene, 4, 40);
  addItem(scene, id, "berry", 1);
  const r = eat(scene, id, "berry", TABLE);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(r.value.healed, 0);
  assert.equal(scene.find(id)?.get<Health>("combat.health")?.hp, 4, "省略 health 就不该回血");
});

test("[食物] 连吃两次累加，第三次撞到上限", () => {
  const scene = mkScene();
  const id = mkHero(scene, 10, 0);
  addItem(scene, id, "meat", 10);
  // 0 → 25 → 50 → 75 → 100 → 满
  for (let i = 0; i < 4; i++) {
    const r = eat(scene, id, "meat", TABLE);
    assert.equal(r.ok, true, `第 ${String(i + 1)} 次应该能吃`);
  }
  assert.equal(hungerOf(scene, id), 100);
  const fifth = eat(scene, id, "meat", TABLE);
  assert.equal(fifth.ok, false, "满了之后不该还能吃");
  if (!fifth.ok) assert.equal(fifth.error.code, FOOD_FULL);
  assert.equal(countItem(scene, id, "meat"), 6, "只该吃掉 4 个");
});
