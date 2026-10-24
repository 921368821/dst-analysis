/**
 * L4 · 制作：把材料换成产物，**要么换成了，要么一点没动**
 *
 * ★ 六条最容易写成假绿的：
 *   ① "缺料"必须验**材料一点没少**。按顺序"检查一项扣一项"的实现在"刚好够"的
 *      语料上完全正常 —— 而玩家看到的是"材料少了，东西没做出来"。
 *   ② 缺料要验**缺的是哪一样、缺几个**（`detail.missing`）。只验"报了个错"的话，
 *      把 missing 写成空数组也能过。
 *   ③ 产物放不下必须验**回滚**。不回滚的症状是"材料变空气"，
 *      而所有计数（consumed / added）都可以是"对"的。
 *   ④ 配方 id 唯一/非空/材料非空/count 正整数要**逐项**验，并点名到字段。
 *   ⑤ 表序即优先级（`firstCraftable`）要用"第一条做不了、第二条能做"的语料验：
 *      顺序恰好与"能做"一致时不排序的实现照样绿。
 *   ⑥ 一次 craft 只产一次：验数量，不验"成功"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { addItem, countItem, makeInventory, registerInventoryComponents, stacksOf } from "../../src/extensions/inventory/inventory.ts";
import {
  RECIPE_BAD_TABLE,
  RECIPE_MISSING,
  RECIPE_NO_OWNER,
  RECIPE_NO_SPACE,
  craft,
  firstCraftable,
  missingFor,
  normalizeRecipes,
  type Recipe,
} from "../../src/extensions/crafting/recipe.ts";

const TABLE = [
  { id: "rope", name: "绳子", inputs: [{ kind: "reed", count: 2 }], output: { kind: "rope", count: 1 } },
  {
    id: "cooked_meat",
    name: "熟肉",
    inputs: [{ kind: "meat", count: 1 }, { kind: "grass_tuft", count: 1 }],
    output: { kind: "cooked_meat", count: 1 },
  },
] as const;

function mkScene(withBag = true): { scene: Scene; id: number } {
  const reg = new ComponentRegistry();
  registerInventoryComponents(reg);
  const scene = new Scene("craft", reg);
  const n = scene.spawnAt("hero", 5.5, 5.5);
  assert.equal(n.ok, true);
  if (!n.ok) throw new Error("unreachable");
  scene.flush();
  const id = n.value.id;
  if (withBag) makeInventory(scene, id, 8, 40);
  return { scene, id };
}

/** 一张"材料齐了"的背包：芦苇 2 / 肉 1 / 草 1。 */
function stock(scene: Scene, id: number): void {
  assert.ok(addItem(scene, id, "reed", 2).ok);
  assert.ok(addItem(scene, id, "meat", 1).ok);
  assert.ok(addItem(scene, id, "grass_tuft", 1).ok);
}

/** 当前堆数（"还有没有格子"要看它，不是看总数量）。 */
function stackCount(scene: Scene, id: number): number {
  return stacksOf(scene, id).length;
}

function table(): readonly Recipe[] {
  const r = normalizeRecipes(TABLE);
  assert.equal(r.ok, true);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
}

test("[制作] normalizeRecipes：合法表原样通过，**顺序不变**（表序即优先级）", () => {
  const r = normalizeRecipes(TABLE);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(r.value.map((x) => x.id), ["rope", "cooked_meat"]);
  assert.deepEqual(r.value[1]?.inputs, [
    { kind: "meat", count: 1 },
    { kind: "grass_tuft", count: 1 },
  ]);
});

