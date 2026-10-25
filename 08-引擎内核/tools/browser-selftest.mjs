/**
 * 浏览器端自检的**自动化**：无头浏览器打开 `web/selftest.html`，等它跑完，读结果。
 *
 * 背景：那 14 条断言一直"要人打开页面看"。要人看的判据不是判据 ——
 * 它会在某一天变成"上次看还是绿的"。这个脚本把它接进 `npm run ci`。
 *
 * ★ 为什么不用 `--dump-dom`（试过，不行）：
 *   `--dump-dom` 在 load 事件后立刻 dump（实测 0.7 秒就返回），而页面要等
 *   bundle boot + wasm 加载 + 帧循环起来才写断言行。`--virtual-time-budget`
 *   只是把**计时器**快进，不能把"等网络与 wasm"变成"已经等到了"——
 *   于是 dump 出来的 DOM 里一条断言都没有。
 *   正确做法是**主动等**：走 CDP 轮询页面里的结果文字。
 *
 * ★ 为什么不装 puppeteer / playwright：
 *   需要的只是"打开页面 + 求值一个表达式"。Node 22 自带 WebSocket，
 *   四十行 CDP 就够。少一个依赖，CI 少一个"装不上"的失败面。
 *   启动/CDP 那套现在在 `tools/browser-kit.mjs`（与跨宿主比对脚本共用一份）。
 *
 * ★ 三种退出码，**必须分开**（这是这个脚本最重要的一点）：
 *   0 = 通过；1 = 真的有断言失败；2 = 环境里没有浏览器 / 起不来。
 *   把 2 混进 0 就是假绿灯（CI 在没有浏览器的机器上一路绿）；
 *   把 2 混进 1 就是假红（人去查一个不存在的 bug）。
 *
 * ★ `--build`：先跑 `npm run build:web` 再自检（与 `editor-selftest.mjs` 同一口径）。
 *   变异校验要用它 —— 改了 `src/**.ts` 之后页面读的还是上一次的 `web/bundle.js`，
 *   不重建就会得到"变异没被抓住"的**假结论**（其实改的东西根本没上页面）。
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
import { WEB_ROOT, startStaticServer } from "./static-server.mjs";

/** 页面里每条断言都以行首的 `row("` 声明（与 tools/docs-check.mjs 同一个口径）。 */
function declaredRows() {
  const src = readFileSync(join(WEB_ROOT, "selftest.html"), "utf8");
  return (src.match(/^row\(/gm) ?? []).length;
}

async function main() {
  if (process.argv.includes("--build")) {
    const b = spawnSync(process.platform === "win32" ? "npm.cmd" : "npm", ["run", "build:web"], {
      stdio: "inherit",
      shell: process.platform === "win32",
    });
    if (b.status !== 0) {
      console.error("✗ 构建失败 —— 自检没有意义（页面读的还是旧包）");
      process.exit(EXIT_FAIL);
    }
  }

  const browser = findBrowser();
  if (browser === null) {
    console.error(
      "✗ 环境缺失：找不到可用浏览器（Chrome / Edge / Chromium 都没有）。\n" +
        "  这不是代码失败 —— 把 ENGINE_BROWSER 指到一个 Chromium 可执行文件即可。",
    );
    process.exit(EXIT_NO_BROWSER);
  }
  if (typeof WebSocket !== "function") {
    console.error("✗ 当前 Node 没有内置 WebSocket（需要 Node ≥ 22）—— 属于环境问题，不是判据失败");
    process.exit(EXIT_NO_BROWSER);
  }

  const declared = declaredRows();
  if (declared === 0) {
    console.error("✗ selftest.html 里没有 `row(` 断言 —— 判据被删了？");
    process.exit(EXIT_FAIL);
  }

  const srv = await startStaticServer({ port: 0 });
  const profile = mkdtempSync(join(tmpdir(), "engine-browser-"));
  const t0 = Date.now();
  let child;
  let client;
  try {
    const page = await openPage(browser, `${srv.origin}/selftest.html`, profile, "selftest.html");
    child = page.child;
    client = page.client;

    // ★ 主动等：页面自己会在一帧循环里反复重写结果表，我们轮询那句汇总文字
    const deadline = Date.now() + 30_000;
    let text = "";
    let done = false;
    while (Date.now() < deadline) {
      const r = await client.send("Runtime.evaluate", {
        // ★ 把 `#fails` 一起带上：`#rows` 每 100ms 被清空重建，读到半张表时
        //   "哪一条红了"就丢了（批69 实际发生过：39 条报 1 失败，表格只打到 26 行）。
        //   ★ 换行必须写成 JS 转义（`\\n`）：直接在字符串里放一个真换行，
        //     送到页面端会变成"没闭合的字符串"，evaluate 抛错 ⇒ 读到空文本 ⇒
        //     工具报"页面在跑到断言之前就挂了"（批69 踩了一次）。
        expression:
          "(() => { const a = (document.getElementById('rows')||{}).innerText || '';" +
          " const b = (document.getElementById('fails')||{}).innerText || '';" +
          " return (b ? b + '\\n' : '') + a; })()",
        returnByValue: true,
      });
      text = String(r?.result?.value ?? "");
      // ★ 页面每 100ms 重写一次表格。看到"有汇总行"不等于"跑完了" ——
      //   第一次渲染时可能还有几条不通过（要等 tick 涨起来）。正确条件是：
      //   失败数为 0，或者页面自己宣布放弃（它会在表尾加一行说明）。
      const m = /(\d+) 通过 \/ (\d+) 失败/.exec(text);
      if (m !== null && Number(m[2]) === 0) {
        done = true;
        break;
      }
      if (/秒内仍有 \d+ 条不通过|秒内引擎没有启动/.test(text)) {
        done = true;
        break;
      }
      await sleep(250);
    }
    if (!done) {
      console.error("✗ 30 秒内页面没有产出可用结果 —— 页面在跑到断言之前就挂了。");
      console.error(`  页面文字（截断）：\n${text.slice(0, 800)}`);
      // ★ 这种失败最需要控制台：没启动的原因只在那里
      const early = client.events
        .filter((e) => e.method === "Runtime.exceptionThrown" || e.method === "Runtime.consoleAPICalled")
        .map((e) => {
          if (e.method === "Runtime.exceptionThrown") return `异常：${e.params?.exceptionDetails?.exception?.description ?? e.params?.exceptionDetails?.text}`;
          const args = (e.params?.args ?? []).map((a) => a.value ?? a.description ?? a.type).join(" ");
          return `${e.params?.type ?? "log"}: ${args}`;
        });
      if (early.length > 0) console.error(`  控制台（${early.length} 条）：\n  ${early.slice(0, 12).join("\n  ")}`);
      else console.error("  控制台是空的 —— 说明连脚本都没开始跑（加载失败？）");
      process.exit(EXIT_FAIL);
    }

    const summary = /(\d+) 通过 \/ (\d+) 失败/.exec(text);
    const total = /判据总数 (\d+)/.exec(text);
    const pass = Number(summary[1]);
    const fail = Number(summary[2]);
    const rows = total === null ? NaN : Number(total[1]);
    // ★ 排除页面自己在表尾追加的"放弃行"（它也以 × 开头）：
    //   那一行不是断言，把它算进来会让"1 条失败"报成"2 个 × 不一致"。
    const badMarks = text
      .split("\n")
      .filter((l) => l.trimStart().startsWith("×") && !/秒内仍有/.test(l)).length;
    const secs = ((Date.now() - t0) / 1000).toFixed(1);

    // 页面上的控制台错误是排障的线索（不是判据）：打印但不当成失败
    const errs = consoleProblems(client);

    console.log(`浏览器：${browser}`);
    console.log(`页面：${srv.origin}/selftest.html（${secs}s）`);
    console.log(`断言：声明 ${declared} 条 · 页面报告 ${Number.isFinite(rows) ? rows : "?"} 条 · ${pass} 通过 / ${fail} 失败`);
    if (errs.length > 0) console.log(`页面控制台错误 ${errs.length} 条：\n  ${errs.slice(0, 5).join("\n  ")}`);

    const problems = [];
    if (fail !== 0) problems.push(`${fail} 条断言失败`);
    if (badMarks !== fail) problems.push(`页面上 ${badMarks} 个 × 与"失败 ${fail}"不一致`);
    if (!Number.isFinite(rows)) problems.push("页面没报告判据总数");
    else if (rows !== declared) problems.push(`页面只跑了 ${rows} 条，文件里声明了 ${declared} 条`);
    if (pass !== declared) problems.push(`通过数 ${pass} ≠ 声明数 ${declared}`);

    if (problems.length > 0) {
      console.error(`✗ ${problems.join("；")}`);
      // 把失败行的名字打出来：只说"3 条失败"等于让人去猜。
      // ★ 名单由页面写在 `#rows` 外面（`#rows` 每 100ms 清空重建，读到半张表就没有它了）。
      const failsLine = text.split("\n").find((l) => /^失败 \d+ 条：/.test(l.trim()));
      if (failsLine !== undefined) console.error(`  ${failsLine.trim()}`);
      // ★ 截断上限要够大：39 条断言的中文详情约 3KB。
      //   1500 字节只能看到前 26 行，而"第 27 行红了"这句话就在被切掉的那一半里
      //   （批69 实际踩过：工具只打印了表格前 26 行，看不出是哪条失败）。
      console.error(text.slice(0, 6000));
      process.exit(EXIT_FAIL);
    }
    console.log("✓ 浏览器端自检全部通过");
    process.exit(EXIT_PASS);
  } catch (e) {
    // 起不来 / 连不上：环境问题（退出码 2），不是判据失败
    console.error(`✗ 浏览器自检起不来：${e instanceof Error ? e.message : String(e)}`);
    process.exit(EXIT_NO_BROWSER);
  } finally {
    client?.close();
    if (child !== undefined) killTree(child);
    await srv.close();
    // 临时 profile 清理是**尽力而为**：Windows 上杀进程后文件句柄可能还没释放（EBUSY）。
    // 在 finally 里抛异常会盖掉真正的结果 —— 清理失败不算判据失败。
    try {
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 60 });
    } catch {
      /* 留给系统临时目录清理 */
    }
  }
}

await main();
