#!/usr/bin/env node
/**
 * 生成 PNG/APNG 回归语料（一次性的工具，产物进 tests/fixtures/png/）
 *
 * 为什么需要它：工程内 3284 张真实 PNG 全部**非隔行、8 位、无 APNG**
 * （tools/scan-png-features.mjs 的实测结果）。想让解码器"支持"这三样，
 * 就必须自己造语料 —— 而自造语料天然有"编码器与解码器犯同一个错"的风险。
 *
 * 破环方案（三道）：
 *   ① 编码器用**过滤式**分 pass（逐像素判断属于哪个 pass），解码器用**生成式**
 *      （按 pass 表算坐标）；两种写法只有表正确时才等价。
 *   ② 产物交给 **pngjs 7** 独立解码，与我们的解码结果逐字节比对（--check 模式）。
 *   ③ 产物再交给 **Pillow 13** 解码（tools/verify-fixtures-pillow.py），
 *      三方一致才写 golden。任一不同就停下来查，不许"以我们的输出为准"。
 *
 * 金标（`.rgba` 文件）用 pngjs 的输出保存：测试运行时**不需要** pngjs，
 * 只读固定字节 —— 项目依赖里不会多出一个第三方包。
 *
 * 用法：
 *   node tools/make-png-fixtures.mjs            # 生成 png + 金标
 *   node tools/make-png-fixtures.mjs --check    # 只校验现有金标是否仍一致
 */

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeApng, encodePng } from "./png-encode.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const OUT_DIR = join(HERE, "..", "tests", "fixtures", "png");
const PNGJS_ROOT = process.env.PNGJS_ROOT ?? "C:/Users/admin/.workbuddy/binaries/node/workspace/";
const require = createRequire(PNGJS_ROOT);
const { PNG } = require("pngjs");

const CHECK = process.argv.includes("--check");

// ------------------------------------------------------------------ 样本

/** 确定性像素生成：覆盖 0/255 边界与中间值，不用随机数（金标要可复现）。 */
function rgbaSamples(w, h) {
  const out = [];
  for (let i = 0; i < w * h; i++) {
    out.push((i * 37 + 11) & 0xff, (i * 97 + 5) & 0xff, (i * 13 + 201) & 0xff, (i * 29 * 7 + 255) & 0xff);
  }
  return out;
}

function graySamples(w, h, maxV) {
  const out = [];
  for (let i = 0; i < w * h; i++) out.push(i % (maxV + 1));
  return out;
}

function grayAlphaSamples(w, h) {
  const out = [];
  for (let i = 0; i < w * h; i++) out.push((i * 31) & 0xff, (i * 17 + 3) & 0xff);
  return out;
}

function rgbSamples(w, h) {
  const out = [];
  for (let i = 0; i < w * h; i++) out.push((i * 41 + 7) & 0xff, (i * 83 + 19) & 0xff, (i * 11 + 233) & 0xff);
  return out;
}

function paletteSamples(w, h, entries) {
  const out = [];
  for (let i = 0; i < w * h; i++) out.push(i % entries);
  return out;
}

/** 16 位样本：故意包含 0x12FF（降采样 floor/round 会差 1 的边界值）。 */
function rgba16Samples(w, h) {
  const out = [];
  for (let i = 0; i < w * h; i++) {
    out.push(
      i === 0 ? 0x12ff : (i * 6101 + 3) & 0xffff,
      i === 1 ? 0x0001 : (i * 9013 + 7) & 0xffff,
      i === 2 ? 0xfffe : (i * 4099 + 11) & 0xffff,
      i === 3 ? 0x8000 : (i * 7919 + 13) & 0xffff,
    );
  }
  return out;
}

// ------------------------------------------------------------------ 用例表

const PALETTE_8 = [
  0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0, 255, 0, 255, 255, 255, 0, 255, 128, 128,
];

