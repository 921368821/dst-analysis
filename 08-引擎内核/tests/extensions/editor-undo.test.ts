/**
 * L4 · 编辑器：可撤销操作（真 Scene）
 *
 * ★ 这里和 `undo-stack.test.ts` 分工明确：那边验「历史怎么排」，
 *   这边验「一步操作反向执行之后，**世界真的回到原样**」。
 *
 * ★ 最强的一条判据是「删除整棵子树 → 撤销 → 连 id、父子链、组件字段值全都回来」。
 *   它同时钉住三件事：快照是在 destroy **之前**拍的、还原用显式 id、三个装配遍
 *   的顺序对。任何一件做错，症状都是「撤销之后世界少了一点东西」，
 *   而少的那点东西要几步之后才反过来把人坑了。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, FieldType, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { NodeId } from "../../src/core/scene/node.ts";
import { setField } from "../../src/extensions/editor/property-model.ts";
import { createUndoStack } from "../../src/extensions/editor/undo-stack.ts";
import {
  EDIT_BAD_NAME,
  EDIT_BAD_NODE,
  EDIT_BAD_PARENT,
  createNodeWithUndo,
  deleteNodeWithUndo,
  makeFieldOp,
  reparentWithUndo,
  restoreRecords,
  snapshotSubtree,
  topmostIds,
} from "../../src/extensions/editor/undo-ops.ts";

class Box extends Component {
  title = "box";
  alpha = 1;
  pos = { x: 0, y: 0 };

  readonly schema: ComponentSchema = {
    type: "test.box",
    fields: {
      title: FieldType.String,
      alpha: FieldType.Int,
      pos: FieldType.Vec2,
    },
  };
}

function makeScene(): Scene {
  const reg = new ComponentRegistry();
  reg.register(new Box().schema, () => new Box());
  return new Scene("editor", reg);
}

/** A(10) → B(11) → C(12)，C 上挂一个 Box（alpha=42，title=深层）。 */
function makeChain(scene: Scene): { a: NodeId; b: NodeId; c: NodeId } {
  const a = scene.spawnImmediate("A", scene.rootId, 10);
  const b = scene.spawnImmediate("B", a.id, 11);
  const c = scene.spawnImmediate("C", b.id, 12);
  const r = scene.attach(c.id, () => {
    const box = new Box();
    box.alpha = 42;
    box.title = "深层";
    return box;
  });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  scene.flush();
  return { a: a.id, b: b.id, c: c.id };
}

function boxOf(scene: Scene, id: NodeId): Box | undefined {
  const n = scene.find(id);
  if (n === undefined) return undefined;
  return n.components.find((x) => x.type === "test.box") as Box | undefined;
}

function codeOf(r: { ok: boolean }): string {
  assert.equal(r.ok, false, "这一步本应失败");
  return (r as unknown as { error: { code: string } }).error.code;
}

// ---------------------------------------------------------------- 字段

test("[撤销·操作] 字段操作：反向写回 before、前向写回 after，都过一遍类型校验", () => {
  const scene = makeScene();
  const { c } = makeChain(scene);
  const r0 = setField(scene, c, "test.box", "alpha", 7);
  assert.equal(r0.ok, true);
  const plus = makeFieldOp(scene, c, "test.box", "alpha", r0.ok ? r0.value.before : 0, r0.ok ? r0.value.after : 0);
  assert.equal(plus.label, "改 test.box.alpha");

  assert.equal(boxOf(scene, c)?.alpha, 7, "前置条件：已经改了");
  plus.revert();
  assert.equal(boxOf(scene, c)?.alpha, 42, "撤销要回到 42（原值），不是回到默认值 1");
  plus.apply();
  assert.equal(boxOf(scene, c)?.alpha, 7, "重做要再回到 7");
});

test("[撤销·操作] 字段操作写回的是坏值时报错，而不是把脏值塞进组件", () => {
  const scene = makeScene();
  const { c } = makeChain(scene);
  // 造一条「历史里记着字符串」的坏 op —— 现实里它来自被手改过的历史/存档
  const bad = makeFieldOp(scene, c, "test.box", "alpha", "不是数字", 5);
  bad.apply();
  const out = bad.revert();
  assert.equal(out.ok, false, "坏值必须报错");
  assert.equal(boxOf(scene, c)?.alpha, 5, "写回失败时组件的值一个字节都不该动");
});

// ---------------------------------------------------------------- 快照

