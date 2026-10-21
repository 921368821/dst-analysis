#!/usr/bin/env node
/**
 * verify-annotated.mjs —— 注释版 Lua 源码完整性校验器（v2）
 *
 * 用途：确认「中文注释版」相对「原版」只增加了注释行，
 *      没有意外改动任何可执行代码。这是对 4030 个文件批量注释的质量底线。
 *
 * 校验规则：
 *   1. 去掉空行与纯注释行（trim 后以 -- 开头）后，两边应逐行完全一致
 *   2. 比较时忽略行首缩进差异与连续空白差异（Lua 语义不受影响）
 *   3. 关键：关键字 local / function 等作用域修饰符必须严格一致
 *
 * ============================================================================
 * ★ v2 改了什么（M9）
 *
 *   ① **「自己比自己」必须报错，不许当通过**。
 *      原版副本已随旧用户目录消失，`DST_SRC` 于是退化成 `02-注释源码/scripts`
 *      —— 而 `tools/check-behaviours.sh` 正是拿 `$DST_SRC` 当「原版根」传进来的。
 *      于是「校验通过」= 同一棵树和自己比。这是**假绿**，比红更坏。
 *      ⇒ 现在 realpath 相同就退出 2（无法复验），永远不退出 0。
 *
 *   ② 退出码语义分开，别再混：
 *        0 = 真的比过，且一致
 *        1 = 真的比过，发现不一致（代码被改动了）
 *        2 = **无法复验**（缺原版根 / 两棵树相同 / 清单缺失）
 *      把「没验」和「验过了没问题」混成 0，等于把承诺作废。
 *
 *   ③ `--stamp` / `--manifest`：原件拿不回来时，**至少把证据固化下来**。
 *      在有原版的那一刻跑一次 `--stamp`，把每个文件「代码行规范化后的 sha256」
 *      写进清单（几 KB，可入库）；以后没有原件也能用 `--manifest` 复验。
 *      清单来自原版 ⇒ 比对不是循环论证。
 *
 * 用法：
 *   node verify-annotated.mjs <原版根> <注释版根>
 *   node verify-annotated.mjs --stamp <原版根> --out <清单.json>
 *   node verify-annotated.mjs --manifest <清单.json> <注释版根>
 *   node verify-annotated.mjs --selftest
 *===========================================================================
 */
