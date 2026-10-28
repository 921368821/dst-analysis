/**
 * UI 过渡判据：补间采样写进 `UiNode` 的那一段
 *
 * 三块，分别对应三种"错了也看不出来"的失败：
 *   ① **值域收口**（`applyUiTween`）：`opacity` 超出 0..1、`scale` 为负、`NaN`。
 *      NaN 落进 `opacity` 会让整棵子树消失，而那是最难定位的症状，所以写入点就拒。
 *   ② **缩放只改矩形、不改 measured**（`layout.ts`）：改 measured 的话，弹一下的按钮
 *      会把它后面的按钮挤开 —— 过渡就变成了"重新排版"。
 *   ③ **不透明度沿父链连乘**（`widgets.ts`）：父 0.5 × 子 0.5 = 0.25；取最终值会让
 *      子节点的 0.5 静默覆盖父节点的 0.5。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Color, Rect } from "../../src/foundation/math/index.ts";
import { buildUiTree, layoutTree, UiNode, UiWidget, hitTest } from "../../src/extensions/ui/layout.ts";
import { buildUiQuads, type UiSkin } from "../../src/extensions/ui/widgets.ts";
import { UiStateStore } from "../../src/extensions/ui/state.ts";
import { FontRegistry } from "../../src/extensions/ui/font.ts";
import { applyUiSamples, applyUiTween, isUiTweenProp, UI_TWEEN_PROP } from "../../src/extensions/ui/ui-transition.ts";
import type { TrackSample } from "../../src/extensions/tween/tween-player.ts";
import { advancePlayer, TweenPlayer } from "../../src/extensions/tween/tween-player.ts";

const FRAME = { page: 0, u0: 0, v0: 0, u1: 1, v1: 1, width: 32, height: 32 };
function skinOf(): UiSkin {
  return { frames: new Map([["panel", FRAME]]) };
}

/** 跑一遍布局 + 出四边形，返回四边形列表（UI 判据的常规两步）。 */
function quadsOf(root: UiNode): ReturnType<typeof buildUiQuads>["quads"] {
  layoutTree(root, new Rect(0, 0, 400, 300));
  return buildUiQuads(root, new FontRegistry(), skinOf(), new UiStateStore()).quads;
}

function sample(over: Partial<TrackSample> = {}): TrackSample {
  return { id: "t", targetId: "n", prop: UI_TWEEN_PROP.Opacity, value: 0.5, done: false, changed: true, ...over };
}

// ── ① 值域收口 ─────────────────────────────────────────────

test("opacity 钳到 0..1（动画过冲不该让面板消失或超亮）", () => {
  const n = new UiNode({ id: "a" });
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.Opacity, 1.4), true);
  assert.equal(n.opacity, 1);
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.Opacity, -0.3), true);
  assert.equal(n.opacity, 0);
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.Opacity, 0.25), true);
  assert.equal(n.opacity, 0.25);
});

test("scale 负值夹到 0（负缩放是镜像，命中测试的矩形会反向）", () => {
  const n = new UiNode({ id: "a" });
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.Scale, -2), true);
  assert.equal(n.scale, 0);
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.Scale, 2.5), true);
  assert.equal(n.scale, 2.5);
});

test("★★ 非有限值不写（NaN 落进 opacity 会让整棵子树消失）", () => {
  const n = new UiNode({ id: "a" });
  n.opacity = 0.75;
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.Opacity, Number.NaN), false);
  assert.equal(n.opacity, 0.75, "被拒绝的值不该改动节点");
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.Scale, Number.POSITIVE_INFINITY), false);
  assert.equal(n.scale, 1);
});

test("未知属性返回 false（拼错的属性名要能被数出来，而不是静默）", () => {
  const n = new UiNode({ id: "a" });
  assert.equal(applyUiTween(n, "rotatoin", 1), false);
  assert.equal(isUiTweenProp("rotatoin"), false);
  assert.equal(isUiTweenProp("opacity"), true);
});

