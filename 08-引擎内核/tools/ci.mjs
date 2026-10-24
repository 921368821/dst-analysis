#!/usr/bin/env node
/**
 * 本地 CI：一条命令跑完**全部**闸门，顺序固定、fail fast、最后给一张表。
 *
 * ★ 为什么 CI 的"定义"放在这里而不是 `.github/workflows/*.yml`：
 *   workflow 文件只能在 GitHub 上验证，在本地它就是一段没人执行的 YAML。
 *   把步骤写成一个能在这里真跑起来的脚本，workflow 只负责"调用它" ——
 *   于是"CI 挂了"可以在本地复现，而不是靠猜日志。
 *
 * ★ 顺序是有理由的（不是按字母排）：
 *   ① typecheck 最快，语法都不对时别浪费时间跑判据；
 *   ② 判据 → 覆盖率 → 文档对账：三道闸门都基于"判据是真的在跑"；
 *   ③ 语料与金标：需要外部解释器（python/Pillow/ffmpeg），失败原因通常是环境而非代码；
 *   ④ 变异放最后：它要重跑很多次判据，最慢，而且前提是判据本身已经绿。
 *
 * 用法：
 *   node tools/ci.mjs            # 全套（含变异，慢）
 *   node tools/ci.mjs --fast     # 跳过外部语料与变异（改代码时的常用档）
 *   node tools/ci.mjs --list     # 只打印步骤清单
 *
 * 退出码：0 全绿；1 有步骤失败（并打印失败步骤的输出尾部）。
 */

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const FAST = process.argv.includes("--fast");
const LIST = process.argv.includes("--list");

/**
 * 变异校验运行期间，`src/` 是**被故意改坏**的状态。
 * 此时跑判据得到的红不是真的 —— 与其在报告里解释"那个红是别的原因"，
 * 不如直接拒绝启动（红得没依据的闸门会被训练成噪音）。
 */
const MUTATION_LOCK = join(ROOT, ".cache", "mutation.lock");
if (!LIST && existsSync(MUTATION_LOCK)) {
  console.error(
    "✗ 有一轮变异校验正在跑（.cache/mutation.lock 存在）——\n" +
      "  它正在就地改 src/ 的源码，现在跑 CI 得到的红不可信。等它结束后再来。",
  );
  process.exit(2);
}

const NPM = process.platform === "win32" ? "npm.cmd" : "npm";

/**
 * 找一个**能 import PIL 的** python。
 * 为什么不能直接写 `python`：本机系统 python 没有 Pillow，而 Pillow 是金标生成器，
 * 缺了它 jpeg 金标那一步会以"看起来像代码错"的方式失败 —— 环境问题必须报成环境问题。
 */
function findPython(needPillow) {
  if (!needPillow) {
    for (const c of [process.env.PYTHON, "python3", "python"]) {
      if (!c) continue;
      const r = spawnSync(c, ["-c", "import sys;print(sys.version_info[0])"], { encoding: "utf8" });
      if (r.status === 0) return c;
    }
    return null;
  }
  const candidates = [
    process.env.JPEG_PYTHON,
    process.env.PYTHON,
    // 本仓库已知的隔离环境（开发机）
    "C:/Users/admin/.workbuddy/binaries/python/envs/jpeg/Scripts/python.exe",
    "python3",
    "python",
  ].filter((c) => typeof c === "string" && c !== "");
  for (const c of candidates) {
    const r = spawnSync(c, ["-c", "import PIL, numpy"], { encoding: "utf8" });
    if (r.status === 0) return c;
  }
  return null;
}

/** @type {{name: string, cmd: string, args: string[], env?: Record<string,string>}[]} */
const STEPS = [];

function node(name, script, args = [], opts = {}) {
  STEPS.push({ name, cmd: process.execPath, args: [script, ...args], ...opts });
}
function npm(name, script) {
  STEPS.push({ name, cmd: NPM, args: ["run", script] });
}
function py(name, script, args = [], needPillow = false) {
  const exe = findPython(needPillow);
  if (exe === null) {
    STEPS.push({
      name,
      cmd: "__missing_python__",
      args: [],
      env: { NEED_PILLOW: needPillow ? "1" : "0", SCRIPT: script, EXTRA: args.join(" ") },
    });
    return;
  }
  STEPS.push({ name, cmd: exe, args: [script, ...args] });
}

npm("类型检查", "typecheck");
npm("判据（全量）", "test");
// ★ 性能闸门必须**独占**跑：它测的是解算耗时，而 `npm test` 并行跑七十多个文件
//   （还有 PNG/JPEG 语料与世界 soak）。并行时它测到的是"机器多忙"而不是"代码多慢"，
//   于是出现"15 轮补跑全慢、单跑立刻 5ms"的噪声红。阈值一个字没动（仍是 8ms），
//   只是换了环境 —— `npm test` 里保留 40ms 粗筛抓真退化。
node("物理性能闸门（独占）", "tools/perf-gate.mjs");
npm("覆盖率闸门", "coverage:gate");
node("文档对账", "tools/docs-check.mjs");

