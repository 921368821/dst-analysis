/**
 * tools/lib/spec-anchor.mjs —— 注释规格的「锚点定位」层（M8 的核心）
 *
 * 问题（为什么行号锚点不行）
 *   `tools/spec-*.mjs` 里的键是**原版源文件的行号**：`BEFORE = { 134: [...] }`。
 *   只要上游（或我们自己）在文件里**插入一行**，134 就指向别处 ——
 *   轻则注释贴错函数，重则贴进字符串中间。257 个 spec 文件、上千个数字键，
 *   等于「源码一动，全部注释静默错位」，而 build 脚本**不会报错**（行号还在范围内）。
 *   这就是 M8 要修的：键改成「**定义名 + 第 n 次出现**」，位置跟着函数走。
 *
 * 键的两种形态（向后兼容，但新写法只许用一种）
 *   134            —— 旧：注入到**第 134 行之前**（1-based，与原 build 脚本语义完全一致）
 *   "Alpha#2"      —— 新：注入到 `Alpha` 的**第 2 个定义**那一行之前
 *   定义名取 `function` 关键字后面的完整标识符，包含类/表前缀与冒号：
 *     `function Brain:OnUpdate(`  ⇒ `Brain:OnUpdate`
 *     `local function ShouldRetreat(` ⇒ `ShouldRetreat`
 *     `SGwilson.OnEnter = function(` ⇒ `SGwilson.OnEnter`
 *
 * 纪律
 *   ① **绝不静默跳过**：名字找不到、第 n 次不存在、行号越界 —— 一律抛错并说清是哪一条。
 *      （「静默跳过」在本工程是有前科的：verify-syntax.py 曾把全部失败记成「基线」，
 *      于是「真缺陷」恒为 0，看着全绿。）
 *   ② 数值键仍然放行（老 spec 还有 200 多个），但 `--check` 会把它们统计出来，
 *      迁移进度是**可测的量**，不是「大概改完了」。
 *   ③ 注入内容一律以 `--` 开头（沿用 build 脚本的 assertComment），防止把代码写进注释层。
 *
 * 自检：node tools/lib/spec-anchor.mjs --selftest   （必须能「红」，见 S3/S4）
 */

/**
 * 找出一份 Lua 源码里所有「可当锚点的定义」，返回 `[{name, line, kind}]`（line 1-based）。
 * 只认三种常见定义形态 —— 认不出的（如 `t[k] = function`）会被忽略，
 * 这是**刻意的**：宁可让 spec 报「锚点找不到」，也不要猜错位置。
 */