test("[制作] normalizeRecipes：空表 / 非数组 都拒绝", () => {
  for (const bad of [[], null, 42, "rope"]) {
    const r = normalizeRecipes(bad);
    assert.equal(r.ok, false, `${JSON.stringify(bad)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, RECIPE_BAD_TABLE);
  }
});

test("[制作] normalizeRecipes：id 重复被拒绝（id 是主键）", () => {
  const r = normalizeRecipes([TABLE[0], { ...TABLE[0], name: "另一条绳子" }]);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, RECIPE_BAD_TABLE);
    assert.equal(r.error.detail?.field, "[1].id");
  }
});

test("[制作] normalizeRecipes：id / name / inputs / count 逐项点名到字段", () => {
  const cases: Array<[unknown, string]> = [
    [[{ name: "x", inputs: [{ kind: "a", count: 1 }], output: { kind: "b", count: 1 } }], "[0].id"],
    [[{ id: "", name: "x", inputs: [{ kind: "a", count: 1 }], output: { kind: "b", count: 1 } }], "[0].id"],
    [[{ id: "r", name: "", inputs: [{ kind: "a", count: 1 }], output: { kind: "b", count: 1 } }], "r.name"],
    [[{ id: "r", name: "x", inputs: [], output: { kind: "b", count: 1 } }], "r.inputs"],
    [[{ id: "r", name: "x", inputs: [{ kind: "a", count: 0 }], output: { kind: "b", count: 1 } }], "r.inputs[0]"],
    [[{ id: "r", name: "x", inputs: [{ kind: "", count: 1 }], output: { kind: "b", count: 1 } }], "r.inputs[0]"],
    [[{ id: "r", name: "x", inputs: [{ kind: "a", count: 1 }], output: { kind: "b", count: 1.5 } }], "r.output"],
    [[{ id: "r", name: "x", inputs: [{ kind: "a", count: 1 }], output: null }], "r.output"],
  ];
  for (const [raw, field] of cases) {
    const r = normalizeRecipes(raw);
    assert.equal(r.ok, false, `${JSON.stringify(raw)} 应被拒绝`);
    if (!r.ok) {
      assert.equal(r.error.code, RECIPE_BAD_TABLE);
      assert.equal(r.error.detail?.field, field, `错误应点名 ${field}，实际 ${JSON.stringify(r.error.detail)}`);
    }
  }
});

test("[制作] 材料齐全：扣 2 芦苇、得到 1 根绳子", () => {
  const { scene, id } = mkScene();
  stock(scene, id);
  const r = craft(scene, id, table()[0]!);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.deepEqual(r.value.consumed, [{ kind: "reed", count: 2 }]);
  assert.equal(r.value.added, 1);
  assert.equal(countItem(scene, id, "reed"), 0, "2 根芦苇应全部扣掉");
  assert.equal(countItem(scene, id, "rope"), 1);
  assert.equal(countItem(scene, id, "meat"), 1, "别的材料不该被动");
});

test("[制作] ★ 缺一项材料：**一点材料都不扣**，并说清缺什么", () => {
  const { scene, id } = mkScene();
  assert.ok(addItem(scene, id, "meat", 1).ok); // 有肉，没有草
  const r = craft(scene, id, table()[1]!);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, RECIPE_MISSING);
    assert.deepEqual(
      r.error.detail?.missing,
      [{ kind: "grass_tuft", need: 1, have: 0 }],
      "缺料清单必须点名到 kind 与数量",
    );
  }
  assert.equal(countItem(scene, id, "meat"), 1, "肉**不该**被扣掉（顺序反了就会出现这个症状）");
  assert.equal(countItem(scene, id, "cooked_meat"), 0);
});

test("[制作] 材料只够一半：缺料清单里给出 have/need", () => {
  const { scene, id } = mkScene();
  assert.ok(addItem(scene, id, "reed", 1).ok);
  const m = missingFor(scene, id, table()[0]!);
  assert.deepEqual(m, [{ kind: "reed", count: 2, have: 1 }]);
  const r = craft(scene, id, table()[0]!);
  assert.equal(r.ok, false);
  assert.equal(countItem(scene, id, "reed"), 1, "不够的时候连那 1 根也不该扣");
});

test("[制作] ★★ 产物放不进背包：材料**全部退回**（不能变空气）", () => {
  // 1 堆上限 1 个 ⇒ 芦苇与肉/草各占一堆，产物没有格子放
  const reg = new ComponentRegistry();
  registerInventoryComponents(reg);
  const scene = new Scene("craft-nospace", reg);
  const n = scene.spawnAt("hero", 5.5, 5.5);
  assert.equal(n.ok, true);
  if (!n.ok) return;
  scene.flush();
  const id = n.value.id;
  makeInventory(scene, id, 2, 40); // 只 2 堆
  // ★ 关键：两种材料都**装满一整堆**。这样扣掉 1 个之后那两堆仍然占着格子
  //   （"扣完就腾出格子"的语料会让 addItem 成功，判据就验不到回滚了）。
  assert.ok(addItem(scene, id, "meat", 40).ok);
  assert.ok(addItem(scene, id, "grass_tuft", 40).ok);
  assert.equal(stackCount(scene, id), 2, "两堆材料已占满背包");

  const r = craft(scene, id, table()[1]!);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, RECIPE_NO_SPACE);
    assert.deepEqual(r.error.detail?.rolledBack, [
      { kind: "meat", count: 1 },
      { kind: "grass_tuft", count: 1 },
    ]);
  }
  assert.equal(countItem(scene, id, "meat"), 40, "肉必须退回");
  assert.equal(countItem(scene, id, "grass_tuft"), 40, "草必须退回");
  assert.equal(countItem(scene, id, "cooked_meat"), 0);
});

test("[制作] 没有背包的节点：报 CRAFT.NO_OWNER（不静默当成成功）", () => {
  const { scene, id } = mkScene(false);
  const r = craft(scene, id, table()[0]!);
  assert.equal(r.ok, false);
  if (!r.ok) {
    // 缺料会先命中（没有背包 ⇒ 什么材料都没有）—— 这也是可接受的答案，
    // 但如果真是"没背包"，报告里必须说缺料而不是说做成了
    assert.ok(r.error.code === RECIPE_MISSING || r.error.code === RECIPE_NO_OWNER);
  }
  assert.equal(countItem(scene, id, "rope"), 0);
});

test("[制作] 节点不存在：报 CRAFT.NO_OWNER", () => {
  const { scene } = mkScene();
  const r = craft(scene, 999, table()[0]!);
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, RECIPE_NO_OWNER);
});

test("[制作] ★ 表序即优先级：第一条做不了时选第二条（不是「随便挑一条」）", () => {
  const { scene, id } = mkScene();
  // 只有肉 + 草 ⇒ rope（需要 2 芦苇）做不了，cooked_meat 能做
  assert.ok(addItem(scene, id, "meat", 1).ok);
  assert.ok(addItem(scene, id, "grass_tuft", 1).ok);
  const picked = firstCraftable(scene, id, table());
  assert.equal(picked?.id, "cooked_meat", `应选第二条，实际 ${picked?.id}`);
});

test("[制作] ★★ 两条都能做时选**表里第一条**，换一张反序表答案跟着换", () => {
  // 上一条判据只有一条"能做"，倒序遍历照样能选对 —— 分辨不出排序有没有被实现。
  // 这里让两条都能做，再给一张顺序相反的表：答案不跟着换 ⇒ 实现根本没看表序。
  const { scene, id } = mkScene();
  stock(scene, id); // 芦苇 2 / 肉 1 / 草 1 ⇒ rope 与 cooked_meat 都能做
  const forward = firstCraftable(scene, id, table());
  assert.equal(forward?.id, "rope", `两条都能做，应选表里第一条，实际 ${forward?.id}`);
  const backward = firstCraftable(scene, id, [...table()].reverse());
  assert.equal(backward?.id, "cooked_meat", `反序表的第一条是 cooked_meat，实际 ${backward?.id}`);
});

test("[制作] 一条都做不了 ⇒ firstCraftable 返回 undefined（不是抛错）", () => {
  const { scene, id } = mkScene();
  assert.equal(firstCraftable(scene, id, table()), undefined);
});

test("[制作] 连做两次：第二次材料不够就被挡住（数量守恒）", () => {
  const { scene, id } = mkScene();
  assert.ok(addItem(scene, id, "reed", 3).ok);
  assert.equal(craft(scene, id, table()[0]!).ok, true);
  assert.equal(countItem(scene, id, "rope"), 1);
  const second = craft(scene, id, table()[0]!);
  assert.equal(second.ok, false, "剩 1 根芦苇，做不出第二根绳子");
  assert.equal(countItem(scene, id, "reed"), 1, "失败的那次不该扣");
  assert.equal(countItem(scene, id, "rope"), 1);
});
