/**
 * L4 · PNG 解码判据
 *
 * 守的缺陷：**"只读 IHDR"的导入链全绿，像素却没人解**。
 *   导入器（importers/texture.ts）刻意不读 IDAT；浏览器画面用程序化假贴图。
 *   没有解码器时，"这张 PNG 到底长什么样"在 Node 侧完全不可知 ——
 *   于是图集合成、GPU 上传、颜色/alpha 全都是未验证的假设。
 *
 * 这里自己**编码** PNG 作为输入（而不是读外部文件）：
 *   · 判据不依赖工作区里有没有某张图；
 *   · 每种 colorType/bitDepth/滤波都能精确构造到"边界值"；
 *   · 编解码往返能逐字节比对 —— 这是最强的一条，能同时抓住滤波方向、
 *     通道顺序、16 位降采样位置、调色板 alpha 的所有错法。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { deflateSync } from "node:zlib";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { DecodedPng } from "../../src/extensions/asset-import/decode/png.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";

// ------------------------------------------------------------------ PNG 编码 helper

function writeU32(b: Uint8Array, at: number, v: number): void {
  b[at] = (v >>> 24) & 0xff;
  b[at + 1] = (v >>> 16) & 0xff;
  b[at + 2] = (v >>> 8) & 0xff;
  b[at + 3] = v & 0xff;
}

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]!) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  writeU32(out, 0, data.length);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  writeU32(out, 8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

const CHANNELS: Readonly<Record<number, number>> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };

function paeth(a: number, b: number, c: number): number {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/** 把一行原始样本按 PNG 规则做正向滤波（编码器侧）。 */
function filterRow(ft: number, cur: Uint8Array, prev: Uint8Array | null, bpp: number): Uint8Array {
  const out = new Uint8Array(cur.length);
  for (let x = 0; x < cur.length; x++) {
    const left = x >= bpp ? cur[x - bpp]! : 0;
    const up = prev === null ? 0 : prev[x]!;
    const upLeft = prev === null || x < bpp ? 0 : prev[x - bpp]!;
    let pred: number;
    switch (ft) {
      case 0:
        pred = 0;
        break;
      case 1:
        pred = left;
        break;
      case 2:
        pred = up;
        break;
      case 3:
        pred = (left + up) >> 1;
        break;
      default:
        pred = paeth(left, up, upLeft);
        break;
    }
    out[x] = (cur[x]! - pred) & 0xff;
  }
  return out;
}

interface PngSpec {
  readonly width: number;
  readonly height: number;
  readonly bitDepth: number;
  readonly colorType: number;
  /** 未滤波的行（每行 stride 字节）。可以为空（用于构造畸形文件）。 */
  readonly rows?: readonly Uint8Array[];
  /** 所有行共用的滤波类型（默认 0）。 */
  readonly filter?: number;
  readonly palette?: Uint8Array;
  readonly trns?: Uint8Array;
  readonly interlace?: number;
  /** 把 zlib 流切成 N 个 IDAT。 */
  readonly splitIdat?: number;
  /** 从压缩流尾部切掉 N 字节（构造"IDAT 被截断"）。 */
  readonly compressCut?: number;
  readonly level?: number;
}

