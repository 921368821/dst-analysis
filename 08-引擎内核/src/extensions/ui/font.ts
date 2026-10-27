/**
 * L4 · 位图字体（BMFont 文本格式）
 *
 * 为什么是位图字体，而不是「用系统字体画文本」：
 *   ① 引擎要在 Node 里跑判据、在浏览器里跑同一份代码 —— 系统字体在两边**度量不同**，
 *      同一段文本的换行位置就会不同，UI 布局变成"只在某个宿主上才对"；
 *   ② 2.5D 像素风（饥荒那一类）本来就要求不做字形抗锯齿 ——
 *      系统字体渲染的小字缩放后会糊成一片；
 *   ③ BMFont 是行业事实标准（AngelCode 格式），美术能从任何造字工具导出，
 *      引擎不必自己实现字库解析。
 *
 * ★★ UV 的 v 轴**不翻转**，与 `batch2d.ts` 里 T330 的结论同源：
 *   BMFont 的 `y` 是**从图片顶部**往下数的像素行号，而上传纹理时像素数组的
 *   第一行就落在 `v=0`。两者同向 ⇒ `v = y / scaleH`；
 *   任何 `1 - v` 都会把字形镜像到别的行去。这个错误的坏形状很隐蔽：
 *   等高的字形镜像后仍然"看着像字"，只有行高不一致时才露出"上下颠倒但位置对"。
 *
 * ★ 解析**只做数据搬运与校验，不做容错兜底**：
 *   静默忽略一个坏字形，症状是「某个字突然不显示」，而字体文件看起来是好的。
 *   所有能判定的坏数据都在这里失败，并带稳定错误码。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 一个字形在纹理页上的位置与度量（除 UV 外单位均为像素）。 */
export interface FontGlyph {
  /** 码点（不是字节）。BMFont 的 `id` 就是它。 */
  readonly code: number;
  /** 纹理页下标（0 起）。多页字体靠它决定绑哪张纹理。 */
  readonly page: number;
  /** 归一化 UV，左上 / 右下。**v 不翻转**（见文件头）。 */
  readonly u0: number;
  readonly v0: number;
  readonly u1: number;
  readonly v1: number;
  /** 字形矩形尺寸（像素）。空白字符为 0。 */
  readonly width: number;
  readonly height: number;
  /** 相对「光标 + 基线」的偏移（BMFont 语义）。 */
  readonly xoffset: number;
  readonly yoffset: number;
  /** 前进量（像素）。**排版唯一的水平推进依据** —— 与 width 不等（含侧边距）。 */
  readonly xadvance: number;
}

export interface FontPage {
  /** BMFont 的 `page id`，仅用于诊断。分批用的是数组下标。 */
  readonly id: number;
  /** 文件名，仅用于诊断（「这个字体要配哪张图」）。 */
  readonly file: string;
}

export interface BitmapFont {
  readonly id: string;
  /** 字号（BMFont 的 `info size`），像素。 */
  readonly size: number;
  /** 行高（像素）。 */
  readonly lineHeight: number;
  /** 基线到行顶的距离（像素）。 */
  readonly base: number;
  readonly scaleW: number;
  readonly scaleH: number;
  readonly pages: readonly FontPage[];
  readonly glyphs: ReadonlyMap<number, FontGlyph>;
  /** kerning：key = `first * 0x200000 + second`（码点最大 0x10FFFF < 0x200000）。 */
  readonly kernings: ReadonlyMap<number, number>;
  /**
   * 缺字时占用的前进量（像素）。
   * ★ 必须有：缺字若按 0 前进，文本会「少一个字的宽度」，
   *   而布局算出的总宽仍是满的 ⇒ 居中会偏、右对齐会溢出。
   */
  readonly missingAdvance: number;
}

/** kerning 的 key。用整数不用字符串：每帧要查几千次。 */
export function kerningKey(first: number, second: number): number {
  return first * 0x200000 + second;
}

export const FONT_ERR = {
  NO_COMMON: "UI.FONT_NO_COMMON",
  BAD_SCALE: "UI.FONT_BAD_SCALE",
  BAD_LINE_HEIGHT: "UI.FONT_BAD_LINE_HEIGHT",
  BAD_BASE: "UI.FONT_BAD_BASE",
  NO_GLYPHS: "UI.FONT_NO_GLYPHS",
  DUP_GLYPH: "UI.FONT_DUP_GLYPH",
  GLYPH_OOB: "UI.FONT_GLYPH_OOB",
  BAD_ADVANCE: "UI.FONT_BAD_ADVANCE",
  BAD_NUMBER: "UI.FONT_BAD_NUMBER",
  UNSUPPORTED_FORMAT: "UI.FONT_UNSUPPORTED_FORMAT",
} as const;