import { readdirSync, statSync, readFileSync, writeFileSync, mkdtempSync, mkdirSync, rmSync, realpathSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";

const EXIT_OK = 0;
const EXIT_DIFF = 1;
const EXIT_CANNOT = 2;

// ---------------------------------------------------------------------------
// 基础工具
// ---------------------------------------------------------------------------

function die(msg, code = EXIT_CANNOT) {
  console.error(`✘ ${msg}`);
  process.exit(code);
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

/** 代码行的指纹：整个「规范化代码行序列」的 sha256（与注释无关） */
function codeHash(file) {
  return createHash("sha256").update(codeLines(file).join("\n"), "utf8").digest("hex");
}

/** 判断两个路径是不是同一棵树（realpath 归一 + Windows 大小写不敏感） */
function sameTree(a, b) {
  const norm = (p) => {
    let r = resolve(p);
    try {
      r = realpathSync(r);
    } catch {
      /* 不存在就走原样，交给上层报「根不存在」 */
    }
    return process.platform === "win32" ? r.toLowerCase() : r;
  };
  return norm(a) === norm(b);
}

// ---------------------------------------------------------------------------
// 三种模式
// ---------------------------------------------------------------------------

/** 对比两棵树 */
function compareTrees(srcRoot, dstRoot) {
  if (!statSync(srcRoot, { throwIfNoEntry: false })?.isDirectory())
    return { code: EXIT_CANNOT, msg: `原版根不存在或不是目录：${srcRoot}` };
  if (!statSync(dstRoot, { throwIfNoEntry: false })?.isDirectory())
    return { code: EXIT_CANNOT, msg: `注释版根不存在或不是目录：${dstRoot}` };
  if (sameTree(srcRoot, dstRoot))
    return {
      code: EXIT_CANNOT,
      msg:
        `原版根与注释版根是**同一棵树**：${srcRoot}\n` +
        `  ⇒ 这是「自己比自己」，必然全过 —— 不能当作校验结果。\n` +
        `  修法：给真正的原版 scripts 根（游戏 data/databundles/scripts 解包目录），\n` +
        `        或用 \`--manifest <清单>\` 复验（清单需先由 --stamp 从原版生成）。`,
    };

  const srcFiles = walk(srcRoot);
  if (srcFiles.length === 0) return { code: EXIT_CANNOT, msg: `原版根里没有任何 .lua：${srcRoot}` };

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
  // ★ 退出码就是结论：没问题是 0，有问题就是 1 —— 别再让调用方自己判
  return { code: problems.length === 0 ? EXIT_OK : EXIT_DIFF, checked, total: srcFiles.length, problems };
}

/** 从原版根生成清单（固化为可入库的证据） */
function stamp(srcRoot, outPath) {
  if (!statSync(srcRoot, { throwIfNoEntry: false })?.isDirectory())
    return { code: EXIT_CANNOT, msg: `原版根不存在：${srcRoot}` };
  const files = {};
  let totalLines = 0;
  for (const src of walk(srcRoot)) {
    const rel = relative(srcRoot, src).split(sep).join("/");
    files[rel] = { sha256: codeHash(src), lines: codeLines(src).length };
    totalLines += files[rel].lines;
  }
  if (Object.keys(files).length === 0) return { code: EXIT_CANNOT, msg: `原版根里没有 .lua：${srcRoot}` };
  const manifest = {
    version: 1,
    kind: "dst-pristine-code-manifest",
    note: "代码行（去空行/去纯注释/空白归一）的 sha256。注释版增减注释不会改变它 ⇒ 可代替原版树做复验。",
    source_root: srcRoot,
    generated_at: new Date().toISOString(),
    file_count: Object.keys(files).length,
    code_lines: totalLines,
    files,
  };
  writeFileSync(outPath, JSON.stringify(manifest, null, 1), "utf8");
  return { code: EXIT_OK, manifest, outPath };
}

/** 用清单复验注释版（原版不在场也能比） */
function compareToManifest(manifestPath, dstRoot) {
  let manifest;
  try {
    manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  } catch (e) {
    return { code: EXIT_CANNOT, msg: `清单读不了：${manifestPath}（${e.message}）` };
  }
  if (manifest?.kind !== "dst-pristine-code-manifest")
    return { code: EXIT_CANNOT, msg: `不是本工具的清单（kind=${manifest?.kind}）：${manifestPath}` };
  if (!statSync(dstRoot, { throwIfNoEntry: false })?.isDirectory())
    return { code: EXIT_CANNOT, msg: `注释版根不存在：${dstRoot}` };

  const problems = [];
  let checked = 0;
  for (const [rel, want] of Object.entries(manifest.files)) {
    const dst = join(dstRoot, rel);
    let got;
    try {
      got = codeHash(dst);
    } catch {
      problems.push({ rel, reason: "注释版缺失该文件" });
      continue;
    }
    checked++;
    if (got !== want.sha256) {
      const n = codeLines(dst).length;
      problems.push({
        rel,
        reason: `代码行指纹不符（清单 ${want.lines} 行 vs 实际 ${n} 行）`,
      });
    }
  }
  return { code: problems.length === 0 ? EXIT_OK : EXIT_DIFF, checked, total: Object.keys(manifest.files).length, problems };
}

// ---------------------------------------------------------------------------
// 自检：校验器自己必须有判据（否则它「绿」也只是没跑）
// ---------------------------------------------------------------------------
function selftest() {
  const root = mkdtempSync(join(tmpdir(), "va-selftest-"));
  const mk = (d, files) => {
    for (const [rel, body] of Object.entries(files)) {
      const p = join(d, rel);
      mkdirSync(join(p, ".."), { recursive: true });
      writeFileSync(p, body, "utf8");
    }
  };
  const cases = [];
  const run = (name, fn, want) => {
    let got;
    try {
      got = fn();
    } catch (e) {
      got = { code: -1, msg: String(e) };
    }
    cases.push({ name, want, got: got.code, msg: got.msg ?? "" });
  };

  const ORIG = "local M = {}\nfunction M.f()\n  return 1\nend\nreturn M\n";
  const SRC = join(root, "src");
  const DST_OK = join(root, "dst-ok");
  const DST_BAD = join(root, "dst-bad");
  const DST_MISS = join(root, "dst-miss");
  mk(SRC, { "a/b.lua": ORIG });
  // 只加注释（长注释块按 SOP 每行都带 `--` 前缀；再加一处行首缩进差异）
  // ⚠️ 注意：本校验器只把「整行以 -- 开头」当注释。
  //    长注释块里若有一行没写 `--`（如 `--[[` 之后的裸文本），那行会被当**代码**
  //    ⇒ 报红。这是刻意保守：宁可报红让人去看，也不要放过一行「看起来像注释」的代码。
  mk(DST_OK, {
    "a/b.lua": "--[[\n-- 说明\n--]]\nlocal M = {}   \n   -- 缩进注释\nfunction M.f()\n  return 1\nend\nreturn M\n",
  });
  // 偷改一个字符
  mk(DST_BAD, { "a/b.lua": ORIG.replace("return 1", "return 2") });
  // 少文件
  mk(DST_MISS, { "other.lua": ORIG });

  run("① 只加注释 ⇒ 0", () => compareTrees(SRC, DST_OK), EXIT_OK);
  run("② 改一个字符 ⇒ 1", () => compareTrees(SRC, DST_BAD), EXIT_DIFF);
  run("③ 注释版缺文件 ⇒ 1", () => compareTrees(SRC, DST_MISS), EXIT_DIFF);
  run("④ 原版根不存在 ⇒ 2", () => compareTrees(join(root, "nope"), DST_OK), EXIT_CANNOT);
  run("⑤ 同一棵树（自己比自己）⇒ 2", () => compareTrees(SRC, SRC), EXIT_CANNOT);

  const mf = join(root, "manifest.json");
  run("⑥ --stamp 生成清单 ⇒ 0", () => stamp(SRC, mf), EXIT_OK);
  run("⑦ 清单复验（只加注释）⇒ 0", () => compareToManifest(mf, DST_OK), EXIT_OK);
  run("⑧ 清单复验（改字符）⇒ 1", () => compareToManifest(mf, DST_BAD), EXIT_DIFF);
  run("⑨ 清单复验（缺文件）⇒ 1", () => compareToManifest(mf, DST_MISS), EXIT_DIFF);

  // 「自己比自己」那条要真的**报出原因**，不是碰巧退出 2
  const self = compareTrees(SRC, SRC);
  const reasonOk = self.code === EXIT_CANNOT && /同一棵树/.test(self.msg);
  cases.push({ name: "⑩ 同一棵树要说明原因", want: true, got: reasonOk, msg: "" });

  rmSync(root, { recursive: true, force: true });

  let bad = 0;
  for (const c of cases) {
    const ok = c.got === c.want;
    if (!ok) bad++;
    console.log(`${ok ? "✔" : "✘"} ${c.name}${ok ? "" : `  期望 ${c.want} 实际 ${c.got}  ${c.msg}`}`);
  }
  // ★ 自检也要守住「用例还在不在」：删几条用例、剩下全过，exit code 仍是 0，
  //   而这条自检就在静默变松（开发计划 §9cd / §9cg）。
  const WANT_CASES = 10;               // 加/删用例必须同步改这里，并同步 tools/case_counts.txt
  if (cases.length !== WANT_CASES) {
    console.log(`  ✘ 自检用例 ${cases.length} 条，期望 ${WANT_CASES} 条 —— 加/删用例时必须同步 WANT_CASES，否则这条自检会静默变松`);
    bad++;
  }
  console.log(`\n自检：${cases.length - bad}/${cases.length} 通过（用例 ${cases.length} 条）`);
  return bad === 0 ? EXIT_OK : EXIT_DIFF;
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
const argv = process.argv.slice(2);

function flag(name) {
  const i = argv.indexOf(name);
  if (i < 0) return null;
  return argv[i + 1] ?? null;
}

if (argv.includes("--selftest")) {
  process.exit(selftest());
}

if (argv.includes("--stamp")) {
  const src = flag("--stamp");
  const out = flag("--out") ?? "pristine-code.sha256.json";
  if (!src) die("--stamp 需要一个原版根参数");
  const r = stamp(src, out);
  if (r.code !== EXIT_OK) die(r.msg);
  console.log(`✔ 清单已写入 ${out}`);
  console.log(`  文件 ${r.manifest.file_count} 个 / 代码行 ${r.manifest.code_lines} 行`);
  console.log(`  来源 ${r.manifest.source_root}`);
  process.exit(EXIT_OK);
}

if (argv.includes("--manifest")) {
  const mf = flag("--manifest");
  const rest = argv.filter((a) => a !== "--manifest" && a !== mf);
  const dst = rest[0];
  if (!mf || !dst) die("用法: --manifest <清单.json> <注释版根>");
  const r = compareToManifest(mf, dst);
  if (r.code === EXIT_CANNOT) die(r.msg);
  report(r, `清单 ${mf}`, dst);
  process.exit(r.code);
}

const [srcRoot, dstRoot] = argv;
if (!srcRoot || !dstRoot) {
  console.error("用法: node verify-annotated.mjs <原版根> <注释版根>");
  console.error("      node verify-annotated.mjs --stamp <原版根> --out <清单.json>");
  console.error("      node verify-annotated.mjs --manifest <清单.json> <注释版根>");
  console.error("      node verify-annotated.mjs --selftest");
  process.exit(EXIT_CANNOT);
}

const res = compareTrees(srcRoot, dstRoot);
if (res.code === EXIT_CANNOT) die(res.msg);
report(res, srcRoot, dstRoot);
process.exit(res.code);

function report(r, srcLabel, dstLabel) {
  console.log(`原版: ${srcLabel}`);
  console.log(`注释: ${dstLabel}`);
  console.log(`检查文件数: ${r.checked}/${r.total}`);
  if (r.problems.length === 0) {
    console.log("✅ 全部通过：注释版仅增加注释，可执行代码与原版完全一致");
    return;
  }
  console.log(`❌ 发现 ${r.problems.length} 个问题：`);
  for (const p of r.problems.slice(0, 40)) console.log(`  [${p.rel}] ${p.reason}`);
  if (r.problems.length > 40) console.log(`  ...另有 ${r.problems.length - 40} 个问题`);
}
