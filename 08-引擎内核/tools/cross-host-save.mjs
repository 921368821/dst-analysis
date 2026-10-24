#!/usr/bin/env node
/**
 * **跨宿主逐字节存档比对**：同一份语料（`tests/fixtures/cross-host-save.ts`）在
 * Node 与真浏览器里各跑一遍，存档字节必须**完全相同**。
 *
 * ★ 补的是哪一块：`tests/backends/save-cross-host.test.ts` 比的是三个**后端**，
 *   三个都在同一个进程里 —— 它证明不了"浏览器存的档桌面端打得开"。
 *   这里差的正是那一段：两个**宿主**（Node / Chromium 的 V8 + 浏览器平台）。
 *
 * ★ 比什么、不比什么：
 *   比 **字节**（UTF-8），不比字符串。字符串比较会盖住编码层差异（BOM、UTF-16 落盘）；
 *   也不比"解析后的对象"——那会把键序、浮点写法、空白全部规范化掉，
 *   而存档的承诺恰恰是"逐字节相同"。
 *
 * ★ 三道防空转的护栏（判据最怕"绿得没依据"）：
 *   ① 语料下限：节点数 / 资源数 / 背包堆数必须达到预期，两边都空也算过的那种不算；
 *   ② **篡改自检**：把金标改一个字节，比对必须报出差异 —— 证明比较器真的在比，
 *      而不是"两边都读成空字符串于是相等"；
 *   ③ 退出码三分：0 通过 / 1 真失败 / 2 环境没有浏览器（CI 上跳过并显式标注）。
 *
 * ★ 这个脚本**自己构建**浏览器侧的 bundle（esbuild API，10ms）。
 *   不让它吃 `web/cross-host.js` 这个"上次构建的产物"：那会引入一种极难发现的假绿 ——
 *   改了源码但忘了构建，比对的仍是旧 bundle，于是"跨宿主相同"证明的是旧代码。
 *   （变异校验也会踩这个坑：它改的是 `src/`，产物不重建就永远不会红。）
 *
 * 用法：`node tools/cross-host-save.mjs`
 */

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  EXIT_FAIL,
  EXIT_NO_BROWSER,
  EXIT_PASS,
  consoleProblems,
  findBrowser,
  killTree,
  openPage,
  sleep,
} from "./browser-kit.mjs";
import { startStaticServer } from "./static-server.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");

/** 语料下限：低于这些数字说明"语料根本没造出来"，比对通过也没有意义。 */
const MIN_NODES = 200;
const MIN_RESOURCES = 5;
const WANT_STACKS = 3;

function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

/** 第一个不同的字节下标（相同返回 -1）。**这是判据的核心**：它按字节比，不做任何规范化。 */
function firstDiff(a, b) {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) if (a[i] !== b[i]) return i;
  return a.length === b.length ? -1 : n;
}

function hexdump(buf, at, radius = 24) {
  const from = Math.max(0, at - radius);
  const to = Math.min(buf.length, at + radius);
  const hex = [...buf.subarray(from, to)].map((b) => b.toString(16).padStart(2, "0")).join(" ");
  return `[${from}..${to}) ${hex}`;
}

/** Node 侧金标：子进程跑 TS（Node 能直接吃 .ts，但父进程是 .mjs，不能 import .ts）。 */
function goldFromNode() {
  const r = spawnSync(process.execPath, ["--experimental-transform-types", join(ROOT, "tools/cross-host-gold.ts")], {
    cwd: ROOT,
    encoding: "buffer",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (r.status !== 0) {
    const err = Buffer.concat([r.stdout ?? Buffer.alloc(0), r.stderr ?? Buffer.alloc(0)]).toString("utf8");
    throw new Error(`Node 侧金标没跑出来（exit ${String(r.status)}）：\n${err.slice(-1200)}`);
  }
  const text = (r.stdout ?? Buffer.alloc(0)).toString("utf8").trim();
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error(`Node 侧金标输出的不是 JSON：${text.slice(0, 400)}`);
  }
  return { ...parsed, bytes: Buffer.from(parsed.base64, "base64") };
}

async function browserFromChromium(browser) {
  const srv = await startStaticServer({ port: 0 });
  const profile = mkdtempSync(join(tmpdir(), "engine-cross-"));
  let child;
  let client;
  try {
    const page = await openPage(browser, `${srv.origin}/cross-host.html`, profile, "cross-host.html", "800,600");
    child = page.child;
    client = page.client;

    const deadline = Date.now() + 30_000;
    let payload;
    while (Date.now() < deadline) {
      const r = await client.send("Runtime.evaluate", {
        expression: "JSON.stringify(globalThis.__crossHost ?? null)",
        returnByValue: true,
      });
      const raw = r?.result?.value;
      if (typeof raw === "string" && raw !== "null") {
        payload = JSON.parse(raw);
        break;
      }
      await sleep(200);
    }
    if (payload === undefined) {
      const errs = consoleProblems(client);
      throw new Error(
        `30 秒内页面没有产出 __crossHost（bundle 没构建？）` + (errs.length > 0 ? `\n  控制台：${errs.slice(0, 5).join("\n  ")}` : "\n  控制台是空的"),
      );
    }
    if (payload.ok !== true) throw new Error(`浏览器侧语料抛错：${payload.error ?? "未知"}`);
    return { ...payload, bytes: Buffer.from(payload.base64, "base64") };
  } finally {
    client?.close();
    if (child !== undefined) killTree(child);
    await srv.close();
    // ★ 临时 profile 的清理必须**尽力而为**：Windows 上浏览器刚被杀掉时
    //   `Default\Affiliation Database` 这类文件还被句柄占着，`rmSync` 会抛 EBUSY。
    //   在 `finally` 里抛异常会把已经算出来的结果**吃掉**（第一次跑就是这样），
    //   于是"比对其实成功了"被报成"跑不通"。清理失败不是判据的一部分。
    try {
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 60 });
    } catch {
      /* 留给系统临时目录清理 */
    }
  }
}

