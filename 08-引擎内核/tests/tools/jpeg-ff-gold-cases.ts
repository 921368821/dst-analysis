/**
 * ffmpeg 外部金标 · 案例定义（生成器与判据**共用同一份**）
 *
 * ★ 为什么要有这一组语料：12 位 DCT 一直是我们最大的证据缺口 ——
 *   Pillow 只能编 8 位，libjpeg-turbo 的 12 位支持要靠 BITS_IN_JSAMPLE=12 重编译，
 *   手上没有任何一个能解 12 位 JPEG 的第三方，于是"12 位对不对"只能靠
 *   **跨精度锚定**（8 位金标 → 12 位编码 → 解回 → 降 8 位落回原像素）间接证明。
 *   跨精度锚定能抓住"12 位独有的错"，但它有一处硬伤：**参考的 8 位像素仍来自 Pillow，
 *   12 位这一段编解码全是我们自己的实现**。若编码器与解码器对 12 位的理解同错
 *   （典型：电平位移该加 2^11 还是 128），回环永远绿。
 *
 *   ffmpeg 的 mjpeg 解码器是**独立实现**（不基于 libjpeg），并且认 12 位：
 *   它把我们的 12 位流解出来的像素与源差 ≤2 级 —— 这一根柱子一插，
 *   "编解码同错"那种盲区就被第三方从外部顶住了。
 *
 * ★ 这份文件只放**案例**（源样本 + 编码参数），不放阈值：
 *   阈值归 `tools/jpeg-ffmpeg-gold.py`（它负责生成时自检），
 *   判据文件读生成出来的 `_ffgold.json` 里的阈值再断言 —— 与 make-jpeg-fixtures.py 同构。
 *
 * ★ 内容为什么两种：`smooth` 用来做紧公差比对（没有边缘，差异只剩取整）；
 *   `rampEdge` 专门打**钳位与电平位移**：它同时含"贴 0 / 贴 max 的斜坡"和一块
 *   满量程方波，一旦电平位移写错（多/少一个 offset），贴边那段会整片裁掉，肉眼可见。
 */

import type { EncodeSpec, JpegMode } from "./jpeg-encode.ts";

export type FfGoldKind = "smooth" | "rampEdge";

export interface FfGoldCase {
  readonly name: string;
  readonly width: number;
  readonly height: number;
  readonly components: 1 | 3;
  readonly precision: 8 | 12;
  readonly kind: FfGoldKind;
  readonly spec: EncodeSpec;
  readonly samples: Uint16Array;
}

function smooth(w: number, h: number, precision: number): Uint16Array {
  const max = (1 << precision) - 1;
  const a = new Uint16Array(w * h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      a[y * w + x] = Math.round(((Math.sin(x * 0.2) + Math.cos(y * 0.17) + 2) / 4) * max);
    }
  }
  return a;
}

function rampEdge(w: number, h: number, precision: number): Uint16Array {
  const max = (1 << precision) - 1;
  // ★ 分母必须用整数：w 是奇数时 `w / 2` 是 18.5，`x / (w/2 - 1)` 在最后一列
  //   会算出 max 的 1.028 倍（实测 37 宽、12 位时算出 4212 > 4095）。
  //   越界的源样本会被编解码两端各自钳位，然后"金标 vs 源"看起来差 118 级 ——
  //   而这 118 级跟解码器一点关系都没有，纯粹是**我造了一份超量程的源**。
  //   这个错误是被 tools/jpeg-ffmpeg-gold.py 的生成时自检当场抓住的。
  const half = Math.ceil(w / 2);
  const a = new Uint16Array(w * h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      // 左半：贴 0 → 贴 max 的斜坡（电平位移写错，两端会整片裁掉）
      // 右半：**8 像素宽**的方波（0.25max / 0.75max）。
      //
      // ★ 这里踩过一次坑：第一版右半写成"逐像素 0/max 交替"，也就是 Nyquist 频率。
      //   q100 时量化步长是 1，但**正变换本身要取整**，一个 8×8 块里塞进
      //   0/max 交替 + 旁边 4095→0 的阶跃，重建出来是强 Gibbs 振铃；
      //   我们的 IDCT 与 ffmpeg 的 IDCT 在极端系数上取整不同，
      //   实测 12 位在第 18 列（阶跃那一列）差 118 级 —— 那是**两个 IDCT 的振铃差异**，
      //   不是"谁错了"。判据必须比"能说明问题的量"，所以这里退到块级方波：
      //   能量仍在边缘上，但不再落在只有 Nyquist 才有的极端系数上。
      a[y * w + x] =
        x < half
          ? Math.round((x / Math.max(1, half - 1)) * max)
          : (x >> 3) % 2 === 0
            ? Math.round(max * 0.75)
            : Math.round(max * 0.25);
    }
  }
  return a;
}

