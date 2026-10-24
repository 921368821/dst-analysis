/**
 * 浏览器端截图：把**真的跑起来**的那个页面拍下来。
 *
 * ★ 为什么需要它：`browser-selftest.mjs` 证明的是"断言都过了"，而断言看不见
 *   "画面对不对"。本项目已经有两条踩过的坑正属于这一类：
 *   · `pivotX` 搬运丢了 —— 组件判据绿、batch 判据绿，画面整体错位半格；
 *   · 地形基色用了草绿而不是中性灰 —— 海会变成墨绿，看起来还挺自然。
 *   这两类只有**看**才能发现。所以这个工具的作用是"给人一双眼睛"，不是判据：
 *   它不设通过/失败，只产出一张图。要判据请写进 `selftest.html`。
 *
 * 用法：
 *   node tools/browser-shot.mjs                     # 默认拍 index.html（游戏页）
 *   node tools/browser-shot.mjs --page game.html --wait 4000 --out shot.png
 *
 * 退出码与自检脚本同一套口径：0 拍到了 / 2 环境里没有浏览器。
 * （拍不到但浏览器在 = 1，那是真问题。）
 */

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WEB_ROOT, startStaticServer } from "./static-server.mjs";

const CANDIDATES = [
  process.env.ENGINE_BROWSER,
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/microsoft-edge",
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
].filter((p) => typeof p === "string" && p !== "");

function arg(name, dflt) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : dflt;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function connect(url) {
  const ws = new WebSocket(url);
  let seq = 0;
  const pending = new Map();
  ws.addEventListener("message", (ev) => {
    let m;
    try {
      m = JSON.parse(typeof ev.data === "string" ? ev.data : "");
    } catch {
      return;
    }
    if (m.id !== undefined && pending.has(m.id)) {
      const p = pending.get(m.id);
      pending.delete(m.id);
      if (m.error !== undefined) p.reject(new Error(m.error.message ?? "CDP 错误"));
      else p.resolve(m.result);
    }
  });
  const ready = new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve());
    ws.addEventListener("error", () => reject(new Error("WebSocket 连不上")));
  });
  return {
    ready,
    close: () => ws.close(),
    send(method, params) {
      const id = ++seq;
      ws.send(JSON.stringify({ id, method, params: params ?? {} }));
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    },
  };
}

function waitForDevTools(child, timeoutMs) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error(`等 DevTools 地址超时：${buf.slice(-300)}`)), timeoutMs);
    const onData = (d) => {
      buf += String(d);
      const m = /DevTools listening on (ws:\/\/\S+)/.exec(buf);
      if (m !== null) {
        clearTimeout(timer);
        resolve(m[1]);
      }
    };
    child.stderr.on("data", onData);
    child.stdout.on("data", onData);
    child.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`浏览器提前退出（code ${code}）`));
    });
  });
}

function killTree(child) {
  if (child.pid === undefined) return;
  if (process.platform === "win32") spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  else {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      child.kill("SIGKILL");
    }
  }
}

async function main() {
  const browser = CANDIDATES.find((p) => existsSync(p)) ?? null;
  if (browser === null) {
    console.error("✗ 环境缺失：找不到可用浏览器。这不是代码失败。");
    process.exit(2);
  }
  if (typeof WebSocket !== "function") {
    console.error("✗ 当前 Node 没有内置 WebSocket（需要 Node ≥ 22）");
    process.exit(2);
  }

  const page = arg("page", "index.html");
  const out = arg("out", "tools/out/game-shot.png");
  const waitMs = Number(arg("wait", "3000"));

  const srv = await startStaticServer({ port: 0 });
  const profile = mkdtempSync(join(tmpdir(), "engine-shot-"));
  const t0 = Date.now();
  let child;
  let client;
  try {
    child = spawn(
      browser,
      [
        "--headless",
        "--no-sandbox",
        "--disable-dev-shm-usage",
        "--no-first-run",
        "--enable-unsafe-swiftshader",
        "--use-gl=angle",
        "--use-angle=swiftshader",
        "--remote-debugging-port=0",
        `--user-data-dir=${profile}`,
        "--window-size=960,700",
        "--hide-scrollbars",
        `${srv.origin}/${page}`,
      ],
      { stdio: ["ignore", "pipe", "pipe"] },
    );

    const devtools = await waitForDevTools(child, 30_000);
    const port = new URL(devtools).port;
    const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const target = list.find((t) => t.type === "page" && String(t.url).includes(page)) ?? list.find((t) => t.type === "page");
    if (target === undefined) throw new Error("调试端口里没有页面 target");

    client = connect(target.webSocketDebuggerUrl);
    await client.ready;
    await client.send("Runtime.enable");

    // 等世界装配完成（不是死等固定时长）：页面把世界链挂在 __engine.world 上
    const deadline = Date.now() + 20_000;
    let ready = false;
    while (Date.now() < deadline) {
      const r = await client.send("Runtime.evaluate", {
        expression: "!!(globalThis.__engine && globalThis.__engine.world && globalThis.__engine.world.assembled)",
        returnByValue: true,
      });
      if (r?.result?.value === true) {
        ready = true;
        break;
      }
      await sleep(200);
    }
    if (!ready) console.warn("⚠ 20 秒内世界没装配完成，仍然按 wait 时长截图（画面可能是半成品）");
    await sleep(waitMs);

    // `--eval "<表达式>"`：在页面里跑一段脚本（改场景、取诊断值），再截图。
    // ★ 有了它，就不必为每个"看一眼"的问题写一个一次性探针脚本。
    const evalSrc = arg("eval", "");
    if (evalSrc !== "") {
      const r = await client.send("Runtime.evaluate", { expression: evalSrc, returnByValue: true });
      console.log(`eval: ${JSON.stringify(r?.result?.value ?? r?.exceptionDetails?.text ?? null)}`);
      await sleep(500);
    }

    const probe = await client.send("Runtime.evaluate", {
      expression: `(() => { const e = globalThis.__engine; if (!e) return "no engine";
        const w = e.world; const c = w ? w.counts() : null; const lf = e.lastFrame();
        return JSON.stringify({ ok: true, hud: (document.getElementById("hud")||{}).textContent,
          counts: c, quads: lf.quads, draws: lf.drawCalls, nodes: e.scene.stats().nodes, atlas: e.atlasSource, fmt: e.renderMod.atlasFormat, frames: e.renderMod.atlasFrameCount }); })()`,
      returnByValue: true,
    });
    const shot = await client.send("Page.captureScreenshot", { format: "png" });
    const buf = Buffer.from(shot.data, "base64");
    writeFileSync(out, buf);
    console.log(`页面：${srv.origin}/${page}`);
    console.log(`探针：${String(probe?.result?.value ?? "?")}`);
    console.log(`截图：${out}（${(buf.length / 1024).toFixed(1)} KB，用时 ${((Date.now() - t0) / 1000).toFixed(1)}s）`);
  } finally {
    client?.close();
    if (child !== undefined) killTree(child);
    await srv.close();
  }
}

void main();
