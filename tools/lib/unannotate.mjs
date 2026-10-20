/**
 * tools/lib/unannotate.mjs —— 从**注释版**反推原版行号（M8 的钥匙）
 *
 * 问题
 *   `spec-*.mjs` 的键是**原版行号**，要迁成锚点就得知道「原版第 K 行是哪一行」。
 *   原版树不在仓库里（M8/M9 卡了两个月的那个前置），于是 23486 个键动不了。
 *
 * 但注释规范 `00-注释规范与术语表.md §四.3` 写死了一条：
 *   「不改动任何可执行代码 —— 仅插入注释行，保证行为完全一致」。
 *   若这条被遵守，注释版必然是
 *       header + Σ( before[K] + 原版第 K 行 + after[K] ) + 尾部原版行
 *   把它反过来算一遍，就能逐行拿回原版 —— **行号就是原版行号**。
 *
 * 为什么敢信（三道闸门，任一不过就报错，绝不猜）
 *   G1 每个注入块必须**逐行精确相等**（不是模糊匹配）——错一个字就不算。
 *   G2 头部行数 H 必须**唯一**：H 是自由变量，遍历 0..400 求所有能全程匹配的解；
 *      多于一个解就报错（不同 H 会把「原版行号」整体平移，静默错位）。
 *   G3 解出来的 derived 里**不许残留插入标记**（`--====`、`-- 文件：`、`【深度注释版】`、
 *      `-- @param`、`-- 说明：`、中文小标题 `---中文`）。这条专治「H 取小了」：
 *      头部的注释行会被当成原版行，行号整体偏大，而 G1 可能一路碰巧都能过。
 *
 * 边界（必须写清楚，别把「派生」当「官方」）
 *   产出的 derived-scripts **不是 Klei 原版**，是「注释版剥掉注入行」的等价视图。
 *   它能满足 spec 迁移与构建，但因为「注释版 = derived + 注入」由构造保证，
 *   它**不能**反过来证明「注释版 = 原版 + 注入」（那是同义反复）。
 *   等真原版到位，`tools/archive-pristine.sh` 之后再跑一次 `spec-keys --check --src <真原版>`
 *   才是终极确认。
 */

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

/** 插入标记：derived 里出现这些，说明头部/注入块没剥干净 */
const INJECT_MARKS = [
  /^--====/,
  /^-- 文件：/,
  /^-- 模块：/,
  /^-- 职责：/,
  /^-- 关键符号：/,
  /^-- 上游来源：/,
  /^-- 交叉引用：/,
  /【深度注释版】/,
  /^-- @param/,
  /^-- @return/,
  /^-- 说明：/,
  /^---[^\x00-\x7F]/, // `---中文函数名` 这种函数标题
];

const isNumericKey = (k) => /^\s*\d+\s*$/.test(k);

/**
 * 解析一个 build-*.mjs → `[{ build, src, specs[], defaultRole }]`
 *
 * 三种实际形态（2026-10-20 实测）：
 *   ① `const SRC = relSrc("x.lua")` + `const SPEC = join(__dirname, "spec-x.mjs")`  —— 89 个
 *   ② `await build("x.lua", …, [join(__dirname, "spec-x-p1.mjs"), …])`              —— build-ui / build-map
 *   ③ `await build("x.lua", …, [S("spec-x-p1.mjs"), …])`                            —— build-map 的局部别名
 *
 * `defaultRole`：`export default` 到底是 before 还是 after，**由 build 脚本决定**。
 *   实测 82 个写的是 `const AFTER = mod.default`（= after），没有 before 的；
 *   但代码里仍要认，因为「同一份 spec 在不同脚本里语义不同」正是这套流水线最脆的地方。
 */