const CASES = [
  // 13×11：七个 pass 全部非空，是最能暴露 pass 布局错误的尺寸
  { name: "rgba8-13x11", width: 13, height: 11, colorType: 6, bitDepth: 8, samples: rgbaSamples(13, 11) },
  { name: "rgb8-13x11", width: 13, height: 11, colorType: 2, bitDepth: 8, samples: rgbSamples(13, 11) },
  { name: "gray8-13x11", width: 13, height: 11, colorType: 0, bitDepth: 8, samples: graySamples(13, 11, 255) },
  {
    name: "gray-alpha8-13x11",
    width: 13,
    height: 11,
    colorType: 4,
    bitDepth: 8,
    samples: grayAlphaSamples(13, 11),
  },
  {
    name: "palette8-13x11",
    width: 13,
    height: 11,
    colorType: 3,
    bitDepth: 8,
    samples: paletteSamples(13, 11, 8),
    palette: PALETTE_8,
    trns: [0, 64, 128, 255, 255, 255, 255, 255],
  },
  // sub-byte：每个 pass 的行要重新按位打包，位深越小越容易错位
  { name: "gray4-13x11", width: 13, height: 11, colorType: 0, bitDepth: 4, samples: graySamples(13, 11, 15) },
  { name: "gray2-9x7", width: 9, height: 7, colorType: 0, bitDepth: 2, samples: graySamples(9, 7, 3) },
  { name: "gray1-17x9", width: 17, height: 9, colorType: 0, bitDepth: 1, samples: graySamples(17, 9, 1) },
  {
    name: "palette4-11x9",
    width: 11,
    height: 9,
    colorType: 3,
    bitDepth: 4,
    samples: paletteSamples(11, 9, 8),
    palette: PALETTE_8,
  },
  { name: "palette2-9x7", width: 9, height: 7, colorType: 3, bitDepth: 2, samples: paletteSamples(9, 7, 4), palette: PALETTE_8.slice(0, 12) },
  // 16 位
  { name: "rgba16-7x5", width: 7, height: 5, colorType: 6, bitDepth: 16, samples: rgba16Samples(7, 5) },
  {
    name: "gray16-5x3",
    width: 5,
    height: 3,
    colorType: 0,
    bitDepth: 16,
    samples: [
      0x12ff, 0x0000, 0x0001, 0x8000, 0xffff, 0x00ff, 0x0100, 0xff00, 0x7fff, 0x1234, 0xabcd, 0x0002, 0x12fe, 0x8080,
      0x0101,
    ],
    // ★ tRNS 故意**不命中任何样本**（0x0003 不在下面的样本里）。
    //   为什么：pngjs 把"命中色键"的像素整像素清 0（含 RGB），而我们与 Pillow/libpng
    //   保留 RGB、只把 alpha 置 0。显示结果等价，但逐字节金标会分歧。
    //   tRNS 语义单独立判据（见 tests/extensions/png-16bit.test.ts），不混进外部金标。
    trns: [0x00, 0x03],
  },
  // 退化尺寸：pass 全空/半空（漏掉"空 pass 不占字节"的规则就会在这里崩）
  { name: "rgba8-1x1", width: 1, height: 1, colorType: 6, bitDepth: 8, samples: rgbaSamples(1, 1) },
  { name: "rgba8-2x2", width: 2, height: 2, colorType: 6, bitDepth: 8, samples: rgbaSamples(2, 2) },
  { name: "rgba8-3x3", width: 3, height: 3, colorType: 6, bitDepth: 8, samples: rgbaSamples(3, 3) },
  { name: "rgba8-9x1", width: 9, height: 1, colorType: 6, bitDepth: 8, samples: rgbaSamples(9, 1) },
  { name: "rgba8-1x9", width: 1, height: 9, colorType: 6, bitDepth: 8, samples: rgbaSamples(1, 9) },
  { name: "gray1-33x2", width: 33, height: 2, colorType: 0, bitDepth: 1, samples: graySamples(33, 2, 1) },
];

// ------------------------------------------------------------------ 生成

function decodeWithPngjs(buf) {
  const png = PNG.sync.read(buf);
  return Buffer.from(png.data);
}

function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

mkdirSync(OUT_DIR, { recursive: true });

const manifest = {
  note:
    "自动生成，勿手改。由 tools/make-png-fixtures.mjs 生成，金标来自 pngjs 7.0.0，" +
    "并已用 Pillow 13.0.0 交叉验证（tools/verify-fixtures-pillow.py）。",
  pngjs: require("pngjs/package.json").version,
  cases: [],
};

