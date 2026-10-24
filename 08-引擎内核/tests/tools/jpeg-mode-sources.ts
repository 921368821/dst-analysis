/**
 * 测试语料源生成器：用**本仓库的编码器**产出算术编码（SOF9/SOF10）与分层（SOF5/SOF7）样本。
 *
 * ★ 为什么这两类语料必须自己编：
 *   没有任何第三方编码器能产出算术 JPEG（Pillow 不暴露 arith_code，
 *   imagecodecs 的 jpeg8_encode 也没有这个参数），也没有任何第三方实现支持分层。
 *   所以"外部金标"只能反过来做：**我们编码 → 别人解码**。
 *   libjpeg-turbo 的算术解码器是独立实现，它能解开我们的流、并且解出来的像素
 *   与 baseline 完全一致，就同时证明了两件事：
 *     1. 我们的算术**编码器**产出了合规的流（否则 libjpeg 解不开或解错）；
 *     2. 我们的算术**解码器**与 libjpeg 的算术解码器在同一份流上得到相同结果
 *        （金标就是 libjpeg 对同一个文件的解码像素）。
 *   分层没有这一步：libjpeg 连解析都不做，所以分层语料不进 `tests/fixtures/jpeg/`，
 *   只在 `tests/extensions/jpeg-modes.test.ts` 里做进程内回环 —— 目录里只放"有外部参照"的文件。
 *
 * 用法（由 tools/make-jpeg-fixtures.py 自动调用，也可单独跑）：
 *   node --experimental-transform-types tests/tools/jpeg-mode-sources.ts --out tests/fixtures/jpeg
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { encodeJpeg } from "./jpeg-encode.ts";
import type { EncodeSpec } from "./jpeg-encode.ts";

const args = process.argv.slice(2);
const outIdx = args.indexOf("--out");
const outDir = outIdx >= 0 ? args[outIdx + 1]! : "tests/fixtures/jpeg";
const W = 40;
const H = 30;

/** 与 tools/make-jpeg-fixtures.py 的 smooth_image 同族：低频渐变 + 轻微波纹。 */
function smoothGray(): Uint16Array {
  const a = new Uint16Array(W * H);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) a[y * W + x] = Math.round(((Math.sin(x * 0.2) + Math.cos(y * 0.15) + 2) / 4) * 255);
  }
  return a;
}

/** 硬边 + 高饱和色块：色度 AC 更丰富，算术 AC 模型的幅度类别会走得更深。 */
function edgedRgb(): Uint16Array {
  const a = new Uint16Array(W * H * 3);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 3;
      const inBlock = (x >> 3) + (y >> 3);
      let r = 250;
      let g = 250;
      let b = 250;
      if (inBlock % 2 === 0) {
        r = 220;
        g = 20;
        b = 30;
      } else if (x < W / 3) {
        r = 10;
        g = 200;
        b = 60;
      } else if (y > (H * 2) / 3) {
        r = 20;
        g = 40;
        b = 230;
      }
      if (x === y) {
        r = 0;
        g = 0;
        b = 0;
      }
      a[o] = r;
      a[o + 1] = g;
      a[o + 2] = b;
    }
  }
  return a;
}

/**
 * 4 分量（反相 CMYK）样本。K 通道**必须变化**：
 * 解码端的公式是 `RGB = 存储值 × K' / maxval`，K' 恒等于 maxval 时乘法那一支
 * 退化成直通，"把 K 当 255 用"这类错误就测不出来。
 */
function cmykSamples(): Uint16Array {
  const a = new Uint16Array(W * H * 4);
  const clamp = (v: number): number => (v < 0 ? 0 : v > 255 ? 255 : Math.round(v));
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 4;
      a[o] = clamp(180 + 70 * Math.sin(x * 0.2)); // 反相 C
      a[o + 1] = clamp(150 + 90 * Math.cos(y * 0.15)); // 反相 M
      a[o + 2] = clamp(((x + y) / (W + H)) * 255); // 反相 Y
      a[o + 3] = clamp(120 + ((x * 7 + y * 11) % 136)); // 反相 K：120..255
    }
  }
  return a;
}

