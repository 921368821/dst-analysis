#!/usr/bin/env node
/**
 * 真实 PNG 语料验证（工具的判据，不是引擎的一部分）
 *
 * 做两级验证：
 *   ① **全量结构校验**：签名、块序列、每块 CRC、IHDR 组合合法性、IDAT/IEND 存在与顺序。
 *      这一级很便宜（只读文件 + 线性扫块），可以覆盖 3000+ 张。
 *   ② **抽样完整解码**：真正 inflate + 反滤波 + 转 RGBA8，断言宽高与头一致。
 *      默认每 20 张取 1 张；`--limit N` 限制解码张数；`--all` 全量解码。
 *
 * ★ 内存：单个最大 2048×2048（RGBA 16 MB），**逐个解码后立刻丢弃**。
 *   绝不把解码结果放进数组 —— 全量 3367 张累积会直接 OOM，而 OOM 会伪装成
 *   "脚本卡住"，浪费半天。
 *
 * ★ 运行方式：`node tools/verify-png-corpus.mjs`。本脚本依赖 `decode/png.ts`
 *   （TS 源码），而 Node 22 需要 `--experimental-transform-types` 才能直接跑 TS。
 *   为了不让调用方记这个旗标，脚本会在缺少旗标时**用旗标重启自己**，
 *   保证导出给 CI/人的命令始终是上面那一条。
 */

import { spawnSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const TS_FLAG = "--experimental-transform-types";
if (!process.execArgv.includes(TS_FLAG)) {
  const self = fileURLToPath(import.meta.url);
  const r = spawnSync(process.execPath, [TS_FLAG, self, ...process.argv.slice(2)], { stdio: "inherit" });
  process.exit(r.status === null ? 1 : r.status);
}

const HERE = fileURLToPath(new URL(".", import.meta.url));
const DEFAULT_ROOT = fileURLToPath(new URL("../..", import.meta.url));
const { decodePng } = await import(pathToFileURL(join(HERE, "..", "src", "extensions", "asset-import", "decode", "png.ts")).href);

// ------------------------------------------------------------------ 参数

const args = process.argv.slice(2);
function argValue(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}
const ROOT = argValue("--root", DEFAULT_ROOT);
const ALL = args.includes("--all");
const EVERY = Number.parseInt(argValue("--every", "20"), 10);
const LIMIT = Number.parseInt(argValue("--limit", String(Number.MAX_SAFE_INTEGER)), 10);

if (!Number.isInteger(EVERY) || EVERY < 1) {
  console.error(`--every 必须是 ≥1 的整数，收到 ${argValue("--every", "")}`);
  process.exit(2);
}

// ------------------------------------------------------------------ 文件收集

function walk(dir, out) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    console.error(`跳过不可读目录 ${dir}：${e instanceof Error ? e.message : String(e)}`);
    return;
  }
  for (const ent of entries) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) {
      if (ent.name === "node_modules" || ent.name === ".git") continue;
      walk(p, out);
    } else if (ent.name.toLowerCase().endsWith(".png")) {
      out.push(p);
    }
  }
}

const files = [];
walk(ROOT, files);
files.sort();

// ------------------------------------------------------------------ 结构校验

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

// Node ≥22.2 自带 crc32（原生，比 JS 表快一个数量级）；没有就退回本地实现。
const nodeCrc32 = typeof (await import("node:zlib")).crc32 === "function" ? (await import("node:zlib")).crc32 : null;

