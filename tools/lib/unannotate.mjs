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
import { findDefinitions } from "./spec-anchor.mjs";

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

/** 锚点键 `Name#nth+off` 的三要素；不是这个形态就返回 null */
function parseAnchorKey(k) {
  const m = /^(.*)#(\d+)(?:\+(\d+))?$/.exec(String(k));
  if (!m) return null;
  return { name: m[1], nth: Number(m[2]), off: Number(m[3] || 0) };
}

/**
 * 按给定 H 走一遍逆运算；全程精确匹配就返回 `{derived, maxLine}`，否则 null。
 * 硬错误（锚点写法不合法 / 锚点永远定位不到）推进 `errBox`，供上层报出真实原因。
 *
 * ★★ 2026-10-20（P49）：这里必须**自己会解析锚点键**。
 *   P48 把 22372 个键迁成 `Name#nth+off` 之后，原来那句 `before[n]` 一个都取不到，
 *   于是 116/118 个文件报「含非数字键…（已迁移过？）」—— 闸门抓到了真回归。
 *
 *   为什么不能「先把锚点展开成行号再逆运算」：展开需要**原版行号**，
 *   而原版行号正是本函数要算的东西（鸡生蛋）。
 *   为什么自举也不行：只留数字键那一遍，没有锚点约束的区段会把**注入行也当成原版行**
 *   推出来 —— 参照物自己就是脏的。实测 104 个文件「自举成功」，
 *   但拿它展开出来的键全错（随后逆运算全部无解，白绕一圈）。
 *
 *   ⇒ 唯一自洽的做法是**边推边解析**：本函数本来就按原版行号 n 顺序前进，
 *     每读一行就知道这一行定义了什么名字（第几次出现），
 *     于是 `Name#nth+off` 指向的原版行号当场就定下来，注入块也就能当场比对。
 */
