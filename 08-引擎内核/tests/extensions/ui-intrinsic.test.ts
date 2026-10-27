/**
 * 「标签自撑开」判据（ADR-0012 的第一个消费者）
 *
 * 这一层守的是"**布局真的用上了量算结果**"，而不是"量算算得对"（那是 text-layout 的事）。
 * 三种最容易写坏的地方：
 *   ① 量了但没写回 `contentSize` ⇒ 父容器仍然看不见这个节点占多少位置（半条链）；
 *   ② 布局与绘制各算一个换行宽 ⇒ 盒子按 A 宽排、字按 B 宽折，字溢出边框一点点；
 *   ③ 没有显式宽时按父容器宽换行 ⇒ 本该"收缩到内容"的标签撑满整行（CSS 里
 *      `width:auto` 与 `width:100%` 的差别，默认必须是前者）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Color, Rect } from "../../src/foundation/math/index.ts";
import { FontRegistry } from "../../src/extensions/ui/font.ts";
import { buildUiTree, layoutTree, UiLayoutKind, UiWidget, type UiNode } from "../../src/extensions/ui/layout.ts";
import { UiStateStore } from "../../src/extensions/ui/state.ts";
import {
  BUTTON_TEXT_INSET,
  createIntrinsicMeasure,
  defaultFontId,
  textBoxOf,
  textInsetOf,
  textStyleFor,
} from "../../src/extensions/ui/intrinsic.ts";
import { layoutText } from "../../src/extensions/ui/text-layout.ts";
import { FONT_LINE_HEIGHT, makeTestFont } from "./ui-fixtures.ts";

/** 夹具：每个非空格字形前进 12 像素、行高 20。 */
const ADV = 12;
const LH = FONT_LINE_HEIGHT;

function fonts(): FontRegistry {
  const r = new FontRegistry();
  r.register(makeTestFont());
  return r;
}

function measureOf(f: FontRegistry, st: UiStateStore) {
  return createIntrinsicMeasure(f, st);
}

const BOUNDS = new Rect(0, 0, 400, 300);

// ── 自撑开本身 ──────────────────────────────────────────────

test("★ 没给宽度的标签按文本撑开：3 个字的宽 = 36、高 = 行高", () => {
  const f = fonts();
  const tree = buildUiTree({ id: "root", children: [{ id: "lbl", widget: UiWidget.Label, props: { text: "ABC" } }] });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const lbl = tree.find("lbl")!;
  assert.equal(lbl.measured.w, 3 * ADV);
  assert.equal(lbl.measured.h, LH);
  assert.equal(lbl.contentSize.w, 3 * ADV, "量算结果要写回 contentSize（诊断能看见）");
  assert.equal(lbl.rect.width, 3 * ADV, "摆出来的矩形也要是文本宽");
});

test("★ 撑开之后父容器的流式布局真的把它算进去了（第二个标签被推后）", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "bar",
        kind: UiLayoutKind.Row,
        gap: 4,
        size: { w: 300, h: 40 },
        children: [
          { id: "a", widget: UiWidget.Label, props: { text: "AB" } },
          { id: "b", widget: UiWidget.Label, props: { text: "C" } },
        ],
      },
    ],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const a = tree.find("a")!;
  const b = tree.find("b")!;
  assert.equal(a.rect.width, 2 * ADV);
  assert.equal(b.rect.x, a.rect.x + 2 * ADV + 4, "gap 之前必须先有第一个标签的宽度");
});

test("★ 列布局里撑开的高度也会传递（换行的标签把下面的元素推下去）", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "col",
        kind: UiLayoutKind.Column,
        gap: 0,
        size: { w: 100, h: 200 },
        children: [
          { id: "wrap", widget: UiWidget.Label, size: { w: 40 }, props: { text: "ABCD" } },
          { id: "after", widget: UiWidget.Label, props: { text: "A" } },
        ],
      },
    ],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const wrap = tree.find("wrap")!;
  const after = tree.find("after")!;
  assert.equal(wrap.measured.h, 2 * LH, "ABCD 在 40 宽里硬断成两行");
  assert.equal(after.rect.y, wrap.rect.y + 2 * LH, "后面的元素按两行高往下排");
});

