#!/usr/bin/env node
/**
 * 文档数字对账：只核对**显式声明为"当前值"**的数字，不猜散文里的历史值。
 *
 * ★ 为什么需要：判据数 / 变异数 / 测试文件数在 README、PROGRESS、ARCHITECTURE 里重复出现，
 *   今天漂了三次（593 写成 612、618 写成 623、加 5 条写成 +7）。人肉对账在多文件重复同一数字时
 *   **必然会漂** —— 漂移该由一条会红的命令挡住，不该靠"下次注意"。
 *
 * ★ 为什么不做成"扫描所有数字"：第一版就是这么写的，结果在
 *   「判据 180 → 317」「上一代引擎的 274 条判据」这类**历史叙述**上全线误报 9 处。
 *   一个会喊狼的检查器比没有更糟：它训练人忽略红字。
 *   所以改成**标记制**：只有作者明确标了 `<!-- n:tests -->`（紧跟在数字后面）的地方才被核对。
 *   没标的地方就是"历史叙述"或"局部统计"，工具不碰。
 *
 * 用法：
 *   node tools/docs-check.mjs           # 跑一遍测试取真实数字，再核对
 *   node tools/docs-check.mjs --quick   # 用 .cache/test-count.json 里上次的数字（tests/ 有改动则自动重跑）
 *   node tools/docs-check.mjs --fix     # 把对不上的数字**就地改成实测值**（只改紧贴在标记前的那个数）
 *
 * ★ 为什么允许 --fix 自动改文档：这些数字是**派生值**，唯一真值在代码里。
 *   手抄一次就会漂一次，而"改文档让闸门变绿"在这里不是作弊 —— 它改的是派生量，
 *   不是判据。反过来，工具**不敢**自动改的东西是散文（"仍然没有外部实现"这种断言），
 *   那些只能人改，所以它们根本不带标记。
 *
 * ★ --fix 只改**紧贴在标记前**的那个数字。所以写文档时不要在标记后面再重复一遍
 *   （"681 条 <!-- n:tests -->（681 通过）"里的第二个 681 它不管，会留在原地发臭）——
 *   要么只写一次，要么写成"全部通过"。
 *
 * ★ --quick 的缓存带新鲜度凭证（tests/ 全量文件的 路径+大小+mtime），不是"信任上次结果"：
 *   改过测试却拿旧数字对账，正是假绿灯的标准形态。
 *
 * 标记写法（数字在前，标记紧跟）：
 *   - **636 条判据全绿** <!-- n:tests -->
 *     npm run audit:mutation  # 变异校验：54 组注入 <!-- n:mutants -->
 *   支持：n:tests / n:mutants / n:files / n:browser / n:editor / n:jpeggold / n:srcfiles / n:srclines
 */

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { EDITOR_DECLARED } from "./editor-declared.mjs";
import { GAP_HEADING, findForgottenClosures, findStaleGapRows, findUnresolvedClaims, gapRowCount } from "./gap-check.mjs";
import { blockerRowCount, findBlockerIssues, pickBlockersDoc } from "./blockers-check.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const QUICK = process.argv.includes("--quick");
const FIX = process.argv.includes("--fix");
/**
 * 只跑「缺口清单对账」就退出。
 *
 * ★ 为什么需要它：接线判据（`tests/tools/gap-check.test.ts` 最后一条）必须证明
 *   **这段代码真的被调用**——纯函数的判据证不了这件事，整块删掉照样全绿。
 *   而完整的 docs-check 要先数判据（`--quick` 在缓存过期时直接退出），
 *   在 `npm test` 里嵌一次全量跑是不可接受的。所以给它一条只走这段代码的路。
 *   ★ 校验逻辑与正常路径**共用同一段代码**，开关只决定"跑完这段之后走不走"。
 */
const GAP_ONLY = process.argv.includes("--gap-only");
const CACHE = join(ROOT, ".cache", "test-count.json");

