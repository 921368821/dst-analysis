/**
 * L4 · 编辑器：文档会话（保存 / 打开 / 新建）的判据
 *
 * 这一组验的不是"能存能读"（那是 `scene-io` 的事），而是**三个副作用**：
 *  ① 打开失败，当前工程必须**原样还在**；
 *  ② 打开成功，撤销栈必须**清空**（否则撤销会改到新文档里的另一个节点）；
 *  ③ 新建之后，不能还能"撤销回上一份文档"。
 *
 * 这三条的共同点是**出错时看不出来**：场景还在、按钮还亮、值真的变了 —— 只是变错了对象。
 * 所以每条判据都要能回答"如果这段逻辑被删掉，它还会绿吗"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { sceneFromJson, sceneToJson, saveScene } from "../../src/core/scene/scene-io.ts";
import { createSelection } from "../../src/extensions/editor/selection.ts";
import { FieldOp } from "../../src/extensions/editor/undo-ops.ts";
import { createUndoStack } from "../../src/extensions/editor/undo-stack.ts";
import {
  EDIT_BAD_DOC,
  EDIT_LOAD_FAILED,
  exportDocument,
  loadDocument,
  newDocument,
  openDocument,
  roundTrip,
  type SessionDeps,
} from "../../src/extensions/editor/session.ts";

function setup(): SessionDeps & { seeded: { a: number; b: number } } {
  const scene = new Scene("doc", new ComponentRegistry());
  const a = scene.spawnImmediate("a", scene.rootId);
  const b = scene.spawnImmediate("b", a.id);
  scene.flush();
  return {
    scene,
    registry: scene.components as ComponentRegistry,
    history: createUndoStack(),
    selection: createSelection(),
    seeded: { a: a.id, b: b.id },
  };
}

/** 往历史里压两条**可撤销**的操作（用真实的 FieldOp —— 假 op 验不到"撤销会不会真的写坏东西"）。 */
function pushTwoOps(deps: SessionDeps, ids: { a: number; b: number }): void {
  const na = deps.scene.find(ids.a);
  const nb = deps.scene.find(ids.b);
  assert.ok(na !== undefined && nb !== undefined);
  deps.history.push(new FieldOp(deps.scene, ids.a, "a", "zIndex", na.zIndex, 7));
  deps.history.push(new FieldOp(deps.scene, ids.b, "b", "zIndex", nb.zIndex, 9));
  assert.equal(deps.history.history().undo.length, 2, "夹具没压进两条历史");
}

const DOC = (deps: SessionDeps): string => {
  const r = exportDocument(deps);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  return r.ok ? r.value : "";
};

/**
 * 装得进、挂上就抛的组件。
 *
 * ★ 它存在的理由：`loadScene` 把"建节点 / 设父子"的异常收进 `skipped`，
 *   所以只有**组件装配**这条路会真的抛（第 3 遍末尾 `scene.flush()` 跑 `onAttach`）。
 *   没有它，"装载中途抛异常"这条分支只能靠读代码相信，判据碰不到。
 */
class Boom extends Component {
  readonly schema: ComponentSchema = { type: "test.boom", fields: {} };
  override onAttach(): void {
    throw new Error("装配期爆炸（夹具）");
  }
}

// ---------------------------------------------------------------- 导出

test("[编辑器会话] 导出是确定性的：同一棵树两次导出逐字节相同", () => {
  const deps = setup();
  const x = DOC(deps);
  const y = DOC(deps);
  assert.equal(x, y);
  // 反面对照：改一个字段之后必须不同（否则上面那条用"恒返回常量"也能过）
  const n = deps.scene.find(deps.seeded.a);
  assert.ok(n !== undefined);
  n.zIndex = 42;
  assert.notEqual(DOC(deps), x, "改了字段导出却没变");
});

test("[编辑器会话] 导出的文本自己读得回来（往返一次节点数与 id 都不变）", () => {
  const deps = setup();
  const before = saveScene(deps.scene).nodes.map((n) => n.id).sort((p, q) => p - q);
  const r = roundTrip(deps);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  const after = saveScene(deps.scene).nodes.map((n) => n.id).sort((p, q) => p - q);
  assert.deepEqual(after, before, "往返之后节点 id 变了（说明导出/导入不是同一个口径）");
  assert.equal(r.ok ? r.value.skipped.length : -1, 0, `往返出现了跳过项：${r.ok ? r.value.skipped.join("；") : ""}`);
});

