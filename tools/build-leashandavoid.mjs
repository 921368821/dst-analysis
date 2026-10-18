#!/usr/bin/env node
/**
 * build-leashandavoid.mjs —— leashandavoid.lua 深度中文注释生成器（锚点注入法）
 *
 *   · 可执行代码行 100% 来自源文件，本脚本从不生成代码行。
 *   · 注释内容独立维护在 spec-leashandavoid.mjs 中，以「源文件行号」为锚点注入。
 *   · 注入位置：在指定行号之后插入以 `--` 开头的注释行。
 *   · 任何插入内容都以 `--` 开头，Lua 语义绝对不受影响。
 *
 * 用法：node build-leashandavoid.mjs
 */
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/behaviours/leashandavoid.lua";
const SPEC = join(__dirname, "spec-leashandavoid.mjs");
const OUT = "E:/DST-Analysis/02-注释源码/scripts/behaviours/leashandavoid.lua";

const HEADER = "--============================================================\n-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖\n-- 文件：behaviours/leashandavoid.lua\n-- 模块：行为树节点库 / 拉拽回归\n-- 职责：超出活动半径后回家，且回家途中绕开指定障碍物（含一段作者自嘲为\n--       「我这一生做过最大的 hack」的侧向绕行几何计算）。\n-- 关键符号：LeashAndAvoid, LeashAndAvoid:Visit, LeashAndAvoid:GetHomePos,\n--           LeashAndAvoid:GetDistFromHomeSq, LeashAndAvoid:IsInsideLeash,\n--           LeashAndAvoid:IsOutsideReturnDist, LeashAndAvoid:GetMaxDistSq,\n--           LeashAndAvoid:GetReturnDistSq, LeashAndAvoid:DBString\n-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本\n-- 交叉引用：leash.lua（同族无避障版本）, chaseandattackandavoid.lua（hack 的原始出处）,\n--       components/locomotor.lua, FunctionOrValue\n--============================================================\n";

/** 校验一行插入内容确实是合法注释（防止规格里混入代码） */
function assertComment(line, where) {
  const t = line.trim();
  if (t !== "" && !t.startsWith("--")) {
    throw new Error(`规格错误 @${where}: 非注释行 -> ${JSON.stringify(line)}`);
  }
  // 防编码损坏：U+FFFD 说明写入时字符被截断，必须修好再生成
  if (line.includes("\uFFFD")) {
    throw new Error(`规格错误 @${where}: 含 U+FFFD 替换字符（编码损坏）-> ${line}`);
  }
}

async function main() {
  const specUrl = pathToFileURL(SPEC).href;
  const mod = await import(specUrl);
  const AFTER = mod.default; // { 行号: [注释行...] }

  const raw = readFileSync(SRC, "utf8");
  const srcLines = raw.split(/\r?\n/);
  if (srcLines.length && srcLines[srcLines.length - 1] === "") srcLines.pop();

  const out = [HEADER.replace(/\n$/, "")];

  let injected = 0;
  for (let i = 0; i < srcLines.length; i++) {
    const lineno = i + 1;
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
  for (const key of Object.keys(AFTER)) {
    const n = Number(key);
    if (!(n >= 1 && n <= srcLines.length)) missing.push(key);
  }
  if (missing.length) {
    throw new Error(`规格中存在越界行号: ${missing.join(", ")}`);
  }

  const text = out.join("\n");
  mkdirSync(dirname(OUT), { recursive: true });
  writeFileSync(OUT, text, "utf8");

  const mech = (text.match(/【/g) || []).length;
  const star = (text.match(/★/g) || []).length;
  const warn = (text.match(/⚠/g) || []).length;
  let cov = 0;
  for (const k of Object.keys(AFTER)) {
    const n = Number(k);
    if (n >= 1 && n <= srcLines.length) cov++;
  }

  console.log(`✔ 已生成: ${OUT}`);
  console.log(`  源文件行数     : ${srcLines.length}`);
  console.log(`  输出文件行数   : ${out.length}`);
  console.log(`  注入注释行数   : ${injected}`);
  console.log(
    `  注释锚点行数   : ${cov} (覆盖率 ${((cov / srcLines.length) * 100).toFixed(1)}%)`
  );
  console.log(`  机制标注【】   : ${mech}`);
  console.log(`  重点标注★      : ${star}`);
  console.log(`  疑似缺陷⚠      : ${warn}`);
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
