/**
 * L4 · 位图字体排版（纯函数）
 *
 * 这一层只做一件事：**把一段字符串变成一串四边形**，不做绘制、不碰 GPU。
 * 好处是"排版对不对"可以用纯数据判据证明（每行的宽度、每个字形的位置都能直接断言），
 * 不需要截图比对；而截图比对在字体这种高频小元素上几乎不可判。
 *
 * ★★ 量出来的宽度与画出来的宽度**必须同源**：
 *   这里没有独立的 `measure()` 实现 —— `layoutText()` 返回的 `width/height`
 *   就是它自己排完的结果。上一代引擎里"标签宽 100、画出来 108"的经典事故，
 *   根因永远是"测量用一套度量、绘制用另一套"，而两套各自都能自洽。
 *
 * ★★ 换行策略（饥荒那类游戏同时有中文与英文，两套规则都要）：
 *   · 英文：在**空格之后**可断；超长单词（比整行还宽）才按字符硬断；
 *   · 中文：每个汉字之后都可断（没有空格），标点不单独起行是"避头尾"，
 *     这一版**没做**避头尾（见文件末尾的已知缺口）。
 *
 * ★ `yoffset` 相对**基线**、向上为负 —— 这是 libgdx / TextMeshPro 采用的语义，
 *   也是 BMFont 文本格式在实际渲染器里的事实约定。写在这里是因为它无法从
 *   数据本身推出来：等高的字形镜像后仍然"看着像字"，只有行高不一致时才会露馅。
 */

import type { Color } from "../../foundation/math/index.ts";
import { kerningOf, type BitmapFont, type FontGlyph } from "./font.ts";

export type TextAlign = "left" | "center" | "right";

export interface TextStyle {
  /** 缩放：1 = 字体原始像素。位图字体放大后会糊，这是它的固有代价。 */
  readonly scale?: number;
  readonly color?: Color;
  readonly align?: TextAlign;
  /** 额外行距（像素，加在 lineHeight 之上，可负）。 */
  readonly lineSpacing?: number;
  /** 额外字距（像素，加在 xadvance 之上，可负）。 */
  readonly letterSpacing?: number;
  /** 自动折行的容器宽度（设计像素）。0 / 缺省 = 不折行。 */
  readonly maxWidth?: number;
  /** 最多几行，超出用省略号。0 / 缺省 = 不限。 */
  readonly maxLines?: number;
  /** 省略号字符串，默认「…」。 */
  readonly ellipsis?: string;
}

/** 一个字形四边形（设计像素坐标，y 向下）。 */
export interface TextQuad {
  readonly page: number;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
  readonly u0: number;
  readonly v0: number;
  readonly u1: number;
  readonly v1: number;
  readonly r: number;
  readonly g: number;
  readonly b: number;
  readonly a: number;
}

export interface TextLayout {
  readonly quads: readonly TextQuad[];
  /** 排版宽度：有 maxWidth 时等于 maxWidth，否则是最长行宽。 */
  readonly width: number;
  readonly height: number;
  readonly lineCount: number;
  /** 是否因 maxLines 被截断（截断时最后一行**真的**带了省略号）。 */
  readonly truncated: boolean;
  /** 缺字码点（升序去重）。空数组 = 全部字形都找到了。 */
  readonly missing: readonly number[];
}

const DEFAULT_ELLIPSIS = "…";

/** 空格与制表符统一按空格处理；其它控制字符直接丢弃（除了换行）。 */
function normalizeCodes(text: string): number[][] {
  const paragraphs: number[][] = [];
  let cur: number[] = [];
  // Array.from 按码点切，代理对（emoji）不会被拆成两半。
  for (const ch of Array.from(text)) {
    const code = ch.codePointAt(0) ?? 0;
    if (ch === "\n") {
      paragraphs.push(cur);
      cur = [];
      continue;
    }
    if (ch === "\r") continue;
    if (ch === "\t") {
      cur.push(0x20);
      continue;
    }
    // 其它 C0 控制字符与 DEL：丢弃。留着它们只会变成缺字记录，污染诊断。
    if (code < 0x20 || code === 0x7f) continue;
    cur.push(code);
  }
  paragraphs.push(cur);
  return paragraphs;
}

/** 这个码点之后是否可以断行（不含空格——空格单独成 token）。 */
function breakAfter(code: number): boolean {
  // CJK 统一表意文字、扩展 A、兼容区、假名、全角标点
  return (
    (code >= 0x2e80 && code <= 0x9fff) ||
    (code >= 0xf900 && code <= 0xfaff) ||
    (code >= 0x3000 && code <= 0x303f) ||
    (code >= 0xff00 && code <= 0xffef)
  );
}