// ---------------------------------------------------------------- 打开失败：不许动场景

test("★★ 打开坏文本：报错，且**当前工程原样还在**（loadScene 会先 clear，所以顺序必须是对的先）", () => {
  const deps = setup();
  const before = DOC(deps);
  const r = openDocument(deps, "{这不是 JSON");
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, EDIT_BAD_DOC);
  // ★ 这一条是整批的重点：如果实现是"直接 load、失败再说"，场景此刻已经空了。
  assert.equal(DOC(deps), before, "打开失败把正在编辑的工程弄丢了");
  assert.equal(deps.scene.find(deps.seeded.a)?.name, "a", "节点 a 不见了");
});

test("★ 打开「版本过新」的档：错误码透传，场景不动", () => {
  const deps = setup();
  const snap = sceneFromJson(DOC(deps));
  assert.equal(snap.ok, true);
  const tooNew = snap.ok ? sceneToJson({ ...snap.value, format: 99 }) : "{}";
  const before = DOC(deps);
  const r = openDocument(deps, tooNew);
  assert.equal(r.ok, false);
  assert.equal(DOC(deps), before, "版本过新的档把场景吃掉了");
});

test("★★ 装载失败（格式过新的快照）：报 EDIT_LOAD_FAILED，且场景被**快照回灌**回原样", () => {
  const deps = setup();
  pushTwoOps(deps, deps.seeded);
  const before = DOC(deps);
  // ★ 用快照直接调，而不是喂文本：sceneFromJson 会把 format 归一成当前版本，
  //   于是 loadScene 的版本闸门永远不触发 —— 那样这条判据是**恒绿**的（测不到任何东西）。
  const snap = sceneFromJson(before);
  assert.equal(snap.ok, true);
  const tooNew = snap.ok ? { ...snap.value, format: 99, nodes: [] } : undefined;
  assert.ok(tooNew !== undefined);
  const r = loadDocument(deps, tooNew);
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, EDIT_LOAD_FAILED);
  // ★★ 这条是"快照必须在 loadScene 之前拍"的**唯一**证据：
  //    顺序写反时 loadScene 已经把世界清空了，回灌装回来的是空场景 —— 错误码一样，
  //    只是人打开一次打不开的档，工程就没了。
  assert.equal(DOC(deps), before, "装载失败之后工作区没了（快照拍晚了 / 没回灌）");
  // 装载失败也不该产生副作用
  assert.equal(deps.history.history().undo.length, 2, "装载失败把历史清了");
});

test("★★★ 装载中途「抛」异常（组件 onAttach 失败）：报 EDIT_LOAD_FAILED，场景回灌，且不把异常扔给按钮", () => {
  const deps = setup();
  pushTwoOps(deps, deps.seeded);
  const before = DOC(deps);
  // 造一个"装得进、但挂上之后立刻抛"的组件 —— `loadScene` 第三遍会 attach，
  // 第 3 遍末尾的 `scene.flush()` 去跑它的 `onAttach`，异常从 flush 穿出去。
  deps.registry.register({ type: "test.boom", fields: {} }, () => new Boom());
  const snap = sceneFromJson(before);
  assert.equal(snap.ok, true);
  const text = snap.ok ? sceneToJson(snap.value) : "{}";
  // 把 boom 组件塞进第一个节点：手改 JSON 比构造第二种快照干净（要的就是"结构合法、装配会抛"）。
  const withComp = text.replace(
    '"components":[]',
    '"components":[{"type":"test.boom","data":{}}]',
  );
  const parsed = sceneFromJson(withComp);
  assert.equal(parsed.ok, true, "夹具没造出来（这会把下面全变成废话）");

  // ★ 不 try/catch：如果 loadDocument 让异常穿出去，这条判据直接红（红在"没接住"上）。
  const r = loadDocument(deps, parsed.ok ? parsed.value : { format: 1, name: "", nodes: [] });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, EDIT_LOAD_FAILED);
  // ★★ 这是「快照必须拍在 loadScene 之前」的**唯一**证据：
  //    clear() 已经发生过了，只有回灌能把工程救回来。顺序写反 ⇒ 这里拿到空场景。
  assert.equal(DOC(deps), before, "装配抛异常之后工作区没了（快照拍晚了 / 没回灌）");
  assert.equal(deps.history.history().undo.length, 2, "装载抛异常把历史清了");
});

