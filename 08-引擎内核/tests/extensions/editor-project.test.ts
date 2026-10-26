/**
 * L4 · 编辑器：工程（多场景）的判据
 *
 * 这一组盯的是**切换本身**，不是"能不能存能读"（那是 `scene-io` / `session` 的判据）。
 * 三条最容易做错、而且做错了看不出来的事：
 *
 *  ① 切走之前没保存源场景 ⇒ 切回来发现自己刚加的节点没了（而人会怪引擎"丢东西"）；
 *  ② 切到**当前**场景却走了 `loadScene` ⇒ 整棵树被换成新实例：撤销栈、选中集、
 *     组件上的运行时状态全废 —— 而节点数、名字、id 全都一样，**看不出来**；
 *  ③ 切换失败（目标文档坏了 / 保存失败）时把 `current` 改了 ⇒ 之后每一次
 *     "切走"都会把 A 的内容写进 B 的槽位。
 *
 * ★ ② 的判据要能分辨"实例"和"id"：`scene.find(id)` 拿到的对象引用是不是同一个。
 *   `NodeId` 写在文档里，重建之后 id 必然一样 —— 只比 id / 名字 / 节点数，
 *   "重建了"和"没重建"是**同一个结果**（假绿）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { Component, ComponentRegistry, type ComponentSchema } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { NodeId } from "../../src/core/scene/node.ts";
import { createSelection } from "../../src/extensions/editor/selection.ts";
import { FieldOp } from "../../src/extensions/editor/undo-ops.ts";
import { createUndoStack } from "../../src/extensions/editor/undo-stack.ts";
import { exportDocument, type SessionDeps } from "../../src/extensions/editor/session.ts";
import {
  EDIT_LAST_SCENE,
  EDIT_NO_SUCH_SCENE,
  EDIT_SAVE_FAILED,
  EDIT_SCENE_EXISTS,
  createProject,
  createScene,
  currentSceneText,
  deleteScene,
  freeSceneName,
  sceneNames,
  switchScene,
  type Project,
} from "../../src/extensions/editor/project.ts";

/** 导出**会抛**的组件：用来把"切走前保存失败"这条分支真的走到。 */
class BadSave extends Component {
  readonly schema: ComponentSchema = { type: "test.badsave", fields: {} };
  override save(): Record<string, unknown> {
    throw new Error("导出爆炸（夹具）");
  }
  override load(): { missing: string[] } {
    return { missing: [] };
  }
}

function setup(): SessionDeps & { seeded: { a: NodeId; b: NodeId } } {
  const registry = new ComponentRegistry();
  registry.register(new BadSave().schema, () => new BadSave());
  const scene = new Scene("main", registry);
  const a = scene.spawnImmediate("a", scene.rootId);
  const b = scene.spawnImmediate("b", a.id);
  scene.flush();
  return {
    scene,
    registry,
    history: createUndoStack(),
    selection: createSelection(),
    seeded: { a: a.id, b: b.id },
  };
}

const DOC = (deps: SessionDeps): string => {
  const r = exportDocument(deps);
  assert.equal(r.ok, true, r.ok ? "" : `${r.error.code}: ${r.error.message}`);
  return r.ok ? r.value : "";
};

/** 拿一个**一定存在**的槽位（`noUncheckedIndexedAccess` 下 `p.scenes[0]` 是可空的）。 */
function slotAt(p: Project, i: number): { name: string; text: string } {
  const s = p.scenes[i];
  assert.ok(s !== undefined, `槽位 #${String(i)} 不存在`);
  return s;
}

/** 场景里所有节点的**实例引用**（用 id 取，取不到就是 undefined）。 */
function instances(deps: SessionDeps & { seeded: { a: NodeId; b: NodeId } }): Array<object | undefined> {
  return [deps.seeded.a, deps.seeded.b].map((id) => deps.scene.find(id));
}

// ---------------------------------------------------------------- 开工程

test("[编辑器工程] 开工程：只有一份场景，当前项就是它，内容就是那份文档", () => {
  const deps = setup();
  const text = DOC(deps);
  const p = createProject("main", text);
  assert.deepEqual(sceneNames(p), ["main"]);
  assert.equal(p.current, "main");
  assert.equal(currentSceneText(p), text);
});

// ---------------------------------------------------------------- 切走要保存

