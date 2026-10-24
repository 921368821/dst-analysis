/**
 * L4 · 资产导入 · 解码 · PNG → RGBA8（可选 RGBA16）
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
 * ★ Adam7 隔行：**已实现**（2026-10-22）。
 *   工程内语料 3284 张全部非隔行 —— 也就是说"实现完就能被真实语料验证"这条路不存在。
 *   于是正确性靠两条正交判据（见 tests/extensions/png-adam7.test.ts）：
 *     ① 同一逻辑图像的非隔行 / 隔行编码必须解出**逐字节相同**的 RGBA；
 *     ② 我们编出的隔行文件交给**两个独立实现**（pngjs 7 / Pillow 13）解码，
 *        三者结果必须一致 —— 这一条破掉了"编码器和解码器犯同一个错"的自证循环。
 *   实测的 pass 布局、每 pass 独立反滤波、sub-byte 位深按 pass 重新打包，
 *   都在 `planPasses` + `decodeZlibImage` 里，没有"隔行专用"的第二套像素转换。
 *
 * ★ 16 位色深：**不丢弃精度，但也不假装 GPU 能吃**。
 *   · 默认：按 `round(v / 257)` 降到 RGBA8（与 pngjs 的 `round(v*255/65535)` 同口径；
 *     旧实现取高字节 = floor，最坏偏暗 1 级，已改）；
 *   · `keep16: true`：额外产出 `pixels16`（RGBA16，通道展开规则与 8 位完全一致），
 *     恒满足 `pixels[i] === round(pixels16[i] / 257)` —— 这条自一致判据钉住两条路径不漂移。
 *   · 边界：`TextureDesc` 目前只有 rgba8，16 位不进 GPU。要进 GPU 得先有 rgba16 格式，
 *     那是渲染管线的事，不能靠"解码器偷偷降采样"混过去。
 */

import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err, ok } from "../../../foundation/result.ts";
import { inflateZlib } from "./inflate.ts";

export const PngErrorCode = {
  BadPng: "ASSET.BAD_PNG",
  BadApng: "ASSET.BAD_APNG",
  Unsupported: "ASSET.UNSUPPORTED_PNG",
  /** 仅在 `interlace: "reject"` 时出现：解码器有能力，但调用方显式关掉了。 */
  UnsupportedInterlace: "ASSET.UNSUPPORTED_INTERLACE",
  /** 仅在 `apng: "reject"` 时出现。 */
  UnsupportedAnimation: "ASSET.UNSUPPORTED_ANIMATION",
} as const;

/** APNG 的 `acTL` 元信息（不解帧，只报告"这是动图、有几帧、循环几次"）。 */
export interface PngAnimationInfo {
  /** acTL.num_frames。 */
  readonly frameCount: number;
  /** acTL.num_plays；0 = 无限循环。 */
  readonly loopCount: number;
}

export interface DecodedPng {
  readonly width: number;
  readonly height: number;
  /** RGBA8 行主序，原点左上（与 AtlasData.pixels 同格式，可直接上传）。 */
  readonly pixels: Uint8Array;
  /**
   * `keep16: true` 时给全精度 RGBA16（原点左上、通道展开规则同 `pixels`）。
   * 8 位源图在这里是 `v * 257`，所以任何位深都恒有 `pixels[i] === round(pixels16[i]/257)`。
   */
  readonly pixels16?: Uint16Array;
  readonly bitDepth: number;
  readonly colorType: number;
  readonly hasAlpha: boolean;
  /** 是否用了 tRNS 透明色键。 */
  readonly usedTransparencyKey: boolean;
  /** 文件用了 Adam7 隔行（已解码，不是"拒绝"）。 */
  readonly interlaced: boolean;
  /** 文件带 acTL 块（动图）。像素是默认帧/首帧；要全部帧请用 `decodeApng`。 */
  readonly isApng: boolean;
  /** APNG 元信息，仅 `isApng === true` 时存在。 */
  readonly animation?: PngAnimationInfo;
}

