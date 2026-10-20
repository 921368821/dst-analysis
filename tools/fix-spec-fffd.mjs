#!/usr/bin/env node
/**
 * tools/fix-spec-fffd.mjs —— 修 spec 里的 U+FFFD「替换字符」（真缺陷，不是显示问题）
 *
 * 为什么要有
 *   spec 是注释内容的**唯一真源**，注释版是它的产物。但产物里有几处是好的、
 *   spec 里却把「每秒」写成了「每 + 一个替换字符 + 秒」—— 说明 spec 在**某次编辑中被截断了一个中文字**。
 *   这件事在「构建」时看不出来（构建要原版树，本机跑不起来），
 *   直到 M8 的「反向重建」逐行严格比对才暴露：**产物比源更正确**。
 *   若不管它，等原版树到位、重新构建一次，坏字就会被写进注释版。
 *
 * 修法（不猜）
 *   对每一处坏行，把 U+FFFD 段当「通配 1~4 个字符」，到**对应注释版文件**里搜。
 *   恰好命中 1 行 ⇒ 用那一行回填（注释版是既有产物，视为正确）。
 *   命中 0 行或多行 ⇒ **不修**，打印出来让人处理 —— 宁可留着，也不猜一个字。
 *
 * 用法
 *   node tools/fix-spec-fffd.mjs            # dry-run，只报
 *   node tools/fix-spec-fffd.mjs --write    # 落盘
 *   node tools/fix-spec-fffd.mjs --check    # 闸门：0 无乱码 / 1 有乱码（不改文件）
 *
 * 退出码：0 干净或全部可修 / 1 仍有坏行（无法自动修）/ 2 缺映射等前置
 */
import { readFileSync, writeFileSync, readdirSync, existsSync } from "node:fs";
import { join } from "node:path";
import { repoRoot, ANN_SCRIPTS } from "./lib/paths.mjs";

const TOOLS = join(repoRoot, "tools");
const BAD = /\uFFFD/;

/** 从 build 脚本抽 spec → 注释版 tail 的映射
 *
 * 三种形态都要认（本工程实际存在）：
 *   ① `const SPEC = join(__dirname, "spec-x.mjs")` + `const SRC = "..."`  —— 单文件构建
 *   ② `build("x.lua", ..., join(__dirname, "spec-y.mjs"))`                —— 多文件构建（build-actions）
 *   ③ `spec-x-p3.mjs`（分片）→ 聚合器 `spec-x.mjs` 的映射                —— 分片共用同一注释版
 */
function specToTail() {
  const rawMap = new Map(); // spec 文件名 -> 源文件相对路径（未归一化）
  for (const f of readdirSync(TOOLS)) {
    if (!/^build-.*\.mjs$/.test(f)) continue;
    const raw = readFileSync(join(TOOLS, f), "utf8");

    // ① 单文件构建
    const srcM = /const\s+SRC\s*=\s*(?:relSrc\(\s*)?\n?\s*"([^"]+\.lua)"/.exec(raw);
    const specM = /const\s+SPEC\s*=\s*join\(\s*__dirname\s*,\s*"([^"]+\.mjs)"\s*\)/.exec(raw);
    if (srcM && specM) {
      rawMap.set(specM[1], srcM[1]);
      continue;
    }

    // ② 多文件构建：按 `await build(` 切块；一个块只构建一个文件 ⇒ 块内所有 spec 归它
    //    （build-ui / build-map / build-actions 都是这个形态，spec 以数组或 S("...") 传入）
    const blocks = raw.split(/await\s+build\s*\(/).slice(1);
    for (const blk of blocks) {
      const fm = /^\s*"([^"]+\.lua)"/.exec(blk);
      if (!fm) continue;
      for (const sm of blk.matchAll(/spec-([\w-]+)\.mjs/g)) rawMap.set(`spec-${sm[1]}.mjs`, fm[1]);
    }
  }

  const map = new Map();
  for (const [s, src] of rawMap) map.set(s, tailOf(src));

  // ③ 分片 → 聚合器
  // ★ 必须遍历「目录里所有 spec 文件」，而不是 map 的 key —— 分片本身不在 map 里，
  //   遍历 key 等于在找「已经映射过的东西」，永远空转（这个 bug 我第一次就写出来了）。
  for (const f of readdirSync(TOOLS)) {
    if (!/^spec-.*\.mjs$/.test(f)) continue;
    if (map.has(f)) continue;
    const mm = /^(spec-.+)-p\d+\.mjs$/.exec(f);
    if (!mm) continue;
    const agg = `${mm[1]}.mjs`;
    if (map.has(agg)) map.set(f, map.get(agg));
  }
  return map;
}

function tailOf(src) {
  const s = src.replace(/\\/g, "/");
  const i = s.lastIndexOf("/scripts/scripts/");
  return i >= 0 ? s.slice(i + "/scripts/scripts/".length) : s.split("/scripts/").pop();
}

