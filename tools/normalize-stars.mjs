#!/usr/bin/env node
/**
 * normalize-stars.mjs —— 消除 spec 里的【同行相邻重复星组】噪声
 *
 * 背景：map/ 各 spec 存在大量 `-- ★★ ★★ xxx` 形态——同一行里两个星组紧邻，
 *      纯属书写噪声（★ 没有累加语义），会稀释真正的重点标记。
 *      但 `-- ★★ for k,v in pairs(...) ——★★ pairs（顺序不定）` 这种
 *      【两处独立标注】是有意义的，必须保留。
 *
 * 判定规则（保守，宁可漏改不可错改）：
 *   只处理「两个星组之间没有任何实义字符」的情况：
 *     ★★ ★★ / ★★★ ★★ / ★★ ★★★  ⇒  ★★ / ★★ / ★★★
 *   ★组之间夹着文字、标点、括号 ⇒ 一律不动。
 *
 * 用法：node normalize-stars.mjs            # 处理全部 spec-map-*.mjs
 *      node normalize-stars.mjs --dry       # 只报告不改
 */
import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const dry = process.argv.includes("--dry");

/** 匹配：星组(1-6) + 至多一个空格 + 星组，且中间无实义字符 */
const DUP = /★{1,6}[ \t]+★{1,6}/g;

/** 归一化：合并两个相邻星组，取较长的那个 */
function normalize(line) {
  return line.replace(DUP, (m) => {
    const groups = m.split(/[ \t]+/);
    const maxLen = Math.max(...groups.map((g) => g.length));
    return "★".repeat(maxLen);
  });
}

const files = readdirSync(__dirname).filter(
  (f) => f.startsWith("spec-map-") && f.endsWith(".mjs")
);

let totalFixed = 0;
for (const f of files) {
  const p = join(__dirname, f);
  const src = readFileSync(p, "utf8");
  const lines = src.split("\n");
  let changed = 0;
  const out = lines.map((l) => {
    if (!l.includes("★")) return l;
    const n = normalize(l);
    if (n !== l) changed++;
    return n;
  });
  if (changed > 0) {
    totalFixed += changed;
    console.log(`  ${dry ? "[dry] " : ""}${f}: 归一化 ${changed} 行`);
    if (!dry) writeFileSync(p, out.join("\n"), "utf8");
  }
}
console.log(
  `${dry ? "[dry] 将" : "已"}归一化 ${totalFixed} 行 / ${files.length} 个 spec`
);