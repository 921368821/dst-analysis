#!/usr/bin/env node
/**
 * 物理性能闸门（**独占**跑）：把 `tests/core/physics-perf.test.ts` 单独拉起来，
 * 用完整的 8ms 预算判定。
 *
 * ★ 为什么需要这一步：那条判据测的是"解算一次要多久"，而 `npm test` 会**并行**跑
 *   七十多个测试文件（还有 JPEG/PNG 语料、世界 soak 这些重活）。并行时它测到的是
 *   "这台机器现在有多忙"，不是"这段代码有多慢" —— 于是 15 轮补跑全慢、判据红，
 *   而单跑立刻回到 5ms。噪声红会训练人忽略闸门，这是比慢更贵的事。
 *
 * ★ 为什么不是"把 8ms 改成 40ms"：那是放宽阈值。这里做的是**换环境**：
 *   阈值一个字没动，只是不再跟别的用例抢 CPU。`npm test` 里保留 40ms 的粗筛
 *   （抓"慢了 5 倍"级别的真退化），严格判定由本脚本负责。
 *
 * 退出码：0 通过 / 1 判据失败 / 2 环境问题（没有 node 的 test runner）。
 *
 * 用法：`node tools/perf-gate.mjs`（CI 的第 3 步）
 */

import { spawnSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const FILE = "tests/core/physics-perf.test.ts";

const r = spawnSync(process.execPath, ["--experimental-transform-types", "--test", FILE], {
  cwd: ROOT,
  encoding: "utf8",
  env: { ...process.env, ENGINE_PERF_STRICT: "1", NODE_NO_WARNINGS: "1" },
});

const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
// 只回显结论附近的内容：这个文件会打一堆数字，全打出来会把失败行挤掉
const lines = out.split(/\r?\n/).filter((l) => l.trim() !== "");
const fails = lines.filter((l) => l.startsWith("not ok"));
const summary = lines.filter((l) => /^# (pass|fail)/.test(l));

if (r.error !== undefined) {
  console.error(`✗ 起不来：${r.error.message}（环境问题，不是判据失败）`);
  process.exit(2);
}
if (r.status !== 0) {
  console.error("✗ 物理性能闸门（独占，8ms 预算）未通过：");
  for (const l of fails.length > 0 ? fails : lines.slice(-12)) console.error(`  ${l}`);
  process.exit(1);
}
console.log(`✓ 物理性能闸门（独占，8ms 预算）通过：${summary.join(" ")}`);
process.exit(0);