async function main() {
  // ---- ① 环境
  let esbuild;
  try {
    esbuild = await import("esbuild");
  } catch {
    console.error("✗ 缺 esbuild（devDependencies）—— 这是环境问题，先 `npm install`");
    process.exit(EXIT_NO_BROWSER);
  }
  await esbuild.build({
    entryPoints: [join(ROOT, "tools/cross-host-entry.ts")],
    bundle: true,
    format: "esm",
    target: "es2022",
    // 与 `npm run build:web` 同一组 external：这两个入口都只跑纯计算，不该真的去 require 它们
    external: ["url", "module", "fs", "path"],
    outfile: join(ROOT, "web/cross-host.js"),
    logLevel: "silent",
  });
  if (!existsSync(join(ROOT, "web/cross-host.js"))) {
    console.error("✗ 构建 web/cross-host.js 之后仍然找不到产物");
    process.exit(EXIT_FAIL);
  }
  const browser = findBrowser();
  if (browser === null) {
    console.error(
      "✗ 环境缺失：找不到可用浏览器（Chrome / Edge / Chromium 都没有）。\n" +
        "  这不是代码失败 —— 把 ENGINE_BROWSER 指到一个 Chromium 可执行文件即可。",
    );
    process.exit(EXIT_NO_BROWSER);
  }

  // ---- ② Node 金标 + 篡改自检（证明比较器不是空转）
  const gold = goldFromNode();
  const tampered = Buffer.from(gold.bytes);
  tampered[Math.floor(tampered.length / 2)] ^= 0x01;
  if (firstDiff(gold.bytes, tampered) < 0) {
    console.error("✗ 篡改自检失败：改了一个字节，比较器却说两边相同 —— 判据是空转的");
    process.exit(EXIT_FAIL);
  }
  if (gold.nodes < MIN_NODES || gold.resources < MIN_RESOURCES || gold.stacks !== WANT_STACKS) {
    console.error(
      `✗ 语料不达标：节点 ${gold.nodes}（≥${MIN_NODES}）/ 资源 ${gold.resources}（≥${MIN_RESOURCES}）/ ` +
        `堆叠 ${gold.stacks}（=${WANT_STACKS}）—— 语料本身坏了，比对没有意义`,
    );
    process.exit(EXIT_FAIL);
  }

  // ---- ③ 浏览器侧
  let web;
  try {
    web = await browserFromChromium(browser);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    // "页面没产出"是代码/构建问题（1）；"起不来连不上"是环境问题（2）
    const env = /起不来|DevTools|WebSocket|提前退出/.test(msg);
    console.error(`✗ 浏览器侧跑不通：${msg}`);
    process.exit(env ? EXIT_NO_BROWSER : EXIT_FAIL);
  }

  const d = firstDiff(gold.bytes, web.bytes);
  const goldSha = sha256(gold.bytes);
  const webSha = sha256(web.bytes);

  console.log(`浏览器：${browser}`);
  console.log(`Node  ：${gold.bytes.length} 字节 · sha256 ${goldSha} · 节点 ${gold.nodes} · 资源 ${gold.resources} · 堆叠 ${gold.stacks}`);
  console.log(`浏览器：${web.bytes.length} 字节 · sha256 ${webSha} · 节点 ${web.nodes} · 资源 ${web.resources} · 堆叠 ${web.stacks}`);

  if (d >= 0) {
    console.error(`✗ 跨宿主存档**不是**逐字节相同：第一处差异在第 ${d} 个字节`);
    console.error(`  Node  ：${hexdump(gold.bytes, d)}`);
    console.error(`  浏览器：${hexdump(web.bytes, d)}`);
    // 长度不同是最常见的一种：先说清楚，别让人去数 hex
    if (gold.bytes.length !== web.bytes.length) {
      console.error(`  长度也不同：Node ${gold.bytes.length} / 浏览器 ${web.bytes.length}`);
    }
    for (const k of ["nodes", "resources", "stacks", "released"]) {
      if (gold[k] !== web[k]) console.error(`  诊断：${k} Node=${String(gold[k])} 浏览器=${String(web[k])}`);
    }
    process.exit(EXIT_FAIL);
  }

  // 长度相同 + 字节相同之后，再确认"这份东西真的是存档"（不是两边都吐了个空字符串）
  const head = gold.bytes.subarray(0, 12).toString("utf8");
  if (!head.startsWith('{"format":1')) {
    console.error(`✗ 存档头不对：${JSON.stringify(head)} —— 比对的不是场景存档`);
    process.exit(EXIT_FAIL);
  }
  console.log(`✓ 跨宿主存档逐字节相同（${gold.bytes.length} 字节）`);
  process.exit(EXIT_PASS);
}

await main();
