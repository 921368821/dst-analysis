/**
 * L4 · JPEG 解码 · 公开契约
 *
 * ★ 这里只放"调用方看得见的东西"：错误码、`JpegInfo`、选项、失败类型。
 *   解码实现（`parse` / `scan-*` / `reconstruct`）依赖它，它不依赖任何实现文件 ——
 *   这样"给上层看的字段"不会随着熵解码重写而漂移。
 */

import type { DecodedPng } from "../png.ts";

export const JpegErrorCode = {
  BadJpeg: "ASSET.BAD_JPEG",
  Unsupported: "ASSET.UNSUPPORTED_JPEG",
} as const;

export interface JpegInfo {
  /** 人读的过程名，例如 "SOF3 无损（Huffman）" / "SOF9 顺序（算术）"。 */
  readonly process: string;
  /** 过程标记（0xC0..0xCF）。要机器判断请用下面几个布尔量，别解析 process。 */
  readonly sof: number;
  /** SOF2/SOF6/SOF10/SOF14：渐进式。 */
  readonly progressive: boolean;
  /** SOF9/10/11/13/14/15：算术编码。 */
  readonly arithmetic: boolean;
  /** SOF3/7/11/15：无损（无 DCT、无量化表）。 */
  readonly lossless: boolean;
  /** SOF5/6/7/13/14/15：差分帧（分层 JPEG 的第 2..N 帧）。 */
  readonly differential: boolean;
  /**
   * 样本精度（8 / 12 / 2..16）。
   *
   * ★ 12 位不是"解成 8 位了事"：全精度样本在 `pixels16` 里（`keep16: true`），
   *   `pixels` 是 `round(pixels16/257)` 的结果，与 PNG 16 位同一条口径。
   */
  readonly precision: number;
  /** 无损/渐进扫描的点变换 Pt（0 表示没有做点变换）。 */
  readonly pointTransform: number;
  /** 文件里的帧数（分层 JPEG > 1；普通 JPEG 恒为 1）。 */
  readonly frames: number;
  /** 是否分层（出现 DHP 或第二个 SOF）。 */
  readonly hierarchical: boolean;
  /** "4:4:4" / "4:2:2" / "4:2:0" / "4:1:1" …（按最大采样因子命名）。 */
  readonly subsampling: string;
  readonly components: number;
  readonly restartInterval: number;
  /** EXIF Orientation（1 = 正常，未在文件里声明也是 1）。 */
  readonly orientation: number;
  /** Adobe APP14 的 transform（null = 没有 APP14）。0=RGB/CMYK, 1=YCbCr, 2=YCCK。 */
  readonly adobeTransform: number | null;
  /**
   * 文件在熵数据结束前就没有 EOI 了 —— 像素**已经解出来了**，但缺少的数据
   * 被补成了 0（画面会出现灰块/条纹）。
   *
   * ★ 为什么要这个字段而不是直接报错：libjpeg 遇到同样情况是"打警告 + 继续解"，
   *   因为现实里确实存在缺 EOI 但内容可用的扫描件。我们要保留这个宽容度，
   *   但不能像原来那样**一声不响**：调用方（导入器/判据/HUD）可以据此拒绝、
   *   降级或提示。要"宁可失败"的调用方传 `strict: true`。
   */
  readonly truncated: boolean;
}

export interface DecodedJpeg extends DecodedPng {
  readonly jpeg: JpegInfo;
}

export interface DecodeJpegOptions {
  /**
   * 像素数上限（默认 64M = 8192×8192）。防"SOF 声明 60000×60000、
   * 熵数据只有 20 字节"时先分配几 GB 再失败。
   */
  readonly maxPixels?: number;
  /** `"apply"`：按 EXIF Orientation 旋转/镜像像素与宽高。默认 `"ignore"`。 */
  readonly orientation?: "ignore" | "apply";
  /**
   * `true`：文件不完整（没有 EOI）就直接失败，不返回补 0 拼出来的像素。
   * 默认 `false`（与 libjpeg 一致：宽容但标记 `truncated`）。
   */
  readonly strict?: boolean;
  /**
   * 额外产出全精度 `pixels16`（RGBA16 行主序）。
   *
   * ★ 12 位 JPEG 的默认输出是 8 位：**不是因为拿不到 12 位**，而是因为
   *   "要 8 位"是常态。要全精度就打开这个开关 —— 与 PNG 的 `keep16` 同名同义。
   */
  readonly keep16?: boolean;
}

export const DEFAULT_MAX_PIXELS = 64 * 1024 * 1024;

/** 内部失败：带错误码，由 `decodeJpeg` 统一转成 `Result`。 */
export class JpegFailure extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly detail?: Record<string, unknown>,
  ) {
    super(message);
    this.name = "JpegFailure";
  }
}

export function fail(code: string, message: string, detail?: Record<string, unknown>): never {
  throw new JpegFailure(code, message, detail);
}
