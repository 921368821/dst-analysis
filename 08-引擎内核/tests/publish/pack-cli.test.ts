/**
 * L5 · 发布：打包 CLI 的「落盘层」判据
 *
 * `pack-plan.test.ts` 验的是纯函数的判断；这里验**写到磁盘之后**还对不对，
 * 以及**退出码**对不对。两者必须分开，理由是上一批（构建 CLI）的同一条经验：
 * 「纯函数全绿」与「跑起来真的对」是两件事 —— 中间隔着路径拼接、目录创建、
 * 覆盖写、以及一个 `process.exit(0)` 写错了的 if。
 *
 * 四条出口在这里重验一遍：
 *   ① 输出布局 = staging 布局（分包文件不重排目录，否则与 game.json 的 root 脱钩）；
 *   ② 重复打包**不产生新的 mtime**（内容没变就不写了 —— 用「先把 mtime 人为调到
 *      2000 年，再打包，看它是否还是 2000 年」来验，比 sleep 之后比时间戳强，
 *      不受文件系统时间精度影响）；
 *   ③ 退出码三分：0 通过 / 1 真有打包问题 / 2 用法与环境错误 —— 混进 0 是假绿；
 *   ④ CLI 写出的 game.json / VDF 与纯函数**逐字节相同**（两个出口不许各说各话）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  planWechat,
  renderAppBuildVdf,
  renderDepotBuildVdf,
  renderGameJson,
  type StagedFile,
  type WechatPackConfig,
} from "../../src/publish/pack-plan.ts";

const ROOT = fileURLToPath(new URL("../..", import.meta.url));

interface CliResult {
  readonly status: number;
  readonly stdout: string;
  readonly stderr: string;
}

function cli(args: readonly string[], env?: NodeJS.ProcessEnv): CliResult {
  const r = spawnSync(process.execPath, ["--experimental-transform-types", "tools/pack.ts", ...args], {
    cwd: ROOT,
    encoding: "utf8",
    ...(env === undefined ? {} : { env }),
  });
  return { status: r.status ?? -1, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
}

function tmp(tag: string): string {
  return mkdtempSync(join(tmpdir(), `wb-pack-${tag}-`));
}

function put(dir: string, files: Record<string, string | Buffer>): void {
  for (const [name, text] of Object.entries(files)) {
    const p = join(dir, name);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, text);
  }
}

/** staging 里相对路径 → 字节数（与 CLI 的 walk 同口径，用于和纯函数对账）。 */
function stagedOf(dir: string, base = dir, acc: StagedFile[] = []): StagedFile[] {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) stagedOf(p, base, acc);
    else if (e.isFile()) {
      acc.push({ path: relative(base, p).split("\\").join("/"), bytes: statSync(p).size });
    }
  }
  return acc.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
}

function listFiles(dir: string, base = dir, acc: string[] = []): string[] {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) listFiles(p, base, acc);
    else acc.push(relative(base, p).split("\\").join("/"));
  }
  return acc.sort();
}

const WECHAT_CFG = join(ROOT, "examples", "pack", "wechat.config.json");
const STEAM_CFG = join(ROOT, "examples", "pack", "steam.config.json");

/** 一份「host-wx 应该产出」的 staging：主包文件 + 两个分包目录。 */
const SAMPLE: Record<string, string> = {
  "game.js": "const a = 1;\n",
  "glue.wasm": "\0asm",
  "assets/logo.png": "PNG",
  "subpackage/terrain/t1.png": "T1",
  "subpackage/terrain/t2.png": "T2",
  "subpackage/audio/bgm.ogg": "OGG",
};

function sampleStaging(tag: string): string {
  const d = tmp(tag);
  put(d, SAMPLE);
  return d;
}

// ---------------------------------------------------------------- 微信：落盘