export interface DecodePngOptions {
  /**
   * 解压后**原始扫描线**字节上限，同时限制 RGBA8 输出大小。默认 256 MB。
   * 目的是在"IHDR 声明 6 万×6 万、IDAT 只有 20 字节"时立刻拒绝，
   * 而不是先分配几 GB 再失败。
   */
  readonly maxBytes?: number;
  /** 额外产出全精度 RGBA16（`pixels16`）。默认 false（省一半内存）。 */
  readonly keep16?: boolean;
  /** `"reject"`：遇到 Adam7 直接报 `ASSET.UNSUPPORTED_INTERLACE`，不给像素。 */
  readonly interlace?: "decode" | "reject";
  /** `"reject"`：遇到 APNG 直接报 `ASSET.UNSUPPORTED_ANIMATION`。默认 `"first-frame"`。 */
  readonly apng?: "first-frame" | "reject";
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

/**
 * Adam7 的七个 pass（PNG 规范 §8.2）。
 * 每个 pass 是整幅图上的一个**子网格**：从 (xStart, yStart) 起，横竖各隔 xStep/yStep 取一个像素。
 * 这七组常量是规范原文，不是"我们的约定" —— 独立实现（pngjs `lib/interlace.js`）
 * 用"坐标列表"的等价形式写了同一张表，可逐项对照。
 */
const ADAM7_PASSES = [
  { xStart: 0, yStart: 0, xStep: 8, yStep: 8 },
  { xStart: 4, yStart: 0, xStep: 8, yStep: 8 },
  { xStart: 0, yStart: 4, xStep: 4, yStep: 8 },
  { xStart: 2, yStart: 0, xStep: 4, yStep: 4 },
  { xStart: 0, yStart: 2, xStep: 2, yStep: 4 },
  { xStart: 1, yStart: 0, xStep: 2, yStep: 2 },
  { xStart: 0, yStart: 1, xStep: 1, yStep: 2 },
] as const;

/** 非隔行 = 单个 pass，步长 1。这样像素转换代码只有一条路径。 */
const SINGLE_PASS = [{ xStart: 0, yStart: 0, xStep: 1, yStep: 1 }] as const;

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

export interface PngChunk {
  readonly type: string;
  readonly start: number;
  readonly dataStart: number;
  readonly length: number;
}

export interface Header {
  readonly width: number;
  readonly height: number;
  readonly bitDepth: number;
  readonly colorType: number;
  readonly interlace: number;
}

export interface PngChunkScan {
  readonly header: Header;
  readonly ihdr: PngChunk;
  readonly palette: PngChunk | undefined;
  readonly trns: PngChunk | undefined;
  readonly idat: readonly PngChunk[];
  /** 全部块（按文件顺序），APNG 需要 fcTL/fdAT 的顺序与位置。 */
  readonly chunks: readonly PngChunk[];
}

/**
 * 走一遍块序列并做结构校验（签名、边界、CRC、IEND）。
 * **不复制** IDAT（大图会有几十个 IDAT）。
 *
 * 对未知的 ancillary 块（首字母小写，如 APNG 的 acTL/fcTL/fdAT、gAMA、iCCP）
 * 一律跳过 —— PNG 规范就是这样规定的，它们不影响像素重建。
 * 未知的 critical 块必须拒绝：跳过一个"必需"块等于猜。
 */
export function scanPng(bytes: Uint8Array): Result<PngChunkScan, EngineError> {
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

  let ihdr: PngChunk | undefined;
  let palette: PngChunk | undefined;
  let trns: PngChunk | undefined;
  const idat: PngChunk[] = [];
  const chunks: PngChunk[] = [];
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

    const chunk: PngChunk = { type, start: at, dataStart, length };

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
      chunks.push(chunk);
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

    chunks.push(chunk);
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

  const header = readHeader(bytes, ihdr);
  if (!header.ok) return err(header.error);

  return ok({ header: header.value, ihdr, palette, trns, idat, chunks });
}

// ------------------------------------------------------------------ IHDR

function readHeader(bytes: Uint8Array, c: PngChunk): Result<Header, EngineError> {
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

/** 校验 colorType/bitDepth 组合，并把 PLTE 缺失提前到分配之前。 */
function validateFormat(header: Header, palette: PngChunk | undefined): Result<number, EngineError> {
  const channels = CHANNELS[header.colorType];
  if (channels === undefined) {
    return err(
      engineError(
        PngErrorCode.Unsupported,
        `未知 colorType=${header.colorType}（允许 0/2/3/4/6；7 及保留值一律拒绝）`,
        { colorType: header.colorType },
      ),
    );
  }
  const legal = LEGAL_DEPTHS[header.colorType]!;
  if (!legal.includes(header.bitDepth)) {
    return err(
      engineError(
        PngErrorCode.Unsupported,
        `不支持的 colorType/bitDepth 组合：colorType=${header.colorType} bitDepth=${header.bitDepth}` +
          `（该 colorType 允许 ${legal.join("/")}）`,
        { colorType: header.colorType, bitDepth: header.bitDepth },
      ),
    );
  }
  if (header.colorType === 3 && palette === undefined) {
    return err(bad("colorType=3（调色板）但文件里没有 PLTE 块"));
  }
  return ok(channels);
}

// ------------------------------------------------------------------ pass 布局

interface PassLayout {
  readonly xStart: number;
  readonly yStart: number;
  readonly xStep: number;
  readonly yStep: number;
  readonly width: number;
  readonly height: number;
  readonly stride: number;
}

/**
 * 按 pass 网格算出每个 pass 的子图尺寸与行字节数。
 *
 * ★ 关键点：**sub-byte 位深在每个 pass 内重新打包**。
 *   4 位灰度图在整幅图上"两个像素挤一个字节"，但 pass 2 宽度可能是 1 ——
 *   它的行是 1 字节里只有高 4 位有效。任何"先整幅解包再取子网格"的做法都会错位。
 *   `stride = ceil(passWidth * bitsPerPixel / 8)` 是唯一正确的算法。
 *
 * ★ 宽度或高度为 0 的 pass **完全不存在**（不占扫描线字节）。漏掉这条会在
 *   小图上少读/多读整整一个 pass 的数据，报"长度不对"。
 */
function planPasses(width: number, height: number, bitsPerPixel: number, interlace: number): readonly PassLayout[] {
  const defs = interlace === 1 ? ADAM7_PASSES : SINGLE_PASS;
  const out: PassLayout[] = [];
  for (const d of defs) {
    const w = width > d.xStart ? Math.ceil((width - d.xStart) / d.xStep) : 0;
    const h = height > d.yStart ? Math.ceil((height - d.yStart) / d.yStep) : 0;
    if (w === 0 || h === 0) continue;
    out.push({ ...d, width: w, height: h, stride: Math.ceil((w * bitsPerPixel) / 8) });
  }
  return out;
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
 * 5 种滤波的逆运算（PNG 规范 §9）。作用范围是**一个 pass**。
 * `bpp` 是**像素**的字节数（不足 1 字节的位深按 1 算）——
 * 用"通道数 × 位深 / 8"算，而不是固定 4：
 * 灰度图用 4 会让 Sub/Paeth 读到错位的左邻像素，看起来像"图像向右拖影"。
 *
 * ★ 隔行的每个 pass 是**独立**的：第一行没有 up 邻居（即使整图上它上面有像素）。
 *   把 pass 之间连起来反滤波，是 Adam7 最经典的错法 —— 画面会出现整片斜纹。
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

/** 把 sub-byte 的灰度/索引样本展开成 0..max 的整数（`x` 是 pass 内的像素下标）。 */
function subByteSample(row: Uint8Array, x: number, bitDepth: number): number {
  const perByte = 8 / bitDepth;
  const byte = row[Math.floor(x / perByte)]!;
  const shift = 8 - bitDepth * ((x % perByte) + 1);
  return (byte >> shift) & ((1 << bitDepth) - 1);
}

/** 16 位 → 8 位：`round(v/257)`。与 pngjs 的 `round(v*255/65535)` 同口径。 */
function narrow16(v: number): number {
  return Math.round(v / 257);
}

interface PassWithPixels extends PassLayout {
  /** 已反滤波的 pass 扫描线（无滤波字节）。 */
  readonly raw: Uint8Array;
}

interface WriteCtx {
  readonly out: Uint8Array;
  readonly out16: Uint16Array | undefined;
  readonly imageWidth: number;
}

/** 往整幅图的 (x,y) 写一个像素；`o` 是 RGBA 线性下标，等于 `(y*W+x)*4`。 */
function put(
  ctx: WriteCtx,
  o: number,
  r: number,
  g: number,
  b: number,
  a: number,
  r16: number,
  g16: number,
  b16: number,
  a16: number,
): void {
  ctx.out[o] = r;
  ctx.out[o + 1] = g;
  ctx.out[o + 2] = b;
  ctx.out[o + 3] = a;
  if (ctx.out16 !== undefined) {
    ctx.out16[o] = r16;
    ctx.out16[o + 1] = g16;
    ctx.out16[o + 2] = b16;
    ctx.out16[o + 3] = a16;
  }
}

/** colorType 0：灰度（1/2/4/8/16 位），可带 tRNS 色键。 */
function writeGray(
  ctx: WriteCtx,
  passes: readonly PassWithPixels[],
  bitDepth: number,
  trnsGray: number,
): void {
  const maxV = (1 << bitDepth) - 1;
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const o = (y * ctx.imageWidth + x) * 4;
        let v: number;
        if (bitDepth === 16) v = sampleU16(row, px * 2);
        else if (bitDepth === 8) v = row[px]!;
        else v = subByteSample(row, px, bitDepth);

        const a = v === trnsGray ? 0 : 255;
        if (bitDepth === 16) {
          put(ctx, o, narrow16(v), narrow16(v), narrow16(v), a, v, v, v, a === 0 ? 0 : 0xffff);
        } else {
          const g = bitDepth === 8 ? v : Math.round((v * 255) / maxV);
          const g16 = bitDepth === 8 ? v * 257 : Math.round((v * 65535) / maxV);
          put(ctx, o, g, g, g, a, g16, g16, g16, a === 0 ? 0 : 0xffff);
        }
      }
    }
  }
}

