#!/usr/bin/env node
/**
 * build-constants.mjs —— constants.lua 深度中文注释生成器（锚点注入法）
 *
 * 设计目标：从根本上杜绝「手抄代码行出错」。
 *   · 可执行代码行 100% 来自源文件，逐字节原样复制，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-constants-pN.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置只有两种：before（该行之前）与 after（该行之后）。
 *   · 任何插入内容都以 `--` 开头，故 Lua 语义绝对不受影响。
 *
 * 用法：node build-constants.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("constants.lua");
const OUT = relOut("constants.lua");

/** 6 个分段 spec */
const SPECS = Array.from({ length: 6 }, (_, i) =>
  join(__dirname, `spec-constants-p${i + 1}.mjs`)
);
const HEADER_SPEC = join(__dirname, "spec-constants-header.mjs");

function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function main() {
  const hdr = await import(pathToFileURL(HEADER_SPEC).href + `?v=${Date.now()}`);
  const HEADER = typeof hdr.HEADER === "string" ? hdr.HEADER.split("\n") : hdr.HEADER;
  if (!Array.isArray(HEADER)) throw new Error("spec-constants-header.mjs 未导出 HEADER");

  let BEFORE = {};
  let AFTER = {};
  for (const sp of SPECS) {
    const m = await import(pathToFileURL(sp).href + `?v=${Date.now()}`);
    for (const [k, v] of Object.entries(m.BEFORE || {})) {
      if (BEFORE[k]) throw new Error(`行号 ${k} 在多个 spec 中重复定义 BEFORE`);
      BEFORE[k] = v;
    }
    for (const [k, v] of Object.entries(m.AFTER || {})) {
      if (AFTER[k]) throw new Error(`行号 ${k} 在多个 spec 中重复定义 AFTER`);
      AFTER[k] = v;
    }
  }

  const srcLines = readFileSync(SRC, "utf8").split("\n");
  expandKeysInPlace(BEFORE, srcLines, "BEFORE");   // 锚点键 → 行号键（M8）
  expandKeysInPlace(AFTER, srcLines, "AFTER");

  const out = [];
  let injected = 0;
  for (const h of HEADER) {
    assertComment(h, "HEADER");
    out.push(h);
    injected++;
  }

  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
    const pre = BEFORE[lineno];
    if (pre) {
      for (const c of pre) {
        assertComment(c, `BEFORE[${lineno}]`);
        out.push(c);
        injected++;
      }
    }
    out.push(srcLines[i]); // ← 代码行永远原样取自源文件
    const post = AFTER[lineno];
    if (post) {
      for (const c of post) {
        assertComment(c, `AFTER[${lineno}]`);
        out.push(c);
        injected++;
      }
    }
  }

  const missing = [];
  for (const key of [...Object.keys(BEFORE), ...Object.keys(AFTER)]) {
    const n = Number(key);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key);
  }
  if (missing.length) throw new Error(`规格中存在越界行号: ${missing.join(", ")}`);

  mkdirSync(dirname(OUT), { recursive: true });
  const text = out.join("\n");
  writeFileSync(OUT, text, "utf8");

  const cnt = (re) => (text.match(re) || []).length;
  console.log(`✔ 已生成: ${OUT}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(`  机制标注【】   : ${cnt(/【/g)}`);
  console.log(`  重点标注★      : ${cnt(/★/g)}`);
  console.log(`  疑似缺陷⚠      : ${cnt(/⚠/g)}`);
  console.log(`  交叉引用参见    : ${cnt(/参见 /g)}`);
  console.log(
    `  保护标记在前10行: ${
      out.slice(0, 10).some((l) => l.includes("【深度注释版】")) ? "是" : "否"
    }`
  );
}

main().catch((e) => {
  console.error("✘ 构建失败:", e.message);
  process.exit(1);
});