export function findDefinitions(lines) {
  const defs = [];
  const re1 = /^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\(/;      // function X( / local function X(
  const re2 = /^\s*([A-Za-z_][\w.:]*)\s*=\s*function\s*\(/;               // X = function(
  for (let i = 0; i < lines.length; i++) {
    const s = lines[i];
    let m = re1.exec(s);
    if (m) {
      defs.push({ name: m[1], line: i + 1, kind: "function" });
      continue;
    }
    m = re2.exec(s);
    if (m) defs.push({ name: m[1], line: i + 1, kind: "assign" });
  }
  return defs;
}

/** 名字 → 该名字的所有定义行号（按出现顺序） */
export function definitionIndex(lines) {
  const idx = new Map();
  for (const d of findDefinitions(lines)) {
    if (!idx.has(d.name)) idx.set(d.name, []);
    idx.get(d.name).push(d.line);
  }
  return idx;
}

/**
 * 解析一个 spec 键 → 注入行号（1-based）。
 * 数值键：原样返回（但仍检查越界）；字符串键：`name#n`。
 */
export function resolveKey(key, index, totalLines) {
  if (typeof key === "number" || /^\s*\d+\s*$/.test(String(key))) {
    const n = Number(key);
    if (!(n >= 1 && n <= totalLines)) {
      throw new Error(`行号锚点越界：${n}（源文件只有 ${totalLines} 行）`);
    }
    return n;
  }
  const m = /^(.*)#(\d+)(?:\+(\d+))?$/.exec(String(key));
  if (!m) {
    throw new Error(
      `无法解析的锚点键：${JSON.stringify(key)}\n` +
        `  合法形态只有两种：134（旧·行号）或 "Brain:OnUpdate#2"（新·定义名+第 n 次）；` +
        `还可以带偏移："Brain:OnUpdate#1+7"（定义行往下第 7 行）`);
  }
  const name = m[1];
  const nth = Number(m[2]);
  const off = Number(m[3] || 0);
  const hits = index.get(name);
  if (!hits || !hits.length) {
    throw new Error(
      `锚点找不到定义：${JSON.stringify(name)}（第 ${nth} 次）\n` +
        `  该名字在本文件里**一次都没出现**。可能是：函数改名了 / spec 记错了名字 / ` +
        `定义写法本工具认不出（只认 function X( / local function X( / X = function( ）`);
  }
  if (nth < 1 || nth > hits.length) {
    throw new Error(
      `锚点不存在：${JSON.stringify(name)} 只定义了 ${hits.length} 次，spec 要第 ${nth} 次`);
  }
  const line = hits[nth - 1] + off;
  if (!(line >= 1 && line <= totalLines)) {
    throw new Error(`锚点越界：${JSON.stringify(key)} → 第 ${line} 行（源文件 ${totalLines} 行）`);
  }
  return line;
}

/**
 * 把 spec 注入源码。返回 `{ text, injected, lines, anchors }`。
 * 与原 build 脚本的**语义逐位一致**：BEFORE 在行前、AFTER 在行后、代码行原样保留。
 */
export function applySpec({ lines, header = [], headerExtra = [], before = {}, after = {} }) {
  const index = definitionIndex(lines);
  const out = [];
  for (const h of header) out.push(h);
  for (const h of headerExtra) out.push(h);

  const pre = new Map();   // 行号 → 注释行数组
  const post = new Map();
  const anchors = [];
  const put = (map, lineno, arr, key) => {
    if (!map.has(lineno)) map.set(lineno, []);
    for (const c of arr) {
      const t = String(c).trim();
      if (!t.startsWith("--")) {
        throw new Error(`规格错误 @${String(key)}：插入内容不是注释 → ${JSON.stringify(c)}`);
      }
      map.get(lineno).push(c);
    }
    anchors.push({ key: String(key), line: lineno });
  };
  for (const [k, arr] of Object.entries(before)) {
    if (arr && arr.length) put(pre, resolveKey(k, index, lines.length), arr, k);
  }
  for (const [k, arr] of Object.entries(after)) {
    if (arr && arr.length) put(post, resolveKey(k, index, lines.length), arr, k);
  }

  let injected = 0;
  for (let i = 0; i < lines.length; i++) {
    const n = i + 1;
    for (const c of pre.get(n) || []) {
      out.push(c);
      injected++;
    }
    out.push(lines[i]);
    for (const c of post.get(n) || []) {
      out.push(c);
      injected++;
    }
  }
  return { text: out.join("\n"), lines: out, injected, anchors };
}

/** 统计一份 spec 里「数字键 / 锚点键」各多少 —— 迁移进度是可测量，不是感觉 */
export function keyStats(maps) {
  const s = { numeric: 0, anchor: 0, numericKeys: [] };
  for (const map of maps) {
    for (const k of Object.keys(map || {})) {
      if (/^\s*\d+\s*$/.test(k)) {
        s.numeric++;
        s.numericKeys.push(k);
      } else s.anchor++;
    }
  }
  return s;
}

/**
 * 把「锚点键」就地展开成「数字键」—— 给 104 个 build 脚本用的一行式接入。
 *
 * 为什么需要
 *   build 脚本都长这样：`for (...) { const pre = BEFORE[lineno]; }` —— 用**整数**取。
 *   spec 迁成锚点键以后，`BEFORE["Brain:OnUpdate#1+7"]` 取不到 ⇒ **注释静默消失**，
 *   而构建照样打印「✔ 已生成」。这是本工程最忌讳的那类失败：看着成功。
 *   所以每个 build 脚本在读完源文件后立刻调一次本函数，把锚点键解析成数字键，
 *   后面的循环一个字都不用改（改动面越小，越不会引入新行为）。
 *
 * 纪律
 *   · 数字键原样保留（文件头区域没有定义名，迁移器本来就不动它们）。
 *   · 同一行既有数字键又有锚点键 ⇒ **拼接**（数字键内容在前），不覆盖、不丢。
 *   · 解析不了就抛错（resolveKey 负责），绝不跳过。
 *
 * @returns {{expanded:number, merged:number}} 展开个数 / 发生拼接的行数
 */
export function expandKeysInPlace(map, lines, label = "spec") {
  if (!map) return { expanded: 0, merged: 0 };
  const idx = definitionIndex(lines);
  const anchorKeys = Object.keys(map).filter((k) => !/^\s*\d+\s*$/.test(k));
  if (!anchorKeys.length) return { expanded: 0, merged: 0 };

  const add = new Map();
  for (const k of anchorKeys) {
    let n;
    try {
      n = resolveKey(k, idx, lines.length);   // 坏锚点在这里抛错
    } catch (e) {
      // 空数组的非法键（`452.1: []`）是历史残留：它不产生任何注入，但键本身不合法。
      // 这种键在老 build 里被**静默忽略**（BEFORE[lineno] 永远取不到），所以一直没人发现。
      if (Array.isArray(map[k]) && map[k].length === 0) {
        throw new Error(
          `${label} 里的键 ${JSON.stringify(k)} 是**空数组**（不产生任何注入），但键本身不合法。\n` +
            `  ⇒ 直接删掉这一项即可（删除后产物逐字节不变）。\n` +
            `  原始错误：${e.message.split("\n")[0]}`
        );
      }
      throw e;
    }
    if (!add.has(n)) add.set(n, []);
    add.get(n).push(...map[k]);
  }
  for (const k of anchorKeys) delete map[k];

  let merged = 0;
  for (const [n, arr] of add) {
    if (map[n] !== undefined) {
      map[n] = [...map[n], ...arr];
      merged++;
    } else {
      map[n] = arr;
    }
  }
  if (label && anchorKeys.length && process.env.DST_SPEC_VERBOSE) {
    console.log(`[spec] ${label}: ${anchorKeys.length} 个锚点键已展开（${merged} 行与数字键拼接）`);
  }
  return { expanded: anchorKeys.length, merged };
}

// ───────────────────────────── 自检 ─────────────────────────────
const SELFTEST_SRC = [
  "-- fake source",
  "local M = {}",                                  // 2
  "",                                              // 3
  "function Alpha(a)",                             // 4  ← 定义 #1
  "  return a + 1",                                // 5
  "end",                                           // 6
  "",                                              // 7
  "local function Beta()",                         // 8  ← 定义
  "  return 2",
  "end",
  "",
  "M.Alpha = function(self)",                      // 12 ← Alpha 的「另一种」名字，不算 Alpha#2
  "  return 3",
  "end",
  "return M",
].join("\n");

if (import.meta.url === `file://${process.argv[1]?.replace(/\\/g, "/")}` ||
    process.argv[1]?.endsWith("spec-anchor.mjs")) {
  if (!process.argv.includes("--selftest")) {
    console.error("用法: node tools/lib/spec-anchor.mjs --selftest");
    process.exit(2);
  }
  let bad = 0;
  const ok = (c, msg) => {
    console.log(`  ${c ? "✔" : "✘"} ${msg}`);
    if (!c) bad++;
  };
  const base = SELFTEST_SRC.split("\n");

  console.log("── S1 定义索引 ──");
  const idx = definitionIndex(base);
  ok(idx.get("Alpha")?.join(",") === "4", `Alpha 定义在 ${idx.get("Alpha")}（期望 [4]）`);
  ok(idx.get("Beta")?.join(",") === "8", `local function Beta 被认出来（${idx.get("Beta")}）`);
  ok(idx.get("M.Alpha")?.join(",") === "12", `M.Alpha = function( 也被认出来（${idx.get("M.Alpha")}）`);
  ok(!idx.has("Alpha2"), "不存在的名字不会凭空出现");

  console.log("── S2 数值键与锚点键指向同一处 ──");
  const nNum = resolveKey(4, idx, base.length);
  const nAnc = resolveKey("Alpha#1", idx, base.length);
  ok(nNum === 4 && nAnc === 4, `行号 4 与 "Alpha#1" 都解析到第 4 行（${nNum} / ${nAnc}）`);

  console.log("── S3 上游插入 2 行：数值键必须**漂移**（能红） ──");
  const shifted = ["-- 上游新增 A", "-- 上游新增 B", ...base];
  const idx2 = definitionIndex(shifted);
  const numAfter = resolveKey(4, idx2, shifted.length);          // 数字键还是 4
  const ancAfter = resolveKey("Alpha#1", idx2, shifted.length);  // 锚点跟着走
  const lineTxt = (arr, n) => (arr[n - 1] || "").trim();
  ok(lineTxt(shifted, numAfter) !== lineTxt(shifted, ancAfter),
     `插入 2 行后：数字键 4 指向 ${JSON.stringify(lineTxt(shifted, numAfter))}，` +
     `锚点指向 ${JSON.stringify(lineTxt(shifted, ancAfter))} —— 两者已经分家`);
  ok(lineTxt(shifted, ancAfter).startsWith("function Alpha("),
     "锚点仍然精确落在 function Alpha( 之前");
  ok(!lineTxt(shifted, numAfter).startsWith("function Alpha("),
     "数字键 4 已经**不再**指向 Alpha（这就是 257 个 spec 的静默错位）");

  console.log("── S4 反向：坏锚点必须抛错，不许静默跳过 ──");
  const mustThrow = (fn, what) => {
    try {
      fn();
      ok(false, `${what} —— 竟然没抛错`);
    } catch (e) {
      ok(true, `${what} → ${e.message.split("\n")[0]}`);
    }
  };
  mustThrow(() => resolveKey("Nope#1", idx, base.length), "名字不存在");
  mustThrow(() => resolveKey("Alpha#2", idx, base.length), "第 2 次出现不存在");
  mustThrow(() => resolveKey(999, idx, base.length), "行号越界");
  mustThrow(() => resolveKey("garbage", idx, base.length), "键格式非法");

  console.log("── S5 注入语义与原 build 脚本一致 ──");
  const r1 = applySpec({ lines: base, before: { 4: ["-- 前置注释"] }, after: { 6: ["-- 后置注释"] } });
  const r2 = applySpec({ lines: base, before: { "Alpha#1": ["-- 前置注释"] }, after: { "Alpha#1": ["-- 后置注释"] } });
  // r2 的 AFTER 挂在函数定义行之后（不同于 r1 挂 end 之后），这里只比 BEFORE 的位置
  const i1 = r1.lines.indexOf("-- 前置注释");
  const i2 = r2.lines.indexOf("-- 前置注释");
  ok(i1 === i2 && i1 > 0 && r1.lines[i1 + 1].startsWith("function Alpha("),
     `两种写法的 BEFORE 落在同一处（index ${i1} / ${i2}）`);
  ok(r1.lines.length === base.length + 2, `注入 2 行 ⇒ 输出 ${r1.lines.length} 行（源 ${base.length} + 2）`);

  console.log("── S6 反向：插入非注释内容必须拒绝 ──");
  mustThrow(() => applySpec({ lines: base, before: { 4: ["print('x')"] } }),
            "spec 里混入代码行");

  console.log("── S7 展开：锚点键就地变成数字键，注入结果逐字节不变 ──");
  {
    const src = ["-- h", "function A()", "  return 1", "end", "", "function B()", "  return 2", "end"];
    const anchored = { "A#1": ["-- a 之前"], "B#1+0": ["-- b 之前"] };
    const direct = applySpec({ lines: src, before: anchored });
    const copy = JSON.parse(JSON.stringify(anchored));
    const st = expandKeysInPlace(copy, src, "selftest");
    const expanded = applySpec({ lines: src, before: copy });
    ok(st.expanded === 2, `展开 ${st.expanded} 个锚点键`);
    ok(Object.keys(copy).every((k) => /^\d+$/.test(k)), "展开后不再有字符串键");
    ok(direct.text === expanded.text, "展开前后注入产物**逐字节相同**");

    // 与数字键同行 ⇒ 拼接，不能覆盖
    const mix = { 2: ["-- 数字键内容"], "A#1": ["-- 锚点内容"] };
    expandKeysInPlace(mix, src, "selftest-mix");
    ok(mix[2].length === 2 && mix[2][0] === "-- 数字键内容" && mix[2][1] === "-- 锚点内容",
       "同行时数字键在前、锚点追加在后（不覆盖）");

    // 反向：坏锚点必须抛错，且**不能**留下半个展开的状态
    mustThrow(() => expandKeysInPlace({ "Nope#1": ["-- x"] }, src, "selftest"), "展开时坏锚点必须抛错");
  }

  console.log(bad ? `\n结果：${bad} 条失败` : "\n结果：全绿（锚点机制可用，且坏输入不会被吞）");
  process.exit(bad ? 1 : 0);
}