test("空文本不表态（标签不占位，也不改写配置里的 contentSize）", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [{ id: "e", widget: UiWidget.Label, contentSize: { w: 9, h: 9 }, props: { text: "" } }],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const e = tree.find("e")!;
  assert.equal(e.contentSize.w, 9, "注入口没表态 ⇒ 配置值原样保留");
  assert.equal(e.measured.w, 9);
});

test("非文本控件不表态（面板/图片/进度条的自然尺寸不归这一层定义）", () => {
  const f = fonts();
  const store = new UiStateStore();
  const m = measureOf(f, store);
  for (const w of [UiWidget.Panel, UiWidget.Image, UiWidget.Progress, UiWidget.Group, UiWidget.Spacer]) {
    const n = buildUiTree({ id: "n", widget: w, props: { text: "ABC" } });
    assert.equal(m(n, 100, 100), null, `${w} 不该被文本撑开`);
  }
  assert.equal(store.misses, 0, "不表态的控件连一次排版都不该做");
});

test("★ 字体不存在 ⇒ 不表态（量不出来就**不要**假装量出 0 宽）", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [{ id: "x", widget: UiWidget.Label, props: { text: "ABC", fontId: "nope" } }],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const x = tree.find("x")!;
  assert.equal(x.measured.w, 0, "退回原来的行为（contentSize = 0）");
});

test("★ 没给宽度时**不按父容器换行**（收缩到内容，不是撑满整行）", () => {
  const f = fonts();
  // 父容器只有 50 宽，文本 8 个字 = 96 宽：仍然单行（内容宽可以超出父容器）
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "box",
        size: { w: 50, h: 100 },
        children: [{ id: "lbl", widget: UiWidget.Label, props: { text: "ABCDEFGH" } }],
      },
    ],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const lbl = tree.find("lbl")!;
  assert.equal(lbl.measured.h, LH, "单行：没有按 50 宽折行");
  assert.equal(lbl.measured.w, 8 * ADV);
});

test("显式宽度里才换行：宽 40 的 ABCD 变成两行，宽不变", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [{ id: "lbl", widget: UiWidget.Label, size: { w: 40 }, props: { text: "ABCD" } }],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const lbl = tree.find("lbl")!;
  assert.equal(lbl.measured.w, 40, "显式宽优先");
  assert.equal(lbl.measured.h, 2 * LH);
});

test("显式宽度里放得下 ⇒ 仍是一行（别无条件多给一行）", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [{ id: "lbl", widget: UiWidget.Label, size: { w: 100 }, props: { text: "ABC" } }],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  assert.equal(tree.find("lbl")!.measured.h, LH);
});

test("百分比宽也按显式宽处理（percent 同样是作者的意图）", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "box",
        size: { w: 100, h: 100 },
        children: [{ id: "lbl", widget: UiWidget.Label, percent: { w: 0.4 }, props: { text: "ABCD" } }],
      },
    ],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const lbl = tree.find("lbl")!;
  assert.equal(lbl.measured.w, 40);
  assert.equal(lbl.measured.h, 2 * LH, "40 宽放不下 48 宽的四个字");
});

// ── 按钮：内缩必须两边一致 ─────────────────────────────────

test("★ 按钮的宽度包含两侧内缩（文字宽 + 2×4），否则字会贴边", () => {
  const f = fonts();
  const tree = buildUiTree({ id: "root", children: [{ id: "btn", widget: UiWidget.Button, props: { text: "ABC" } }] });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  const btn = tree.find("btn")!;
  assert.equal(btn.measured.w, 3 * ADV + BUTTON_TEXT_INSET * 2);
  assert.equal(btn.measured.h, LH);
});

test("★ 按钮的换行宽比标签少 8：宽 60 的按钮里 5 个字（60 宽）要折行", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [{ id: "btn", widget: UiWidget.Button, size: { w: 60 }, props: { text: "ABCDE" } }],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  // 换行宽 = 60 − 8 = 52 < 60 ⇒ 硬断成两行
  assert.equal(tree.find("btn")!.measured.h, 2 * LH);
});

test("textBoxOf：标签原样返回，按钮两侧各内缩 4，极窄时不出现负宽", () => {
  const label = buildUiTree({ id: "l", widget: UiWidget.Label });
  const btn = buildUiTree({ id: "b", widget: UiWidget.Button });
  const r = new Rect(10, 20, 100, 30);
  assert.equal(textBoxOf(label, r), r);
  const inner = textBoxOf(btn, r);
  assert.deepEqual([inner.x, inner.width, inner.height], [14, 92, 30]);
  const tiny = textBoxOf(btn, new Rect(0, 0, 6, 10));
  assert.equal(tiny.width, 0, "宽小于 2×内缩时夹到 0，不给负数");
  assert.equal(textInsetOf(UiWidget.Label), 0);
  assert.equal(textInsetOf(UiWidget.Panel), -1);
});