test("[撤销·操作] 子树快照：id 升序、含全部后代、父子按记录走", () => {
  const scene = makeScene();
  const { a, b, c } = makeChain(scene);
  const snap = snapshotSubtree(scene, a);
  assert.ok(snap !== undefined, "快照必须拍得到");
  assert.equal(snap.name, "A");
  assert.deepEqual(snap.records.map((r) => r.id), [a, b, c], "id 升序，不是添加序也不是深度优先序");
  assert.equal(snap.records[0]?.parent, null, "挂在场景根下的节点，记录里 parent 是 null");
  assert.equal(snap.records[2]?.parent, b, "C 的父是 B");
  assert.equal(snap.records[2]?.components[0]?.type, "test.box");
  assert.equal(snapshotSubtree(scene, 9999), undefined, "不存在的节点该返回 undefined，不是空快照");
});

// ---------------------------------------------------------------- 新建

test("[撤销·操作] 新建节点：撤销后消失，重做后**同一个 id** 回来", () => {
  const scene = makeScene();
  const { a } = makeChain(scene);
  const made = createNodeWithUndo(scene, "  石头  ", a);
  assert.equal(made.ok, true, made.ok ? "" : made.error.code);
  const bundle = made.ok ? made.value : null;
  assert.ok(bundle !== null);
  const created = [...(scene.find(a)?.children ?? [])].find((k) => k.name === "石头");
  assert.ok(created !== undefined, "名字要去掉首尾空白，并且挂在指定的父下");
  const id = created.id;

  bundle.op.revert();
  assert.equal(scene.find(id), undefined, "撤销之后节点该没了");
  bundle.op.apply();
  assert.notEqual(scene.find(id), undefined, "重做之后必须回来");
  assert.equal(scene.find(id)?.id, id, "★ id 必须原样还回去 —— 换了 id 等于场景里所有引用都断了");
  assert.equal(scene.find(id)?.parent?.id, a, "父节点也要原样回来");
});

test("[撤销·操作] 新建节点：名字空白直接拒绝（树里出现空白行，人点不到也认不出）", () => {
  const scene = makeScene();
  assert.equal(codeOf(createNodeWithUndo(scene, "   ")), EDIT_BAD_NAME);
  assert.equal(codeOf(createNodeWithUndo(scene, "")), EDIT_BAD_NAME);
  assert.equal(codeOf(createNodeWithUndo(scene, "x", 9999)), EDIT_BAD_NODE, "父节点不存在也要拒绝");
});

// ---------------------------------------------------------------- 删除

test("[撤销·操作] ★ 删除整棵子树 → 撤销：id、父子链、组件字段值全都回来", () => {
  const scene = makeScene();
  const { a, b, c } = makeChain(scene);
  const before = scene.stats();
  const del = deleteNodeWithUndo(scene, a);
  assert.equal(del.ok, true, del.ok ? "" : del.error.code);
  const bundle = del.ok ? del.value : null;
  assert.ok(bundle !== null);
  assert.equal(scene.stats().nodes, 1, "三个节点都该被删掉（只剩根）");
  assert.ok(before.nodes > scene.stats().nodes);

  const out = bundle.op.revert();
  assert.equal(out.ok, true, out.ok ? "撤销删除成功" : out.error.code);
  assert.equal(scene.stats().nodes, before.nodes, "节点数要回到删除前");
  assert.deepEqual([a, b, c].map((id) => scene.find(id)?.name), ["A", "B", "C"], "id 与名字都要对得上");
  assert.equal(scene.find(b)?.parent?.id, a, "父子链要按原样接回去");
  assert.equal(scene.find(c)?.parent?.id, b);
  const box = boxOf(scene, c);
  assert.ok(box !== undefined, "组件必须挂回来");
  assert.equal(box.alpha, 42, "★ 组件字段值必须逐字段还原（这里是 42，不是默认值 1）");
  assert.equal(box.title, "深层");
  assert.deepEqual(box.pos, { x: 0, y: 0 });
});

test("[撤销·操作] 删除后重做（=再删一次）也成立，且能反复来回", () => {
  const scene = makeScene();
  const { a } = makeChain(scene);
  const del = deleteNodeWithUndo(scene, a);
  assert.equal(del.ok, true);
  const op = del.ok ? del.value.op : null;
  assert.ok(op !== null);
  for (let i = 0; i < 3; i++) {
    assert.equal(op.revert().ok, true, `第 ${String(i + 1)} 轮撤销`);
    assert.notEqual(scene.find(a), undefined);
    assert.equal(op.apply().ok, true, `第 ${String(i + 1)} 轮重做`);
    assert.equal(scene.find(a), undefined);
  }
});

