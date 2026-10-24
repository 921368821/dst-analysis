/**
 * L4 · 资产导入 · 解码 · 格式分发
 *
 * ★ 为什么需要这一层（否则"支持 JPEG"只是"有个函数能调"）：
 *   导入管线里同时有 `.png` 与 `.jpg`，调用方（浏览器入口、图集合成、判据）
 *   不该自己写 `if (magic === ...)` —— 那种分支一旦分散，新增格式就会有
 *   某个调用点忘了改，症状是"某个入口的 JPG 静默变成黑图"。
 *
 * ★ 判定用**文件头魔数**，不用扩展名：
 *   扩展名是文件名的一部分，可以被随便改；而 `.meta` 派生的稳定 id 也基于路径。
 *   用魔数判定让"foo.jpg 其实是 PNG"这类情况解出正确的像素。
 *
 * ★ 返回值统一成 `DecodedPng` 的形状（宽高 + RGBA8 + 位深/色彩类型），
 *   是因为下游（`buildAtlasFromSources`、纹理上传）只认这个形状。
 *   需要 JPEG 专有信息（是否渐进、子采样、EXIF 方向）时直接调 `decodeJpeg`。
 *   这个类型名里的 "Png" 是历史包袱 —— 它实际表示"已解码的位图"。
 */

import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err } from "../../../foundation/result.ts";
import type { DecodedPng, DecodePngOptions } from "./png.ts";
import { decodePng } from "./png.ts";
import type { DecodeJpegOptions } from "./jpeg.ts";
import { decodeJpeg, isJpeg } from "./jpeg.ts";

export type ImageFormat = "png" | "jpeg";

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] as const;

export function isPng(bytes: Uint8Array): boolean {
  if (bytes.length < PNG_SIGNATURE.length) return false;
  for (let i = 0; i < PNG_SIGNATURE.length; i++) {
    if (bytes[i] !== PNG_SIGNATURE[i]) return false;
  }
  return true;
}

/** 按魔数识别格式；都不匹配 → null（不猜）。 */
export function sniffImageFormat(bytes: Uint8Array): ImageFormat | null {
  if (isPng(bytes)) return "png";
  if (isJpeg(bytes)) return "jpeg";
  return null;
}

export interface DecodeImageOptions {
  readonly png?: DecodePngOptions;
  readonly jpeg?: DecodeJpegOptions;
}

/**
 * 解码任意受支持的位图，产出统一的 RGBA8。
 * 不认识的格式 → `ASSET.UNKNOWN_FORMAT`（错误里带上前 4 字节，便于对账）。
 */
export function decodeImage(bytes: Uint8Array, opts?: DecodeImageOptions): Result<DecodedPng, EngineError> {
  const fmt = sniffImageFormat(bytes);
  if (fmt === "png") return decodePng(bytes, opts?.png);
  if (fmt === "jpeg") return decodeJpeg(bytes, opts?.jpeg);
  const head = Array.from(bytes.subarray(0, Math.min(4, bytes.length)), (x) => x.toString(16).padStart(2, "0"));
  return err(
    engineError(
      "ASSET.UNKNOWN_FORMAT",
      `无法识别的图片格式：开头字节 ${head.join(" ") || "(空)"}（支持 PNG 89 50 4e 47 / JPEG ff d8 ff）`,
      { head: head.join(" "), byteLength: bytes.length },
    ),
  );
}