/** colorType 2：真彩（8/16 位），可带 tRNS 色键（三个通道同时相等才算透明）。 */
function writeRgb(
  ctx: WriteCtx,
  passes: readonly PassWithPixels[],
  bitDepth: number,
  trnsR: number,
  trnsG: number,
  trnsB: number,
): void {
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const o = (y * ctx.imageWidth + x) * 4;
        let r: number;
        let g: number;
        let b: number;
        let r16: number;
        let g16: number;
        let b16: number;
        if (bitDepth === 16) {
          r16 = sampleU16(row, px * 6);
          g16 = sampleU16(row, px * 6 + 2);
          b16 = sampleU16(row, px * 6 + 4);
          r = narrow16(r16);
          g = narrow16(g16);
          b = narrow16(b16);
        } else {
          r = r16 = row[px * 3]!;
          g = g16 = row[px * 3 + 1]!;
          b = b16 = row[px * 3 + 2]!;
          r16 *= 257;
          g16 *= 257;
          b16 *= 257;
        }
        const keyed = bitDepth === 16 ? r16 === trnsR && g16 === trnsG && b16 === trnsB : r === trnsR && g === trnsG && b === trnsB;
        put(ctx, o, r, g, b, keyed ? 0 : 255, r16, g16, b16, keyed ? 0 : 0xffff);
      }
    }
  }
}