/**
 * ★ 缺口清单对账（批97）：一条「缺口」点名了某个 `tools/` 路径，而那个工具**已经在 CI 里跑** ——
 *   那这条缺口要么早就做完了（该改清单），要么它缺的根本不是这个工具（该改措辞）。
 *
 *   2026-10-27 实测：`PROGRESS §六` 的「headless ↔ 浏览器逐字节存档」从批57 起就一直写着
 *   "浏览器侧只断言到 Lua 算得对 + 跨界日志可见"，而 `tools/cross-host-save.mjs` 那时
 *   就在 CI 里跑了。批94 清查阻塞项时我**照抄了那一行**，于是一件已完成的事被记成了
 *   `BLOCKERS` 的 C12，还配了一句自己编的现状。**对账的对象是磁盘，不是上一版清单。**
 *
 *   ★ 反向自检不是可选项：这条判据今天**永远输出 0 条**，而"没在扫"与"扫了没发现"
 *   在这份输出上完全一样。所以每次都要拿一条合成的过期行打自己一发。
 */
/**
 * 当前生效的阻塞清单文件名。
 *
 * ★ 声明位置**必须在 `gapIssues` 之前**：批113 那条「仍缺必须挂编号」要读清单，
 *   而它跑在缺口对账里。原本这两个块谁也不需要谁，加了一行就读到 TDZ —— 报错信息
 *   是「Cannot access 'blockersFile' before initialization」，看上去像文件路径的错。
 */
const blockersFile = pickBlockersDoc(readdirSync(join(ROOT, "docs")));