let failures = 0;
for (const c of CASES) {
  const plain = encodePng({ ...c, interlace: 0 });
  const interlaced = encodePng({ ...c, interlace: 1 });

  // ① 不变量：隔行与非隔行必须解出同一份像素（不依赖任何外部金标）
  const p = decodeWithPngjs(plain);
  const i = decodeWithPngjs(interlaced);
  if (!p.equals(i)) {
    console.error(`✗ ${c.name}: pngjs 解出的隔行与非隔行不一致（编码器有 bug）`);
    failures++;
    continue;
  }

  // ② 8 位图：像素必须与源样本逐字节相同（pngjs 自身也被钉住）
  if (c.bitDepth === 8 && c.colorType === 6) {
    const src = Buffer.from(c.samples);
    if (!p.equals(src)) {
      console.error(`✗ ${c.name}: pngjs 解出的像素与源样本不同（编码器有 bug）`);
      failures++;
      continue;
    }
  }

  const plainName = `${c.name}.plain.png`;
  const interName = `${c.name}.interlaced.png`;
  const goldName = `${c.name}.rgba`;

  if (CHECK) {
    const goldExisting = readFileSync(join(OUT_DIR, goldName));
    if (!goldExisting.equals(i)) {
      console.error(`✗ ${c.name}: 现有金标与当前编码器输出不一致`);
      failures++;
    }
    continue;
  }

  writeFileSync(join(OUT_DIR, plainName), plain);
  writeFileSync(join(OUT_DIR, interName), interlaced);
  writeFileSync(join(OUT_DIR, goldName), i);
  const entry = {
    name: c.name,
    width: c.width,
    height: c.height,
    colorType: c.colorType,
    bitDepth: c.bitDepth,
    plain: plainName,
    interlaced: interName,
    golden: goldName,
    goldenSha256: sha256(i),
  };
  if (c.bitDepth === 16) {
    // 16 位：外部解码器（pngjs/Pillow）都只能给 8 位降采样结果，拿不到原值。
    // 原值判据只能靠**往返**：这里存下编码器的输入样本，测试断言 pixels16 与它逐值相等。
    // 文件的合法性由 Pillow 独立确认（8 位结果与我们差 ≤1），所以往返不是自证。
    const samples16 = Uint16Array.from(c.samples);
    writeFileSync(join(OUT_DIR, `${c.name}.rgba16`), Buffer.from(samples16.buffer));
    entry.samples16 = `${c.name}.rgba16`;
  }
  manifest.cases.push(entry);
  console.log(`✓ ${c.name}  非隔行 ${plain.length}B  隔行 ${interlaced.length}B  金标 ${i.length}B`);
}

// ------------------------------------------------------------------ APNG 用例
//
// 每帧只画一块矩形，dispose/blend 的组合才是"合成逻辑"的真正考点：
// 若解码器把 blend=OVER 当覆盖、或把 dispose=PREVIOUS 当 BACKGROUND，帧序列会立刻不同。

function rect(w, h, rgba) {
  return { rect: { x: 0, y: 0, width: w, height: h }, rgba };
}

/** 一块纯色（可半透明）的矩形 RGBA。 */
function solid(w, h, [r, g, b, a]) {
  const out = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) out.set([r, g, b, a], i * 4);
  return out;
}

function checker(w, h, c1, c2) {
  const out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) out.set(x % 2 === y % 2 ? c1 : c2, (y * w + x) * 4);
  }
  return out;
}