/** colorType 3：调色板（1/2/4/8 位索引）+ 逐项 alpha（tRNS）。 */
function writePalette(
  ctx: WriteCtx,
  passes: readonly PassWithPixels[],
  bitDepth: number,
  palette: Uint8Array,
  trns: Uint8Array | undefined,
  state: { paletteAlpha: boolean },
): Result<void, EngineError> {
  const entries = palette.length / 3;
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const idx = bitDepth === 8 ? row[px]! : subByteSample(row, px, bitDepth);
        if (idx >= entries) {
          return err(
            bad(`调色板索引越界：第 (${x},${y}) 像素索引 ${idx}，PLTE 只有 ${entries} 项`, { x, y, index: idx }),
          );
        }
        const o = (y * ctx.imageWidth + x) * 4;
        const r = palette[idx * 3]!;
        const g = palette[idx * 3 + 1]!;
        const b = palette[idx * 3 + 2]!;
        const a = trns !== undefined && idx < trns.length ? trns[idx]! : 255;
        if (a < 255) state.paletteAlpha = true;
        put(ctx, o, r, g, b, a, r * 257, g * 257, b * 257, a * 257);
      }
    }
  }
  return ok(undefined);
}

/** colorType 4：灰度 + alpha。 */
function writeGrayAlpha(ctx: WriteCtx, passes: readonly PassWithPixels[], bitDepth: number): void {
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const o = (y * ctx.imageWidth + x) * 4;
        if (bitDepth === 16) {
          const v = sampleU16(row, px * 4);
          const a = sampleU16(row, px * 4 + 2);
          const g = narrow16(v);
          put(ctx, o, g, g, g, narrow16(a), v, v, v, a);
        } else {
          const v = row[px * 2]!;
          const a = row[px * 2 + 1]!;
          put(ctx, o, v, v, v, a, v * 257, v * 257, v * 257, a * 257);
        }
      }
    }
  }
}