interface RawChar {
  readonly code: number;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
  readonly xo: number;
  readonly yo: number;
  readonly xa: number;
  readonly pg: number;
}

/** 解析 BMFont 的**文本**格式（.fnt）。二进制与 XML 版本不实现，遇到明确失败。 */
export function parseBmFont(
  text: string,
  opts: { readonly id?: string; readonly pageBase?: number } = {},
): Result<BitmapFont, EngineError> {
  const id = opts.id ?? "font";
  /**
   * 这份 `.fnt` 的**第 0 页**落在全局图集的第几页。
   *
   * ★★ BMFont 的 `page id` 是**字体局部**的编号，它从来就不是"全局图集下标"：
   *   每个 `.fnt` 都说自己从 0 开始（造字工具就是这么导的，一份字体只有一个纹理页时
   *   连 `page` 行都只有一行）。而一个 UI 模块的 `pageSources` 是**全局**的数组 ——
   *   5×7 字形、皮肤、中文字形各有各的图，谁都得有个位置。
   *   两层编号之间必须有一次显式换算，否则第二张字体要么把自己的页当成 0
   *   （画面上是"中文采样到了 5×7 那张图"，一片乱纹），要么被迫在 `.fnt` 里写假页号
   *   （写出 `page id=2` 却不带 0/1 两行，解析器会判它引用不存在的页 —— 那是自相矛盾的资产）。
   */
  const pageBase = opts.pageBase ?? 0;
  if (!Number.isInteger(pageBase) || pageBase < 0) {
    return err(engineError(FONT_ERR.BAD_NUMBER, `pageBase 必须是非负整数：${String(pageBase)}`));
  }

  // 二进制以 "BMF" 开头、XML 以 "<" 开头。这两种不静默返回空字体 ——
  // 空字体的症状是「所有字都不显示」，而调用方以为字体加载成功了。
  const head = text.slice(0, 4);
  if (head.startsWith("BMF")) {
    return err(
      engineError(FONT_ERR.UNSUPPORTED_FORMAT, "这是 BMFont 二进制格式，当前只支持文本格式（.fnt）"),
    );
  }
  if (head.trimStart().startsWith("<")) {
    return err(engineError(FONT_ERR.UNSUPPORTED_FORMAT, "这是 BMFont XML 格式，当前只支持文本格式（.fnt）"));
  }

  let size = 0;
  let lineHeight = 0;
  let base = 0;
  let scaleW = 0;
  let scaleH = 0;
  let sawCommon = false;

  const pages: FontPage[] = [];
  const rawChars: RawChar[] = [];
  const kernings = new Map<number, number>();

  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (line === "") continue;
    const sp = line.indexOf(" ");
    const tag = sp < 0 ? line : line.slice(0, sp);
    const rest = sp < 0 ? "" : line.slice(sp + 1);

    if (tag === "info") {
      const kv = parseKeyValues(rest);
      const s = num(kv, "size");
      if (s === undefined) return err(engineError(FONT_ERR.BAD_NUMBER, `info 行缺少 size：${line}`));
      size = s;
    } else if (tag === "common") {
      const kv = parseKeyValues(rest);
      const lh = num(kv, "lineHeight");
      const bs = num(kv, "base");
      const sw = num(kv, "scaleW");
      const sh = num(kv, "scaleH");
      if (lh === undefined || bs === undefined || sw === undefined || sh === undefined) {
        return err(engineError(FONT_ERR.BAD_NUMBER, `common 行缺字段：${line}`));
      }
      lineHeight = lh;
      base = bs;
      scaleW = sw;
      scaleH = sh;
      sawCommon = true;
    } else if (tag === "page") {
      const kv = parseKeyValues(rest);
      const pid = num(kv, "id");
      if (pid === undefined) return err(engineError(FONT_ERR.BAD_NUMBER, `page 行缺少 id：${line}`));
      pages.push({ id: pid, file: kv.get("file") ?? "" });
    } else if (tag === "char") {
      const kv = parseKeyValues(rest);
      const code = num(kv, "id");
      const x = num(kv, "x");
      const y = num(kv, "y");
      const w = num(kv, "width");
      const h = num(kv, "height");
      const xa = num(kv, "xadvance");
      if (
        code === undefined ||
        x === undefined ||
        y === undefined ||
        w === undefined ||
        h === undefined ||
        xa === undefined
      ) {
        return err(engineError(FONT_ERR.BAD_NUMBER, `char 行缺字段：${line}`));
      }
      rawChars.push({
        code,
        x,
        y,
        w,
        h,
        xo: num(kv, "xoffset") ?? 0,
        yo: num(kv, "yoffset") ?? 0,
        xa,
        pg: num(kv, "page") ?? 0,
      });
    } else if (tag === "kerning") {
      const kv = parseKeyValues(rest);
      const first = num(kv, "first");
      const second = num(kv, "second");
      const amount = num(kv, "amount");
      if (first === undefined || second === undefined || amount === undefined) {
        return err(engineError(FONT_ERR.BAD_NUMBER, `kerning 行缺字段：${line}`));
      }
      kernings.set(kerningKey(first, second), amount);
    }
    // 其它标签（`chars count=…`、`kernings count=…`、未来的扩展）明确忽略：
    // 那是**计数**，与逐条数据重复；信计数不如信数据。
  }

  if (!sawCommon) {
    return err(engineError(FONT_ERR.NO_COMMON, "缺少 common 行（拿不到 lineHeight / scaleW / scaleH）"));
  }
  if (!(scaleW > 0) || !(scaleH > 0)) {
    return err(engineError(FONT_ERR.BAD_SCALE, `纹理页尺寸必须 > 0：${scaleW}x${scaleH}`, { scaleW, scaleH }));
  }
  if (!(lineHeight > 0)) {
    return err(engineError(FONT_ERR.BAD_LINE_HEIGHT, `lineHeight 必须 > 0：${lineHeight}`));
  }
  if (!Number.isFinite(base) || base < 0) {
    return err(engineError(FONT_ERR.BAD_BASE, `base 必须 ≥ 0：${base}`));
  }
  if (rawChars.length === 0) return err(engineError(FONT_ERR.NO_GLYPHS, "没有任何 char 行"));
  // 省掉 page 行是合法的（单页字体常见），补一个只用于诊断的 0 号页。
  if (pages.length === 0) pages.push({ id: 0, file: "" });

  const glyphs = new Map<number, FontGlyph>();
  for (const c of rawChars) {
    // ★ 重复码点：报错而不是覆盖。静默覆盖的症状是「某个字用了别的字的字形」，
    //   而且只在特定造字工具的导出顺序下出现。
    if (glyphs.has(c.code)) {
      return err(engineError(FONT_ERR.DUP_GLYPH, `字符 ${c.code} 重复定义`, { code: c.code }));
    }
    if (!Number.isFinite(c.xa) || c.xa < 0) {
      return err(engineError(FONT_ERR.BAD_ADVANCE, `字符 ${c.code} 的 xadvance 非法：${c.xa}`, { code: c.code }));
    }
    if (c.x < 0 || c.y < 0 || c.w < 0 || c.h < 0 || c.x + c.w > scaleW || c.y + c.h > scaleH) {
      return err(
        engineError(
          FONT_ERR.GLYPH_OOB,
          `字符 ${c.code} 的矩形超出纹理页 ${scaleW}x${scaleH}：x=${c.x} y=${c.y} w=${c.w} h=${c.h}`,
          { code: c.code },
        ),
      );
    }
    if (c.pg < 0 || c.pg >= pages.length) {
      return err(
        engineError(FONT_ERR.BAD_NUMBER, `字符 ${c.code} 引用不存在的页 ${c.pg}（共 ${pages.length} 页）`, {
          code: c.code,
        }),
      );
    }
    const w = c.w;
    const h = c.h;
    glyphs.set(c.code, {
      code: c.code,
      // 校验用局部页号（`c.pg`），落表用全局页号（`c.pg + pageBase`）——
      // 这两个数在单页字体里恰好相等，于是"忘了换算"在 5×7 上完全看不出来。
      page: c.pg + pageBase,
      // ★ 恒等映射，理由见文件头。
      u0: c.x / scaleW,
      v0: c.y / scaleH,
      u1: (c.x + w) / scaleW,
      v1: (c.y + h) / scaleH,
      width: w,
      height: h,
      xoffset: c.xo,
      yoffset: c.yo,
      xadvance: c.xa,
    });
  }

  return ok({
    id,
    size,
    lineHeight,
    base,
    scaleW,
    scaleH,
    pages,
    glyphs,
    kernings,
    // 缺字占位：半个字号是"看得见有个东西缺了、但不会把行撑开"的折中。
    missingAdvance: size > 0 ? size / 2 : lineHeight / 2,
  });
}

