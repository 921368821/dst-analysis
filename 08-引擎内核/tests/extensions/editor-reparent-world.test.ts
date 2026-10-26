/**
 * L4 · 编辑器：换父要**保住世界位置**（批85）
 *
 * ★ 为什么单独一个文件而不并进 `editor-undo.test.ts`：那边验的是"历史的排布与反向"，
 *   这一批改的是**换父的语义本身** —— 换父会重算 `localPosition`。
 *   两者的失败模式完全不同：历史错了是"撤不回去"，语义错了是"层级对了、位置错了"，
 *   而后者看起来更像"当初就是这样"，更难发现。
 *
 * ★ 有一条判据专门钉**限制**（父带旋转时朝向会跟着新父走）。它不是在测 bug，
 *   而是在防止下一个人以为"世界变换整个被保住了" —— 只保位置是有意为之。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { NodeId } from "../../src/core/scene/node.ts";
import { EDIT_BAD_PARENT, reparentWithUndo } from "../../src/extensions/editor/undo-ops.ts";

function mkScene(): Scene {
  return new Scene("editor", new ComponentRegistry());
}

function localOf(scene: Scene, id: NodeId): { x: number; y: number } {
  const n = scene.find(id);
  assert.ok(n !== undefined, `节点 #${String(id)} 应该还在`);
  return { x: n.localPosition.x, y: n.localPosition.y };
}

function worldOf(scene: Scene, id: NodeId): { x: number; y: number } {
  const n = scene.find(id);
  assert.ok(n !== undefined, `节点 #${String(id)} 应该还在`);
  const p = n.worldPosition;
  return { x: p.x, y: p.y };
}

/** 世界朝向（弧度）：从世界变换的线性部分取，父的旋转会体现在这里。 */
function worldRotOf(scene: Scene, id: NodeId): number {
  const n = scene.find(id);
  assert.ok(n !== undefined);
  const t = n.worldTransform;
  return Math.atan2(t.m10, t.m00);
}

function parentOf(scene: Scene, id: NodeId): NodeId | undefined {
  return scene.find(id)?.parent?.id;
}

/**
 * 带旋转的用例只能用近似比较：45° 的 cos/sin 是 0.7071…，往返一次必然带 1e-16 级误差
 * （实测 `220` 回来变成 `219.99999999999997`）。**只在需要的地方放宽**：
 * 平移类用例仍然用 `deepEqual` 精确比 —— 那里算的是加减法，差一点点就是真的算错了。
 */
function assertNear(actual: { x: number; y: number }, expected: { x: number; y: number }, msg: string): void {
  const eps = 1e-9;
  assert.ok(
    Math.abs(actual.x - expected.x) < eps && Math.abs(actual.y - expected.y) < eps,
    `${msg}（实际 ${String(actual.x)},${String(actual.y)}，期望 ${String(expected.x)},${String(expected.y)}）`,
  );
}

/**
 * A(100,200) 与 B(300,400) 都挂在根下，C(10,20) 挂在 A 下 ⇒ C 的世界位置 (110,220)。
 */
function mkTree(scene: Scene): { a: NodeId; b: NodeId; c: NodeId } {
  const a = scene.spawnImmediate("A", scene.rootId, 10);
  const b = scene.spawnImmediate("B", scene.rootId, 11);
  const c = scene.spawnImmediate("C", a.id, 12);
  const an = scene.find(a.id);
  const bn = scene.find(b.id);
  const cn = scene.find(c.id);
  assert.ok(an !== undefined && bn !== undefined && cn !== undefined);
  an.setLocalPosition(100, 200);
  bn.setLocalPosition(300, 400);
  cn.setLocalPosition(10, 20);
  return { a: a.id, b: b.id, c: c.id };
}

test("[换父·世界位置] 新父带偏移：换父后世界位置不动，局部坐标被重算", () => {
  const scene = mkScene();
  const { b, c } = mkTree(scene);
  assert.deepEqual(worldOf(scene, c), { x: 110, y: 220 }, "前置：C 现在在 A 下的世界位置");

  const r = reparentWithUndo(scene, c, b);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);

  assert.equal(parentOf(scene, c), b, "父真的换了");
  // ★ 这一条是本批的核心：只改父子关系、不改局部坐标的话，这里会变成 (410,420) ——
  //   "拖到别的节点下面"变成"节点飞走了"。
  assert.deepEqual(worldOf(scene, c), { x: 110, y: 220 }, "世界位置必须一动不动");
  assert.deepEqual(localOf(scene, c), { x: -190, y: -180 }, "局部坐标要按新父重算（110-300, 220-400）");
});

