/**
 * L4 · 资产导入 · 位图贴图（PNG / JPEG）
 *
 * ★ 只读**文件头**，不解像素。
 *   边界很清楚：
 *     · 导入阶段要的是"宽高、位深、是否带 alpha" —— PNG 全在 IHDR 里，
 *       JPEG 全在 SOF 里，而编辑器缩略图/图集排版/内存预算只需要这些；
 *     · 真正解码成 RGBA 是 `decode/png.ts` 与 `decode/jpeg.ts` 的事。
 *   所以这里**故意**不校验 PNG 的 CRC、不读 IDAT、不解 JPEG 的熵数据：
 *   一份数据区损坏的图会在这里导入成功，在解码时失败。报错点仍然明确。
 *
 * ★ 为什么 JPEG 也要在这里认，而不是"让下一个人自己解"：
 *   导入器决定"这个文件能不能进资产库"。`.jpg` 没有导入器，它就永远进不了图集 ——
 *   解码器写得再对，"支持 JPEG"也只是一句空话。
 *   过程与精度的支持判据**不在这里重写**：直接调解码器的 `checkProcessSupport()`。
 *   两边各写一份的后果实测过 —— 解码器支持了算术/无损/12 位之后，
 *   导入器的旧清单把它们全拦在门外，而两边测试都是绿的。
 */

import { AssetType } from "../../../core/asset/asset.ts";
import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err, ok } from "../../../foundation/result.ts";
import type { ImportedArtifact, SourceImporter } from "../importer.ts";
import { contentHash } from "../hash.ts";

/**
 * ★ 版本号不因"产物多了一个描述字段"而提升：
 *   `format` 只是给人看的标签，解码路径靠**魔数**判定（见 decode/image.ts），
 *   所以旧产物缺它也不影响任何行为。为纯描述字段让所有用户缓存失效，
 *   等于把版本号当成"我改过这个文件"来用 —— 那它就不再是缓存契约。
 */
const VERSION = 1;

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] as const;

/** PNG 的签名 8 + 块头 8（长度 4 + 类型 4）+ IHDR 数据 13 + CRC 4。 */
const MIN_PNG_HEADER_BYTES = 33;
/** IHDR 数据区固定 13 字节。 */
const IHDR_DATA_BYTES = 13;

function u32be(b: Uint8Array, at: number): number {
  return (b[at]! * 0x1000000 + (b[at + 1]! << 16) + (b[at + 2]! << 8) + b[at + 3]!) >>> 0;
}

function u16be(b: Uint8Array, at: number): number {
  return (b[at]! << 8) | b[at + 1]!;
}

function ascii4(b: Uint8Array, at: number): string {
  return String.fromCharCode(b[at]!, b[at + 1]!, b[at + 2]!, b[at + 3]!);
}

function hexBytes(b: Uint8Array, from: number, to: number): string {
  return Array.from(b.slice(from, to), (x) => x.toString(16).padStart(2, "0")).join(" ");
}

function badSource(sourcePath: string, why: string): EngineError {
  return engineError("IMPORT.BAD_SOURCE", `${sourcePath}: ${why}`, { path: sourcePath, importer: "texture" });
}

/**
 * alpha 只看色彩类型自带的 alpha 通道（4=灰度+alpha，6=RGBA）。
 * 调色板图（3）靠 tRNS 块声明透明色 —— 那需要继续扫块，超出"只读头"的边界；
 * 宁可在需要时按解码结果为准，也不在这里猜。
 */
function hasAlphaChannel(colorType: number): boolean {
  return colorType === 4 || colorType === 6;
}

interface ImageHeader {
  readonly width: number;
  readonly height: number;
  /**
   * **源精度**（与 PNG 的 IHDR 位深同义）：8 位 JPEG 是 8，12 位是 12，
   * 无损 2..16 就是那个数。
   *
   * ★ 不要把它读成"解码输出的容器宽度"：JPEG/PNG 的 `pixels` **恒为 RGBA8**，
   *   全精度另走 `pixels16`（解码时 `keep16: true`）。这里若写 8，
   *   一张 12 位无损图就和 8 位图分不出来了 —— 下游没法据此决定要不要拿全精度。
   */
  readonly bitDepth: number;
  /** JPEG 过程名（"SOF9 扩展顺序（算术）"），PNG 没有。 */
  readonly process?: string;
  /**
   * 分层（hierarchical）标记：文件里有 DHP，末帧是差分帧。
   *
   * ★ 这个字段不改变解码结果（分层图解出来仍是一张普通纹理），但它决定
   *   **上面两个尺寸读的是谁** —— 见 `readJpegHeader` 里关于 DHP 的注释。
   */
  readonly hierarchical?: boolean;
  readonly colorType: number;
  readonly hasAlpha: boolean;
  readonly format: "png" | "jpeg";
}