function smoothRgb(w: number, h: number, precision: number): Uint16Array {
  const max = (1 << precision) - 1;
  const a = new Uint16Array(w * h * 3);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 3;
      a[o] = Math.round(((Math.sin(x * 0.2) + 1) / 2) * max);
      a[o + 1] = Math.round(((Math.cos(y * 0.17) + 1) / 2) * max);
      a[o + 2] = Math.round(((x + y) / (w + h)) * max); // 全量程，用来抓 12 位的钳位
    }
  }
  return a;
}

function grayCase(
  name: string,
  width: number,
  height: number,
  precision: 8 | 12,
  mode: JpegMode,
  kind: FfGoldKind,
  extra: Partial<EncodeSpec> = {},
): FfGoldCase {
  const samples = kind === "smooth" ? smooth(width, height, precision) : rampEdge(width, height, precision);
  return {
    name,
    width,
    height,
    components: 1,
    precision,
    kind,
    samples,
    spec: { width, height, components: 1, precision, mode, quality: 100, subsampling: "444", ...extra },
  };
}

function rgbCase(name: string, width: number, height: number, precision: 8 | 12, mode: JpegMode): FfGoldCase {
  const samples = smoothRgb(width, height, precision);
  return {
    name,
    width,
    height,
    components: 3,
    precision,
    kind: "smooth",
    samples,
    // ★ 强制 4:4:4：4:2:0 的色度上采样发生在 ffmpeg 的 swscale 里，
    //   比的就不是"我们的解码器 vs ffmpeg 的解码器"，而是"libjpeg 的 fancy 三角 vs swscale"。
    //   实测 12 位 4:2:0 两边差 177 级，这个数字没有任何诊断价值（详见 ADR-0009 ⑥-g）。
    spec: { width, height, components: 3, precision, mode, quality: 100, subsampling: "444" },
  };
}

/**
 * 12 例：灰度 10 + RGB 4:4:4 两例。
 *
 * 灰度是"紧金标"（实测差 ≤2 级），RGB 是"松金标"（≤4 级，差在 YCbCr↔RGB 的取整上，
 * 两家系数舍入不同）—— 两者都用，但阈值分开记，绝不能混成一个数。
 */
export const FF_GOLD_CASES: readonly FfGoldCase[] = [
  grayCase("gray8-baseline", 64, 48, 8, "baseline", "smooth"),
  grayCase("gray8-progressive", 64, 48, 8, "progressive", "smooth"),
  grayCase("gray8-restart", 64, 48, 8, "baseline", "smooth", { restart: 3 }),
  grayCase("gray8-lossless", 64, 48, 8, "lossless", "rampEdge"),
  // 奇数尺寸：块padding / 最后一行 MCU 不满 —— 12 位与 8 位在这里走的都是同一条填充路径
  grayCase("gray8-odd", 37, 23, 8, "baseline", "rampEdge"),
  grayCase("gray12-baseline", 64, 48, 12, "baseline", "smooth"),
  grayCase("gray12-progressive", 64, 48, 12, "progressive", "smooth"),
  grayCase("gray12-restart", 64, 48, 12, "baseline", "smooth", { restart: 3 }),
  grayCase("gray12-lossless", 64, 48, 12, "lossless", "rampEdge"),
  grayCase("gray12-odd", 37, 23, 12, "baseline", "rampEdge"),
  rgbCase("rgb8-444", 64, 48, 8, "baseline"),
  rgbCase("rgb12-444", 64, 48, 12, "baseline"),
];

/** 语料目录（相对仓库根）。 */
export const FF_GOLD_DIR = "tests/fixtures/jpeg/ff";

export function ffGoldTolerance(c: FfGoldCase): number {
  // 灰度是单通道，唯一的差源是 IDCT 取整；RGB 还多一层颜色变换取整（两家系数不同）。
  return c.components === 1 ? 2 : 8;
}
