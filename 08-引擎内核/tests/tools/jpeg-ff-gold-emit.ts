/**
 * ffmpeg 外部金标 · 语料生成器（只负责把 .jpg 写出来）
 *
 * 分工：
 *   这里（node）= 用**本仓库的编码器**产出流；`pix_fmt` 由 Python 那边决定，这里不管。
 *   `tools/jpeg-ffmpeg-gold.py` = 调本脚本 → 调 ffmpeg 解码 → 落 gold。
 *
 * 为什么要拆开：ffmpeg 解出来的才是金标，而"编码器产流"这一步必须能在 node 里跑
 * （编码器是 TS）。拆开之后 Python 只做"跑进程 + 存字节"，不重复实现编码。
 *
 * 用法（由 tools/jpeg-ffmpeg-gold.py 自动调用，也可单独跑）：
 *   node --experimental-transform-types tests/tools/jpeg-ff-gold-emit.ts --out tests/fixtures/jpeg/ff
 */

import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { encodeJpeg } from "./jpeg-encode.ts";
import { FF_GOLD_CASES } from "./jpeg-ff-gold-cases.ts";

const args = process.argv.slice(2);
function argOf(flag: string, fallback: string): string {
  const i = args.indexOf(flag);
  if (i < 0) return fallback;
  const v = args[i + 1];
  if (v === undefined) throw new Error(`${flag} 后面必须跟一个值`);
  return v;
}

const outDir = argOf("--out", "tests/fixtures/jpeg/ff");
const srcOut = args.includes("--src-out") ? argOf("--src-out", "") : null;
const metaOut = args.includes("--meta-out") ? argOf("--meta-out", "") : null;
mkdirSync(outDir, { recursive: true });
if (srcOut !== null) mkdirSync(srcOut, { recursive: true });

const meta: Array<Record<string, unknown>> = [];
for (const c of FF_GOLD_CASES) {
  const bytes = encodeJpeg(c.samples, c.spec);
  writeFileSync(join(outDir, `${c.name}.jpg`), bytes);
  if (srcOut !== null) {
    // 源样本落盘给 Python 侧自检用（"ffmpeg 解出来的 == 源"是这条链的第一环）
    const buf = Buffer.from(c.samples.buffer, c.samples.byteOffset, c.samples.byteLength);
    writeFileSync(join(srcOut, `${c.name}.src.u16`), buf);
  }
  meta.push({
    name: c.name,
    width: c.width,
    height: c.height,
    components: c.components,
    precision: c.precision,
    kind: c.kind,
    bytes: bytes.length,
  });
  console.log(`${c.name}: ${bytes.length} B  ${c.width}x${c.height}x${c.components} ${c.precision}bit ${c.spec.mode}`);
}

// ★ 案例表(宽/高/分量/精度)只写在这里，Python 侧读它，**不许两边各推一遍** ——
//   上一版 Python 用"名字里有没有 37x23"猜尺寸，改名就静默错。
if (metaOut !== null) writeFileSync(metaOut, JSON.stringify(meta, null, 2) + "\n");