function readPngHeader(sourcePath: string, source: Uint8Array): Result<ImageHeader, EngineError> {
  if (source.length < MIN_PNG_HEADER_BYTES) {
    return err(
      badSource(
        sourcePath,
        `PNG 头截断：读 IHDR 需要 ${MIN_PNG_HEADER_BYTES} 字节（签名 8 + 块头 8 + IHDR 13 + CRC 4），实际 ${source.length}`,
      ),
    );
  }
  const chunkLength = u32be(source, 8);
  if (chunkLength !== IHDR_DATA_BYTES) {
    return err(badSource(sourcePath, `第一个块不是 IHDR：块长度 ${chunkLength}（期望 13）`));
  }
  const chunkType = ascii4(source, 12);
  if (chunkType !== "IHDR") {
    return err(badSource(sourcePath, `第一个块必须是 IHDR，实际是 "${chunkType}"`));
  }
  const width = u32be(source, 16);
  const height = u32be(source, 20);
  const bitDepth = source[24]!;
  const colorType = source[25]!;
  if (width === 0 || height === 0) {
    return err(badSource(sourcePath, `IHDR 宽高必须非 0，实际 ${width}×${height}`));
  }
  if (bitDepth === 0) {
    return err(badSource(sourcePath, "IHDR 位深为 0"));
  }
  return ok({ width, height, bitDepth, colorType, hasAlpha: hasAlphaChannel(colorType), format: "png" });
}

/**
 * JPEG 段的"能不能解"判据 **不在这个文件里**。
 *
 * ★ 这里曾经是一张手写的"SOF3/SOF9/… 不支持"表，与解码器各存一份。
 *   解码器把算术、无损、分层全做完之后，这张表没跟着改，结果就是：
 *   解码器能解、导入器在门口就拦下，下游永远吃不到 —— 而两边测试各自全绿。
 *   （这种"两处规则、各自自洽"比单点 bug 更坏：它让两边的绿灯都失去意义。）
 *   现在判据只剩一份：解码器的 `checkProcessSupport()`，导入器只是**调用**它。
 */
import { checkProcessSupport, SOF_NAMES } from "../decode/jpeg/frame.ts";