test("[撤销·操作] 不能删除场景根节点（删了之后一切都不存在，没有意义）", () => {
  const scene = makeScene();
  assert.equal(codeOf(deleteNodeWithUndo(scene, scene.rootId)), EDIT_BAD_NODE);
  assert.equal(codeOf(deleteNodeWithUndo(scene, 9999)), EDIT_BAD_NODE);
});

test("[撤销·操作] ★ 组件类型未注册时还原会报出来，不静默少一个组件", () => {
  const scene = makeScene();
  const { c } = makeChain(scene);
  const snap = snapshotSubtree(scene, c);
  assert.ok(snap !== undefined);

  // 换一个「没有注册 test.box」的场景来还原：模拟「插件被卸掉之后撤销一次删除」
  const bare = new Scene("bare", new ComponentRegistry());
  const rep = restoreRecords(bare, snap.records, null);
  assert.equal(rep.made, 1, "节点本身还是建出来了");
  assert.equal(
    rep.warnings.some((w) => w.includes("test.box")),
    true,
    `少了一个组件就必须有一条指名道姓的警告，实际：${JSON.stringify(rep.warnings)}`,
  );
  assert.equal(bare.find(c)?.components.length, 0, "组件确实没挂上 —— 警告说的是真事");
});

test("[撤销·操作] 还原时父节点已经不在了 ⇒ 挂到根下并留一条警告", () => {
  const scene = makeScene();
  const { b, c } = makeChain(scene);
  const snap = snapshotSubtree(scene, c);
  assert.ok(snap !== undefined);
  // 只把 C 的记录拿去还原，而它的父 B 不在另一棵树里
  const other = new Scene("other", scene.components);
  const rep = restoreRecords(other, snap.records, null);
  assert.equal(rep.made, 1);
  assert.equal(b !== c, true);
  assert.equal(other.find(c)?.parent?.id, other.rootId, "父不在了就挂到根下（并已被警告告知）");
  assert.equal(rep.warnings.length, 1);
  assert.match(rep.warnings[0] ?? "", /父节点/);
});

// ---------------------------------------------------------------- 换父

test("[撤销·操作] 换父：撤销回到原父，重做回到新父", () => {
  const scene = makeScene();
  const { a, b, c } = makeChain(scene);
  const mv = reparentWithUndo(scene, c, a);
  assert.equal(mv.ok, true, mv.ok ? "" : mv.error.code);
  const op = mv.ok ? mv.value.op : null;
  assert.ok(op !== null);
  assert.equal(scene.find(c)?.parent?.id, a, "已经挪过去了");

  op.revert();
  assert.equal(scene.find(c)?.parent?.id, b, "撤销要回到原来的父 B");
  op.apply();
  assert.equal(scene.find(c)?.parent?.id, a);
});

test("[撤销·操作] 换父的三种拒绝：原地不动 / 挂到自己或后代下面 / 目标不存在", () => {
  const scene = makeScene();
  const { a, b, c } = makeChain(scene);
  assert.equal(codeOf(reparentWithUndo(scene, b, a)), EDIT_BAD_PARENT, "已经挂在 A 下，不该进历史");
  assert.equal(codeOf(reparentWithUndo(scene, a, c)), EDIT_BAD_PARENT, "把 A 挂到它的孙子 C 下面会造环");
  assert.equal(codeOf(reparentWithUndo(scene, a, a)), EDIT_BAD_PARENT);
  assert.equal(codeOf(reparentWithUndo(scene, b, 9999)), EDIT_BAD_PARENT);
  assert.equal(codeOf(reparentWithUndo(scene, scene.rootId, a)), EDIT_BAD_NODE);
});

test("[撤销·操作] ★ 换父的反向：目标父节点被删了要报错，不能悄悄挂到根下", () => {
  const scene = makeScene();
  const { b, c } = makeChain(scene);
  // 先把 C 挪到根下，历史里记着 from=B
  const mv = reparentWithUndo(scene, c, null);
  assert.equal(mv.ok, true);
  const op = mv.ok ? mv.value.op : null;
  assert.ok(op !== null);
  // 然后把 B 连同 A 一起删掉 —— C 的原父没了
  scene.destroy(b);
  scene.flush();
  assert.equal(scene.find(b), undefined, "前置条件：B 真的没了");
  const out = op.revert();
  assert.equal(out.ok, false, "原父不在了，撤销必须报错");
  assert.match(out.ok ? "" : out.error.message, /不在了/);
  assert.equal(scene.find(c)?.parent?.id, scene.rootId, "★ 报错之后位置不许动（不能顺手挂到根下还说自己成功了）");
});

