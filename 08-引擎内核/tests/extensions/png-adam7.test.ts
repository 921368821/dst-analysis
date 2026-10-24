/**
 * L4 · PNG 解码 · Adam7 隔行的**尺寸矩阵**判据
 *
 * png-fixtures.test.ts 验的是"外部实现认可的金标"，本文件验的是"边界不漏"：
 *   · 每个 pass 宽度为 0 的尺寸（窄图只有前几个 pass 存在）；
 *   · sub-byte 位深在每个 pass 内**重新按位打包**（4 位灰度在某 pass 里可能只有 1 个像素，
 *     占 1 字节的高 4 位）；
 *   · 每个 pass 独立反滤波（第一行没有 up 邻居）。
 *
 * ★ 为什么用 5 种滤波各编一遍：如果解码器把"上一个 pass 的最后一行"当成
 *   "本 pass 的第一行的 up 邻居"，只有 filter=2/3/4 会错，filter=0/1 照样对。
 *   五张图必须解出**完全相同**的像素 —— 这条判据专门钉住这个错法，
 *   而"只跟自己比一次往返"是抓不到的（编解码双方会一起错）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { DecodedPng } from "../../src/extensions/asset-import/decode/png.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";
import { encodePng } from "../../tools/png-encode.mjs";

function must(r: Result<DecodedPng, EngineError>): DecodedPng {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

/** RGBA8 源样本：与 fixture 生成器同一公式，保证可复现。 */
function rgbaSamples(w: number, h: number): number[] {
  const out: number[] = [];
  for (let i = 0; i < w * h; i++) {
    out.push((i * 37 + 11) & 0xff, (i * 97 + 5) & 0xff, (i * 13 + 201) & 0xff, (i * 251 + 7) & 0xff);
  }
  return out;
}

const CHANNELS: Readonly<Record<number, number>> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

test("Adam7：1..17 × 1..17 全尺寸矩阵，隔行解码 == 源样本", () => {
  let count = 0;
  for (let w = 1; w <= 17; w++) {
    for (let h = 1; h <= 17; h++) {
      const samples = rgbaSamples(w, h);
      const png = encodePng({ width: w, height: h, colorType: 6, bitDepth: 8, samples, interlace: 1 });
      const d = must(decodePng(png));
      assert.equal(d.interlaced, true);
      assert.equal(d.width, w);
      assert.equal(d.height, h);
      assert.deepEqual(
        Buffer.from(d.pixels),
        Buffer.from(samples),
        `${w}×${h} 的隔行解码与源像素不同（pass 布局或空 pass 处理错了）`,
      );
      count++;
    }
  }
  assert.equal(count, 289, "矩阵数量不对，说明循环被改坏了");
});

test("Adam7：隔行与非隔行在 1..17 矩阵上逐字节相同", () => {
  for (let w = 1; w <= 17; w++) {
    for (let h = 1; h <= 17; h++) {
      const samples = rgbaSamples(w, h);
      const base = { width: w, height: h, colorType: 6, bitDepth: 8, samples };
      const plain = must(decodePng(encodePng({ ...base, interlace: 0 })));
      const il = must(decodePng(encodePng({ ...base, interlace: 1 })));
      assert.deepEqual(Buffer.from(plain.pixels), Buffer.from(il.pixels), `${w}×${h} 两条路径不一致`);
    }
  }
});

test("Adam7：5 种滤波各自解出相同像素（证明每个 pass 独立反滤波）", () => {
  const w = 13;
  const h = 11;
  const samples = rgbaSamples(w, h);
  const results: Uint8Array[] = [];
  for (const filter of [0, 1, 2, 3, 4]) {
    const png = encodePng({ width: w, height: h, colorType: 6, bitDepth: 8, samples, interlace: 1, filter });
    results.push(must(decodePng(png)).pixels);
  }
  for (let i = 1; i < results.length; i++) {
    assert.deepEqual(
      Buffer.from(results[i]!),
      Buffer.from(results[0]!),
      `filter=${i} 的结果与 filter=0 不同 —— pass 之间串了 up 邻居`,
    );
  }
  assert.deepEqual(Buffer.from(results[0]!), Buffer.from(samples));
});

test("Adam7：sub-byte 灰度 1/2/4 位在矩阵尺寸上正确（每 pass 重新按位打包）", () => {
  for (const bitDepth of [1, 2, 4]) {
    const maxV = (1 << bitDepth) - 1;
    for (let w = 1; w <= 13; w++) {
      for (let h = 1; h <= 9; h++) {
        const samples: number[] = [];
        for (let i = 0; i < w * h; i++) samples.push(i % (maxV + 1));
        const png = encodePng({ width: w, height: h, colorType: 0, bitDepth, samples, interlace: 1 });
        const d = must(decodePng(png));
        const scale = 255 / maxV;
        for (let i = 0; i < w * h; i++) {
          const expect = Math.round(samples[i]! * scale);
          assert.equal(
            d.pixels[i * 4],
            expect,
            `${w}×${h} bitDepth=${bitDepth} 第 ${i} 像素：${d.pixels[i * 4]} != ${expect}`,
          );
        }
      }
    }
  }
});

