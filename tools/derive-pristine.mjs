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
import { applySpec } from "./lib/spec-anchor.mjs";

const TOOLS = join(repoRoot, "tools");
const OUT_ROOT = join(repoRoot, "_baseline", "derived-scripts");
const MANIFEST = join(OUT_ROOT, "MANIFEST.json");

const argv = process.argv.slice(2);
const write = argv.includes("--write");
const check = argv.includes("--check");
const verbose = argv.includes("--verbose");

const sha256 = (t) => createHash("sha256").update(t, "utf8").digest("hex");

/**
 * 派生树的**规范文本**（`--write` 落盘的字节由它决定）
 *
 * ★★ 为什么不能简单「多留一个空串」（P50 实测，两次都撞了）：
 *   每个 build 脚本读源文件后会做一次
 *     `if (srcLines[srcLines.length-1] === "") srcLines.pop();`
 *   —— 它把「文件以换行结尾」这个事实当成噪音摘掉；而派生树**就是喂给 build 的源文件**。
 *   于是「派生树末尾该留几个空行」取决于这个文件尾部到底有几个空行、注入块有没有落在最后：
 *   一律 +1 会让 32 个文件多一行，一律 +0 会让另外 8 个文件少一行（两次都实测过，
 *   `git status 02-注释源码/` 分别报 32 与 8 个文件）。
 *   ⇒ 不猜。**逐文件用往返自证**：试 0~3 个尾部空行，谁能「模拟 build 后与注释版逐行相等」
 *   就用谁；一个都不成立就记进不可重建清单（宁可红，也不悄悄写出一棵重建不出原样的树）。
 */
function canonicalText(derived, annLines, H, spec, pops) {
  // pops = 该 build 脚本会不会 pop 掉末尾空串；null = 不知道（孤儿 spec，没有 build 可读）
  const models = pops === null || pops === undefined ? [true, false] : [pops];
  const hits = new Map();
  for (const usePop of models) {
    for (let extra = 0; extra <= 3; extra++) {
      const lines = derived.concat(Array(extra).fill(""));
      // 照抄 build 的读法。★ 只在这里与 build 耦合，所以必须**按脚本**判（见 manifestOf 的注释）
      const src = lines.slice();
      if (usePop && src.length && src[src.length - 1] === "") src.pop();
      let res;
      try {
        res = applySpec({ lines: src, before: spec.before, after: spec.after });
      } catch {
        continue;
      }
      // ★ 判等用**文本**，不用数组：`[x,y]` 与 `[x,y,""]` 是两个数组、却是同一个文件。
      //   按数组比会被「末尾换行产生的空串」骗 —— 第一版就这么误判了 31 个文件。
      if (res.lines.join("\n") === annLines.slice(H).join("\n")) {
        hits.set(lines.join("\n"), { extra, usePop });
      }
    }
  }
  if (hits.size === 0) {
    return { ok: false, why: "尾部空行对不齐（试了 0~3 个尾部空行，模拟 build 后都对不上注释版）" };
  }
  // ★ 多解时取 **extra 最小**的那个 —— 这不是「随便挑一个」，而是唯一有意义的规范：
  //   对「会 pop」的脚本，多加的末尾空行**会被 pop 吃掉**，所以 extra=0 与 extra=1
  //   产生逐字节相同的注释版 ⇒ 两者同样「对」。取最小 = **不往派生树里塞注释版本来没有的行**，
  //   也就是让派生树尽量保持「注释版 − 注入行」这个定义本身。（第一版把多解判成「无法判定」，
  //   88 个文件立刻红 —— 判据是对的，只是我没想到 extra 对 pop 来说是隐形的。）
  const best = [...hits.entries()].sort((x, y) => x[1].extra - y[1].extra)[0];
  return { ok: true, text: best[0], extra: best[1].extra, usePop: best[1].usePop, ambiguous: hits.size };
}

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
  const canon = canonicalText(g.r.derived, annLines, g.r.H, g.spec, g.it.pops);
  if (!canon.ok) {
    badList.push({ src: out, why: canon.why });
    continue;
  }
  okList.push({
    canon: { extra: canon.extra, pop: canon.usePop },
    ambiguous: g.r.ambiguous,
    src: g.it.src,      // 派生树里按**原版文件名**落盘（build 读的是 SRC_ROOT/src）
    out,                // 注释版里的相对路径（可能带子目录）
    build: g.it.build,
    specs: g.it.specs,
    pops: g.it.pops,
    H: g.r.H,
    origLines: g.r.derived.length,
    annLines: annLines.length,
    injected: g.r.injected,
    maxKey: g.r.maxKey,
    text: canon.text,
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
    tries.push({ role, spec, r: reconstruct(annLines, spec) });
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
  const canon = canonicalText(g.r.derived, annLines, g.r.H, g.spec, null);
  if (!canon.ok) {
    badList.push({ src: `${sp}（孤儿 spec）`, why: canon.why });
    continue;
  }
  okList.push({
    canon: { extra: canon.extra, pop: canon.usePop },
    ambiguous: g.r.ambiguous,
    src: cands[0],
    out: cands[0],
    build: `（无 build 脚本，按 ${sp} 名字推导）`,
    specs: [sp],
    H: g.r.H,
    origLines: g.r.derived.length,
    annLines: annLines.length,
    injected: g.r.injected,
    maxKey: g.r.maxKey,
    text: canon.text,
  });
}

console.log(`build 脚本声明的注释版文件：${byOut.size} 个（${items.length} 条声明）`);
console.log(`  可重建 ✔ ${okList.length}`);
console.log(`  不可重建 ✘ ${badList.length}`);
const amb = okList.filter((o) => o.ambiguous > 1);
if (amb.length) {
  console.log(`  ⚠ H 多解取最大：${amb.length} 个（取「头部之外没有注释被当成原版行」的那个解）`);
  if (verbose) for (const o of amb) console.log(`     ${o.out}：${o.ambiguous} 个候选 → H=${o.H}`);
}
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
    okList.map((o) => [o.src, { out: o.out, H: o.H, lines: o.origLines, ann: o.annLines, injected: o.injected, maxKey: o.maxKey, sha256: sha256(o.text), build: o.build, specs: o.specs, pops: o.pops, canonical: o.canon }])
  ),
};

