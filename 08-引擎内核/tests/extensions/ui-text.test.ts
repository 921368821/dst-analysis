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
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { layoutRichText, layoutText } from "../../src/extensions/ui/text-layout.ts";
import { parseBmFont } from "../../src/extensions/ui/font.ts";
import { Color } from "../../src/foundation/math/index.ts";
import { stripComments } from "../arch/scan.ts";
import { asciiGlyphs, ELLIPSIS_CODE, FONT_BASE, FONT_LINE_HEIGHT, fontText, makeFontWith, makeTestFont } from "./ui-fixtures.ts";

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

test("颜色传到每个字形（整段一个颜色；行内换色见下面「富文本」一节）", () => {
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

// ------------------------------------------------------------------ 避头尾（批111）

/**
 * 中文排版用的夹具：每字 advance 仍是 12，所以「4 个字 = 48」照样能心算。
 * ★ 用 `makeFontWith` 精确列出用到的码点，而不是给一张全角表：
 *   字体里没有的字会被算作缺字、不画 —— 那样排出来的行宽是错的，
 *   而这些用例断言的全是"第几个字落在哪一行"。
 */
const CJK = "一二三四五六，（）甲乙丙丁";
const cf = makeFontWith([...CJK].map((c) => c.codePointAt(0) ?? 0));

/** 每行几个字（`lineCaretX` 的行长 - 1）。比读 quads 直接得多。 */
function lineLengths(r: { readonly lineCaretX: readonly (readonly number[])[] }): number[] {
  return r.lineCaretX.map((x) => x.length - 1);
}

test("★★ 避头尾：逗号不再顶行首（多带一个字下来）", () => {
  const width = 48; // 4 个字
  const plain = layoutText(cf, "一二三四五六", { maxWidth: width });
  assert.deepEqual(lineLengths(plain), [4, 2], "前提：不带标点时正好 4+2");
  const r = layoutText(cf, "一二三四，五六", { maxWidth: width });
  assert.deepEqual(lineLengths(r), [3, 4], "断点要从「，」前面挪到它前面那位的前面");
  // 反向断言：两行合起来还是 7 个字，没有丢字
  assert.equal(
    lineLengths(r).reduce((a, b) => a + b, 0),
    7,
    "避头尾只挪断点，不许吞字",
  );
});

test("★★ 行尾禁则：开括号跟着下一行走（不能孤零零挂行尾）", () => {
  const r = layoutText(cf, "甲乙（丙", { maxWidth: 36 }); // 3 个字
  assert.deepEqual(lineLengths(r), [2, 2], "「（」不能留在第一行末尾");
});

test("★★ 连续开括号：必须终止，且每行至少一个字（不设上界就死循环）", () => {
  const r = layoutText(cf, "（（（（（（", { maxWidth: 24 }); // 2 个字
  const lens = lineLengths(r);
  assert.equal(
    lens.reduce((a, b) => a + b, 0),
    6,
    "六字排完就停 —— 不终止的实现会在这里挂死，而不是给出错误的行数",
  );
  for (const n of lens) assert.ok(n >= 1, `出现了长度 ${String(n)} 的行：空行会让下一轮从 0 开始`);
});

test("★ 纯汉字（无标点）断行与以前完全一样（避头尾不影响正常文本）", () => {
  assert.deepEqual(lineLengths(layoutText(cf, "一二三四五", { maxWidth: 24 })), [2, 2, 1]);
});

// ------------------------------------------------------------------ 富文本（批114）

/**
 * 富文本唯一的正确性来源是**手算**，不是"再跑一遍别处的实现"。
 *
 * ★ 为什么不写「单 run 的 `layoutRichText` 与 `layoutText` 逐字段相等」：
 *   后者现在就是前者的一行委托，那条断言**把被测逻辑删掉也照样绿**
 *   （它比的是同一个函数）。真正守住"不许有两份实现"的是下面那条
 *   **源码结构判据**（只有一处 `quads.push`），而几何对不对由本节的手算数字钉。
 */

const RED = new Color(1, 0, 0, 1);
const BLUE = new Color(0, 0, 1, 1);

/** 带 kerning 的夹具：`AB` 收 2 像素（其余仍是 advance 12）。 */
function kernedFont(): typeof f {
  const r = parseBmFont(fontText(asciiGlyphs(), { extraLines: ["kernings count=1", "kerning first=65 second=66 amount=-2"] }), {
    id: "kern",
  });
  if (!r.ok) throw new Error(`kerning 夹具解析失败：${r.error.message}`);
  return r.value;
}

test("★★ 富文本：两段各自的颜色烘进四边形，几何一点不变", () => {
  const plain = layoutRichText(f, [{ text: "AB" }, { text: "CD" }]);
  assert.equal(plain.width, 48, "4 个字 × 12");
  const colored = layoutRichText(f, [
    { text: "AB", color: RED },
    { text: "CD", color: BLUE },
  ]);
  // ① 该变的变了：颜色逐字形跟着 run 走
  assert.deepEqual(
    colored.quads.map((q) => [q.r, q.g, q.b]),
    [
      [1, 0, 0],
      [1, 0, 0],
      [0, 0, 1],
      [0, 0, 1],
    ],
  );
  // ② 不该变的没变：位置/宽度/高度逐字段相同
  //   ★ 两个观测量一起读 —— 只比颜色的话，"把颜色算进前进量"的实现照样绿。
  assert.deepEqual(
    colored.quads.map((q) => [q.x, q.y, q.w, q.h]),
    plain.quads.map((q) => [q.x, q.y, q.w, q.h]),
  );
  assert.equal(colored.width, plain.width);
  assert.equal(colored.height, plain.height);
});

test("★★ 行高与基线取**本行最大字号**（不是整段、也不是第一个字）", () => {
  // 第一行两个字都是 2 倍，第二行是 1 倍
  const r = layoutRichText(f, [{ text: "AB", scale: 2 }, { text: "\nCD" }]);
  assert.equal(r.lineCount, 2);
  // 行高：40 + 20 = 60。若按整段最大字号（2 倍）算第二行，会是 80。
  assert.equal(r.height, 60);
  // 基线：第一行 0 + 15×2 = 30，第二行从 40 起 + 15×1 = 55
  assert.deepEqual(
    r.quads.map((q) => q.y),
    [FONT_BASE * 2, FONT_BASE * 2, 40 + FONT_BASE, 40 + FONT_BASE],
    "基线跟着**本行**最大字号走：按整段算第二行会下坠到 70",
  );
  // 字号真的作用到字形尺寸上（不是只改了行高）
  assert.equal(r.quads[0]?.w, 20, "10 × 2");
  assert.equal(r.quads[2]?.w, 10, "10 × 1");
  assert.equal(r.width, 48, "第一行 2 个字 × 12 × 2 = 48（第二行 24 更窄，取最宽的）");
});

test("★★ 跨 run 断行：先摊平再切词，行尾空格照样丢掉", () => {
  // run 边界正好在空格上：第一段 "aa "、第二段 "bb"
  const r = layoutRichText(f, [{ text: "aa ", color: RED }, { text: "bb", color: BLUE }], { maxWidth: 30 });
  assert.equal(r.lineCount, 2, "24 + 6 + 24 > 30");
  assert.deepEqual(lineLengths(r), [2, 2], "行尾空格被丢掉，而不是留在第一行末尾");
  // 第二行从行首开始（前导空格不会跟着换行）
  const second = r.quads.filter((q) => q.y === FONT_BASE + FONT_LINE_HEIGHT);
  assert.equal(second[0]?.x, 0);
  assert.deepEqual(
    second.map((q) => [q.r, q.g, q.b]),
    [
      [0, 0, 1],
      [0, 0, 1],
    ],
    "换行之后颜色仍然是第二段自己的",
  );
});

test("★ kerning 只在**同一字号**之间加，且跟着右侧字号缩放", () => {
  const kf = kernedFont();
  // 前提：这个夹具在同一字号下确实收了 2（否则下面三条全是空转）
  assert.equal(layoutText(kf, "AB").width, 22, "12 + 12 − 2");
  assert.equal(
    layoutRichText(kf, [{ text: "A", scale: 2 }, { text: "B", scale: 2 }]).width,
    44,
    "24 + 24 − 2×2：kerning 要乘当前缩放",
  );
  // 跨字号边界：这一对度量在该字号下没有定义，取 0
  assert.equal(
    layoutRichText(kf, [{ text: "A" }, { text: "B", scale: 2 }]).width,
    36,
    "12 + 24，不加 kerning",
  );
});

test("★★ 省略号继承**最后一个还剩的字**的样式（不是最后一段 run）", () => {
  // 第一段红、第二段蓝；maxWidth=30 只放得下第一行的两个字，截断会把红字删到只剩一个
  const r = layoutRichText(f, [{ text: "ABC", color: RED }, { text: "D", color: BLUE }], {
    maxWidth: 30,
    maxLines: 1,
  });
  assert.equal(r.truncated, true);
  assert.equal(r.lineCount, 1);
  assert.deepEqual(
    r.quads.map((q) => [q.x, q.r, q.g, q.b]),
    [
      [0, 1, 0, 0], // A 红
      [12, 1, 0, 0], // 省略号：跟着它前面那个字（红）走
    ],
    "按「最后一段 run」实现的话这里会是蓝色 —— 而 C 已经被裁掉了",
  );
  assert.equal(r.quads[1]?.u0, f.glyphs.get(ELLIPSIS_CODE)?.u0, "第二个四边形真的是省略号");
});

test("★ run 的 scale ≤ 0 抛 RangeError（不静默当 1）", () => {
  assert.throws(() => layoutRichText(f, [{ text: "A", scale: 0 }]), RangeError);
  assert.throws(() => layoutRichText(f, [{ text: "A", scale: -1 }]), RangeError);
  // 反向：合法的 scale 不抛
  assert.equal(layoutRichText(f, [{ text: "A", scale: 1 }]).quads.length, 1);
});

test("★ 空 run 不占位、不改变几何（宿主可以放心拼 null 段）", () => {
  const a = layoutRichText(f, [{ text: "" }, { text: "AB" }, { text: "" }]);
  const b = layoutRichText(f, [{ text: "AB" }]);
  assert.deepEqual(
    a.quads.map((q) => [q.x, q.y, q.w, q.h]),
    b.quads.map((q) => [q.x, q.y, q.w, q.h]),
  );
  assert.equal(a.width, b.width);
  assert.equal(a.lineCount, b.lineCount);
  // 全空的 runs 与空字符串一样：不占高度（否则空标签会撑开布局）
  assert.equal(layoutRichText(f, [{ text: "" }, { text: " " }]).height, 0);
});

test("★★ 源码里只有一处绘制循环（多写一份排版实现就会红）", () => {
  const here = dirname(fileURLToPath(import.meta.url));
  const src = readFileSync(join(here, "..", "..", "src", "extensions", "ui", "text-layout.ts"), "utf8");
  const code = stripComments(src);
  // ★ 先证明"扫到了东西"：文件读错/改路径时长度会塌，那时后面的计数是假绿。
  assert.ok(code.length > 4000, `扫到的源码只有 ${String(code.length)} 字符，先确认文件读对了`);
  assert.ok(code.includes("layoutRichText"), "扫到的内容里没有 layoutRichText，说明读错了文件");
  // `layoutText` 是 `layoutRichText` 的一行委托：一旦有人复制出第二份循环，
  // 就会多出第二个 `quads.push(`（或第二个 `lineCaretX.push(`）—— 这就是这条判据的价值。
  assert.equal((code.match(/quads\.push\(/g) ?? []).length, 1, "绘制循环只许有一处");
  assert.equal((code.match(/lineCaretX\.push\(/g) ?? []).length, 1, "光标表只许有一处写入");
});