const gapIssues = (() => {
  const docText = readFileSync(join(ROOT, "docs", "PROGRESS.md"), "utf8");
  const ciText = readFileSync(join(ROOT, "tools", "ci.mjs"), "utf8");
  const exists = (rel) => {
    try {
      readFileSync(join(ROOT, rel));
      return true;
    } catch {
      return false;
    }
  };
  const SAMPLE = [
    GAP_HEADING,
    "",
    "| 缺口 | 现状 | 在等什么 |",
    "|---|---|---|",
    "| 合成的过期行（没标已消除） | 现状 | `tools/ci.mjs` 早就在跑 |",
    "",
    "## 七、结束",
    "",
  ].join("\n");
  const probe = findStaleGapRows({ docText: SAMPLE, exists: () => true, ciText: "tools/ci.mjs" });
  if (probe.length !== 1) {
    console.error("✗ 清单对账打不中合成的过期行 —— 这条判据是摆设（绿着但没在扫）");
    process.exit(2);
  }
  const gapRows = gapRowCount(docText);
  const stale = findStaleGapRows({ docText, exists, ciText });

  // ★ 「仍缺」必须挂阻断编号（批113，规则见 `tools/gap-check.mjs` 的 findUnresolvedClaims）。
  //   反向自检同样不是可选项：零条输出分不清「没在扫」与「扫了没问题」。
  const blockersText = readFileSync(join(ROOT, "docs", blockersFile), "utf8");
  const CLAIM_SAMPLE = [
    GAP_HEADING,
    "",
    "| 缺口 | 现状 | 在等什么 |",
    "|---|---|---|",
    "| 甲 | 现状 | **仍缺**：没写编号 |",
    "| 乙 | 现状 | **仍缺**：早就做完了（C2） |",
    "| 丙 | 现状 | **仍缺**：还在做（C9） |",
    "| 丁 | 现状 | ~~仍缺：写完了~~ ✅ |",
    "",
    "## 七、结束",
    "",
  ].join("\n");
  const CLAIM_BLOCKERS = [
    "| # | 项 | 状态 |",
    "|---|---|---|",
    "| C2 | 剧情解锁 | ✅ 批103 |",
    "| C9 | 富文本 | 🔜 批106 起 |",
    "",
  ].join("\n");
  const claimProbe = findUnresolvedClaims(CLAIM_SAMPLE, CLAIM_BLOCKERS);
  const probeOk =
    claimProbe !== null &&
    claimProbe.length === 2 &&
    claimProbe.some((x) => x.kind === "uncited") &&
    claimProbe.some((x) => x.kind === "stale" && x.ids.includes("C2"));
  if (!probeOk) {
    console.error("✗ 「仍缺必须挂编号」打不中合成语料 —— 这条判据是摆设（绿着但没在扫）");
    process.exit(2);
  }
  const claims = findUnresolvedClaims(docText, blockersText) ?? [];

  // ★ 「做完了却没关单」（批131，规则见 `tools/gap-check.mjs` 的 findForgottenClosures）。
  //   反向自检同样不是可选项：这条判据今天应当输出 0 条（唯一的实例已被修掉），
  //   而「0 条」与「没在扫」在这份输出上完全一样。
  const CLOSE_SAMPLE = [
    GAP_HEADING,
    "",
    "| 缺口 | 现状 | 在等什么 |",
    "|---|---|---|",
    "| 合成的没关单 | **已交付**（批99） | 已完成 |",
    "| 真的还在半路 | 已交付一半，仍缺 B | —— |",
    "| ~~划掉的那种~~ | 已交付 | —— |",
    "| 还在做 | 没做 | —— |",
    "",
    "## 七、结束",
    "",
  ].join("\n");
  const closeProbe = findForgottenClosures(CLOSE_SAMPLE);
  const closeProbeOk =
    closeProbe !== null && closeProbe.length === 1 && closeProbe[0].head === "合成的没关单";
  if (!closeProbeOk) {
    console.error("✗ 「做完了却没关单」打不中合成语料 —— 这条判据是摆设（绿着但没在扫）");
    process.exit(2);
  }
  const forgotten = findForgottenClosures(docText) ?? [];
  console.log(
    `清单对账：§六 缺口行 ${gapRows} 行，过期 ${stale.length} 条，未挂编号/已过期的「仍缺」 ${claims.length} 条，做完却没关单 ${forgotten.length} 条`,
  );
  if (GAP_ONLY) {
    // ★ 退出码要带得走原因：`--gap-only` 在 problems 汇总之前就退出了，
    //   只留一个 1 的话，接线判据红起来只有「rc=1」—— 与「脚本崩了」分不开。
    for (const it of [...stale, ...claims, ...forgotten]) {
      console.error(`  ✗ PROGRESS.md:${it.no} ${it.kind ?? "stale-tool"} ${it.head ?? ""}`);
    }
    process.exit(stale.length === 0 && claims.length === 0 && forgotten.length === 0 ? 0 : 1);
  }
  return [...stale, ...claims, ...forgotten];
})();

/**
 * ★ 阻塞项对账（批102）：规则见 `tools/blockers-check.mjs` 的文件头。
 *
 *   2026-10-27 实测：清单里 C5 / C7 / C10 / C11 四条**早就做完了**却还挂着"没做"
 *   （C12 是同一形状的第三次）。根因不是"某人忘了改"，而是**这句话没有任何东西在管**：
 *   一条 ✅ 只要有人写过一次就永久成立 —— 代码变了、文件改名了、判据被删了，
 *   没有任何一环会去问它一句。
 *
 *   ★ 反向自检同样不是可选项：今天它输出 0 条，而"没在扫"与"扫了没问题"在输出上一样。
 */
