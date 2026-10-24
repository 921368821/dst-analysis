/**
 * L4 · APNG 解码判据
 *
 * 守的缺陷：**"动图被当静态图静默取首帧"**。
 *   APNG 的 acTL/fcTL/fdAT 首字母小写，按 PNG 规范属于 ancillary 块，
 *   任何只扫 IHDR+IDAT 的解码器都会**不报错地**取到默认帧 —— 于是动图在引擎里
 *   变成一张静止图，且没有任何地方能发现。本文件要求它至少被显式识别。
 *
 * ★ 金标来源（外部实现，不是自解自证）：
 *   `tools/make-png-fixtures.mjs` 编出 APNG → `tools/verify-fixtures-pillow.py`
 *   用 **Pillow** 逐帧解矩形 PNG、再用 `Image.alpha_composite` 做严格 source-over 合成，
 *   按 dispose/blend 状态机拼出每一帧的整幅画布 → 存成 `.frames.rgba`。
 *
 * ★ 为什么不用 Pillow 的 APNG 内建读取当金标：
 *   它把 blend=OVER 实现成 `paste(im, box, im)`，等于拿 alpha 当 mask 同时混 RGB
 *   **和 alpha 自身**，半透明帧的 alpha 会被二次相乘（实测 128 → 64）。
 *   APNG 规范定义的是 Porter-Duff over：`Ao = As + Ad(1-As)`。
 *   所以内建读取只在**全不透明帧**上与逐帧合成做交叉核对（那时两者等价）。
 *   这条差异是"实现口径不同"，不是"我们可选"：按规范算出来的才是对的。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { DecodedApng } from "../../src/extensions/asset-import/decode/apng.ts";
import { decodeApng } from "../../src/extensions/asset-import/decode/apng.ts";
import type { DecodedPng } from "../../src/extensions/asset-import/decode/png.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";

const DIR = fileURLToPath(new URL("../fixtures/png/", import.meta.url));

interface ApngFixture {
  readonly kind: "apng";
  readonly name: string;
  readonly width: number;
  readonly height: number;
  readonly frameCount: number;
  readonly loopCount: number;
  readonly file: string;
  readonly delays: readonly number[];
  readonly idatFirstFrame: boolean;
  readonly golden: string;
}

const manifest = JSON.parse(readFileSync(DIR + "manifest.json", "utf8")) as {
  readonly cases: readonly ({ readonly kind: "apng" } & ApngFixture)[];
};
const apngs = manifest.cases.filter((c) => c.kind === "apng");

function read(name: string): Uint8Array {
  return new Uint8Array(readFileSync(DIR + name));
}

function must(r: Result<DecodedApng, EngineError>): DecodedApng {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function mustFail(r: Result<DecodedApng, EngineError>): EngineError {
  if (r.ok) throw new Error("期望失败，实际成功了");
  return r.error;
}

function mustPng(r: Result<DecodedPng, EngineError>): DecodedPng {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

// ------------------------------------------------------------------ 块定位（用于构造畸形文件）

function u32(b: Uint8Array, at: number): number {
  return ((b[at]! << 24) | (b[at + 1]! << 16) | (b[at + 2]! << 8) | b[at + 3]!) >>> 0;
}

function chunkStart(b: Uint8Array, type: string, nth = 0): number {
  let at = 8;
  let seen = 0;
  while (at + 8 <= b.length) {
    const len = u32(b, at);
    const t = String.fromCharCode(b[at + 4]!, b[at + 5]!, b[at + 6]!, b[at + 7]!);
    if (t === type) {
      if (seen === nth) return at;
      seen++;
    }
    if (t === "IEND") break;
    at += 12 + len;
  }
  throw new Error(`测试构造错误：找不到第 ${nth} 个 "${type}" 块`);
}

/** 改一个字节后必须重算该块 CRC，否则会被"CRC 校验失败"提前拦下，测不到目标逻辑。 */
function patchChunk(b: Uint8Array, type: string, nth: number, offsetInData: number, value: number): void {
  const at = chunkStart(b, type, nth);
  const len = u32(b, at);
  b[at + 8 + offsetInData] = value;
  const crc = crc32(b.subarray(at + 4, at + 8 + len));
  b[at + 8 + len] = (crc >>> 24) & 0xff;
  b[at + 9 + len] = (crc >>> 16) & 0xff;
  b[at + 10 + len] = (crc >>> 8) & 0xff;
  b[at + 11 + len] = crc & 0xff;
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

// ------------------------------------------------------------------ 金标

test("APNG：清单里有 4 类合成场景（none/default-image/background/previous）", () => {
  assert.ok(apngs.length >= 4, `APNG 用例只有 ${apngs.length} 个`);
  const names = apngs.map((a) => a.name).join(",");
  for (const expect of ["none-source", "background-over", "previous-over", "default-image"]) {
    assert.match(names, new RegExp(expect), `缺少场景 ${expect}`);
  }
});

for (const a of apngs) {
  test(`APNG 金标：${a.name} 逐帧画布 == Pillow 严格合成金标（逐字节）`, () => {
    const r = must(decodeApng(read(a.file)));
    assert.equal(r.width, a.width);
    assert.equal(r.height, a.height);
    assert.equal(r.loopCount, a.loopCount, "num_plays 要原样保留（0 = 无限，不能换成 Infinity）");
    assert.equal(r.frames.length, a.frameCount);

    const golden = read(a.golden);
    const frameBytes = a.width * a.height * 4;
    assert.equal(golden.length, frameBytes * a.frameCount, "金标长度应等于 帧数 × 画布字节数");

    for (let i = 0; i < r.frames.length; i++) {
      const f = r.frames[i]!;
      assert.equal(f.pixels.length, frameBytes, `第 ${i} 帧必须是整幅画布，不是帧矩形切片`);
      const got = Buffer.from(f.pixels);
      const want = Buffer.from(golden.subarray(i * frameBytes, (i + 1) * frameBytes));
      assert.deepEqual(got, want, `第 ${i} 帧的合成结果与金标不同`);
      assert.equal(f.delayMs, a.delays[i], `第 ${i} 帧延迟应为 ${a.delays[i]}ms`);
    }
  });

  test(`APNG：${a.name} 帧矩形与 dispose/blend 元信息与 manifest 一致`, () => {
    const r = must(decodeApng(read(a.file)));
    assert.ok(r.frames.length > 0);
    for (const f of r.frames) {
      assert.equal(f.rect.x + f.rect.width <= a.width, true, "帧矩形不能越界");
      assert.equal(f.rect.y + f.rect.height <= a.height, true, "帧矩形不能越界");
      assert.ok(f.dispose === 0 || f.dispose === 1 || f.dispose === 2);
      assert.ok(f.blend === 0 || f.blend === 1);
    }
  });
}

test("APNG：limit 只解前 N 帧（大动图按需解，不一次吃满内存）", () => {
  const a = apngs[0]!;
  const all = must(decodeApng(read(a.file)));
  const one = must(decodeApng(read(a.file), { limit: 1 }));
  assert.equal(one.frames.length, 1);
  assert.deepEqual(Buffer.from(one.frames[0]!.pixels), Buffer.from(all.frames[0]!.pixels));
});

test("APNG：decodePng 遇到动图默认给首帧，但必须标记 isApng 与帧数", () => {
  const a = apngs[0]!;
  const d = mustPng(decodePng(read(a.file)));
  assert.equal(d.isApng, true, "静默取首帧是最坏的失败模式：调用方无法知道这是动图");
  assert.equal(d.animation?.frameCount, a.frameCount);
  assert.equal(d.animation?.loopCount, a.loopCount);
  assert.equal(d.interlaced, false);
});

test("APNG：decodePng 的 apng:'reject' 报 ASSET.UNSUPPORTED_ANIMATION", () => {
  const a = apngs[0]!;
  const r = decodePng(read(a.file), { apng: "reject" });
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, "ASSET.UNSUPPORTED_ANIMATION");
  assert.match(r.error.message, /APNG|动图/);
});

