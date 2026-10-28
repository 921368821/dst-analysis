#!/usr/bin/env node
/**
 * 生成 Unicode 双向算法（UAX #9）需要的**三张数据表**，产出
 * `src/extensions/ui/bidi-tables.ts`（base64 打包，Node 与浏览器共用，无 IO 依赖）。
 *
 * 输入（**不入库**，下载后放 `.tmp-bidi/`，见 vendor/bidi/README.md 的来源与版本）：
 *   · DerivedBidiClass.txt —— 每码点 Bidi_Class 的范围表（含 @missing 默认值行）
 *   · BidiMirroring.txt    —— 镜像字符对（M1）
 *   · BidiBrackets.txt     —— 括号配对（N0 / BD16，只收 `o` 行：open → close）
 *
 * ★ 为什么用 base64 而不是数字字面量：同样的 Uint32 数据，数字字面量源码
 *   是 base64 的约 2.5 倍大，而这个文件会被打进浏览器 bundle。
 * ★ 为什么整个 Unicode 的类型范围都要（而不是"常用区"）：Bidi_Class 的
 *   @missing 规则明确写「RTL 保留块的未分配字符默认 R/AL」——截断成常用区
 *   等于把未分配字符当 LTR，那些区块一来新字符（或测试语料引用它们）就静默排反。
 *   全表紧凑编码后只有几十 KB，比"看似更小"的截断表便宜。
 *
 * 用法：`node tools/make-bidi-tables.mjs`（产物与生成器同批入库，逐字节可复现）
 */
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const SRC = join(HERE, "..", ".tmp-bidi");
const OUT = join(HERE, "..", "src", "extensions", "ui", "bidi-tables.ts");

/** Bidi_Class 的规范顺序（UAX #44）。数组下标 = 表里存的字节值。 */
const CLASS_NAMES = [
  "AL", "AN", "B", "BN", "CS", "EN", "ES", "ET", "FSI", "L",
  "LRE", "LRI", "LRO", "NSM", "ON", "PDI", "R", "RLE", "RLI", "RLO", "PDF", "S", "WS",
];
const CLASS_ID = new Map(CLASS_NAMES.map((n, i) => [n, i]));

/** @missing 行用的是属性**全名**（UAX #44 惯例），换算回缩写。 */
const LONG_NAMES = {
  Left_To_Right: "L", Right_To_Left: "R", European_Number: "EN",
  European_Separator: "ES", European_Terminator: "ET", Arabic_Number: "AN",
  Common_Number_Separator: "CS", Paragraph_Separator: "B", Segment_Separator: "S",
  White_Space: "WS", Other_Neutral: "ON", Boundary_Neutral: "BN",
  Nonspacing_Mark: "NSM", Arabic_Letter: "AL",
  Left_To_Right_Embedding: "LRE", Right_To_Left_Embedding: "RLE",
  Left_To_Right_Override: "LRO", Right_To_Left_Override: "RLO",
  Pop_Directional_Format: "PDF", Left_To_Right_Isolate: "LRI",
  Right_To_Left_Isolate: "RLI", First_Strong_Isolate: "FSI",
  Pop_Directional_Isolate: "PDI",
};
function classIdOf(name) {
  const short = CLASS_ID.has(name) ? name : LONG_NAMES[name];
  if (short === undefined) return undefined;
  return CLASS_ID.get(short);
}

function readLines(name) {
  return readFileSync(join(SRC, name), "utf8").split(/\r?\n/);
}