const BLOCKERS_ONLY = process.argv.includes("--blockers-only");
// （声明已上移到 §六 缺口对账之前 —— 那里要用它读清单，见批113）
const blockerIssues = (() => {
  if (blockersFile === null) {
    console.error("✗ docs/ 下没有 BLOCKERS-*.md —— 阻塞清单不在了，这条判据无从对账");
    process.exit(2);
  }
  const docText = readFileSync(join(ROOT, "docs", blockersFile), "utf8");
  const exists = (rel) => {
    try {
      readFileSync(join(ROOT, rel));
      return true;
    } catch {
      return false;
    }
  };
  const readText = (rel) => {
    try {
      return readFileSync(join(ROOT, rel), "utf8");
    } catch {
      return "";
    }
  };
  const SAMPLE = [
    "# 阻塞项",
    "",
    "| # | 项 | 现状 | 验证 | 状态 |",
    "|---|---|---|---|---|",
    "| C99 | 合成的坏行（标了已消除却一个文件都没点名） | 现状 | —— | ✅ 已消除 |",
    "",
  ].join("\n");
  const probe = findBlockerIssues({ docText: SAMPLE, exists: () => true, readText: () => "" });
  if (probe.length !== 1) {
    console.error("✗ 阻塞项对账打不中合成的坏行 —— 这条判据是摆设（绿着但没在扫）");
    process.exit(2);
  }
  const bad = findBlockerIssues({ docText, exists, readText });
  console.log(`阻塞项对账：${String(blockerRowCount(docText))} 行，问题 ${String(bad.length)} 条`);
  if (BLOCKERS_ONLY) process.exit(bad.length === 0 ? 0 : 1);
  return bad;
})();

/**
 * 缓存必须自带**新鲜度凭证**，否则 --quick 就是一台假绿灯机器：
 * "改了测试 → 缓存还是旧数字 → 文档里那个旧数字被判定为一致"。
 *
 * ★ 凭证用**内容哈希**，不用 mtime+size。
 *   2026-10-23 踩过：变异校验里有两条会改 `tests/tools/jpeg-encode.ts`（测试辅助），
 *   改完再还原 —— 内容一个字节没变，mtime 却变了。mtime 派生的凭证当场判"过期"，
 *   而"过期"的补救是去跑整套测试，但变异期间测试入口**拒绝启动**（src/ 正被改坏），
 *   于是 docs-check 恒失败，被误报成"还原不干净"。
 *   mtime 是个会说谎的代理：`touch`、`git checkout`、改完还原，都会让它变而内容不变。
 */
function testsStamp() {
  const h = createHash("sha1");
  const walk = (p, out = []) => {
    for (const e of readdirSync(p, { withFileTypes: true })) {
      const q = join(p, e.name);
      if (e.isDirectory()) walk(q, out);
      else if (e.isFile()) out.push(q);
    }
    return out;
  };
  for (const f of walk(join(ROOT, "tests")).sort()) {
    h.update(f);
    h.update(readFileSync(f));
  }
  return h.digest("hex");
}