// ---------------------------------------------------------------- 与栈一起

test("[撤销·操作] ★ 多选删除 = 一个原子历史：撤销一次两个都回来", () => {
  const scene = makeScene();
  const { b, c } = makeChain(scene);
  const stack = createUndoStack();

  stack.beginBatch("删除选中 2 个");
  const d1 = deleteNodeWithUndo(scene, c);
  assert.equal(d1.ok, true);
  if (d1.ok) stack.push(d1.value.op);
  const d2 = deleteNodeWithUndo(scene, b);
  assert.equal(d2.ok, true);
  if (d2.ok) stack.push(d2.value.op);
  const committed = stack.commitBatch();
  assert.equal(committed.ok && committed.value.pushed, true);
  assert.equal(scene.stats().nodes, 2, "A 与根，B/C 都没了");

  const out = stack.undo();
  assert.equal(out.kind, "done");
  assert.deepEqual([b, c].map((id) => scene.find(id)?.name), ["B", "C"], "一次撤销两个都回来");
  assert.equal(scene.find(c)?.parent?.id, b, "父子关系也要回来（C 的父是 B，而 B 刚被一起删过）");
  assert.equal(stack.depth, 0);
});

test("[撤销·操作] 栈 + 字段 + 结构混用：一路撤销回去，每一步都能对上", () => {
  const scene = makeScene();
  const { c } = makeChain(scene);
  const stack = createUndoStack();
  const nodes0 = scene.stats().nodes;

  // 1) 改字段
  const r = setField(scene, c, "test.box", "alpha", 9);
  assert.equal(r.ok, true);
  if (r.ok) stack.push(makeFieldOp(scene, c, "test.box", "alpha", r.value.before, r.value.after));
  // 2) 新建节点
  const made = createNodeWithUndo(scene, "D", c);
  assert.equal(made.ok, true);
  if (made.ok) stack.push(made.value.op);
  assert.equal(scene.stats().nodes, nodes0 + 1);

  assert.equal(stack.undo().kind, "done");
  assert.equal(scene.stats().nodes, nodes0, "撤销新建");
  assert.equal(boxOf(scene, c)?.alpha, 9, "此时字段改动还在");

  assert.equal(stack.undo().kind, "done");
  assert.equal(boxOf(scene, c)?.alpha, 42, "撤销字段改动");
  assert.equal(stack.canUndo, false, "历史该空了");
  assert.equal(stack.undo().kind, "empty");
});

test("[撤销·操作] ★ topmostIds 去掉「祖先也被选中」的子孙（否则多选删除会整批回滚）", () => {
  const scene = makeScene();
  const { a, b, c } = makeChain(scene);
  const d = scene.spawnImmediate("D", scene.rootId, 20);
  scene.flush();

  assert.deepEqual(topmostIds(scene, [a, b, c]), [a], "父子孙三个都选中，真正该删的只有最上层那个");
  assert.deepEqual(topmostIds(scene, [a, c]), [a]);
  assert.deepEqual(topmostIds(scene, [c, b]), [b], "顺序按传入的顺序保留，只做过滤不重排");
  assert.deepEqual(topmostIds(scene, [b, d.id]), [b, d.id], "互不为祖先的两个都要留下");
  assert.deepEqual(topmostIds(scene, []), []);

  // 端到端：真的按 topmostIds 删，一次成功（不回滚）
  const stack = createUndoStack();
  stack.beginBatch("删除选中 3 个");
  for (const id of topmostIds(scene, [a, b, c])) {
    const r = deleteNodeWithUndo(scene, id);
    assert.equal(r.ok, true, r.ok ? "" : r.error.code);
    if (r.ok) stack.push(r.value.op);
  }
  const cm = stack.commitBatch();
  assert.equal(cm.ok && cm.value.count, 1, "三条历史实际只产生一条（其余两个是它的后代）");
  assert.equal(scene.find(a), undefined);
  assert.equal(scene.find(c), undefined);
  stack.undo();
  assert.deepEqual([a, b, c].map((id) => scene.find(id)?.name), ["A", "B", "C"]);
});
