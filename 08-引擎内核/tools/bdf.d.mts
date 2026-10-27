/**
 * 工具层类型声明：`tools/bdf.mjs`（BDF 位图字库解析）供测试与生成器直接使用。
 *
 * 为什么要这一份：tsconfig 是 strict 且没有 `allowJs`，`.mjs` 必须配 `.d.mts`
 * （与 `png-encode.d.mts` / `gap-check.d.mts` 同一口径）。
 *
 * ★ 声明按**生成器真正用到的字段**写，不多写：多写的字段会让"生成器读了一个
 *   解析器没给的属性"（= `undefined`）在类型层面看不出来。
 */

/** 一个字形。`cols[x][y]`，1 = 墨；坐标为字形位图内部坐标（左上原点）。 */
export interface BdfGlyphShape {
  readonly code: number;
  /** 前进量（px）。Unifont 是 duospaced：半角 8 / 全角 16。 */
  readonly advance: number;
  /** 位图宽高（`BBX`）。**墨迹全空时为 0**（空格走这条路）。 */
  readonly w: number;
  readonly h: number;
  /** `BBX` 的 xoffset（左侧留白，向右为正）。 */
  readonly xoff: number;
  /** `BBX` 的 yoffset：**位图底行**相对基线、向上为正。 */
  readonly yoff: number;
  /** `w === 0` 时为 null。 */
  readonly cols: number[][] | null;
}

export interface BdfFont {
  readonly ascent: number;
  readonly descent: number;
  readonly bboxW: number;
  readonly bboxH: number;
  readonly glyphs: Map<number, BdfGlyphShape>;
  /** 扫过的 `STARTCHAR` 数（应等于文件里 `CHARS` 声明的数）。 */
  readonly scanned: number;
}

export function parseBdf(text: string, only?: ReadonlySet<number>): BdfFont;
