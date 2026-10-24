#!/usr/bin/env node
/**
 * PNG 语料特征普查（工具的判据，不是引擎的一部分）
 *
 * 只回答一个问题：**这个磁盘上到底有没有 Adam7 / 16 位 / APNG 的真实样本？**
 *   · 有 → 那就是回归语料，解码器必须逐字节对得上；
 *   · 没有 → 解码器的正确性只能靠"构造语料 + 跨实现交叉验证"，
 *     这个事实必须写进文档，而不是含糊地说"支持"。
 *
 * ★ 只读 IHDR + 扫块类型，不解压、不分配像素缓冲。
 *   3000 张 2048² 的图如果真解压，光是跑一遍就要几分钟；这里全部是 O(块数)。
 *
 * 用法：
 *   node tools/scan-png-features.mjs                 # 默认扫工程根 + 系统图片目录
 *   node tools/scan-png-features.mjs --root D:/x     # 只扫指定目录
 *   node tools/scan-png-features.mjs --json          # 机器可读
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const SIGNATURE = "89504e470d0a1a0a";
const DEFAULT_ROOTS = [
  new URL("../../", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1"),
  "C:/Windows/Web",
  "C:/Users/Public/Pictures",
];

const args = process.argv.slice(2);
function argValue(name, fallback) {
  const i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
}
const JSON_OUT = args.includes("--json");
const roots = args.includes("--root") ? [argValue("--root")] : DEFAULT_ROOTS;
const maxFiles = Number.parseInt(argValue("--max", "200000"), 10);

const SKIP_DIRS = new Set(["node_modules", ".git", "_out", "System32", "WinSxS", "Installer"]);

/** @type {{total:number, interlaced:number, deep:number, apng:number, palette:number, alpha:number, gray:number, files:string[]}} */
const stats = {
  total: 0,
  interlaced: 0,
  deep: 0,
  apng: 0,
  palette: 0,
  alpha: 0,
  gray: 0,
  files: [],
};

function inspect(file) {
  let buf;
  try {
    buf = readFileSync(file);
  } catch {
    return;
  }
  if (buf.length < 33 || buf.subarray(0, 8).toString("hex") !== SIGNATURE) return;

  const width = buf.readUInt32BE(16);
  const height = buf.readUInt32BE(20);
  const bitDepth = buf[24];
  const colorType = buf[25];
  const interlace = buf[28];

  stats.total++;
  if (interlace === 1) {
    stats.interlaced++;
    stats.files.push(`interlaced: ${file} (${width}x${height} bd=${bitDepth} ct=${colorType})`);
  }
  if (bitDepth === 16) {
    stats.deep++;
    stats.files.push(`depth16:   ${file} (${width}x${height} ct=${colorType}${interlace ? " interlaced" : ""})`);
  }
  if (colorType === 3) stats.palette++;
  if (colorType === 4 || colorType === 6) stats.alpha++;
  if (colorType === 0 || colorType === 4) stats.gray++;

  // 扫块只看类型，不看数据：APNG 的 acTL 是可选的，通常紧跟 IHDR
  let at = 8;
  while (at + 8 <= buf.length) {
    const len = buf.readUInt32BE(at);
    const type = buf.toString("latin1", at + 4, at + 8);
    if (type === "acTL") {
      stats.apng++;
      stats.files.push(`apng:      ${file}`);
      break;
    }
    if (type === "IDAT" || type === "IEND") break;
    at += 12 + len;
  }
}

function walk(dir, budget) {
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    if (budget.left <= 0) return;
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      if (SKIP_DIRS.has(e.name)) continue;
      walk(p, budget);
    } else if (e.isFile() && e.name.toLowerCase().endsWith(".png")) {
      budget.left--;
      inspect(p);
    }
  }
}

const budget = { left: maxFiles };
for (const r of roots) {
  try {
    if (!statSync(r).isDirectory()) continue;
  } catch {
    continue;
  }
  walk(r, budget);
}

if (JSON_OUT) {
  console.log(JSON.stringify({ roots, ...stats }, null, 2));
} else {
  console.log(`扫描根：${roots.join(" | ")}`);
  console.log(`PNG 总数        ${stats.total}`);
  console.log(`Adam7 隔行      ${stats.interlaced}`);
  console.log(`16 位色深       ${stats.deep}`);
  console.log(`APNG (acTL)     ${stats.apng}`);
  console.log(`调色板 colorType=3  ${stats.palette}`);
  console.log(`带 alpha 通道   ${stats.alpha}`);
  console.log(`灰度 colorType=0/4 ${stats.gray}`);
  if (stats.files.length > 0) {
    console.log("\n值得注意的样本：");
    for (const f of stats.files.slice(0, 40)) console.log("  " + f);
    if (stats.files.length > 40) console.log(`  ... 另有 ${stats.files.length - 40} 个`);
  }
}