test("textStyleFor：显式 maxWidth 优先于盒子宽；缺省对齐按控件类型", () => {
  const label = buildUiTree({ id: "l", widget: UiWidget.Label, props: { text: "A" } });
  const btn = buildUiTree({ id: "b", widget: UiWidget.Button, props: { text: "A" } });
  assert.equal(textStyleFor(label, 80).maxWidth, 80);
  assert.equal(textStyleFor(label, 80).align, "left");
  assert.equal(textStyleFor(btn, 80).align, "center");
  const pinned = buildUiTree({ id: "p", widget: UiWidget.Label, props: { text: "A", style: { maxWidth: 33 } } });
  assert.equal(textStyleFor(pinned, 80).maxWidth, 33, "作者写了换行宽就按作者的");
});

test("textStyleFor：textColor 覆盖 style.color（与绘制原有的优先级一致）", () => {
  const n = buildUiTree({
    id: "c",
    widget: UiWidget.Label,
    props: { text: "A", style: { color: new Color(0, 1, 0, 1) }, textColor: new Color(1, 0, 0, 1) },
  });
  assert.equal(textStyleFor(n, 10).color?.r, 1);
});

// ── 结构性不变量 ────────────────────────────────────────────

test("★★ 自撑开的标签在按测量宽排版时**必然不换行**（余量来自内缩与内边距）", () => {
  const f = fonts();
  const store = new UiStateStore();
  const tree = buildUiTree({
    id: "root",
    children: [
      { id: "a", widget: UiWidget.Label, padding: { left: 3, right: 5 }, props: { text: "ABCDEFG" } },
      { id: "b", widget: UiWidget.Button, props: { text: "ABCDEFG" } },
    ],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, store) });
  const font = f.require("test");
  for (const id of ["a", "b"]) {
    const n: UiNode = tree.find(id)!;
    // 绘制时用的换行宽 = textBoxOf 之后宽度
    const drawn = layoutText(font, "ABCDEFG", textStyleFor(n, textBoxOf(n, n.rect).width));
    assert.equal(drawn.lineCount, 1, `${id} 按测量宽绘制时不该折行`);
    assert.equal(drawn.height, LH);
  }
});

test("注入口对每个节点恰好问一次（容器也会被问，但不做排版）", () => {
  const f = fonts();
  const store = new UiStateStore();
  let asked = 0;
  const inner = measureOf(f, store);
  const spy = (n: UiNode, w: number, h: number) => {
    asked++;
    return inner(n, w, h);
  };
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "row",
        kind: UiLayoutKind.Row,
        size: { w: 200, h: 40 },
        children: [
          { id: "a", widget: UiWidget.Label, props: { text: "AB" } },
          { id: "b", widget: UiWidget.Label, props: { text: "CD" } },
        ],
      },
    ],
  });
  layoutTree(tree, BOUNDS, { intrinsic: spy });
  // 根 + row + 两个标签 = 4 次（每个节点一次），其中只有标签真的做了排版
  assert.equal(asked, 4, "每个节点恰好一次（measure 只走一趟）");
  assert.equal(store.misses, 2, "只有两个标签真的排了版");
});

test("★ 隐藏节点完全不参与（既不量也不占位）", () => {
  const f = fonts();
  const tree = buildUiTree({
    id: "root",
    children: [{ id: "h", widget: UiWidget.Label, visible: false, props: { text: "ABC" } }],
  });
  layoutTree(tree, BOUNDS, { intrinsic: measureOf(f, new UiStateStore()) });
  assert.equal(tree.find("h")!.measured.w, 0);
  assert.equal(tree.find("h")!.contentSize.w, 0, "不可见时不该被写进量算结果");
});

test("默认字体按 id 排序取第一个（注册顺序不该改变画面）", () => {
  const f = new FontRegistry();
  f.register(makeTestFont("zeta"));
  f.register(makeTestFont("alpha"));
  assert.equal(defaultFontId(f), "alpha");
  assert.equal(defaultFontId(new FontRegistry()), "");
});
