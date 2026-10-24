/**
 * 大规模离线差分对照 · 我们的解码器 vs Pillow(libjpeg-turbo)
 *
 * 用法：
 *   python tools/jpeg-diff-sweep.py --out .cache/jpeg-sweep     # 先产包（要 Pillow）
 *   node   tools/jpeg-diff-sweep.mjs .cache/jpeg-sweep          # 再比对（只要 node）
 *
 * ★ 这是"测分布"的工具，不是 CI 判据：
 *   CI 判据是 14 个固定语料 + manifest 里的容差（tests/extensions/jpeg.test.ts）。
 *   本工具的产出是**一张分布表**，用来回答两个 CI 判据回答不了的问题：
 *     ① 现有容差是"实测"还是"恰好够用"？——看 p99 和峰值有没有超过它；
 *     ② 长尾出现在哪个角落？——按 (通道结构 × 子采样 × 质量 × 渐进 × 重启) 分桶，
 *        哪个桶的峰值明显高于同尺寸其他桶，就是那条路径没被固定语料覆盖。
 *
 * ★ 为什么这个对照器自己也要做自检（--self-check 默认开）：
 *   一个"永远报很小的差"的比较器是最危险的假绿灯——
 *   它可以是索引错位、可以是只比了第一个像素、也可以是两边读了同一份缓冲。
 *   做法：把我们的输出整体 +8 再比一遍，报告的峰值必须**随之抬到 ≥8**。
 *   抬不动，就说明这个比较器根本没看到像素差异，表上的数字全部作废。
 *
 * ★ 为什么不把这几百个用例也塞进仓库：
 *   金标是未压缩 RGBA，上千个加起来十几 MB，进 git 之后每次 clone 都要背。
 *   固定语料负责"每次都判"，这个负责"按需测分布"，两者不重复。
 */

import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { decodeJpeg } from "../src/extensions/asset-import/decode/jpeg.ts";

const dir = process.argv[2];
if (!dir) {
  console.error("用法: node tools/jpeg-diff-sweep.mjs <sweep 目录> [报告 json]");
  process.exit(2);
}

const manifest = JSON.parse(readFileSync(join(dir, "sweep.json"), "utf8"));

/** 分桶维度：都是会改变解码路径的东西。 */
const DIFF_FIELDS = ["mode", "sampling", "quality", "progressive", "restartRows", "pattern"];

/**
 * 逐通道差异：max 用于"最坏像素"，mean 用于"整幅偏了多少"。
 * `shiftR` 只挪 R 通道，用来自检（见文件头）。
 */
function diff(a, b, shiftR = 0) {
  if (a.length !== b.length) throw new Error(`像素长度不同: ${a.length} vs ${b.length}`);
  let max = 0;
  let sum = 0;
  let differing = 0;
  for (let i = 0; i < a.length; i++) {
    const av = shiftR !== 0 && i % 4 === 0 ? Math.min(255, a[i] + shiftR) : a[i];
    const d = Math.abs(av - b[i]);
    if (d !== 0) differing++;
    if (d > max) max = d;
    sum += d;
  }
  return { max, mean: sum / a.length, differing };
}

function pct(sorted, p) {
  if (sorted.length === 0) return 0;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.round((p / 100) * (sorted.length - 1))));
  return sorted[i];
}

const decoded = [];
for (const c of manifest.cases) {
  const src = new Uint8Array(readFileSync(join(dir, c.file)));
  const golden = new Uint8Array(readFileSync(join(dir, c.golden)));
  const r = decodeJpeg(src);
  if (!r.ok) {
    decoded.push({ c, golden, failed: `${r.error.code}: ${r.error.message}` });
    continue;
  }
  const d = r.value;
  if (d.width !== c.width || d.height !== c.height) {
    decoded.push({ c, golden, failed: `尺寸不符: 解出 ${d.width}x${d.height}，SOF 声明 ${c.width}x${c.height}` });
    continue;
  }
  if (d.pixels.length !== golden.length) {
    decoded.push({ c, golden, failed: `像素长度不符: 解出 ${d.pixels.length}，金标 ${golden.length}` });
    continue;
  }
  decoded.push({ c, golden, pixels: d.pixels, failed: null });
}

const failed = decoded.filter((r) => r.failed);
if (failed.length > 0) {
  console.error(`✗ ${failed.length} 个用例解码失败或尺寸/长度不符：`);
  for (const f of failed.slice(0, 20)) console.error(`   ${f.c.note} → ${f.failed}`);
  process.exit(1);
}

