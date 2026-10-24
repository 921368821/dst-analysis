/**
 * L4 · PNG 16 位色深判据
 *
 * 守的缺陷：**"16 位被悄悄当成 8 位用"**。
 *   旧实现只取高字节（`v >> 8`），这在视觉上"看起来没问题"，但两件事被悄悄丢掉：
 *     ① 取整方向固定向暗（floor），与 pngjs/多数实现（round(v/257)）不一致，
 *        同一张图在 headless 判据与浏览器里会差 1 级；
 *     ② 高度图 / 法线图 / 遮罩这类**不能降精度**的图，一旦降到 8 位就再也回不来。
 *   现在的口径：
 *     · `pixels` 恒为 RGBA8，用 `round(v/257)`（与 pngjs 相同的取整）；
 *     · `keep16: true` 时另给 `pixels16`（RGBA16 全精度），且恒满足
 *       `pixels[i] === round(pixels16[i]/257)` —— 两条路径不许漂移。
 *
 * ★ 为什么 16 位"支持"只到解码层：
 *   `TextureDesc` 目前只有 `rgba8` 一种格式，`IGraphicsDevice` 没有 rgba16 上传路径。
 *   让解码器偷偷降采样再假装"支持 16 位纹理"是自欺 —— 真要让 16 位进 GPU，
 *   要先在渲染层加格式与采样器，那是另一件事。这里能保证的是"读进来不丢"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { deflateSync } from "node:zlib";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { DecodedPng } from "../../src/extensions/asset-import/decode/png.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";

function must(r: Result<DecodedPng, EngineError>): DecodedPng {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

// ------------------------------------------------------------------ 最小编码器（只为构造 16 位样本）

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) {
    c ^= bytes[i]!;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  }
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  out[0] = (data.length >>> 24) & 0xff;
  out[1] = (data.length >>> 16) & 0xff;
  out[2] = (data.length >>> 8) & 0xff;
  out[3] = data.length & 0xff;
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  const crc = crc32(out.subarray(4, 8 + data.length));
  out[8 + data.length] = (crc >>> 24) & 0xff;
  out[9 + data.length] = (crc >>> 16) & 0xff;
  out[10 + data.length] = (crc >>> 8) & 0xff;
  out[11 + data.length] = crc & 0xff;
  return out;
}

const SIG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** 单行、filter=0 的 16 位图（够用来验像素语义，不用管压缩率）。 */
function png16(
  width: number,
  height: number,
  colorType: number,
  samples: readonly number[],
  trns?: readonly number[],
): Uint8Array {
  const channels = colorType === 0 ? 1 : colorType === 2 ? 3 : colorType === 4 ? 2 : 4;
  const stride = width * channels * 2;
  const raw = new Uint8Array((stride + 1) * height);
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0;
    for (let x = 0; x < width * channels; x++) {
      const v = samples[y * width * channels + x]!;
      const at = y * (stride + 1) + 1 + x * 2;
      raw[at] = (v >> 8) & 0xff;
      raw[at + 1] = v & 0xff;
    }
  }
  const ihdr = new Uint8Array(13);
  ihdr[0] = (width >>> 24) & 0xff;
  ihdr[1] = (width >>> 16) & 0xff;
  ihdr[2] = (width >>> 8) & 0xff;
  ihdr[3] = width & 0xff;
  ihdr[4] = (height >>> 24) & 0xff;
  ihdr[5] = (height >>> 16) & 0xff;
  ihdr[6] = (height >>> 8) & 0xff;
  ihdr[7] = height & 0xff;
  ihdr[8] = 16;
  ihdr[9] = colorType;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = 0;

  const parts: Uint8Array[] = [SIG, chunk("IHDR", ihdr)];
  if (trns !== undefined) {
    const t = new Uint8Array(trns.length);
    for (let i = 0; i < trns.length; i++) t[i] = trns[i]!;
    parts.push(chunk("tRNS", t));
  }
  parts.push(chunk("IDAT", new Uint8Array(deflateSync(raw))));
  parts.push(chunk("IEND", new Uint8Array(0)));

  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

// ------------------------------------------------------------------ 判据

