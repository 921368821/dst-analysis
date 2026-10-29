#!/usr/bin/env node
/**
 * 拿真实 DST 源码量一次：`dstsrc/scripts` 顶层脚本，按字母序全加载，数通过/失败。
 *
 * ★ 为什么要有这个工具：批133 报出「117 / 218」、批134 要报"修完是多少" ——
 *   这两个数字必须**同一条命令**量得出来。写进文档的测量如果不可复现，
 *   下一批的人只能照抄，而照抄的数字没人能推翻。
 *
 * ★ `dstsrc` **未入库**（授权素材，不进仓库）：所以这里缺目录时退 **2**（环境缺失），
 *   不是 0、也不是 1。退 0 = 假装量过了；退 1 = 假装代码坏了。
 *   这条纪律来自批130：把语料挂在 `dstsrc` 上就等于 CI 永远跳过，
 *   而"永远跳过"与"永远通过"在报告里长得一模一样。
 *
 * 用法：
 *   node --experimental-transform-types tools/dstsrc-sweep.ts
 *   node --experimental-transform-types tools/dstsrc-sweep.ts --order all
 *   node --experimental-transform-types tools/dstsrc-sweep.ts --order boot-first --max-fail 20
 *
 * ★ `--order`（批136）：**加载顺序是测量口径的一部分**。`IsConsole` / `global` /
 *   `Vector3` 是 `main.lua` / `strict.lua` / `vector3.lua` 自己定义的，纯字母序
 *   把它们数成了引擎缺口。换口径必须显式写在命令行上 —— 数字进了文档之后，
 *   读者要能复现出「这一版是用哪个口径量的」。
 *
 * 退出码：0 解析器那一轮**全部**通过；1 仍有失败（prints 明细）；2 dstsrc 不在（环境缺失）；
 *        64 参数写错（未知预设 / `--order` 没给值）。64 必须与 2 分开：
 *        把"打错字"报成"环境缺失"，下次谁也不会去看那条命令。
 */

import { readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { collectModuleSources } from "../src/backends/script-lua/module-resolver.ts";
import { ORDER_PRESETS, splitNeverDefined, summarizeFailures } from "./dstsrc-report.mjs";
import { runSweepPass } from "./dstsrc-run.ts";
import { NodeFileSystem } from "../src/backends/fs-node/fs.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = join(ROOT, "..", "dstsrc", "scripts");

const argv = process.argv.slice(2);
const maxFailArg = argv.indexOf("--max-fail");
const MAX_FAIL = maxFailArg >= 0 ? Number(argv[maxFailArg + 1] ?? 10) : 10;

const orderArg = argv.indexOf("--order");
const ORDER_RAW = orderArg >= 0 ? String(argv[orderArg + 1] ?? "").trim() : "alpha";
const KNOWN_ORDERS = Object.keys(ORDER_PRESETS);
const ORDERS = ORDER_RAW === "all" ? KNOWN_ORDERS : ORDER_RAW.split(",").map((s) => s.trim()).filter(Boolean);

if (ORDERS.length === 0 || ORDERS.some((o) => !KNOWN_ORDERS.includes(o))) {
  console.error(
    `⊘ 参数错误：--order ${ORDER_RAW === "" ? "(没给值)" : ORDER_RAW}\n` +
      `  可选：${KNOWN_ORDERS.join(" / ")}，或 all 跑全部三档。`,
  );
  process.exit(64);
}

function srcExists(): boolean {
  try {
    return statSync(SRC).isDirectory();
  } catch {
    return false;
  }
}

if (!srcExists()) {
  console.error(
    `⊘ 环境缺失：${SRC} 不存在。\n` +
      "  `dstsrc` 是授权素材、未入库 —— 这条测量只在有素材的机器上跑得起来，\n" +
      "  所以这里退 2（环境缺失），不假装通过。",
  );
  process.exit(2);
}

/** 顶层脚本，按名字取一次（顺序交给 `orderScripts`，这里不排）。 */
const allFiles = readdirSync(SRC).filter((n) => n.endsWith(".lua"));
const files = [...allFiles].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

type Pass = { readonly label: string; readonly resolve: boolean; readonly order: string };

/**
 * 跑一档。**逻辑全在 `dstsrc-run.ts`**（批138 拆出去的：那段逻辑承载着报告的结论，
 * 却在 CI 里永远跑不到 —— `dstsrc` 未入库）。这里只负责"抓异常 → 退出码"和打印。
 */
async function run(
  pass: Pass,
): Promise<{ ok: number; fail: ReadonlyArray<readonly [string, string]>; order: readonly string[]; probed: Map<string, string> }> {
  // 根 = scripts 目录；collect 的键是**相对**路径（`cls.lua` / `ai/brain.lua`）
  const fs = new NodeFileSystem(SRC);
  const collected = await collectModuleSources(fs, "");
  if (!collected.ok) throw new Error(`收集模块失败：${collected.error.message}`);

  // ★ 三档共用同一份模块快照：每档各收集一次的话，量到的可能不是同一份语料
  //   （中间有人改了文件，三档的对比就失去意义，而且没有任何地方会报错）。
  const r = await runSweepPass({
    fs,
    files,
    order: pass.order,
    resolve: pass.resolve,
    modules: collected.value,
  });
  if (!r.ok) throw new Error(`${pass.label} 跑不起来：${r.error.message}`);
  return {
    ok: r.value.ok,
    fail: r.value.fail,
    order: r.value.order,
    probed: new Map(r.value.probed),
  };
}

console.log(`语料：${SRC}`);
console.log(`顶层脚本：${files.length} 个（共享模块环境）`);
console.log(`加载顺序口径：${ORDERS.join(" / ")}（alpha = 纯字母序，是批133/134 的基线）\n`);

const passes: Pass[] = [
  { label: "没有解析器（批134 之前的行为）", resolve: false, order: "alpha" },
  ...ORDERS.map((o) => ({ label: `装上模块解析器 · 顺序 ${o}`, resolve: true, order: o })),
];

type RunResult = { pass: Pass } & Awaited<ReturnType<typeof run>>;

const results: RunResult[] = [];
for (const pass of passes) {
  const r = await run(pass);
  const total = files.length;
  const pct = ((r.ok / total) * 100).toFixed(1);
  console.log(`▸ ${pass.label}：${r.ok} 通过 / ${r.fail.length} 失败（共 ${total}，通过率 ${pct}%）`);
  results.push({ pass, ...r });
}

// ★ 明细只打**解析器那几轮**：没有解析器那轮不是"要做的事"，是基线。
//   顺序不同 ⇒ 失败集合不同 ⇒ 逐档打，否则"哪一档少了哪几条"只能靠脑补。
const resolved = results.filter((r) => r.pass.resolve);
for (const one of resolved) {
  const sum = summarizeFailures(one.fail);
  const tag = `顺序 ${one.pass.order}`;
  console.log(`\n══ ${tag}：仍失败 ${sum.total} 条 ══`);
  if (sum.total === 0) {
    console.log("  ✓ 全部通过");
    continue;
  }
  console.log("  按形状：");
  for (const g of sum.groups) {
    console.log(`  ${String(g.count).padStart(3)} × ${g.shape}`);
  }

  if (sum.missingGlobals.length > 0) {
    console.log("\n  缺的全局（当表用 / 当值用 / strict 点名）—— 这是「要不要提供 API 面」的依据：");
    for (const g of sum.missingGlobals.slice(0, MAX_FAIL)) {
      console.log(
        `  ${String(g.count).padStart(3)} × ${g.name}  [${(g.how ?? []).join("+")}]  如 ${g.scripts[0] ?? ""}` +
          `  → 跑完是 ${one.probed.get(g.name) ?? "?"}`,
      );
    }
  }

  if (sum.missingModules.length > 0) {
    console.log("\n  找不到的模块（文件就不在语料里，不是引擎的活）：");
    for (const m of sum.missingModules.slice(0, MAX_FAIL)) {
      console.log(`  ${String(m.count).padStart(3)} × ${m.name}  如 ${m.scripts[0] ?? ""}`);
    }
  }

  if (sum.localNils.length > 0) {
    console.log("\n  局部变量是 nil（脚本自己的逻辑问题，不算缺全局）：");
    for (const l of sum.localNils.slice(0, MAX_FAIL)) {
      console.log(`  ${String(l.count).padStart(3)} × ${l.name}  如 ${l.scripts[0] ?? ""}`);
    }
  }

  if (sum.others.length > 0) {
    console.log("\n  其余（认不出的形状，原文留着 —— 不许静默丢掉）：");
    for (const o of sum.others.slice(0, MAX_FAIL)) {
      console.log(`  ${String(o.count).padStart(3)} × ${o.text}  如 ${o.scripts[0] ?? ""}`);
    }
  }
}

// ★ 退出码只看**最后一档**（`--order` 指定的最后一个预设）：0 = 那一档全通过。
//   拿"某一档全通过"当 0 会让 `--order all` 永远退 0，等于没有退出码。
const last = resolved[resolved.length - 1];

// ── 跨口径求交：哪些名字**换个顺序也还是缺** ────────────────────────────────────
//
// ★ 这一段才回答 C27「要不要提供 API 面」。单看一档不行：`global` 只在 alpha 缺
//   （actions.lua 排在 strict.lua 前面），`PI` 只在 strict 档缺 —— 它们都是**顺序**
//   造成的。判据很简单：**三种顺序都缺 ⇒ 顺序解释不了它**。
//   反过来，"被某一档修掉"的名字直接可以划掉，不必再讨论。
if (resolved.length > 1) {
  const sums = resolved.map((r) => summarizeFailures(r.fail));
  const namesOf = (s: (typeof sums)[number]): string[] => s.missingGlobals.map((g) => g.name);
  const modsOf = (s: (typeof sums)[number]): string[] => s.missingModules.map((m) => m.name);

  const intersect = (lists: string[][]): string[] => {
    const first = lists[0] ?? [];
    return first.filter((n) => lists.every((l) => l.includes(n)));
  };
  const union = (lists: string[][]): string[] =>
    [...new Set(lists.flatMap((l) => [...l]))].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

  const globalLists = sums.map(namesOf);
  const always = intersect(globalLists);
  const orderFixed = union(globalLists).filter((n) => !always.includes(n));

  console.log(`\n══ 跨口径对比（${resolved.length} 档）══`);
  // 每档跑完后 `_G` 的探测结果：`nil` = 这份语料里没有任何文件给过它。
  const probeOf = (name: string): string =>
    resolved
      .map((r) => `${r.pass.order}=${r.probed.get(name) ?? "（未探测）"}`)
      .join(" / ");

  // ★ 判据本身在 `dstsrc-report.mjs`（纯函数、CI 里能用合成语料打），
  //   这里只负责把每档的探测结果摆成它要的形状 —— 一份逻辑不许写两处。
  const split = splitNeverDefined(
    always,
    resolved.map((r) => Object.fromEntries(r.probed)),
  );

  console.log("\n  ★★ 三档都缺 **且跑完仍是 nil** —— 引擎欠的（顺序解释不了，语料里也没人给）：");
  if (split.never.length === 0) console.log("    （无）");
  for (const n of split.never) console.log(`    · ${n}   [${probeOf(n)}]`);

  console.log("\n  ★ 三档都缺、但**跑完不是 nil** —— 内容层自己定义了，只是当时还没轮到（顺序问题，别做 API 面）：");
  if (split.later.length === 0) console.log("    （无）");
  for (const n of split.later) console.log(`    · ${n}   [${probeOf(n)}]`);
  // ★ 这里**不能**写成「换顺序就消失 = 顺序问题」：某一档没报它，可能只是因为
  //   那个脚本在更早的一行就死在别的错上了（`TheSim` 就是这样：strict 档里
  //   main.lua 先炸在「赋值给未声明的全局」，根本走不到读 `TheSim` 那行）。
  //   所以只列"哪几档报过"，判断留给读的人 —— 少一句推断，胜过一句错推断。
  console.log("\n  只被某些口径缺的全局 —— 逐条标出**哪几档报过**（没报 ≠ 修好了，可能死在更前面）：");
  if (orderFixed.length === 0) console.log("    （无）");
  for (const n of orderFixed) {
    const inWhich = resolved
      .filter((_, i) => (globalLists[i] ?? []).includes(n))
      .map((r) => r.pass.order);
    console.log(`    · ${n}  [${inWhich.join(" / ")}]`);
  }

  const modAlways = intersect(sums.map(modsOf));
  if (modAlways.length > 0) {
    console.log("\n  三档都找不到的模块（文件根本不在语料里 —— 与顺序无关，也不是引擎的活）：");
    for (const n of modAlways) console.log(`    · ${n}`);
  }
}

if (last !== undefined && last.fail.length > 0) process.exit(1);
console.log("\n✓ 全部通过");