function readJpegHeader(sourcePath: string, source: Uint8Array): Result<ImageHeader, EngineError> {
  if (source.length < 4) return err(badSource(sourcePath, "JPEG 头截断：连 SOI 都不完整"));
  /**
   * ★ 分层文件的第一帧**不是完成态图像**：按 B.3.1 它是 1/2（或更小）分辨率的参考帧，
   *   真正的尺寸与精度写在 DHP（FF DE）里，再靠 EXP + 差分帧逐级合成。
   *   所以"扫到第一个 SOF 就返回宽高"对分层文件会报出**一半的尺寸**（40×24 → 20×12），
   *   而解码器解出来的像素是 40×24 —— 元数据与实际产物对不上，下游按元数据分配缓冲就会裁掉 3/4。
   *   这里记住 DHP 声明的完成态几何，命中 SOF 时优先用它。
   */
  let dhpWidth = 0;
  let dhpHeight = 0;
  let pos = 2; // 跳过 SOI
  while (pos + 3 < source.length) {
    if (source[pos] !== 0xff) {
      pos++;
      continue;
    }
    const marker = source[pos + 1]!;
    if (marker === 0xff) {
      pos++;
      continue;
    }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      pos += 2;
      continue;
    }
    if (marker === 0xd9) break; // EOI：一直没见到 SOF
    const segLen = u16be(source, pos + 2);
    if (segLen < 2) return err(badSource(sourcePath, `JPEG 段 0x${marker.toString(16)} 长度非法：${segLen}`));
    if (marker === 0xde && segLen >= 8) {
      // DHP 负载：[P, Y(2), X(2), Nf, …] —— 与 SOF 同构，但描述的是完成态图像
      const d = pos + 4;
      if (d + 6 <= source.length) {
        dhpHeight = u16be(source, d + 1);
        dhpWidth = u16be(source, d + 3);
      }
      pos += 2 + segLen;
      continue;
    }
    const isSof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (isSof) {
      const dataStart = pos + 4;
      if (dataStart + 6 > source.length) return err(badSource(sourcePath, "JPEG SOF 段被截断"));
      const precision = source[dataStart]!;
      const frameHeight = u16be(source, dataStart + 1);
      const frameWidth = u16be(source, dataStart + 3);
      const components = source[dataStart + 5]!;
      // 过程 + 精度：**问解码器**，不在这里重写一遍规则
      const support = checkProcessSupport(marker, precision);
      if (!support.ok) {
        return err(
          engineError("IMPORT.UNSUPPORTED_SOURCE", `${sourcePath}: ${support.reason ?? "不支持的 JPEG 过程"}`, {
            path: sourcePath,
            marker: `0x${marker.toString(16)}`,
            precision,
          }),
        );
      }
      const hier = dhpWidth > 0 && dhpHeight > 0;
      const width = hier ? dhpWidth : frameWidth;
      const height = hier ? dhpHeight : frameHeight;
      if (width === 0 || height === 0) {
        return err(badSource(sourcePath, `SOF 宽高必须非 0，实际 ${width}×${height}`));
      }
      if (components !== 1 && components !== 3 && components !== 4) {
        return err(
          engineError("IMPORT.UNSUPPORTED_SOURCE", `${sourcePath}: 不支持 ${components} 个分量的 JPEG`, {
            path: sourcePath,
            components,
          }),
        );
      }
      return ok({
        width,
        height,
        // 源精度，与 PNG 的 IHDR 位深同义（输出恒为 RGBA8，全精度走 pixels16）
        bitDepth: precision,
        // 分层文件报"分层"而不是参考帧的 SOF —— 只报 SOF1 会让元数据说"这是扩展顺序图"，
        // 而它其实是两帧合成的；同一条流里同时存在参考帧与差分帧两个不同的 SOF。
        // 这里能看到的只有先出现的**参考帧**（轻量扫头不跨熵数据，看不到末帧）。
        process: hier
          ? `分层（DHP + 差分帧，参考帧 ${SOF_NAMES[marker] ?? `SOF 0x${marker.toString(16)}`}）`
          : (SOF_NAMES[marker] ?? `SOF 0x${marker.toString(16)}`),
        colorType: components === 1 ? 0 : 2,
        hasAlpha: false,
        format: "jpeg",
        hierarchical: hier,
      });
    }
    pos += 2 + segLen;
  }
  return err(badSource(sourcePath, "JPEG 里没有找到 SOF 帧头（可能只有头、没有图像数据）"));
}

export const textureImporter: SourceImporter = {
  id: AssetType.Texture,
  version: VERSION,
  extensions: [".png", ".jpg", ".jpeg"],

  async import(sourcePath, source): Promise<Result<ImportedArtifact, EngineError>> {
    let header: Result<ImageHeader, EngineError>;
    if (source.length >= 3 && source[0] === 0xff && source[1] === 0xd8 && source[2] === 0xff) {
      header = readJpegHeader(sourcePath, source);
    } else {
      if (source.length < PNG_SIGNATURE.length) {
        return err(badSource(sourcePath, `期望 8 字节 PNG 签名或 JPEG SOI，实际只有 ${source.length} 字节`));
      }
      for (let i = 0; i < PNG_SIGNATURE.length; i++) {
        if (source[i] !== PNG_SIGNATURE[i]) {
          return err(
            badSource(
              sourcePath,
              `期望 8 字节 PNG 签名（89 50 4e 47 0d 0a 1a 0a）或 JPEG SOI（ff d8 ff），实际 ${hexBytes(source, 0, 8)}`,
            ),
          );
        }
      }
      header = readPngHeader(sourcePath, source);
    }
    if (!header.ok) return err(header.error);

    return ok({
      type: AssetType.Texture,
      dependencies: [],
      byteLength: source.byteLength,
      sourceHash: contentHash(source),
      importerVersion: VERSION,
      data: { ...header.value },
    });
  },
};