const base = { width: W, height: H, precision: 8, quality: 92, subsampling: "444" } as const;

const cases: ReadonlyArray<readonly [string, EncodeSpec, Uint16Array]> = [
  ["arith-seq-gray", { ...base, components: 1, mode: "arith-sequential" }, smoothGray()],
  ["arith-seq-rgb", { ...base, components: 3, mode: "arith-sequential" }, edgedRgb()],
  ["arith-prog-gray", { ...base, components: 1, mode: "arith-progressive" }, smoothGray()],
  ["arith-prog-rgb", { ...base, components: 3, mode: "arith-progressive" }, edgedRgb()],
  ["arith-seq-gray-dac", { ...base, components: 1, mode: "arith-sequential", dac: true }, smoothGray()],
  ["arith-seq-gray-rst", { ...base, components: 1, mode: "arith-sequential", restart: 2 }, smoothGray()],
  // 4 分量：transform=0 是 CMYK 直通，transform=2 是 YCCK（Y/Cb/Cr 编码墨量）。
  // 两者都必须被 libjpeg 解出接近原图的像素 —— 金标就是 libjpeg 对同一个文件的解码。
  ["cmyk-baseline", { ...base, components: 4, mode: "baseline", adobeTransform: 0 }, cmykSamples()],
  ["ycck-baseline", { ...base, components: 4, mode: "baseline", adobeTransform: 2 }, cmykSamples()],
  ["cmyk-arith", { ...base, components: 4, mode: "arith-sequential", adobeTransform: 0 }, cmykSamples()],
  ["ycck-arith", { ...base, components: 4, mode: "arith-sequential", adobeTransform: 2 }, cmykSamples()],
  // ★ 哈夫曼模式的"我们编码 → libjpeg 解码"。
  //   之前这一向只有算术语料有：Pillow 编的 17 个语料证明的是"我们能解别人的流"，
  //   而"别人能解我们的流"是另一件事 —— 它才管编码器是否合规：
  //   采样因子写错、右边界填充方式不同、扫描脚本不合法，都会在这里暴露，
  //   而**我们自己的解码器看不出来**（它会老实按我们写的东西解）。
  ["selfenc-444", { ...base, components: 3, mode: "baseline", subsampling: "444" }, edgedRgb()],
  ["selfenc-420", { ...base, components: 3, mode: "baseline", subsampling: "420" }, edgedRgb()],
  ["selfenc-422", { ...base, components: 3, mode: "baseline", subsampling: "422" }, edgedRgb()],
  ["selfenc-prog-420", { ...base, components: 3, mode: "progressive", subsampling: "420" }, edgedRgb()],
  ["selfenc-rst-420", { ...base, components: 3, mode: "baseline", subsampling: "420", restart: 2 }, edgedRgb()],
  ["selfenc-gray", { ...base, components: 1, mode: "baseline" }, smoothGray()],
];

mkdirSync(outDir, { recursive: true });
for (const [name, spec, samples] of cases) {
  const bytes = encodeJpeg(samples, spec);
  writeFileSync(join(outDir, `${name}.jpg`), bytes);
  process.stdout.write(`  ${name} ${bytes.length}B\n`);
}
// 把"我写了哪些文件"告诉 make-jpeg-fixtures.py：
// 容差表在 Python 那边（它负责定阈值），但**文件清单以这里为准**，
// 两边各写一份清单一定会漂移 —— 漂移之后就是"新加的语料没人判"。
writeFileSync(
  join(outDir, "_selfenc.json"),
  JSON.stringify(cases.map(([name, spec]) => ({ name, mode: spec.mode, components: spec.components })), null, 1),
);
process.stdout.write(`写入 ${cases.length} 个自产语料到 ${outDir}\n`);
