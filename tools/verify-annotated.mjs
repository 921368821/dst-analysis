#!/usr/bin/env node
/**
 * verify-annotated.mjs —— 注释版Lua 源码完整性校验器
 *
 * 用途：确认「中文注释版」相对「原版」只增加了注释行，
 *      没有意外改动任何可执行代码。这是对4030 个文件批量注释的质量底线。
 *
 * 校验规则：
 *   1. 去掉空行与纯注释行（trim 后以 -- 开头）后，两边应逐行完全一致
 *   2. 比较时忽略行首缩进差异与连续空白差异（Lua 语义不受影响）
 *   3. 关键：关键字 local / function 等作用域修饰符必须严格一致
 *
 * 用法：node verify-annotated.mjs <原版根> <注释版根>
 */
import { readdirSync, statSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";

const [srcRoot, dstRoot] = process.argv.slice(2);
if (!srcRoot || !dstRoot) {
  console.error("用法: node verify-annotated.mjs <原版根> <注释版根>");
  process.exit(2);
}

function walk(dir, acc = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, acc);
    else if (name.endsWith(".lua")) acc.push(p);
  }
  return acc;
}

/** 提取"有效代码行"：去空行、去纯注释行、归一化空白 */
const codeLines = (file) =>
  readFileSync(file, "utf8")
    .split(/\r?\n/)
    .filter((l) => {
      const t = l.trim();
      return t !== "" && !t.startsWith("--");
    })
    .map((l) => l.trim().replace(/\s+/g, " "));

const srcFiles = walk(srcRoot);
let checked = 0;
const problems = [];

for (const src of srcFiles) {
  const rel = relative(srcRoot, src);
  const dst = join(dstRoot, rel);
  let dstCode;
  try {
    dstCode = codeLines(dst);
  } catch {
    problems.push({ rel, reason: "注释版缺失该文件" });
    continue;
  }
  const srcCode = codeLines(src);
  checked++;

  if (srcCode.length !== dstCode.length) {
    problems.push({
      rel,
      reason: `有效代码行数不同：原 ${srcCode.length} vs 注释 ${dstCode.length}`,
    });
    continue;
  }
  for (let i = 0; i < srcCode.length; i++) {
    if (srcCode[i] !== dstCode[i]) {
      problems.push({
        rel,
        reason: `第 ${i + 1} 有效行不一致\n      原  : ${srcCode[i]}\n      注释: ${dstCode[i]}`,
      });
      break;
    }
  }
}

console.log(`检查文件数: ${checked}/${srcFiles.length}`);
if (problems.length === 0) {
  console.log("✅ 全部通过：注释版仅增加注释，可执行代码与原版完全一致");
  process.exit(0);
}
console.log(`❌ 发现 ${problems.length} 个问题：`);
for (const p of problems.slice(0, 40)) console.log(`  [${p.rel}] ${p.reason}`);
if (problems.length > 40) console.log(`  ...另有 ${problems.length - 40} 个问题`);
process.exit(1);