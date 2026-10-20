#!/usr/bin/env node
/**
 * build-tuning-override.mjs —— tuning_override.lua 深度中文注释生成器（锚点注入法）
 *
 * 本文件仅 45 行，但**极易被误解** —— 名字叫「数值覆盖」，实际却一个数字都没有。
 * 注释重点在于澄清它的真实用途（见 spec 内详述）。
 *
 * 用法：node build-tuning-override.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { expandKeysInPlace } from "./lib/spec-anchor.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("tuning_override.lua");
const OUT = relOut("tuning_override.lua");
const SPEC = join(__dirname, "spec-tuning-override.mjs");

function assertComment(line, where) {
  const t = line.trim();
  if (!t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
}

async function main() {
  const m = await import(pathToFileURL(SPEC).href + `?v=${Date.now()}`);
  const BEFORE = m.BEFORE || {};
  const AFTER = m.AFTER || {};

  const srcLines = readFileSync(SRC, "utf8").split("\n");
  expandKeysInPlace(BEFORE, srcLines, "BEFORE");   // 锚点键 → 行号键（M8）
  expandKeysInPlace(AFTER, srcLines, "AFTER");
  const out = [];
  let injected = 0;

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