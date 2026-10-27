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
 *   · 中文：每个汉字之后都可断（没有空格）；标点不单独起行 = **避头尾**，批111 已做
 *     （`LINE_START_FORBIDDEN` / `LINE_END_FORBIDDEN`，见 `breakParagraph`）。
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

/**
 * 富文本的一段：一段文字 + 它自己的样式（缺省继承 `TextStyle`）。
 *
 * ★ 为什么是「run 列表」而不是「带标记的字符串」：标记语法要解析、要转义、
 *   还要保证「字体里没有这个字符」时的降级；而这些在内容侧一律不划算 ——
 *   这里的使用者都是代码拼出来的文案（背包行、状态行），不是富文本编辑器。
 * ★ 一段 run 里的样式**完全一致**是它的定义，不是约定：混排就是把两段并排。
 */
export interface TextRun {
  readonly text: string;
  /** 这一段的字号缩放（缺省 = `TextStyle.scale`）。必须 > 0。 */
  readonly scale?: number;
  /** 这一段的颜色（缺省 = `TextStyle.color`）。 */
  readonly color?: Color;
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
  /**
   * **每一行每个码点边界的笔位置**（设计像素 x，长度 = 该行码点数 + 1）。
   *
   * ★★ 为什么光标位置必须由排版层给，而不是让调用方拿 `quads[i].x` 去推：
   *   `quads` 与码点**不是一一对应**的 ——
   *   · 空格、零宽字符没有四边形（但有前进量）；
   *   · 缺字的码点被跳过（只推进笔位置）；
   *   · 四边形的宽度 `w` 是**字形宽**，而光标要的是**前进量**（`xadvance` +
   *     字距 + kerning），三者都不同。
   *   拿 `quads[i].x` 当第 i 个光标位置，在纯英文无空格时恰好对，一加空格就整段错位 ——
   *   而错位的症状是"光标停在字中间"，看起来像渲染 bug，实际是下标与布局没对上。
   *   这里把笔位置**原样记下来**：下标 i 对应的 x 就是第 i 个码点左边界，
   *   最后一项是行尾。判据可以说"相邻两项严格递增""末项等于行宽"。
   *
   * ★ 每行一份（不是一整条）：换行之后 x 会重置，把多行拼成一条会让第二行起的位置全错。
   */
  readonly lineCaretX: readonly (readonly number[])[];
}

const DEFAULT_ELLIPSIS = "…";

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

/**
 * **行首禁则**：这些字符不许出现在一行的开头，得把它前面一个字一起带下来。
 *
 * 中文排版的硬规矩。不做的话，"你好，世界"在某个宽度下会断成
 * `你好` / `，世界` —— 逗号顶着行首，读起来像排版软件崩了。
 *
 * 集合只收**闭口类**（收括号、句读、后置标点）。开口类在 `LINE_END_FORBIDDEN`。
 * 采用**精确码点表**而不是范围：范围会把「一」到「龥」全卷进来，
 * 于是每个汉字都变成禁则字符，避头尾等于关掉了。
 */
const LINE_START_FORBIDDEN: ReadonlySet<number> = new Set([
  0x3001, // 、
  0x3002, // 。
  0xff0c, // ，
  0xff0e, // ．
  0xff1a, // ：
  0xff1b, // ；
  0xff01, // ！
  0xff1f, // ？
  0x2026, // …
  0x2014, // —
  0x30fb, // ・
  0xff09, // ）
  0x3009, // 〉
  0x300b, // 》
  0x300d, // 」
  0x300f, // 』
  0x3011, // 】
  0x3015, // 〕
  0x3017, // 〗
  0x3019, // 〙
  0x301b, // 〛
  0x0029, // )
  0x005d, // ]
  0x007d, // }
  0x002c, // ,
  0x002e, // .
  0x003a, // :
  0x003b, // ;
  0x0021, // !
  0x003f, // ?
]);

