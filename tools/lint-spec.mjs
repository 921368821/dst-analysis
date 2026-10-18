#!/usr/bin/env node
/**
 * lint-spec.mjs —— spec 文件自检器（构建前的批量体检）
 *
 * 复用 build 脚本的 assertComment 规则，但一次性列出【全部】违规行，
 * 避免像逐个修那样反复失败。
 *
 * 用法：node lint-spec.mjs spec-<name>.mjs [spec-<name>.mjs ...]
 */
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("用法: node lint-spec.mjs <spec-xxx.mjs> [...]");
  process.exit(2);
}

let bad = 0;

for (const f of files) {
  const specUrl = pathToFileURL(resolve(f)).href;
  const spec = (await import(specUrl)).default;
  const problems = [];

  // ★ 重复键检测：JS 对象字面量里重复的 key 会「后者静默覆盖前者」，
  //   导致 spec 写的一大段注释凭空消失，而 node --check 与 build 都发现不了。
  //   这里从源码文本里统计每个 `^  N: [` 锚点出现的次数。
  const raw = readFileSync(resolve(f), "utf8");
  const seen = new Map();
  for (const m of raw.matchAll(/^\s{2}(\d+(?:\.\d+)?):\s*\[/gm)) {
    seen.set(m[1], (seen.get(m[1]) || 0) + 1);
  }
  for (const [k, n] of seen) {
    if (n > 1) problems.push(`锚点 ${k} 在源码中出现 ${n} 次（后者会覆盖前者！）`);
  }

  // spec 有两种导出形态：
  //   A) export default { 行号: [...] }              —— 新版（build-combat/builder 等）
  //   B) export const BEFORE = {} / AFTER = {}       —— 旧版（build-health 等）
  const maps = [];
  if (spec && typeof spec === "object") {
    if (spec.default) maps.push(["default", spec.default]);
    if (spec.AFTER) maps.push(["AFTER", spec.AFTER]);
    if (spec.BEFORE) maps.push(["BEFORE", spec.BEFORE]);
    if (!maps.length && !spec.__esModule) maps.push(["?", spec]); // 少数直接 module.exports
  }
  if (!maps.length) {
    console.log(`✘ ${f}：无法识别的导出形态（既无 default 也无 AFTER/BEFORE）`);
    bad++;
    continue;
  }

  for (const [tag, map] of maps) {
    if (!map || typeof map !== "object") {
      console.log(`✘ ${f}：${tag} 不是对象`);
      bad++;
      continue;
    }
    for (const [key, arr] of Object.entries(map)) {
      const n = Number(key);
      if (!Number.isInteger(n) || n < 1) {
        problems.push(`${tag} 行号非法: ${key}`);
        continue;
      }
      if (!Array.isArray(arr)) {
        problems.push(`${tag}[${n}] 不是数组`);
        continue;
      }
      // ── 块注释配对需要跨行统计，不能逐行判断 ──
      // 一个锚点数组里 `--[[` 在第 i 行开启、`--]]` 在第 j>i 行闭合是**完全合法**的
      // （文件头总述就是这么写的）。真正危险的只有两种：
      //   a) 整个数组结束后仍未闭合 → 会吞掉后续所有内容
      //   b) 正文中段出现裸 `]]` → 会提前闭合源码已开启的长注释块
      let openDepth = 0;
      arr.forEach((line, i) => {
        if (typeof line !== "string") return;
        // 剥掉合法的 --[[ 与 --]] 后，剩下的裸序列才是问题
        const rest = line.replace(/--\[\[/g, "").replace(/--\]\]/g, "");
        if (rest.includes("]]")) {
          problems.push(`${tag}[${n}][${i}] 正文含裸 ]] 序列（会提前闭合源码的长注释块）`);
        }
        if (rest.includes("--[[")) {
          problems.push(`${tag}[${n}][${i}] 正文含裸 --[[ 序列`);
        }
        if (line.includes("\\r")) {
          problems.push(`${tag}[${n}][${i}] 含 \\r 转义（会被当真回车劈开行）`);
        }
        openDepth += (line.match(/--\[\[/g) || []).length;
        openDepth -= (line.match(/--\]\]/g) || []).length;
        if (openDepth < 0) {
          problems.push(`${tag}[${n}][${i}] 出现多余的 --]] （块注释提前闭合）`);
          openDepth = 0;
        }
      });
      if (openDepth > 0) {
        problems.push(`${tag}[${n}] 块注释未闭合（净开启 ${openDepth} 个 --[[ ）`);
      }
    }
  }

  if (problems.length) {
    bad++;
    console.log(`✘ ${f}：${problems.length} 处问题`);
    for (const p of problems) console.log(`   ${p}`);
  } else {
    console.log(`✔ ${f}：${maps.map(([t, m]) => t + ":" + Object.keys(m).length).join(" ")} 全部合规`);
  }
}

process.exit(bad ? 1 : 0);
