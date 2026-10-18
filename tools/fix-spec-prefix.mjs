#!/usr/bin/env node
/**
 * fix-spec-prefix.mjs —— 批量给 spec 里漏掉 `--` 前缀的注释行补上前缀
 *
 * 判定规则：数组元素是字符串、trim 后不以 -- 开头、且不含成对引号/代码符号
 * （即它明显是续行注释而非误入的代码）时，补上 `-- `。
 * 只处理「看起来是中文续行」的行，其他一律跳过并报告，交人工判断。
 *
 * 用法：node fix-spec-prefix.mjs <spec-xxx.mjs>
 */
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const f = resolve(process.argv[2]);
let src = readFileSync(f, "utf8");

// 匹配形如:  <indent>'<content>'   且 content 以空白 + 中文/（ 开头的续行
const re = /^(\s*)'(?!\s*-)([^']*)'/gm;
let fixed = 0;
const skipped = [];

// ⚠️ 必须接住 replace 的返回值，String.prototype.replace 不改原串
src = src.replace(re, (m, indent, content) => {
  const t = content.trim();
  if (t === "") return m; // 空串合法
  if (t.startsWith("--")) return m; // 已有前缀
  // 只自动修「明显是中文续行」：去掉缩进后以中文标点、汉字、全角括号开头
  if (!/^[一-鿿（【★⚠]/.test(t)) {
    skipped.push(t.slice(0, 60));
    return m;
  }
  fixed++;
  return `${indent}'-- ${content}'`;
});

writeFileSync(f, src, "utf8");
console.log(`已补前缀 ${fixed} 行`);
if (skipped.length) {
  console.log(`⚠ 跳过 ${skipped.length} 行（需人工判断）:`);
  for (const s of skipped) console.log(`   ${s}`);
}