interface Token {
  readonly codes: readonly number[];
  readonly width: number;
  readonly isSpace: boolean;
}

/** 字形前进量。缺字用 `missingAdvance`（见 font.ts 的理由）。 */
function advanceOf(font: BitmapFont, code: number, scale: number, letterSpacing: number): number {
  const g = font.glyphs.get(code);
  const base = g === undefined ? font.missingAdvance : g.xadvance;
  return base * scale + letterSpacing;
}

/**
 * 切 token：一个 token 是「不可再断的一段」+ 它后面的空隙。
 * 空格自成一个 token（这样行尾空格可以整段丢掉，右对齐不会多出一格）。
 */
function tokenize(font: BitmapFont, codes: readonly number[], scale: number, letterSpacing: number): Token[] {
  const out: Token[] = [];
  let buf: number[] = [];
  let bufW = 0;
  const flush = (isSpace: boolean): void => {
    if (buf.length === 0) return;
    out.push({ codes: buf, width: bufW + (isSpace ? 0 : 0), isSpace });
    buf = [];
    bufW = 0;
  };
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i]!;
    if (code === 0x20) {
      flush(false);
      out.push({ codes: [code], width: advanceOf(font, code, scale, letterSpacing), isSpace: true });
      continue;
    }
    buf.push(code);
    bufW += advanceOf(font, code, scale, letterSpacing);
    // 字距只作用于 token 内部（token 之间由 kerning/空格决定）
    const prev = codes[i - 1];
    if (prev !== undefined) bufW += kerningOf(font, prev, code) * scale;
    if (breakAfter(code)) flush(false);
  }
  flush(false);
  return out;
}

/** 一行（码点序列）的宽度。与绘制共用同一套前进量计算。 */
function lineWidthOf(
  font: BitmapFont,
  codes: readonly number[],
  scale: number,
  letterSpacing: number,
): number {
  let w = 0;
  for (let i = 0; i < codes.length; i++) {
    const code = codes[i]!;
    w += advanceOf(font, code, scale, letterSpacing);
    const prev = codes[i - 1];
    if (prev !== undefined) w += kerningOf(font, prev, code) * scale;
  }
  return w;
}

function trimTrailingSpaces(codes: number[]): number[] {
  let end = codes.length;
  while (end > 0 && codes[end - 1] === 0x20) end--;
  return codes.slice(0, end);
}

/** 把一段码点按 maxWidth 贪心装行；单个 token 超宽时按字符硬断。 */
function breakParagraph(
  font: BitmapFont,
  codes: readonly number[],
  scale: number,
  letterSpacing: number,
  maxWidth: number,
): number[][] {
  if (maxWidth <= 0) return [trimTrailingSpaces(codes.slice())];

  const lines: number[][] = [];
  let cur: number[] = [];
  let curW = 0;

  const pushLine = (): void => {
    lines.push(trimTrailingSpaces(cur));
    cur = [];
    curW = 0;
  };

  for (const tk of tokenize(font, codes, scale, letterSpacing)) {
    if (tk.isSpace) {
      // 行首空格丢掉：否则居中/右对齐会因为不可见的前导空格整体偏移。
      if (cur.length === 0) continue;
      cur.push(...tk.codes);
      curW += tk.width;
      continue;
    }
    if (curW + tk.width <= maxWidth) {
      cur.push(...tk.codes);
      curW += tk.width;
      continue;
    }
    // 放不下：先收掉当前行（若当前行是空的，说明这个 token 本身超宽）
    if (cur.length > 0) pushLine();
    if (tk.width <= maxWidth) {
      cur.push(...tk.codes);
      curW = tk.width;
      continue;
    }
    // 硬断：逐字符塞，塞不下就换行。★ 每行至少放一个字符，
    // 否则 maxWidth 小于单字宽时会死循环（这是硬断最经典的写法错误）。
    for (const code of tk.codes) {
      const cw = advanceOf(font, code, scale, letterSpacing);
      if (curW + cw > maxWidth && cur.length > 0) pushLine();
      cur.push(code);
      curW += cw;
    }
  }
  // 最后一段：只有非空才作为一行（避免文本以换行结尾时多出一个空行）
  if (cur.length > 0 || lines.length === 0) lines.push(trimTrailingSpaces(cur));
  return lines;
}

/**
 * 排版。返回四边形列表与度量。
 *
 * 调用方（控件层）负责缓存：文本没变就不要重排 —— 这个函数是纯的，
 * 缓存键应当是「文本 + 样式 + 字体 id」，不是指针。
 */
