/**
 * L4 · 关卡流程：传送门的判据
 *
 * 这一组盯的是**"什么时候算走进了另一扇门"**。四条最容易做错的：
 *
 *  ① 站着不动就重复触发（"距离 < 半径就跳"的直觉实现）—— 在门里站两帧跳两次；
 *  ② 落地时已经在门里却没有 `reseed` —— A→B 一落地就立刻 B→A，来回弹；
 *  ③ 重叠时靠遍历顺序选门 —— 同一次点击在两次运行里跳向不同场景；
 *  ④ 半径/坐标用浮点 —— 边界判据只能写"大约"，而"门刚好差一点"是作者会踩的坑。
 *
 * ★ 这一组全部是**纯函数 + 纯状态机**，不需要场景就能跑 —— 除了 `collectPortals`
 *   （它要从真实节点上取世界坐标）。分开写是刻意的："读场景"和"判断跨越"是两种失效。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { FIXED_UNITS } from "../../src/extensions/worldgen/worldgen.ts";
import {
  FLOW_PORTAL_BAD_RADIUS,
  FLOW_PORTAL_DUPLICATE,
  FLOW_PORTAL_NO_TARGET,
  PORTAL_DEFAULT_RADIUS,
  PORTAL_TYPE,
  Portal,
  PortalWatcher,
  collectPortals,
  hitTestPortals,
  registerPortalComponent,
  type PortalSpec,
} from "../../src/extensions/flow/portal.ts";

const F = FIXED_UNITS;

function spec(
  name: string,
  x: number,
  z: number,
  radius = F,
  to = "b",
  extra: Partial<PortalSpec> = {},
): PortalSpec {
  return {
    name,
    to,
    radius,
    open: true,
    requires: "",
    requiresCount: 1,
    consume: false,
    x,
    z,
    ...extra,
  };
}

function setup(): { scene: Scene; registry: ComponentRegistry } {
  const registry = new ComponentRegistry();
  registerPortalComponent(registry);
  const scene = new Scene("main", registry);
  return { scene, registry };
}

/** 在场景里造一扇门。坐标按定点给，`worldPositionOf` 的输入是格单位。 */
function makePortal(
  scene: Scene,
  name: string,
  x: number,
  z: number,
  to = "b",
  radius?: number,
): number {
  const n = scene.spawnImmediate(name, scene.rootId);
  scene.flush();
  const r = scene.attach(n.id, () => {
    const p = new Portal();
    p.to = to;
    // `undefined` = 不设，用组件自己的出生默认值（第一条判据要验的就是它）
    if (radius !== undefined) p.radius = radius;
    return p;
  });
  assert.ok(r.ok, `挂传送门组件失败：${r.ok ? "" : r.error.message}`);
  n.setLocalPosition(x / F, z / F);
  scene.flush();
  return n.id;
}

// ---------------------------------------------------------------- collectPortals

test("传送门：从场景读出规格（坐标是定点整数，默认半径 1.5 格）", () => {
  const { scene } = setup();
  makePortal(scene, "door-a", 3 * F, 4 * F);
  const r = collectPortals(scene);
  assert.ok(r.ok, r.ok ? "" : r.error.message);
  assert.equal(r.value.length, 1);
  const p = r.value[0]!;
  assert.equal(p.name, "door-a");
  assert.equal(p.to, "b");
  assert.equal(p.x, 3 * F);
  assert.equal(p.z, 4 * F);
  assert.equal(p.radius, PORTAL_DEFAULT_RADIUS);
  assert.equal(p.radius, (F * 3) / 2, "缺省半径必须是 1.5 格");
});

test("传送门：没写目标场景是错误（不是「默认跳第一个场景」）", () => {
  const { scene } = setup();
  makePortal(scene, "door-a", 0, 0, "");
  const r = collectPortals(scene);
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, FLOW_PORTAL_NO_TARGET);
});

