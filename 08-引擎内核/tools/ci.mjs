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
import { appendFileSync, existsSync } from "node:fs";
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
function py(name, script, args = [], needPillow = false, opts = {}) {
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
  STEPS.push({ name, cmd: exe, args: [script, ...args], ...opts });
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
  // ★ `skipCode: 2`：金标是**某个具体 ffmpeg 构建**的产物（本地是 gyan.dev 的 7.1
  //   Windows 构建），而 CI 上 `pip install imageio-ffmpeg` 装的是 Linux 构建 ——
  //   同一份流、同一个 12 位灰度样本，两家解出来的样本值不同。逐字节比对在异构
  //   构建上没有判别力，脚本此时退出码 2（不是 0：那不是"通过"）。
  //   判据本身不用 ffmpeg（读入库金标），覆盖不受影响。
  py("JPEG ffmpeg 金标 --check", "tools/jpeg-ffmpeg-gold.py", ["--check"], true, { skipCode: 2 });
  // ★ 上一条的三分退出码**本身**要有人守：否则「构建不同」会变成万能免罪符，
  //   真把编码器改坏了、恰好又在异构构建上跑，一样被放过去。
  //   自检显式把版本行设成"当前"或"别的构建"，四种情形（0/1/2/1）在哪个平台都可复现。
  py("JPEG 金标三分自检", "tools/jpeg-ffmpeg-gold-selftest.py", [], true, { skipCode: 2 });
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
  // ★★ 但**尾部对 `npm test` 是没有信息量的**：node:test 的最后 12 行是
  //   `1..1413 / # tests / # pass / # fail` 汇总，它说"39 条红"，不说"哪 39 条"。
  //   所以另外抓失败行本身 —— 判据红了要能直接看到用例名，否则只能靠猜或重跑。
  const allLines = cleaned.split("\n");
  // ★★ 语义行**优先**，`not ok` 垫底。
  //
  //   2026-10-25 第九轮实测：变异校验跑 278 条会打出**几百行** `not ok` ——
  //   那是"变异被抓住"的**证据**，不是失败；真正的失败摘要在最后
  //   （`✗ 未通过 2 条：M12(假绿)、M45(漂移)`）。
  //   而下面原本的 `.slice(0, 25)` 取的是**前** 25 条 ⇒ annotation 里只剩预期内的
  //   `not ok`，该看的那一行永远进不去。**不是信息不存在，是取值顺序把它吃掉了。**
  const matches = allLines
    .map((l) => l.trim())
    .filter(
      (l) =>
        /^(not ok\b|✗|×|FAIL\b)/.test(l) ||
        /·\s*\[(判据假绿|靶子漂移|还原不干净)\]/.test(l),
    );
  const semantic = matches.filter((l) => !/^not ok\b/.test(l)).slice(0, 12);
  const plainNotOk = matches.filter((l) => /^not ok\b/.test(l));
  const failing = [...semantic, ...plainNotOk].slice(0, 25);
  // ★★ 光有用例名还是不够：`not ok N - 名字` 只说"它红了"，不说"为什么红"。
  //   node:test 的 TAP 会在 `not ok` 之后紧跟一个 `---` 块，里面有 `error:` /
  //   `expected:` / `actual:` —— 那才是可行动的东西。
  //   只取**前 3 条**判据的详情：annotation 有长度上限，而且 3 条失败详情
  //   足以定位一个共同的根因（比 25 条名字有用得多）。
  const detail = [];
  for (let i = 0; i < allLines.length && detail.length < 3; i++) {
    if (!/^\s*not ok\b/.test(allLines[i])) continue;
    detail.push(allLines[i].trimEnd());
    for (let j = i + 1; j < Math.min(i + 16, allLines.length); j++) {
      const line = allLines[j];
      if (/^\s*(not ok|ok)\b/.test(line)) break;
      detail.push(line.replace(/\r$/, ""));
    }
  }
  console.log(tail);
  const isSkip = s.skipCode !== undefined && r.status === s.skipCode;
  rows.push({ name: s.name, ok: r.status === 0, ms, skip: isSkip });
  if (isSkip) console.log(`· 跳过（环境缺失，不算通过）：${s.name}`);
  if (r.status !== 0 && !isSkip) {
    failed = { name: s.name, tail, failing, detail };
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
  // ★★ 把失败摘要写进 GitHub 的 **annotation**，而不是只打在 stdout。
  //
  //   原因很具体：job 日志（GET /actions/jobs/{id}/logs）**需要仓库 admin 权限**，
  //   公开仓库也一样（实测 403 "Must have admin rights"）。而 annotations
  //   （GET /repos/{o}/{r}/check-runs/{id}/annotations）**匿名可读**。
  //
  //   没有这一行时，一次 CI 失败在外部只能看到一句
  //   "Process completed with exit code 1." —— 它不说哪个判据红、红在哪。
  //   2026-10-24 首次真实运行就是这样：三个 job 两个红，而"为什么红"完全不可见。
  //
  //   `::error::` 是 Actions 的工作流命令，由 runner 从输出里解析。只在
  //   `GITHUB_ACTIONS=true` 时才写，免得污染本地终端。
  if (process.env.GITHUB_ACTIONS === "true") {
    const ghEsc = (s) =>
      String(s).replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
    // ★ 保留换行（不压成一行）：多行尾巴直接可读，压成 "a ⏎ b" 后
    //   人眼要在一条长串里找红行，而这条 annotation 的全部价值就是那一行。
    const tailLines = failed.tail.split(/\r?\n/).filter((l) => l.trim() !== "").slice(-12);
    // ★ 把**已经跑过的步骤**也带上：只看"哪步挂了"不够，还要知道
    //   "它前面那些步在这台机器上花了几秒" —— 否则分不清
    //   "真的坏了"与"这台机器太慢"（8ms 性能闸门就是靠这个判的）。
    const done = rows
      .map((r) => `${r.skip === true ? "⊘" : r.ok ? "✔" : "✘"} ${r.name} ${(r.ms / 1000).toFixed(1)}s`)
      .join(" / ");
    const body = [
      `已过步骤：${done}`,
      "",
      ...(failed.failing !== undefined && failed.failing.length > 0
        ? ["失败用例（最多 25 条）：", ...failed.failing, ""]
        : []),
      ...(failed.detail !== undefined && failed.detail.length > 0
        ? ["前 3 条判据的失败详情：", ...failed.detail, ""]
        : []),
      ...tailLines,
    ].join("\n");
    process.stderr.write(`::error title=CI 失败·${failed.name}::${ghEsc(body)}\n`);
    // 同时写进 job summary：网页上看 Actions 摘要时不用展开 20 万行日志
    const summaryFile = process.env.GITHUB_STEP_SUMMARY;
    if (typeof summaryFile === "string" && summaryFile !== "") {
      try {
        appendFileSync(
          summaryFile,
          `## ✘ CI 失败：${failed.name}\n\n**已过步骤**：${done}\n\n<details><summary>输出尾部</summary>\n\n\`\`\`\n${failed.tail}\n\`\`\`\n\n</details>\n`,
        );
      } catch {
        // summary 写不进去不该影响退出码（它只是给人看的）
      }
    }
  }
  process.exit(1);
}
const skipped = STEPS.length - rows.length;
const envSkipped = rows.filter((r) => r.skip === true).length;
console.log(
  `\n✓ 全部通过${skipped > 0 ? `（${skipped} 步未执行）` : ""}` +
    `${envSkipped > 0 ? `；**但 ${envSkipped} 步因环境缺失被跳过**（${rows.filter((r) => r.skip === true).map((r) => r.name).join("、")}）` : ""}`,
);
process.exit(0);