test("★★ 切走前必须保存：源场景里**没保存过的改动**在切回来之后还在", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  createScene(deps, p); // 场景 1（空）
  assert.equal(p.current, "场景 1");

  // 回到 main，加一个节点（**不动槽位** —— 模拟"改了还没保存"）
  const back = switchScene(deps, p, "main");
  assert.equal(back.ok, true, back.ok ? "" : back.error.code);
  const added = deps.scene.spawnImmediate("后来加的", deps.scene.rootId);
  deps.scene.flush();

  switchScene(deps, p, "场景 1");
  assert.equal(deps.scene.find(added.id), undefined, "场景 1 里不该有 main 的节点");

  const again = switchScene(deps, p, "main");
  assert.equal(again.ok, true, again.ok ? "" : again.error.code);
  assert.equal(
    deps.scene.find(added.id)?.name,
    "后来加的",
    "切回来时那个节点不见了 —— 说明切走前没把源场景存下来（导出装的是目标内容）",
  );
});

test("★★ 切走再切回：内容逐字节一致（节点 id 写在文档里，所以外部记的 id 照样有效）", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  const t0 = DOC(deps);
  createScene(deps, p);
  const r = switchScene(deps, p, "main");
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assert.equal(DOC(deps), t0, "往返之后内容变了");
  // ★ 这一条是"内容一致"的**加强版**：id 一致意味着 `heroId` 这类外部引用也有效
  assert.equal(deps.scene.find(deps.seeded.b)?.name, "b", "往返之后节点 id 对不上了");
});

test("★★ 切到**当前**场景：kind=noop，一个节点实例都不换，历史与选中都不清", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  deps.history.push(new FieldOp(deps.scene, deps.seeded.a, "a", "zIndex", 0, 3));
  deps.selection.select(deps.seeded.b);
  const before = instances(deps);
  const r = switchScene(deps, p, "main");
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assert.equal(r.ok ? r.value.kind : "", "noop");
  // ★★ 判据的重点：实例引用必须还是原来那些。只比"节点还在"的话，
  //    `loadScene` 重建出来的节点**同样**满足 —— 那是本批最危险的一种假绿。
  const after = instances(deps);
  assert.equal(after[0], before[0], "切到当前场景却把节点实例换掉了（走了 loadScene）");
  assert.equal(after[1], before[1], "切到当前场景却把节点实例换掉了（走了 loadScene）");
  assert.equal(deps.history.history().undo.length, 1, "noop 不该清历史");
  assert.equal(deps.selection.size, 1, "noop 不该清选中");
});

test("★ 切到另一个场景再切回来：实例**一定**是新的（`loadScene` 的语义，不假装保住）", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  const before = instances(deps);
  createScene(deps, p);
  switchScene(deps, p, "main");
  const after = instances(deps);
  // ★ 把这条写成断言，是为了让"不重建"这句话**只在 noop 上成立**这件事留在判据里。
  //   哪天有人把跨场景也做成保实例，这条会红 —— 那时应当连同文档一起改，而不是删掉它。
  assert.notEqual(after[0], before[0], "跨场景往返竟然保住了实例？那 noop 与它就没区别了");
});

// ---------------------------------------------------------------- 失败面

test("切到不存在的场景：报 EDIT_NO_SUCH_SCENE，场景一个字节都没动", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  const before = instances(deps);
  const t0 = DOC(deps);
  const r = switchScene(deps, p, "并不存在");
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, EDIT_NO_SUCH_SCENE);
  assert.equal(p.current, "main");
  assert.equal(DOC(deps), t0);
  assert.equal(instances(deps)[0], before[0]);
});

test("★★ 目标文档坏掉：切不动、current 不变，且场景被回灌成原样", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  const t0 = DOC(deps);
  p.scenes.push({ name: "坏的", text: "{这不是 JSON" });
  const r = switchScene(deps, p, "坏的");
  assert.equal(r.ok, false);
  assert.equal(p.current, "main", "切失败了却把当前项改了 —— 之后每次切走都会把 A 写进 B 的槽位");
  assert.equal(DOC(deps), t0, "切失败把正在编辑的场景吃掉了");
});

test("★★ 切走前保存失败：报 EDIT_SAVE_FAILED，场景不动（连实例都不许换）", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  createScene(deps, p);
  switchScene(deps, p, "main");
  const before = instances(deps);
  // 现在 main 里挂一个"导出会抛"的组件 ⇒ 下一次切走时保存必然失败
  deps.scene.attach(deps.seeded.a, () => new BadSave());
  deps.scene.flush();
  const r = switchScene(deps, p, "场景 1");
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, EDIT_SAVE_FAILED);
  assert.equal(p.current, "main", "保存失败却把当前项改了");
  assert.equal(instances(deps)[0], before[0], "保存失败却重建了场景");
  // 半存半切最糟：槽位也不该被写坏
  assert.notEqual(slotAt(p, 0).text, "", "保存失败把槽位清空了");
});

