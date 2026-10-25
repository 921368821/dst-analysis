/**
 * 平台打包 CLI（微信小游戏 / Steam）
 *
 * 用法：
 *   node --experimental-transform-types tools/pack.ts --platform wechat --staging <dir> --out <dir> \
 *        [--config <json>] [--check] [--strict-api]
 *   node --experimental-transform-types tools/pack.ts --platform steam  --staging <dir> --out <dir> \
 *        --config <json> [--check]
 *
 * ★ 这一层只做 IO：读目录、写文件、报大小。所有**判断**（预算 / 归属 / 后缀 / VDF 形状）
 *   都在 `src/publish/pack-plan.ts` 里 —— 那里的逻辑能被 Node 判据逐条钉住，
 *   而"CLI 里顺手写的 if"只能靠人看。
 *
 * ★ 退出码三分（与浏览器判据同一口径）：
 *   0 = 通过；1 = 真的有打包问题（超预算 / 文件没归属 / 配置错）；2 = 用法或环境错误。
 *   混进 0 是假绿灯（打包坏了 CI 还是绿），混进 1 是假红（人跑去查不存在的 bug）。
 *
 * ★ 只写"内容不同"的文件：重复打包不该产生新的 mtime —— 与 `build.ts` 同一条纪律，
 *   否则每次打包都会在产物目录里留下几百个"改了但内容一样"的文件。
 */

import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

import {
  WECHAT_LIMITS,
  checkVdf,
  planWechat,
  renderAppBuildVdf,
  renderDepotBuildVdf,
  renderGameJson,
  scanMiniGameSource,
  type StagedFile,
  type WechatPackConfig,
} from "../src/publish/pack-plan.ts";
import type { EngineError } from "../src/foundation/result.ts";

const EXIT_PASS = 0;
const EXIT_FAIL = 1;
const EXIT_USAGE = 2;

interface Staged extends StagedFile {
  readonly abs: string;
}

function usage(msg: string): never {
  console.error(`✗ ${msg}`);
  console.error("  用法：--platform wechat|steam --staging <dir> --out <dir> [--config <json>] [--check] [--strict-api]");
  process.exit(EXIT_USAGE);
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(`--${name}`);
  if (i < 0) return undefined;
  const v = process.argv[i + 1];
  if (v === undefined || v.startsWith("--")) usage(`--${name} 缺少值`);
  return v;
}

function fmt(n: number): string {
  if (n < 1024) return `${String(n)}B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)}KB`;
  return `${(n / (1024 * 1024)).toFixed(2)}MB`;
}

const platform = arg("platform");
const staging = arg("staging");
const out = arg("out");
const configPath = arg("config");
const checkOnly = process.argv.includes("--check");
const strictApi = process.argv.includes("--strict-api");

if (platform !== "wechat" && platform !== "steam") usage("--platform 必须是 wechat 或 steam");
if (staging === undefined) usage("缺少 --staging <dir>");
if (out === undefined) usage("缺少 --out <dir>");
const stagingAbs = resolve(staging);
const outAbs = resolve(out);

let stagingOk = false;
try {
  stagingOk = statSync(stagingAbs).isDirectory();
} catch {
  stagingOk = false;
}
if (!stagingOk) usage(`${staging} 不是可读目录`);

/** 递归列出 staging 下的文件（路径分隔统一成 `/`，按字典序 —— 确定性）。 */
function walk(dir: string, base: string): Staged[] {
  const acc: Staged[] = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) acc.push(...walk(p, base));
    else if (ent.isFile()) {
      const rel = p.slice(base.length + 1).split("\\").join("/");
      acc.push({ path: rel, bytes: statSync(p).size, abs: p });
    }
  }
  return acc;
}

const files = walk(stagingAbs, stagingAbs).sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
const total = files.reduce((n, f) => n + f.bytes, 0);
console.log(`平台 ${platform} · staging ${String(files.length)} 个文件 · ${fmt(total)}`);

// ★ 空 staging 在**两个平台**都直接拒绝：一个空包上传成功比打包失败更难发现
//   （Steam 上会推一个空 depot，微信上会传一个打不开的包）。
if (files.length === 0) {
  console.error(`✗ PACK.EMPTY：${staging} 下没有任何文件 —— 不打包空目录`);
  process.exit(EXIT_FAIL);
}

function loadConfig(): Record<string, unknown> | null {
  if (configPath === undefined) return null;
  try {
    const raw: unknown = JSON.parse(readFileSync(configPath, "utf8"));
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) usage("配置文件必须是一个 JSON 对象");
    return raw as Record<string, unknown>;
  } catch (e) {
    usage(`读不了配置 ${configPath}：${e instanceof Error ? e.message : String(e)}`);
  }
}

let wrote = 0;
let same = 0;
function writeIfChanged(path: string, buf: Buffer): void {
  mkdirSync(dirname(path), { recursive: true });
  try {
    if (readFileSync(path).equals(buf)) {
      same++;
      return;
    }
  } catch {
    /* 不存在：往下走 */
  }
  writeFileSync(path, buf);
  wrote++;
}

function report(errors: readonly EngineError[]): void {
  for (const e of errors) console.error(`✗ ${e.code}：${e.message}`);
}

// ---------------------------------------------------------------- 微信小游戏

