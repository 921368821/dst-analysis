#!/usr/bin/env node
/**
 * tools/spec-keys.mjs —— 把 spec 的「行号键」迁成「定义名 + 第 n 次」锚点键（M8）
 *
 * 为什么需要（一句话）
 *   257 个 `spec-*.mjs` 里上千个键是**原版行号**。上游插一行，全部注释静默错位，
 *   而 build 脚本不会报错（行号仍在范围内）。锚点键跟函数走，插入多少行都不散。
 *
 * 键的形态
 *   旧：`  134: ["-- ..."]`                      → 注入到源文件第 134 行之前
 *   新：`  "Brain:OnUpdate#1+7": ["-- ..."]`      → 注入到 `Brain:OnUpdate` 第 1 个定义 + 7 行之前
 *   文件头区域（第 1 个定义之前）没有可用的定义名 ⇒ **保留数字键**并计入「未迁移」，
 *   不强行编一个假锚点 —— 宁可留着待办，也不要造一个漂了就错的锚点。
 *
 * 三个必须成立的性质（`--selftest` 逐条验，且都能红）
 *   P1 迁移前后 **注入产物逐字节一致**（同一份源代码 ⇒ 同一份输出）
 *   P2 在上游插入 2 行之后：**数字键错位**、**锚点键仍落在同一函数之前**
 *   P3 坏输入（找不到定义 / 第 n 次不存在）**必须抛错**，不许静默跳过
 *
 * 用法
 *   node tools/spec-keys.mjs --selftest
 *   node tools/spec-keys.mjs --check  tools/spec-brain.mjs --src <原版 lua>
 *   node tools/spec-keys.mjs --migrate tools/spec-brain.mjs --src <原版 lua> [--write]
 *   node tools/spec-keys.mjs --all [--write]        # 扫 build-*.mjs 找出 spec↔源文件
 *   node tools/spec-keys.mjs --all --status         # 只报进度（数字键还剩多少），不需要原版
 *
 * 退出码：0 通过 / 1 有差异或失败 / 2 无法判定（缺原版树等前置）
 */
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdtempSync, mkdirSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { applySpec, definitionIndex, resolveKey, findDefinitions } from "./lib/spec-anchor.mjs";
import { repoRoot, pristineCandidates, relSrc, ANN_SCRIPTS } from "./lib/paths.mjs";
import { scanBuilds } from "./lib/unannotate.mjs";

const TOOLS = join(repoRoot, "tools");

// ─────────────────────── spec 读入 / 键统计 ───────────────────────
/** 读 spec 模块，返回 `[{name, map}]`（default / BEFORE / AFTER 三种导出形态都认）
 *
 * ★ 少数 spec 只提供 `HEADER` / `HEADER_EXTRA`（纯文件头，没有任何行锚点），
 *   它们返回空数组 —— 调用方要把它们记成「无键」，**不能**当成「迁移完成」。
 */
async function loadSpec(file) {
  const url = pathToFileURL(resolve(file)).href + `?t=${Date.now()}`;
  const m = await import(url);
  const out = [];
  if (m.default && typeof m.default === "object") out.push({ name: "default", map: m.default });
  if (m.BEFORE) out.push({ name: "BEFORE", map: m.BEFORE });
  if (m.AFTER) out.push({ name: "AFTER", map: m.AFTER });
  return out;
}

const isNumericKey = (k) => /^\s*\d+\s*$/.test(k);

/** 统计一份 spec 的迁移进度 */
async function status(file) {
  const maps = await loadSpec(file);
  let numeric = 0, anchor = 0, total = 0;
  for (const { map } of maps) {
    for (const k of Object.keys(map)) {
      total++;
      if (isNumericKey(k)) numeric++;
      else anchor++;
    }
  }
  return { numeric, anchor, total, nokey: maps.length === 0 };
}

// ─────────────────────── 迁移：数字键 → 锚点键 ───────────────────────
/**
 * 计算某个行号对应的锚点键。
 * 规则：取**行号之前最近的那个定义**，用「定义名#第几次出现」+ 偏移表达。
 * 第 1 个定义之前（文件头/常量区）→ 返回 null（保留数字键）。
 */