/** 取字形。缺字返回 undefined（由排版层统一处理，别在这里造一个假字形）。 */
export function glyphOf(font: BitmapFont, code: number): FontGlyph | undefined {
  return font.glyphs.get(code);
}

/** 取一对字符之间的字距调整（没有就是 0）。 */
export function kerningOf(font: BitmapFont, first: number, second: number): number {
  return font.kernings.get(kerningKey(first, second)) ?? 0;
}

/**
 * 字体注册表：按 id 取字体。
 * ★ 为什么不做"按字号自动挑最近的字体"：位图字体缩放会糊，
 *   自动挑一个"差 2px"的字体会让画面边界模糊而没人知道为什么。
 *   要别的字号就再注册一个字体，id 由使用方显式写。
 */
export class FontRegistry {
  private readonly fonts = new Map<string, BitmapFont>();
  private readonly listeners = new Set<() => void>();

  /**
   * 订阅"字体表变了"。
   *
   * ★★ 为什么必须有这个通知，而不是让调用方记得手动清缓存：
   *   文本排版结果里**烘进了字形来源**（`page` 下标、UV、`xadvance`、kerning）。
   *   热重载一个字体（同 id、不同图集或不同字号）之后，旧缓存里的四边形
   *   指向的是**旧图集的坐标** —— 画面上字会变成另一堆乱码/空白，
   *   而布局量出来的宽高还是旧的。
   *   让"谁改字体"顺手记得"谁清缓存"是不可靠的：注册点可能有三处
   *   （启动、编辑器导入、热重载），漏一处就复现一次。
   *   所以通知由**表自己**发：改了表就等于旧缓存作废，这条因果关系写在源头。
   *
   * 返回退订函数（dispose 时调用，避免模块销毁后还被通知）。
   */
  onRegister(cb: () => void): () => void {
    this.listeners.add(cb);
    return () => {
      this.listeners.delete(cb);
    };
  }

