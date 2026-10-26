/**
 * L4 · 编辑器：组件挂载 / 卸载的可撤销操作
 *
 * 这一组验的是**批77 记下的那个缺口**：结构性操作（新建 / 删除 / 换父）都能撤销了，
 * 组件的挂载与卸载一直没有反向实现。
 *
 * 它比那三件更容易写错，因为**外观会骗人**：重做时新建一个同类组件，
 * 面板上「组件回来了」、字段也都在，只有状态（血量 / 计时器 / 指向别人的引用）
 * 悄悄回到出厂值。所以这里最重的一条判据不是「组件回来了」，而是
 * **回来的是同一个实例、里面的值也没变**。
 *
 * 第二类判据全是「历史失效」：撤销栈里记的是实例引用，而节点上的组件可能
 * 在这条历史与现在之间被换掉。此时按类型去摘会摘掉别人（`scene.detach` 就是按类型找的），
 * 症状是「撤销一次卸载，结果卸掉了另一个组件」。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, FieldType, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { NodeId } from "../../src/core/scene/node.ts";
import { createUndoStack } from "../../src/extensions/editor/undo-stack.ts";
import {
  EDIT_BAD_COMP,
  EDIT_BAD_NODE,
  attachComponentWithUndo,
  detachComponentWithUndo,
} from "../../src/extensions/editor/undo-ops.ts";

/**
 * 夹具组件。
 *
 * ★ `onAttach` **不**重置 `hp` —— 这是刻意留的坑位：卸载再挂回时 `onAttach` 会跑第二次，
 *   如果它把 `hp` 写回满值，「撤销卸载保住状态」这条判据就会红在夹具上而不是实现上。
 *   真实的组件也不该这么做（见 `undo-ops.ts` 那段约定），这里用 `attachCount`
 *   把"跑了几次"记下来，让那条行为**显式**可见，而不是靠猜。
 */
class Gauge extends Component {
  hp = 100;
  attachCount = 0;

  readonly schema: ComponentSchema = {
    type: "test.gauge",
    fields: { hp: FieldType.Int },
  };

  override onAttach(): void {
    this.attachCount += 1;
  }
}

function makeScene(): { scene: Scene; node: NodeId } {
  const reg = new ComponentRegistry();
  reg.register(new Gauge().schema, () => new Gauge());
  const scene = new Scene("editor", reg);
  const n = scene.spawnImmediate("靶子", scene.rootId);
  scene.flush();
  return { scene, node: n.id };
}

function gaugeOf(scene: Scene, id: NodeId): Gauge | undefined {
  const n = scene.find(id);
  if (n === undefined) return undefined;
  return n.components.find((c) => c.type === "test.gauge") as Gauge | undefined;
}

/**
 * 节点上挂着的 `test.gauge` **有几个**。
 *
 * ★ 必须单独数：`Node.attach` **允许**同一节点上存在两个同类型组件
 *   （它只把实例 push 进数组，不查类型；只有 `Scene.attach` 查了"类型注册过没有"）。
 *   于是「挂上失败」有两种世界 —— 一种是干净的，一种是**多出一个没人认领的组件**，
 *   而后者用 `get(type)` 看不出来（它只返回第一个）。
 */
function gaugeCount(scene: Scene, id: NodeId): number {
  const n = scene.find(id);
  if (n === undefined) return -1;
  return n.components.filter((c) => c.type === "test.gauge").length;
}

function codeOf(r: { ok: boolean }): string {
  assert.equal(r.ok, false, "这一步本应失败");
  return (r as unknown as { error: { code: string } }).error.code;
}

// ---------------------------------------------------------------- 挂上 / 卸下

test("[组件撤销] 挂上之后节点上真的多了它，且历史里有一条「挂上」", () => {
  const { scene, node } = makeScene();
  const h = createUndoStack();
  const r = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assert.ok(gaugeOf(scene, node) !== undefined, "挂上之后节点上没有这个组件");
  assert.equal(r.ok ? r.value.op.label : "", "挂上 test.gauge");
  if (r.ok) h.push(r.value.op);
  assert.equal(h.canUndo, true);
});

test("★★ 撤销挂上：组件从节点上消失", () => {
  const { scene, node } = makeScene();
  const h = createUndoStack();
  const r = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(r.ok, true);
  if (r.ok) h.push(r.value.op);
  const out = h.undo();
  assert.equal(out.kind, "done", `撤销失败：${out.kind}`);
  assert.equal(gaugeOf(scene, node), undefined, "撤销之后组件还在（这条历史根本没反着走）");
});

test("★★★ 重做挂上：拿回的是**同一个实例**（不是新建一个同类）", () => {
  const { scene, node } = makeScene();
  const h = createUndoStack();
  const r = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(r.ok, true);
  if (r.ok) h.push(r.value.op);
  const first = gaugeOf(scene, node);
  assert.ok(first !== undefined);
  assert.equal(h.undo().kind, "done");
  assert.equal(h.redo().kind, "done");
  const again = gaugeOf(scene, node);
  assert.ok(again !== undefined, "重做之后组件没回来");
  // ★ 这一条是整批的核心：`===` 才算数。值相等还不够（新建的默认值恰好也是 100）。
  assert.equal(again, first, "重做新建了一个同类组件（状态回到出厂值，而界面看不出来）");
});