test("PNG16：0x12FF 降采样到 19（round，不是 floor 的 18）", () => {
  const d = must(decodePng(png16(1, 1, 6, [0x12ff, 0, 0, 0xffff])));
  assert.equal(d.pixels.length, 4);
  assert.equal(d.pixels[0], 19);
  assert.equal(d.pixels[1], 0);
  assert.equal(d.pixels[2], 0);
  assert.equal(d.pixels[3], 255);
});

test("PNG16：全精度保留 —— pixels16 与输入逐值相等", () => {
  const samples = [0x12ff, 0x0001, 0x8000, 0xfffe, 0x0000, 0xffff, 0x7fff, 0x1234];
  const d = must(decodePng(png16(2, 1, 6, samples), { keep16: true }));
  assert.deepEqual(Array.from(d.pixels16!), samples);
});

test("PNG16：pixels 与 pixels16 恒满足 round(v/257)（两条路径不漂移）", () => {
  const samples: number[] = [];
  for (let i = 0; i < 64 * 4; i++) samples.push((i * 1021 + 137) & 0xffff);
  const d = must(decodePng(png16(8, 8, 6, samples), { keep16: true }));
  const p16 = d.pixels16!;
  for (let i = 0; i < d.pixels.length; i++) {
    assert.equal(d.pixels[i], Math.round(p16[i]! / 257), `第 ${i} 通道不一致`);
  }
});

test("PNG16：灰度 16 位 + tRNS 命中 → alpha=0 但 RGB 保留（规范语义）", () => {
  // 色键命中只影响 alpha；把整像素清 0 是某些实现（pngjs）的简化，不是规范要求。
  const d = must(decodePng(png16(3, 1, 0, [0x12ff, 0x0000, 0xffff], [0x12, 0xff]), { keep16: true }));
  assert.equal(d.pixels[0], 19, "命中的像素颜色仍在");
  assert.equal(d.pixels[3], 0, "alpha 必须为 0");
  assert.equal(d.pixels[4], 0, "未命中像素颜色为 0");
  assert.equal(d.pixels[7], 255);
  assert.equal(d.pixels16![0], 0x12ff, "16 位原值也要保留，不能用降采样后的值比较色键");
  assert.equal(d.pixels16![3], 0);

  // 反例：tRNS 落在 0x0003 上、样本里没有 3 → 谁都不透明
  const d2 = must(decodePng(png16(3, 1, 0, [0x12ff, 0x0000, 0xffff], [0x00, 0x03])));
  assert.equal(d2.pixels[3], 255);
  assert.equal(d2.pixels[7], 255);
  assert.equal(d2.usedTransparencyKey, true, "用了 tRNS 就要报告，哪怕这次没命中");
});

test("PNG16：RGB 16 位 + tRNS（三通道同时相等才算透明）", () => {
  const samples = [0x1234, 0x5678, 0x9abc, 0x1234, 0x5678, 0x9abd, 0x0000, 0x0000, 0x0000];
  const d = must(decodePng(png16(3, 1, 2, samples, [0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc]), { keep16: true }));
  assert.equal(d.pixels[3], 0, "三个通道都等于色键 → 透明");
  assert.equal(d.pixels[7], 255, "B 差 1 就不算命中");
  assert.equal(d.pixels[11], 255);
  assert.equal(d.pixels16![1], 0x5678);
});

test("PNG16：灰度+alpha 16 位，走独立通道而不是复制 alpha", () => {
  const d = must(decodePng(png16(2, 1, 4, [0x8000, 0xffff, 0x4000, 0x0000]), { keep16: true }));
  assert.deepEqual(Array.from(d.pixels), [128, 128, 128, 255, 64, 64, 64, 0]);
  assert.deepEqual(Array.from(d.pixels16!), [0x8000, 0x8000, 0x8000, 0xffff, 0x4000, 0x4000, 0x4000, 0]);
  assert.equal(d.hasAlpha, true);
});

test("PNG16：不传 keep16 时不分配 pixels16（16 MB 的图白占 32 MB 不值得）", () => {
  const samples: number[] = [];
  for (let i = 0; i < 32 * 32 * 4; i++) samples.push(i & 0xffff);
  const d = must(decodePng(png16(32, 32, 6, samples)));
  assert.equal(d.pixels16, undefined);
  assert.equal(d.bitDepth, 16);
});
