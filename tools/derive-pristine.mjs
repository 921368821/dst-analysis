#!/usr/bin/env node
/**
 * tools/derive-pristine.mjs —— 生成「派生原版树」（`_baseline/derived-scripts/`）
 *
 * 干什么
 *   把 `02-注释源码/scripts/` 的每个文件，按其 spec 逆运算剥掉注入的注释行，
 *   得到一份**行号即原版行号**的等价视图。这是 M8 迁移 23486 个数字键所缺的那把钥匙。
 *
 * 不是什么（诚实边界）
 *   它**不是** Klei 原版。它是「注释版 − 注入行」，由构造保证。
 *   ⇒ 它能用来算锚点、能让 build 脚本跑起来；
 *   ⇒ 它**不能**用来证明「注释版 = 原版 + 注释」（同义反复）。
 *   真原版到位后仍要 `archive-pristine.sh` + `spec-keys --check --src <真原版>`。
 *
 * 用法
 *   node tools/derive-pristine.mjs                 # 只报：多少文件可重建 / 多少不可
 *   node tools/derive-pristine.mjs --write         # 写 _baseline/derived-scripts/ + MANIFEST.json
 *   node tools/derive-pristine.mjs --check         # 闸门：磁盘上的派生树与「按当前 spec 重算」一致
 *   node tools/derive-pristine.mjs --verbose
 *
 * 退出码：0 全部可重建且 --check 一致 / 1 有文件不可重建或不一致 / 2 找不到注释版
 */
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { createHash } from "node:crypto";
import { repoRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { scanBuilds, collectSpec, reconstruct } from "./lib/unannotate.mjs";

const TOOLS = join(repoRoot, "tools");
const OUT_ROOT = join(repoRoot, "_baseline", "derived-scripts");
const MANIFEST = join(OUT_ROOT, "MANIFEST.json");

const argv = process.argv.slice(2);
const write = argv.includes("--write");
const check = argv.includes("--check");
const verbose = argv.includes("--verbose");

const sha256 = (t) => createHash("sha256").update(t, "utf8").digest("hex");

if (!existsSync(ANN_SCRIPTS)) {
  console.error(`✘ 找不到注释版：${ANN_SCRIPTS}`);
  process.exit(2);
}

const { items, byOut } = scanBuilds(TOOLS);

// 同一个源文件被多个 build 脚本构建 —— 「同一事实两处定义」，必须报出来（不静默取其一）
const dup = [...byOut.entries()].filter(([, v]) => v.length > 1);

const okList = [];
const badList = [];

for (const [out, its] of [...byOut.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
  const annPath = join(ANN_SCRIPTS, out);
  if (!existsSync(annPath)) {
    badList.push({ src: out, why: "注释版不存在" });
    continue;
  }
  const annLines = readFileSync(annPath, "utf8").split("\n");
  // 多脚本构建同一文件时，用「能重建成功」的那个；都不成再报错
  const results = [];
  for (const it of its) {
    const spec = await collectSpec(it, TOOLS);
    results.push({ it, spec, r: reconstruct(annLines, spec) });
  }
  const good = results.filter((x) => x.r.ok);
  if (!good.length) {
    badList.push({ src: out, why: results.map((x) => `${x.it.build}: ${x.r.why}`).join("；") });
    continue;
  }
  if (new Set(good.map((x) => x.r.derived.join("\n"))).size > 1) {
    badList.push({ src: out, why: `多个 build 脚本重建出不同结果：${good.map((x) => x.it.build).join(", ")}` });
    continue;
  }
  const g = good[0];
  okList.push({
    src: g.it.src,      // 派生树里按**原版文件名**落盘（build 读的是 SRC_ROOT/src）
    out,                // 注释版里的相对路径（可能带子目录）
    build: g.it.build,
    specs: g.it.specs,
    H: g.r.H,
    origLines: g.r.derived.length,
    annLines: annLines.length,
    injected: g.r.injected,
    maxKey: g.r.maxKey,
    text: g.r.derived.join("\n"),
  });
}

// ── 孤儿 spec：没有 build 脚本声明它，但注释版里能找到同名文件 ──
//    这批 spec 的注释**确实被注入过**（产物能逐行对上），只是构建脚本已不在仓库里
//    （networking / world / sanity / hunger / mainfunctions / shardnetworking 等）。
//    对它们仍然可以反推原版 —— 判据和别处一样：注入块必须逐行精确相等。
function walkLua(d, out = []) {
  for (const f of readdirSync(d)) {
    const p = join(d, f);
    if (statSync(p).isDirectory()) walkLua(p, out);
    else if (f.endsWith(".lua")) out.push(p.slice(ANN_SCRIPTS.length + 1).replace(/\\/g, "/"));
  }
  return out;
}
const annFiles = walkLua(ANN_SCRIPTS);
const usedSpecs = new Set(items.flatMap((i) => i.specs));
const importedSpecs = new Set();
for (const f of readdirSync(TOOLS).filter((x) => /^spec-.*\.mjs$/.test(x))) {
  const s = readFileSync(join(TOOLS, f), "utf8");
  for (const m of s.matchAll(/import\(\s*"\.\/(spec-[\w-]+\.mjs)"\s*\)/g)) importedSpecs.add(m[1]);
}
// spec-keys.mjs 是工具不是 spec（`spec-` 前缀撞上了），显式排除
const leftovers = readdirSync(TOOLS).filter(
  (f) => /^spec-.*\.mjs$/.test(f) && !usedSpecs.has(f) && !importedSpecs.has(f) && f !== "spec-keys.mjs"
);

for (const sp of leftovers) {
  const base = sp.replace(/^spec-/, "").replace(/\.mjs$/, "");
  const cands = annFiles.filter((p) => p.split("/").pop() === base + ".lua");
  if (cands.length !== 1) {
    badList.push({ src: `${sp}（孤儿 spec）`, why: cands.length ? `同名注释版有 ${cands.length} 个：${cands.join(", ")}` : `注释版里没有 ${base}.lua` });
    continue;
  }
  const annLines = readFileSync(join(ANN_SCRIPTS, cands[0]), "utf8").split("\n");
  // default 的语义未知（没有 build 脚本可读）⇒ 两种都试；只有一种成立才采纳
  const tries = [];
  for (const role of ["after", "before"]) {
    const spec = await collectSpec({ specs: [sp], defaultRole: role }, TOOLS);
    tries.push({ role, r: reconstruct(annLines, spec) });
  }
  const good = tries.filter((t) => t.r.ok);
  if (!good.length) {
    badList.push({ src: `${sp}（孤儿 spec）`, why: tries.map((t) => `${t.role}: ${t.r.why}`).join("；") });
    continue;
  }
  if (new Set(good.map((t) => t.r.derived.join("\n"))).size > 1) {
    badList.push({ src: `${sp}（孤儿 spec）`, why: `default 按 after/before 解释得到不同结果，无法判定` });
    continue;
  }
  const g = good[0];
  okList.push({
    src: cands[0],
    out: cands[0],
    build: `（无 build 脚本，按 ${sp} 名字推导）`,
    specs: [sp],
    H: g.r.H,
    origLines: g.r.derived.length,
    annLines: annLines.length,
    injected: g.r.injected,
    maxKey: g.r.maxKey,
    text: g.r.derived.join("\n"),
  });
}

console.log(`build 脚本声明的注释版文件：${byOut.size} 个（${items.length} 条声明）`);
console.log(`  可重建 ✔ ${okList.length}`);
console.log(`  不可重建 ✘ ${badList.length}`);
if (dup.length) {
  console.log(`\n⚠ 同一源文件被多个 build 脚本构建（${dup.length} 个）：`);
  for (const [src, v] of dup) console.log(`    ${src} ← ${v.map((x) => x.build).join(", ")}`);
}
if (badList.length) {
  console.log(`\n✘ 不可重建清单：`);
  for (const b of badList) console.log(`    ${b.src} —— ${b.why}`);
}
if (verbose) {
  for (const o of okList) {
    console.log(`  ✔ ${o.out} → ${o.src}  H=${o.H}  ${o.origLines}/${o.annLines} 行  maxKey=${o.maxKey}`);
  }
}
const allSpecs = readdirSync(TOOLS).filter((f) => /^spec-.*\.mjs$/.test(f) && f !== "spec-keys.mjs");
console.log(`\nspec 文件 ${allSpecs.length} 个：build 直接声明 ${usedSpecs.size} 个 / 聚合器 import ${importedSpecs.size} 个 / 孤儿 ${leftovers.length} 个`);
if (leftovers.length) console.log(`    孤儿（按名字推导）：${leftovers.join(", ")}`);

const manifest = {
  generated_by: "tools/derive-pristine.mjs",
  note:
    "派生原版：由 02-注释源码 剥掉 spec 注入行得到，行号 = 原版行号。" +
    "它不是 Klei 原版，不能用于证明「注释版 = 原版 + 注释」。",
  totals: { ok: okList.length, bad: badList.length, annLines: okList.reduce((a, x) => a + x.annLines, 0) },
  files: Object.fromEntries(
    okList.map((o) => [o.src, { out: o.out, H: o.H, lines: o.origLines, ann: o.annLines, injected: o.injected, maxKey: o.maxKey, sha256: sha256(o.text), build: o.build, specs: o.specs }])
  ),
};

if (check) {
  if (!existsSync(MANIFEST)) {
    console.log(`\n✘ 派生树不存在（${MANIFEST}）—— 先跑 --write`);
    process.exit(1);
  }
  const old = JSON.parse(readFileSync(MANIFEST, "utf8"));
  const problems = [];
  for (const [src, o] of Object.entries(manifest.files)) {
    const p = join(OUT_ROOT, src);
    if (!existsSync(p)) { problems.push(`${src}：文件缺失`); continue; }
    const disk = readFileSync(p, "utf8");
    if (sha256(disk) !== o.sha256) problems.push(`${src}：内容与当前 spec 重算不一致`);
    const prev = old.files?.[src];
    if (!prev) problems.push(`${src}：旧清单里没有（spec 覆盖变多了？）`);
    else if (prev.sha256 !== o.sha256) problems.push(`${src}：与旧清单记录的指纹不同（spec 改过但没重跑 --write）`);
  }
  for (const src of Object.keys(old.files || {})) {
    if (!manifest.files[src]) problems.push(`${src}：旧清单有、现在算不出来`);
  }
  if (problems.length) {
    console.log(`\n✘ 派生树与 spec 不一致（${problems.length} 处）：`);
    for (const p of problems.slice(0, 20)) console.log("    " + p);
    console.log("   修复：node tools/derive-pristine.mjs --write");
    process.exit(1);
  }
  console.log(`\n✔ 派生树与当前 spec 一致（${Object.keys(manifest.files).length} 个文件）`);
  process.exit(badList.length ? 1 : 0);
}

if (write) {
  mkdirSync(OUT_ROOT, { recursive: true });
  for (const o of okList) {
    const p = join(OUT_ROOT, o.src);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, o.text, "utf8");
  }
  writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + "\n", "utf8");
  console.log(`\n✔ 已写入 ${okList.length} 个文件 → ${OUT_ROOT}`);
  console.log(`  MANIFEST.json：${Object.keys(manifest.files).length} 条（含 sha256 / H / 行数）`);
}

process.exit(badList.length ? 1 : 0);
