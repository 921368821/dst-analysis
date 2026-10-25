/**
 * L4 · 位图字体解析判据
 *
 * 守三件事：
 *   ① **UV 的 v 不翻转** —— 与 `batch2d.ts` 的 T330 同族缺陷。写错时字形会被镜像，
 *      而"镜像后仍然像字"，只有行高不一致时才露馅。所以断言必须落在**具体数值**上。
 *   ② **坏数据一律失败** —— 重复字形、越界、非法 advance。静默容错的症状是
 *      "某个字突然不显示/变成别的字"，而字体文件看起来完全正常。
 *   ③ **advance 与 width 是两个数** —— 用 width 当 advance 的实现在等宽测试字体上
 *      完全看不出来（这是本夹具故意让空格 width=0 而 advance=6 的原因）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { FONT_ERR, FontRegistry, kerningOf, parseBmFont } from "../../src/extensions/ui/font.ts";
import {
  FONT_BASE,
  FONT_LINE_HEIGHT,
  FONT_SCALE_H,
  FONT_SCALE_W,
  FONT_SIZE,
  GLYPH_ADVANCE,
  SPACE_ADVANCE,
  asciiGlyphs,
  fontText,
  makeTestFont,
} from "./ui-fixtures.ts";

test("解析：ASCII 夹具的 95 个字形全部就位，度量取自 common/info", () => {
  const f = makeTestFont("t1");
  assert.equal(f.id, "t1");
  assert.equal(f.glyphs.size, 96, "32..126 共 95 个码点 + 省略号 1 个");
  assert.equal(f.size, FONT_SIZE);
  assert.equal(f.lineHeight, FONT_LINE_HEIGHT);
  assert.equal(f.base, FONT_BASE);
  assert.equal(f.scaleW, FONT_SCALE_W);
  assert.equal(f.scaleH, FONT_SCALE_H);
  assert.equal(f.pages.length, 1, "单页字体也要有一条 page 记录");
});

test("★ UV 的 v 不翻转：'A' 的 v0 是「行号/高」，不是「1 − 行号/高」", () => {
  const f = makeTestFont();
  const a = f.glyphs.get(65);
  assert.ok(a !== undefined);
  // 夹具里 A = 第 33 个字 → 列 9、行 1 → x=90, y=10
  assert.equal(a.u0, 90 / 256);
  assert.equal(a.v0, 10 / 256, "v0 必须是 y/scaleH；写成 1−y/scaleH 会把字形镜像到另一行");
  assert.equal(a.u1, 100 / 256);
  assert.equal(a.v1, 20 / 256);
  // 反向断言：把 v 翻转后的值必须是**不等**的（防止"两者恰好相等"的空转）
  assert.notEqual(a.v0, 1 - 10 / 256);
});

test("★ advance 与 width 是两回事：空格的 width=0 但 advance=6", () => {
  const f = makeTestFont();
  const sp = f.glyphs.get(32);
  assert.ok(sp !== undefined);
  assert.equal(sp.width, 0, "空格的字形矩形是空的");
  assert.equal(sp.xadvance, SPACE_ADVANCE);
  assert.notEqual(sp.xadvance, sp.width, "用 width 当 advance 的实现会在这里露馅");
  // 普通字：width=10 / advance=12，两者也不等
  const b = f.glyphs.get(66);
  assert.ok(b !== undefined);
  assert.equal(b.width, 10);
  assert.equal(b.xadvance, GLYPH_ADVANCE);
});

test("重复码点 → FONT_DUP_GLYPH（不静默覆盖）", () => {
  const glyphs = [
    { code: 65, x: 0, y: 0, w: 10, h: 10 },
    { code: 65, x: 20, y: 0, w: 10, h: 10 },
  ];
  const r = parseBmFont(fontText(glyphs));
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, FONT_ERR.DUP_GLYPH);
  assert.equal(r.error.detail?.code, 65, "错误里要带上是哪个码点，否则只能靠猜");
});

test("矩形超出纹理页 → FONT_GLYPH_OOB（含右/下边界，等于边界算合法）", () => {
  const bad = parseBmFont(fontText([{ code: 65, x: 250, y: 0, w: 10, h: 10 }]));
  assert.equal(bad.ok, false);
  if (!bad.ok) assert.equal(bad.error.code, FONT_ERR.GLYPH_OOB);

  // 贴边：x+w = scaleW 是合法的（UV 上界正好 1.0）
  const edge = parseBmFont(fontText([{ code: 65, x: 246, y: 246, w: 10, h: 10 }]));
  assert.equal(edge.ok, true);
  if (edge.ok) assert.equal(edge.value.glyphs.get(65)?.u1, 1);
});

test("缺 common / scaleW=0 / lineHeight=0 → 各自稳定错误码", () => {
  const noCommon = parseBmFont('info face="x" size=16\nchar id=65 x=0 y=0 width=10 height=10 xadvance=12 page=0');
  assert.equal(noCommon.ok, false);
  if (!noCommon.ok) assert.equal(noCommon.error.code, FONT_ERR.NO_COMMON);

  const badScale = parseBmFont(fontText([{ code: 65, x: 0, y: 0, w: 10, h: 10 }], { scaleW: 0 }));
  assert.equal(badScale.ok, false);
  if (!badScale.ok) assert.equal(badScale.error.code, FONT_ERR.BAD_SCALE);

  const badLine = parseBmFont(fontText([{ code: 65, x: 0, y: 0, w: 10, h: 10 }], { lineHeight: 0 }));
  assert.equal(badLine.ok, false);
  if (!badLine.ok) assert.equal(badLine.error.code, FONT_ERR.BAD_LINE_HEIGHT);
});

test("xadvance 非数字 → FONT_BAD_NUMBER（NaN 不能被当成 0）", () => {
  const r = parseBmFont(
    fontText([{ code: 65, x: 0, y: 0, w: 10, h: 10 }]).replace("xadvance=12", "xadvance=abc"),
  );
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, FONT_ERR.BAD_NUMBER);
});

test("二进格式与 XML 明确拒绝（不返回空字体冒充成功）", () => {
  const bin = parseBmFont("BMF\x03\x00\x00\x00");
  assert.equal(bin.ok, false);
  if (!bin.ok) assert.equal(bin.error.code, FONT_ERR.UNSUPPORTED_FORMAT);
  const xml = parseBmFont('<?xml version="1.0"?><font><common lineHeight="20"/></font>');
  assert.equal(xml.ok, false);
  if (!xml.ok) assert.equal(xml.error.code, FONT_ERR.UNSUPPORTED_FORMAT);
});

test("多页字体：page 字段保留，引用不存在的页直接失败", () => {
  const two = [
    { code: 65, x: 0, y: 0, w: 10, h: 10, page: 0 },
    { code: 66, x: 0, y: 0, w: 10, h: 10, page: 1 },
  ];
  const ok = parseBmFont(fontText(two, { pages: 2 }));
  assert.equal(ok.ok, true);
  if (ok.ok) {
    assert.equal(ok.value.glyphs.get(65)?.page, 0);
    assert.equal(ok.value.glyphs.get(66)?.page, 1, "第二页的字形必须指向第 1 页");
  }

  const bad = parseBmFont(fontText([{ code: 65, x: 0, y: 0, w: 10, h: 10, page: 3 }], { pages: 2 }));
  assert.equal(bad.ok, false, "引用第 3 页但只有 2 页必须报错");
});

test("kerning：成对字距被解析，未定义的对返回 0", () => {
  const text = fontText(asciiGlyphs(), { extraLines: ["kernings count=1", "kerning first=65 second=86 amount=-2"] });
  const r = parseBmFont(text);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  assert.equal(kerningOf(r.value, 65, 86), -2);
  assert.equal(kerningOf(r.value, 86, 65), 0, "字距是有方向的，反向不能命中");
  assert.equal(kerningOf(r.value, 65, 65), 0);
});

test("未知标签与 CRLF 不影响解析（向前兼容）", () => {
  const text = fontText(asciiGlyphs(), { extraLines: ["futureTag foo=1 bar=2"] }).replace(/\n/g, "\r\n");
  const r = parseBmFont(text);
  assert.equal(r.ok, true);
  if (r.ok) assert.equal(r.value.glyphs.size, 96);
});

test("FontRegistry：require 缺字体时抛错并列出已有 id", () => {
  const reg = new FontRegistry();
  reg.register(makeTestFont("b-font"));
  reg.register(makeTestFont("a-font"));
  assert.deepEqual(reg.ids(), ["a-font", "b-font"], "ids 必须排序，否则诊断输出随注册顺序变");
  assert.equal(reg.get("a-font")?.id, "a-font");
  assert.equal(reg.get("missing"), undefined);
  assert.throws(() => reg.require("missing"), /a-font, b-font/);
});
