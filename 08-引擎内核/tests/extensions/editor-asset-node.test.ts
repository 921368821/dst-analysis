/**
 * L4 · 编辑器：资产 → 带精灵的节点（批86）
 *
 * 这一组里最重的一条是**「一次撤销就够」**：
 * 如果实现成「先 `createNodeWithUndo` 再 `attachComponentWithUndo`」，
 * 那会是两条历史 —— 按一次撤销只退掉精灵，留下一个空节点。
 * 而人做的动作是「把一个图标拖进场景」，他期望它整个消失。
 * 症状是"撤销之后世界里多了一个看不见的节点"，要翻树才看得见。
 *
 * 第二类判据是**「拒绝的时候场里不能留半截」**：
 * 图集里没有那一帧时必须报错，而且**一个节点都不能多**
 * （先建节点再校验的话，错误码是对的、世界却脏了）。
 *
 * 第三类判据是**重做回来的帧**：
 * 快照若在挂精灵**之前**拍，重做回来的是个没精灵的空节点 ——
 * 画面上与"资产没加载"完全一样，只有查组件才分得出来。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { NodeId } from "../../src/core/scene/node.ts";
import { Sprite, SPRITE_TYPE } from "../../src/extensions/render/sprite.ts";
import { createUndoStack } from "../../src/extensions/editor/undo-stack.ts";
import {
  EDIT_BAD_NAME,
  EDIT_BAD_NODE,
  EDIT_NO_FRAME,
  addSpriteNodeWithUndo,
} from "../../src/extensions/editor/undo-ops.ts";

/** 与编辑器的程序化图集同名的那几帧。 */
const FRAMES = ["tree", "rock", "player", "berry", "ground", "terrain"];

function makeScene(): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("asset-node", reg);
  scene.flush();
  return { scene, reg };
}

const hasFrame = (f: string): boolean => FRAMES.includes(f);

function nodeCount(scene: Scene): number {
  let n = 0;
  scene.root.walk((x) => {
    if (x.id !== scene.rootId) n += 1;
  });
  return n;
}

function spriteOf(scene: Scene, id: NodeId): Sprite | undefined {
  return scene.find(id)?.get<Sprite>(SPRITE_TYPE);
}

test("加入场景：节点建出来、精灵挂上、帧与位置都对", () => {
  const { scene, reg } = makeScene();
  const r = addSpriteNodeWithUndo(scene, reg, {
    name: "tree",
    frame: "tree",
    position: { x: 3, y: -2 },
    hasFrame,
  });
  assert.equal(r.ok, true, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  if (!r.ok) return;

  assert.equal(nodeCount(scene), 1);
  assert.equal(r.value.op.label, "加入 tree");
  const n = scene.find(r.value.nodeId);
  assert.ok(n !== undefined, "节点不见了");
  assert.equal(n.name, "tree");
  assert.equal(n.localPosition.x, 3);
  assert.equal(n.localPosition.y, -2);
  assert.equal(spriteOf(scene, r.value.nodeId)?.frame, "tree", "精灵没挂上或帧没写进去");
});

test("★★ 一次撤销就够：节点连同精灵一起消失（不是留一个空节点）", () => {
  const { scene, reg } = makeScene();
  const h = createUndoStack();
  const r = addSpriteNodeWithUndo(scene, reg, { name: "rock", frame: "rock", hasFrame });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;

  scene.spawnImmediate("旁观者", scene.rootId); // 场里本来就有别的节点，撤销不该碰它
  scene.flush();
  assert.equal(nodeCount(scene), 2);

  h.push(r.value.op);
  const out = h.undo();
  assert.equal(out.kind, "done", `撤销结果不是 done：${JSON.stringify(out)}`);
  assert.equal(nodeCount(scene), 1, "撤销一次之后还剩东西 —— 说明压的是两条历史");
  assert.equal(scene.find(r.value.nodeId), undefined);
});

test("★★ 重做回来的帧还是那个（快照要在挂精灵之后拍）", () => {
  const { scene, reg } = makeScene();
  const h = createUndoStack();
  const r = addSpriteNodeWithUndo(scene, reg, { name: "berry", frame: "berry", hasFrame });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;

  h.push(r.value.op);
  assert.equal(h.undo().kind, "done");
  assert.equal(h.redo().kind, "done");

  // 节点 id 会变（销毁后重建），所以按名字找回来，再看它的精灵
  let found: NodeId | undefined;
  scene.root.walk((n) => {
    if (n.name === "berry") found = n.id;
  });
  assert.ok(found !== undefined, "重做之后节点没回来");
  assert.equal(spriteOf(scene, found)?.frame, "berry", "重做回来的精灵帧是空的 —— 快照拍早了");
});

test("★ 图集没有那一帧：拒绝，且场里一个节点都不多", () => {
  const { scene, reg } = makeScene();
  const r = addSpriteNodeWithUndo(scene, reg, { name: "photo", frame: "photo", hasFrame });
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, EDIT_NO_FRAME);
  assert.ok(r.error.message.includes("photo"), `消息里得带上资产名：${r.error.message}`);
  assert.equal(nodeCount(scene), 0, "被拒的操作在世界里留下了节点 —— 半截状态");
});

test("空帧名也被拒（解析不出名字的资产不该建节点）", () => {
  const { scene, reg } = makeScene();
  const r = addSpriteNodeWithUndo(scene, reg, { name: "x", frame: "  ", hasFrame });
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, EDIT_NO_FRAME);
});

test("空名字 / 父节点不在：各自的错误码，且不留半截", () => {
  const { scene, reg } = makeScene();
  const empty = addSpriteNodeWithUndo(scene, reg, { name: "   ", frame: "tree", hasFrame });
  assert.equal(empty.ok, false);
  if (!empty.ok) assert.equal(empty.error.code, EDIT_BAD_NAME);

  const ghost = addSpriteNodeWithUndo(scene, reg, {
    name: "tree",
    frame: "tree",
    parent: 9999,
    hasFrame,
  });
  assert.equal(ghost.ok, false);
  if (!ghost.ok) assert.equal(ghost.error.code, EDIT_BAD_NODE);

  assert.equal(nodeCount(scene), 0);
});

test("指定父节点：真的挂在那下面", () => {
  const { scene, reg } = makeScene();
  const host = scene.spawnImmediate("货架", scene.rootId);
  scene.flush();
  const r = addSpriteNodeWithUndo(scene, reg, {
    name: "tree",
    frame: "tree",
    parent: host.id,
    hasFrame,
  });
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  assert.equal(scene.find(r.value.nodeId)?.parent?.id, host.id);
  assert.equal(nodeCount(scene), 2);
});
