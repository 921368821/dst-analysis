/**
 * L4 · 编辑器：场景树快照
 *
 * ★ 顺序是这里最容易被当成"无所谓"的东西。`Node.children` 是插入序，
 *   而插入序在「销毁后重建 / 拖拽换父」之后与 id 序不一致 ——
 *   判据里直接构造"插入序与 id 序**相反**"的场景，否则两边恰好相同时也照样绿。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, FieldType, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { buildOutline, flattenOutline } from "../../src/extensions/editor/outline.ts";

class Marker extends Component {
  readonly schema: ComponentSchema = { type: "test.marker", fields: { v: FieldType.Int } };
  v = 1;
}

class Deco extends Component {
  readonly schema: ComponentSchema = { type: "render.deco", fields: { v: FieldType.Int } };
  v = 1;
}

function makeScene(): Scene {
  const reg = new ComponentRegistry();
  reg.register(new Marker().schema, () => new Marker());
  reg.register(new Deco().schema, () => new Deco());
  return new Scene("editor", reg);
}

function attach(scene: Scene, id: number, make: () => Component): void {
  const r = scene.attach(id, make);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  scene.flush();
}

test("[编辑器·树] 子节点按 id 升序，即使插入序相反", () => {
  const scene = makeScene();
  // ★ 故意让插入序 (11, 10, 9) 与 id 序 (9, 10, 11) 相反
  scene.spawnImmediate("c", scene.root.id, 11);
  scene.spawnImmediate("b", scene.root.id, 10);
  scene.spawnImmediate("a", scene.root.id, 9);
  assert.deepEqual(
    scene.root.children.map((x) => x.id),
    [11, 10, 9],
    "前置条件：场景里的插入序确实是倒的（否则这条判据测不出排序）",
  );

  const o = buildOutline(scene);
  assert.deepEqual(o.root.children.map((x) => x.id), [9, 10, 11]);
  assert.deepEqual(o.root.children.map((x) => x.name), ["a", "b", "c"]);
  assert.equal(o.count, 4, "根 + 3 个子节点");
  assert.equal(o.truncated, false);
});

test("[编辑器·树] 摊平是深度优先，且带层级深度", () => {
  const scene = makeScene();
  const a = scene.spawnImmediate("a", scene.root.id, 2);
  scene.spawnImmediate("a1", a.id, 4);
  scene.spawnImmediate("a2", a.id, 3);
  scene.spawnImmediate("b", scene.root.id, 5);

  const rows = flattenOutline(buildOutline(scene).root);
  assert.deepEqual(
    rows.map((r) => `${"  ".repeat(r.depth)}${r.node.name}`),
    ["__root__", "  a", "    a2", "    a1", "  b"],
    "a 的孩子按 id 升序（3 在 4 前），且 b 在 a 的整棵子树之后",
  );
});

test("[编辑器·树] skipTypes 连子树一起跳过，根不受影响", () => {
  const scene = makeScene();
  const deco = scene.spawnImmediate("deco", scene.root.id, 2);
  scene.spawnImmediate("deco-child", deco.id, 3);
  scene.spawnImmediate("keep", scene.root.id, 4);
  attach(scene, 2, () => new Deco());
  // 根上也挂一个被 skip 的类型：根必须还在（树要有锚）
  attach(scene, scene.root.id, () => new Deco());

  const o = buildOutline(scene, { skipTypes: ["render.deco"] });
  assert.deepEqual(o.root.children.map((x) => x.name), ["keep"], "被跳过的节点连同它的子树一起消失");
  assert.equal(o.count, 2, "根 + keep");
});

test("[编辑器·树] maxDepth 截断要留痕", () => {
  const scene = makeScene();
  const a = scene.spawnImmediate("a", scene.root.id, 2);
  scene.spawnImmediate("a1", a.id, 3);

  const o = buildOutline(scene, { maxDepth: 1 });
  assert.equal(o.root.children[0]?.children.length, 0, "深度上限之外不再展开");
  assert.equal(o.truncated, true, "少画了东西必须能被人看见，否则会被当成『树里没有这个节点』");
});

test("[编辑器·树] maxNodes 截断要留痕", () => {
  const scene = makeScene();
  for (let i = 2; i <= 20; i++) scene.spawnImmediate(`n${String(i)}`, scene.root.id, i);
  const o = buildOutline(scene, { maxNodes: 5 });
  assert.equal(o.count, 5);
  assert.equal(o.truncated, true);
  assert.equal(flattenOutline(o.root).length, 5, "摊平后的行数必须与 count 一致");
});

test("[编辑器·树] types 按挂载顺序，不排序", () => {
  const scene = makeScene();
  const n = scene.spawnImmediate("n", scene.root.id, 2);
  attach(scene, n.id, () => new Marker());
  attach(scene, n.id, () => new Deco());

  const types = buildOutline(scene).root.children[0]?.types;
  assert.deepEqual(types, ["test.marker", "render.deco"], "挂载顺序本身就是信息（后面的组件后更新）");
});
