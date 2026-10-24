/**
 * L4 · 背包与"采集 → 背包"闭环
 *
 * ★ 这一组判据盯住三种**静默**失效：
 *   ① 每次采集都新建一堆 ⇒ `maxStacks` 第 9 次就满，而玩家只捡了一种东西；
 *   ② 取到 0 的堆叠留成空壳 ⇒ 名额被残骸占满，同样表现为"背包满了但看起来很空"；
 *   ③ **先摘再进包** ⇒ 背包满时资源凭空消失：树倒了、计数自洽、玩家什么都没拿到。
 *   第三种最坏，因为画面上"树确实没了"，没有任何异常可看。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { registerResourceComponent, RESOURCE_TYPE, ResourceMarker } from "../../src/extensions/worldgen/task-module.ts";
import {
  INVENTORY_BAD_COUNT,
  INVENTORY_FULL,
  INVENTORY_NOT_ENOUGH,
  INVENTORY_NO_OWNER,
  INVENTORY_TYPE,
  ITEM_TYPE,
  addItem,
  countItem,
  makeInventory,
  registerInventoryComponents,
  stacksOf,
  takeItem,
  type Inventory,
} from "../../src/extensions/inventory/inventory.ts";
import { harvestInto } from "../../src/extensions/inventory/harvest-into.ts";
import { peekResourceAt } from "../../src/extensions/worldgen/harvest.ts";
import { loadScene, saveScene, sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";

function makeScene(withWorld = false): Scene {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerInventoryComponents(reg);
  const scene = new Scene("inv", reg);
  if (withWorld) {
    const g = generateWorld({ seed: 7, width: 16, height: 12, maxSitesPerCell: 0 });
    assert.ok(g.ok);
    assert.ok(assembleWorld(g.value, scene).ok);
  }
  return scene;
}

function makeOwner(scene: Scene, maxStacks = 8, maxStack = 40): number {
  const r = scene.spawn("hero", null);
  assert.ok(r.ok);
  scene.flush(); // spawn 只是入队：不 flush 的话节点还不在场景里
  const inv = makeInventory(scene, r.value.id, maxStacks, maxStack);
  assert.ok(inv.ok, inv.ok ? "" : `${inv.error.code}`);
  return r.value.id;
}

// ── ① 合并 ───────────────────────────────────────────────────

test("★★ 同种物品加两次：一个堆叠、数量累加（不是两个节点）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene);
  assert.ok(addItem(scene, owner, "tree", 3).ok);
  assert.ok(addItem(scene, owner, "tree", 2).ok);
  assert.equal(countItem(scene, owner, "tree"), 5);
  const stacks = stacksOf(scene, owner);
  assert.equal(stacks.length, 1, `有 ${stacks.length} 个堆叠 —— 每次采集都新建一堆的话，第 9 次就报满了`);
  assert.equal(stacks[0]!.count, 5);
});

test("不同种类各自一堆，互不合并", () => {
  const scene = makeScene();
  const owner = makeOwner(scene);
  assert.ok(addItem(scene, owner, "tree", 1).ok);
  assert.ok(addItem(scene, owner, "rock", 1).ok);
  assert.equal(stacksOf(scene, owner).length, 2);
  assert.equal(countItem(scene, owner, "tree"), 1);
  assert.equal(countItem(scene, owner, "rock"), 1);
});

// ── ② 名额 ───────────────────────────────────────────────────

test("★ 堆叠到上限再加**新种类**报 FULL，且场景一点都没动", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 2);
  assert.ok(addItem(scene, owner, "a", 1).ok);
  assert.ok(addItem(scene, owner, "b", 1).ok);
  const nodesBefore = scene.stats().nodes;

  const r = addItem(scene, owner, "c", 1);
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, INVENTORY_FULL);
  assert.equal(scene.stats().nodes, nodesBefore, "报满了却还是建了节点");
  assert.equal(stacksOf(scene, owner).length, 2);
});

test("★ 满了之后加**已有种类**仍然可以（合并不占名额）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 1);
  assert.ok(addItem(scene, owner, "a", 1).ok);
  const r = addItem(scene, owner, "a", 4);
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  assert.equal(countItem(scene, owner, "a"), 5);
});

// ── ② 单堆上限（maxStack：每格几个）────────────────────────────

test("★★ 单堆到顶自动开新堆（45 个 ⇒ 40 + 5 两堆，总数一个不少）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 8, 40);
  const r = addItem(scene, owner, "tree", 45);
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  assert.equal(r.ok ? r.value : -1, 45, "返回值必须是这种物品的总数");
  const stacks = stacksOf(scene, owner);
  assert.equal(stacks.length, 2, `45 个 / 每堆 40 应该开 2 堆，实际 ${stacks.length}`);
  assert.deepEqual(
    stacks.map((s) => s.count).sort((a, b) => a - b),
    [5, 40],
  );
});

test("★★ 溢出装不下时**整体失败**：场景一点都没动（不许先改一半再失败）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 2, 40);
  assert.ok(addItem(scene, owner, "a", 40).ok);
  const nodesBefore = scene.stats().nodes;
  const countsBefore = stacksOf(scene, owner).map((s) => `${s.kind}:${s.count}`);

  // 已有 1 堆 40 个，加 41 个需要 2 个新堆，但只剩 1 个名额 ⇒ 必须整体失败
  const r = addItem(scene, owner, "a", 41);
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, INVENTORY_FULL);
  assert.equal(scene.stats().nodes, nodesBefore, "失败路径还是建了节点");
  assert.deepEqual(
    stacksOf(scene, owner).map((s) => `${s.kind}:${s.count}`),
    countsBefore,
    "原堆叠被改过了 —— 「先合并再发现没名额」会把数量改成猜谜",
  );
  assert.equal(countItem(scene, owner, "a"), 40);
});

test("★★ 合并先填**所有**同种堆（满堆 + 半堆时不许跳过半堆直接开新堆）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 8, 40);
  assert.ok(addItem(scene, owner, "a", 40).ok); // 第一堆：满
  assert.ok(addItem(scene, owner, "a", 10).ok); // 第二堆：10
  const r = addItem(scene, owner, "a", 5);
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  const stacks = stacksOf(scene, owner);
  assert.equal(stacks.length, 2, "半堆还有 30 个空位，却开了第三堆 —— 名额被白白浪费");
  assert.deepEqual(
    stacks.map((s) => s.count).sort((x, y) => x - y),
    [15, 40],
  );
});

test("★ maxStack=1 的极端配置仍然自洽（一个物品一堆）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 3, 1);
  assert.ok(addItem(scene, owner, "a", 2).ok);
  assert.equal(stacksOf(scene, owner).length, 2);
  const r = addItem(scene, owner, "a", 2); // 只剩 1 个名额，还差 1 堆
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, INVENTORY_FULL);
  assert.equal(countItem(scene, owner, "a"), 2, "失败的尝试还是塞了东西进去");
});

test("★ 存档里的坏 maxStack（0）当 1 用：宁可立刻暴露，不假装正常", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 8, 0);
  // 0 = 每堆 0 个 ⇒ 一个都装不下才对；但"当成 1"更诚实：行为立刻变得可疑（疯狂开新堆）
  const r = addItem(scene, owner, "a", 1);
  assert.ok(r.ok, r.ok ? "" : r.error.code);
  const stacks = stacksOf(scene, owner);
  assert.equal(stacks.length, 1);
  assert.equal(stacks[0]!.count, 1, "坏 maxStack 下的堆叠数量不对");
});

test("★★ 两层上限都能过存档：maxStack / maxStacks 存 → 读 → 都在", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 6, 40);
  assert.ok(addItem(scene, owner, "tree", 45).ok);
  const json = sceneToJson(saveScene(scene));
  const back = sceneFromJson(json);
  assert.ok(back.ok);
  // ★ 注册表要单独建一份：两张场景各持一份，才能证明"字段是从存档里读出来的"
  //   而不是"碰巧还在同一个 registry 里"
  const reg2 = new ComponentRegistry();
  registerWorldComponents(reg2);
  registerResourceComponent(reg2);
  registerInventoryComponents(reg2);
  const scene2 = new Scene("inv2", reg2);
  assert.ok(loadScene(scene2, back.value, reg2).ok);
  const invs = [...scene2.componentsOf<Inventory>(INVENTORY_TYPE)];
  assert.equal(invs.length, 1);
  assert.equal(invs[0]!.maxStacks, 6, "maxStacks 没过档");
  assert.equal(invs[0]!.maxStack, 40, "maxStack 没过档 —— 新字段漏进 schema 的症状是「读档后每堆无上限」");
  assert.equal(countItem(scene2, owner, "tree"), 45, "两堆同种没过档");
});

// ── ③ 取出与释放 ─────────────────────────────────────────────

test("★★ 取到 0 的堆叠销毁节点（空壳不许占名额）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene, 2);
  assert.ok(addItem(scene, owner, "a", 2).ok);
  const before = scene.stats().nodes;
  assert.ok(takeItem(scene, owner, "a", 2).ok);
  assert.equal(countItem(scene, owner, "a"), 0);
  assert.equal(stacksOf(scene, owner).length, 0, "空壳还在 —— 名额被残骸占着，玩家看到的是「背包满了但里面没东西」");
  assert.ok(scene.stats().nodes < before);
});

test("取超过存量报 NOT_ENOUGH，且数量不变（不许扣一半）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene);
  assert.ok(addItem(scene, owner, "a", 3).ok);
  const r = takeItem(scene, owner, "a", 5);
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, INVENTORY_NOT_ENOUGH);
  assert.equal(countItem(scene, owner, "a"), 3);
});

test("数量非正整数报 BAD_COUNT（0 与小数都不许悄悄变成「什么也没做」）", () => {
  const scene = makeScene();
  const owner = makeOwner(scene);
  for (const bad of [0, -1, 1.5, Number.NaN]) {
    const a = addItem(scene, owner, "a", bad);
    assert.ok(!a.ok, `加 ${String(bad)} 居然成功了`);
    if (!a.ok) assert.equal(a.error.code, INVENTORY_BAD_COUNT);
    const t = takeItem(scene, owner, "a", bad);
    assert.ok(!t.ok);
    if (!t.ok) assert.equal(t.error.code, INVENTORY_BAD_COUNT);
  }
  assert.equal(countItem(scene, owner, "a"), 0);
});

test("没有背包组件的节点报 NO_OWNER（不是静默成功）", () => {
  const scene = makeScene();
  const r = scene.spawn("bare", null);
  assert.ok(r.ok);
  scene.flush();
  const a = addItem(scene, r.value.id, "a", 1);
  assert.ok(!a.ok);
  if (!a.ok) assert.equal(a.error.code, INVENTORY_NO_OWNER);
  assert.equal(scene.countOf(ITEM_TYPE), 0);
});

test("makeInventory 是幂等的：挂两次只有一个组件", () => {
  const scene = makeScene();
  const owner = makeOwner(scene);
  const again = makeInventory(scene, owner, 3);
  assert.ok(again.ok);
  assert.equal(again.value.maxStacks, 8, "第二次调用把上限改了 —— 幂等应该是「什么都不动」");
});

// ── ④ 采集 → 背包闭环 ───────────────────────────────────────

test("★★ 闭环：采一个资源 ⇒ 世界侧少一个节点 + 背包侧多一个物品", () => {
  const scene = makeScene(true);
  const owner = makeOwner(scene);
  // 没有任务模块，就手工放一个资源：借用装配好的地形坐标
  const cell = 5 * 16 + 5;
  const spawned = scene.spawn("resource/tree", null);
  assert.ok(spawned.ok);
  scene.flush();
  spawned.value.setLocalPosition(5.5, 5.5);
  const made = scene.attach(spawned.value.id, () => {
    const m = new ResourceMarker();
    m.cell = cell;
    m.kind = "tree";
    return m;
  });
  assert.ok(made.ok);
  scene.flush();
  assert.equal(scene.countOf(RESOURCE_TYPE), 1);
  assert.deepEqual(peekResourceAt(scene, cell)?.kind, "tree", "peek 看不到刚放下的资源");

  const r = harvestInto(scene, cell, owner);
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.equal(countItem(scene, owner, "tree"), 1);
  assert.equal(scene.countOf(RESOURCE_TYPE), 0, "资源节点还在 —— 采了等于没采");
  assert.equal(peekResourceAt(scene, cell), null);
});

test("★★ 背包满时采集**不许白摘**：报 FULL 且资源还在原地", () => {
  const scene = makeScene(true);
  const owner = makeOwner(scene, 1);
  assert.ok(addItem(scene, owner, "rock", 1).ok); // 占掉唯一的堆叠名额

  const cell = 6 * 16 + 6;
  const spawned = scene.spawn("resource/tree", null);
  assert.ok(spawned.ok);
  scene.flush();
  spawned.value.setLocalPosition(6.5, 6.5);
  assert.ok(
    scene.attach(spawned.value.id, () => {
      const m = new ResourceMarker();
      m.cell = cell;
      m.kind = "tree";
      return m;
    }).ok,
  );
  scene.flush();

  const r = harvestInto(scene, cell, owner);
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, INVENTORY_FULL);
  // ★ 关键：资源必须还在（先看 → 再进包 → 最后摘）
  assert.equal(scene.countOf(RESOURCE_TYPE), 1, "背包满了却把资源摘掉了 —— 东西凭空消失，画面上只是树倒了");
  assert.deepEqual(peekResourceAt(scene, cell)?.kind, "tree");
});

// ── ⑤ 存档往返 ───────────────────────────────────────────────

test("★★ 背包能过存档：存 → 读 → 种类与数量都在（含「两堆同种」这种非常规形状）", () => {
  const scene = makeScene();
  const reg = (scene as unknown as { components: ComponentRegistry }).components;
  const owner = makeOwner(scene);
  assert.ok(addItem(scene, owner, "tree", 3).ok);
  assert.ok(addItem(scene, owner, "rock", 7).ok);
  assert.ok(addItem(scene, owner, "tree", 2).ok); // 合并进第一堆 ⇒ tree 共 5
  assert.equal(countItem(scene, owner, "tree"), 5);

  const json = sceneToJson(saveScene(scene));
  const snap = sceneFromJson(json);
  assert.ok(snap.ok, snap.ok ? "" : `${snap.error.code} ${snap.error.message}`);

  const fresh = new Scene("inv2", reg);
  const loaded = loadScene(fresh, snap.value, reg);
  assert.ok(loaded.ok, loaded.ok ? "" : `${loaded.error.code} ${loaded.error.message}`);

  // 拥有者是 id 最小的那个非根节点；直接按名字找更稳
  let heroId = -1;
  fresh.root.walk((n) => {
    if (heroId < 0 && n.name === "hero") heroId = n.id;
  });
  assert.ok(heroId > 0, "读档后找不到 hero");
  assert.equal(countItem(fresh, heroId, "tree"), 5, "读档后木头数量不对");
  assert.equal(countItem(fresh, heroId, "rock"), 7);
  assert.equal(stacksOf(fresh, heroId).length, 2, "堆叠数变了 —— 存档把「一堆」拆成了几堆");
});
