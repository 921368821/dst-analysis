#!/usr/bin/env node
/**
 * tools/relocate-paths.mjs —— 把 104 个 build 脚本里**写死的绝对路径**改成「共享解析」
 *
 * 症状（M8 的另一半）
 *   `tools/build-*.mjs` 每个都在顶上抄两份字面量：
 *       const SRC = "C:/Users/35916/.qwenworkcn/workspace/.../scripts/brain.lua";
 *       const OUT = "E:/DST-Analysis/02-注释源码/scripts/brain.lua";
 *   工作区搬过家（35916 → admin，E:/DST-Analysis → 当前盘符）之后，这 104 个脚本
 *   **同时**指向不存在的目录。它们不会一开始就报错 —— 要等脚本跑到 `readFileSync`
 *   才炸，而且炸出来的是 `ENOENT ... 35916 ...`，看着像「别人的机器」。
 *
 * 改法
 *   SRC / SRC_ROOT → `relSrc("<tail>")` / `pristineRoot()`（统一走 tools/lib/paths.mjs）
 *   OUT / OUT_ROOT → `relOut("<tail>")` / `ANN_SCRIPTS`
 *   并在文件头补一行 `import { relSrc, relOut } from "./lib/paths.mjs";`（已存在就不重复）
 *
 * 判据
 *   ① `--check`：仍含旧绝对路径字面量的文件数必须为 0（可红：改回一处就会红）
 *   ② 改完每个文件 `node --check` 必须过（语法没被改坏）
 *   ③ 原版树缺失时，脚本报的必须是「**先跑 archive-pristine.sh**」，而不是 ENOENT
 *
 * 用法：
 *   node tools/relocate-paths.mjs --check
 *   node tools/relocate-paths.mjs --write
 *   node tools/relocate-paths.mjs --selftest
 * 退出码：0 通过 / 1 有差异 / 2 前置缺失
 */
import { readFileSync, writeFileSync, readdirSync, unlinkSync } from "node:fs";
import { join, resolve, relative } from "node:path";
import { execFileSync } from "node:child_process";
import { repoRoot } from "./lib/paths.mjs";

const TOOLS = join(repoRoot, "tools");
const OLD_MARKERS = [/C:\/Users\/35916\//i, /\.qwenworkcn/i, /E:\/DST-Analysis\//i,
                     /C:\\Users\\35916\\/i, /E:\\DST-Analysis\\/i];
const SRC_PREFIXES = [
  "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/",
  "C:\\Users\\35916\\.qwenworkcn\\workspace\\mv38nal4gdn29zna\\dst-analysis\\scripts\\scripts\\",
];
const OUT_PREFIXES = ["E:/DST-Analysis/02-注释源码/scripts/", "E:\\DST-Analysis\\02-注释源码\\scripts\\"];

const IMPORT_LINE = 'import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";';

function targets() {
  return readdirSync(TOOLS)
    .filter((f) => /^(build|gen)-.*\.mjs$/.test(f))
    .map((f) => join(TOOLS, f));
}

/** 从旧字面量里剥出「相对 scripts 根」的尾巴；剥不掉就返回 null（交给人看） */
function tailOf(literal, prefixes) {
  const p = literal.replace(/\\/g, "/");
  for (const pre of prefixes) {
    const q = pre.replace(/\\/g, "/");
    if (p.startsWith(q)) return p.slice(q.length).replace(/\/+$/, "");
  }
  return null;
}

/** 把 `const NAME = "...";`（可跨行）整体替换 */
function replaceConst(raw, name, newExpr) {
  const re = new RegExp(`const\\s+${name}\\s*=\\s*([\\s\\S]*?);`, "m");
  const m = re.exec(raw);
  if (!m) return { raw, hit: false, old: null };
  const body = m[1];
  const lit = /["']([^"']+)["']/.exec(body);
  const next = raw.slice(0, m.index) + `const ${name} = ${newExpr};` + raw.slice(m.index + m[0].length);
  return { raw: next, hit: true, old: lit ? lit[1] : null };
}