/** 把 spec 字符串内容变成「FFFD 段通配」的正则 */
function fuzzyRe(content) {
  const parts = content.split(/\uFFFD+/).map((s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  return new RegExp("^" + parts.join(".{1,4}") + "$");
}

/** 取 spec 行里引号内的内容（只认单行、'...' / "..." 两种） */
function stringOf(line) {
  const m = /^\s*(['"])(.*)\1\s*,?\s*$/.exec(line);
  return m ? { quote: m[1], content: m[2] } : null;
}

const { map: specMap } = { map: specToTail() };
const argv = process.argv.slice(2);
const write = argv.includes("--write");
const checkOnly = argv.includes("--check");

// ★ 闸门语义：--check 只问「现在还有没有乱码」，**不管能不能自动修**
//   （第一版把「可修」也算干净 ⇒ 修完没写入仍返回 0 = 假绿。判据必须问最终状态。）
if (checkOnly) {
  const bad = [];
  for (const f of readdirSync(TOOLS)) {
    if (!/\.mjs$/.test(f)) continue;
    const raw = readFileSync(join(TOOLS, f), "utf8");
    raw.split("\n").forEach((l, i) => {
      if (BAD.test(l)) bad.push(`${f}:${i + 1}  ${l.trim().slice(0, 90)}`);
    });
  }
  if (bad.length) {
    console.log(`✘ 仍有 ${bad.length} 行含 U+FFFD（工具不猜字，请人工处理）：`);
    for (const b of bad) console.log("  " + b);
    process.exit(1);
  }
  console.log("✔ 全部 .mjs 里没有 U+FFFD");
  process.exit(0);
}

let fixed = 0, unfixable = 0, filesTouched = 0;
const report = [];

for (const f of readdirSync(TOOLS)) {
  if (!/\.mjs$/.test(f)) continue;
  const path = join(TOOLS, f);
  const raw = readFileSync(path, "utf8");
  if (!BAD.test(raw)) continue;
  const tail = specMap.get(f);
  const annPath = tail ? join(ANN_SCRIPTS, tail) : null;
  const annLines = annPath && existsSync(annPath) ? readFileSync(annPath, "utf8").split(/\r?\n/) : null;

  const lines = raw.split("\n");
  let touched = false;
  for (let i = 0; i < lines.length; i++) {
    if (!BAD.test(lines[i])) continue;
    const s = stringOf(lines[i]);
    let hit = null;
    if (s && annLines) {
      const re = fuzzyRe(s.content);
      const cands = annLines.filter((l) => re.test(l.trim()));
      if (cands.length === 1) hit = cands[0].trim();
    }
    const where = `${f}:${i + 1}`;
    if (!hit) {
      unfixable++;
      report.push(`  ✘ ${where} 无法自动修（${tail ? "注释版无唯一匹配" : "该 spec 未映射到注释版"}）\n      ${lines[i].trim()}`);
      continue;
    }
    const quote = s.quote;
    // ★ 这里踩过一次：把 `(\s*['"])` 当作引号组、再用 `\1` 收尾 ⇒ 组里含缩进，
    //   反向引用永远失败 ⇒ replace 什么都没做，却照样打印「✔ 回填」。
    //   正确写法是「缩进 / 引号 / 内容 / 同一个引号 / 尾随逗号」四段，引号用 \2 引用。
    const next = lines[i].replace(
      /^(\s*)(['"])(.*)\2(\s*,?\s*)$/,
      (_m, ind, q, _old, tail) => ind + q + hit.replace(/\\/g, "\\\\") + q + tail
    );
    if (next === lines[i]) {
      unfixable++;
      report.push(`  ✘ ${where} 回填失败（行结构与预期不符，未改动）\n      ${lines[i].trim()}`);
      continue;
    }
    if (hit.includes("$")) {
      // 函数式替换已经避开了 $ 语义问题；这里只做一次自证，防止将来改成字符串拼接又踩坑
      if (!next.includes(hit)) {
        unfixable++;
        report.push(`  ✘ ${where} 回填结果不含目标文本（含 $ 转义问题）`);
        continue;
      }
    }
    lines[i] = next;
    fixed++;
    touched = true;
    report.push(`  ✔ ${where} 回填 → ${hit}`);
  }
  if (touched) {
    filesTouched++;
    if (write) writeFileSync(path, lines.join("\n"), "utf8");
  }
}

console.log(report.join("\n"));
console.log(`\n合计：可修 ${fixed} 处 / 不可修 ${unfixable} 处 / 涉及 ${filesTouched} 个文件${write ? "（已写入）" : "（dry-run）"}`);
if (unfixable) {
  console.log(`\n⚠ 不可修的必须人工处理 —— 工具不猜字。`);
  process.exit(1);
}
process.exit(0);
