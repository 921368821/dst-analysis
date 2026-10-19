/**
 * tools/lib/paths.mjs —— 注释流水线里「源码根 / 输出根」的**单一来源**
 *
 * 为什么要有这个文件（M8 的根因之一）
 *   104 个 `build-*.mjs` 里各自抄了一份**绝对路径字面量**：
 *       const SRC = "C:/Users/35916/.qwenworkcn/workspace/.../scripts/brain.lua";
 *       const OUT = "E:/DST-Analysis/02-注释源码/scripts/brain.lua";
 *   这份工作区搬过家（用户目录 35916 → admin，工程 E:/DST-Analysis → E:/game_make/25d/...），
 *   于是 104 个脚本**同时**指向不存在的目录 —— 而且没有一个会因此报错退出，
 *   它们是「跑起来才发现打不开文件」。这正是本工程反复踩的
 *   「同一串事实抄 N 份 ⇒ 改一处、其余悄悄过期」。
 *
 * 本文件的纪律
 *   ① **只解析，不猜**：原版根找不到就抛错并说清三条解析顺序，
 *      绝不回退到注释版（拿注释版当原版 = 自己比自己，见 M9 的假绿教训）。
 *   ② 输出根永远存在（注释版在仓库里），但 **tail 必须存在**，
 *      否则说明 spec 与源文件已经对不上，早报早好。
 *   ③ 所有路径都用 `/`（Windows 上也认），避免反斜杠被当转义。
 *
 * 用法（build 脚本里）：
 *   import { relSrc, relOut, repoRoot } from "./lib/paths.mjs";
 *   const SRC = relSrc("scripts/brain.lua");       // 原版（未注释）
 *   const OUT = relOut("brain.lua");               // 02-注释源码/scripts/brain.lua
 */