function encodePng(spec: PngSpec): Uint8Array {
  const channels = CHANNELS[spec.colorType] ?? 4; // 未知 colorType 的测试用 4 通道占位
  const stride = Math.ceil((spec.width * channels * spec.bitDepth) / 8);
  const bpp = Math.max(1, Math.ceil((channels * spec.bitDepth) / 8));
  const rows = spec.rows ?? [];
  const ft = spec.filter ?? 0;

  const raw = new Uint8Array(rows.length * (stride + 1));
  for (const [y, row] of rows.entries()) {
    assert.equal(row.length, stride, `测试构造错误：第 ${y} 行 ${row.length} 字节，应为 ${stride}`);
    raw[y * (stride + 1)] = ft;
    const masked = filterRow(ft, row, y > 0 ? rows[y - 1]! : null, bpp);
    raw.set(masked, y * (stride + 1) + 1);
  }

  let compressed = new Uint8Array(deflateSync(raw, { level: spec.level ?? 6 }));
  if (spec.compressCut !== undefined) compressed = compressed.subarray(0, Math.max(0, compressed.length - spec.compressCut));

  const ihdr = new Uint8Array(13);
  writeU32(ihdr, 0, spec.width);
  writeU32(ihdr, 4, spec.height);
  ihdr[8] = spec.bitDepth;
  ihdr[9] = spec.colorType;
  ihdr[10] = 0;
  ihdr[11] = 0;
  ihdr[12] = spec.interlace ?? 0;

  const parts: Uint8Array[] = [
    new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
  ];
  if (spec.palette !== undefined) parts.push(chunk("PLTE", spec.palette));
  if (spec.trns !== undefined) parts.push(chunk("tRNS", spec.trns));

  const nIdat = spec.splitIdat ?? 1;
  const piece = Math.ceil(compressed.length / nIdat);
  for (let i = 0; i < nIdat; i++) {
    parts.push(chunk("IDAT", compressed.subarray(i * piece, Math.min((i + 1) * piece, compressed.length))));
  }
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

function must<T>(r: Result<T, EngineError>): T {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function mustFail(r: Result<DecodedPng, EngineError>): EngineError {
  if (r.ok) throw new Error("期望失败，实际成功了");
  return r.error;
}

/** 生成 RGBA 像素 + 对应的未滤波行。 */
function rgbaImage(w: number, h: number): { pixels: Uint8Array; rows: Uint8Array[] } {
  const pixels = new Uint8Array(w * h * 4);
  for (let i = 0; i < pixels.length; i++) pixels[i] = (i * 37 + 11) & 0xff;
  const rows: Uint8Array[] = [];
  for (let y = 0; y < h; y++) rows.push(pixels.slice(y * w * 4, (y + 1) * w * 4));
  return { pixels, rows };
}

// ------------------------------------------------------------------ 判据

test("PNG：1×1 RGB 解码成 RGBA，alpha 补 255", () => {
  const png = encodePng({
    width: 1,
    height: 1,
    bitDepth: 8,
    colorType: 2,
    rows: [new Uint8Array([10, 20, 30])],
  });
  const d = must(decodePng(png));
  assert.equal(d.width, 1);
  assert.equal(d.height, 1);
  assert.equal(d.colorType, 2);
  assert.deepEqual(Array.from(d.pixels), [10, 20, 30, 255]);
  assert.equal(d.hasAlpha, false);
});

test("PNG：RGBA8 编解码逐字节往返（滤波/通道顺序的最强判据）", () => {
  const { pixels, rows } = rgbaImage(7, 5);
  const png = encodePng({ width: 7, height: 5, bitDepth: 8, colorType: 6, rows });
  const d = must(decodePng(png));
  assert.equal(d.width, 7);
  assert.equal(d.height, 5);
  assert.equal(d.pixels.byteLength, pixels.byteLength);
  assert.deepEqual(Buffer.from(d.pixels), Buffer.from(pixels), "往返后每个字节都必须相同");
  assert.equal(d.hasAlpha, true);
});

test("PNG：Sub / Up / Average / Paeth 四种滤波各自往返正确", () => {
  const { pixels, rows } = rgbaImage(9, 6);
  for (const ft of [1, 2, 3, 4]) {
    const png = encodePng({ width: 9, height: 6, bitDepth: 8, colorType: 6, rows, filter: ft });
    const d = must(decodePng(png));
    assert.deepEqual(Buffer.from(d.pixels), Buffer.from(pixels), `滤波 ${ft} 往返不一致`);
  }
});

test("PNG：调色板 + tRNS → 索引转 RGBA，透明索引 alpha=0", () => {
  const png = encodePng({
    width: 4,
    height: 1,
    bitDepth: 8,
    colorType: 3,
    rows: [new Uint8Array([0, 1, 2, 0])],
    palette: new Uint8Array([255, 0, 0, 0, 255, 0, 0, 0, 255]),
    trns: new Uint8Array([0]),
  });
  const d = must(decodePng(png));
  assert.deepEqual(Array.from(d.pixels), [255, 0, 0, 0, 0, 255, 0, 255, 0, 0, 255, 255, 255, 0, 0, 0]);
  assert.equal(d.hasAlpha, true);
  assert.equal(d.usedTransparencyKey, false, "调色板的 tRNS 是逐项 alpha，不是色键");
});

test("PNG：灰度 bitDepth 1/2/4 展开成 8 位（v*255/max）", () => {
  // 1 位、宽 8：值 1,0,1,0,0,0,0,0 → 0b10100000
  const g1 = must(
    decodePng(
      encodePng({ width: 8, height: 1, bitDepth: 1, colorType: 0, rows: [new Uint8Array([0b10100000])] }),
    ),
  );
  assert.deepEqual(
    Array.from(g1.pixels).filter((_, i) => i % 4 === 0),
    [255, 0, 255, 0, 0, 0, 0, 0],
  );
  assert.equal(g1.pixels[1], 255, "灰度值要复制到 G");
  assert.equal(g1.pixels[3], 255);

  // 2 位、宽 4：值 0,1,2,3 → 0b00011011
  const g2 = must(
    decodePng(
      encodePng({ width: 4, height: 1, bitDepth: 2, colorType: 0, rows: [new Uint8Array([0b00011011])] }),
    ),
  );
  assert.deepEqual(
    Array.from(g2.pixels).filter((_, i) => i % 4 === 0),
    [0, 85, 170, 255],
  );

  // 4 位、宽 2：值 3,15 → 0x3F
  const g4 = must(
    decodePng(encodePng({ width: 2, height: 1, bitDepth: 4, colorType: 0, rows: [new Uint8Array([0x3f])] })),
  );
  assert.deepEqual(
    Array.from(g4.pixels).filter((_, i) => i % 4 === 0),
    [51, 255],
  );
});

test("PNG：16 位降采样到 8 位（取高字节）", () => {
  const row = new Uint8Array([0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0]);
  const d = must(decodePng(encodePng({ width: 1, height: 1, bitDepth: 16, colorType: 6, rows: [row] })));
  assert.deepEqual(Array.from(d.pixels), [0x12, 0x56, 0x9a, 0xde]);
  assert.equal(d.bitDepth, 16);
});

test("PNG：多 IDAT 块拼接后与单块结果一致", () => {
  const { pixels, rows } = rgbaImage(16, 9);
  const one = must(decodePng(encodePng({ width: 16, height: 9, bitDepth: 8, colorType: 6, rows })));
  const many = must(
    decodePng(encodePng({ width: 16, height: 9, bitDepth: 8, colorType: 6, rows, splitIdat: 4 })),
  );
  assert.deepEqual(Buffer.from(many.pixels), Buffer.from(one.pixels));
  assert.deepEqual(Buffer.from(many.pixels), Buffer.from(pixels));
});

test("PNG：签名错误 → ASSET.BAD_PNG", () => {
  const png = encodePng({ width: 1, height: 1, bitDepth: 8, colorType: 2, rows: [new Uint8Array([1, 2, 3])] });
  png[0] = 0x88;
  const e = mustFail(decodePng(png));
  assert.equal(e.code, "ASSET.BAD_PNG");
  assert.match(e.message, /签名/);
});

test("PNG：IDAT 被截断 → 明确报错（不返回半张图）", () => {
  const { rows } = rgbaImage(32, 32);
  const png = encodePng({ width: 32, height: 32, bitDepth: 8, colorType: 6, rows, compressCut: 24 });
  const e = mustFail(decodePng(png));
  assert.equal(e.code, "ASSET.BAD_PNG");
  assert.match(e.message, /IDAT|扫描线|解压/);
});

test("PNG：CRC 错误 → ASSET.BAD_PNG 且点名块类型", () => {
  const png = encodePng({
    width: 4,
    height: 4,
    bitDepth: 8,
    colorType: 6,
    rows: rgbaImage(4, 4).rows,
  });
  // 找 IDAT：块布局 length(4) type(4) data...
  const needle = [0x49, 0x44, 0x41, 0x54];
  let at = -1;
  outer: for (let i = 0; i < png.length - 4; i++) {
    for (let k = 0; k < 4; k++) if (png[i + k] !== needle[k]) continue outer;
    at = i;
    break;
  }
  assert.ok(at > 0, "测试构造错误：找不到 IDAT");
  png[at + 4] = png[at + 4]! ^ 0xff; // 改数据 → CRC 必然不符
  const e = mustFail(decodePng(png));
  assert.equal(e.code, "ASSET.BAD_PNG");
  assert.match(e.message, /IDAT/, "错误要点名是哪个块");
  assert.match(e.message, /CRC/);
});

test("PNG：Adam7 隔行 → ASSET.UNSUPPORTED_INTERLACE（不是花屏）", () => {
  const png = encodePng({
    width: 4,
    height: 4,
    bitDepth: 8,
    colorType: 6,
    rows: rgbaImage(4, 4).rows,
    interlace: 1,
  });
  const e = mustFail(decodePng(png));
  assert.equal(e.code, "ASSET.UNSUPPORTED_INTERLACE");
  assert.match(e.message, /隔行|interlace/i);
});

test("PNG：未知 colorType=7 → ASSET.UNSUPPORTED_PNG", () => {
  const png = encodePng({ width: 1, height: 1, bitDepth: 8, colorType: 7, rows: [new Uint8Array([1, 2, 3, 4])] });
  const e = mustFail(decodePng(png));
  assert.equal(e.code, "ASSET.UNSUPPORTED_PNG");
  assert.match(e.message, /colorType=7/);
});

test("PNG：声明巨大尺寸 + 极少数据 → 被 maxBytes 拦下（解压炸弹）", () => {
  // IHDR 说 100000×100000（RGBA 需要 40 GB），IDAT 里一个字节都没有
  const png = encodePng({ width: 100000, height: 100000, bitDepth: 8, colorType: 6, rows: [] });
  const e = mustFail(decodePng(png));
  assert.equal(e.code, "ASSET.BAD_PNG");
  assert.match(e.message, /maxBytes/);
});