function crc32(b, from, to) {
  if (nodeCrc32 !== null) return nodeCrc32(b.subarray(from, to)) >>> 0;
  let c = 0xffffffff;
  for (let i = from; i < to; i++) c = CRC_TABLE[(c ^ b[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function u32be(b, at) {
  return ((b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]) >>> 0;
}

const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const LEGAL = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };

function checkStructure(bytes) {
  if (bytes.length < 8) return { ok: false, error: `过短（${bytes.length} 字节）` };
  for (let i = 0; i < 8; i++) if (bytes[i] !== SIGNATURE[i]) return { ok: false, error: "签名不匹配" };

  let at = 8;
  let header = null;
  let idat = 0;
  let iend = false;
  let iendEnd = -1;
  let first = true;

  while (at < bytes.length) {
    if (at + 8 > bytes.length) return { ok: false, error: `块头截断@${at}` };
    const len = u32be(bytes, at);
    const type = String.fromCharCode(bytes[at + 4], bytes[at + 5], bytes[at + 6], bytes[at + 7]);
    if (len > 0x7fffffff) return { ok: false, error: `块 ${type} 长度非法 ${len}` };
    const dataStart = at + 8;
    const crcAt = dataStart + len;
    if (crcAt + 4 > bytes.length) return { ok: false, error: `块 ${type} 越界（截断）@${at}` };
    if (crc32(bytes, at + 4, crcAt) !== u32be(bytes, crcAt)) return { ok: false, error: `块 ${type} CRC 错误@${at}` };

    if (first) {
      if (type !== "IHDR") return { ok: false, error: `首块是 ${type} 而不是 IHDR` };
      if (len !== 13) return { ok: false, error: `IHDR 长度 ${len}` };
      const width = u32be(bytes, dataStart);
      const height = u32be(bytes, dataStart + 4);
      const bitDepth = bytes[dataStart + 8];
      const colorType = bytes[dataStart + 9];
      const compression = bytes[dataStart + 10];
      const filter = bytes[dataStart + 11];
      const interlace = bytes[dataStart + 12];
      if (width === 0 || height === 0) return { ok: false, error: `宽高为 0（${width}×${height}）` };
      if (compression !== 0) return { ok: false, error: `compression=${compression}` };
      if (filter !== 0) return { ok: false, error: `filter=${filter}` };
      if (interlace !== 0 && interlace !== 1) return { ok: false, error: `interlace=${interlace}` };
      if (!LEGAL[colorType]) return { ok: false, error: `colorType=${colorType}` };
      if (!LEGAL[colorType].includes(bitDepth)) {
        return { ok: false, error: `colorType=${colorType}/bitDepth=${bitDepth} 组合非法` };
      }
      header = { width, height, bitDepth, colorType, interlace };
      first = false;
    } else if (type === "IDAT") {
      idat++;
    } else if (type === "IEND") {
      if (len !== 0) return { ok: false, error: `IEND 长度 ${len}` };
      iend = true;
      iendEnd = crcAt + 4;
      break;
    } else if ((bytes[at + 4] & 0x20) === 0) {
      return { ok: false, error: `未知关键块 ${type}` };
    }
    at = crcAt + 4;
  }

  if (header === null) return { ok: false, error: "没有 IHDR" };
  if (!iend) return { ok: false, error: "缺少 IEND" };
  if (iendEnd !== bytes.length) return { ok: false, error: `IEND 之后有 ${bytes.length - iendEnd} 字节` };
  if (idat === 0) return { ok: false, error: "没有 IDAT" };
  return { ok: true, header, idat };
}

// ------------------------------------------------------------------ 主流程

const t0 = Date.now();
console.log(`语料根：${ROOT}`);
console.log(`PNG 总数：${files.length}`);

let structOk = 0;
const structFails = [];
const colors = new Map();
const interlace = new Map();
let maxW = 0;
let maxH = 0;
let maxPath = "";

for (const p of files) {
  let bytes;
  try {
    bytes = new Uint8Array(readFileSync(p));
  } catch (e) {
    structFails.push({ path: p, error: `读取失败：${e instanceof Error ? e.message : String(e)}` });
    continue;
  }
  const r = checkStructure(bytes);
  if (!r.ok) {
    structFails.push({ path: p, error: r.error });
    continue;
  }
  structOk++;
  const h = r.header;
  const key = `colorType=${h.colorType}/bitDepth=${h.bitDepth}`;
  colors.set(key, (colors.get(key) ?? 0) + 1);
  interlace.set(h.interlace, (interlace.get(h.interlace) ?? 0) + 1);
  if (h.width * h.height > maxW * maxH) {
    maxW = h.width;
    maxH = h.height;
    maxPath = p;
  }
}

console.log(`结构校验（签名/块序列/CRC/IHDR）：通过 ${structOk}，失败 ${structFails.length}`);
console.log(`分布：${Array.from(colors.entries()).map(([k, v]) => `${k}×${v}`).join("  ")}`);
console.log(
  `隔行：${Array.from(interlace.entries()).map(([k, v]) => `interlace=${k}×${v}`).join("  ")}；` +
    `最大尺寸：${maxW}×${maxH}（${maxPath === "" ? "-" : relative(ROOT, maxPath)}）`,
);

// ---- 抽样解码 ----
let order = 0;
const samples = [];
for (const p of files) {
  const i = order++;
  if (ALL || i % EVERY === 0) samples.push(p);
  if (samples.length >= LIMIT) break;
}

console.log(
  `\n抽样解码：${ALL ? "全量" : `每 ${EVERY} 张取 1 张`}，上限 ${LIMIT === Number.MAX_SAFE_INTEGER ? "不限" : LIMIT}，` +
    `实际 ${samples.length} 张`,
);

let decodeOk = 0;
let decodedBytes = 0;
const decodeFails = [];

for (const [i, p] of samples.entries()) {
  let bytes;
  try {
    bytes = new Uint8Array(readFileSync(p));
  } catch (e) {
    decodeFails.push({ path: p, error: `读取失败：${e instanceof Error ? e.message : String(e)}` });
    continue;
  }
  const struct = checkStructure(bytes);
  const r = decodePng(bytes);
  if (!r.ok) {
    decodeFails.push({ path: p, error: `${r.error.code}: ${r.error.message}` });
  } else {
    const d = r.value;
    if (struct.ok && (d.width !== struct.header.width || d.height !== struct.header.height)) {
      decodeFails.push({
        path: p,
        error: `解码宽高 ${d.width}×${d.height} 与 IHDR ${struct.header.width}×${struct.header.height} 不一致`,
      });
    } else {
      decodeOk++;
      decodedBytes += d.pixels.byteLength;
    }
    // ★ 立刻丢弃：不要把解码结果留在数组里（全量会 OOM）
  }
  bytes = null;
  if ((i + 1) % 25 === 0 || i + 1 === samples.length) {
    process.stdout.write(`\r  解码进度 ${i + 1}/${samples.length}（成功 ${decodeOk}，失败 ${decodeFails.length}）`);
  }
}
process.stdout.write("\n");

console.log(`解码成功：${decodeOk}，失败：${decodeFails.length}（累计解码像素 ${(decodedBytes / 1048576).toFixed(1)} MB）`);

const show = (list, label) => {
  if (list.length === 0) return;
  console.log(`${label}（前 5 个）：`);
  for (const f of list.slice(0, 5)) {
    console.log(`  - ${relative(ROOT, f.path)}`);
    console.log(`      ${f.error}`);
  }
};
show(structFails, "结构失败样本");
show(decodeFails, "解码失败样本");

console.log(`耗时：${((Date.now() - t0) / 1000).toFixed(1)}s`);

if (structFails.length > 0 || decodeFails.length > 0) process.exit(1);
