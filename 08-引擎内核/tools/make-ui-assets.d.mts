/**
 * 工具层类型声明：`tools/make-ui-assets.mjs` 供测试直接调用 `build()`。
 *
 * 为什么判据要**调函数**而不是只比磁盘：
 *   ① 磁盘比对（`--check`，另有一条判据跑 CLI）只能回答"一致/不一致"，
 *      说不了"哪里错了"；而生成器的变异需要**具体**的观测量（图集里有没有墨、
 *      字形矩形有没有叠、行高能不能装下字形）才能被分辨；
 *   ② 更重要的是：只比磁盘的话，**改了生成器而没重跑**会红在"不一致"上，
 *      而"改了生成器且重跑了"就全绿 —— 那等于判据守的是"记得跑生成器"，
 *      不是"生成的资产是对的"。
 */

/** 排布后的一个字形（`x/y` 是图集内像素坐标）。 */
export interface PlacedGlyph {
  readonly code: number;
  readonly cols: number[][];
  readonly w: number;
  readonly h: number;
  /** 墨迹顶行在基线上方多少像素（`.fnt` 的 `yoffset` 就是它的相反数）。 */
  readonly inkTop: number;
  /** 前进量（px），`.fnt` 的 `xadvance`。 */
  readonly advance: number;
  readonly xoff?: number;
  /** 空格这类无图形：`w === 0` 且 `x === y === 0`。 */
  readonly x: number;
  readonly y: number;
}

export interface BuiltAtlas {
  readonly width: number;
  readonly height: number;
}

/** 一张字体（图 + `.fnt` 文本 + 排布结果）。 */
export interface BuiltFont {
  readonly png: Uint8Array;
  readonly fnt: string;
  readonly glyphCount: number;
  readonly placed: readonly PlacedGlyph[];
  readonly atlas: BuiltAtlas;
}

/** 中文字体多出来的诊断量。 */
export interface BuiltCjkFont extends BuiltFont {
  /** 墨迹全空的字形数（理论上只有空格）。 */
  readonly blank: number;
  readonly meta: {
    readonly face: string;
    readonly size: number;
    readonly tracking: number;
    readonly lineHeight: number;
    readonly base: number;
    readonly page: string;
  };
}

export interface BuildResult {
  /** `[文件名, 字节]`，顺序固定 ⇒ 产物逐字节可复现。 */
  readonly files: readonly (readonly [string, Uint8Array])[];
  readonly glyphCount: number;
  readonly placed: readonly PlacedGlyph[];
  readonly atlas: BuiltAtlas;
  readonly cjk: BuiltCjkFont;
}

/** 在内存里跑一遍完整生成（**不写盘**）。 */
export function build(): BuildResult;

/** 读 `tools/cjk-charset.txt`（`#` 注释 / `@ascii LO HI` / 逐字符行）。 */
export function loadCharset(): Set<number>;

export const CJK_FACE: string;
export const CHARSET_FILE: string;
