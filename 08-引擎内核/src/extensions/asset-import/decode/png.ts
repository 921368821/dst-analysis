/**
 * L4 · 资产导入 · 解码 · PNG → RGBA8
 *
 * ★★ 这是**导入期解码**，不是运行时解码。
 *   产出是一块 RGBA8（与 `AtlasData.pixels` / `TextureDesc.format = rgba8` 同格式），
 *   交给 `IGraphicsDevice.createTexture(desc, pixels)` 上传一次即可。
 *   浏览器若改用 `createImageBitmap(blob)` 原生解码，**那是另一条路径**：
 *   它与这里的颜色空间处理、alpha 是否预乘、16 位降采样的取整方式都可能不同，
 *   于是"headless 判据看到的像素"与"浏览器看到的像素"不再是一回事。
 *   两条路径**不应同时存在** —— 本文件存在的意义就是让两条链共用同一份解码结果。
 *   （代价：无法利用浏览器的 SIMD/多线程解码。导入期一次性成本，可接受。）
 *
 * ★ 为什么严格校验 CRC 并把块名写进错误：
 *   一个坏 PNG 在"只读头"的导入器里是能通过的（见 importers/texture.ts 的文件头）。
 *   到这里才真正读 IDAT，就必须给出"哪个块坏了、在哪个偏移" —— 否则
 *   在几千张图的工程里，报错等于没说。
 *
 * ★ 隔行（Adam7）**明确拒绝**，不尝试解码：
 *   工程内实测 0 个隔行 PNG，实现 Adam7 却没有真实语料验证，最可能的结局是
 *   "看起来支持、遇到就花屏"。宁可在导入期红，也不要上线后花屏。
 */

import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err, ok } from "../../../foundation/result.ts";
import { inflateZlib } from "./inflate.ts";

export const PngErrorCode = {
  BadPng: "ASSET.BAD_PNG",
  Unsupported: "ASSET.UNSUPPORTED_PNG",
  UnsupportedInterlace: "ASSET.UNSUPPORTED_INTERLACE",
} as const;

export interface DecodedPng {
  readonly width: number;
  readonly height: number;
  /** RGBA8 行主序，原点左上（与 AtlasData.pixels 同格式，可直接上传）。 */
  readonly pixels: Uint8Array;
  readonly bitDepth: number;
  readonly colorType: number;
  readonly hasAlpha: boolean;
  /** 是否用了 tRNS 透明色键。 */
  readonly usedTransparencyKey: boolean;
}

export interface DecodePngOptions {
  /**
   * 解压后**原始扫描线**字节上限，同时限制 RGBA8 输出大小。默认 256 MB。
   * 目的是在"IHDR 声明 6 万×6 万、IDAT 只有 20 字节"时立刻拒绝，
   * 而不是先分配几 GB 再失败。
   */
  readonly maxBytes?: number;
}

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] as const;
const DEFAULT_MAX_BYTES = 256 * 1024 * 1024;
const IHDR_BYTES = 13;

/** 各 colorType 的通道数（调色板按 1 个索引通道算）。 */
const CHANNELS: Readonly<Record<number, number>> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

/** 合法位深组合（PNG 规范表 11.1）。 */
const LEGAL_DEPTHS: Readonly<Record<number, readonly number[]>> = {
  0: [1, 2, 4, 8, 16],
  2: [8, 16],
  3: [1, 2, 4, 8],
  4: [8, 16],
  6: [8, 16],
};

