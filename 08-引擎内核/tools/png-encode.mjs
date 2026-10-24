#!/usr/bin/env node
/**
 * PNG / APNG **编码器**（工具的判据，不是引擎的一部分）
 *
 * ★ 这个文件只为一件事存在：**造语料**。
 *   工程内 3284 张真实 PNG 全部非隔行、无 16 位、无 APNG（见 tools/scan-png-features.mjs），
 *   所以"解码器对不对"没有现成语料可验。自己造语料就必须回答"造得对不对"：
 *   本文件的输出会同时交给 **pngjs 7**（隔行/16 位）与 **Pillow 13**（隔行/16 位/APNG）
 *   解码，两个独立实现给出同一份 RGBA 之后，语料才算可信。
 *   也就是说：编码器写错了，两个外部解码器会给出"另一个答案"，不会跟我们错到一起。
 *
 * ★ 隔行数据的生成方式是**过滤式**，与解码器的**生成式**刻意不同：
 *   · 解码器：给定 pass 的 (xStart,yStart,xStep,yStep)，直接算出每个像素的图坐标；
 *   · 编码器：遍历整幅图的每个像素，判断它"落进哪个 pass"，再按 pass 顺序收集。
 *   两种写法只有在 pass 表真的正确时才等价 —— 这是破自证循环的一半（另一半是外部解码器）。
 */

import { deflateSync } from "node:zlib";

// ------------------------------------------------------------------ 基础块

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(bytes) {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(12 + data.length);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, "latin1");
  Buffer.from(data).copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

export const SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

// ------------------------------------------------------------------ 采样

const CHANNELS = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

/** 一行样本值（0..maxV）→ 字节序列。sub-byte 位深按"高比特在前"打包。 */
function packSamples(samples, bitDepth) {
  if (bitDepth === 8) return Buffer.from(samples);
  if (bitDepth === 16) {
    const b = Buffer.alloc(samples.length * 2);
    for (let i = 0; i < samples.length; i++) {
      b[i * 2] = (samples[i] >> 8) & 0xff;
      b[i * 2 + 1] = samples[i] & 0xff;
    }
    return b;
  }
  const perByte = 8 / bitDepth;
  const out = Buffer.alloc(Math.ceil(samples.length / perByte));
  for (let i = 0; i < samples.length; i++) {
    const shift = 8 - bitDepth * ((i % perByte) + 1);
    out[Math.floor(i / perByte)] |= (samples[i] & ((1 << bitDepth) - 1)) << shift;
  }
  return out;
}

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

function filterRow(ft, cur, prev, bpp) {
  const out = Buffer.alloc(cur.length);
  for (let x = 0; x < cur.length; x++) {
    const left = x >= bpp ? cur[x - bpp] : 0;
    const up = prev === null ? 0 : prev[x];
    const upLeft = prev === null || x < bpp ? 0 : prev[x - bpp];
    const pred =
      ft === 0 ? 0 : ft === 1 ? left : ft === 2 ? up : ft === 3 ? (left + up) >> 1 : paeth(left, up, upLeft);
    out[x] = (cur[x] - pred) & 0xff;
  }
  return out;
}

// ------------------------------------------------------------------ Adam7

/** 规范 §8.2 的七组 (xStart, yStart, xStep, yStep)。 */
const ADAM7 = [
  [0, 0, 8, 8],
  [4, 0, 8, 8],
  [0, 4, 4, 8],
  [2, 0, 4, 4],
  [0, 2, 2, 4],
  [1, 0, 2, 2],
  [0, 1, 1, 2],
];

/**
 * **过滤式**分 pass：整幅图逐像素判断"落进哪个 pass"。
 * 返回每个 pass 的行列表 `{ y, xs }`，空 pass 直接不出现。
 */
function passRows(width, height, [xStart, yStart, xStep, yStep]) {
  const rows = [];
  for (let y = yStart; y < height; y += yStep) {
    const xs = [];
    for (let x = xStart; x < width; x += xStep) xs.push(x);
    if (xs.length > 0) rows.push({ y, xs });
  }
  return rows;
}

// ------------------------------------------------------------------ PNG 编码

/**
 * @param {object} spec
 * @param {number} spec.width
 * @param {number} spec.height
 * @param {number} spec.colorType
 * @param {number} spec.bitDepth
 * @param {readonly number[]} spec.samples 整图像素样本（行主序，每像素 channels 个值）
 * @param {number} [spec.interlace] 0/1
 * @param {number} [spec.filter] 0..4
 * @param {readonly number[]} [spec.palette] PLTE（RGB 三元组展开）
 * @param {readonly number[]} [spec.trns] tRNS 数据
 * @param {number} [spec.idatCount] 切成几个 IDAT
 */