  register(font: BitmapFont): void {
    if (this.fonts.has(font.id)) {
      // 覆盖是允许的（热重载字体），但必须是**显式**的：同名注册两次通常意味着
      // 两个资源用了同一个 id，那会让"我明明换了字体却没变"变成一个谜。
      this.fonts.delete(font.id);
    }
    this.fonts.set(font.id, font);
    for (const cb of this.listeners) cb();
  }

  get(id: string): BitmapFont | undefined {
    return this.fonts.get(id);
  }

  require(id: string): BitmapFont {
    const f = this.fonts.get(id);
    if (f === undefined) {
      throw new Error(`字体未注册：${id}（已注册：${Array.from(this.fonts.keys()).sort().join(", ") || "无"}）`);
    }
    return f;
  }

  ids(): readonly string[] {
    return Array.from(this.fonts.keys()).sort();
  }
}

/**
 * 解析 `key=value` 对。value 可以是带引号的字符串或裸值。
 * 引号内的空格不切分（`face="Noto Sans"` 是一个值）。
 */
function parseKeyValues(rest: string): Map<string, string> {
  const out = new Map<string, string>();
  let i = 0;
  const n = rest.length;
  while (i < n) {
    while (i < n && rest[i] === " ") i++;
    const eq = rest.indexOf("=", i);
    if (eq < 0) break;
    const key = rest.slice(i, eq).trim();
    i = eq + 1;
    let value: string;
    if (rest[i] === "\"") {
      const close = rest.indexOf("\"", i + 1);
      if (close < 0) {
        value = rest.slice(i + 1);
        i = n;
      } else {
        value = rest.slice(i + 1, close);
        i = close + 1;
      }
    } else {
      const next = rest.indexOf(" ", i);
      if (next < 0) {
        value = rest.slice(i);
        i = n;
      } else {
        value = rest.slice(i, next);
        i = next;
      }
    }
    if (key !== "") out.set(key, value);
  }
  return out;
}

function num(kv: Map<string, string>, key: string): number | undefined {
  const raw = kv.get(key);
  if (raw === undefined) return undefined;
  const v = Number(raw);
  return Number.isFinite(v) ? v : undefined;
}