test("APNG：默认帧（IDAT 不属于动画）不算动画帧，帧数只数 fcTL", () => {
  const a = apngs.find((x) => !x.idatFirstFrame)!;
  assert.ok(a !== undefined, "清单里应有 idatFirstFrame=false 的用例");
  const r = must(decodeApng(read(a.file)));
  assert.equal(r.frames.length, a.frameCount);
  // 第一帧应当只有 fcTL 描述的矩形被绘制，其余像素仍是初始透明
  const f0 = r.frames[0]!;
  assert.ok(f0.rect.width <= a.width && f0.rect.height <= a.height);
});

// ------------------------------------------------------------------ 错误路径

test("APNG：静态 PNG 调 decodeApng → ASSET.BAD_APNG（并提示改用 decodePng）", () => {
  const e = mustFail(decodeApng(read("rgba8-13x11.interlaced.png")));
  assert.equal(e.code, "ASSET.BAD_APNG");
  assert.match(e.message, /acTL/);
  assert.match(e.message, /decodePng/);
});

test("APNG：acTL 声明的帧数与实际 fcTL 数不符 → 报错（不静默截断）", () => {
  const a = apngs[0]!;
  const buf = read(a.file);
  // acTL 数据：num_frames(u32) num_plays(u32)
  patchChunk(buf, "acTL", 0, 3, buf[chunkStart(buf, "acTL", 0) + 8 + 3]! + 1);
  const e = mustFail(decodeApng(buf));
  assert.equal(e.code, "ASSET.BAD_APNG");
  assert.match(e.message, /帧数|声明/);
});

