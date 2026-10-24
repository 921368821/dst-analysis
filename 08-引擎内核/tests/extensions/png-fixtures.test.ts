/**
 * L4 · PNG 解码 · **外部金标回归**（Adam7 隔行 / 16 位 / sub-byte / 退化尺寸）
 *
 * 这组判据与 png-decode.test.ts 的分工：
 *   · png-decode.test.ts 用**自造编码 + 自解**验算法骨架（往返、滤波、错误路径）；
 *   · 本文件用**外部实现产出的金标**验"我们解的和对别人解的是一样的"。
 *
 * ★ 金标怎么来的（不是我们自己解出来的）：
 *   `tools/make-png-fixtures.mjs` 生成隔行 PNG → **pngjs 7** 解码 → 存成 `.rgba`；
 *   `tools/verify-fixtures-pillow.py` 再用 **Pillow 13** 解一遍，两者必须逐字节相同。
 *   两个独立实现都认了，金标才写进 fixtures。测试运行时**不依赖**它们，
 *   只读固定字节 —— 项目不会因此多一个第三方依赖。
 *
 * ★ 为什么没有真实语料也能叫"支持"：
 *   工程内 3284 张真实 PNG 实测**全部非隔行、8 位、无 APNG**
 *   （`node tools/scan-png-features.mjs`）。也就是说"拿真实图片跑一遍"这条路根本不存在。
 *   替代方案不是"相信实现"，而是：构造语料 → 两个外部实现交叉验证 →
 *   把结果固化成金标 → 每次 CI 逐字节比对。任一环节撒谎，金标就会和我们的输出分叉。
 *
 * ★ 隔行与非隔行必须解出**同一份像素**：这是不依赖任何外部金标的不变量。
 *   它同时钉住两件事 —— pass 布局正确、sub-byte 在每个 pass 内重新打包正确。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { DecodedPng } from "../../src/extensions/asset-import/decode/png.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";

const DIR = fileURLToPath(new URL("../fixtures/png/", import.meta.url));

interface Fixture {
  readonly name: string;
  readonly width: number;
  readonly height: number;
  readonly colorType: number;
  readonly bitDepth: number;
  readonly plain: string;
  readonly interlaced: string;
  readonly golden: string;
  readonly goldenSha256: string;
  readonly samples16?: string;
}

const manifest = JSON.parse(readFileSync(DIR + "manifest.json", "utf8")) as {
  readonly pngjs: string;
  readonly cases: readonly (Fixture | { readonly kind: "apng" })[];
};

const fixtures = manifest.cases.filter((c): c is Fixture => !("kind" in c));

function read(name: string): Uint8Array {
  return new Uint8Array(readFileSync(DIR + name));
}

function must(r: Result<DecodedPng, EngineError>): DecodedPng {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

test("PNG 金标：清单非空且记录了外部生成器版本", () => {
  assert.ok(fixtures.length >= 15, `金标用例只有 ${fixtures.length} 个，少了说明生成器坏了`);
  assert.match(manifest.pngjs, /^\d+\.\d+\.\d+/, "manifest 必须记录 pngjs 版本");
});

for (const f of fixtures) {
  test(`PNG 金标：${f.name} 隔行解码 == pngjs/Pillow 金标（逐字节）`, () => {
    const golden = read(f.golden);
    assert.equal(
      createHash("sha256").update(golden).digest("hex"),
      f.goldenSha256,
      "金标文件被改动过 —— 重新跑 tools/make-png-fixtures.mjs 并说明为什么变",
    );

    const d = must(decodePng(read(f.interlaced)));
    assert.equal(d.width, f.width);
    assert.equal(d.height, f.height);
    assert.equal(d.colorType, f.colorType);
    assert.equal(d.bitDepth, f.bitDepth);
    assert.equal(d.interlaced, true, "金标都是隔行文件，interlaced 必须为 true");
    assert.equal(d.isApng, false);
    assert.deepEqual(Buffer.from(d.pixels), Buffer.from(golden), "每个字节都必须与独立实现相同");
  });

  test(`PNG 金标：${f.name} 非隔行与隔行解出同一份像素（不变量）`, () => {
    const plain = must(decodePng(read(f.plain)));
    const interlaced = must(decodePng(read(f.interlaced)));
    assert.equal(plain.interlaced, false);
    assert.deepEqual(
      Buffer.from(interlaced.pixels),
      Buffer.from(plain.pixels),
      "同一张图的两种扫描线布局必须解出相同像素 —— 不同就说明 pass 布局或 sub-byte 打包错了",
    );
  });

  if (f.samples16 !== undefined) {
    test(`PNG 金标：${f.name} 16 位原值无损（pixels16 == 编码器输入）`, () => {
      const d = must(decodePng(read(f.interlaced), { keep16: true }));
      const p16 = d.pixels16;
      assert.ok(p16 !== undefined, "keep16 必须产出 pixels16");

      const raw = readFileSync(DIR + f.samples16!);
      const samples = new Uint16Array(raw.buffer, raw.byteOffset, raw.byteLength / 2);
      const px = f.width * f.height;

      if (f.colorType === 6) {
        assert.equal(p16.length, samples.length, "RGBA16 的通道数应与输入一致");
        for (let i = 0; i < samples.length; i++) {
          assert.equal(p16[i], samples[i], `第 ${i} 个 16 位样本不相等`);
        }
      } else {
        // colorType 0：输入的 1 个样本要展开到 R/G/B，A 满值（tRNS 不命中）
        assert.equal(samples.length, px);
        for (let i = 0; i < px; i++) {
          assert.equal(p16[i * 4], samples[i], `第 ${i} 像素的 R 原值不相等`);
          assert.equal(p16[i * 4 + 1], samples[i], "灰度要复制到 G");
          assert.equal(p16[i * 4 + 2], samples[i], "灰度要复制到 B");
          assert.equal(p16[i * 4 + 3], 0xffff, "没有 tRNS 命中时 alpha 应为满值");
        }
      }
    });

    test(`PNG 金标：${f.name} RGBA8 与 RGBA16 自一致（pixels[i] == round(pixels16[i]/257)）`, () => {
      const d = must(decodePng(read(f.interlaced), { keep16: true }));
      const p16 = d.pixels16!;
      assert.equal(p16.length, d.pixels.length);
      for (let i = 0; i < d.pixels.length; i++) {
        assert.equal(
          d.pixels[i],
          Math.round(p16[i]! / 257),
          `第 ${i} 个通道：8 位值与 16 位值不满足 round(v/257) 关系（两条路径漂移了）`,
        );
      }
    });
  }
}

test("PNG：keep16 对 8 位图也给出 v*257（任何位深都能进 pixels16）", () => {
  const f = fixtures.find((x) => x.name === "rgba8-13x11")!;
  const d = must(decodePng(read(f.interlaced), { keep16: true }));
  const p16 = d.pixels16!;
  for (let i = 0; i < d.pixels.length; i++) assert.equal(p16[i], d.pixels[i]! * 257);
});

test("PNG：不传 keep16 时 pixels16 为 undefined（不白占内存）", () => {
  const f = fixtures.find((x) => x.name === "rgba8-13x11")!;
  const d = must(decodePng(read(f.interlaced)));
  assert.equal(d.pixels16, undefined);
});

test("PNG：interlace:'reject' 时对隔行图报 ASSET.UNSUPPORTED_INTERLACE", () => {
  const f = fixtures.find((x) => x.name === "rgba8-13x11")!;
  const r = decodePng(read(f.interlaced), { interlace: "reject" });
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, "ASSET.UNSUPPORTED_INTERLACE");
  assert.match(r.error.message, /Adam7|隔行/);
  // 非隔行图不受该选项影响 —— 否则调用方会被迫在"全支持"和"全拒绝"之间二选一
  assert.ok(decodePng(read(f.plain), { interlace: "reject" }).ok);
});