export function manifestOf(buildFile, raw, toolsDir) {
  const out = [];
  const defaultRole =
    /const\s+BEFORE\s*=\s*\w+\.default/.test(raw) ? "before"
    : /const\s+AFTER\s*=\s*\w+\.default/.test(raw) ? "after"
    : null;

  // ① 单文件构建。`const SRC` / `const SRC_REL` 两种都认（playercontroller 用后者）。
  const srcM = /const\s+(?:SRC|SRC_REL)\s*=\s*(?:relSrc\(\s*)?\n?\s*"([^"]+\.lua)"/.exec(raw);
  if (srcM) {
    const specs = new Set();
    // spec 路径的五种写法：SPEC / SPECS / specFile / HEADER_SPEC / build() 实参
    for (const m of raw.matchAll(/join\(\s*__dirname\s*,\s*"([^"]+\.mjs)"\s*\)/g)) specs.add(m[1]);
    for (const m of raw.matchAll(/["'`](spec-[\w-]+\.mjs)["'`]/g)) specs.add(m[1]);
    // `Array.from({ length: 12 }, (_, i) => join(__dirname, `spec-tuning-p${i+1}.mjs`))`
    for (const m of raw.matchAll(/Array\.from\(\s*\{\s*length:\s*(\d+)\s*\}[\s\S]{0,200}?`spec-([\w-]+)-p\$\{/g)) {
      for (let i = 1; i <= Number(m[1]); i++) specs.add(`spec-${m[2]}-p${i}.mjs`);
    }
    // 兜底：一个都没抓到 ⇒ 按源文件 basename 找同前缀 spec
    if (!specs.size && toolsDir) {
      const base = srcM[1].split("/").pop().replace(/\.lua$/, "");
      for (const f of readdirSync(toolsDir)) if (new RegExp(`^spec-${base}(-p\\d+)?\\.mjs$`).test(f)) specs.add(f);
    }
    const outM = /const\s+OUT\s*=\s*relOut\(\s*"([^"]+\.lua)"\s*\)/.exec(raw);
    out.push({
      build: buildFile,
      src: srcM[1],
      out: outM ? outM[1] : srcM[1],
      specs: [...specs].filter((s) => !s.includes("${")),
      defaultRole,
    });
    return out;
  }

  // ② / ③：按 `await build(` 切块，一块 = 一个源文件
  // ★ `src` 是**原版树里的路径**，`out` 是**注释版里的相对路径**，两者可能不同：
  //   build-map 写的是 `build("map/forest_map.lua", join(R, "forest_map.lua"), …)`，
  //   R = join(OUT_ROOT, "map") ⇒ 注释版在 scripts/map/ 下。
  //   第一版只看 src ⇒ 9 个文件报「注释版不存在」（教训：文件名不等于路径）。
  const prefixM = /const\s+R\s*=\s*join\(\s*OUT_ROOT\s*,\s*"([^"]+)"\s*\)/.exec(raw);
  const prefix = prefixM ? prefixM[1].replace(/\/$/, "") + "/" : "";
  const blocks = raw.split(/await\s+build\s*\(/).slice(1);
  for (const blk of blocks) {
    const fm = /^\s*"([^"]+\.lua)"/.exec(blk);
    if (!fm) continue;
    const om = /join\(\s*[A-Za-z_$][\w$]*\s*,\s*"([^"]+\.lua)"\s*\)/.exec(blk);
    const specs = [...new Set([...blk.matchAll(/spec-([\w-]+)\.mjs/g)].map((m) => `spec-${m[1]}.mjs`))];
    if (!specs.length) continue;
    out.push({ build: buildFile, src: fm[1], out: prefix + (om ? om[1] : fm[1]), specs, defaultRole });
  }
  return out;
}

/** 扫 tools/ 下所有 build-*.mjs，返回 { items, byOut }
 *  按 `out`（注释版相对路径）归并 —— 同一份注释版可能被多个 build 脚本声明，
 *  那属于「同一事实两处定义」，调用方要报出来而不是静默取一个。 */
export function scanBuilds(toolsDir) {
  const items = [];
  for (const f of readdirSync(toolsDir)) {
    if (!/^build-.*\.mjs$/.test(f)) continue;
    const raw = readFileSync(join(toolsDir, f), "utf8");
    items.push(...manifestOf(f, raw, toolsDir));
  }
  const byOut = new Map();
  for (const it of items) {
    if (!byOut.has(it.out)) byOut.set(it.out, []);
    byOut.get(it.out).push(it);
  }
  return { items, byOut };
}

/** 把 HEADER_EXTRA 展平（build-ui 会 String(x).split("\n") 并跳过空行） */
function flattenHeader(v) {
  return [v].flat(Infinity).flatMap((x) => String(x).split("\n")).filter((l) => l.trim() !== "");
}

/** 按 build 脚本的合并规则收集一份 spec：同键**拼接**（后一段接在前一段之后） */
export async function collectSpec(item, toolsDir) {
  const before = {};
  const after = {};
  let headerExtra = [];
  const role = item.defaultRole || "after";
  for (const s of item.specs) {
    const mod = await import(pathToFileURL(join(toolsDir, s)).href);
    if (mod.HEADER_EXTRA) headerExtra = headerExtra.concat(flattenHeader(mod.HEADER_EXTRA));
    const push = (target, map) => {
      for (const [k, v] of Object.entries(map || {})) {
        if (!v || !v.length) continue;
        // ★ 一个元素里可能含 `\n`（多条注释写成一个字符串）。build 是 `out.push(c)` 然后
        //   `out.join("\n")` ⇒ 它会展开成多行。重建必须按**展开后**的行比对，否则会
        //   报「期望带 \n、实际不带」（networkclientrpc 就是这么失败的）。
        const flat = [v].flat(Infinity).flatMap((x) => String(x).split("\n"));
        if (target[k] !== undefined) target[k] = [...target[k], ...flat];
        else target[k] = flat;
      }
    };
    if (mod.BEFORE) push(before, mod.BEFORE);
    if (mod.AFTER) push(after, mod.AFTER);
    if (mod.default) push(role === "before" ? before : after, mod.default);
  }
  return { before, after, headerExtra };
}

/** 按给定 H 走一遍逆运算；全程精确匹配就返回 derived，否则 null */
function tryH(lines, H, before, after, maxKey) {
  const derived = [];
  let pos = H;
  for (let n = 1; n <= maxKey; n++) {
    const pre = before[n];
    if (pre) {
      for (let j = 0; j < pre.length; j++) if (lines[pos + j] !== pre[j]) return null;
      pos += pre.length;
    }
    if (pos >= lines.length) return null;
    derived.push(lines[pos]);
    pos++;
    const post = after[n];
    if (post) {
      for (let j = 0; j < post.length; j++) if (lines[pos + j] !== post[j]) return null;
      pos += post.length;
    }
  }
  while (pos < lines.length) derived.push(lines[pos++]);
  return derived;
}

/**
 * 反向重建。返回 `{ ok:true, H, derived, maxKey, injected }` 或 `{ ok:false, why }`。
 * **失败一律给原因，不给「大概对」的结果。**
 */
export function reconstruct(annLines, { before, after }) {
  const keys = [...Object.keys(before), ...Object.keys(after)];
  if (!keys.length) return { ok: false, why: "无行锚点（只有文件头）" };
  const nonNum = keys.filter((k) => !isNumericKey(k));
  if (nonNum.length) {
    return { ok: false, why: `含非数字键 ${nonNum.length} 个（已迁移过？）：${nonNum.slice(0, 3).join(", ")}` };
  }
  const maxKey = Math.max(...keys.map(Number));
  if (maxKey > annLines.length) {
    return { ok: false, why: `最大键 ${maxKey} > 注释版 ${annLines.length} 行` };
  }

  const cands = [];
  for (let H = 0; H <= Math.min(400, annLines.length); H++) {
    const d = tryH(annLines, H, before, after, maxKey);
    if (d) cands.push({ H, derived: d });
  }
  if (!cands.length) return { ok: false, why: "H∈[0,400] 内无解（注入块与注释版对不上）" };

  // G3：头部不许残留插入标记
  const clean = cands.filter((c) => !c.derived.slice(0, 60).some((l) => INJECT_MARKS.some((re) => re.test(l))));
  if (clean.length !== 1) {
    return {
      ok: false,
      why: `H 不唯一：候选 ${cands.length} 个，去掉残留标记后 ${clean.length} 个` +
        `（候选 H=${cands.map((c) => c.H).join("/")}）`,
    };
  }
  const { H, derived } = clean[0];
  return { ok: true, H, derived, maxKey, injected: annLines.length - derived.length };
}