function runSuite() {
  // ★ `--test-reporter=tap` 是**必须显式指定**的，不能靠默认值。
  //   2026-10-25 踩过：默认 reporter 在 Node 22 下是 TAP（`# tests 1493`），
  //   在 Node 24 下变成 spec（`ℹ tests 1493`）。于是同一个仓库、同一份代码，
  //   只因为 PATH 里的 node 从 22 换到 24，这个闸门就从"全绿"变成
  //   "✗ 测试输出里没有 `# tests N` —— 测试根本没跑起来"。
  //   而它其实是**跑了且全过**的。这类"结论随环境变"的闸门比没有闸门更危险：
  //   它的红字指向的是解释器，不是被测对象，照着红字改只会越改越远。
  const args = ["--experimental-transform-types", "--test-reporter=tap", "--test", "tests/run.ts"];
  const r = spawnSync(process.execPath, args, {
    cwd: ROOT,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  const out = `${r.stdout ?? ""}\n${r.stderr ?? ""}`;
  // 仍然两种前缀都认：万一将来 `--test-reporter=tap` 被重命名/忽略，
  // 也不至于把"跑了 1493 条全过"误判成"根本没跑"。
  const t = /^[#ℹ]\s*tests (\d+)$/m.exec(out);
  const f = /^[#ℹ]\s*fail (\d+)$/m.exec(out);
  if (t === null) {
    console.error("✗ 测试输出里既没有 `# tests N` 也没有 `ℹ tests N` —— 测试根本没跑起来");
    process.exit(2);
  }
  if (f !== null && Number(f[1]) !== 0) {
    console.error(`✗ 有 ${f[1]} 条判据失败 —— 先修测试再对账（文档数字此时没有意义）`);
    // ★ 失败时必须说出**是哪几条**：只报条数时，"基线不绿"这三个字没有任何行动信息
    //   （2026-10-24：变异校验连跑三次卡在"1 条判据失败"，而全量单跑三次全绿 ——
    //    没有测试名，连"是不是同一条在抖"都判断不了，只能瞎猜）。
    //   注意 node:test 的 `not ok` 行与紧随的 `error:` 行才是定位信息，其余都是噪声。
    const bad = out.split("\n").filter((ln) => /^not ok /.test(ln)).slice(0, 5);
    for (const ln of bad) console.error(`  ${ln.trim()}`);
    const errs = out.split("\n").filter((ln) => /^\s+error:/.test(ln)).slice(0, 5);
    for (const ln of errs) console.error(`  ${ln.trim()}`);
    if (bad.length === 0) console.error("  （输出里没有 not ok 行 —— 测试可能根本没跑起来，看上面的原始输出）");
    process.exit(2);
  }
  return Number(t[1]);
}

function actualTests() {
  const stamp = testsStamp();
  if (QUICK && existsSync(CACHE)) {
    let cache = null;
    try {
      cache = JSON.parse(readFileSync(CACHE, "utf8"));
    } catch {
      cache = null; // 旧格式（纯数字）或损坏：当作没有缓存，老老实实跑
    }
    if (cache !== null && cache.stamp === stamp && Number.isFinite(cache.tests)) {
      return cache.tests;
    }
    if (cache !== null) {
      console.log("· 缓存过期（tests/ 有改动），重跑一遍测试取真实数字");
    }
  }
  // 变异校验运行期间 src/ 是被故意改坏的，此时跑出来的"判据数"没有意义
  if (existsSync(join(ROOT, ".cache", "mutation.lock"))) {
    console.error("✗ 有一轮变异校验正在跑（.cache/mutation.lock）—— 现在跑测试得到的数字不可信，等它结束");
    process.exit(2);
  }
  const n = runSuite();
  mkdirSync(join(ROOT, ".cache"), { recursive: true });
  writeFileSync(CACHE, JSON.stringify({ tests: n, stamp, at: new Date().toISOString() }));
  return n;
}

function actualMutants() {
  const src = readFileSync(join(ROOT, "tools", "mutation-check.py"), "utf8");
  return [...src.matchAll(/"name":\s*"(M\d+)/g)].map((m) => m[1]);
}

function actualFiles() {
  const r = spawnSync(
    process.execPath,
    ["-e", "const {readdirSync}=require('node:fs');const {join}=require('node:path');" +
      "const d=(p,o=[])=>{for(const e of readdirSync(p,{withFileTypes:true})){const q=join(p,e.name);" +
      "if(e.isDirectory())d(q,o);else if(e.name.endsWith('.test.ts')&&e.name!=='run.ts')o.push(q);}return o;};" +
      "console.log(d('tests').length)"],
    { cwd: ROOT, encoding: "utf8" },
  );
  return Number((r.stdout ?? "").trim());
}

function actualBrowser() {
  const src = readFileSync(join(ROOT, "web", "selftest.html"), "utf8");
  // 自检页每条断言都以行首的 row(" 声明；页脚显示的"判据总数"就是它的个数
  return (src.match(/^row\(/gm) ?? []).length;
}

/**
 * 编辑器页自检的条数。
 * ★ 直接 import 清单本身，**不数源码里的行**：`grep -c '^  "'` 这类计数器一旦数错，
 *   `--fix` 会把文档"修"成错误的值并报绿 —— 会改文档的假绿灯比漂移更贵。
 *   清单在 `editor-declared.mjs` 里，零副作用，import 它不会起浏览器。
 */
function actualEditor() {
  return EDITOR_DECLARED.length;
}

/**
 * JPEG 外部金标语料总例数（去重口径：三份清单里同名案例只算一次）。
 * ★ 为什么要去重：`_selfenc.json` 的 16 个案例名与主清单**完全重合**（它们是同一批文件，
 *   只是"谁来解"不同）。直接相加会把 54 说成 70 —— 这种"多重计数"是最难自查的一类漂移：
 *   每个清单都真的变长了，只有总口径错。
 */
function actualJpegGold() {
  const dir = join(ROOT, "tests", "fixtures", "jpeg");
  const read = (p) => JSON.parse(readFileSync(join(dir, p), "utf8"));
  const main = read("manifest.json");
  const ff = read("ff/_ffgold.json");
  const names = new Set();
  for (const c of [...main.cases, ...main.wide, ...ff.cases]) names.add(c.name);
  return names.size;
}

/** src 的规模：文件数 + 总行数（这是"项目有多大"最常被引用的两个数，也最容易漂）。 */
function actualSrc() {
  const walk = (p, out = []) => {
    for (const e of readdirSync(p, { withFileTypes: true })) {
      const q = join(p, e.name);
      if (e.isDirectory()) walk(q, out);
      else if (e.name.endsWith(".ts")) out.push(q);
    }
    return out;
  };
  const files = walk(join(ROOT, "src"));
  let lines = 0;
  for (const f of files) lines += readFileSync(f, "utf8").split("\n").length - 1;
  return { srcfiles: files.length, srclines: lines };
}

/**
 * 后端数量：`src/backends` 下的目录数。
 * ★ 为什么按目录数而不是按"注册了几次"：注册表里的数量取决于宿主注册了什么，
 *   而"我们有几个后端实现"是代码结构事实。文档里说的是后者。
 */
function actualBackends() {
  const dir = join(ROOT, "src", "backends");
  return readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).length;
}

/**
 * CI 步骤数：直接问 `tools/ci.mjs --list`。
 * ★ 不数 `STEPS.push` 的个数：那会把"被 --fast 跳过的步骤"算错。
 *   唯一的真值是脚本自己的清单。
 */
function actualCiSteps() {
  const r = spawnSync(process.execPath, ["tools/ci.mjs", "--list"], { cwd: ROOT, encoding: "utf8" });
  const m = /共 (\d+) 步/.exec(r.stdout ?? "");
  if (m === null) {
    console.error("✗ 读不到 CI 步骤数 —— `tools/ci.mjs --list` 的输出变了");
    process.exit(2);
  }
  return Number(m[1]);
}

const tests = actualTests();
const mutantIds = actualMutants();
const files = actualFiles();
const browser = actualBrowser();
const editor = actualEditor();
const jpegGold = actualJpegGold();
const src = actualSrc();
const backends = actualBackends();
const steps = actualCiSteps();
/**
 * 可以打的标记类型 —— **唯一来源**。
 * ★ 原先正则里手写了一遍类型名、`actual` 里又手写了一遍键名，两份清单各自漂：
 *   2026-10-23 加了 backends/steps 两个 md 函数却忘了把它们塞进 `actual`，
 *   正则认得这两个标记、值却是 undefined，而文档当时还没有标记 ⇒ 闸门报「全部一致」。
 *   「工具自己没接上却报绿」和「工具喊狼」一样是假信号，所以这里把清单收成一份并当场校验。
 */
const MARKER_KEYS = ["tests", "mutants", "files", "browser", "editor", "jpeggold", "srcfiles", "srclines", "backends", "steps"];

const actual = { tests, mutants: mutantIds.length, files, browser, editor, jpeggold: jpegGold, backends, steps, ...src };

const missingKeys = MARKER_KEYS.filter((k) => !(k in actual));
if (missingKeys.length > 0) {
  console.error(`✗ 标记类型没有对应的实测值：${missingKeys.join(", ")} —— 标记会读到 undefined，对账等于没做`);
  process.exit(2);
}

const DOCS = ["README.md", "docs/PROGRESS.md", "docs/ARCHITECTURE.md"];
const problems = [];
const fixed = [];
let checked = 0;
let markers = 0;

// 由 MARKER_KEYS 生成，不再手写 —— 见上面那段注释
const MARKER_RE = new RegExp(`<!--\\s*n:(${MARKER_KEYS.join("|")})\\s*-->`, "g");

// ★ 反向自检：写一个不存在的标记类型，必须一条都匹配不上。
//   否则上面那条 `missingKeys` 校验就成了摆设（正则永远不会命中未知类型）。
if (new RegExp(MARKER_RE.source).test("<!-- n:__nope__ -->")) {
  console.error("✗ 标记正则能匹配未知类型 —— 类型清单没有真的把住");
  process.exit(2);
}

for (const rel of DOCS) {
  const raw = readFileSync(join(ROOT, rel), "utf8");
  let lines = raw.split("\n");
  let dirty = false;
  lines = lines.map((line, i) => {
    let out = line;
    // 从后往前改：替换会改变下标，而标记位置是先算出来的
    const hits = [...line.matchAll(MARKER_RE)];
    for (let k = hits.length - 1; k >= 0; k--) {
      const m = hits[k];
      markers++;
      const key = m[1];
      const before = out.slice(0, m.index);
      // 同一行里标记之前**最后一个**数字就是这个声明的值
      const nums = [...before.matchAll(/(\d+)/g)];
      const last = nums[nums.length - 1];
      if (last === undefined) {
        problems.push(`${rel}:${i + 1} 标了 n:${key} 但前面没有数字 —— ${line.trim().slice(0, 60)}`);
        continue;
      }
      checked++;
      if (Number(last[1]) !== actual[key]) {
        if (FIX) {
          const at = last.index;
          out = out.slice(0, at) + String(actual[key]) + out.slice(at + last[1].length);
          dirty = true;
          fixed.push(`${rel}:${i + 1} n:${key} ${last[1]} → ${actual[key]}`);
        } else {
          problems.push(`${rel}:${i + 1} n:${key} 声明 ${last[1]}，实际 ${actual[key]} —— ${line.trim().slice(0, 70)}`);
        }
      }
    }
    return out;
  });
  if (dirty) writeFileSync(join(ROOT, rel), lines.join("\n"));
}

// ★ 数字里带千分位逗号（17,638）时，逐位比对会读到 "638"。宁可让作者改掉逗号，
//   也不让一个静默的截断规则把 "17,638 → 638" 这种漂移放过去。
for (const rel of DOCS) {
  const lines = readFileSync(join(ROOT, rel), "utf8").split("\n");
  lines.forEach((line, i) => {
    const at = line.indexOf("<!--");
    if (at < 0 || !/<!--\s*n:/.test(line)) return;
    if (/\d,\d/.test(line.slice(0, at))) {
      problems.push(`${rel}:${i + 1} 标记前的数字带千分位逗号 —— 对账读不了逗号，请写成纯数字`);
    }
  });
}

// 变异编号必须连续：缺号说明删过条目而"总数"口径没跟着改
const nums = mutantIds.map((s) => Number(s.slice(1))).sort((a, b) => a - b);
for (let k = 1; k <= nums.length; k++) {
  if (nums[k - 1] !== k) {
    problems.push(`变异编号不连续：第 ${k} 条是 M${nums[k - 1]} —— 删条目时报告里的总数要一起改`);
    break;
  }
}

/**
 * ★ 「下表与 `ci.mjs --list` 逐行对应」这句话本身要有人守。
 *
 *   2026-10-25 实测：ARCHITECTURE 的闸门表写着 **10 行**，而 `--list` 说是 **14 步** ——
 *   漏了物理性能闸门、编辑器页自检、跨宿主存档比对、JPEG 三分自检整整 4 项。
 *   而 `n:steps` 那个数字刚好对得上（14 == 14），所以对账一路绿。
 *   **数字对 ≠ 表对**：可以一边把标题里的数改对、一边留着过期的表格。
 *   识别这类"写在墙上的判据"只能靠机器数行数。
 */
{
  const lines = readFileSync(join(ROOT, "docs", "ARCHITECTURE.md"), "utf8").split("\n");
  const anchor = lines.findIndex((l) => l.includes("与 `node tools/ci.mjs --list` 逐行对应"));
  if (anchor < 0) {
    problems.push("ARCHITECTURE.md 找不到「与 ci.mjs --list 逐行对应」这句锚点 —— 闸门表被删了？");
  } else {
    const rows = [];
    for (let i = anchor + 1; i < lines.length; i++) {
      const m = /^\|\s*(\d+)\s*\|/.exec(lines[i]);
      if (m !== null) rows.push(Number(m[1]));
      else if (rows.length > 0) break;
    }
    if (rows.length !== steps) {
      problems.push(
        `ARCHITECTURE.md 的闸门表 ${rows.length} 行，而 ci.mjs --list 是 ${steps} 步 —— 「逐行对应」不成立了`,
      );
    } else {
      const wrong = rows.findIndex((n, i) => n !== i + 1);
      if (wrong >= 0) {
        problems.push(`闸门表编号不连续：第 ${wrong + 1} 行写的是 ${rows[wrong]}`);
      }
    }
  }
}

// 缺口清单对账的结果并入 problems（判据本身在文件开头那段：它必须先于「数判据」跑，
// 否则 `--gap-only` 也要等缓存/全量测试 —— 见那段注释）。
for (const it of gapIssues) {
  if (it.kind === "uncited") {
    problems.push(
      `PROGRESS.md:${it.no} 缺口里的「仍缺」没挂阻断编号` +
        " —— 挂上（C9）这类编号，下一轮清查才会被迫回来核对；写完的就把「仍缺」划掉并标 ✅",
    );
  } else if (it.kind === "stale") {
    problems.push(
      `PROGRESS.md:${it.no} 「仍缺」引用的 ${it.ids.join(", ")} 在阻塞清单里已经是 ✅` +
        " —— 这条缺口早就消除了，句子过期了（C12 就是照抄过期句写出来的）",
    );
  } else if (it.kind === "forgot-close") {
    problems.push(
      `PROGRESS.md:${it.no} 「${it.head}」这一行自称做完了，首格却没划掉` +
        " —— 要么把首格划掉并写清哪一批交付的，要么在行里写明还差什么（仍缺 / 待补）：缺口表要能回答「还剩几件」",
    );
  } else {
    problems.push(
      `PROGRESS.md:${it.no} 缺口行点名了已在 CI 里跑的工具（${it.hits.join(", ")}）` +
        " —— 若这条缺口已被它补上，把首格标 ✅ 并写清哪一批补的；若没补上，写清还差什么（工具在跑 ≠ 这件事做完了）",
    );
  }
}

// 阻塞项对账的结果并入 problems（同一条理由：它在文件开头跑，才能被 `--blockers-only` 单跑）。
for (const it of blockerIssues) {
  problems.push(`${blockersFile}:${it.no} ${it.id} ${it.code}：${it.detail}`);
}

console.log(
  `实际：判据 ${tests} · 变异 ${mutantIds.length} 组（M1..M${nums[nums.length - 1] ?? 0}）· 测试文件 ${files} · 浏览器自检 ${browser} · 编辑器自检 ${editor} · JPEG 金标 ${jpegGold} 例 · 后端 ${actual.backends} · CI ${actual.steps} 步`,
);
console.log(`标记：${markers} 处，核对 ${checked} 处`);
if (markers === 0) {
  console.log("· 没有找到任何 n: 标记 —— 说明文档里没有声明当前值，或标记被删了（不是错，但等于没对账）");
}
if (problems.length === 0) {
  if (fixed.length > 0) {
    console.log(`· 已修正 ${fixed.length} 处：`);
    for (const f of fixed) console.log(`  ${f}`);
  }
  console.log("✓ 文档数字与实际一致");
  process.exit(0);
}
console.error(`\n✗ 文档数字漂移 ${problems.length} 处：`);
for (const p of problems) console.error(`  · ${p}`);
process.exit(1);