function ensureImport(raw) {
  if (raw.includes('from "./lib/paths.mjs"')) return raw;
  // 插在最后一个 import 语句之后；没有 import 就插在文件头注释块之后的第一行
  const lines = raw.split("\n");
  let last = -1;
  for (let i = 0; i < lines.length; i++) if (/^\s*import\s.+from\s+["']/.test(lines[i])) last = i;
  if (last < 0) {
    for (let i = 0; i < lines.length; i++) if (lines[i].trim() && !lines[i].trim().startsWith("*") &&
      !lines[i].trim().startsWith("/*") && !lines[i].trim().startsWith("//") && !lines[i].trim().startsWith("/**")) {
      last = i - 1; break;
    }
  }
  lines.splice(last + 1, 0, IMPORT_LINE);
  return lines.join("\n");
}

function plan(file) {
  const raw = readFileSync(file, "utf8");
  const hasOld = OLD_MARKERS.some((re) => re.test(raw));
  if (!hasOld) return { file, raw, changed: false, notes: [] };
  let out = raw;
  const notes = [];
  // 单个文件型：SRC / OUT
  for (const [name, prefixes, fn] of [
    ["SRC", SRC_PREFIXES, (t) => `relSrc(${JSON.stringify(t)})`],
    ["OUT", OUT_PREFIXES, (t) => `relOut(${JSON.stringify(t)})`],
  ]) {
    if (!new RegExp(`const\\s+${name}\\b`).test(out)) continue;
    const m = new RegExp(`const\\s+${name}\\s*=\\s*([\\s\\S]*?);`, "m").exec(out);
    const q = m && /["']([^"']+)["']/.exec(m[1]);
    if (!q) { notes.push(`${name}: 取不到字面量，跳过`); continue; }
    const tail = tailOf(q[1], prefixes);
    if (tail === null) { notes.push(`${name}: 前缀认不出（${q[1]}），跳过`); continue; }
    out = replaceConst(out, name, fn(tail)).raw;
  }
  // 目录型：SRC_ROOT / OUT_ROOT
  if (/const\s+SRC_ROOT\b/.test(out)) {
    out = replaceConst(out, "SRC_ROOT", "pristineRoot()").raw;
    notes.push("SRC_ROOT → pristineRoot()");
  }
  if (/const\s+OUT_ROOT\b/.test(out)) {
    out = replaceConst(out, "OUT_ROOT", "ANN_SCRIPTS").raw;
    notes.push("OUT_ROOT → ANN_SCRIPTS");
  }
  out = ensureImport(out);
  return { file, raw, next: out, changed: out !== raw, notes };
}

function check() {
  const files = targets();
  const bad = [];
  for (const f of files) {
    const raw = readFileSync(f, "utf8");
    if (OLD_MARKERS.some((re) => re.test(raw))) bad.push(relative(repoRoot, f).replace(/\\/g, "/"));
  }
  console.log(`扫描 ${files.length} 个 build/gen 脚本：仍含旧绝对路径 ${bad.length} 个`);
  if (bad.length) {
    for (const b of bad.slice(0, 12)) console.log("  · " + b);
    if (bad.length > 12) console.log(`  … 其余 ${bad.length - 12} 个`);
    console.log("→ 跑 `node tools/relocate-paths.mjs --write` 修掉");
  }
  return bad.length ? 1 : 0;
}

function write() {
  let n = 0, skipped = [];
  for (const f of targets()) {
    const p = plan(f);
    if (!p.changed) continue;
    // 语法闸门：先写临时文件用 node --check 验，再落盘
    const tmp = f + ".tmp.mjs";
    writeFileSync(tmp, p.next, "utf8");
    try {
      execFileSync(process.execPath, ["--check", tmp], { stdio: "pipe" });
      writeFileSync(f, p.next, "utf8");
      n++;
      console.log(`  ✔ ${relative(repoRoot, f).replace(/\\/g, "/")}${p.notes.length ? "（" + p.notes.join("；") + "）" : ""}`);
    } catch (e) {
      skipped.push(relative(repoRoot, f));
      console.log(`  ✘ ${relative(repoRoot, f)}：改完语法不过，**未写入**（${String(e.stderr || e).split("\n")[0]}）`);
    } finally {
      try { unlinkSync(tmp); } catch { /* noop */ }
    }
  }
  console.log(`\n结果：改写 ${n} 个 / 跳过 ${skipped.length} 个`);
  return skipped.length ? 1 : 0;
}

function selftest() {
  let bad = 0;
  let nCase = 0;                        // 用例条数（开发计划 §9cd / §9cg）
  const WANT_CASES = 8;                 // 加/删用例必须同步改这里，并同步 tools/case_counts.txt
  const ok = (c, m) => { console.log(`  ${c ? "✔" : "✘"} ${m}`); nCase++; if (!c) bad++; };
  console.log("── R1 tailOf：旧前缀能剥出相对尾巴 ──");
  ok(tailOf(SRC_PREFIXES[0] + "brains/abigail.lua", SRC_PREFIXES) === "brains/abigail.lua",
     "SRC 尾巴 = brains/abigail.lua");
  ok(tailOf(OUT_PREFIXES[0] + "tuning.lua", OUT_PREFIXES) === "tuning.lua", "OUT 尾巴 = tuning.lua");
  console.log("── R2 反向：不是旧前缀的路径必须返回 null（不许猜） ──");
  ok(tailOf("/home/someone/scripts/scripts/x.lua", SRC_PREFIXES) === null,
     "别的机器路径认不出 ⇒ null（交给人工，不硬编）");
  console.log("── R3 改写：一处 SRC/OUT → relSrc/relOut，并补 import ──");
  const demo = [
    'import { join } from "node:path";',
    'const SRC = "C:/Users/35916/.qwenworkcn/workspace/mv38nal4gdn29zna/dst-analysis/scripts/scripts/brain.lua";',
    'const OUT = "E:/DST-Analysis/02-注释源码/scripts/brain.lua";',
    "console.log(SRC, OUT);",
  ].join("\n");
  const tmp = join(TOOLS, "_selftest-relocate.mjs");
  writeFileSync(tmp, demo, "utf8");
  try {
    const p = plan(tmp);
    ok(/relSrc\("brain\.lua"\)/.test(p.next), "SRC → relSrc(\"brain.lua\")");
    ok(/relOut\("brain\.lua"\)/.test(p.next), "OUT → relOut(\"brain.lua\")");
    ok(p.next.includes('from "./lib/paths.mjs"'), "补上了共享 import");
    ok(!OLD_MARKERS.some((re) => re.test(p.next)), "改写后不再含旧绝对路径（--check 会绿）");
    // 改完必须能通过 node --check
    writeFileSync(tmp, p.next, "utf8");
    let syntaxOk = true;
    try { execFileSync(process.execPath, ["--check", tmp], { stdio: "pipe" }); } catch { syntaxOk = false; }
    ok(syntaxOk, "改写后的文件 node --check 通过");
  } finally {
    try { unlinkSync(tmp); } catch { /* noop */ }
  }
  // ★ 自检也要守住「用例还在不在」：删几条用例、剩下全过，exit code 仍是 0，
  //   而这条自检就在静默变松（开发计划 §9cd / §9cg）。
  if (nCase !== WANT_CASES) {
    console.log(`  ✘ 自检用例 ${nCase} 条，期望 ${WANT_CASES} 条 —— 加/删用例时必须同步 WANT_CASES，否则这条自检会静默变松`);
    bad++;
  }
  console.log(bad ? `\n结果：${bad} 条失败（用例 ${nCase} 条）` : `\n结果：全绿（用例 ${nCase} 条）`);
  return bad ? 1 : 0;
}

const argv = process.argv.slice(2);
let rc;
if (argv.includes("--selftest")) rc = selftest();
else if (argv.includes("--check")) rc = check();
else if (argv.includes("--write")) rc = write();
else {
  console.error("用法: --check | --write | --selftest");
  rc = 2;
}
process.exit(rc);