if (!FAST) {
  py("拒绝路径审计", "tools/audit-error-paths.py");
  // ★ 唯一的已知缺陷：源文件本身只有一半扫描线（解码器正确拒绝）。
  //   必须**显式登记**而不是"容差"—— 脚本会双向核对：多一个失败就红，
  //   这个缺陷哪天不复现了也红（逼人销账）。
  node("PNG 语料校验", "tools/verify-png-corpus.mjs", ["--all", "--known-defect", "_cmp_pair.png"]);
  py("JPEG ffmpeg 金标 --check", "tools/jpeg-ffmpeg-gold.py", ["--check"], true);
  // ★ 浏览器自检要最新的 bundle，先构建（200ms，不值得省）
  npm("浏览器包构建", "build:web");
  // ★ `skipCode: 2`：没有浏览器时**跳过并显式标注**，不是"通过"。
  //   把"环境缺失"混进 0 就是假绿灯（CI 在没有浏览器的机器上一路绿）；
  //   混进 1 就是假红（人去查一个不存在的 bug）。
  node("浏览器端自检", "tools/browser-selftest.mjs", [], { skipCode: 2 });
  // ★ 编辑器页自检（阶段 4 的出口判据）：树 → 选中 → 改属性 → 单步 → 播放/暂停。
  //   与"浏览器端自检"分开成两步，是因为失败时要一眼看出是**运行时**坏了还是**编辑器**坏了；
  //   合成一步的话，一次红要翻两页的控制台才知道该谁修。
  node("编辑器页自检", "tools/editor-selftest.mjs", [], { skipCode: 2 });
  // ★ 跨宿主**逐字节**存档比对：同一份语料在 Node 与浏览器各跑一遍，比字节。
  //   与自检同理，没有浏览器时 `skipCode: 2` 显式跳过（不混进"通过"）。
  node("跨宿主存档比对", "tools/cross-host-save.mjs", [], { skipCode: 2 });
  py("变异校验", "tools/mutation-check.py");
}

if (LIST) {
  console.log(`共 ${STEPS.length} 步${FAST ? "（--fast）" : ""}：`);
  for (const s of STEPS) console.log(`  · ${s.name}`);
  process.exit(0);
}

const rows = [];
let failed = null;

for (const s of STEPS) {
  if (s.cmd === "__missing_python__") {
    rows.push({ name: s.name, ok: false, ms: 0 });
    failed = {
      name: s.name,
      tail: [
        s.env.NEED_PILLOW === "1"
          ? "缺少能 import PIL 的 python（jpeg 金标需要 Pillow + numpy）"
          : "找不到可用的 python",
        `请安装依赖，或用 JPEG_PYTHON=... / PYTHON=... 指定解释器。脚本：${s.env.SCRIPT}`,
      ].join("\n"),
    };
    break;
  }
  process.stdout.write(`\n=== ${s.name} ===\n`);
  const t0 = Date.now();
  const r = spawnSync(s.cmd, s.args, {
    cwd: ROOT,
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 128 * 1024 * 1024,
    shell: s.cmd === NPM,
  });
  const ms = Date.now() - t0;
  const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  // 进度条用 `\r` 原地刷新：直接回显会拼成一行几千字的"进度历史"，把真正的报错挤出去
  const cleaned = out.replace(/\r\n/g, "\n").replace(/[^\n]*\r/g, "");
  // 只回显尾部：判据输出动辄上千行，全打出来等于什么都看不见
  const tail = cleaned.split(/\r?\n/).slice(-12).join("\n");
  console.log(tail);
  const isSkip = s.skipCode !== undefined && r.status === s.skipCode;
  rows.push({ name: s.name, ok: r.status === 0, ms, skip: isSkip });
  if (isSkip) console.log(`· 跳过（环境缺失，不算通过）：${s.name}`);
  if (r.status !== 0 && !isSkip) {
    failed = { name: s.name, tail };
    break;
  }
}

console.log("\n================ 汇总 ================");
for (const r of rows) {
  const sec = (r.ms / 1000).toFixed(1).padStart(6);
  const mark = r.skip === true ? "⊘" : r.ok ? "✔" : "✘";
  console.log(`  ${mark} ${r.name.padEnd(24, " ")} ${sec}s${r.skip === true ? "   ← 环境缺失，未执行" : ""}`);
}
if (failed !== null) {
  console.error(`\n✘ 失败步骤：${failed.name}`);
  console.error("---- 输出尾部 ----");
  console.error(failed.tail);
  process.exit(1);
}
const skipped = STEPS.length - rows.length;
const envSkipped = rows.filter((r) => r.skip === true).length;
console.log(
  `\n✓ 全部通过${skipped > 0 ? `（${skipped} 步未执行）` : ""}` +
    `${envSkipped > 0 ? `；**但 ${envSkipped} 步因环境缺失被跳过**（${rows.filter((r) => r.skip === true).map((r) => r.name).join("、")}）` : ""}`,
);
process.exit(0);