test("★★★ 卸载 → 撤销：同一实例回来，且**字段值没被重置**", () => {
  const { scene, node } = makeScene();
  const h = createUndoStack();
  const a = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(a.ok, true);
  const g = gaugeOf(scene, node);
  assert.ok(g !== undefined);
  g.hp = 37; // 模拟人改过 / 战斗里掉过血

  const d = detachComponentWithUndo(scene, node, "test.gauge");
  assert.equal(d.ok, true, d.ok ? "" : d.error.code);
  if (d.ok) h.push(d.value.op);
  assert.equal(gaugeOf(scene, node), undefined, "卸载之后组件还在");

  assert.equal(h.undo().kind, "done");
  const back = gaugeOf(scene, node);
  assert.equal(back, g, "撤销卸载拿回的是另一个实例");
  assert.equal(back?.hp, 37, `撤销卸载之后 hp 变成 ${String(back?.hp)}（状态没保住）`);
});

test("★ onAttach 会跑第二次（所以它不能当初始化用）", () => {
  const { scene, node } = makeScene();
  const a = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(a.ok, true);
  const g = gaugeOf(scene, node);
  assert.ok(g !== undefined);
  assert.equal(g.attachCount, 1);
  const d = detachComponentWithUndo(scene, node, "test.gauge");
  assert.equal(d.ok, true);
  const h = createUndoStack();
  if (d.ok) h.push(d.value.op);
  assert.equal(h.undo().kind, "done");
  // ★ 不是"顺手记一下"：这条把「onAttach 在撤销路径上会再跑」变成受控行为。
  //   哪天有人把重置逻辑写进 onAttach，这条不会红（计数照样涨），
  //   但上面那条 hp 判据会红 —— 两条配合才拦得住。
  assert.equal(gaugeOf(scene, node)?.attachCount, 2, "撤销卸载没有真的重新挂载（那 hp 判据就是假绿）");
});

// ---------------------------------------------------------------- 拒绝路径

test("★ 挂未注册的类型：报 EDIT_BAD_COMP，且节点上什么都没多", () => {
  const { scene, node } = makeScene();
  const before = scene.find(node)?.components.length ?? -1;
  const r = attachComponentWithUndo(scene, scene.components, node, "test.nope");
  assert.equal(codeOf(r), EDIT_BAD_COMP);
  assert.equal(scene.find(node)?.components.length, before, "失败却动了节点");
});

test("★ 同类型已经挂了一个：报 EDIT_BAD_COMP（不留第二条历史）", () => {
  const { scene, node } = makeScene();
  const h = createUndoStack();
  const a = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(a.ok, true);
  if (a.ok) h.push(a.value.op);
  const b = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(codeOf(b), EDIT_BAD_COMP);
  assert.equal(h.history().undo.length, 1, "被拒绝的操作也进了历史（撤销会撤掉一个没发生过的动作）");
  assert.equal(scene.find(node)?.components.length, 1);
});

test("★ 节点不存在：挂与卸都报 EDIT_BAD_NODE", () => {
  const { scene } = makeScene();
  const ghost = 9999 as NodeId;
  assert.equal(codeOf(attachComponentWithUndo(scene, scene.components, ghost, "test.gauge")), EDIT_BAD_NODE);
  assert.equal(codeOf(detachComponentWithUndo(scene, ghost, "test.gauge")), EDIT_BAD_NODE);
});

test("★ 卸一个本来就没挂的类型：报 EDIT_BAD_COMP", () => {
  const { scene, node } = makeScene();
  assert.equal(codeOf(detachComponentWithUndo(scene, node, "test.gauge")), EDIT_BAD_COMP);
});

// ---------------------------------------------------------------- 历史失效

test("★★ 卸载之后手动挂了个新的同类型：撤销卸载要报错，且**不许摘掉新的那个**", () => {
  const { scene, node } = makeScene();
  const a = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(a.ok, true);
  const d = detachComponentWithUndo(scene, node, "test.gauge");
  assert.equal(d.ok, true);
  const h = createUndoStack();
  if (d.ok) h.push(d.value.op);

  // 历史与现在之间，有人挂了一个**新的**同类型组件（不是卸载前那个）
  const fresh = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(fresh.ok, true, "夹具没造出来");
  const freshComp = gaugeOf(scene, node);
  assert.ok(freshComp !== undefined);

  const out = h.undo();
  assert.equal(out.kind, "failed", "撤销卸载应当失败（节点上那个不是它记的那个）");
  // ★★ 这才是重点：失败之后世界不许被改。按类型去摘会摘掉 fresh；
  //    而**不检查就硬挂**的写法会把 comp 也塞进去（`Node.attach` 不管重复类型）——
  //    两种都在 `gaugeOf` 上看着"还是 fresh"，只有数个数才分得开。
  assert.equal(gaugeOf(scene, node), freshComp, "撤销失败之后，别人的组件被摘掉了");
  assert.equal(gaugeCount(scene, node), 1, "撤销失败却在节点上多塞了一个同类组件（没人认领的那个）");
});

test("★★ 挂上之后手动换成了另一个同类型：撤销挂上报错，且不许覆盖新的那个", () => {
  const { scene, node } = makeScene();
  const a = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(a.ok, true);
  const h = createUndoStack();
  if (a.ok) h.push(a.value.op);

  // 手动把组件摘掉再换成新的，再撤销「挂上」
  detachComponentWithUndo(scene, node, "test.gauge");
  const fresh = attachComponentWithUndo(scene, scene.components, node, "test.gauge");
  assert.equal(fresh.ok, true);
  const freshComp = gaugeOf(scene, node);
  assert.ok(freshComp !== undefined);

  const out = h.undo();
  assert.equal(out.kind, "failed", "撤销挂上应当失败（位置上已经站了别人）");
  assert.equal(gaugeOf(scene, node), freshComp, "撤销失败却把别人的组件换掉了");
  assert.equal(gaugeCount(scene, node), 1, "撤销失败却在节点上多塞了一个同类组件");
});