test("传送门：半径 0 / 负数 / 小数都是错误（那扇门永远不会触发）", () => {
  for (const bad of [0, -F, 1.5 as number, Number.NaN]) {
    const { scene } = setup();
    makePortal(scene, "door-a", 0, 0, "b", bad);
    const r = collectPortals(scene);
    assert.equal(r.ok, false, `半径 ${String(bad)} 应该被拒绝`);
    assert.equal(r.ok ? "" : r.error.code, FLOW_PORTAL_BAD_RADIUS, `半径 ${String(bad)} 的错误码`);
  }
});

test("传送门：两扇门重名是错误（名字是「上一刻在哪扇门里」的身份）", () => {
  const { scene } = setup();
  makePortal(scene, "same", 0, 0);
  makePortal(scene, "same", 5 * F, 0);
  const r = collectPortals(scene);
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, FLOW_PORTAL_DUPLICATE);
});

test("传送门：规格按名字升序（重叠时的兜底顺序不能取决于挂载顺序）", () => {
  const { scene } = setup();
  makePortal(scene, "zzz", 0, 0);
  makePortal(scene, "aaa", F, 0);
  makePortal(scene, "mmm", 2 * F, 0);
  const r = collectPortals(scene);
  assert.ok(r.ok, r.ok ? "" : r.error.message);
  assert.deepEqual(
    r.value.map((p) => p.name),
    ["aaa", "mmm", "zzz"],
  );
});

test("传送门：组件字段能存档往返（门锁那几个字段一起进档）", () => {
  const p = new Portal();
  p.to = "forest";
  p.radius = 640;
  p.open = false;
  p.requires = "wood";
  p.requiresCount = 3;
  p.consume = true;
  const saved = p.save();
  // ★ 字段**顺序即序列化顺序**，所以这里必须逐字段比 —— 只写 `deepEqual(saved)`
  //   而不写期望对象的话，"少存一个字段"这种错会被漏掉（对象多出来的键不会被检查）。
  assert.deepEqual(saved, {
    type: PORTAL_TYPE,
    to: "forest",
    radius: 640,
    open: false,
    requires: "wood",
    requiresCount: 3,
    consume: true,
  });
  const back = new Portal();
  const miss = back.load(saved);
  assert.deepEqual(miss.missing, []);
  assert.equal(back.to, "forest");
  assert.equal(back.radius, 640);
  assert.equal(back.open, false, "关着的门读回来还是关着的");
  assert.equal(back.requires, "wood");
  assert.equal(back.requiresCount, 3);
  assert.equal(back.consume, true);
});

// ---------------------------------------------------------------- hitTest

test("传送门：边界是闭区间（距离恰好等于半径算在里面，多 1 定点单位就不算）", () => {
  const p = spec("a", 0, 0, 10);
  assert.equal(hitTestPortals(10, 0, [p]).length, 1, "dx=r 在圈内");
  assert.equal(hitTestPortals(0, -10, [p]).length, 1, "dz=-r 在圈内");
  assert.equal(hitTestPortals(11, 0, [p]).length, 0, "多 1 就不算");
  // 勾股：6-8-10 恰好落在边界上
  assert.equal(hitTestPortals(6, 8, [p]).length, 1, "3-4-5 的 2 倍恰好等于半径");
  assert.equal(hitTestPortals(7, 8, [p]).length, 0, "r²=113 > 100");
});

test("传送门：重叠时最近的在前；距离相同按名字升序", () => {
  const near = spec("near", 10, 0, 50);
  const far = spec("far", 30, 0, 50);
  assert.deepEqual(
    hitTestPortals(12, 0, [far, near]).map((h) => h.portal.name),
    ["near", "far"],
  );
  // 同一个点、同样半径 ⇒ 距离相同，按名字
  const b = spec("bbb", 0, 0, 50);
  const a = spec("aaa", 0, 0, 50);
  assert.deepEqual(
    hitTestPortals(0, 0, [b, a]).map((h) => h.portal.name),
    ["aaa", "bbb"],
  );
});

// ---------------------------------------------------------------- PortalWatcher