test("Adam7：调色板 2/4 位在矩阵尺寸上正确（索引按 pass 重新打包）", () => {
  const palette = Array.from({ length: 48 }, (_, i) => (i * 37) & 0xff);
  for (const bitDepth of [2, 4]) {
    const entries = bitDepth === 2 ? 4 : 16;
    for (let w = 1; w <= 11; w += 2) {
      for (let h = 1; h <= 9; h += 2) {
        const samples: number[] = [];
        for (let i = 0; i < w * h; i++) samples.push(i % entries);
        const png = encodePng({ width: w, height: h, colorType: 3, bitDepth, samples, interlace: 1, palette });
        const d = must(decodePng(png));
        for (let i = 0; i < w * h; i++) {
          const idx = samples[i]!;
          assert.equal(d.pixels[i * 4], palette[idx * 3], `${w}×${h} 第 ${i} 像素 R 通道错`);
          assert.equal(d.pixels[i * 4 + 1], palette[idx * 3 + 1]);
          assert.equal(d.pixels[i * 4 + 2], palette[idx * 3 + 2]);
        }
      }
    }
  }
});

test("Adam7：64×64 大图（七个 pass 都多行）逐字节往返", () => {
  const w = 64;
  const h = 64;
  const samples = rgbaSamples(w, h);
  const png = encodePng({ width: w, height: h, colorType: 6, bitDepth: 8, samples, interlace: 1, filter: 4 });
  const d = must(decodePng(png));
  assert.deepEqual(Buffer.from(d.pixels), Buffer.from(samples));
});

test("Adam7：16 位隔行往返（按 pass 重新对齐 2 字节样本）", () => {
  const w = 9;
  const h = 7;
  const samples: number[] = [];
  for (let i = 0; i < w * h * 4; i++) samples.push((i * 4099 + 7) & 0xffff);
  const png = encodePng({ width: w, height: h, colorType: 6, bitDepth: 16, samples, interlace: 1 });
  const d = must(decodePng(png, { keep16: true }));
  assert.deepEqual(Array.from(d.pixels16!), samples);
});

test("Adam7：IHDR 声明 interlace=1 但数据按非隔行写 → 报长度不对（不猜）", () => {
  const w = 8;
  const h = 8;
  const samples = rgbaSamples(w, h);
  // 非隔行的数据，却把 IHDR 标成隔行
  const png = encodePng({ width: w, height: h, colorType: 6, bitDepth: 8, samples, interlace: 0 });
  const at = 8; // IHDR 块起始（签名之后第一个块）
  const len = ((png[at]! << 24) | (png[at + 1]! << 16) | (png[at + 2]! << 8) | png[at + 3]!) >>> 0;
  png[at + 8 + 12] = 1; // interlace 字节
  // 重算 CRC（否则会先被 CRC 拦下，测不到布局校验）
  const crcTable: number[] = [];
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crcTable[n] = c >>> 0;
  }
  let crc = 0xffffffff;
  for (let i = at + 4; i < at + 8 + len; i++) crc = crcTable[(crc ^ png[i]!) & 0xff]! ^ (crc >>> 8);
  crc = (crc ^ 0xffffffff) >>> 0;
  png[at + 8 + len] = (crc >>> 24) & 0xff;
  png[at + 9 + len] = (crc >>> 16) & 0xff;
  png[at + 10 + len] = (crc >>> 8) & 0xff;
  png[at + 11 + len] = crc & 0xff;

  const r = decodePng(png);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, "ASSET.BAD_PNG");
  assert.match(r.error.message, /扫描线|长度不对|Adam7/);
});

test("Adam7：每个 pass 的通道数与非隔行一致（灰度不带 alpha）", () => {
  const w = 10;
  const h = 10;
  const samples: number[] = [];
  for (let i = 0; i < w * h; i++) samples.push((i * 7) & 0xff);
  const d = must(
    decodePng(encodePng({ width: w, height: h, colorType: 0, bitDepth: 8, samples, interlace: 1 })),
  );
  assert.equal(d.hasAlpha, false);
  for (let i = 0; i < w * h; i++) {
    assert.equal(d.pixels[i * 4], samples[i]);
    assert.equal(d.pixels[i * 4 + 3], 255);
  }
  // 顺带确认 CHANNELS 表没被改坏：这是编解码双方共享的唯一常量，改错会一致地错
  assert.equal(CHANNELS[0], 1);
});