test("offsetX 只改 x、offsetY 只改 y（各走一条轨道时互不覆盖）", () => {
  const n = new UiNode({ id: "a", offset: { x: 3, y: 4 } });
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.OffsetX, 10), true);
  assert.deepEqual(n.offset, { x: 10, y: 4 });
  assert.equal(applyUiTween(n, UI_TWEEN_PROP.OffsetY, -7), true);
  assert.deepEqual(n.offset, { x: 10, y: -7 });
});

test("★ applyUiSamples 把四类结果分开计数（找不到目标不等于属性名写错）", () => {
  const a = new UiNode({ id: "a" });
  const index = (id: string): UiNode | undefined => (id === "a" ? a : undefined);
  const r = applyUiSamples(
    [
      sample({ targetId: "a", prop: "opacity", value: 0.5, changed: true }),
      sample({ targetId: "a", prop: "opacity", value: 0.5, changed: false }),
      sample({ targetId: "gone", prop: "opacity" }),
      sample({ targetId: "a", prop: "nope" }),
    ],
    index,
  );
  assert.equal(r.applied, 2);
  assert.equal(r.changed, 1, "值没变的那条不算 changed");
  assert.equal(r.missingNode, 1);
  assert.equal(r.unknownProp, 1);
});

// ── ② 缩放：只改矩形，不改 measured ─────────────────────────

test("★★ 缩放绕 pivot 放大矩形，但**不挤开兄弟**（过渡不是重排版）", () => {
  const root = buildUiTree({
    id: "root",
    size: { w: 400, h: 300 },
    children: [
      { id: "a", size: { w: 100, h: 50 }, offset: { x: 10, y: 20 }, scale: 2 },
      { id: "b", size: { w: 100, h: 50 }, offset: { x: 150, y: 20 } },
    ],
  });
  layoutTree(root, new Rect(0, 0, 400, 300));
  const a = root.find("a");
  const b = root.find("b");
  assert.ok(a !== undefined && b !== undefined);
  // pivot 默认左上 ⇒ 左上角不动、宽高翻倍
  assert.equal(a.rect.x, 10);
  assert.equal(a.rect.y, 20);
  assert.equal(a.rect.width, 200);
  assert.equal(a.rect.height, 100);
  assert.equal(b.rect.x, 150, `b 被挤开了：x=${String(b.rect.x)}`);
  assert.equal(a.measured.w, 100, "measured 必须保持原尺寸（否则父的流式布局会算进放大）");
});

test("★ pivot 在中心时绕中心放大（不是永远从左上角长）", () => {
  const root = buildUiTree({
    id: "root",
    size: { w: 400, h: 300 },
    children: [
      { id: "a", size: { w: 100, h: 50 }, offset: { x: 100, y: 50 }, pivot: { x: 0.5, y: 0.5 }, scale: 2 },
    ],
  });
  layoutTree(root, new Rect(0, 0, 400, 300));
  const a = root.find("a");
  assert.ok(a !== undefined);
  // ★ pivot 同时参与**锚点定位**：pivot=0.5 时 rect.x = 0 + 0 - 0.5×100 + 100 = 50，
  //   即未缩放矩形 x=50..150，中心 100。绕中心放大 2 倍 ⇒ x=0..200。
  assert.equal(a.rect.x, 0, `实际 ${String(a.rect.x)}`);
  assert.equal(a.rect.width, 200);
  assert.equal(a.rect.x + a.rect.width / 2, 100, "中心不动");
});

test("★ 缩放后的矩形参与命中测试（看得见的地方才点得到）", () => {
  const root = buildUiTree({
    id: "root",
    size: { w: 400, h: 300 },
    children: [{ id: "a", widget: UiWidget.Panel, interactive: true, size: { w: 100, h: 50 }, scale: 2 }],
  });
  layoutTree(root, new Rect(0, 0, 400, 300));
  // 原尺寸只到 (100,50)；放大 2 倍后 (150,80) 也在范围内
  assert.equal(hitTest(root, 150, 80)?.id, "a");
});

