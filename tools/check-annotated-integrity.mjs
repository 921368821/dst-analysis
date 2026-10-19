#!/usr/bin/env node
/**
 * check-annotated-integrity.mjs —— 注释版**自身**的完整性体检（不需要原版）
 *
 * 为什么需要它（M9 的副产品）
 *   整套注释的质量底线是「只增注释、可执行代码逐字节一致」。
 *   证明它的**最强**手段是拿原版逐行比（verify-annotated.mjs），
 *   但原版副本已丢失，那一关现在是「无法复验」。
 *
 *   好在有一条**不依赖原版**的判据：**U+FFFD 只可能来自数据损坏**。
 *     · Lua 源码是文本，原文里不会凭空出现替换字符 U+FFFD（EF BF BD）
 *     · 一旦某行**代码行**里出现 U+FFFD ⇒ 那一行被改写过
 *       ⇒ 「只增注释」当场被证伪（不需要原版就能判）
 *   同理，二进制内容（NUL / `\x1bLuaQ` 字节码头）出现在 `.lua` 里，
 *   说明「当文本读进来再加注释」的流水线把字节烤坏了。
 *
 *   实测抓到（2026-10-19）：
 *     · `prefabs/pocketwatch.lua:148` 代码行 `... haunted by Wanda<FFFD>s timeline`
 *       —— 原文是 `Wanda's`，一个字节被吃掉。
 *     · `nis/xbnyn.lua` 整个文件是 LuaQ 字节码，被当 UTF-8 解码后重写，
 *       正文已不可逆损坏（不是「多了注释」，是「原文没了」）。
 *     · 另有 30+ 行**注释文本**损坏（`无手<FFFD>物` 之类），不影响执行但影响可读性。
 *
 * 判据分层（故意分开，别混）：
 *   ✘ 代码行损坏 / 二进制损坏 ⇒ **不合格**（code=1）
 *   ⚠ 注释文本损坏          ⇒ **可读性缺陷**（code=1，除非 --allow-comment）
 *   ○ 已登记的历史缺陷       ⇒ 不算新问题（见 --baseline）
 *
 * 用法：
 *   node tools/check-annotated-integrity.mjs
 *   node tools/check-annotated-integrity.mjs --allow-comment      # 只卡代码行
 *   node tools/check-annotated-integrity.mjs --baseline <清单>    # 登记已知缺陷
 *   node tools/check-annotated-integrity.mjs --selftest
 */
import {
  readdirSync, statSync, readFileSync, existsSync,
  mkdtempSync, mkdirSync, writeFileSync, rmSync,
} from "node:fs";
import { join, relative, sep, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";

const REPO = dirname(dirname(fileURLToPath(import.meta.url)));
const ANN = join(REPO, "02-注释源码", "scripts");

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const val = (f) => {
  const i = argv.indexOf(f);
  return i < 0 ? null : argv[i + 1] ?? null;
};

const FFFD = "\uFFFD";

function walk(dir, acc = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, acc);
    else if (name.endsWith(".lua")) acc.push(p);
  }
  return acc;
}

/** 是否是「代码行」——与 verify-annotated.mjs 完全同一套口径 */
const isCodeLine = (t) => t !== "" && !t.startsWith("--");

function scan(root) {
  const codeHits = [];
  const commentHits = [];
  const binHits = [];
  let files = 0;

  for (const p of walk(root)) {
    files++;
    const rel = relative(root, p).split(sep).join("/");
    const buf = readFileSync(p);

    // ② 二进制判据：NUL 或 LuaQ 字节码头
    const head = buf.subarray(0, 512).toString("latin1");
    if (buf.includes(0) || /^\u001bLuaQ/.test(head) || head.includes("\u001bLuaQ")) {
      binHits.push({ rel, note: "文件含 NUL / LuaQ 字节码，正文被当文本重写过" });
    }

    const text = buf.toString("utf8");
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i++) {
      if (!lines[i].includes(FFFD)) continue;
      const t = lines[i].trim().replace(/\s+/g, " ");
      (isCodeLine(t) ? codeHits : commentHits).push({
        rel,
        line: i + 1,
        text: lines[i].trim().slice(0, 120),
      });
    }
  }
  return { files, codeHits, commentHits, binHits };
}

function loadBaseline(path) {
  if (!path || !existsSync(path)) return new Set();
  return new Set(
    readFileSync(path, "utf8")
      .split(/\r?\n/)
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith("#"))
  );
}