// ---- ① 类型范围表（含 @missing 默认） ----
// DerivedBidiClass.txt 的 @missing 行给"显式区间之外"的默认值（比如 RTL 保留块
// 的未分配字符默认 R/AL）。显式行覆盖默认行 —— 所以先收 @missing，再用显式行
// 从低到高覆盖。最终产物是一张**无缝覆盖 0..0x10FFFF** 的范围表。
const ranges = []; // {start, end, cls}
for (const raw of readLines("DerivedBidiClass.txt")) {
  // ★ @missing 行整行在注释里（"# @missing: ..."），必须先查它再剥注释 ——
  //   剥完就是空行，会在下面被 continue 掉。
  const mm = /@missing:\s*([0-9A-Fa-f]+)\.\.([0-9A-Fa-f]+)\s*;\s*(\w+)/.exec(raw);
  if (mm !== null) {
    const cls = classIdOf(mm[3]);
    if (cls === undefined) throw new Error(`未知 Bidi_Class（@missing）：${mm[3]}`);
    ranges.push({ start: parseInt(mm[1], 16), end: parseInt(mm[2], 16), cls, missing: true });
    continue;
  }
  const line = raw.split("#")[0].trim();
  if (line === "") continue;
  const m = /^([0-9A-Fa-f]+)(?:\.\.([0-9A-Fa-f]+))?\s*;\s*(\w+)\s*$/.exec(line);
  if (m !== null) {
    const cls = classIdOf(m[3]);
    if (cls === undefined) throw new Error(`未知 Bidi_Class：${m[3]}`);
    ranges.push({ start: parseInt(m[1], 16), end: parseInt(m[2] ?? m[1], 16), cls });
  }
}
// 排序：@missing 先进（作为底层），显式行按起点排序后逐段覆盖。
// 做法：显式行按 start 排序，然后对每个显式区间，把覆盖到它的 missing 段切开。
const explicit = ranges.filter((r) => !r.missing).sort((a, b) => a.start - b.start);
const missing = ranges.filter((r) => r.missing).sort((a, b) => a.start - b.start);
if (missing.length === 0) throw new Error("DerivedBidiClass.txt 里没有 @missing 行？");
const out = []; // 最终 [start, end, cls] 三元组
let cursor = 0; // 已覆盖到（含）
for (const miss of missing) {
  if (miss.end < cursor) continue;
  const s = Math.max(miss.start, cursor);
  if (s > miss.end) continue;
  // 这段 missing 之前可能被显式行占用过 —— cursor 之前的已在前面处理
  // 先填 [s, miss.end] 为默认，再让显式行稍后覆盖。
  // 但显式行在 cursor..miss.end 之间的部分要先切开 —— 为了简单：
  // 把这段先按默认值铺满，随后显式行覆盖时再切。
  if (out.length > 0) {
    const last = out[out.length - 1];
    if (last[1] >= s - 1 && last[2] === miss.cls) {
      // 可以并段（同 class 相邻）
      last[1] = miss.end;
      cursor = miss.end + 1;
      continue;
    }
  }
  out.push([s, miss.end, miss.cls]);
  cursor = miss.end + 1;
}
// 显式行覆盖：经典"切片覆盖" —— 对每个显式区间，删掉与它重叠的已有段，插入自身。
const merged = [];
for (const [s, e, cls] of out) merged.push([s, e, cls]);
for (const r of explicit) {
  const next = [];
  for (const [s, e, cls] of merged) {
    if (e < r.start || s > r.end) {
      next.push([s, e, cls]); // 不相交
      continue;
    }
    if (s < r.start) next.push([s, r.start - 1, cls]); // 左残段
    if (e > r.end) next.push([r.end + 1, e, cls]); // 右残段
    // 重叠部分丢弃（被显式行覆盖）
  }
  next.push([r.start, r.end, r.cls]);
  next.sort((a, b) => a[0] - b[0]);
  merged.length = 0;
  merged.push(...next);
}
// 相邻同 class 并段（省一点空间）
const typeRanges = [];
for (const [s, e, cls] of merged) {
  const last = typeRanges[typeRanges.length - 1];
  if (last !== undefined && last[1] + 1 === s && last[2] === cls) last[1] = e;
  else typeRanges.push([s, e, cls]);
}
// 覆盖完整性检查：必须无缝铺满 0..0x10FFFF
{
  let expect = 0;
  for (const [s, e] of typeRanges) {
    if (s !== expect) throw new Error(`类型表在 U+${expect.toString(16)} 出现空洞（下一段 U+${s.toString(16)}）`);
    expect = e + 1;
  }
  if (expect !== 0x110000) throw new Error(`类型表只覆盖到 U+${(expect - 1).toString(16)}`);
}

// ---- ② 镜像表 ----
const mirror = []; // [src, dst]
for (const raw of readLines("BidiMirroring.txt")) {
  const line = raw.split("#")[0].trim();
  if (line === "") continue;
  const [a, b] = line.split(";").map((x) => parseInt(x.trim(), 16));
  mirror.push([a, b]);
}

// ---- ③ 括号表（只收 o 行） ----
const brackets = []; // [open, close]
for (const raw of readLines("BidiBrackets.txt")) {
  const line = raw.split("#")[0].trim();
  if (line === "") continue;
  const [a, b, t] = line.split(";").map((x) => x.trim());
  if (t === "o") brackets.push([parseInt(a, 16), parseInt(b, 16)]);
}

// ---- 打包 ----
function u32(rows) {
  const flat = rows.flat();
  return Buffer.from(new Uint32Array(flat).buffer).toString("base64");
}
function versionOf(name) {
  const line = readLines(name)[0] ?? "";
  const m = /-(\d+\.\d+\.\d+)/.exec(line);
  return m === null ? "unknown" : m[1];
}

const ts = `/**
 * UAX #9 数据表（由 tools/make-bidi-tables.mjs 生成 —— **不要手改**）。
 *
 * 来源：Unicode ${versionOf("DerivedBidiClass.txt")}（www.unicode.org/Public/UCD/latest/ucd/），
 * 版本与再生成方法见 vendor/bidi/README.md。表是全 Unicode 范围（含 @missing
 * 默认值），否则 RTL 保留块的未分配字符会被当 LTR 排。
 *
 * 编码都是 base64(Uint32Array)：
 *   · TYPE_RANGES：[start, end, class] 三元组连存，class 是 CLASS_NAMES 的下标；
 *   · MIRROR_PAIRS：[src, dst]（BidiMirroring.txt，含 [BEST FIT] 近似行）；
 *   · BRACKET_PAIRS：[open, close]（BidiBrackets.txt 只收 \`o\` 行，N0/BD16 用）。
 */
export const BIDI_CLASS_NAMES = ${JSON.stringify(CLASS_NAMES)} as const;

export const TYPE_RANGES_B64 =
  "${u32(typeRanges)}";

export const MIRROR_PAIRS_B64 =
  "${u32(mirror)}";

export const BRACKET_PAIRS_B64 =
  "${u32(brackets)}";
`;
writeFileSync(OUT, ts, "utf8");
console.log(
  `bidi-tables.ts：类型范围 ${typeRanges.length} 段 / 镜像 ${mirror.length} 对 / 括号 ${brackets.length} 对` +
    `（Unicode ${versionOf("DerivedBidiClass.txt")}）`,
);
