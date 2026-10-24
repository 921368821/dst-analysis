/**
 * 无头浏览器驱动的**公共件**：找浏览器、起进程、连 CDP、收尸。
 *
 * ★ 为什么抽出来：`tools/browser-selftest.mjs`（跑自检页）与
 *   `tools/cross-host-save.mjs`（比跨宿主存档）需要**同一套**启动参数与环境判定。
 *   抄两遍的后果不是"多 80 行"，而是某一版修了参数（比如 SwiftShader）另一版没修 ——
 *   于是"一个脚本能跑、另一个脚本起不来"，而两边看的是同一个浏览器。
 *
 * ★ 退出码三分法（这是本文件最重要的一条约定）：
 *   0 = 通过；1 = 判据真的失败；2 = 环境里没有浏览器 / 起不来。
 *   把 2 混进 0 是假绿灯（CI 在没有浏览器的机器上一路绿）；
 *   把 2 混进 1 是假红（人去查一个不存在的 bug）。
 */

import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";

export const EXIT_PASS = 0;
export const EXIT_FAIL = 1;
export const EXIT_NO_BROWSER = 2;

/** 已知安装位置。`ENGINE_BROWSER` 可以覆盖（CI 上把 chrome 装到别处时用）。 */
const CANDIDATES = [
  process.env.ENGINE_BROWSER,
  // Windows
  "C:/Program Files/Google/Chrome/Application/chrome.exe",
  "C:/Program Files (x86)/Google/Chrome/Application/chrome.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  // Linux（CI 的 ubuntu 跑这个分支；装了 chromium 才有）
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
  "/usr/bin/microsoft-edge",
  // macOS
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
].filter((p) => typeof p === "string" && p !== "");

export function findBrowser() {
  for (const p of CANDIDATES) if (existsSync(p)) return p;
  return null;
}

export function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/** 极简 CDP 客户端：只做 `send` 与事件收集。 */
export function connect(url) {
  const ws = new WebSocket(url);
  let seq = 0;
  const pending = new Map();
  const events = [];
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
      return;
    }
    events.push(m);
  });
  const ready = new Promise((resolve, reject) => {
    ws.addEventListener("open", () => resolve());
    ws.addEventListener("error", () => reject(new Error("WebSocket 连不上")));
  });
  return {
    ready,
    events,
    close: () => ws.close(),
    send(method, params) {
      const id = ++seq;
      ws.send(JSON.stringify({ id, method, params: params ?? {} }));
      return new Promise((resolve, reject) => pending.set(id, { resolve, reject }));
    },
  };
}

/** 等浏览器把 DevTools 地址打到 stderr（`--remote-debugging-port=0` 时端口是随机的）。 */
export function waitForDevTools(child, timeoutMs) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const timer = setTimeout(() => reject(new Error(`等 DevTools 地址超时（${timeoutMs}ms）：${buf.slice(-400)}`)), timeoutMs);
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
      reject(new Error(`浏览器提前退出（code ${code}）：${buf.slice(-400)}`));
    });
  });
}

export function killTree(child) {
  if (child.pid === undefined) return;
  if (process.platform === "win32") {
    // Windows 上 Edge 会拉起一串子进程；只 kill 主进程会留下孤儿
    spawnSync("taskkill", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  } else {
    try {
      process.kill(-child.pid, "SIGKILL");
    } catch {
      child.kill("SIGKILL");
    }
  }
}

/**
 * 打开一个无头页面并连上它的 target。
 *
 * @param {string} browser 浏览器可执行文件
 * @param {string} url 完整地址
 * @param {string} profile 临时 profile 目录（调用方负责删）
 * @param {string} pageHint 用于在 target 列表里认出"我们那个页面"的片段
 */
export async function openPage(browser, url, profile, pageHint, windowSize = "960,700") {
  const child = spawn(
    browser,
    [
      "--headless",
      "--no-sandbox",
      "--disable-dev-shm-usage",
      "--no-first-run",
      // ★ 无头环境没有真 GPU。Chromium 122+ 里软件 WebGL（SwiftShader）默认被关掉，
      //   必须显式打开，否则 WebGL2 探测失败 → 页面只剩降级路径 → "引擎没启动"。
      //   `--disable-gpu` 与这几个参数是**互相矛盾**的：禁了 GPU 就一个绘图层都没有。
      "--enable-unsafe-swiftshader",
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--remote-debugging-port=0",
      `--user-data-dir=${profile}`,
      `--window-size=${windowSize}`,
      url,
    ],
    { stdio: ["ignore", "pipe", "pipe"] },
  );

  const devtools = await waitForDevTools(child, 30_000);
  // ws://127.0.0.1:PORT/devtools/browser/<id> → 取页面 target 的 ws 地址
  const port = new URL(devtools).port;
  const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = list.find((t) => t.type === "page" && String(t.url).includes(pageHint)) ?? list.find((t) => t.type === "page");
  if (page === undefined) throw new Error("调试端口里没有页面 target");

  const client = connect(page.webSocketDebuggerUrl);
  await client.ready;
  await client.send("Runtime.enable");
  return { child, client };
}

/** 页面控制台里的异常与 error 日志（排障线索，不是判据）。 */
export function consoleProblems(client) {
  return client.events
    .filter((e) => e.method === "Runtime.exceptionThrown" || (e.method === "Runtime.consoleAPICalled" && e.params?.type === "error"))
    .map((e) => (e.params?.exceptionDetails?.text ?? e.params?.args?.map((a) => a.value ?? a.description).join(" ")) ?? "")
    .filter((s) => s !== "");
}