test("★ 子节点跟着父节点一起缩放（整体弹出，不是各自从左上角放大）", () => {
  const root = buildUiTree({
    id: "root",
    size: { w: 400, h: 300 },
    children: [
      {
        id: "box",
        size: { w: 100, h: 100 },
        scale: 2,
        children: [{ id: "inner", size: { w: 50, h: 50 }, offset: { x: 25, y: 25 } }],
      },
    ],
  });
  layoutTree(root, new Rect(0, 0, 400, 300));
  const inner = root.find("inner");
  assert.ok(inner !== undefined);
  assert.equal(inner.rect.x, 50, "子节点在缩放后的内区里 ⇒ 25×2");
  assert.equal(inner.rect.width, 100, "子节点自身也被放大 ⇒ 50×2");
});

// ── ③ 不透明度：沿父链连乘，落到顶点 alpha ─────────────────

test("★★ 不透明度乘进四边形 alpha", () => {
  const root = buildUiTree({
    id: "root",
    size: { w: 400, h: 300 },
    children: [{ id: "p", widget: UiWidget.Panel, size: { w: 100, h: 50 }, opacity: 0.5, props: { frame: "panel" } }],
  });
  const q = quadsOf(root);
  assert.equal(q.length, 1);
  assert.equal(q[0]?.a, 0.5);
});

test("★★ 父子连乘：父 0.5 × 子 0.5 = 0.25（不是取子节点的最终值）", () => {
  const root = buildUiTree({
    id: "root",
    size: { w: 400, h: 300 },
    children: [
      {
        id: "group",
        size: { w: 400, h: 300 },
        opacity: 0.5,
        children: [{ id: "p", widget: UiWidget.Panel, size: { w: 100, h: 50 }, opacity: 0.5, props: { frame: "panel" } }],
      },
    ],
  });
  const q = quadsOf(root);
  assert.equal(q.length, 1);
  assert.equal(q[0]?.a, 0.25);
});

test("★ 与 props.tint 的 alpha 也相乘（染色 + 淡入可以同时用）", () => {
  const root = buildUiTree({
    id: "root",
    size: { w: 400, h: 300 },
    children: [
      {
        id: "p",
        widget: UiWidget.Panel,
        size: { w: 100, h: 50 },
        opacity: 0.5,
        props: { frame: "panel", tint: new Color(1, 1, 1, 0.5) },
      },
    ],
  });
  const q = quadsOf(root);
  assert.equal(q[0]?.a, 0.25);
});

test("★ 完全不透明的节点不该额外产生四边形（淡到 0 就是真的不画）", () => {
  const root = buildUiTree({
    id: "root",
    size: { w: 400, h: 300 },
    children: [{ id: "p", widget: UiWidget.Panel, size: { w: 100, h: 50 }, opacity: 0, props: { frame: "panel" } }],
  });
  assert.equal(quadsOf(root).length, 0);
});

// ── 批117：合成之后的两个消费者必须看到同一个数 ──────────────
//   推进器算出的是"合成值"，UI 这一层只负责写；`applied === 1` 证明
//   同一属性**没有**被写两次（写两次时第二次会盖掉第一次的合法值）。

test("★★ 两条轨道写同一属性 ⇒ 写进节点的只有一次，且是合成后的值", () => {
  const p = new TweenPlayer();
  assert.ok(
    p.addTrack({ id: "base", targetId: "panel", prop: UI_TWEEN_PROP.Opacity, spec: { id: "b", from: 0, to: 1, durationMs: 100, easing: "linear" } }).ok,
  );
  assert.ok(
    p.addTrack({
      id: "dim",
      targetId: "panel",
      prop: UI_TWEEN_PROP.Opacity,
      composite: "multiply",
      spec: { id: "d", from: 1, to: 0.5, durationMs: 100, easing: "linear" },
    }).ok,
  );
  const node = new UiNode({ id: "panel" });
  node.opacity = 1;
  // 走 50ms：base = 0.5，dim = 0.75 ⇒ 合成 0.375
  const r = applyUiSamples(advancePlayer(p, 50), (id) => (id === "panel" ? node : undefined));
  assert.equal(r.applied, 1, "一个属性只写一次");
  assert.equal(r.changed, 1);
  assert.equal(node.opacity, 0.375, "写进去的是合成值（0.5 × 0.75），不是任一条的采样");
});