function encodeSampleData(spec) {
  const { width, height, colorType, bitDepth, samples } = spec;
  const channels = CHANNELS[colorType];
  if (channels === undefined) throw new Error(`未知 colorType=${colorType}`);
  if (samples.length !== width * height * channels) {
    throw new Error(`样本数不对：${samples.length}，期望 ${width * height * channels}`);
  }
  const interlace = spec.interlace ?? 0;
  const filter = spec.filter ?? 0;
  const bpp = Math.max(1, Math.ceil((channels * bitDepth) / 8));

  const parts = [];
  const passes = interlace === 1 ? ADAM7 : [[0, 0, 1, 1]];
  for (const def of passes) {
    const rows = passRows(width, height, def);
    if (rows.length === 0) continue; // 该 pass 完全不存在，不占字节
    let prev = null;
    for (const { y, xs } of rows) {
      const rowSamples = [];
      for (const x of xs) {
        const off = (y * width + x) * channels;
        for (let c = 0; c < channels; c++) rowSamples.push(samples[off + c]);
      }
      const packed = packSamples(rowSamples, bitDepth);
      parts.push(Buffer.from([filter]), filterRow(filter, packed, prev, bpp));
      prev = packed;
    }
  }
  return { raw: Buffer.concat(parts), interlace };
}

export function encodePng(spec) {
  const { raw, interlace } = encodeSampleData(spec);
  const compressed = deflateSync(raw, { level: 6 });

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(spec.width, 0);
  ihdr.writeUInt32BE(spec.height, 4);
  ihdr[8] = spec.bitDepth;
  ihdr[9] = spec.colorType;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = interlace;

  const out = [SIGNATURE, chunk("IHDR", ihdr)];
  if (spec.palette) out.push(chunk("PLTE", Buffer.from(spec.palette)));
  if (spec.trns) out.push(chunk("tRNS", Buffer.from(spec.trns)));

  const n = spec.idatCount ?? 1;
  const piece = Math.ceil(compressed.length / n);
  for (let i = 0; i < n; i++) {
    out.push(chunk("IDAT", compressed.subarray(i * piece, Math.min((i + 1) * piece, compressed.length))));
  }
  out.push(chunk("IEND", Buffer.alloc(0)));
  return Buffer.concat(out);
}

// ------------------------------------------------------------------ APNG 编码

/**
 * 生成 APNG。
 *
 * @param {object} spec
 * @param {number} spec.width 画布宽
 * @param {number} spec.height 画布高
 * @param {number} spec.loopCount 0 = 无限
 * @param {readonly {rect:{x:number,y:number,width:number,height:number}, rgba:Uint8Array, delayNum:number, delayDen:number, dispose:number, blend:number}[]} spec.frames
 *        `rgba` 是该帧**矩形**的 RGBA8（长度 = w*h*4），不是整幅画布。
 * @param {boolean} [spec.idatFirstFrame] true（默认）时第一帧用 IDAT，否则 IDAT 只是一张
 *        不属于动画的"默认图"，动画帧全部走 fdAT。
 *
 * ★ 序列号：fcTL 与 fdAT 共用同一个递增计数器（APNG 规范 §5.2）。
 *   先 +1 再写，这样序号从 1 开始、第 0 号留给第一帧的 fcTL。
 */
export function encodeApng(spec) {
  const { width, height, loopCount, frames } = spec;
  const idatFirstFrame = spec.idatFirstFrame ?? true;
  if (frames.length === 0) throw new Error("APNG 至少要一帧");

  let sequence = 0;
  const fctl = (f) => {
    const d = Buffer.alloc(26);
    d.writeUInt32BE(sequence++, 0);
    d.writeUInt32BE(f.rect.width, 4);
    d.writeUInt32BE(f.rect.height, 8);
    d.writeUInt32BE(f.rect.x, 12);
    d.writeUInt32BE(f.rect.y, 16);
    d.writeUInt16BE(f.delayNum, 20);
    d.writeUInt16BE(f.delayDen, 22);
    d[24] = f.dispose;
    d[25] = f.blend;
    return chunk("fcTL", d);
  };

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6; // RGBA8
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const actl = Buffer.alloc(8);
  actl.writeUInt32BE(frames.length, 0);
  actl.writeUInt32BE(loopCount, 4);

  const out = [SIGNATURE, chunk("IHDR", ihdr), chunk("acTL", actl)];

  frames.forEach((f, i) => {
    const raw = Buffer.concat([
      // 单行滤波字节 0 + 该行像素，逐行拼
      ...Array.from({ length: f.rect.height }, (_, row) => {
        const line = Buffer.alloc(1 + f.rect.width * 4);
        Buffer.from(f.rgba.buffer, f.rgba.byteOffset + row * f.rect.width * 4, f.rect.width * 4).copy(line, 1);
        return line;
      }),
    ]);
    const z = deflateSync(raw, { level: 6 });

    if (i === 0 && idatFirstFrame) {
      out.push(fctl(f));
      out.push(chunk("IDAT", z));
      return;
    }
    if (i === 0) {
      // 默认图：整幅画布（不属于动画），内容用第一帧矩形铺到左上角之外也行，
      // 但为了让 Pillow 的默认图有意义，这里用"全透明"默认图。
      out.push(chunk("IDAT", deflateSync(Buffer.alloc((1 + width * 4) * height), { level: 6 })));
    }
    out.push(fctl(f));
    const seq = Buffer.alloc(4);
    seq.writeUInt32BE(sequence++, 0);
    out.push(chunk("fdAT", Buffer.concat([seq, z])));
  });

  out.push(chunk("IEND", Buffer.alloc(0)));
  return Buffer.concat(out);
}