/** colorType 6：RGBA。 */
function writeRgba(ctx: WriteCtx, passes: readonly PassWithPixels[], bitDepth: number): void {
  for (const p of passes) {
    for (let py = 0; py < p.height; py++) {
      const row = p.raw.subarray(py * p.stride, (py + 1) * p.stride);
      const y = p.yStart + py * p.yStep;
      for (let px = 0; px < p.width; px++) {
        const x = p.xStart + px * p.xStep;
        const o = (y * ctx.imageWidth + x) * 4;
        if (bitDepth === 16) {
          const r = sampleU16(row, px * 8);
          const g = sampleU16(row, px * 8 + 2);
          const b = sampleU16(row, px * 8 + 4);
          const a = sampleU16(row, px * 8 + 6);
          put(ctx, o, narrow16(r), narrow16(g), narrow16(b), narrow16(a), r, g, b, a);
        } else {
          const r = row[px * 4]!;
          const g = row[px * 4 + 1]!;
          const b = row[px * 4 + 2]!;
          const a = row[px * 4 + 3]!;
          put(ctx, o, r, g, b, a, r * 257, g * 257, b * 257, a * 257);
        }
      }
    }
  }
}

interface RgbaResult {
  readonly pixels: Uint8Array;
  readonly pixels16: Uint16Array | undefined;
  readonly usedTransparencyKey: boolean;
  /** 调色板 tRNS 里有 < 255 的项（与"色键透明"是两件事，但都算 hasAlpha）。 */
  readonly paletteAlpha: boolean;
}

function toRgba(
  passes: readonly PassWithPixels[],
  header: Header,
  palette: Uint8Array | undefined,
  trns: Uint8Array | undefined,
  keep16: boolean,
): Result<RgbaResult, EngineError> {
  const { width, height, colorType, bitDepth } = header;
  const pixels = new Uint8Array(width * height * 4);
  const pixels16 = keep16 ? new Uint16Array(width * height * 4) : undefined;
  const ctx: WriteCtx = { out: pixels, out16: pixels16, imageWidth: width };

  // tRNS 的三种含义，先解析成"语义"，避免在像素循环里反复判断长度
  const state = { paletteAlpha: false };
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

  switch (colorType) {
    case 0:
      writeGray(ctx, passes, bitDepth, trnsGray);
      break;
    case 2:
      writeRgb(ctx, passes, bitDepth, trnsR, trnsG, trnsB);
      break;
    case 3: {
      const r = writePalette(ctx, passes, bitDepth, palette!, trns, state);
      if (!r.ok) return err(r.error);
      break;
    }
    case 4:
      writeGrayAlpha(ctx, passes, bitDepth);
      break;
    default:
      writeRgba(ctx, passes, bitDepth);
      break;
  }

  return ok({
    pixels,
    pixels16,
    usedTransparencyKey: (colorType === 0 && trnsGray >= 0) || (colorType === 2 && trnsR >= 0),
    paletteAlpha: state.paletteAlpha,
  });
}

/**
 * 内部：把一段 zlib 数据按给定宽高解成 RGBA。
 * 供 `decodePng`（整幅）与 APNG 帧解码（帧矩形）共用 —— 帧的 Adam7 是按帧矩形算的，
 * 不是按画布算的（APNG 规范：帧数据独立按自己的 width/height 做扫描线布局）。
 */