test("[换父·世界位置] 撤销：父回到原处，世界位置也回到原处（局部坐标一起回）", () => {
  const scene = mkScene();
  const { a, b, c } = mkTree(scene);
  const r = reparentWithUndo(scene, c, b);
  assert.equal(r.ok, true);
  const op = r.ok ? r.value.op : null;
  assert.ok(op !== null);

  op.revert();
  assert.equal(parentOf(scene, c), a, "撤销要回到原来的父 A");
  // ★ 只回父子关系不回局部坐标的话，这里会是 (110,220) 之外的值：
  //   父对了、位置错了，而且错得很像"当初就是这样"。
  assert.deepEqual(localOf(scene, c), { x: 10, y: 20 }, "局部坐标要回到换父之前的那个值");
  assert.deepEqual(worldOf(scene, c), { x: 110, y: 220 }, "世界位置自然也跟着回");

  op.apply();
  assert.equal(parentOf(scene, c), b, "重做回到新父");
  assert.deepEqual(worldOf(scene, c), { x: 110, y: 220 }, "重做之后世界位置同样不能动");
  assert.deepEqual(localOf(scene, c), { x: -190, y: -180 });
});

test("[换父·世界位置] 挂到根下（newParent=null）也保世界位置", () => {
  const scene = mkScene();
  const { c } = mkTree(scene);
  const r = reparentWithUndo(scene, c, null);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assert.deepEqual(worldOf(scene, c), { x: 110, y: 220 }, "爬到根下不该改变它在画面上的位置");
  assert.deepEqual(localOf(scene, c), { x: 110, y: 220 }, "根是恒等，于是局部就等于世界");
});

test("[换父·世界位置] ★ 目标父把坐标轴压成 0：拒绝，且场景一个字节没动", () => {
  const scene = mkScene();
  const { a, b, c } = mkTree(scene);
  const bn = scene.find(b);
  assert.ok(bn !== undefined);
  bn.setLocalScale(0, 1); // 把 x 轴压成 0 ⇒ 无解

  const r = reparentWithUndo(scene, c, b);
  assert.equal(r.ok, false, "换算无解时必须拒绝");
  assert.equal(r.ok ? "" : r.error.code, EDIT_BAD_PARENT);
  // ★ 先算再改结构的证据：拒绝之后**父还挂在 A 下、局部坐标还是原来的**。
  //   反过来（先 reparent 再算）在这里会留下"父已经是 B、位置没跟上"的半截场景。
  assert.equal(parentOf(scene, c), a, "拒绝时不许先改父子关系");
  assert.deepEqual(localOf(scene, c), { x: 10, y: 20 }, "拒绝时局部坐标也不许动");
});

test("[换父·世界位置] ★ 限制：父带旋转时只保位置、不保朝向（写进判据，不藏在注释里）", () => {
  const scene = mkScene();
  const { a, b, c } = mkTree(scene);
  const bn = scene.find(b);
  assert.ok(bn !== undefined);
  bn.setLocalRotation(Math.PI / 4);

  const before = worldOf(scene, c);
  const r = reparentWithUndo(scene, c, b);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assertNear(worldOf(scene, c), before, "位置仍然保住");
  // 朝向会跟着新父走：C 自己的 localRotation 是 0，世界朝向等于父的 45°。
  // 这不是 bug，是"只保位置"的必然结果 —— 要保住整个世界变换得做极分解。
  assert.ok(Math.abs(worldRotOf(scene, c) - Math.PI / 4) < 1e-9, `世界朝向应变成 45°，实际 ${String(worldRotOf(scene, c))}`);
  // 顺带钉住：C 自己的局部旋转没有被偷偷改掉（改了就成"换父顺便改了节点自身属性"）。
  assert.equal(scene.find(c)?.localRotation, 0);
  assert.equal(scene.find(a)?.localRotation, 0, "原父 A 没被碰");
});

test("[换父·世界位置] 拒绝路径不受影响：挂到自己/后代、原地不动仍然报错", () => {
  const scene = mkScene();
  const { a, b, c } = mkTree(scene);
  const same = reparentWithUndo(scene, c, a);
  assert.equal(same.ok ? "" : same.error.code, EDIT_BAD_PARENT, "已经挂在 A 下");
  const cycle = reparentWithUndo(scene, a, c);
  assert.equal(cycle.ok ? "" : cycle.error.code, EDIT_BAD_PARENT, "挂到自己的后代下面会造环");
  // 两次拒绝都不能留下副作用
  assert.equal(parentOf(scene, c), a);
  assert.deepEqual(localOf(scene, a), { x: 100, y: 200 });
  assert.equal(parentOf(scene, b), scene.rootId);
});
