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
 *   node --experimental-transform-types tools/dstsrc-sweep.ts --max-fail 20
 *
 * 退出码：0 解析器那一轮**全部**通过；1 仍有失败（prints 明细）；2 dstsrc 不在（环境缺失）。
 */

import { readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { LuaScriptRuntime } from "../src/backends/script-lua/runtime.ts";
import {
  collectModuleSources,
  resolverFromSources,
} from "../src/backends/script-lua/module-resolver.ts";
import { NodeFileSystem } from "../src/backends/fs-node/fs.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SRC = join(ROOT, "..", "dstsrc", "scripts");

const argv = process.argv.slice(2);
const maxFailArg = argv.indexOf("--max-fail");
const MAX_FAIL = maxFailArg >= 0 ? Number(argv[maxFailArg + 1] ?? 10) : 10;

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

/** 顶层脚本按名字排序（与批133 的「按字母序全加载」一致）。 */
const files = readdirSync(SRC)
  .filter((n) => n.endsWith(".lua"))
  .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

type Pass = { readonly label: string; readonly resolve: boolean };

async function run(pass: Pass): Promise<{ ok: number; fail: Array<[string, string]> }> {
  // 根 = scripts 目录；collect 的键是**相对**路径（`cls.lua` / `ai/brain.lua`）
  const fs = new NodeFileSystem(SRC);
  const collected = await collectModuleSources(fs, "");
  if (!collected.ok) throw new Error(`收集模块失败：${collected.error.message}`);

  const rt = new LuaScriptRuntime(
    pass.resolve
      ? { sharedModuleEnv: true, resolveModule: resolverFromSources(collected.value) }
      : { sharedModuleEnv: true },
  );
  try {
    const ready = await rt.ready();
    if (!ready.ok) throw new Error(`运行时没起来：${ready.error.message}`);

    let ok = 0;
    const fail: Array<[string, string]> = [];
    for (const name of files) {
      const read = await fs.readText(name);
      if (!read.ok) throw new Error(`读不动 ${name}：${read.error.message}`);
      const r = await rt.loadModule(name.replace(/\.lua$/, ""), read.value);
      if (r.ok) ok++;
      else fail.push([name, r.error.message]);
    }
    return { ok, fail };
  } finally {
    rt.dispose();
  }
}

console.log(`语料：${SRC}`);
console.log(`顶层脚本：${files.length} 个（按名字排序全加载，共享模块环境）\n`);

const passes: Pass[] = [
  { label: "没有解析器（批134 之前的行为）", resolve: false },
  { label: "装上模块解析器（本轮）", resolve: true },
];

let lastFail: Array<[string, string]> = [];
for (const pass of passes) {
  const r = await run(pass);
  const total = files.length;
  const pct = ((r.ok / total) * 100).toFixed(1);
  console.log(`▸ ${pass.label}：${r.ok} 通过 / ${r.fail.length} 失败（共 ${total}，通过率 ${pct}%）`);
  lastFail = r.fail;
}

if (lastFail.length > 0) {
  console.log(`\n解析器那一轮仍失败的，前 ${Math.min(MAX_FAIL, lastFail.length)} 条：`);
  for (const [name, msg] of lastFail.slice(0, MAX_FAIL)) {
    console.log(`  ✗ ${name}：${msg.split("\n")[0]}`);
  }
  const kinds = new Map<string, number>();
  for (const [, msg] of lastFail) {
    const head = msg.split("\n")[0] ?? "";
    // 取**最内层**那一句（`模块 A 加载失败（源：x）：B:12: 真正的原因` 的最后一段），
    // 再去掉"文件:行号"和具体名字 —— 否则每条都因为模块名不同而各成一类，
    // 归类表会退化成"54 条各 1 次"，等于没归类。
    const inner = head.split("）：").pop() ?? head;
    const key = inner.replace(/^\s*[^:]*:\d+:\s*/, "").replace(/'[^']*'/g, "'<name>'").slice(0, 80);
    kinds.set(key, (kinds.get(key) ?? 0) + 1);
  }
  console.log("\n按形状归类：");
  for (const [k, n] of [...kinds.entries()].sort((a, b) => b[1] - a[1])) {
    console.log(`  ${String(n).padStart(3)} × ${k}`);
  }
  process.exit(1);
}

console.log("\n✓ 全部通过");