export function decodeZlibImage(
  compressed: Uint8Array,
  header: Header,
  width: number,
  height: number,
  palette: Uint8Array | undefined,
  trns: Uint8Array | undefined,
  opts: { keep16?: boolean; maxBytes?: number; label?: string } = {},
): Result<RgbaResult & { bitDepth: number; colorType: number }, EngineError> {
  const channels = CHANNELS[header.colorType];
  if (channels === undefined) {
    return err(
      engineError(PngErrorCode.Unsupported, `未知 colorType=${header.colorType}`, { colorType: header.colorType }),
    );
  }
  const bitsPerPixel = channels * header.bitDepth;
  const bpp = Math.max(1, Math.ceil(bitsPerPixel / 8));
  const passes = planPasses(width, height, bitsPerPixel, header.interlace);
  const rawBytes = passes.reduce((n, p) => n + (p.stride + 1) * p.height, 0);
  const label = opts.label ?? "PNG";
  const maxBytes = opts.maxBytes ?? DEFAULT_MAX_BYTES;

  if (rawBytes > maxBytes) {
    return err(
      bad(
        `${label} 的扫描线约 ${rawBytes} 字节，超过 maxBytes=${maxBytes}（解压炸弹保护）`,
        { width, height, rawBytes, maxBytes },
      ),
    );
  }
  const inflated = inflateZlib(compressed, { maxBytes: rawBytes, sizeHint: rawBytes });
  if (!inflated.ok) {
    return err(
      engineError(
        PngErrorCode.BadPng,
        `${label} 解压失败（${compressed.length} 字节压缩数据，期望 ${rawBytes}）：${inflated.error.message}`,
      ),
    );
  }
  const raw = inflated.value;
  if (raw.length !== rawBytes) {
    return err(
      bad(
        `${label} 扫描线数据长度不对：期望 ${rawBytes}` +
          `${header.interlace === 1 ? `（Adam7 七个 pass 之和，非隔行应为 ${height * (Math.ceil((width * bitsPerPixel) / 8) + 1)}）` : ""}，` +
          `实际 ${raw.length}。IDAT 被截断或 IHDR 与实际数据不符 —— 拒绝返回半张图。`,
        { expectedRaw: rawBytes, actual: raw.length, interlace: header.interlace },
      ),
    );
  }

  const filled: PassWithPixels[] = [];
  let at = 0;
  for (const p of passes) {
    const bytes = (p.stride + 1) * p.height;
    const slice = raw.subarray(at, at + bytes);
    at += bytes;
    const u = unfilter(slice, p.stride, p.height, bpp);
    if (!u.ok) return err(u.error);
    filled.push({ ...p, raw: u.value });
  }

  const rgba = toRgba(filled, { ...header, width, height }, palette, trns, opts.keep16 === true);
  if (!rgba.ok) return err(rgba.error);
  return ok({ ...rgba.value, bitDepth: header.bitDepth, colorType: header.colorType });
}

// ------------------------------------------------------------------ APNG 元信息

function readAnimationInfo(
  bytes: Uint8Array,
  chunks: readonly PngChunk[],
): Result<PngAnimationInfo | undefined, EngineError> {
  const actl = chunks.find((c) => c.type === "acTL");
  if (actl === undefined) return ok(undefined);
  if (actl.length !== 8) {
    return err(
      engineError(PngErrorCode.BadApng, `acTL 数据长度 ${actl.length}（必须 8）`, { chunk: "acTL" }),
    );
  }
  const frameCount = u32be(bytes, actl.dataStart);
  const loopCount = u32be(bytes, actl.dataStart + 4);
  if (frameCount === 0) {
    return err(engineError(PngErrorCode.BadApng, "acTL.num_frames=0（动图至少要有一帧）", { chunk: "acTL" }));
  }
  // acTL 必须在 IDAT 之前（APNG 规范 §5.2）
  const firstIdat = chunks.find((c) => c.type === "IDAT");
  if (firstIdat !== undefined && actl.start > firstIdat.start) {
    return err(
      engineError(PngErrorCode.BadApng, "acTL 出现在 IDAT 之后（APNG 规范要求之前）", { chunk: "acTL" }),
    );
  }
  return ok({ frameCount, loopCount });
}

// ------------------------------------------------------------------ 入口

