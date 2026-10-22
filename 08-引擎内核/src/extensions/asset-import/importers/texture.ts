/**
 * L4 · 资产导入 · PNG 贴图
 *
 * ★ 只读 PNG **头**（签名 + IHDR），**不 inflate 像素**。
 *   边界很清楚：
 *     · 导入阶段要的是"宽高、位深、是否带 alpha" —— 这些全在 IHDR 里，
 *       而且编辑器缩略图/图集排版/内存预算只需要这些；
 *     · 真正解码成 RGBA 是 **gfx 加载器**的事（浏览器交给 `createImageBitmap`，
 *       原生端交给各自的解码器）。在导入器里塞一个 zlib/inflate，
 *       等于在引擎内核里再养一份解码器，还是同步阻塞的。
 *   所以这里**故意**不校验 CRC、不读 IDAT：一份 IDAT 损坏的 PNG 会在这里
 *   导入成功，在加载时失败。这是可接受的取舍 —— 报错点仍然明确（gfx.load）。
 *
 * ★ 其他图片格式（`.jpg`/`.webp`）没有导入器 → `IMPORT.NO_IMPORTER`。
 *   诚实地说"不支持"，比假装支持、然后在加载时崩要便宜。
 */

import { AssetType } from "../../../core/asset/asset.ts";
import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err, ok } from "../../../foundation/result.ts";
import type { ImportedArtifact, SourceImporter } from "../importer.ts";
import { contentHash } from "../hash.ts";

const VERSION = 1;

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] as const;

/** PNG 的签名 8 + 块头 8（长度 4 + 类型 4）+ IHDR 数据 13 + CRC 4。 */
const MIN_HEADER_BYTES = 33;
/** IHDR 数据区固定 13 字节。 */
const IHDR_DATA_BYTES = 13;

function u32be(b: Uint8Array, at: number): number {
  return (b[at]! * 0x1000000 + (b[at + 1]! << 16) + (b[at + 2]! << 8) + b[at + 3]!) >>> 0;
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
 * 调色板图（3）可以靠 tRNS 块声明透明色 —— 那需要继续扫块，超出"只读头"的边界；
 * 宁可在需要时按加载器结果为准，也不在这里猜。
 */
function hasAlphaChannel(colorType: number): boolean {
  return colorType === 4 || colorType === 6;
}

export const textureImporter: SourceImporter = {
  id: AssetType.Texture,
  version: VERSION,
  extensions: [".png"],

  async import(sourcePath, source): Promise<Result<ImportedArtifact, EngineError>> {
    if (source.length < SIGNATURE.length) {
      return err(badSource(sourcePath, `期望 8 字节 PNG 签名，实际只有 ${source.length} 字节`));
    }
    for (let i = 0; i < SIGNATURE.length; i++) {
      if (source[i] !== SIGNATURE[i]) {
        return err(
          badSource(
            sourcePath,
            `期望 8 字节 PNG 签名（89 50 4e 47 0d 0a 1a 0a），实际 ${hexBytes(source, 0, 8)}`,
          ),
        );
      }
    }
    if (source.length < MIN_HEADER_BYTES) {
      return err(
        badSource(
          sourcePath,
          `PNG 头截断：读 IHDR 需要 ${MIN_HEADER_BYTES} 字节（签名 8 + 块头 8 + IHDR 13 + CRC 4），实际 ${source.length}`,
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
    // 压缩/过滤/隔行方式也在 IHDR 里，但导入阶段完全不用它们做决策；
    // 记录只会让产物多出"没人读的字段"，所以不解析、不落盘。

    if (width === 0 || height === 0) {
      return err(badSource(sourcePath, `IHDR 宽高必须非 0，实际 ${width}×${height}`));
    }
    if (bitDepth === 0) {
      return err(badSource(sourcePath, "IHDR 位深为 0"));
    }

    return ok({
      type: AssetType.Texture,
      dependencies: [],
      byteLength: source.byteLength,
      sourceHash: contentHash(source),
      importerVersion: VERSION,
      data: {
        width,
        height,
        bitDepth,
        colorType,
        hasAlpha: hasAlphaChannel(colorType),
      },
    });
  },
};