/**
 * **行尾禁则**：这些字符不许留在一行的末尾（开括号/开引号跟着下一行走）。
 *
 * ★ 与行首禁则是**两件事**，不能合成一张表：一个字符不可能既"不许在行首"
 *   又"不许在行尾"。合成一张表的结果是每次断行都要挪，字少的行会被拖空。
 */
const LINE_END_FORBIDDEN: ReadonlySet<number> = new Set([
  0xff08, // （
  0x3008, // 〈
  0x300a, // 《
  0x300c, // 「
  0x300e, // 『
  0x3010, // 【
  0x3014, // 〔
  0x3016, // 〖
  0x3018, // 〘
  0x301a, // 〚
  0x0028, // (
  0x005b, // [
  0x007b, // {
]);

/** 一个码点 + 它自己的样式 —— 富文本的最小单位。 */
interface Cell {
  readonly code: number;
  readonly scale: number;
  readonly color: Color | undefined;
}

interface Token {
  readonly cells: readonly Cell[];
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
 * 两个相邻码点之间要不要加 kerning —— **只有同一字号才算**。
 *
 * ★ kerning 是某个字号下的一对字形度量（`AV` 收一点）。跨字号的边界上
 *   这一对根本没有定义：拿大字号的值会让小字那一段被挤，拿小字号的值会让大字那一段变松。
 *   取「同字号才 `kerningOf`」是最不容易骗人的规则 —— 它在**单字号文本上与旧实现逐字节相同**，
 *   而那正是下面等价性判据钉住的东西。
 */
function kernBetween(font: BitmapFont, prev: Cell, cur: Cell): number {
  if (prev.scale !== cur.scale) return 0;
  return kerningOf(font, prev.code, cur.code) * cur.scale;
}

/**
 * 切 token：一个 token 是「不可再断的一段」+ 它后面的空隙。
 * 空格自成一个 token（这样行尾空格可以整段丢掉，右对齐不会多出一格）。
 */
function tokenize(font: BitmapFont, cells: readonly Cell[], letterSpacing: number): Token[] {
  const out: Token[] = [];
  let buf: Cell[] = [];
  let bufW = 0;
  const flush = (isSpace: boolean): void => {
    if (buf.length === 0) return;
    out.push({ cells: buf, width: bufW, isSpace });
    buf = [];
    bufW = 0;
  };
  for (let i = 0; i < cells.length; i++) {
    const c = cells[i]!;
    if (c.code === 0x20) {
      flush(false);
      out.push({ cells: [c], width: advanceOf(font, c.code, c.scale, letterSpacing), isSpace: true });
      continue;
    }
    buf.push(c);
    bufW += advanceOf(font, c.code, c.scale, letterSpacing);
    // 字距只作用于 token 内部（token 之间由 kerning/空格决定）
    const prev = cells[i - 1];
    if (prev !== undefined) bufW += kernBetween(font, prev, c);
    if (breakAfter(c.code)) flush(false);
  }
  flush(false);
  return out;
}

/** 一行（码点序列）的宽度。与绘制共用同一套前进量计算。 */
function lineWidthOf(font: BitmapFont, cells: readonly Cell[], letterSpacing: number): number {
  let w = 0;
  for (let i = 0; i < cells.length; i++) {
    const c = cells[i]!;
    w += advanceOf(font, c.code, c.scale, letterSpacing);
    const prev = cells[i - 1];
    if (prev !== undefined) w += kernBetween(font, prev, c);
  }
  return w;
}

function trimTrailingSpaces(cells: readonly Cell[]): Cell[] {
  let end = cells.length;
  while (end > 0 && cells[end - 1]!.code === 0x20) end--;
  return cells.slice(0, end);
}

/** 把一段码点按 maxWidth 贪心装行；单个 token 超宽时按字符硬断。 */
function breakParagraph(
  font: BitmapFont,
  cells: readonly Cell[],
  letterSpacing: number,
  maxWidth: number,
): Cell[][] {
  if (maxWidth <= 0) return [trimTrailingSpaces(cells)];

  const lines: Cell[][] = [];
  let cur: Cell[] = [];
  let curW = 0;

  const pushLine = (): void => {
    lines.push(trimTrailingSpaces(cur));
    cur = [];
    curW = 0;
  };

  for (const tk of tokenize(font, cells, letterSpacing)) {
    if (tk.isSpace) {
      // 行首空格丢掉：否则居中/右对齐会因为不可见的前导空格整体偏移。
      if (cur.length === 0) continue;
      cur.push(...tk.cells);
      curW += tk.width;
      continue;
    }
    if (curW + tk.width <= maxWidth) {
      cur.push(...tk.cells);
      curW += tk.width;
      continue;
    }
    // 放不下：先收掉当前行（若当前行是空的，说明这个 token 本身超宽）
    if (cur.length > 0) {
      // ---- 避头尾（kinsoku）
      //
      // 断点定下来之后要再问一次：**下一行的第一个字**是不是行首禁则、
      // **这一行的最后一个字**是不是行尾禁则。任一条成立，就把这一行末尾的字符
      // 逐个往下带，直到两条都不成立。
      //
      // ★ 上界是「当前行至少留一个字」：不设上界的话，"（（（（" 这种串会把整行
      //   全推下去，然后下一轮又从空行开始 —— 死循环。宁可让一个标点落在行首，
      //   也不能没有进展。
      // ★ 每带下来一个字，**下一行的首字**就变成它 —— 所以循环里判断的首字是
      //   `cur[len - carry]` 而不是 `tk.cells[0]`。只判一次 `tk.cells[0]` 的话，
      //   「「（」连在一起时会漏掉第二个。
      let carry = 0;
      while (cur.length - carry > 1) {
        const last = cur[cur.length - 1 - carry]!.code;
        const nextFirst = carry === 0 ? (tk.cells[0]?.code ?? -1) : cur[cur.length - carry]!.code;
        if (!LINE_END_FORBIDDEN.has(last) && !LINE_START_FORBIDDEN.has(nextFirst)) break;
        carry++;
      }
      if (carry === 0) {
        pushLine();
      } else {
        const moved = cur.splice(cur.length - carry, carry);
        pushLine();
        cur.push(...moved);
        curW = lineWidthOf(font, cur, letterSpacing);
      }
    }
    if (tk.width <= maxWidth) {
      cur.push(...tk.cells);
      curW = tk.width;
      continue;
    }
    // 硬断：逐字符塞，塞不下就换行。★ 每行至少放一个字符，
    // 否则 maxWidth 小于单字宽时会死循环（这是硬断最经典的写法错误）。
    for (const c of tk.cells) {
      const cw = advanceOf(font, c.code, c.scale, letterSpacing);
      if (curW + cw > maxWidth && cur.length > 0) pushLine();
      cur.push(c);
      curW += cw;
    }
  }
  // 最后一段：只有非空才作为一行（避免文本以换行结尾时多出一个空行）
  if (cur.length > 0 || lines.length === 0) lines.push(trimTrailingSpaces(cur));
  return lines;
}

/**
 * 把若干 run 摊平成「每个码点带自己的样式」，同时按 `\n` 切段。
 *
 * ★ 摊平的理由：断行、量宽、光标全都按**码点**走，而样式是按**run**给的。
 *   在每一个循环里都维护「现在是第几个 run」会让避头尾那段（要回退几个字）
 *   变成跨 run 的索引算术 —— 那是这个文件里最容易写错的一处。
 *   摊平之后，断行逻辑与单样式版本**逐行相同**，只是多读了一个 `cell.scale`。
 */
function cellsOf(runs: readonly TextRun[], baseScale: number, baseColor: Color | undefined): Cell[][] {
  const paragraphs: Cell[][] = [];
  let cur: Cell[] = [];
  for (const run of runs) {
    const scale = run.scale ?? baseScale;
    if (!(scale > 0)) throw new RangeError(`文本 run 的 scale 必须 > 0：${String(run.scale)}`);
    const color = run.color ?? baseColor;
    for (const ch of Array.from(run.text)) {
      const code = ch.codePointAt(0) ?? 0;
      if (ch === "\n") {
        paragraphs.push(cur);
        cur = [];
        continue;
      }
      if (ch === "\r") continue;
      if (ch === "\t") {
        cur.push({ code: 0x20, scale, color });
        continue;
      }
      // 其它 C0 控制字符与 DEL：丢弃。留着它们只会变成缺字记录，污染诊断。
      if (code < 0x20 || code === 0x7f) continue;
      cur.push({ code, scale, color });
    }
  }
  paragraphs.push(cur);
  return paragraphs;
}

/** 一行里最大的字号 —— 行高与基线都由它定（不是「第一个字」，也不是平均）。 */
function maxScaleOf(cells: readonly Cell[], baseScale: number): number {
  let m = 0;
  for (const c of cells) if (c.scale > m) m = c.scale;
  return m > 0 ? m : baseScale;
}

/**
 * 富文本排版：run 之间可以换字号 / 换颜色。
 *
 * ★★ 与 `layoutText` 的关系：那一个是这一个的特例（单 run）。
 *   **不许有两份实现** —— 单样式版本一旦另写一套，混排换行、光标、省略号
 *   就会在两套里各自漂。等价性由判据钉住（同一输入两边逐字段相等）。
 *
 * ★ 行高按**本行最大字号**：一行里有一个大字，整行都要为它让出高度，
 *   否则大字会压到上一行。基线同样跟着本行最大字号走 ——
 *   若按整段的最大字号算，只有小字的行会整体下坠，看起来像行距不匀。
 */
export function layoutRichText(font: BitmapFont, runs: readonly TextRun[], style: TextStyle = {}): TextLayout {
  const baseScale = style.scale ?? 1;
  const ls = style.letterSpacing ?? 0;
  const maxWidth = style.maxWidth ?? 0;
  const maxLines = style.maxLines ?? 0;
  const ellipsis = style.ellipsis ?? DEFAULT_ELLIPSIS;
  const align: TextAlign = style.align ?? "left";

  if (!(baseScale > 0)) throw new RangeError(`文本 scale 必须 > 0：${baseScale}`);

  const lineSpacing = style.lineSpacing ?? 0;
  const paragraphs = cellsOf(runs, baseScale, style.color);

  const lines: Cell[][] = [];
  for (const p of paragraphs) {
    for (const l of breakParagraph(font, p, ls, maxWidth)) lines.push(l);
  }
  // 纯空文本：没有行，高度 0（而不是一行高度）—— 空标签不该占位。
  const isEmpty = runs.every((r) => r.text.trim() === "");
  if (lines.length === 1 && lines[0]!.length === 0 && isEmpty) {
    lines.length = 0;
  }

  let truncated = false;
  if (maxLines > 0 && lines.length > maxLines) {
    lines.length = maxLines;
    truncated = true;
    if (lines.length === 0) lines.push([]);
    const last = lines[lines.length - 1]!;
    // 省略号跟着**它前面那个字**的样式：末尾是红色小字时，省略号也应当是红色小字。
    const tail = last[last.length - 1];
    const ellScale = tail?.scale ?? baseScale;
    const ellColor = tail?.color ?? style.color;
    const ellCells = Array.from(ellipsis).map((c) => ({
      code: c.codePointAt(0) ?? 0,
      scale: ellScale,
      color: ellColor,
    }));
    if (maxWidth > 0) {
      const ellW = lineWidthOf(font, ellCells, ls);
      // ★ 从尾部逐字删除直到「本行 + 省略号」放得下。
      //   注意要重算宽度（kerning 会让"删一个字"减掉的宽度不等于单字宽度）。
      while (last.length > 0 && lineWidthOf(font, last, ls) + ellW > maxWidth) last.pop();
      if (last.length === 0 && ellW > maxWidth) {
        // 连省略号都放不下：宁可不画，也不能溢出容器。
        lines[lines.length - 1] = [];
      } else {
        last.push(...ellCells);
      }
    } else {
      last.push(...ellCells);
    }
  }

  const lineWidths = lines.map((l) => lineWidthOf(font, l, ls));
  const naturalWidth = lineWidths.reduce((m, w) => (w > m ? w : m), 0);
  const boxWidth = maxWidth > 0 ? maxWidth : naturalWidth;

  const quads: TextQuad[] = [];
  const missingSet = new Set<number>();
  const lineCaretX: number[][] = [];
  let yTop = 0;

  for (let li = 0; li < lines.length; li++) {
    const cells = lines[li]!;
    const lw = lineWidths[li]!;
    const lineScale = maxScaleOf(cells, baseScale);
    const lineHeightPx = font.lineHeight * lineScale + lineSpacing;
    let penX = 0;
    if (align === "center") penX = (boxWidth - lw) / 2;
    else if (align === "right") penX = boxWidth - lw;

    // 基线：行顶 + base。yoffset 相对基线（向上为负）。
    const baseline = yTop + font.base * lineScale;

    // ★ 光标位置在这一趟里顺手记：笔位置只有这里知道（advance/kerning 都在下面加）。
    const caretX: number[] = [];

    for (let i = 0; i < cells.length; i++) {
      const cell = cells[i]!;
      const code = cell.code;
      const s = cell.scale;
      caretX.push(penX); // 先记「本格左边界」，再往前走
      const g: FontGlyph | undefined = font.glyphs.get(code);
      if (g === undefined) {
        missingSet.add(code);
        penX += font.missingAdvance * s + ls;
        continue;
      }
      if (g.width > 0 && g.height > 0) {
        const color = cell.color;
        quads.push({
          page: g.page,
          x: penX + g.xoffset * s,
          y: baseline + g.yoffset * s,
          w: g.width * s,
          h: g.height * s,
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
      penX += g.xadvance * s + ls;
      const prev = cells[i - 1];
      if (prev !== undefined) penX += kernBetween(font, prev, cell);
    }
    caretX.push(penX); // 行尾
    lineCaretX.push(caretX);
    yTop += lineHeightPx;
  }

  return {
    quads,
    width: boxWidth,
    height: yTop,
    lineCount: lines.length,
    truncated,
    missing: Array.from(missingSet).sort((a, b) => a - b),
    lineCaretX,
  };
}

/**
 * 排版（单样式）。返回四边形列表与度量。
 *
 * 调用方（控件层）负责缓存：文本没变就不要重排 —— 这个函数是纯的，
 * 缓存键应当是「文本 + 样式 + 字体 id」，不是指针。
 *
 * ★ 它就是 `layoutRichText` 的单 run 特例，**没有第二份实现**（见那边的 ★★）。
 */
export function layoutText(font: BitmapFont, text: string, style: TextStyle = {}): TextLayout {
  return layoutRichText(font, [{ text }], style);
}

/**
 * 已知缺口（不打算在这一版做，写下来免得下一个人以为是漏了）：
 *   ① ~~**避头尾**~~ ✅ 批111：断点定下来之后，若「下一行首字是禁则」或
 *      「本行末字是禁则」，就把本行末尾的字符逐个带到下一行，上界是**本行至少留一个字**
 *      （不设上界的话「（（（（」会把整行推空并死循环）。两张表分开：
 *      一个字符不可能既不许在行首又不许在行尾，合成一张会让字少的行被拖空。
 *   ② **双向文本（RTL）** — 阿拉伯语/希伯来语的游标方向相反，需要**显式的 run 切分**
 *      与 bidi 算法（UAX #9）。这不是"加个反向遍历"能做到的：数字与标点在 RTL 段落里
 *      仍然从左往右排。建议单独立项，不要和避头尾混在一轮里 —— 一个改断点，一个改顺序。
 *   ③ ~~**富文本**（行内换色/换字号）~~ ✅ 批114：`layoutRichText` + `TextRun`，
 *      按 run 摊平成「每码点带样式」再走同一套断行（断行逻辑不复制一份）。
 *      行高与基线取**本行最大字号**；kerning 只在同一字号之间加（跨字号那一对没有定义）。
 *   剩下的只有 RTL —— 它不影响"用中文与英文做一款饥荒类游戏"。
 */