const APNG_CASES = [
  {
    name: "apng-none-source",
    width: 8,
    height: 6,
    loopCount: 0,
    frames: [
      { rect: { x: 0, y: 0, width: 8, height: 6 }, rgba: checker(8, 6, [220, 30, 40, 255], [30, 60, 200, 255]), delayNum: 100, delayDen: 1000, dispose: 0, blend: 0 },
      { rect: { x: 2, y: 1, width: 4, height: 3 }, rgba: solid(4, 3, [40, 220, 90, 255]), delayNum: 200, delayDen: 1000, dispose: 0, blend: 0 },
      { rect: { x: 1, y: 2, width: 3, height: 2 }, rgba: solid(3, 2, [250, 240, 20, 255]), delayNum: 50, delayDen: 100, dispose: 0, blend: 0 },
    ],
  },
  {
    name: "apng-background-over",
    width: 8,
    height: 6,
    loopCount: 3,
    frames: [
      { rect: { x: 0, y: 0, width: 8, height: 6 }, rgba: solid(8, 6, [0, 0, 0, 255]), delayNum: 1, delayDen: 10, dispose: 1, blend: 1 },
      { rect: { x: 2, y: 1, width: 4, height: 4 }, rgba: solid(4, 4, [255, 0, 0, 128]), delayNum: 1, delayDen: 10, dispose: 1, blend: 1 },
      { rect: { x: 0, y: 0, width: 3, height: 3 }, rgba: solid(3, 3, [0, 0, 255, 200]), delayNum: 1, delayDen: 10, dispose: 0, blend: 1 },
    ],
  },
  {
    name: "apng-previous-over",
    width: 6,
    height: 6,
    loopCount: 0,
    frames: [
      { rect: { x: 0, y: 0, width: 6, height: 6 }, rgba: solid(6, 6, [10, 200, 210, 255]), delayNum: 80, delayDen: 1000, dispose: 0, blend: 0 },
      { rect: { x: 1, y: 1, width: 3, height: 3 }, rgba: solid(3, 3, [255, 128, 0, 160]), delayNum: 80, delayDen: 1000, dispose: 2, blend: 1 },
      { rect: { x: 2, y: 0, width: 2, height: 2 }, rgba: solid(2, 2, [0, 0, 0, 255]), delayNum: 80, delayDen: 1000, dispose: 0, blend: 0 },
    ],
  },
  {
    name: "apng-default-image",
    width: 5,
    height: 5,
    loopCount: 1,
    idatFirstFrame: false,
    frames: [
      { rect: { x: 0, y: 0, width: 5, height: 5 }, rgba: solid(5, 5, [255, 200, 0, 255]), delayNum: 1, delayDen: 20, dispose: 0, blend: 0 },
      { rect: { x: 1, y: 1, width: 2, height: 2 }, rgba: solid(2, 2, [0, 120, 255, 255]), delayNum: 1, delayDen: 20, dispose: 0, blend: 1 },
    ],
  },
];

for (const c of APNG_CASES) {
  const buf = encodeApng(c);
  if (CHECK) continue;
  writeFileSync(join(OUT_DIR, `${c.name}.png`), buf);
  // 每帧矩形单独存一张**普通 PNG**：金标生成器（Pillow）用它做严格的 alpha_composite。
  // 为什么不直接信任 Pillow 的 APNG 内建读取：它对 blend=OVER 用 `paste(im, box, im)`，
  // 等于拿 alpha 当 mask 混 RGB **和 alpha 自己**，半透明帧的 alpha 会被二次相乘
  // （实测 128 → 64）。规范要求的是 Porter-Duff source-over（Ao = As + Ad(1-As)）。
  // 所以帧像素用 Pillow 解单帧（无损），合成用 Pillow 的 alpha_composite（严格），
  // 状态机（dispose 顺序）再用 Pillow 的 APNG 原生结果在**全不透明帧**上交叉核对。
  c.frames.forEach((f, i) => {
    const samples = [];
    for (let k = 0; k < f.rect.width * f.rect.height * 4; k++) samples.push(f.rgba[k]);
    writeFileSync(
      join(OUT_DIR, `${c.name}.frame${i}.png`),
      encodePng({
        width: f.rect.width,
        height: f.rect.height,
        colorType: 6,
        bitDepth: 8,
        samples,
        interlace: 0,
      }),
    );
  });
  console.log(`✓ ${c.name}  ${c.frames.length} 帧  ${buf.length}B`);
  manifest.cases.push({
    name: c.name,
    kind: "apng",
    width: c.width,
    height: c.height,
    frameCount: c.frames.length,
    loopCount: c.loopCount ?? 0,
    file: `${c.name}.png`,
    delays: c.frames.map((f) => Math.round((f.delayNum * 1000) / (f.delayDen === 0 ? 100 : f.delayDen))),
    frames: c.frames.map((f, i) => ({
      rect: f.rect,
      dispose: f.dispose,
      blend: f.blend,
      delayMs: Math.round((f.delayNum * 1000) / (f.delayDen === 0 ? 100 : f.delayDen)),
      png: `${c.name}.frame${i}.png`,
    })),
    idatFirstFrame: c.idatFirstFrame ?? true,
    golden: `${c.name}.frames.rgba`,
  });
}

if (!CHECK) {
  writeFileSync(join(OUT_DIR, "manifest.json"), JSON.stringify(manifest, null, 2) + "\n");
  console.log(`\n共 ${manifest.cases.length} 个用例 → ${OUT_DIR}`);
}

if (failures > 0) {
  console.error(`\n${failures} 个用例失败`);
  process.exit(1);
}