function tryH(lines, H, before, after, errBox) {
  const derived = [];
  let pos = H;
  if (pos > lines.length) return null;

  const occ = new Map();     // 定义名 → 已出现的次数（走到第 n 行时的状态）
  const preAt = new Map();   // 原版行号 → [注入行数组]（行前）
  const postAt = new Map();  // 同上（行后）
  const pending = [];        // 还没确定行号的锚点
  const put = (at, n, arr) => {
    if (!at.has(n)) at.set(n, []);
    at.get(n).push(arr);
  };

  // ① 数字键：行号本来就已知，先登记（数值序在前 —— 与 expandKeysInPlace 的拼接顺序一致）
  for (const [which, map, at] of [["before", before, preAt], ["after", after, postAt]]) {
    for (const [k, arr] of Object.entries(map || {})) {
      if (!arr || !arr.length) continue;
      if (isNumericKey(k)) {
        put(at, Number(k), arr);
        continue;
      }
      const a = parseAnchorKey(k);
      if (!a) {
        errBox.push({
          n: -1,
          pos: -1,
          msg: `${which} 里无法解析的键：${JSON.stringify(k)}（只认 134 或 "Name#2" / "Name#1+7"）`,
        });
        return null;
      }
      pending.push({ ...a, arr, at, which });
    }
  }

  let n = 1;
  // 对不上时把**现场**记下来：走得越远越有诊断价值（H=0 往往第一行就崩）
  const miss = (msg, where) => {
    errBox.push({ n, pos, msg: `H=${H} 在注释版第 ${pos} 行（原版第 ${n} 行）${where}：${msg}` });
    return null;
  };
  while (pos < lines.length) {
    // ② 行前注入（行号已确定的那批）：数字键与 off>0 的锚点都在这里，逐行精确相等
    for (const blk of preAt.get(n) || []) {
      for (const l of blk) {
        if (pos >= lines.length) return miss("注释版提前结束", "行前注入");
        if (lines[pos] !== l) {
          return miss(`期望 ${JSON.stringify(l)} / 实得 ${JSON.stringify(lines[pos])}`, "行前注入");
        }
        pos++;
      }
    }

    // ③ 行前注入（`off=0`：块就贴在定义行**前面**）。
    //    ★★ 这里是最容易写错的一步：块在原版行之前，所以「这一行是定义」这个事实
    //       要到**块全部读完的下一个位置**才知道。若在块首就去判断定义，永远判不到
    //       （实测：33 个文件全部卡在这里，报「行前注入 期望注释 / 实得 function …」）。
    //    做法：用块长往后够一格，确认那一行确实是「该名字的第 nth 次定义」，
    //          且中间这几行与块**逐行相等**。三条同时成立才算数。
    let hit = null;
    for (const p of pending) {
      if (p.off !== 0 || p.which !== "before") continue;   // 只看行前锚点
      const L = p.arr.length;
      const dl = lines[pos + L];
      if (dl === undefined) continue;
      const isTheDef = findDefinitions([dl]).some(
        (d) => d.name === p.name && (occ.get(p.name) || 0) + 1 === p.nth
      );
      if (!isTheDef) continue;
      if (!p.arr.every((l, i) => lines[pos + i] === l)) continue;
      if (hit) {
        return miss(`锚点 ${JSON.stringify(hit.name)}#${hit.nth} 与 ${JSON.stringify(p.name)}#${p.nth} 都能解释这段注入`,
          "行前注入歧义");
      }
      hit = p;
    }
    if (hit) {
      pos += hit.arr.length;
      pending.splice(pending.indexOf(hit), 1);
    }

    // ④ 原版行本身
    if (pos >= lines.length) return miss("注释版提前结束", "取原版行");
    const orig = lines[pos];
    derived.push(orig);
    pos++;

    // ⑤ 记定义 + 解析锚点。行号 = 这一行的行号 + off。
    //    ★ 例外：**行前** 且 off=0 的锚点已经在 ③ 里消费掉了；若此刻才现身，
    //      说明它的块根本没被注入 ⇒ 留在 pending 里由收尾报错，绝不静默丢弃。
    //      （**行后** 的 off=0 是正常写法：`Name#1` = 「紧跟在定义行后面」。
    //        这里顺手踩过一次：把 off=0 一律跳过，于是所有 `Name#1` 形式的
    //        行后注释全部消失，85 个文件报「行后注入 期望注释 / 实得 end」。）
    for (const d of findDefinitions([orig])) {
      const c = (occ.get(d.name) || 0) + 1;
      occ.set(d.name, c);
      for (let i = 0; i < pending.length; i++) {
        const p = pending[i];
        if (p.name !== d.name || p.nth !== c) continue;
        if (p.off === 0 && p.which === "before") continue;
        const target = n + p.off;
        if (target < 1) {
          return miss(`锚点 ${JSON.stringify(p.name)}#${p.nth}+${p.off} 落到第 ${target} 行`, "锚点越界");
        }
        put(p.at, target, p.arr);
        pending.splice(i--, 1);
      }
    }

    // ⑥ 行后注入同理
    for (const blk of postAt.get(n) || []) {
      for (const l of blk) {
        if (pos >= lines.length) return miss("注释版提前结束", "行后注入");
        if (lines[pos] !== l) {
          return miss(`期望 ${JSON.stringify(l)} / 实得 ${JSON.stringify(lines[pos])}`, "行后注入");
        }
        pos++;
      }
    }
    n++;
  }

  // ⑤ 收尾：一整份注释版必须**恰好读完**。读完了还多出来 = 有注入块没被认出来；
  //    提前结束 = 把不该吃的吃掉了。两种情况都不许放过（这正是一条静默丢行的来源：
  //    重建出的原版比磁盘上的少一行，而内容看着全对 —— 只差末尾一个空行）。
  if (pos !== lines.length) {
    return miss(`注释版没读完（读完 ${pos}/${lines.length} 行）`, "收尾·未读完");
  }
  if (pending.length) {
    const p = pending[0];
    return miss(`锚点 ${JSON.stringify(p.name)}#${p.nth} 定位不到（该名字只定义了 ${occ.get(p.name) || 0} 次）`, "收尾");
  }
  for (const k of [...preAt.keys(), ...postAt.keys()]) {
    if (k > derived.length) {
      return miss(`目标第 ${k} 行，原版只有 ${derived.length} 行`, "锚点越界");
    }
  }

  const maxLine = Math.max(0, ...preAt.keys(), ...postAt.keys());
  return { derived, maxLine };
}