/**
 * 解码一张 PNG 成 RGBA8（`keep16` 时另给 RGBA16）。
 *
 * 支持：colorType 0/2/3/4/6 × 位深 1/2/4/8/16 × 非隔行与 **Adam7 隔行**；
 *       APNG 默认解首帧并标记 `isApng`（要全部帧用 `decodeApng`）。
 * 拒绝：非法 interlace 值、未知 colorType/位深（`ASSET.UNSUPPORTED_PNG`）、
 *       任何结构/CRC/zlib 问题（`ASSET.BAD_PNG`）。
 */
export function decodePng(bytes: Uint8Array, opts?: DecodePngOptions): Result<DecodedPng, EngineError> {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_BYTES;
  const scanned = scanPng(bytes);
  if (!scanned.ok) return err(scanned.error);
  const { header: h, palette, trns, idat, chunks } = scanned.value;

  if (h.interlace !== 0 && opts?.interlace === "reject") {
    return err(
      engineError(
        PngErrorCode.UnsupportedInterlace,
        `PNG 使用了 Adam7 隔行（interlace=${h.interlace}），但调用方要求 reject。` +
          `本解码器支持隔行，去掉 interlace:"reject" 即可解出像素。`,
        { width: h.width, height: h.height },
      ),
    );
  }

  const channels = validateFormat(h, palette);
  if (!channels.ok) return err(channels.error);

  const animation = readAnimationInfo(bytes, chunks);
  if (!animation.ok) return err(animation.error);
  if (animation.value !== undefined && opts?.apng === "reject") {
    return err(
      engineError(
        PngErrorCode.UnsupportedAnimation,
        `这是 APNG 动图（${animation.value.frameCount} 帧），但调用方要求 reject。` +
          `要单帧请用默认的 apng:"first-frame"，要全部帧请用 decodeApng()。`,
        { frameCount: animation.value.frameCount },
      ),
    );
  }

  const bitsPerPixel = channels.value * h.bitDepth;
  // ---- 尺寸上限先于任何分配：别让"声明 6 万×6 万"的坏文件把进程打死 ----
  if (h.height > 0 && h.width > Math.floor(maxBytes / 4 / h.height)) {
    return err(
      bad(
        `PNG 尺寸 ${h.width}×${h.height} 的 RGBA8 像素数超过 maxBytes=${maxBytes} 的上限（解压炸弹保护）`,
        { width: h.width, height: h.height, maxBytes },
      ),
    );
  }
  const rawBytes = planPasses(h.width, h.height, bitsPerPixel, h.interlace).reduce(
    (n, p) => n + (p.stride + 1) * p.height,
    0,
  );
  if (rawBytes > maxBytes) {
    return err(
      bad(
        `PNG ${h.width}×${h.height} 的解压后扫描线约 ${rawBytes} 字节，超过 maxBytes=${maxBytes}`,
        { width: h.width, height: h.height, maxBytes },
      ),
    );
  }

  // ---- 拼接 IDAT ----
  const compressed = new Uint8Array(idat.reduce((n, c) => n + c.length, 0));
  {
    let o = 0;
    for (const c of idat) {
      compressed.set(bytes.subarray(c.dataStart, c.dataStart + c.length), o);
      o += c.length;
    }
  }

  const paletteBytes =
    palette === undefined ? undefined : bytes.subarray(palette.dataStart, palette.dataStart + palette.length);
  const trnsBytes = trns === undefined ? undefined : bytes.subarray(trns.dataStart, trns.dataStart + trns.length);

  const decoded = decodeZlibImage(compressed, h, h.width, h.height, paletteBytes, trnsBytes, {
    keep16: opts?.keep16,
    maxBytes,
    label: `PNG ${h.width}×${h.height}`,
  });
  if (!decoded.ok) return err(decoded.error);

  const hasChannelAlpha = h.colorType === 4 || h.colorType === 6;
  return ok({
    width: h.width,
    height: h.height,
    pixels: decoded.value.pixels,
    pixels16: decoded.value.pixels16,
    bitDepth: h.bitDepth,
    colorType: h.colorType,
    hasAlpha: hasChannelAlpha || decoded.value.usedTransparencyKey || decoded.value.paletteAlpha,
    usedTransparencyKey: decoded.value.usedTransparencyKey,
    interlaced: h.interlace === 1,
    isApng: animation.value !== undefined,
    animation: animation.value,
  });
}
