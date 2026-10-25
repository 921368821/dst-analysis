/**
 * L4 · 文本排版判据
 *
 * 每条都用手算的数字断言，因为这一层最容易"看起来对"：
 *   · 行宽差 2 像素（把 advance 当成 width）肉眼看不出来，但右对齐会溢出一格；
 *   · 换行点偏一个字，在一段话里几乎看不出来，但截断时少显示一个字；
 *   · 省略号没裁字，尾部会溢出容器 —— 而容器本身不报错。
 *
 * 夹具固定：非空格 advance = 12、空格 advance = 6、lineHeight = 20、base = 15。
 * 于是「n 个字 = 12n」可以在脑子里核。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { layoutText } from "../../src/extensions/ui/text-layout.ts";
import { Color } from "../../src/foundation/math/index.ts";
import { ELLIPSIS_CODE, FONT_BASE, FONT_LINE_HEIGHT, makeFontWith, makeTestFont } from "./ui-fixtures.ts";

const f = makeTestFont();

test("单行：两个字的宽 = 2×advance，第二个字的 x = 第一个的 advance", () => {
  const r = layoutText(f, "AB");
  assert.equal(r.quads.length, 2);
  assert.equal(r.width, 24, "12 + 12");
  assert.equal(r.height, FONT_LINE_HEIGHT);
  assert.equal(r.lineCount, 1);
  assert.equal(r.quads[0]?.x, 0);
  assert.equal(r.quads[1]?.x, 12, "推进用 xadvance，不是字形宽（10）");
  // 字形高 10、基线在第 15 行像素处，yoffset=0 ⇒ 顶边 y = 15
  assert.equal(r.quads[0]?.y, FONT_BASE);
  assert.equal(r.quads[0]?.w, 10);
});

test("★ 空格占宽度但不产生四边形（用 advance=6，与字宽不同）", () => {
  const r = layoutText(f, "A B");
  assert.equal(r.quads.length, 2, "空格不画");
  assert.equal(r.width, 30, "12 + 6 + 12");
  assert.equal(r.quads[1]?.x, 18, "空格之后光标在 18");
});

test("换行：maxWidth=30 时 ABCD 断成 AB / CD，行高翻倍", () => {
  const r = layoutText(f, "ABCD", { maxWidth: 30 });
  assert.equal(r.lineCount, 2);
  assert.equal(r.height, 40, "2 行 × lineHeight 20");
  assert.equal(r.width, 30, "有 maxWidth 时排版宽度就是它");
  const ys = new Set(r.quads.map((q) => q.y));
  assert.equal(ys.size, 2, "两行的 y 必须不同");
  assert.deepEqual([...ys].sort((a, b) => a - b), [FONT_BASE, FONT_BASE + FONT_LINE_HEIGHT]);
});

test("★ 词优先：aa bb 在 maxWidth=30 时在空格处断，且行尾空格被丢掉", () => {
  const r = layoutText(f, "aa bb", { maxWidth: 30 });
  assert.equal(r.lineCount, 2);
  // 第一行只有 aa（24），不是 "aa "（30）—— 行尾空格若留下，右对齐会多出 6 像素
  const firstLine = r.quads.filter((q) => q.y === FONT_BASE);
  assert.equal(firstLine.length, 2);
  assert.equal(r.quads[2]?.y, FONT_BASE + FONT_LINE_HEIGHT);
  assert.equal(r.quads[2]?.x, 0, "第二行从行首开始，不带前导空格");
});

test("超长单词按字符硬断（每行 2 个字 = 24 ≤ 30）", () => {
  const r = layoutText(f, "abcdef", { maxWidth: 30 });
  assert.equal(r.lineCount, 3, "6 个字 / 每行 2 个");
  assert.equal(r.height, 60);
  // 第三行只剩 ef
  const third = r.quads.filter((q) => q.y === FONT_BASE + 2 * FONT_LINE_HEIGHT);
  assert.equal(third.length, 2);
});

test("★ maxWidth 小于单字宽时不能死循环，且每行至少一个字", () => {
  const r = layoutText(f, "ABC", { maxWidth: 5 });
  assert.equal(r.lineCount, 3, "一个字都放不下时，一行一个字");
  assert.equal(r.quads.length, 3);
});

test("对齐相对**容器宽度**：center / right 的起点可手算", () => {
  const left = layoutText(f, "AB", { maxWidth: 100 });
  const center = layoutText(f, "AB", { maxWidth: 100, align: "center" });
  const right = layoutText(f, "AB", { maxWidth: 100, align: "right" });
  assert.equal(left.quads[0]?.x, 0);
  assert.equal(center.quads[0]?.x, 38, "(100 − 24) / 2");
  assert.equal(right.quads[0]?.x, 76, "100 − 24");
  // 三种对齐的宽度一致，只有起点不同
  assert.equal(center.width, 100);
  assert.equal(right.width, 100);
});

test("★ 省略号：超出行数时真的裁字并加省略号，总宽不超容器", () => {
  const r = layoutText(f, "ABCDEF", { maxWidth: 30, maxLines: 1 });
  assert.equal(r.lineCount, 1);
  assert.equal(r.truncated, true);
  // 省略号本身占 12：第一行 AB(24) + 12 = 36 > 30 ⇒ 删到 A(12) + 12 = 24 ≤ 30
  const xs = r.quads.map((q) => q.x);
  assert.deepEqual(xs, [0, 12], "留下 A 与省略号");
  assert.equal(r.quads.length, 2);
  const last = r.quads[1];
  assert.ok(last !== undefined);
  assert.ok(last.x + last.w <= 30, "省略号不能溢出容器");
  // 省略号真的画出来了（不是只置了 truncated 标志）
  assert.equal(f.glyphs.has(ELLIPSIS_CODE), true);
});

test("★ 没超行数时不该有省略号（truncated 不能恒真）", () => {
  const r = layoutText(f, "AB", { maxWidth: 100, maxLines: 3 });
  assert.equal(r.truncated, false);
  assert.equal(r.quads.length, 2);
  const hasEllipsis = r.quads.some((q) => q.u0 === f.glyphs.get(ELLIPSIS_CODE)?.u0);
  assert.equal(hasEllipsis, false);
});

test("缺字：不画、但仍占 advance，且去重升序记录", () => {
  // 只含 A 与 B 的字体，文本里塞 Z 与 Y
  const partial = makeFontWith([65, 66]);
  const r = layoutText(partial, "AZBY");
  // 文本 AZBY：A(65) 有、Z(90) 缺、B(66) 有、Y(89) 缺 ⇒ 只报 89 与 90，且升序
  assert.deepEqual([...r.missing], [89, 90], "只报真正缺的码点，且升序去重");
  assert.equal(r.quads.length, 2, "A 与 B 画出来，Z/Y 不画");
  // Z 占的是 missingAdvance = size/2 = 8
  const bQuad = r.quads[1];
  assert.ok(bQuad !== undefined);
  assert.equal(bQuad.x, 12 + 8, "A(12) + 缺字占位(8)");
});

test("多行 + 显式换行：空行也占一行高度", () => {
  const r = layoutText(f, "A\n\nB");
  assert.equal(r.lineCount, 3);
  assert.equal(r.height, 60);
  assert.equal(r.quads.length, 2);
  assert.equal(r.quads[1]?.y, FONT_BASE + 2 * FONT_LINE_HEIGHT);
});

test("空文本 / 纯空白：不占高度（空标签不该撑开布局）", () => {
  assert.equal(layoutText(f, "").height, 0);
  assert.equal(layoutText(f, "   ").height, 0);
  assert.equal(layoutText(f, "").quads.length, 0);
});

test("scale 同时缩放度量与位置（相对关系不变）", () => {
  const one = layoutText(f, "AB");
  const two = layoutText(f, "AB", { scale: 2 });
  assert.equal(two.width, one.width * 2);
  assert.equal(two.height, one.height * 2);
  assert.equal(two.quads[1]?.x, one.quads[1]!.x * 2);
  assert.equal(two.quads[0]?.y, one.quads[0]!.y * 2);
  assert.equal(two.quads[0]?.w, one.quads[0]!.w * 2);
});

test("letterSpacing 参与宽度（间距加在两个字之间，也加在行尾）", () => {
  const r = layoutText(f, "AB", { letterSpacing: 3 });
  assert.equal(r.width, 30, "(12+3) × 2");
  assert.equal(r.quads[1]?.x, 15);
});

test("颜色传到每个字形（整段一个颜色，富文本是已记录缺口）", () => {
  const c = new Color(1, 0.5, 0.25, 0.8);
  const r = layoutText(f, "AB", { color: c });
  assert.equal(r.quads[0]?.r, 1);
  assert.equal(r.quads[0]?.g, 0.5);
  assert.equal(r.quads[0]?.a, 0.8);
});

test("UV 原样透传（排版层不再动 v 轴）", () => {
  const r = layoutText(f, "A");
  const g = f.glyphs.get(65)!;
  const q = r.quads[0]!;
  assert.equal(q.u0, g.u0);
  assert.equal(q.v0, g.v0);
  assert.equal(q.v1, g.v1);
});