function selftest() {
  // 造几棵小树，验证各类判据各自能红
  const tmp = mkdtempSync(join(tmpdir(), "cai-"));
  const mk = (name, body) => {
    const d = join(tmp, name);
    mkdirSync(d, { recursive: true });
    writeFileSync(join(d, "a.lua"), body, "utf8");
    return d;
  };
  const cases = [];
  const run = (name, dir, wantCode, opts = {}) => {
    const r = scan(dir);
    let bad = r.codeHits.length + r.binHits.length;
    if (!opts.allowComment) bad += r.commentHits.length;
    const code = bad > 0 ? 1 : 0;
    cases.push({ name, want: wantCode, got: code, detail: `code=${r.codeHits.length} comment=${r.commentHits.length} bin=${r.binHits.length}` });
  };
  run("① 干净文件 ⇒ 0", mk("ok", "local M = {}\n-- 正常注释\nreturn M\n"), 0);
  run("② 代码行损坏 ⇒ 1", mk("code", "local M = {}\nlocal s = 'Wanda" + FFFD + "s'\nreturn M\n"), 1);
  run("③ 注释行损坏 ⇒ 1", mk("cmt", "local M = {}\n-- 无手" + FFFD + "物\nreturn M\n"), 1);
  run("④ 注释行损坏 + --allow-comment ⇒ 0", mk("cmt2", "local M = {}\n-- 无手" + FFFD + "物\nreturn M\n"), 0, { allowComment: true });
  run("⑤ 二进制 ⇒ 1", mk("bin", "\u001bLuaQ\u0000\u0001\u0004binary"), 1);
  rmSync(tmp, { recursive: true, force: true });

  let bad = 0;
  for (const c of cases) {
    const ok = c.got === c.want;
    if (!ok) bad++;
    console.log(`${ok ? "✔" : "✘"} ${c.name}${ok ? "" : `  期望 ${c.want} 实际 ${c.got}`}  ${c.detail}`);
  }
  console.log(`\n自检：${cases.length - bad}/${cases.length} 通过`);
  return bad === 0 ? 0 : 1;
}

if (has("--selftest")) process.exit(selftest());

if (!existsSync(ANN)) {
  console.error(`✘ 找不到注释版根：${ANN}`);
  process.exit(2);
}

// 默认读「已知缺陷登记表」；显式传 --baseline 可换一份
const BASELINE_DEFAULT = join(REPO, "tools", "baseline", "annotated-defects.txt");
const baseline = loadBaseline(val("--baseline") ?? BASELINE_DEFAULT);
const allowComment = has("--allow-comment");
const { files, codeHits, commentHits, binHits } = scan(ANN);

const key = (h) => `${h.rel}`;
const isKnown = (h) => baseline.has(key(h));
const freshBin = binHits.filter((h) => !isKnown(h));
const freshCode = codeHits.filter((h) => !isKnown(h));
const freshCmt = allowComment ? [] : commentHits.filter((h) => !isKnown(h));
const knownCount = binHits.length - freshBin.length + (codeHits.length - freshCode.length) + (commentHits.length - freshCmt.length);

console.log(`注释版根: ${ANN}`);
console.log(`已扫描  : ${files} 个 .lua`);
console.log("");
console.log(`代码行损坏 : ${codeHits.length}`);
console.log(`注释行损坏 : ${commentHits.length}${allowComment ? "（本次不卡）" : ""}`);
console.log(`二进制损坏 : ${binHits.length}`);
console.log(`已登记豁免 : ${knownCount}`);

const dump = (title, arr, mark) => {
  if (arr.length === 0) return;
  console.log(`\n── ${title} ──`);
  for (const h of arr.slice(0, 60)) {
    console.log(`  ${mark} ${h.rel}:${h.line ?? "-"} ${h.text ?? h.note ?? ""}`);
  }
  if (arr.length > 60) console.log(`  ...另有 ${arr.length - 60} 处`);
};

dump("代码行损坏（违反「只增注释」，必须修）", freshCode, "✘");
dump("二进制损坏（原文已不可逆丢失）", freshBin, "✘");
dump("注释行损坏（不影响执行，影响可读性）", freshCmt, "⚠");

const fail = freshCode.length + freshBin.length + freshCmt.length;
if (fail === 0) {
  console.log("\n✅ 通过：没有未登记的编码损坏");
  process.exit(0);
}
console.log(`\n❌ 共 ${fail} 处未登记损坏`);
process.exit(1);