function anchorForLine(lineNo, defs) {
  let best = null;
  const byName = new Map();
  for (const d of defs) {
    if (!byName.has(d.name)) byName.set(d.name, 0);
    byName.set(d.name, byName.get(d.name) + 1);
    if (d.line <= lineNo) best = { name: d.name, nth: byName.get(d.name), line: d.line };
  }
  if (!best) return null;
  const off = lineNo - best.line;
  return off === 0 ? `${best.name}#${best.nth}` : `${best.name}#${best.nth}+${off}`;
}

/** 文本级替换：把 `  134: [` 改成 `  "X#1+7": [`（按出现顺序，一一对应） */
function rewriteText(raw, mapping) {
  let out = "";
  let last = 0;
  const re = /^([ \t]*)(\d+)([ \t]*):\s*\[/gm;
  let m;
  while ((m = re.exec(raw)) !== null) {
    const num = Number(m[2]);
    const key = String(num);
    const anc = mapping.get(key);
    out += raw.slice(last, m.index);
    if (anc) {
      out += `${m[1]}"${anc}"${m[3]}: [`;
    } else {
      out += m[0];                       // 保持原样（文件头区域，无锚点可用）
    }
    last = m.index + m[0].length;
  }
  out += raw.slice(last);
  return out;
}

/** 迁移一个 spec 文件；sync=true 时写回。返回 {ok, info} */
async function migrate(file, src, { write = false } = {}) {
  const raw = readFileSync(file, "utf8");
  const lines = readFileSync(src, "utf8").split("\n");
  const defs = findDefinitions(lines);
  const maps0 = await loadSpec(file);
  if (!maps0.length) return { ok: true, info: "只有文件头、没有行锚点 —— 无需迁移", changed: false };

  // ① 为每个**出现过的**数字键算出锚点
  const mapping = new Map();
  const headerRegion = [];
  for (const m of raw.matchAll(/^[ \t]*(\d+)[ \t]*:\s*\[/gm)) {
    const num = m[1];
    if (mapping.has(num) || headerRegion.includes(num)) continue;
    const anc = anchorForLine(Number(num), defs);
    if (anc) mapping.set(num, anc);
    else headerRegion.push(num);
  }

  // ② 换文本
  const next = rewriteText(raw, mapping);
  if (next === raw && mapping.size === 0) {
    return { ok: true, info: `无数字键可迁（${basename(file)}）`, mapping, headerRegion };
  }

  // ③ 结构校验：新 spec 的每个键都必须解析回**同一行**
  const tmpDir = mkdtempSync(join(tmpdir(), "speckey-"));
  const tmpFile = join(tmpDir, basename(file));
  mkdirSync(tmpDir, { recursive: true });
  writeFileSync(tmpFile, next, "utf8");
  let maps1;
  try {
    maps1 = await loadSpec(tmpFile);
  } catch (e) {
    return { ok: false, info: `迁移后无法 import（语法坏了）：${e.message}` };
  }
  if (maps1.length !== maps0.length) {
    return { ok: false, info: `迁移后导出形态变了（${maps0.length} → ${maps1.length}）` };
  }
  const idx = definitionIndex(lines);
  for (let i = 0; i < maps0.length; i++) {
    const a = maps0[i], b = maps1[i];
    const ka = Object.keys(a.map), kb = Object.keys(b.map);
    if (ka.length !== kb.length) {
      return { ok: false, info: `${a.name}：键数变了 ${ka.length} → ${kb.length}` };
    }
    // ★ 2026-10-20 修正：原先按「位置」逐条比（nums 升序 + others 文本序）。
    //   但 JS 对象枚举的整数键是**数值升序**，而迁移后这些键变成字符串键、按**文本顺序**排列。
    //   原文里若键不是升序写的（如先 900 后 100），两边位置就错开 ⇒ 误报「内容变了」。
    //   改为按**行号**对齐：旧键 → 它该变成的新键 → 比内容，与顺序无关。
    for (const oldKey of ka) {
      const target = isNumericKey(oldKey) ? mapping.get(oldKey) ?? oldKey : oldKey;
      if (!(target in b.map)) {
        return { ok: false, info: `${a.name}：迁移后找不到键 ${target}（原 ${oldKey}）` };
      }
      if (JSON.stringify(a.map[oldKey]) !== JSON.stringify(b.map[target])) {
        return { ok: false, info: `${a.name}：键 ${oldKey} → ${target} 的内容变了 —— 迁移会改内容，拒绝` };
      }
      if (isNumericKey(oldKey) && mapping.has(oldKey)) {
        const got = resolveKey(target, idx, lines.length);
        if (got !== Number(oldKey)) {
          return { ok: false, info: `${a.name}[${oldKey}] → ${target} 解析到第 ${got} 行（期望 ${oldKey}）` };
        }
      }
    }
  }

  // ④ 产物逐字节一致（P1）
  const before = applySpec({ lines, before: maps0.find((x) => x.name === "BEFORE")?.map || {},
                             after: maps0.find((x) => x.name === "AFTER")?.map || {} });
  const after = applySpec({ lines, before: maps1.find((x) => x.name === "BEFORE")?.map || {},
                            after: maps1.find((x) => x.name === "AFTER")?.map || {} });
  if (before.text !== after.text) {
    return { ok: false, info: "注入产物不一致（P1 不成立）—— 拒绝迁移" };
  }

  if (write) writeFileSync(file, next, "utf8");
  return {
    ok: true,
    info: `迁 ${mapping.size} 个键（保留数字键 ${headerRegion.length} 个：文件头区域无定义名可用）`,
    mapping, headerRegion, changed: next !== raw,
  };
}

// ─────────────────────── spec ↔ 源文件：统一用 lib/unannotate 的清单 ───────────────────────
/**
 * ★ 2026-10-20：原先这里自带一份 `discoverPairs()`，只认 `const SRC = "..."` 一种写法，
 *   于是 108 个源文件里只认出 89 个（漏了 SRC_REL / build() 实参 / Array.from 动态分片）。
 *   「同一份事实抄两份 ⇒ 改一处、另一处悄悄过期」—— 这是本工程反复踩的坑，
 *   现在把清单交给 `tools/lib/unannotate.mjs`，与 `derive-pristine` 共用同一份。
 *
 * 孤儿 spec（没有任何 build 脚本声明，但注释版里有同名文件）也纳入：
 * 它们的注释确实被注入过（derive-pristine 能逐行重建），只是构建脚本已不在仓库里。
 */
function discoverPairs() {
  const { items } = scanBuilds(TOOLS);
  const bySpec = new Map();               // spec 文件名 → 原版相对路径
  for (const it of items) for (const s of it.specs) if (!bySpec.has(s)) bySpec.set(s, it.src);

  const ann = [];
  (function walk(d) {
    for (const f of readdirSync(d)) {
      const p = join(d, f);
      if (isDir(p)) walk(p);
      else if (f.endsWith(".lua")) ann.push(p.slice(ANN_SCRIPTS.length + 1).replace(/\\/g, "/"));
    }
  })(ANN_SCRIPTS);

  // ★ 逐个 **spec 文件**给 tail，而不是逐个「manifest 项」：
  //   分片式 spec（spec-health-p1..p3）的键在**分片**里，聚合器本身只有 import，
  //   对聚合器迁移等于什么也没做（第一版就是这样，报了一堆「无数字键可迁」）。
  const specs = readdirSync(TOOLS).filter((f) => /^spec-.*\.mjs$/.test(f) && f !== "spec-keys.mjs");
  const pairs = [];
  for (const f of specs) {
    let src = bySpec.get(f);
    if (!src) {
      const mm = /^(spec-.+)-p\d+\.mjs$/.exec(f);     // 分片 ⇒ 继承聚合器的源文件
      if (mm) src = bySpec.get(`${mm[1]}.mjs`);
    }
    if (!src) {
      // 孤儿 spec：按名字推导（注释版里必须**唯一**同名）
      const base = f.replace(/^spec-/, "").replace(/-p\d+\.mjs$/, "").replace(/\.mjs$/, "");
      const cands = ann.filter((p) => p.split("/").pop() === base + ".lua");
      if (cands.length === 1) src = cands[0];
    }
    if (src) pairs.push({ spec: join(TOOLS, f), tail: src });
  }
  return pairs;
}
function isDir(p) {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}

// ─────────────────────── 自检 ───────────────────────
async function selftest() {
  let bad = 0;
  const ok = (c, msg) => {
    console.log(`  ${c ? "✔" : "✘"} ${msg}`);
    if (!c) bad++;
  };
  const SRC = [
    "-- fake",                                  // 1
    "local M = {}",                             // 2
    "",                                         // 3
    "function Alpha(a)",                        // 4  ← 定义
    "  local x = 1",                            // 5
    "  local y = 2",                            // 6
    "end",                                      // 7
    "",                                         // 8
    "local function Beta()",                    // 9  ← 定义
    "  return 2",                               // 10
    "end",                                      // 11
    "return M",                                 // 12
  ];
  const SPEC_TEXT = `export const BEFORE = {
  4: ["-- α 定义之前"],
  6: ["-- α 体内第 2 行"],
  9: ["-- β 之前"],
};
`;
  const dir = mkdtempSync(join(tmpdir(), "speckey-selftest-"));
  const srcFile = join(dir, "fake.lua");
  const specFile = join(dir, "spec-fake.mjs");
  writeFileSync(srcFile, SRC.join("\n"), "utf8");
  writeFileSync(specFile, SPEC_TEXT, "utf8");

  console.log("── T1 迁移：3 个数字键 → 锚点键 ──");
  const r = await migrate(specFile, srcFile, { write: true });
  ok(r.ok, "迁移成功：" + r.info);
  const after = readFileSync(specFile, "utf8");
  ok(/"Alpha#1":/.test(after), '有 "Alpha#1"（第 4 行 = Alpha 定义行）');
  ok(/"Alpha#1\+2":/.test(after), '有 "Alpha#1+2"（第 6 行 = 定义 + 2）');
  ok(/"Beta#1":/.test(after), '有 "Beta#1"（第 9 行 = local function Beta）');
  ok(!/^\s{2}4:\s*\[/m.test(after), "旧的 4: [ 已被替换掉");

  console.log("── T2 P1：注入产物逐字节不变 ──");
  const lines = SRC.slice();
  const oldMaps = { before: { 4: ["-- α 定义之前"], 6: ["-- α 体内第 2 行"], 9: ["-- β 之前"] } };
  const newMaps = {
    before: { "Alpha#1": ["-- α 定义之前"], "Alpha#1+2": ["-- α 体内第 2 行"], "Beta#1": ["-- β 之前"] },
  };
  const t1 = applySpec({ lines, ...oldMaps }).text;
  const t2 = applySpec({ lines, ...newMaps }).text;
  ok(t1 === t2, "同一份源码：旧键与新键的产物**逐字节相同**");

  console.log("── T3 P2：上游插 2 行 ⇒ 数字键错位、锚点不错位 ──");
  const shifted = ["-- 上游新增 A", "-- 上游新增 B", ...SRC];
  const t3 = applySpec({ lines: shifted, ...oldMaps }).text.split("\n");
  const t4 = applySpec({ lines: shifted, ...newMaps }).text.split("\n");
  const posOf = (arr, txt) => arr.findIndex((l) => l.includes(txt));
  // 旧键：数字 4 = 新第 4 行 = 原第 2 行 `local M = {}` ⇒ 注释粘到了 M 之前（错位）
  const i3 = posOf(t3, "-- α 定义之前");
  const i4 = posOf(t4, "-- α 定义之前");
  ok(!t3[i3 + 1].startsWith("function Alpha("), `数字键已错位（注释后一行是 ${JSON.stringify(t3[i3 + 1])}）`);
  ok(t4[i4 + 1].startsWith("function Alpha("), "锚点键仍精确落在 function Alpha( 之前");

  console.log("── T4 P3：坏输入必须抛错 ──");
  const mustThrow = (fn, what) => {
    try {
      fn();
      ok(false, `${what} —— 没抛错`);
    } catch (e) {
      ok(true, `${what} → ${e.message.split("\n")[0]}`);
    }
  };
  const idx = definitionIndex(SRC);
  mustThrow(() => resolveKey("Gamma#1", idx, SRC.length), "定义名不存在");
  mustThrow(() => resolveKey("Alpha#2", idx, SRC.length), "第 2 次出现不存在");
  mustThrow(() => resolveKey("Alpha#1+99", idx, SRC.length), "偏移越界");

  console.log(bad ? `\n结果：${bad} 条失败` : "\n结果：全绿");
  return bad ? 1 : 0;
}

// ─────────────────────── CLI ───────────────────────
async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes("--selftest")) return selftest();

  const statusOnly = argv.includes("--status");
  const all = argv.includes("--all");
  const write = argv.includes("--write");
  const si = argv.indexOf("--src");
  const srcArg = si >= 0 ? resolve(argv[si + 1]) : null;
  const files = argv.filter((a, i) => !a.startsWith("--") && argv[i - 1] !== "--src");

  // ★ `--status` 是**进度表**（只需 spec 文本，永远能跑）；
  //   `--all`（不带 --write）是**迁移演练**（需要原版，缺则 2）。两者不能混。
  if (statusOnly) {
    // 进度只需要 spec 文本，不需要原版 —— 永远能跑
    const specs = files.length ? files : readdirSync(TOOLS).filter((f) => /^spec-.*\.mjs$/.test(f))
      .map((f) => join(TOOLS, f));
    let num = 0, anc = 0, n = 0, nokey = 0;
    for (const f of specs) {
      const s = await status(f);
      num += s.numeric; anc += s.anchor; n++;
      if (s.nokey) nokey++;
    }
    console.log(`spec 文件 ${n} 个：数字键 ${num} 个 / 锚点键 ${anc} 个（共 ${num + anc}）`);
    if (nokey) console.log(`  其中 ${nokey} 个 spec 只有文件头（HEADER/HEADER_EXTRA），没有行锚点 —— 不参与迁移`);
    console.log(num === 0 ? "✔ 已全部锚点化" :
      `⚠ 还有 ${num} 个数字键待迁移（需要原版源码才能算出锚点）`);
    return num === 0 ? 0 : 1;
  }

  if (!all && !files.length) {
    console.error("用法见文件头：--selftest / --status / --check / --migrate <spec> --src <lua> / --all");
    return 2;
  }

  // 需要原版源码：没有就明确「无法判定」，绝不退回注释版
  let pairs;
  if (all) {
    pairs = discoverPairs();
  } else {
    if (!srcArg) {
      try {
        relSrc("scripts/x.lua");    // 只为触发「没有原版」的统一报错
      } catch {
        /* 继续走下面的统一提示 */
      }
    }
    pairs = files.map((f) => ({ spec: resolve(f), tail: null, explicitSrc: srcArg }));
  }

  let bad = 0, done = 0, cannot = 0;
  if (all && !pairs.length) {
    console.log("⊘ 一条 spec↔源文件 的对应关系都没认出来 —— 本命令什么也没做。");
    console.log("  （build-*.mjs 里的 SRC 既不是 `relSrc(\"x.lua\")` 也不是字面量路径？）");
    return 2;
  }
  for (const p of pairs) {
    let src = p.explicitSrc || null;
    if (!src) {
      try {
        src = relSrc(p.tail);
      } catch (e) {
        cannot++;
        if (cannot === 1) console.log("⊘ 无法判定：" + e.message.split("\n")[0]);
        continue;
      }
    }
    const r = await migrate(p.spec, src, { write });
    if (!r.ok) {
      bad++;
      console.log(`  ✘ ${basename(p.spec)}：${r.info}`);
    } else if (r.changed !== false) {
      done++;
      console.log(`  ✔ ${basename(p.spec)}：${r.info}${write ? "" : "（演练，未写回）"}`);
    }
  }
  console.log(`\n结果：迁移 ${done} 个 / 失败 ${bad} 个 / 无法判定 ${cannot} 个`);
  if (cannot && !done && !bad) {
    console.log("→ 前置缺失：先 `bash tools/archive-pristine.sh <原版 scripts 根>`，再重跑本命令。");
    return 2;
  }
  return bad ? 1 : 0;
}

main().then((rc) => process.exit(rc)).catch((e) => {
  console.error("✘ " + (e && e.message ? e.message : e));
  process.exit(1);
});