/**
 * 反向重建。返回 `{ ok:true, H, derived, maxKey, injected }` 或 `{ ok:false, why }`。
 * **失败一律给原因，不给「大概对」的结果。**
 */
export function reconstruct(annLines, { before, after }) {
  const keys = [...Object.keys(before || {}), ...Object.keys(after || {})];
  if (!keys.length) return { ok: false, why: "无行锚点（只有文件头）" };
  // 数字键仍然先查越界（锚点键的行号要一边推一边才知道，查不了）
  const nums = keys.filter(isNumericKey).map(Number);
  if (nums.length && Math.max(...nums) > annLines.length) {
    return { ok: false, why: `最大键 ${Math.max(...nums)} > 注释版 ${annLines.length} 行` };
  }

  const cands = [];
  const errBox = [];
  for (let H = 0; H <= Math.min(400, annLines.length); H++) {
    const d = tryH(annLines, H, before, after, errBox);
    if (d) cands.push({ H, derived: d.derived, maxKey: d.maxLine });
  }
  if (!cands.length) {
    // 报「走得最远」的那个候选：H=0 往往第一行就崩，它的原因对定位毫无帮助
    let best = null;
    for (const e of errBox) if (!best || e.n > best.n) best = e;
    return { ok: false, why: `H∈[0,400] 内无解${best ? `；最接近的一次：${best.msg}` : ""}` };
  }

  // G3：头部不许残留插入标记
  const clean = cands.filter((c) => !c.derived.slice(0, 60).some((l) => INJECT_MARKS.some((re) => re.test(l))));
  if (!clean.length) {
    return { ok: false, why: `H 候选 ${cands.length} 个，但每个的头部都残留了插入标记（G3 全否）` };
  }
  // ★★ 多解取 **H 最大**那个。这不是「随便挑一个」：
  //   候选区间是连续的 [小 … 大]，按 H 递增，派生行数**逐个递减 1** ——
  //   因为 H 每小 1，就多一行头部散文被当成原版行推出来（推一行，n 也加一，于是后面
  //   所有注入块照样对得上 ⇒ 约束力为零，一整段都通过）。
  //   而在「头部之后紧接着一个注入块」的文件里（如 components/equippable.lua：
  //   `onequipslot#1` 的 12 行块就贴在定义行前面），**最大 H 恰好等于块首** ——
  //   也就是「头部之外没有任何注释被误当原版行」的那个解，正是真值。
  //   实测 111 个文件里 110 个本来就唯一，只有 equippable.lua 需要这条规则，
  //   取最大后 H=173 与清单记录一致。
  //   ⚠ 已知边界：若某个文件**开头就有若干原版行**、而第一个注入块又是 `off=0` 行前块，
  //     这条规则会把那几行原版行当成头部丢掉（不报错）。所以「用过这条规则」必须
  //     计数并打印出来，让它是可见的，而不是悄悄发生。
  const ambiguous = clean.length;
  const { H, derived, maxKey } = clean[clean.length - 1];
  if (maxKey > derived.length) {
    return { ok: false, why: `锚点越界：目标第 ${maxKey} 行，原版只有 ${derived.length} 行` };
  }
  return { ok: true, H, derived, maxKey, injected: annLines.length - derived.length, ambiguous };
}