test("传送门：站在门里连续喂 10 次只触发一次（边沿，不是电平）", () => {
  const w = new PortalWatcher();
  const p = spec("a", 0, 0, 100);
  let n = 0;
  for (let i = 0; i < 10; i++) if (w.enter(5, 5, [p]) !== null) n++;
  assert.equal(n, 1, "10 次里面只该有 1 次跨越");
  assert.equal(w.insideKey, "a");
});

test("传送门：走出去再进来会再触发一次", () => {
  const w = new PortalWatcher();
  const p = spec("a", 0, 0, 100);
  assert.notEqual(w.enter(0, 0, [p]), null);
  assert.equal(w.enter(1000, 0, [p]), null, "走出去不触发");
  assert.equal(w.insideKey, null);
  assert.notEqual(w.enter(0, 0, [p]), null, "再进来要触发");
});

test("传送门：从一扇门直接跨到另一扇门也会触发（最近的那扇换了）", () => {
  const w = new PortalWatcher();
  const a = spec("a", 0, 0, 100);
  const b = spec("b", 300, 0, 100);
  assert.equal(w.enter(0, 0, [a, b])?.portal.name, "a");
  const hit = w.enter(300, 0, [a, b]);
  assert.equal(hit?.portal.name, "b", "两扇门不重叠时，跨过去就该触发新的那扇");
});

test("传送门：一扇门叠进另一扇门里时，触发「更近的那扇」", () => {
  const w = new PortalWatcher();
  const a = spec("a", 0, 0, 200);
  const b = spec("b", 40, 0, 200);
  assert.equal(w.enter(0, 0, [a, b])?.portal.name, "a", "先站在 a 里");
  // 走到 b 的门心：仍在 a 的范围内（距离 40 < 200），但 b 更近
  const hit = w.enter(40, 0, [a, b]);
  assert.equal(hit?.portal.name, "b");
  assert.equal(hit?.distance2, 0);
});

test("传送门：走进重叠区、但最近的门没变 ⇒ 不触发（否则在门口挪一步就跳一次）", () => {
  // ★ 这一条钉的是"身份记的是**最近的那扇**"：两门重叠时覆盖集合会变（{a} → {a,b}），
  //   但玩家脚下最近的那扇还是 a。按集合记身份的话这里会误触发 ——
  //   而"在门口蹭两步就掉进另一个场景"是玩家最容易遇到的一种怪事。
  const w = new PortalWatcher();
  const a = spec("a", 0, 0, 200);
  const b = spec("b", 300, 0, 200);
  assert.equal(w.enter(0, 0, [a, b])?.portal.name, "a");
  // (150,0) 到两扇门都是 150（平手按名字 ⇒ 仍然是 a），而它已经在两门的重叠区里
  assert.equal(w.enter(150, 0, [a, b]), null, "最近的门还是 a，不许触发");
  assert.equal(w.insideKey, "a");
});

test("传送门：reseed 之后落在门里不算跨进来（否则两扇门互相对接就会无限回弹）", () => {
  const w = new PortalWatcher();
  const p = spec("a", 0, 0, 100);
  w.reseed(0, 0, [p]);
  assert.equal(w.enter(0, 0, [p]), null, "落地就在门里，不许触发");
  assert.equal(w.insideKey, "a");
  // 但走出去再回来仍然触发 —— reseed 只吃掉"落地那一次"
  assert.equal(w.enter(1000, 0, [p]), null);
  assert.notEqual(w.enter(0, 0, [p]), null);
});

test("传送门：reset 之后忘掉位置（世界被换掉时用）", () => {
  const w = new PortalWatcher();
  const p = spec("a", 0, 0, 100);
  assert.notEqual(w.enter(0, 0, [p]), null);
  w.reset();
  assert.equal(w.insideKey, null);
  assert.notEqual(w.enter(0, 0, [p]), null, "reset 之后同一位置算「跨进来」");
});

test("传送门：reseed 到没有门的地方 ⇒ 下一次 enter 正常触发（不是永久免疫）", () => {
  const w = new PortalWatcher();
  const p = spec("a", 0, 0, 100);
  w.reseed(1000, 1000, [p]);
  assert.equal(w.insideKey, null);
  assert.notEqual(w.enter(0, 0, [p]), null);
});