test("APNG：fdAT 序列号断裂 → 报错（序列号是防止帧错位的唯一手段）", () => {
  const a = apngs[0]!;
  const buf = read(a.file);
  patchChunk(buf, "fdAT", 0, 3, 0x7f);
  const e = mustFail(decodeApng(buf));
  assert.equal(e.code, "ASSET.BAD_APNG");
  assert.match(e.message, /序列号/);
});

test("APNG：dispose_op=3 → 报错（越界枚举不能猜着当 0 处理）", () => {
  const a = apngs[0]!;
  const buf = read(a.file);
  patchChunk(buf, "fcTL", 1, 24, 3);
  const e = mustFail(decodeApng(buf));
  assert.equal(e.code, "ASSET.BAD_APNG");
  assert.match(e.message, /dispose_op=3/);
});

test("APNG：blend_op=2 → 报错", () => {
  const a = apngs[0]!;
  const buf = read(a.file);
  patchChunk(buf, "fcTL", 1, 25, 2);
  const e = mustFail(decodeApng(buf));
  assert.equal(e.code, "ASSET.BAD_APNG");
  assert.match(e.message, /blend_op=2/);
});

test("APNG：帧矩形越界 → 报错（不然合成时会写穿画布）", () => {
  const a = apngs[0]!;
  const buf = read(a.file);
  // fcTL 数据：seq(4) width(4) height(4) x(4) y(4) ...
  const at = chunkStart(buf, "fcTL", 0);
  const tooWide = a.width + 10;
  buf[at + 8 + 4] = (tooWide >>> 24) & 0xff;
  buf[at + 8 + 5] = (tooWide >>> 16) & 0xff;
  buf[at + 8 + 6] = (tooWide >>> 8) & 0xff;
  buf[at + 8 + 7] = tooWide & 0xff;
  const len = u32(buf, at);
  const crc = crc32(buf.subarray(at + 4, at + 8 + len));
  buf[at + 8 + len] = (crc >>> 24) & 0xff;
  buf[at + 9 + len] = (crc >>> 16) & 0xff;
  buf[at + 10 + len] = (crc >>> 8) & 0xff;
  buf[at + 11 + len] = crc & 0xff;

  const e = mustFail(decodeApng(buf));
  assert.equal(e.code, "ASSET.BAD_APNG");
  assert.match(e.message, /越界/);
});

test("APNG：maxFrames 太小 → 报错（防「声明一百万帧」）", () => {
  const a = apngs[0]!;
  const e = mustFail(decodeApng(read(a.file), { maxFrames: 1 }));
  assert.equal(e.code, "ASSET.BAD_APNG");
  assert.match(e.message, /maxFrames/);
});