// ------------------------------------------------------------------ CRC32

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(bytes: Uint8Array, from: number, to: number): number {
  let c = 0xffffffff;
  for (let i = from; i < to; i++) c = CRC_TABLE[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// ------------------------------------------------------------------ 小工具

function u32be(b: Uint8Array, at: number): number {
  return ((b[at]! << 24) | (b[at + 1]! << 16) | (b[at + 2]! << 8) | b[at + 3]!) >>> 0;
}

function ascii4(b: Uint8Array, at: number): string {
  return String.fromCharCode(b[at]!, b[at + 1]!, b[at + 2]!, b[at + 3]!);
}

function hex32(v: number): string {
  return `0x${v.toString(16).padStart(8, "0")}`;
}

function bad(why: string, detail?: Record<string, unknown>): EngineError {
  return detail === undefined
    ? engineError(PngErrorCode.BadPng, why)
    : engineError(PngErrorCode.BadPng, why, detail);
}

interface Chunk {
  readonly type: string;
  readonly start: number;
  readonly dataStart: number;
  readonly length: number;
}

/**
 * 走一遍块序列并做结构校验（签名、边界、CRC、IEND）。
 * 返回需要的块内容位置；**不复制** IDAT（大图会有几十个 IDAT）。
 */
function walkChunks(bytes: Uint8Array): Result<
  {
    readonly ihdr: Chunk;
    readonly palette: Chunk | undefined;
    readonly trns: Chunk | undefined;
    readonly idat: readonly Chunk[];
  },
  EngineError
> {
  if (bytes.length < SIGNATURE.length) {
    return err(bad(`文件过短：${bytes.length} 字节，连 PNG 签名都不够（8 字节）`));
  }
  for (let i = 0; i < SIGNATURE.length; i++) {
    if (bytes[i] !== SIGNATURE[i]) {
      return err(
        bad(
          `PNG 签名不匹配：期望 89 50 4e 47 0d 0a 1a 0a，实际 ${Array.from(bytes.subarray(0, 8), (x) =>
            x.toString(16).padStart(2, "0"),
          ).join(" ")}`,
        ),
      );
    }
  }

  let ihdr: Chunk | undefined;
  let palette: Chunk | undefined;
  let trns: Chunk | undefined;
  const idat: Chunk[] = [];
  let iendEnd = -1;
  let at = SIGNATURE.length;

  while (at < bytes.length) {
    if (at + 8 > bytes.length) {
      return err(bad(`块头截断：偏移 ${at} 处只剩 ${bytes.length - at} 字节（块头 8 字节）`));
    }
    const length = u32be(bytes, at);
    const type = ascii4(bytes, at + 4);
    if (length > 0x7fffffff) {
      return err(bad(`块 "${type}" 长度 ${length} 非法（> 2^31-1）`, { offset: at }));
    }
    const dataStart = at + 8;
    const crcAt = dataStart + length;
    if (crcAt + 4 > bytes.length) {
      return err(
        bad(
          `块 "${type}" 越界（截断）：偏移 ${at}，长度 ${length}，文件只剩 ${bytes.length - dataStart} 字节`,
          { chunk: type, offset: at },
        ),
      );
    }
    const expectedCrc = u32be(bytes, crcAt);
    const actualCrc = crc32(bytes, at + 4, crcAt); // 覆盖 type + data
    if (expectedCrc !== actualCrc) {
      return err(
        bad(
          `块 "${type}" CRC 校验失败：期望 ${hex32(expectedCrc)}，实际 ${hex32(actualCrc)}（偏移 ${at}）`,
          { chunk: type, offset: at },
        ),
      );
    }

    const chunk: Chunk = { type, start: at, dataStart, length };

    if (ihdr === undefined) {
      if (type !== "IHDR") {
        return err(bad(`第一个块必须是 IHDR，实际是 "${type}"`));
      }
      if (length !== IHDR_BYTES) {
        return err(bad(`IHDR 数据长度 ${length}（必须 13）`));
      }
      ihdr = chunk;
    } else if (type === "IHDR") {
      return err(bad("出现第二个 IHDR"));
    } else if (type === "PLTE") {
      if (palette !== undefined) return err(bad("出现第二个 PLTE"));
      if (idat.length > 0) return err(bad("PLTE 出现在 IDAT 之后（规范要求之前）"));
      if (length === 0 || length % 3 !== 0 || length > 768) {
        return err(bad(`PLTE 长度 ${length} 非法（应为 3 的倍数且 ≤768）`));
      }
      palette = chunk;
    } else if (type === "tRNS") {
      if (trns !== undefined) return err(bad("出现第二个 tRNS"));
      if (idat.length > 0) return err(bad("tRNS 出现在 IDAT 之后（规范要求之前）"));
      trns = chunk;
    } else if (type === "IDAT") {
      idat.push(chunk);
    } else if (type === "IEND") {
      if (length !== 0) return err(bad(`IEND 数据长度 ${length}（必须 0）`));
      iendEnd = crcAt + 4;
      break;
    } else if ((bytes[at + 4]! & 0x20) === 0) {
      // 块类型首字节大写 = critical；不认识的 critical 块必须拒绝（PNG 规范 §5.4）
      return err(
        engineError(
          PngErrorCode.Unsupported,
          `未知关键块 "${type}"（保留位必须为 0；本解码器不认识它，不能猜着跳过）`,
          { chunk: type, offset: at },
        ),
      );
    }

    at = crcAt + 4;
  }

  if (ihdr === undefined) return err(bad("没有 IHDR"));
  if (iendEnd < 0) {
    return err(bad("缺少 IEND（文件在最后一个块之后结束，可能被截断）"));
  }
  if (idat.length === 0) return err(bad("没有 IDAT：文件里没有任何图像数据"));
  // IEND 之后不允许有内容：多出来的字节要么是拼接坏了，要么是隐藏数据
  if (iendEnd !== bytes.length) {
    return err(bad(`IEND 之后还有 ${bytes.length - iendEnd} 字节数据（PNG 不允许尾部附加内容）`));
  }

  return ok({ ihdr, palette, trns, idat });
}

// ------------------------------------------------------------------ IHDR

interface Header {
  readonly width: number;
  readonly height: number;
  readonly bitDepth: number;
  readonly colorType: number;
  readonly interlace: number;
}

function readHeader(bytes: Uint8Array, c: Chunk): Result<Header, EngineError> {
  const width = u32be(bytes, c.dataStart);
  const height = u32be(bytes, c.dataStart + 4);
  const bitDepth = bytes[c.dataStart + 8]!;
  const colorType = bytes[c.dataStart + 9]!;
  const compression = bytes[c.dataStart + 10]!;
  const filter = bytes[c.dataStart + 11]!;
  const interlace = bytes[c.dataStart + 12]!;

  if (width === 0 || height === 0) return err(bad(`IHDR 宽高必须非 0，实际 ${width}×${height}`));
  if (compression !== 0) return err(bad(`IHDR compression=${compression}（只支持 0）`));
  if (filter !== 0) return err(bad(`IHDR filter method=${filter}（只支持 0）`));
  if (interlace !== 0 && interlace !== 1) {
    return err(bad(`IHDR interlace=${interlace} 非法（只允许 0/1）`));
  }
  return ok({ width, height, bitDepth, colorType, interlace });
}

// ------------------------------------------------------------------ 反滤波

function paeth(a: number, b: number, c: number): number {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/**
 * 5 种滤波的逆运算（PNG 规范 §9）。
 * `bpp` 是**像素**的字节数（不足 1 字节的位深按 1 算）——
 * 用"通道数 × 位深 / 8"算，而不是固定 4：
 * 灰度图用 4 会让 Sub/Paeth 读到错位的左邻像素，看起来像"图像向右拖影"。
 */
function unfilter(raw: Uint8Array, stride: number, height: number, bpp: number): Result<Uint8Array, EngineError> {
  const out = new Uint8Array(stride * height);
  for (let y = 0; y < height; y++) {
    const rowStart = y * (stride + 1);
    const ft = raw[rowStart]!;
    const src = rowStart + 1;
    const dst = y * stride;
    if (ft === 0) {
      out.set(raw.subarray(src, src + stride), dst);
      continue;
    }
    if (ft > 4) return err(bad(`第 ${y} 行的滤波类型 ${ft} 非法（只允许 0..4）`));
    for (let x = 0; x < stride; x++) {
      const cur = raw[src + x]!;
      const left = x >= bpp ? out[dst + x - bpp]! : 0;
      const up = y > 0 ? out[dst - stride + x]! : 0;
      const upLeft = y > 0 && x >= bpp ? out[dst - stride + x - bpp]! : 0;
      let v: number;
      switch (ft) {
        case 1:
          v = cur + left;
          break;
        case 2:
          v = cur + up;
          break;
        case 3:
          v = cur + ((left + up) >> 1);
          break;
        default:
          v = cur + paeth(left, up, upLeft);
          break;
      }
      out[dst + x] = v & 0xff;
    }
  }
  return ok(out);
}

// ------------------------------------------------------------------ 样本 → RGBA

function sampleU16(row: Uint8Array, byteIndex: number): number {
  return (row[byteIndex]! << 8) | row[byteIndex + 1]!;
}

/** 把 sub-byte 的灰度/索引样本展开成 0..max 的整数。 */
function subByteSample(row: Uint8Array, x: number, bitDepth: number): number {
  const perByte = 8 / bitDepth;
  const byte = row[Math.floor(x / perByte)]!;
  const shift = 8 - bitDepth * ((x % perByte) + 1);
  return (byte >> shift) & ((1 << bitDepth) - 1);
}

function toRgba(
  raw: Uint8Array,
  stride: number,
  h: Header,
  palette: Uint8Array | undefined,
  trns: Uint8Array | undefined,
): Result<{ pixels: Uint8Array; usedTransparencyKey: boolean; paletteAlpha: boolean }, EngineError> {
  const { width, height, colorType, bitDepth } = h;
  const out = new Uint8Array(width * height * 4);
  const maxV = (1 << bitDepth) - 1;
  const scale = (v: number): number => Math.round((v * 255) / maxV);

  // tRNS 的三种含义，先解析成"语义"，避免在像素循环里反复判断长度
  let trnsGray = -1;
  let trnsR = -1;
  let trnsG = -1;
  let trnsB = -1;
  if (trns !== undefined) {
    if (colorType === 0) {
      if (trns.length !== 2) return err(bad(`灰度图的 tRNS 长度必须是 2，实际 ${trns.length}`));
      trnsGray = (trns[0]! << 8) | trns[1]!;
    } else if (colorType === 2) {
      if (trns.length !== 6) return err(bad(`RGB 图的 tRNS 长度必须是 6，实际 ${trns.length}`));
      trnsR = (trns[0]! << 8) | trns[1]!;
      trnsG = (trns[2]! << 8) | trns[3]!;
      trnsB = (trns[4]! << 8) | trns[5]!;
    } else if (colorType !== 3) {
      return err(bad(`colorType=${colorType} 不允许 tRNS（该类型自带 alpha 通道）`));
    }
  }

  let paletteAlpha = false;
  for (let y = 0; y < height; y++) {
    const row = raw.subarray(y * stride, (y + 1) * stride);
    let o = y * width * 4;
    for (let x = 0; x < width; x++, o += 4) {
      if (colorType === 0) {
        let v: number;
        let alpha = 255;
        if (bitDepth === 16) {
          v = sampleU16(row, x * 2);
          out[o] = out[o + 1] = out[o + 2] = (v >> 8) & 0xff; // 16→8：取高字节
          if (v === trnsGray) alpha = 0;
        } else if (bitDepth === 8) {
          v = row[x]!;
          out[o] = out[o + 1] = out[o + 2] = v;
          if (v === trnsGray) alpha = 0;
        } else {
          v = subByteSample(row, x, bitDepth);
          const g = scale(v);
          out[o] = out[o + 1] = out[o + 2] = g;
          if (v === trnsGray) alpha = 0;
        }
        out[o + 3] = alpha;
      } else if (colorType === 2) {
        let r: number;
        let g: number;
        let b: number;
        if (bitDepth === 16) {
          const rv = sampleU16(row, x * 6);
          const gv = sampleU16(row, x * 6 + 2);
          const bv = sampleU16(row, x * 6 + 4);
          r = rv >> 8;
          g = gv >> 8;
          b = bv >> 8;
          out[o] = r;
          out[o + 1] = g;
          out[o + 2] = b;
          out[o + 3] = rv === trnsR && gv === trnsG && bv === trnsB ? 0 : 255;
        } else {
          r = row[x * 3]!;
          g = row[x * 3 + 1]!;
          b = row[x * 3 + 2]!;
          out[o] = r;
          out[o + 1] = g;
          out[o + 2] = b;
          out[o + 3] = r === trnsR && g === trnsG && b === trnsB ? 0 : 255;
        }
      } else if (colorType === 3) {
        if (palette === undefined) return err(bad("colorType=3 但缺少 PLTE"));
        const idx = bitDepth === 8 ? row[x]! : subByteSample(row, x, bitDepth);
        const entries = palette.length / 3;
        if (idx >= entries) {
          return err(
            bad(`调色板索引越界：第 (${x},${y}) 像素索引 ${idx}，PLTE 只有 ${entries} 项`, { x, y, index: idx }),
          );
        }
        out[o] = palette[idx * 3]!;
        out[o + 1] = palette[idx * 3 + 1]!;
        out[o + 2] = palette[idx * 3 + 2]!;
        if (trns !== undefined && idx < trns.length) {
          out[o + 3] = trns[idx]!;
          if (trns[idx]! < 255) paletteAlpha = true;
        } else {
          out[o + 3] = 255;
        }
      } else if (colorType === 4) {
        if (bitDepth === 16) {
          const v = sampleU16(row, x * 4);
          out[o] = out[o + 1] = out[o + 2] = v >> 8;
          out[o + 3] = sampleU16(row, x * 4 + 2) >> 8;
        } else {
          const v = row[x * 2]!;
          out[o] = out[o + 1] = out[o + 2] = v;
          out[o + 3] = row[x * 2 + 1]!;
        }
      } else {
        // colorType 6
        if (bitDepth === 16) {
          for (let k = 0; k < 4; k++) out[o + k] = row[x * 8 + k * 2]!; // 取高字节
        } else {
          out[o] = row[x * 4]!;
          out[o + 1] = row[x * 4 + 1]!;
          out[o + 2] = row[x * 4 + 2]!;
          out[o + 3] = row[x * 4 + 3]!;
        }
      }
    }
  }

  return ok({
    pixels: out,
    usedTransparencyKey: (colorType === 0 && trnsGray >= 0) || (colorType === 2 && trnsR >= 0),
    paletteAlpha,
  });
}

// ------------------------------------------------------------------ 入口

/**
 * 解码一张 PNG 成 RGBA8。
 *
 * 支持：colorType 0/2/3/4/6；bitDepth 1/2/4（仅 0、3）、8、16（取高字节降采样）。
 * 拒绝：Adam7 隔行（`ASSET.UNSUPPORTED_INTERLACE`）、未知 colorType/位深
 * （`ASSET.UNSUPPORTED_PNG`）、任何结构/CRC/zlib 问题（`ASSET.BAD_PNG`）。
 */
export function decodePng(bytes: Uint8Array, opts?: DecodePngOptions): Result<DecodedPng, EngineError> {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_BYTES;
  const walked = walkChunks(bytes);
  if (!walked.ok) return err(walked.error);
  const { ihdr, palette, trns, idat } = walked.value;

  const hdr = readHeader(bytes, ihdr);
  if (!hdr.ok) return err(hdr.error);
  const h = hdr.value;

  if (h.interlace !== 0) {
    return err(
      engineError(
        PngErrorCode.UnsupportedInterlace,
        `PNG 使用了 Adam7 隔行（interlace=${h.interlace}）—— 本解码器明确不支持。` +
          `工程内语料为 0 个隔行图；未经验证的隔行实现会导致花屏，所以这里直接报错而不是猜。`,
        { width: h.width, height: h.height },
      ),
    );
  }

  const channels = CHANNELS[h.colorType];
  if (channels === undefined) {
    return err(
      engineError(
        PngErrorCode.Unsupported,
        `未知 colorType=${h.colorType}（允许 0/2/3/4/6；7 及保留值一律拒绝）`,
        { colorType: h.colorType },
      ),
    );
  }
  const legal = LEGAL_DEPTHS[h.colorType]!;
  if (!legal.includes(h.bitDepth)) {
    return err(
      engineError(
        PngErrorCode.Unsupported,
        `不支持的 colorType/bitDepth 组合：colorType=${h.colorType} bitDepth=${h.bitDepth}` +
          `（该 colorType 允许 ${legal.join("/")}）`,
        { colorType: h.colorType, bitDepth: h.bitDepth },
      ),
    );
  }
  if (h.colorType === 3 && palette === undefined) {
    return err(bad("colorType=3（调色板）但文件里没有 PLTE 块"));
  }

  const bitsPerPixel = channels * h.bitDepth;
  const stride = Math.ceil((h.width * bitsPerPixel) / 8);
  const bpp = Math.max(1, Math.ceil(bitsPerPixel / 8));
  const rowBytes = stride + 1;

  // ---- 尺寸上限先于任何分配：别让"声明 6 万×6 万"的坏文件把进程打死 ----
  if (h.height > 0 && h.width > Math.floor(maxBytes / 4 / h.height)) {
    return err(
      bad(
        `PNG 尺寸 ${h.width}×${h.height} 的 RGBA8 像素数超过 maxBytes=${maxBytes} 的上限（解压炸弹保护）`,
        { width: h.width, height: h.height, maxBytes },
      ),
    );
  }
  if (h.height > 0 && h.width > Math.floor(maxBytes / rowBytes)) {
    return err(
      bad(
        `PNG ${h.width}×${h.height} 的解压后扫描线约 ${rowBytes * h.height} 字节，超过 maxBytes=${maxBytes}`,
        { width: h.width, height: h.height, maxBytes },
      ),
    );
  }
  const expectedRaw = rowBytes * h.height;

  // ---- 拼接 IDAT 并解压 ----
  const compressed = new Uint8Array(idat.reduce((n, c) => n + c.length, 0));
  {
    let o = 0;
    for (const c of idat) {
      compressed.set(bytes.subarray(c.dataStart, c.dataStart + c.length), o);
      o += c.length;
    }
  }
  const inflated = inflateZlib(compressed, { maxBytes: expectedRaw, sizeHint: expectedRaw });
  if (!inflated.ok) {
    return err(
      engineError(
        PngErrorCode.BadPng,
        `IDAT 解压失败（${idat.length} 个块，共 ${compressed.length} 字节解压出，期望 ${expectedRaw}）：${inflated.error.message}`,
        { idatChunks: idat.length },
      ),
    );
  }
  const raw = inflated.value;
  if (raw.length !== expectedRaw) {
    return err(
      bad(
        `扫描线数据长度不对：期望 ${expectedRaw}（${h.height} 行 × (1 滤波字节 + ${stride})），实际 ${raw.length}。` +
          `IDAT 被截断或 IHDR 与实际数据不符 —— 拒绝返回半张图。`,
        { expectedRaw, actual: raw.length },
      ),
    );
  }

  // ---- 反滤波 ----
  const unfiltered = unfilter(raw, stride, h.height, bpp);
  if (!unfiltered.ok) return err(unfiltered.error);

  const paletteBytes =
    palette === undefined ? undefined : bytes.subarray(palette.dataStart, palette.dataStart + palette.length);
  const trnsBytes = trns === undefined ? undefined : bytes.subarray(trns.dataStart, trns.dataStart + trns.length);

  const rgba = toRgba(unfiltered.value, stride, h, paletteBytes, trnsBytes);
  if (!rgba.ok) return err(rgba.error);

  const hasChannelAlpha = h.colorType === 4 || h.colorType === 6;
  return ok({
    width: h.width,
    height: h.height,
    pixels: rgba.value.pixels,
    bitDepth: h.bitDepth,
    colorType: h.colorType,
    hasAlpha: hasChannelAlpha || rgba.value.usedTransparencyKey || rgba.value.paletteAlpha,
    usedTransparencyKey: rgba.value.usedTransparencyKey,
  });
}
