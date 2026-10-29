/**
 * 小游戏包检查：**构建 + 打包 + 三条结构断言**，接进 CI。
 *
 * ★ 为什么需要这个文件（2026-10-29 批129 清查时发现的悬空项）：
 *
 *   批128 交付了 `tools/build-wx.mjs`（esbuild IIFE）与 `src/wx-entry.ts`，
 *   并"实测"过 `build:wx` → `pack --platform wechat --strict-api` 退出码 0。
 *   但那是一次**手工结论**：14 步 CI 里没有任何一步会去构建小游戏包。
 *   后果是双重的：
 *
 *   ① `platform: "neutral"` 这个设置的全部价值是「node 内置依赖在**构建期**就爆」，
 *      而构建期只在有人手跑时发生 —— 于是它保护的是一条没人走的路；
 *   ② 产物本身没有任何断言。「构建出了个空壳」「被打成了 ESM」「混进了 `require("node:fs")`」
 *      这三件事，只要不跑真机、不跑构建，就全都看不出来，而它们**每一个都只在真机上炸**。
 *
 * ★ 判据与实现分开：`checkWxBundle` 是纯函数（输入源码字节，输出问题列表），
 *   所以判据可以用**合成语料**逐条打每条规则（`tests/host/wx-bundle.test.ts`）。
 *   只跑真实产物的检查会退化成"产物还在就绿"—— 那正是本仓库反复踩的 `假绿`。
 */

import { spawnSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

/**
 * 产物体积下限。
 *
 * 实测一整局（含 Lua 运行时垫片、UI、导航网格）是 869.9KB。取 200KB 是"少了四分之三就报"：
 * 松到能容忍正常增减，紧到"构建成了空壳/只打进一个入口壳"必红。
 * 上限不在这里判 —— `pack.ts` 已经按 4MB 三重预算算过并退出非 0，重复一遍只会让
 * 两处数字有机会漂移。
 */
export const MIN_BUNDLE_BYTES = 200_000;

/** ESM 语法：真机上没有模块加载器，`game.js` 是被**直接执行**的普通脚本。 */
const ESM_EXPORT = /\bexport\s*(?:\{|default\b|const\b|let\b|var\b|function\b|class\b|async\b|\*)/;

/**
 * `import.meta` 是 ESM 专属语法，IIFE 产物里没有意义。
 *
 * ★ 为什么**不**扫 `import(`：第一版写了 `\bimport\s*\(`，产物里当场命中 4 处，全是
 *   本仓库自己的导入管线接口 —— `u.importer.import(u.path, …)` 与
 *   `async import(sourcePath, source) { … }`。名字叫 `import` 的方法与 ESM 动态导入
 *   在**字节层没有区别**（两者都是 `import(` 后面跟参数），分不清就会假红；
 *   而假红比漏报贵：被误报吓过两次的人会把整条闸门关掉。
 *   真出现 ESM 动态导入时，产物必然同时带上 `export` 或 `import.meta`（esbuild
 *   保留 ESM 形态时两者至少有一个），所以这两条合起来足够，且都能分辨。
 */
const ESM_META = /\bimport\.meta\b/;

/** node 内置模块依赖：`require("node:fs")` 或 `from "node:fs"`。 */
const NODE_BUILTIN = /(?:\brequire\s*\(\s*|\bfrom\s*)["']node:[a-z/]+["']/;

/**
 * 检查小游戏产物。
 *
 * @param {string} source 产物的 UTF-8 文本（`game.js` 的内容）
 * @returns {string[]} 问题列表；**空数组 = 通过**
 */
export function checkWxBundle(source) {
  const issues = [];
  const bytes = Buffer.byteLength(source, "utf8");

  // ① 不能是空壳。字节数从 source 现算（不另传一个 length 参数）：两个入参描述同一件事，
  //    某个调用点传错一个就会得到"文本很长、字节很少"这种自相矛盾的判定。
  if (bytes < MIN_BUNDLE_BYTES) {
    issues.push(
      `产物只有 ${String(bytes)} 字节（下限 ${String(MIN_BUNDLE_BYTES)}）—— 不像一整局游戏，更像只打进了入口壳`,
    );
  }

  // ② 必须是 IIFE，不能是 ESM。真机上 `Unexpected token 'export'` 只在运行时出现，
  //    而那时人手里只有一张白屏截图。
  if (ESM_EXPORT.test(source)) {
    issues.push("产物里有 ESM `export` —— 小游戏直接执行 game.js，没有模块加载器（真机报 Unexpected token 'export'）");
  }
  if (ESM_META.test(source)) {
    issues.push("产物里有 `import.meta` —— ESM 专属语法，IIFE 产物里不该出现");
  }

  // ③ 不能依赖 node 内置（`platform: "neutral"` 就是为了让它在构建期炸，
  //    这里在产物侧再钉一次：构建参数被人改回 `node` 时，前一条不会报）。
  if (NODE_BUILTIN.test(source)) {
    issues.push("产物里 require/import 了 node 内置模块 —— 真机上没有这些模块");
  }

  // ④ IIFE 的全局名。这是"包装确实发生了"的结构证据：`format: "iife"` + `globalName`
  //    两者都在才有它；任一被改掉，打包形状就变了 —— 而那时 ② 可能仍然绿
  //    （一个顶层没有 export 的 IIFE 与一个没包起来的脚本，在"有没有 export"上一样）。
  if (!source.includes("EngineWx")) {
    issues.push("产物里没有 `EngineWx` —— IIFE 的 globalName 没生效，打包形状与预期不符");
  }

  return issues;
}

/** `--out` 之类的取值参数（与 `build-wx.mjs` 同口径）。 */
function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return fallback;
  const v = process.argv[i + 1];
  return v === undefined || v.startsWith("--") ? fallback : v;
}

/** 跑一条子命令，返回 { status, out }。失败时把尾巴一起带出来（不然人只看到一行 exit code）。 */
function run(cmd, args, label) {
  const r = spawnSync(cmd, args, { encoding: "utf8", env: process.env });
  const out = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  if (r.status !== 0) {
    console.error(`✗ ${label} 失败（exit=${String(r.status)}）：`);
    console.error(out.trim().split("\n").slice(-12).join("\n"));
    process.exit(1);
  }
  return out;
}

const workDir = resolve(arg("work", ".cache/wx"));
const aDir = join(workDir, "a");
const bDir = join(workDir, "b");
const packDir = join(workDir, "packed");

const node = process.execPath;
const buildArgs = ["tools/build-wx.mjs", "--out"];

// ---- 1. 构建两次：确定性
// ★ 两次而不是一次：产物要能"同一份源码 ⇒ 同一份字节"（内容寻址、产物比对、
//   "改了什么"的 diff 全都建立在这上面）。esbuild 真出过非确定性输出，
//   而那种症状是"每次构建都有一点点不同" —— 没人会去查，因为它不报错。
run(node, [...buildArgs, aDir], "第一次构建");
run(node, [...buildArgs, bDir], "第二次构建");
const a = readFileSync(join(aDir, "game.js"));
const b = readFileSync(join(bDir, "game.js"));
if (!a.equals(b)) {
  console.error(`✗ 两次构建的产物不同（${String(a.length)} vs ${String(b.length)} 字节）—— 产物不可复现`);
  process.exit(1);
}

// ---- 2. 结构断言
const source = a.toString("utf8");
const issues = checkWxBundle(source);
if (issues.length > 0) {
  console.error(`✗ 小游戏包断言：${String(issues.length)} 条不通过`);
  for (const it of issues) console.error(`  · ${it}`);
  process.exit(1);
}

// ---- 3. 打包 + 禁用 API 扫描
const packOut = run(
  node,
  [
    "--experimental-transform-types",
    "tools/pack.ts",
    "--platform",
    "wechat",
    "--staging",
    aDir,
    "--out",
    packDir,
    "--strict-api",
  ],
  "微信打包 --strict-api",
);

// ★ 不能只看退出码：`--strict-api` 干净时也会打印 `✓ 小游戏禁用 API：0 处（扫了 N 个 .js / …）`，
//   而**「扫了 0 个文件」与「一个都没命中」都满足退出码 0**。批128 刚为这件事补过输出，
//   这里顺手把"真的扫过东西"变成判据的一部分。
const scanLine = packOut.split("\n").find((l) => l.includes("小游戏禁用 API：0 处"));
if (scanLine === undefined) {
  console.error("✗ 打包输出里没有「小游戏禁用 API：0 处」—— 要么扫描没跑，要么命中了");
  console.error(packOut.trim().split("\n").slice(-10).join("\n"));
  process.exit(1);
}

const sizeKb = (statSync(join(aDir, "game.js")).size / 1024).toFixed(1);
console.log(`✓ 小游戏包 ${sizeKb}KB：IIFE · 零 ESM · 零 node 内置依赖`);
console.log("✓ 两次构建逐字节相同（产物可复现）");
console.log(scanLine.trim());