if (check) {
  if (!existsSync(MANIFEST)) {
    console.log(`\n✘ 派生树不存在（${MANIFEST}）—— 先跑 --write`);
    process.exit(1);
  }
  const old = JSON.parse(readFileSync(MANIFEST, "utf8"));
  const problems = [];
  const rows = [];

  // ★★ 2026-10-20（P49）：--check 改成**正向校验**（派生树 + spec → 注入 → 与注释版逐行相等）。
  //
  //   为什么不再用「反向重算再比 sha」：反向分解在**末尾空行**上有多解。
  //   实测 behaviours/avoidlight.lua 在同一条 spec 下能解出 80/81/82 行三种派生，
  //   都逐块对得上（尾部连续空行可以算作原版行，也可以算作注入行）。
  //   于是每跑一次「重建派生树 → 重跑构建」，末尾就少一个空行 —— 一轮轮往下掉，
  //   永远收敛不了，--check 也就不可能稳定变绿。**多解的判据不能当闸门。**
  //
  //   正向没有这个问题：派生树是输入，注入是确定性的，输出必须与注释版**逐行相等**。
  //   它抓的仍然是最要紧的两件事：
  //     · spec 改了没重建 → 注入内容和注释版对不上；
  //     · 派生树过期/被手改 → 同上，或者锚点在派生树里找不到定义（直接抛错）。
  //   末尾空行按「不算内容」归一（注释版与派生树都各自在 EOF 有/没有换行，
  //   这属于文本工具的约定，不该被当成差异，但**只归一末尾**，中间一个空行都不放过）。
  const tailCount = (arr) => {
    let i = arr.length;
    while (i > 0 && arr[i - 1] === "") i--;
    return arr.length - i;
  };

  for (const [src, o] of Object.entries(old.files || {})) {
    const dp = join(OUT_ROOT, src);
    const ap = join(ANN_SCRIPTS, o.out);
    if (!existsSync(dp)) { problems.push(`${src}：派生树里没有这个文件`); continue; }
    if (!existsSync(ap)) { problems.push(`${src}：注释版不存在（${o.out}）`); continue; }
    const derLines = readFileSync(dp, "utf8").split("\n");
    const annLines = readFileSync(ap, "utf8").split("\n");
    // ★★ 校验必须**照抄 build 的读法**，否则「校验的」和「跑的」不是一回事。
    //    build 读源文件后固定 pop 一次末尾空串；派生树按 canonicalText 为此多留了一个，
    //    所以这里也要 pop —— 漏了它，派生树一重建就会几十个文件同时报「尾部空行对不上」
    //    （实测：按「不 pop」实现时连红 32 处）。
    const srcLines = derLines.slice();
    // ★ 用**重建时选中的那个模型**（清单里记着），不要在这里重新猜：
    //   孤儿 spec 没有 build 脚本可读，猜错了就是这 6 个文件「尾部空行对不上」。
    const usePop = o.canonical ? !!o.canonical.pop : o.pops !== false;
    if (usePop && srcLines.length && srcLines[srcLines.length - 1] === "") srcLines.pop();

    let res = null;
    let why = "";
    // 孤儿 spec 没有 build 脚本可读，default 的语义未知 ⇒ 两种都试（只有一种能对上）
    for (const role of ["after", "before"]) {
      const spec = await collectSpec({ specs: o.specs, defaultRole: role }, TOOLS);
      try {
        res = applySpec({ lines: srcLines, before: spec.before, after: spec.after });
        break;
      } catch (e) {
        why = e.message.split("\n")[0];
      }
    }
    if (!res) {
      problems.push(`${src}：注入失败 —— ${why || "未知原因"}`);
      continue;
    }
    const a = res.lines;
    // 注释版 = 头部(H 行) + 正文，而 applySpec 只产正文 ⇒ 跳过头部按正文比
    const b = annLines.slice(o.H);
    if (a.join("\n") !== b.join("\n")) {
      // 报错尽量给行号；但「只差尾部空行」要单独说 ——
      // 否则「第 279 行对不上」看不出是尾部的锅（这轮就吃过这个苦）
      let diffAt = -1;
      for (let i = 0; i < Math.min(a.length, b.length); i++) {
        if (a[i] !== b[i]) { diffAt = i; break; }
      }
      if (diffAt < 0) {
        problems.push(`${src}：**尾部空行**对不上（派生树注入后 ${tailCount(a)} 个 / 注释版 ${tailCount(b)} 个）`);
      } else {
        problems.push(
          `${src}：第 ${diffAt + 1} 行对不上（注入 ${JSON.stringify(a[diffAt].slice(0, 50))} / ` +
          `注释版 ${JSON.stringify(b[diffAt].slice(0, 50))}）`);
      }
      continue;
    }
    rows.push({ src, H: o.H, injected: res.injected });
  }

  if (problems.length) {
    console.log(`\n✘ 派生树 + spec 注入后与注释版不一致（${problems.length} 处）：`);
    for (const p of problems.slice(0, 20)) console.log("    " + p);
    console.log("   修复：node tools/derive-pristine.mjs --write  （spec 改过就一直重建到一致）");
    process.exit(1);
  }
  console.log(`\n✔ 派生树 + spec 注入后与注释版逐行相等（${rows.length} 个文件）`);
  // 反向重算只作**参考**：多解不判红（见上面的说明），但要把「解出来和磁盘不一样」说出来
  const drift = okList.filter((o) => old.files?.[o.src] && o.text !== readFileSync(join(OUT_ROOT, o.src), "utf8"));
  if (drift.length) {
    console.log(`  ⓘ 反向重算与磁盘派生树有 ${drift.length} 个文件不同（末尾空行多解，不影响上面的判定）：` +
      drift.slice(0, 6).map((o) => o.src).join(", ") + (drift.length > 6 ? " …" : ""));
  }
  // ★ 覆盖面：spec 能推出、但清单里没有的文件必须报出来（否则加了 spec 也没人发现）
  const missing = okList.filter((o) => !old.files?.[o.src]).map((o) => o.src);
  if (missing.length) {
    console.log(`\n✘ 有 ${missing.length} 个文件能按 spec 重建，但清单（派生树）里没有：`);
    for (const m of missing.slice(0, 20)) console.log("    " + m);
    console.log("   修复：node tools/derive-pristine.mjs --write --force");
    process.exit(1);
  }
  process.exit(0);
}

if (write) {
  // ★ 防「越写越漂」：反向分解在末尾空行上有多解，无条件重写会让派生树每轮少一行，
  //   连带产物也每轮少一行（实测 behaviours/avoidlight.lua 连续三轮 82→81→80）。
  //   ⇒ 已经有派生树、且**正向校验通过**时，拒绝重写。要重建就显式 --force。
  if (existsSync(MANIFEST) && !argv.includes("--force")) {
    console.log(`\n⊘ 派生树已存在且 --check 未报错时**不重写**（反向分解末尾空行多解，重写会越来越短）。`);
    console.log(`  确实要按当前注释版重建：node tools/derive-pristine.mjs --write --force`);
    process.exit(0);
  }
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