if (platform === "wechat") {
  const rawCfg = loadConfig();
  const cfg: WechatPackConfig =
    rawCfg === null
      ? { main: ["*.js", "*.json"], subpackages: [] }
      : (rawCfg as unknown as WechatPackConfig);
  const planR = planWechat(files, cfg);
  if (!planR.ok) {
    report(planR.error);
    console.error(`\n✗ 分包规划失败（${String(planR.error.length)} 个问题）—— 没有写出任何东西`);
    process.exit(EXIT_FAIL);
  }
  const plan = planR.value;
  console.log(
    `主包 ${fmt(plan.main.bytes)} / 上限 ${fmt(WECHAT_LIMITS.mainPackage)} · ` +
      `分包 ${String(plan.subpackages.length)} 个 · 合计 ${fmt(plan.totalBytes)} / 上限 ${fmt(WECHAT_LIMITS.total)}`,
  );
  for (const p of plan.subpackages) {
    console.log(`  · ${p.name} → ${String(p.root)} · ${String(p.files.length)} 个文件 · ${fmt(p.bytes)}`);
  }

  // ---- 小游戏里不存在的浏览器 API（诊断，不假装能修）
  const hits: { file: string; api: string; line: number }[] = [];
  for (const f of files) {
    if (!f.path.endsWith(".js")) continue;
    const src = readFileSync(f.abs, "utf8");
    for (const h of scanMiniGameSource(src)) hits.push({ file: f.path, api: h.api, line: h.line });
  }
  if (hits.length > 0) {
    const byApi = new Map<string, number>();
    for (const h of hits) byApi.set(h.api, (byApi.get(h.api) ?? 0) + 1);
    const list = [...byApi.entries()].map(([a, n]) => `${a}×${String(n)}`).join("、");
    console.log(`\n⚠ 小游戏环境里没有的 API：${String(hits.length)} 处（${list}）`);
    console.log(`  首个命中：${hits[0]!.file}:${String(hits[0]!.line)}（${hits[0]!.api}）`);
    if (strictApi) {
      console.error("✗ --strict-api：存在小游戏不可用的浏览器 API，需要 host-wx 适配层");
      process.exit(EXIT_FAIL);
    }
  }

  if (checkOnly) {
    console.log("✓ 分包规划通过（--check 未写文件）");
    process.exit(EXIT_PASS);
  }

  // ★ 输出布局 = staging 布局（逐字节原样拷贝，只额外写一个 game.json）。
  //   分包的文件路径已经由 `planWechat` 验过位于各自 root 之下，所以这里不需要
  //   「按包名重排目录」—— 重排过一次就会与 game.json 的 root 脱钩。
  for (const pkg of [plan.main, ...plan.subpackages]) {
    for (const f of pkg.files) {
      const src = files.find((x) => x.path === f.path);
      if (src === undefined) continue;
      writeIfChanged(join(outAbs, f.path), readFileSync(src.abs));
    }
  }
  writeIfChanged(join(outAbs, "game.json"), Buffer.from(renderGameJson(plan, cfg), "utf8"));
  console.log(`\n✓ 已写出 ${outAbs}（新建/更新 ${String(wrote)} 个文件，${String(same)} 个未变）`);
  process.exit(EXIT_PASS);
}

// ---------------------------------------------------------------- Steam

const cfg = loadConfig();
if (cfg === null) usage("Steam 打包必须给 --config（appId / depots / buildOutput，可选 setLive）");
const appId = Number(cfg["appId"]);
if (!Number.isInteger(appId) || appId <= 0) usage("配置里的 appId 必须是正整数");
const depotsRaw = cfg["depots"];
if (!Array.isArray(depotsRaw) || depotsRaw.length === 0) usage("配置里的 depots 必须是非空数组");

const buildOutput = String(cfg["buildOutput"] ?? join(outAbs, "steam_output"));
const contentRoot = outAbs;
const depotFiles: { depotId: number; file: string }[] = [];
const texts: [string, string][] = [];
for (const d of depotsRaw) {
  const depotId = Number((d as { depotId?: unknown }).depotId);
  if (!Number.isInteger(depotId) || depotId <= 0) usage("depotId 必须是正整数");
  const file = `depot_build_${String(depotId)}.vdf`;
  depotFiles.push({ depotId, file });
  texts.push([file, renderDepotBuildVdf({ depotId, contentRoot })]);
}
const appFile = `app_build_${String(appId)}.vdf`;
texts.push([
  appFile,
  renderAppBuildVdf({
    appId,
    desc: String(cfg["desc"] ?? ""),
    buildOutput,
    contentRoot,
    depots: depotFiles,
    ...(cfg["setLive"] === undefined ? {} : { setLive: String(cfg["setLive"]) }),
    ...(cfg["preview"] === undefined ? {} : { preview: Number(cfg["preview"]) }),
  }),
]);

let bad = 0;
for (const [name, text] of texts) {
  const p = checkVdf(text);
  if (p !== null) {
    console.error(`✗ ${name} 的 VDF 结构有问题：${p}`);
    bad++;
  }
}
if (bad > 0) process.exit(EXIT_FAIL);

console.log(`Steam 内容 ${String(files.length)} 个文件 · ${fmt(total)} · depot ${String(depotsRaw.length)} 个`);
if (cfg["setLive"] !== undefined) {
  // ★ 这条提示必须打出来：SetLive 只对 beta 分支自动生效，default 要人工点发布。
  //   忘掉这一步的现象是「上传成功了，但玩家那边没更新」，而日志一切正常。
  console.log(`  注意：setlive=${String(cfg["setLive"])} —— 只有 beta 分支会自动生效，default 必须人工发布`);
}

if (checkOnly) {
  console.log("✓ VDF 生成与结构自检通过（--check 未写文件）");
  process.exit(EXIT_PASS);
}
for (const [name, text] of texts) writeIfChanged(join(outAbs, name), Buffer.from(text, "utf8"));
console.log(`✓ 已写出 ${String(texts.length)} 个 VDF（新建/更新 ${String(wrote)} 个，${String(same)} 个未变）`);
console.log(`  下一步：steamcmd +login <账号> +run_app_build ${join(outAbs, appFile)}`);
process.exit(EXIT_PASS);