import { existsSync, statSync, realpathSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/** 工程根：tools/lib → tools → 工程根 */
export const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");

/** 注释版（产线）scripts 根 —— 永远存在 */
export const ANN_SCRIPTS = join(repoRoot, "02-注释源码", "scripts");

/** 归一化到真实路径；不存在就返回 null（不做任何猜测） */
function realOrNull(p) {
  try {
    return realpathSync(p).replace(/\\/g, "/").toLowerCase();
  } catch {
    return null;
  }
}

/**
 * 原版（未注释）scripts 根的三条解析顺序。
 * ★ 与 tools/verify-syntax.py 的 `_src_root()` **完全一致**（同一份事实只许一处定义…
 *   但那是 Python，这里是 JS；两边都改了才生效，见 tools/baseline/README 的说明）。
 */
export function pristineCandidates() {
  const env = process.env.DST_PRISTINE || process.env.DST_SRC || "";
  return [
    env ? resolve(env) : null,
    join(repoRoot, "_baseline", "pristine-scripts"),
    join(repoRoot, "dstsrc-pristine", "scripts"),
  ].filter(Boolean);
}

/** 找到原版根；一个都没有就抛（附带三条解析顺序 + 修复建议） */
export function pristineRoot() {
  const annReal = realOrNull(ANN_SCRIPTS);
  const rejected = [];
  for (const p of pristineCandidates()) {
    if (!existsSync(p) || !statSync(p).isDirectory()) continue;
    // ★★ 「同一棵树」必须判死：`tools/env.sh` 默认把 `DST_SRC` 指向 `dstsrc/scripts`，
    //   而 `dstsrc` 是**注释版**的联接。拿它当原版 = 自己比自己 = 永远「逐字节一致」。
    //   这条守卫是 M9 加的（verify-annotated.mjs 也是这么判的），这里再守一遍：
    //   两个工具各守一次，比「指望上游传对」可靠。
    if (annReal && realOrNull(p) === annReal) {
      rejected.push(p);
      continue;
    }
    return p;
  }
  throw new Error(
    "找不到**原版（未注释）** scripts 根。解析顺序：\n" +
      "  1) $DST_PRISTINE / $DST_SRC\n" +
      "  2) <工程根>/_baseline/pristine-scripts\n" +
      "  3) <工程根>/dstsrc-pristine/scripts\n" +
      (rejected.length
        ? `⚠ 以下候选被**拒绝**（realpath 与注释版相同，属「自己比自己」）：\n` +
          rejected.map((p) => `    ${p}`).join("\n") + "\n"
        : "") +
      "一条都不成立 ⇒ 现在**无法**重新生成注释版。先跑：\n" +
      "  bash tools/archive-pristine.sh <原版 scripts 根>\n" +
      "★ 注意 `dstsrc/` 是**注释版**的联接，绝不能当原版用 —— 那是「自己比自己」。");
}

/** 原版某个文件的绝对路径（tail 例："scripts/brain.lua" 或 "brain.lua"） */
export function relSrc(tail) {
  const root = pristineRoot();
  const t = String(tail).replace(/\\/g, "/").replace(/^\/+/, "");
  // 允许同时接受 "brain.lua" 与 "scripts/brain.lua"
  const p = existsSync(join(root, t)) ? join(root, t) : join(root, "scripts", t);
  if (!existsSync(p)) {
    throw new Error(`原版里没有这个文件：${t}\n  试过：${join(root, t)}\n        ${join(root, "scripts", t)}`);
  }
  return p;
}

/** 注释版某个文件的绝对路径（tail 相对 02-注释源码/scripts） */
export function relOut(tail) {
  const t = String(tail).replace(/\\/g, "/").replace(/^\/+/, "");
  const p = existsSync(join(ANN_SCRIPTS, t)) ? join(ANN_SCRIPTS, t) : join(ANN_SCRIPTS, "scripts", t);
  // ★ 输出文件允许尚不存在（首次生成），但**目录**必须在 —— 否则是 tail 写错了
  const dir = dirname(p);
  if (!existsSync(dir)) {
    throw new Error(`输出目录不存在：${dir}（tail=${t}）—— build 脚本里的输出路径写错了`);
  }
  return p;
}

/** 自检：跑 `node tools/lib/paths.mjs --selftest` */
if (process.argv[1] && resolve(process.argv[1]) === resolve(fileURLToPath(import.meta.url))) {
  if (!process.argv.includes("--selftest")) {
    console.error("用法: node tools/lib/paths.mjs --selftest");
    process.exit(2);
  }
  let bad = 0;
  const ok = (cond, msg) => {
    console.log(`  ${cond ? "✔" : "✘"} ${msg}`);
    if (!cond) bad++;
  };
  console.log("工程根 :", repoRoot);
  ok(existsSync(ANN_SCRIPTS), "注释版 scripts 根存在");
  ok(existsSync(join(repoRoot, "tools")) && existsSync(join(repoRoot, "07-通用引擎")),
     "工程根算对（tools/ 与 07-通用引擎/ 都在）");
  // ① 正常路径
  try {
    const p = relOut("brain.lua");
    ok(existsSync(p), "relOut('brain.lua') 解析到真实文件");
  } catch (e) {
    ok(false, "relOut 抛了：" + e.message);
  }
  // ② 反向：tail 写错必须抛，不许「返回一个不存在的路径」
  let threw = false;
  try {
    relOut("no_such_dir_xyz/x.lua");
  } catch {
    threw = true;
  }
  ok(threw, "反向：输出目录不存在时 relOut 抛错（不静默返回坏路径）");
  // ③ 原版缺失时必须抛，且话里要说清「dstsrc 不能当原版」
  //    ★ 这里**故意**把 DST_SRC 指向注释版（= tools/env.sh 的默认值），
  //      复现那个陷阱：如果守卫失效，relSrc 会「成功」返回注释版路径，下面就会红。
  const saved = { p: process.env.DST_PRISTINE, s: process.env.DST_SRC };
  delete process.env.DST_PRISTINE;
  process.env.DST_SRC = ANN_SCRIPTS;
  let msg = "";
  let leaked = null;
  try {
    leaked = relSrc("scripts/brain.lua");
  } catch (e) {
    msg = e.message;
  }
  process.env.DST_PRISTINE = saved.p;
  process.env.DST_SRC = saved.s;
  if (leaked !== null) {
    ok(false, `把 DST_SRC 指向注释版时**竟然返回了路径**（${leaked}）—— 自己比自己的假绿`);
  } else {
    ok(/自己比自己|拒绝/.test(msg) && /archive-pristine/.test(msg),
       "同树候选被拒绝，报错点明了 dstsrc 陷阱与修复命令");
  }
  console.log(bad ? `\n结果：${bad} 条失败` : "\n结果：全绿");
  process.exit(bad ? 1 : 0);
}