export function layoutText(font: BitmapFont, text: string, style: TextStyle = {}): TextLayout {
  const scale = style.scale ?? 1;
  const ls = style.letterSpacing ?? 0;
  const maxWidth = style.maxWidth ?? 0;
  const maxLines = style.maxLines ?? 0;
  const ellipsis = style.ellipsis ?? DEFAULT_ELLIPSIS;
  const align: TextAlign = style.align ?? "left";

  if (!(scale > 0)) throw new RangeError(`文本 scale 必须 > 0：${scale}`);

  const lineHeightPx = font.lineHeight * scale + (style.lineSpacing ?? 0);
  const paragraphs = normalizeCodes(text);

  const lines: number[][] = [];
  for (const p of paragraphs) {
    const broken = breakParagraph(font, p, scale, ls, maxWidth);
    for (const l of broken) lines.push(l);
  }
  // 纯空文本：没有行，高度 0（而不是一行高度）—— 空标签不该占位。
  if (lines.length === 1 && lines[0]!.length === 0 && text.trim() === "") {
    lines.length = 0;
  }

  let truncated = false;
  if (maxLines > 0 && lines.length > maxLines) {
    lines.length = maxLines;
    truncated = true;
    if (lines.length === 0) lines.push([]);
    const last = lines[lines.length - 1]!;
    const ellCodes = Array.from(ellipsis).map((c) => c.codePointAt(0) ?? 0);
    if (maxWidth > 0) {
      const ellW = lineWidthOf(font, ellCodes, scale, ls);
      // ★ 从尾部逐字删除直到「本行 + 省略号」放得下。
      //   注意要重算宽度（kerning 会让"删一个字"减掉的宽度不等于单字宽度）。
      while (last.length > 0 && lineWidthOf(font, last, scale, ls) + ellW > maxWidth) last.pop();
      if (last.length === 0 && ellW > maxWidth) {
        // 连省略号都放不下：宁可不画，也不能溢出容器。
        lines[lines.length - 1] = [];
      } else {
        last.push(...ellCodes);
      }
    } else {
      last.push(...ellCodes);
    }
  }

  const lineWidths = lines.map((l) => lineWidthOf(font, l, scale, ls));
  const naturalWidth = lineWidths.reduce((m, w) => (w > m ? w : m), 0);
  const boxWidth = maxWidth > 0 ? maxWidth : naturalWidth;

  const color = style.color;
  const quads: TextQuad[] = [];
  const missingSet = new Set<number>();

  for (let li = 0; li < lines.length; li++) {
    const codes = lines[li]!;
    const lw = lineWidths[li]!;
    let penX = 0;
    if (align === "center") penX = (boxWidth - lw) / 2;
    else if (align === "right") penX = boxWidth - lw;

    // 基线：行顶 + base。yoffset 相对基线（向上为负）。
    const lineTop = li * lineHeightPx;
    const baseline = lineTop + font.base * scale;

    for (let i = 0; i < codes.length; i++) {
      const code = codes[i]!;
      const g: FontGlyph | undefined = font.glyphs.get(code);
      if (g === undefined) {
        missingSet.add(code);
        penX += font.missingAdvance * scale + ls;
        continue;
      }
      if (g.width > 0 && g.height > 0) {
        quads.push({
          page: g.page,
          x: penX + g.xoffset * scale,
          y: baseline + g.yoffset * scale,
          w: g.width * scale,
          h: g.height * scale,
          u0: g.u0,
          v0: g.v0,
          u1: g.u1,
          v1: g.v1,
          r: color?.r ?? 1,
          g: color?.g ?? 1,
          b: color?.b ?? 1,
          a: color?.a ?? 1,
        });
      }
      penX += g.xadvance * scale + ls;
      const prev = codes[i - 1];
      if (prev !== undefined) penX += kerningOf(font, prev, code) * scale;
    }
  }

  return {
    quads,
    width: boxWidth,
    height: lines.length === 0 ? 0 : lines.length * lineHeightPx,
    lineCount: lines.length,
    truncated,
    missing: Array.from(missingSet).sort((a, b) => a - b),
  };
}

/**
 * 已知缺口（不打算在这一版做，写下来免得下一个人以为是漏了）：
 *   ① **避头尾**（行首不能是「，。）」、行尾不能是「（」）— 中文排版必需，
 *      但它要求"回退到上一行末尾重排"，与贪心装行的结构冲突，要单独一轮；
 *   ② **双向文本（RTL）** — 阿拉伯语/希伯来语的游标方向相反，需要显式的 run 切分；
 *   ③ **富文本**（行内换色/换字号）— 需要按 run 切段，现在整段一个颜色。
 *   三条都不影响"用中文与英文做一款饥荒类游戏"，所以排在 UI 控件层之后。
 */