// ---------------------------------------------------------------- 新建 / 删除

test("★★ 新建场景的名字按编号避让（删掉中间几个之后不许撞上现存的）", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  createScene(deps, p); // 场景 1
  createScene(deps, p); // 场景 2
  createScene(deps, p); // 场景 3
  assert.deepEqual(sceneNames(p), ["main", "场景 1", "场景 2", "场景 3"]);
  // 删掉前两个（都不是当前项）⇒ 列表 = [main, 场景 3]，长度 2
  deleteScene(deps, p, "场景 1");
  deleteScene(deps, p, "场景 2");
  assert.deepEqual(sceneNames(p), ["main", "场景 3"]);
  // ★ 朴素实现是「场景 ${length+1}」= 长度 2 ⇒ 「场景 3」——**正好撞上现存的**。
  //   撞名之后 `slotOf` 只会返回第一个，于是"新建"变成"切到已有场景"，
  //   而界面上看起来一切正常（列表多一行、当前项也换了）。
  assert.equal(freeSceneName(p), "场景 1");
  createScene(deps, p);
  assert.deepEqual(sceneNames(p), ["main", "场景 3", "场景 1"]);
  assert.equal(new Set(sceneNames(p)).size, 3, "自动名字撞了已有的场景");
});

test("★ 新建重名：报 EDIT_SCENE_EXISTS，列表不多出一行", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  const n0 = p.scenes.length;
  const r = createScene(deps, p, "main");
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, EDIT_SCENE_EXISTS);
  assert.equal(p.scenes.length, n0);
  assert.equal(p.current, "main");
});

test("★★ 删当前场景：切到**后一个**；删的是列表末项时切到前一个", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  createScene(deps, p); // 场景 1
  createScene(deps, p); // 场景 2（当前）
  // 现在在「场景 2」（末项）⇒ 删它应当回到前一个「场景 1」
  const r1 = deleteScene(deps, p);
  assert.equal(r1.ok, true, r1.ok ? "" : r1.error.code);
  assert.equal(p.current, "场景 1", "删掉末项时应当切到前一个");
  // 当前是「场景 1」，它后面还有 main? 不 —— 列表是 [main, 场景 1]，
  // 删掉场景 1 之后邻居是 main（前一个）。
  const r2 = deleteScene(deps, p);
  assert.equal(r2.ok, true, r2.ok ? "" : r2.error.code);
  assert.equal(p.current, "main");
  assert.equal(p.scenes.length, 1);
});

test("★★ 删当前场景时**不保存**它：邻居的槽位要原样，被删的内容不许流进去", () => {
  const deps = setup();
  const mainText = DOC(deps);
  const p = createProject("main", mainText);
  createScene(deps, p); // 场景 1（当前，空）
  // 在「场景 1」里加节点 ⇒ 若"删当前"实现里顺手做了 `saveCurrent` + 装载邻居，
  // 那还无所谓；真正要防的是"把当前场景的内容写进了邻居的槽位"。
  deps.scene.spawnImmediate("即将跟着一起消失", deps.scene.rootId);
  deps.scene.flush();
  const r = deleteScene(deps, p);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assert.equal(p.current, "main");
  assert.deepEqual(sceneNames(p), ["main"]);
  assert.equal(currentSceneText(p), mainText, "main 的槽位被这次删除改写了");
  assert.equal(DOC(deps), mainText, "删完之后场景里应当是 main 的内容");
});

test("★ 只剩一个场景时删除被拒（EDIT_LAST_SCENE），什么都不删", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  const r = deleteScene(deps, p);
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, EDIT_LAST_SCENE);
  assert.deepEqual(sceneNames(p), ["main"]);
});

test("★ 删的不是当前场景：纯列表操作，场景的节点实例恒等", () => {
  const deps = setup();
  const p = createProject("main", DOC(deps));
  createScene(deps, p); // 场景 1（当前）
  createScene(deps, p); // 场景 2（当前）
  switchScene(deps, p, "main");
  const before = instances(deps);
  const r = deleteScene(deps, p, "场景 1"); // 不是当前
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  assert.deepEqual(sceneNames(p), ["main", "场景 2"]);
  assert.equal(p.current, "main");
  assert.equal(instances(deps)[0], before[0], "删别人的槽位却重建了我的场景");
});
