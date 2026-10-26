/**
 * L4 · 编辑器：画布拖拽（gizmo）的判据
 *
 * 这一组里最值钱的是第 3 段：**父节点带偏移、再带旋转**时拖拽仍然对。
 * 原因是编辑器日常里 99% 的节点挂在根下（父是恒等变换），
 * 漏掉「世界 → 局部」那次换算也照样能用 —— 直到有人把箱子挂到一棵
 * 已经摆好位置的货架下面，然后一拖它跳到别处。
 *
 * 其余几条覆盖三类"看起来成功"：
 *   · 位移为 0 也压一条历史 ⇒ 按一次撤销什么都没发生；
 *   · 命中测试不排序 ⇒ 重叠时选到"先创建的那个"，而不是画面上看得见的那个；
 *   · 位置 op 不推进变换版本 ⇒ 逻辑坐标回去了、画面还在新位置。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { NodeId } from "../../src/core/scene/node.ts";
import { createUndoStack } from "../../src/extensions/editor/undo-stack.ts";
import { EDIT_BAD_DRAG, beginDrag, dragTarget, endDrag, pickAt, worldToLocal } from "../../src/extensions/editor/gizmo.ts";

function makeScene(): { scene: Scene; a: NodeId; b: NodeId } {
  const scene = new Scene("gizmo", new ComponentRegistry());
  // a 在原点，b 在 (2, 0)：两个都挂在根下，用来做命中测试
  const a = scene.spawnImmediate("A", scene.rootId);
  const b = scene.spawnImmediate("B", scene.rootId);
  a.setLocalPosition(0, 0);
  b.setLocalPosition(2, 0);
  scene.flush();
  return { scene, a: a.id, b: b.id };
}

function posOf(scene: Scene, id: NodeId): { x: number; y: number } {
  const n = scene.find(id);
  assert.ok(n !== undefined, `节点 #${String(id)} 不见了`);
  return { x: n.localPosition.x, y: n.localPosition.y };
}

function codeOf(r: { ok: boolean }): string {
  assert.equal(r.ok, false, "这一步本应失败");
  return (r as unknown as { error: { code: string } }).error.code;
}

const near = (a: number, b: number, eps = 1e-9): boolean => Math.abs(a - b) <= eps;

// ---------------------------------------------------------------- 命中测试

test("[拖拽] 点在节点上就选中它，点在空地返回 undefined", () => {
  const { scene, a } = makeScene();
  assert.equal(pickAt(scene, 0, 0), a);
  // 空地在两个节点之间：半径 0.55 够不到任何一边
  assert.equal(pickAt(scene, 1, 0), undefined, "空地上不该命中（半径漏成无限大就是这个症状）");
});

test("★ 命中测试不许选中场景根", () => {
  const { scene } = makeScene();
  // 根的世界位置是 (0,0)，和 A 重合 —— 但根不是可拖的东西
  assert.notEqual(pickAt(scene, 0, 0), scene.rootId);
});

test("★★ 两个节点重叠时选**画面上压在上面**的那个（zIndex 高），不是先创建的那个", () => {
  const { scene, a, b } = makeScene();
  const nb = scene.find(b);
  assert.ok(nb !== undefined);
  nb.setLocalPosition(0, 0); // b 挪到和 a 完全重合
  // 默认两者 zIndex 都是 0 ⇒ 按 id 升序 ⇒ 选 a（先创建）
  assert.equal(pickAt(scene, 0, 0), a);
  // 把**后创建**的 b 抬到上面：这时必须选 b
  nb.zIndex = 5;
  assert.equal(pickAt(scene, 0, 0), b, "重叠时选错了对象（zIndex 没参与排序）");
});

test("★ 隐藏（active=false）的节点点不中", () => {
  const { scene, a } = makeScene();
  const na = scene.find(a);
  assert.ok(na !== undefined);
  na.active = false;
  assert.equal(pickAt(scene, 0, 0), undefined, "看不见的东西被点中了");
});

// ---------------------------------------------------------------- 拖拽增量

test("★★ 抓哪拖哪：抓在节点边缘拖 (+1, +2)，节点整体位移 (+1, +2)，不是跳到光标", () => {
  const { scene, a } = makeScene();
  // 在 A 的右侧 0.4 格按下（仍在 0.55 的命中半径内）
  const r = beginDrag(scene, a, 0.4, 0);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const to = dragTarget(r.value, 1.4, 2);
  assert.equal(near(to.x, 1), true, `x=${String(to.x)}（1 = 抓在 0.4 处、拖到 1.4 处，位移正好 1）`);
  assert.equal(near(to.y, 2), true, `y=${String(to.y)}`);
});

test("★★★ 父节点带偏移时，抓哪拖哪（这条抓的是 `grabU` 忘了换算，不是增量换算）", () => {
  // ★★ 一个容易高估的事实：**父节点只有平移时，世界增量恰好等于局部位移**，
  //    所以"漏掉 世界→局部 换算"的写法在这里**照样通过**（实测过）。
  //    真正能暴露增量换算的是下一条（父带旋转）。这条守的是另一个入口：
  //    按下点的偏移 `grabU` 如果直接用世界坐标，这里会得到 10 而不是 0。
  const { scene } = makeScene();
  const parent = scene.spawnImmediate("货架", scene.rootId);
  parent.setLocalPosition(10, 5);
  const box = scene.spawnImmediate("箱子", parent.id);
  scene.flush();

  const world = { x: 10, y: 5 }; // 箱子世界位置 = 父的世界位置（局部是 0,0）
  const r = beginDrag(scene, box.id, world.x, world.y);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const to = dragTarget(r.value, world.x + 1, world.y + 1);
  assert.equal(near(to.x, 1), true, `局部 x=${String(to.x)}（1 才对；10 说明把世界坐标当成了局部）`);
  assert.equal(near(to.y, 1), true, `局部 y=${String(to.y)}`);
});

test("★★★ 父节点旋转 45° 时，世界 +x 的拖动对应局部 (0.707, -0.707)", () => {
  const { scene } = makeScene();
  const parent = scene.spawnImmediate("转过的台面", scene.rootId);
  parent.setLocalRotation(Math.PI / 4);
  const box = scene.spawnImmediate("箱子", parent.id);
  scene.flush();

  const w = { x: 0, y: 0 };
  const r = beginDrag(scene, box.id, w.x, w.y);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const to = dragTarget(r.value, 1, 0);
  const k = Math.SQRT1_2; // 0.7071...
  assert.equal(near(to.x, k, 1e-9), true, `局部 x=${String(to.x)}，期望 ${String(k)}`);
  assert.equal(near(to.y, -k, 1e-9), true, `局部 y=${String(to.y)}，期望 ${String(-k)}`);
});

test("★ 吸附：snap=0.5 时位置落在半格上", () => {
  const { scene, a } = makeScene();
  const r = beginDrag(scene, a, 0, 0);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const to = dragTarget(r.value, 1.3, 0.8, 0.5);
  assert.equal(near(to.x, 1.5), true, `x=${String(to.x)}`);
  assert.equal(near(to.y, 1.0), true, `y=${String(to.y)}`);
});

// ---------------------------------------------------------------- 收尾与撤销

test("★★ 位移为 0 时不产生历史（否则按一次撤销什么都没发生）", () => {
  const { scene, a } = makeScene();
  const r = beginDrag(scene, a, 0, 0);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const same = endDrag(scene, r.value, r.value.fromX, r.value.fromY);
  assert.equal(same.ok, true, same.ok ? "" : same.error.code);
  assert.equal(same.ok ? same.value : "x", undefined, "没动也压了一条历史");
});

test("★★ 拖完一条 op：撤销回到原位，重做回到新位", () => {
  const { scene, a } = makeScene();
  const h = createUndoStack();
  const r = beginDrag(scene, a, 0, 0);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const to = dragTarget(r.value, 3, -2);
  const made = endDrag(scene, r.value, to.x, to.y);
  assert.equal(made.ok, true, made.ok ? "" : made.error.code);
  if (!made.ok || made.value === undefined) {
    assert.fail("没产出 op");
    return;
  }
  const op = made.value;
  scene.find(a)?.setLocalPosition(to.x, to.y); // 模拟拖拽过程中已经写进场景
  h.push(op);
  assert.equal(h.undo().kind, "done");
  assert.deepEqual(posOf(scene, a), { x: 0, y: 0 }, "撤销之后位置没回去");
  assert.equal(h.redo().kind, "done");
  assert.equal(near(posOf(scene, a).x, 3), true);
  assert.equal(near(posOf(scene, a).y, -2), true);
});

test("★ 位置改完世界变换要跟着走（不推进版本号的话画面会停在旧位置）", () => {
  const { scene, a } = makeScene();
  const n = scene.find(a);
  assert.ok(n !== undefined);
  const before = n.worldPosition;
  const r = beginDrag(scene, a, 0, 0);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const to = dragTarget(r.value, 4, 0);
  const made = endDrag(scene, r.value, to.x, to.y);
  assert.equal(made.ok, true);
  if (!made.ok || made.value === undefined) {
    assert.fail("没产出 op");
    return;
  }
  assert.equal(made.value.apply().ok, true);
  const after = n.worldPosition;
  assert.equal(near(after.x, 4, 1e-9), true, `world.x=${String(after.x)}（还是 ${String(before.x)} 说明缓存没失效）`);
});

// ---------------------------------------------------------------- 拒绝路径

test("★ 拖根节点、拖不存在的节点都要报错", () => {
  const { scene } = makeScene();
  assert.equal(codeOf(beginDrag(scene, scene.rootId, 0, 0)), EDIT_BAD_DRAG);
  assert.equal(codeOf(beginDrag(scene, 9999 as NodeId, 0, 0)), EDIT_BAD_DRAG);
});

test("★★ 父节点把坐标轴压成 0：拒绝拖拽，而不是算出 NaN", () => {
  const { scene } = makeScene();
  const parent = scene.spawnImmediate("压扁的父", scene.rootId);
  parent.setLocalScale(0, 0);
  const box = scene.spawnImmediate("箱子", parent.id);
  scene.flush();
  assert.equal(codeOf(beginDrag(scene, box.id, 0, 0)), EDIT_BAD_DRAG);
  // 直接调换算也该返回 undefined（NaN 会一路渗进存档，是最难查的一类）
  assert.equal(worldToLocal({ m00: 0, m01: 0, m02: 0, m10: 0, m11: 0, m12: 0 }, 1, 1), undefined);
});

test("★ 拖拽过程中节点被删：收尾报错，而不是把位置写到别人身上", () => {
  const { scene, a } = makeScene();
  const r = beginDrag(scene, a, 0, 0);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  scene.destroy(a);
  scene.flush();
  assert.equal(codeOf(endDrag(scene, r.value, 1, 1)), EDIT_BAD_DRAG);
});