test("[打包CLI] 真跑一次：输出布局 = staging 布局，只额外多一个 game.json", () => {
  const staging = sampleStaging("real");
  const out = tmp("real-out");
  try {
    const res = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG]);
    assert.equal(res.status, 0, `${res.stdout}\n${res.stderr}`);
    assert.deepEqual(listFiles(out), [...Object.keys(SAMPLE), "game.json"].sort());
    for (const [name, text] of Object.entries(SAMPLE)) {
      assert.equal(readFileSync(join(out, name), "utf8"), text, `${name} 不是逐字节拷贝`);
    }
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] ★ 写出的 game.json 与纯函数逐字节相同（两个出口不许各说各话）", () => {
  const staging = sampleStaging("gj");
  const out = tmp("gj-out");
  try {
    const cfg = JSON.parse(readFileSync(WECHAT_CFG, "utf8")) as WechatPackConfig;
    const plan = planWechat(stagedOf(staging), cfg);
    assert.equal(plan.ok, true, plan.ok ? "" : plan.error.map((e) => e.code).join(","));
    const expected = plan.ok ? renderGameJson(plan.value, cfg) : "";
    // 反面对照：先确认这份期望值不是空串/恒等值，否则下面的 equal 无从证明
    assert.ok(expected.includes("subpackage/terrain"), "期望的 game.json 里应该有分包 root");

    const res = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG]);
    assert.equal(res.status, 0, res.stderr);
    assert.equal(readFileSync(join(out, "game.json"), "utf8"), expected);
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] --check：只判断不写盘（输出目录连创建都不该创建）", () => {
  const staging = sampleStaging("chk");
  const base = tmp("chk-out");
  const out = join(base, "never", "created");
  try {
    const res = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG, "--check"]);
    assert.equal(res.status, 0, res.stderr);
    assert.equal(existsSync(out), false, "--check 写出了文件");
    assert.match(res.stdout, /--check/);
  } finally {
    for (const d of [staging, base]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] ★ 重复打包不产生新的 mtime（内容没变就不写）", () => {
  const staging = sampleStaging("mt");
  const out = tmp("mt-out");
  const OLD = new Date("2000-01-01T00:00:00Z");
  try {
    assert.equal(cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG]).status, 0);
    const first = listFiles(out);
    assert.ok(first.length >= 6, `输出只有 ${String(first.length)} 个文件，这条判据验不动`);
    // 人为把 mtime 调到 2000 年：如果第二次打包重写了它，mtime 一定会变成「现在」
    for (const f of first) utimesSync(join(out, f), OLD, OLD);

    const second = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG]);
    assert.equal(second.status, 0, second.stderr);
    for (const f of first) {
      assert.equal(statSync(join(out, f)).mtime.getUTCFullYear(), 2000, `${f} 被无谓重写了（mtime 变了）`);
    }

    // 反面对照：真的改了内容就必须写（否则上面那条可以用「永不写盘」作弊通过）
    put(staging, { "subpackage/terrain/t1.png": "T1-CHANGED" });
    assert.equal(cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG]).status, 0);
    assert.equal(readFileSync(join(out, "subpackage/terrain/t1.png"), "utf8"), "T1-CHANGED");
    assert.notEqual(statSync(join(out, "subpackage/terrain/t1.png")).mtime.getUTCFullYear(), 2000, "改动没有落盘");
    // 没改的文件仍保持旧 mtime（只重写变了的那个）
    assert.equal(statSync(join(out, "game.js")).mtime.getUTCFullYear(), 2000, "牵一发动全身：没变的文件也被重写了");
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] ★ 可复现：同一 staging 打到两个空目录，文件名与字节完全相同", () => {
  const staging = sampleStaging("rep");
  const o1 = tmp("rep1");
  const o2 = tmp("rep2");
  try {
    assert.equal(cli(["--platform", "wechat", "--staging", staging, "--out", o1, "--config", WECHAT_CFG]).status, 0);
    assert.equal(cli(["--platform", "wechat", "--staging", staging, "--out", o2, "--config", WECHAT_CFG]).status, 0);
    const f1 = listFiles(o1);
    assert.deepEqual(f1, listFiles(o2));
    for (const f of f1) assert.deepEqual(readFileSync(join(o1, f)), readFileSync(join(o2, f)), f);
  } finally {
    for (const d of [staging, o1, o2]) rmSync(d, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------- 退出码三分

test("[打包CLI] 退出码 1：有文件没有归属（不是用法错误，别让人去查参数）", () => {
  const staging = tmp("unm");
  const out = tmp("unm-out");
  try {
    put(staging, { ...SAMPLE, "notes.md": "x" });
    const res = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG]);
    assert.equal(res.status, 1, res.stdout);
    assert.match(res.stderr, /PACK\.UNMATCHED/);
    assert.equal(listFiles(out).length, 0, "规划失败时不许留下半成品");
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] 退出码 1：主包超 4MB（预算是最常见的一次真机失败）", () => {
  const staging = sampleStaging("over");
  const out = tmp("over-out");
  try {
    put(staging, { "huge.js": Buffer.alloc(4 * 1024 * 1024 + 1, 0x20) });
    const res = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG]);
    assert.equal(res.status, 1, res.stdout);
    assert.match(res.stderr, /PACK\.OVER_MAIN/);
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] 退出码 1：配置里的规则写法不认识（`assets/**` 之类）", () => {
  const staging = sampleStaging("badrule");
  const out = tmp("badrule-out");
  const cfg = join(tmp("badrule-cfg"), "c.json");
  try {
    writeFileSync(cfg, JSON.stringify({ main: ["assets/**"], subpackages: [] }));
    const res = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", cfg]);
    assert.equal(res.status, 1, res.stdout);
    assert.match(res.stderr, /PACK\.BAD_CONFIG/);
  } finally {
    for (const d of [staging, out, dirname(cfg)]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] 退出码 1：空 staging（两个平台都不打包空包）", () => {
  const staging = tmp("empty");
  const out = tmp("empty-out");
  try {
    const w = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG]);
    assert.equal(w.status, 1, w.stdout);
    assert.match(w.stderr, /PACK\.EMPTY/);
    const s = cli(["--platform", "steam", "--staging", staging, "--out", out, "--config", STEAM_CFG]);
    assert.equal(s.status, 1, s.stdout);
    assert.match(s.stderr, /PACK\.EMPTY/);
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] 退出码 2：用法与环境错误（与「打包坏了」分开）", () => {
  const staging = sampleStaging("usage");
  const out = tmp("usage-out");
  try {
    const cases: [string, string[]][] = [
      ["缺 --platform", ["--staging", staging, "--out", out]],
      ["--platform 不认识", ["--platform", "ps5", "--staging", staging, "--out", out]],
      ["缺 --staging", ["--platform", "wechat", "--out", out]],
      ["缺 --out", ["--platform", "wechat", "--staging", staging]],
      ["staging 不存在", ["--platform", "wechat", "--staging", join(staging, "nope"), "--out", out]],
      ["平台名后面没值", ["--platform", "--staging", staging, "--out", out]],
    ];
    for (const [why, args] of cases) {
      const r = cli(args);
      assert.equal(r.status, 2, `${why} 应该退出 2，实际 ${String(r.status)}：${r.stdout}${r.stderr}`);
    }
    // Steam 不给 --config 是用法错误（appId 无处可读）
    const noCfg = cli(["--platform", "steam", "--staging", staging, "--out", out]);
    assert.equal(noCfg.status, 2, noCfg.stdout);
    assert.match(noCfg.stderr, /--config/);
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] 退出码 2：配置文件不是 JSON 对象", () => {
  const staging = sampleStaging("badcfg");
  const out = tmp("badcfg-out");
  const dir = tmp("badcfg-dir");
  try {
    for (const text of ["{ 这不是 JSON", "[1,2,3]", "\"字符串\""]) {
      const cfg = join(dir, "c.json");
      writeFileSync(cfg, text);
      const r = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", cfg]);
      assert.equal(r.status, 2, `配置 ${text} 应该退出 2，实际 ${String(r.status)}`);
    }
  } finally {
    for (const d of [staging, out, dir]) rmSync(d, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------- 小游戏 API 诊断

test("[打包CLI] 浏览器专有 API：默认只告警（退出 0），--strict-api 才红", () => {
  const staging = tmp("api");
  const out = tmp("api-out");
  try {
    put(staging, { "game.js": "const c = document.createElement('canvas');\n", "a.json": "{}" });
    const lenient = cli(["--platform", "wechat", "--staging", staging, "--out", out]);
    assert.equal(lenient.status, 0, lenient.stderr);
    assert.match(lenient.stdout, /document\./);
    assert.match(lenient.stdout, /game\.js:1/, "要报出文件和行号（能直接跳过去改）");

    const strict = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG, "--strict-api"]);
    assert.equal(strict.status, 1, strict.stdout);
    assert.match(strict.stderr, /--strict-api/);
    // 报错要带错误码：CI 里能直接 grep，人也能对上文档
    assert.match(strict.stderr, /PACK\.FORBIDDEN_API/);
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] 干净的源码在 --strict-api 下也通过（判据不能恒红）", () => {
  const staging = tmp("apiok");
  const out = tmp("apiok-out");
  try {
    put(staging, { ...SAMPLE, "game.js": "const w = globalThis.wx;\n" });
    const r = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG, "--strict-api"]);
    assert.equal(r.status, 0, `${r.stdout}${r.stderr}`);
    assert.equal(r.stdout.includes("小游戏环境里没有的 API"), false);
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------- Steam

test("[打包CLI] Steam：写出 app_build 与每个 depot 的 VDF，内容与纯函数逐字节相同", () => {
  const staging = sampleStaging("steam");
  const out = tmp("steam-out");
  try {
    const cfg = JSON.parse(readFileSync(STEAM_CFG, "utf8")) as {
      appId: number;
      desc: string;
      buildOutput: string;
      preview: number;
      depots: { depotId: number }[];
    };
    const outAbs = resolve(out);
    const res = cli(["--platform", "steam", "--staging", staging, "--out", out, "--config", STEAM_CFG]);
    assert.equal(res.status, 0, `${res.stdout}${res.stderr}`);

    const names = listFiles(out);
    const appFile = `app_build_${String(cfg.appId)}.vdf`;
    assert.ok(names.includes(appFile), `没写 ${appFile}：${names.join(",")}`);
    for (const d of cfg.depots) assert.ok(names.includes(`depot_build_${String(d.depotId)}.vdf`));

    const expectedApp = renderAppBuildVdf({
      appId: cfg.appId,
      desc: cfg.desc,
      buildOutput: cfg.buildOutput,
      contentRoot: outAbs,
      preview: cfg.preview,
      depots: cfg.depots.map((d) => ({ depotId: d.depotId, file: `depot_build_${String(d.depotId)}.vdf` })),
    });
    assert.equal(readFileSync(join(out, appFile), "utf8"), expectedApp);
    for (const d of cfg.depots) {
      assert.equal(
        readFileSync(join(out, `depot_build_${String(d.depotId)}.vdf`), "utf8"),
        renderDepotBuildVdf({ depotId: d.depotId, contentRoot: outAbs }),
      );
    }
    // 示例配置里没有 setLive ⇒ 不许出现这个键（default 分支不自动发布）
    assert.equal(expectedApp.includes("setlive"), false);
    assert.match(res.stdout, /steamcmd/);
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] Steam --check：不写 VDF，但仍要打印结构自检结论", () => {
  const staging = sampleStaging("steamck");
  const base = tmp("steamck-out");
  const out = join(base, "nope");
  try {
    const res = cli(["--platform", "steam", "--staging", staging, "--out", out, "--config", STEAM_CFG, "--check"]);
    assert.equal(res.status, 0, `${res.stdout}${res.stderr}`);
    assert.equal(existsSync(out), false, "--check 写出了 VDF");
    assert.match(res.stdout, /VDF/);
  } finally {
    for (const d of [staging, base]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] Steam 配置缺 appId / depots → 退出码 2", () => {
  const staging = sampleStaging("steambad");
  const out = tmp("steambad-out");
  const dir = tmp("steambad-cfg");
  try {
    const cfg = join(dir, "c.json");
    for (const bad of [{ depots: [{ depotId: 1 }] }, { appId: 0, depots: [{ depotId: 1 }] }, { appId: 1, depots: [] }]) {
      writeFileSync(cfg, JSON.stringify(bad));
      const r = cli(["--platform", "steam", "--staging", staging, "--out", out, "--config", cfg]);
      assert.equal(r.status, 2, `${JSON.stringify(bad)} 应该退出 2，实际 ${String(r.status)}`);
    }
    // depotId 非法同理
    writeFileSync(cfg, JSON.stringify({ appId: 1, depots: [{ depotId: -3 }] }));
    assert.equal(cli(["--platform", "steam", "--staging", staging, "--out", out, "--config", cfg]).status, 2);
  } finally {
    for (const d of [staging, out, dir]) rmSync(d, { recursive: true, force: true });
  }
});

// ---------------------------------------------------------------- 上传（steamcmd）

/** 把 PATH 清空的环境：用来验「找不到 steamcmd」这条环境分支，不需要真的装它。 */
function envWithoutPath(): NodeJS.ProcessEnv {
  const e: NodeJS.ProcessEnv = { ...process.env };
  // Windows 上 PATH 的大小写不固定，两个都清掉才真的找不到
  e["PATH"] = "";
  e["Path"] = "";
  return e;
}

test("[打包CLI] --upload 只支持 Steam：微信上传要给 appid/私钥走开发者工具", () => {
  const staging = sampleStaging("upwx");
  const out = tmp("upwx-out");
  try {
    const r = cli(["--platform", "wechat", "--staging", staging, "--out", out, "--config", WECHAT_CFG, "--upload"]);
    // 退出 2（用法/环境），不是 1：这不是"包打坏了"
    assert.equal(r.status, 2, `${r.stdout}${r.stderr}`);
    assert.match(r.stderr, /开发者工具/, "要说清微信上传该走哪条路，而不是只说「不支持」");
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] --check 与 --upload 不许同时给（说好只检查，顺手就传上去最危险）", () => {
  const staging = sampleStaging("ckup");
  const base = tmp("ckup-out");
  // ★ 必须用**不存在的子路径**：`mkdtempSync` 自己就建了目录，
  //   直接断言那个目录不存在会恒假（这条判据自己踩过）。
  const out = join(base, "never", "created");
  try {
    const r = cli(["--platform", "steam", "--staging", staging, "--out", out, "--config", STEAM_CFG, "--check", "--upload"]);
    assert.equal(r.status, 2, `${r.stdout}${r.stderr}`);
    assert.equal(existsSync(out), false, "既说 --check 就一个文件都不该写");
  } finally {
    for (const d of [staging, base]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] --login 单独给（没有 --upload）→ 退出码 2，不让它悄悄无效", () => {
  const staging = sampleStaging("loginonly");
  const out = tmp("loginonly-out");
  try {
    const r = cli(["--platform", "steam", "--staging", staging, "--out", out, "--config", STEAM_CFG, "--login", "builder"]);
    assert.equal(r.status, 2, `${r.stdout}${r.stderr}`);
    assert.match(r.stderr, /--upload/);
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});

test("[打包CLI] ★★ PATH 里没有 steamcmd：退出 2、但仍把 VDF 写好并给出可手抄的命令", () => {
  const staging = sampleStaging("nosteamcmd");
  const out = tmp("nosteamcmd-out");
  try {
    const r = cli(["--platform", "steam", "--staging", staging, "--out", out, "--config", STEAM_CFG, "--upload"], envWithoutPath());
    // 环境缺失 = 2（不是 1）：人去查预算/归属只会白查
    assert.equal(r.status, 2, `${r.stdout}${r.stderr}`);
    assert.match(r.stderr, /STEAM\.NO_STEAMCMD/);

    // ★ 这条最重要：上传这一步失败，**不许把已经打好的东西丢掉** ——
    //   VDF 是上一步的产物，重跑一次要重扫整个 staging。
    assert.ok(listFiles(out).length > 0, "上传失败时连 VDF 都没写出来");
    const names = listFiles(out);
    assert.ok(names.some((n) => n.startsWith("app_build_")), `没写 app_build：${names.join(",")}`);

    // 报错里要给出能直接抄去执行的完整命令（含 +quit —— 少了它 steamcmd 会挂住）
    const hint = `${r.stdout}${r.stderr}`;
    assert.ok(hint.includes("+run_app_build"), "没有给出可手抄的命令");
    assert.ok(hint.includes("+quit"), "手抄的命令里没有 +quit —— 贴进去 steamcmd 会停在提示符上");
  } finally {
    for (const d of [staging, out]) rmSync(d, { recursive: true, force: true });
  }
});