// ---------------------------------------------------------------- 比较器自检
// 先跑：把输出整体 +8，峰值必须抬起来。否则后面的表全是假的。
const SHIFT = 8;
let selfMax = 0;
for (const r of decoded.slice(0, Math.min(200, decoded.length))) {
  const st = diff(r.pixels, r.golden, SHIFT);
  if (st.max > selfMax) selfMax = st.max;
}
if (selfMax < SHIFT) {
  console.error(
    `✗ 比较器自检失败：把输出整体 +${SHIFT} 之后峰值只有 ${selfMax}，` +
      `说明它没在看像素（索引错位？两边读了同一份缓冲？）—— 后面的分布表一律作废`,
  );
  process.exit(1);
}

const rows = decoded.map((r) => ({ ...r.c, ...diff(r.pixels, r.golden) }));

function bucket(rowsIn, keys) {
  const map = new Map();
  for (const r of rowsIn) {
    const k = keys.map((f) => `${f}=${r[f]}`).join(" ");
    if (!map.has(k)) map.set(k, []);
    map.get(k).push(r);
  }
  return map;
}

function table(title, map) {
  console.log(`\n${title}`);
  console.log(
    "  " +
      "分组".padEnd(44) +
      "n".padStart(5) +
      "  max".padStart(6) +
      "  p99".padStart(6) +
      "  p50".padStart(6) +
      "   mean".padStart(8) +
      "  差异样本".padStart(10),
  );
  for (const [k, list] of [...map.entries()].sort()) {
    const maxes = list.map((r) => r.max).sort((a, b) => a - b);
    const means = list.map((r) => r.mean).sort((a, b) => a - b);
    const worstCase = list.reduce((a, b) => (a.max >= b.max ? a : b));
    const share = list.reduce((s, r) => s + r.differing, 0) / list.reduce((s, r) => s + r.width * r.height * 4, 0);
    console.log(
      "  " +
        k.padEnd(42) +
        String(list.length).padStart(5) +
        String(maxes[maxes.length - 1]).padStart(6) +
        String(pct(maxes, 99)).padStart(6) +
        String(pct(maxes, 50)).padStart(6) +
        means[means.length - 1].toFixed(3).padStart(8) +
        (share * 100).toFixed(1).padStart(9) +
        "%",
    );
    if (maxes[maxes.length - 1] >= 6) console.log(`      最差: ${worstCase.note}`);
  }
}

const allMax = rows.map((r) => r.max).sort((a, b) => a - b);
const allMean = rows.map((r) => r.mean).sort((a, b) => a - b);

console.log(`用例 ${rows.length} 个（${manifest.generator} / ${manifest.reference}）`);
console.log(`比较器自检：输出整体 +${SHIFT} 后峰值 = ${selfMax}（≥${SHIFT} 即敏感）`);
console.log(
  `总体 max：p99 ${pct(allMax, 99)} / 中位 ${pct(allMax, 50)} / 峰值 ${allMax[allMax.length - 1]}；` +
    ` mean 峰值 ${allMean[allMean.length - 1].toFixed(3)} / 中位 ${pct(allMean, 50).toFixed(3)}`,
);

table("按通道结构", bucket(rows, ["mode"]));
table("按子采样", bucket(rows, ["sampling"]));
table("按子采样 × 渐进 × 重启", bucket(rows, ["sampling", "progressive", "restartRows"]));
table("按质量", bucket(rows, ["quality"]));
table("按内容", bucket(rows, ["pattern"]));

const worst = rows.reduce((a, b) => (a.max >= b.max ? a : b));
console.log(`\n最差用例: ${worst.note}  max=${worst.max} mean=${worst.mean.toFixed(3)}`);

const out = process.argv[3];
if (out) {
  writeFileSync(
    out,
    JSON.stringify(
      {
        generator: manifest.generator,
        reference: manifest.reference,
        count: rows.length,
        selfCheckShift: SHIFT,
        selfCheckPeak: selfMax,
        maxPeak: allMax[allMax.length - 1],
        meanPeak: Number(allMean[allMean.length - 1].toFixed(4)),
        p99Max: pct(allMax, 99),
        medianMax: pct(allMax, 50),
        cases: rows.map((r) => ({
          note: r.note,
          ...Object.fromEntries(DIFF_FIELDS.map((f) => [f, r[f]])),
          max: r.max,
          mean: Number(r.mean.toFixed(4)),
        })),
      },
      null,
      1,
    ),
  );
  console.log(`分布已写入 ${out}`);
}