test("★★ 打开失败**不产生副作用**：历史与选中都还在（否则连刚才那步改错都退不回去）", () => {
  const deps = setup();
  pushTwoOps(deps, deps.seeded);
  deps.selection.select(deps.seeded.a);
  const r = openDocument(deps, "nope");
  assert.equal(r.ok, false);
  assert.equal(deps.history.history().undo.length, 2, "打开失败把历史清了");
  assert.deepEqual(deps.selection.ids(), [deps.seeded.a], "打开失败把选中清了");
});

// ---------------------------------------------------------------- 打开成功：清历史与选中

test("★★ 打开合法文档：历史被清空，且报告清掉了几条", () => {
  const deps = setup();
  pushTwoOps(deps, deps.seeded);
  deps.selection.select(deps.seeded.b);
  const r = openDocument(deps, DOC(deps));
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  // ★ 不清历史的话：撤销会把 FieldOp 应用到"同 id 的另一个节点"上 —— 值真的变了，只是错对象。
  assert.equal(deps.history.canUndo, false, "打开之后还能撤销（会改到新文档里的另一个节点）");
  assert.equal(r.ok ? r.value.droppedHistory : -1, 2, "没说清清掉了几条历史");
  assert.equal(r.ok ? r.value.droppedSelection : -1, 1, "没说清清掉了几项选中");
  assert.deepEqual(deps.selection.ids(), []);
});

test("★ 打开之后撤销返回 empty（不是 failed —— 那会让人以为操作坏了）", () => {
  const deps = setup();
  pushTwoOps(deps, deps.seeded);
  assert.equal(openDocument(deps, DOC(deps)).ok, true);
  const out = deps.history.undo();
  assert.equal(out.kind, "empty");
});

test("★ 打开一份**别人写的**文档：id 与名字都按文档来，不是按当前场景", () => {
  const a = setup();
  const b = new Scene("other", new ComponentRegistry());
  const only = b.spawnImmediate("来自另一份文档", b.rootId);
  b.flush();
  const text = sceneToJson(saveScene(b));

  const r = openDocument(a, text);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  const names = saveScene(a.scene).nodes.map((n) => n.name).sort();
  // ★ 根节点不在存档记录里（`collectNodes` 排除它），所以这里只剩文档自己的节点
  assert.deepEqual(names, ["来自另一份文档"], `打开的文档没替换掉原场景：${names.join(",")}`);
  assert.ok(a.scene.find(only.id) !== undefined, "文档里那个节点应该按它自己的 id 落地");
});

// ---------------------------------------------------------------- 新建

test("★★ 新建：场景只剩根，历史清空（否则能撤销回上一份文档）", () => {
  const deps = setup();
  pushTwoOps(deps, deps.seeded);
  deps.selection.select(deps.seeded.a);
  deps.selection.add(deps.seeded.b);
  const r = newDocument(deps);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  const nodes = saveScene(deps.scene).nodes;
  // 根节点不进存档 ⇒ "只剩根"表现为**零条记录**；再用一次真实的 walk 确认根还在。
  assert.equal(nodes.length, 0, `新建之后还有 ${String(nodes.length)} 个节点记录`);
  const walked: number[] = [];
  deps.scene.root.walk((n) => walked.push(n.id));
  assert.deepEqual(walked, [deps.scene.rootId], "新建之后根不在了（那场景就废了）");
  assert.equal(deps.history.canUndo, false, "新建之后还能撤销回上一份文档 —— 两份文档混在一条历史里");
  assert.deepEqual(deps.selection.ids(), []);
  assert.equal(r.ok ? r.value.droppedHistory : -1, 2);
});

test("★ 新建之后再打开一份文档：仍然只有那份文档的内容（没有叠加）", () => {
  const deps = setup();
  const text = DOC(deps);
  assert.equal(newDocument(deps).ok, true);
  const r = openDocument(deps, text);
  assert.equal(r.ok, true);
  const names = saveScene(deps.scene).nodes.map((n) => n.name).sort();
  assert.deepEqual(names, ["a", "b"], `叠加了：${names.join(",")}`);
});

// ---------------------------------------------------------------- failed 语义

test("EDIT_BAD_DOC / EDIT_LOAD_FAILED 是两个码（一个能改文档，一个是引擎的问题）", () => {
  assert.notEqual(EDIT_BAD_DOC, EDIT_LOAD_FAILED);
  const deps = setup();
  const r = openDocument(deps, "");
  assert.equal(r.ok ? "" : r.error.code, EDIT_BAD_DOC);
});
