/**
 * UI 判据用的字体夹具。
 *
 * ★ 为什么不读一张真的字体文件：
 *   判据要断言的是**布局数学**（第几个字落在哪、行宽多少），而真实字体每次
 *   导出都可能变（造字工具版本、字符集、栅格参数）。用固定夹具，断言里的
 *   每个数字都可以手算核对 —— 手算核不出来的断言，等于把实现抄了一遍。
 *
 * ★ 夹具本身也要有护栏：`makeTestFont()` 解析失败直接抛。若夹具悄悄退化，
 *   后面所有排版判据都会变成"对着一个坏字体验证"，而且照样绿。
 */

import { parseBmFont, type BitmapFont } from "../../src/extensions/ui/font.ts";

export const FONT_SIZE = 16;
export const FONT_LINE_HEIGHT = 20;
export const FONT_BASE = 15;
export const FONT_SCALE_W = 256;
export const FONT_SCALE_H = 256;
/** 每个非空格字形的固定宽度。 */
export const GLYPH_W = 10;
export const GLYPH_H = 10;
/** 每个非空格字形的固定前进量。手算行宽时用它：n 个字 = 12n。 */
export const GLYPH_ADVANCE = 12;
/** 空格的前进量（故意与字宽不同，用来抓"用 width 当 advance"的实现）。 */
export const SPACE_ADVANCE = 6;

export interface FixtureGlyph {
  readonly code: number;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
  readonly xo?: number;
  readonly yo?: number;
  readonly xa?: number;
  readonly page?: number;
}

export interface FontTextOptions {
  readonly size?: number;
  readonly lineHeight?: number;
  readonly base?: number;
  readonly scaleW?: number;
  readonly scaleH?: number;
  readonly pages?: number;
  readonly extraLines?: readonly string[];
}

/** 造一段 BMFont 文本。 */
export function fontText(glyphs: readonly FixtureGlyph[], opts: FontTextOptions = {}): string {
  const size = opts.size ?? FONT_SIZE;
  const lineHeight = opts.lineHeight ?? FONT_LINE_HEIGHT;
  const base = opts.base ?? FONT_BASE;
  const scaleW = opts.scaleW ?? FONT_SCALE_W;
  const scaleH = opts.scaleH ?? FONT_SCALE_H;
  const pages = opts.pages ?? 1;
  const lines = [
    `info face="Fixture" size=${size} bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=1 aa=1 padding=0,0,0,0 spacing=1,1 outline=0`,
    `common lineHeight=${lineHeight} base=${base} scaleW=${scaleW} scaleH=${scaleH} pages=${pages} packed=0`,
  ];
  for (let p = 0; p < pages; p++) lines.push(`page id=${p} file="fixture${p}.png"`);
  lines.push(`chars count=${glyphs.length}`);
  for (const g of glyphs) {
    lines.push(
      `char id=${g.code} x=${g.x} y=${g.y} width=${g.w} height=${g.h} ` +
        `xoffset=${g.xo ?? 0} yoffset=${g.yo ?? 0} xadvance=${g.xa ?? GLYPH_ADVANCE} page=${g.page ?? 0} chnl=15`,
    );
  }
  for (const l of opts.extraLines ?? []) lines.push(l);
  return lines.join("\n");
}

/** 省略号（U+2026）。必须有：否则「截断」判据里连省略号都画不出来，只能断 missing。 */
export const ELLIPSIS_CODE = 0x2026;

/**
 * 覆盖 ASCII 32..126 + 省略号的标准夹具：每个字 10×10、advance 12，一行 24 个。
 * 共 96 个字形。
 */
export function asciiGlyphs(): FixtureGlyph[] {
  const out: FixtureGlyph[] = [];
  for (let code = 32; code <= 126; code++) {
    const i = code - 32;
    const x = (i % 24) * GLYPH_W;
    const y = Math.floor(i / 24) * GLYPH_H;
    if (code === 32) {
      out.push({ code, x, y, w: 0, h: 0, xa: SPACE_ADVANCE });
    } else {
      out.push({ code, x, y, w: GLYPH_W, h: GLYPH_H });
    }
  }
  // 省略号放在第一行右侧的空位上（x=240..250，不与其他字形重叠）
  out.push({ code: ELLIPSIS_CODE, x: 240, y: 0, w: GLYPH_W, h: GLYPH_H });
  return out;
}

/** 解析并断言成功 —— 夹具坏了要立刻停，不能让下游判据对着坏数据变绿。 */
export function makeTestFont(id = "test"): BitmapFont {
  const r = parseBmFont(fontText(asciiGlyphs()), { id });
  if (!r.ok) throw new Error(`字体夹具自身解析失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

/** 只含给定字符的字体（用来造缺字场景）。 */
export function makeFontWith(codes: readonly number[], id = "partial"): BitmapFont {
  const glyphs: FixtureGlyph[] = codes.map((code, i) => ({
    code,
    x: (i % 24) * GLYPH_W,
    y: Math.floor(i / 24) * GLYPH_H,
    w: GLYPH_W,
    h: GLYPH_H,
  }));
  const r = parseBmFont(fontText(glyphs), { id });
  if (!r.ok) throw new Error(`字体夹具自身解析失败：${r.error.code} ${r.error.message}`);
  return r.value;
}
