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

/**
 * 判一次「资产来源探针」的结果（批127 / C21）。
 *
 * ★ 为什么这件事必须端到端、而且必须读 `kind`：
 *   `?pack=` 坏掉时**画面不会坏** —— 包里装的字节就是源文件的字节，退回直读之后
 *   游戏照跑、贴图照旧，只有一条 `console.warn` 飘过。C17 的 16 条 Node 判据
 *   也发现不了：那些用例自己造的 manifest 与 root 当然对得上（真实构建产物的
 *   `path` 是源文件位置，运行时的键是挂载根），于是这个错活过了整整一批。
 *   唯一能把两条路径分开的观测量是宿主自报的 `asset.kind`。
 *
 * ★ 为什么还要比字节：`kind` 只回答"走的哪条路"，回答不了"包里那份内容对不对"。
 *   两者一起读，才既证明路径通了、又证明内容没串。
 */
export function judgePackProbe({ label, expectedKind, booted, actualKind, byteEqual, atlasSource }) {
  const problems = [];
  if (booted !== true) return [`${label}：引擎没起来（页面里读不到 __engine.asset —— 包路径让启动挂掉了？）`];
  if (actualKind !== expectedKind) {
    problems.push(
      `${label}：资产来源应当是 ${expectedKind}，实际是 ${String(actualKind)}` +
        (expectedKind === "bundle" ? "（包没被用上 = 每个 readBinary 都 NOT_FOUND，图集静默降级）" : "（该退回直读却没退）"),
    );
  }
  if (byteEqual !== true) problems.push(`${label}：从来源读出的 tree.png 与直读的字节不一致（或读不出来）`);
  // ★ 第三条只在"资产真的走完导入链"时成立：程序化图集意味着读资产的每一张都失败了，
  //   而那正是"path 与 root 对不上"的症状。它在两种来源下都该为真。
  if (atlasSource === "procedural") problems.push(`${label}：图集退回程序化贴图 —— 说明资产一张都没读成功`);
  return problems;
}

/** 在页面里读一次资产来源状态（`__engine.asset` 由入口暴露）。 */
const PROBE_EXPR =
  "(async () => {" +
  " const e = globalThis.__engine;" +
  " if (!e || !e.asset) return { booted: false };" +
  " const kind = e.asset.kind();" +
  " const hex = await e.asset.readHex('tree.png');" +
  " let want = '';" +
  " try {" +
  "   const r = await fetch('./assets/tree.png');" +
  "   if (!r.ok) return { booted: true, actualKind: kind, byteEqual: false, atlasSource: e.atlasSource };" +
  "   const u = new Uint8Array(await r.arrayBuffer());" +
  "   for (const b of u) want += b.toString(16).padStart(2, '0');" +
  " } catch (err) { return { booted: true, actualKind: kind, byteEqual: false, atlasSource: e.atlasSource }; }" +
  " return { booted: true, actualKind: kind, byteEqual: hex === want, atlasSource: e.atlasSource };" +
  "})()";

/** 开一个页面、等引擎起来，读一次探针。失败返回 `{booted:false}` 或抛给调用方。 */
async function probeAssetSource(browser, url) {
  const profile = mkdtempSync(join(tmpdir(), "engine-probe-"));
  let child;
  let client;
  try {
    const page = await openPage(browser, url, profile, "selftest.html");
    child = page.child;
    client = page.client;
    const deadline = Date.now() + 45_000;
    while (Date.now() < deadline) {
      const r = await client.send("Runtime.evaluate", {
        expression: PROBE_EXPR,
        awaitPromise: true,
        returnByValue: true,
      });
      const v = r?.result?.value;
      // ★ 等到"引擎起来了 **且** 图集来源已有值"：`__engine` 是启动末尾才挂上的，
      //   而 atlasSource 在那之前是 undefined —— 提前采会读到"程序化"的假象。
      if (v !== undefined && v.booted === true && typeof v.atlasSource === "string") return v;
      await sleep(250);
    }
    return { booted: false };
  } finally {
    client?.close();
    if (child !== undefined) killTree(child);
    try {
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 60 });
    } catch {
      /* 留给系统临时目录清理 */
    }
  }
}

/**
 * dpr=2 下「画布物理尺寸 = CSS × 上限 2」的**接线**检查（批145 / C28）。
 *
 * ★ 为什么只有这一条，而不是把整张 56 条表也跑一遍：
 *   批144 试过两种做法（`Emulation.setDeviceMetricsOverride` + reload；960×700 的
 *   `--force-device-scale-factor=2`），三次全红。批145 定的性：
 *   ① `selftest.html` 的 `#cv` CSS 尺寸**写死** 958×598，dpr=2 ⇒ 物理 1916×1196，
 *      SwiftShader 跑不动（实测「1000ms 内渲染帧 0 涨幅（837→837）」）—— 那是**负载**；
 *   ② 同 CSS 尺寸（479×299）下比对 dpr=1 与 dpr=2：采样几何严格 2 倍对应
 *      （@351,182 255×22 对 @176,92 128×11）⇒ 换算**是对的**；
 *   ③ 那条像素判据在两个 dpr 下都红（「计数=0px」），与 dpr 无关 —— 是它自己的
 *      采样区宽度依赖视口。整表 dpr=2 只会变成「常红、且原因不在 dpr」的噪声。
 *   留下来的这条 0.7 秒、只读四个数，抓的是**入口有没有用 `backingStoreSize`**
 *   （Node 判据只能测那个纯函数，测不到「三个入口是不是真的在用它」）。
 *
 * ★ 为什么必须要求 `devicePixelRatio === 2`：dpr=1 时这条公式退化成恒等
 *   （958×1 = 958），跟「根本没乘像素比」分不开 —— 覆盖没生效就必须报红，
 *   否则这一格是「永远绿」，而它守的正是「桌面全绿、手机才露」的那条缝。
 */
/**
 * 联机接线探针（批163）：`?net=` 是**页面参数**，而它生效了没有在画面上几乎看不出来 ——
 * 单机、主机、客户端三种模式都能走能打。唯一能分开的观测量是宿主自报的 `net()`。
 *
 * ★ 为什么不能只靠 Node 判据：`parseNetMode` / `planNetWiring` 那 13 条全绿，也说明不了
 *   「`browser-entry` 把 `?net=` 传进 `env`、`demo-game` 照着它建了会话」—— 中间少接一根线时，
 *   两头都测得到、中间空着。这与 C20（批128 之前的 wx 入口「装上了但没接进 main」）同一条缝。
 * ★ 只读四个字段，每个都对应一种具体的坏法：
 *   `role` 错了 ⇒ 参数没接到装配上；`seat` 错了 ⇒ 座位号与端点号被合并；
 *   `why` 是"参数认不认得"的人话（静默回退的症状是「我明明加了参数」）；
 *   `stats` 说明会话对象**真的**建了（不是只算了个标志位）。
 */
const NET_PROBE_EXPR =
  "(() => {" +
  " const e = globalThis.__engine;" +
  " if (!e || typeof e.net !== 'function') return null;" +
  " const n = e.net();" +
  " if (n === null) return { role: null };" +
  " return { role: n.role, seat: n.seat, why: n.why, stats: n.stats };" +
  "})()";

/** 开一个页面、等 `__engine` 挂上（启动末尾），读一次联机状态。读不到返回 `null`。 */
async function probeNetState(browser, url) {
  const profile = mkdtempSync(join(tmpdir(), "engine-net-"));
  let child;
  let client;
  try {
    const page = await openPage(browser, url, profile, "selftest.html");
    child = page.child;
    client = page.client;
    const deadline = Date.now() + 30_000;
    while (Date.now() < deadline) {
      let v;
      try {
        const r = await client.send("Runtime.evaluate", { expression: NET_PROBE_EXPR, returnByValue: true });
        v = r?.result?.value;
      } catch {
        v = undefined; // 执行上下文还没建起来
      }
      // ★ 只认"拿到了一个对象"：`__engine` 挂上之前读到的是 undefined，
      //   它与"参数没生效"（`net()` 返回 null ⇒ `{role:null}`）必须分得开 ——
      //   混在一起的话，"页面根本没起来"会被判成"参数没接上"。
      if (v !== undefined && v !== null) return v;
      await sleep(250);
    }
    return null;
  } finally {
    client?.close();
    if (child !== undefined) killTree(child);
    try {
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 60 });
    } catch {
      /* 留给系统临时目录清理 */
    }
  }
}

/**
 * 判一次联机探针。
 *
 * ★ `want === null` 那一格不是凑数：**加了联机之后单机必须还是单机**。
 *   它一旦坏了，症状是"打开首页就在等一个不存在的房间"，而首页在所有 Node 判据里都是绿的。
 */
function judgeNetState({ label, want, got }) {
  if (got === null) return [`${label}：30 秒内读不到 __engine.net —— 页面没起来，这一轮没验到`];
  if (want === null) {
    if (got.role === null) return [];
    return [`${label}：没带参数时 net() 应当是 null（单机、联机代码一行都不经过），实际 role=${String(got.role)}`];
  }
  if (got.role === null) {
    return [`${label}：参数带上了，但 net() 是 null —— 这个参数没接到装配上（症状与"参数写错"一模一样）`];
  }
  const problems = [];
  if (got.role !== want) problems.push(`${label}：role=${String(got.role)}（期望 ${want}）`);
  if (typeof got.seat !== "number") problems.push(`${label}：seat=${String(got.seat)}（期望一个数字）`);
  else if (want === "client" && got.seat !== 1) problems.push(`${label}：seat=${String(got.seat)}（客户端缺省座位号是 1）`);
  if (typeof got.why !== "string" || !got.why.includes(`net=${want}`)) {
    problems.push(`${label}：why=「${String(got.why)}」里没有 net=${want} —— 理由要能被人看懂`);
  }
  if (typeof got.stats !== "object" || got.stats === null) problems.push(`${label}：没有会话统计（会话对象没建出来）`);
  return problems;
}

async function probeDprBackingStore(browser, url) {
  const profile = mkdtempSync(join(tmpdir(), "engine-dpr-"));
  let child;
  let client;
  try {
    const page = await openPage(browser, url, profile, "selftest.html", "960,700", [
      "--force-device-scale-factor=2",
    ]);
    child = page.child;
    client = page.client;
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      let v = null;
      try {
        const r = await client.send("Runtime.evaluate", {
          // 默认 canvas 是 300×150；引擎还没设过尺寸时它比 CSS 宽小 ⇒ 继续等
          expression:
            "(() => { const c = document.getElementById('cv');" +
            " if (!c || !c.clientWidth || c.width < c.clientWidth) return null;" +
            " return { dpr: window.devicePixelRatio, w: c.width, h: c.height," +
            " cw: c.clientWidth, ch: c.clientHeight }; })()",
          returnByValue: true,
        });
        v = r?.result?.value ?? null;
      } catch {
        /* 执行上下文还没建起来 */
      }
      if (v !== null) return v;
      await sleep(100);
    }
    return null;
  } finally {
    client?.close();
    if (child !== undefined) killTree(child);
    try {
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 60 });
    } catch {
      /* 留给系统临时目录清理 */
    }
  }
}

/** 判 `probeDprBackingStore` 的结果。期望值**从页面自己的 CSS 尺寸算**，不写死 1916。 */
function judgeDprBackingStore(got) {
  if (got === null) return ["20 秒内画布没被引擎设过尺寸 —— 引擎没起来，这一轮没验到"];
  const problems = [];
  if (got.dpr !== 2) {
    problems.push(
      `--force-device-scale-factor=2 没生效（window.devicePixelRatio=${String(got.dpr)}）——` +
        " dpr=1 下这条公式退化成恒等，等于没验；报红而不是静默跳过",
    );
  }
  const dpr = Math.min(2, got.dpr);
  const ew = Math.max(1, Math.floor(got.cw * dpr));
  const eh = Math.max(1, Math.floor(got.ch * dpr));
  if (got.w !== ew) {
    problems.push(`画布宽 ${got.w} ≠ CSS ${got.cw} × ${dpr} = ${ew}（实际 ${(got.w / got.cw).toFixed(2)} 倍）`);
  }
  if (got.h !== eh) {
    problems.push(`画布高 ${got.h} ≠ CSS ${got.ch} × ${dpr} = ${eh}（实际 ${(got.h / got.ch).toFixed(2)} 倍）`);
  }
  return problems;
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

  // ---- 构建产物（批127 / C21）：`?pack=` 那条路径要用**真产物**才能验，
  //   自己造一个假 manifest 等于把"构建侧与运行时侧的路径约定"这条缝又让过去。
  //   ★ 打进 `web/.packfix`（静态服务的根就是 `web/`），跑完删掉；`.gitignore` 里有它。
  const packDir = join(WEB_ROOT, ".packfix");
  rmSync(packDir, { recursive: true, force: true });
  const packBuild = spawnSync(
    process.execPath,
    ["--experimental-transform-types", join("tools", "build.ts"), "--out", "web/.packfix"],
    { encoding: "utf8", env: { ...process.env, NODE_NO_WARNINGS: "1" } },
  );
  if (packBuild.status !== 0) {
    console.error("✗ 构建产物打不出来 —— `?pack=` 那条路径无从验证（不是判据失败，是验证条件缺失）");
    console.error(`${packBuild.stdout ?? ""}${packBuild.stderr ?? ""}`.slice(0, 1200));
    process.exit(EXIT_FAIL);
  }

  const srv = await startStaticServer({ port: 0 });  const profile = mkdtempSync(join(tmpdir(), "engine-browser-"));
  const t0 = Date.now();
  let child;
  let client;
  try {
    const page = await openPage(browser, `${srv.origin}/selftest.html`, profile, "selftest.html");
    child = page.child;
    client = page.client;

    // ★ 主动等：页面自己会在一帧循环里反复重写结果表，我们轮询那句汇总文字
    // ★★ 上限 60 秒（批75 从 30 秒抬上来）：runner 实测一次**提前通过**的自检
    //   就要 23.2 秒 —— 其中大半是 SwiftShader 软件渲染下的引擎启动，
    //   而失败轮要跑满页面自己的 10 秒总闸，两者叠起来贴着 30 秒的边。
    //   这个上限是**工具等页面开口**的预算，不是判据口径：页面内部的
    //   `MAX_TRIES = 100 × 100ms = 10 秒`（selftest.html）才是判据的预算，没动。
    //   M316 守着这里：改成 ~0 会让整条自检变成"页面挂了"的假红。
    const deadline = Date.now() + 60_000;
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
      console.error("✗ 60 秒内页面没有产出可用结果 —— 页面在跑到断言之前就挂了。");
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
    // ---- 资产来源探针（批127 / C21）：`?pack=` 只在真浏览器里才算数
    //   ★ 两条一起跑，缺一条就有一半是瞎的：
    //     · 包有效 ⇒ 必须真的走包里（kind=bundle）；
    //     · 包无效 ⇒ 必须退回直读（kind=direct），**而且游戏还能跑**。
    //   只跑前者的话，"永远走直读"（即 `?pack=` 完全没接线）会绿；
    //   只跑后者的话，"永远走直读"同样绿。
    const probes = [
      { label: "?pack= 有效", query: "pack=.packfix/manifest.json", expectedKind: "bundle" },
      { label: "?pack= 无效", query: "pack=.packfix/没有这个文件.json", expectedKind: "direct" },
    ];
    const probeProblems = [];
    for (const p of probes) {
      const got = await probeAssetSource(browser, `${srv.origin}/selftest.html?${p.query}`);
      const msgs = judgePackProbe({ label: p.label, expectedKind: p.expectedKind, ...got });
      if (msgs.length === 0) {
        console.log(`· 资产来源 ${p.label}：${String(got.actualKind)}${got.actualKind === "bundle" ? "（包里的字节与直读一致）" : ""}`);
      }
      probeProblems.push(...msgs);
    }
    if (probeProblems.length > 0) {
      console.error("✗ 资产来源探针失败（`?pack=` 这条路径）：");
      for (const m of probeProblems) console.error(`  · ${m}`);
      process.exit(EXIT_FAIL);
    }

    // ---- dpr=2 的接线检查（批145 / C28）：只读四个数，验「入口真的按像素比放大画布」
    const dprGot = await probeDprBackingStore(browser, `${srv.origin}/selftest.html`);
    const dprProblems = judgeDprBackingStore(dprGot);
    if (dprProblems.length > 0) {
      console.error("✗ dpr=2 画布尺寸检查失败：");
      for (const m of dprProblems) console.error(`  · ${m}`);
      process.exit(EXIT_FAIL);
    }
    console.log(
      `· dpr=2 画布：CSS ${String(dprGot.cw)}×${String(dprGot.ch)} → 物理 ${String(dprGot.w)}×${String(dprGot.h)}（×${String(dprGot.dpr)}）`,
    );


    // ---- 联机接线探针（批163）：`?net=` 从 URL 一路到「会话对象建出来了没有」
    const netCases = [
      { label: "不带 ?net=", query: "", want: null },
      { label: "?net=client", query: "net=client&room=selftest163", want: "client" },
    ];
    const netProblems = [];
    for (const c of netCases) {
      const base = `${srv.origin}/selftest.html`;
      const got = await probeNetState(browser, c.query === "" ? base : `${base}?${c.query}`);
      const msgs = judgeNetState({ label: c.label, want: c.want, got });
      if (msgs.length === 0) {
        console.log(
          got.role === null
            ? `· 联机 ${c.label}：net() = null（单机，联机代码一行都不经过）`
            : `· 联机 ${c.label}：role=${String(got.role)} seat=${String(got.seat)}（会话已建）`,
        );
      }
      netProblems.push(...msgs);
    }
    if (netProblems.length > 0) {
      console.error("✗ 联机接线探针失败（`?net=` 这条路径）：");
      for (const m of netProblems) console.error(`  · ${m}`);
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
    // ★ 产物目录也要清：它每次都能重建，留着只会让下一个人以为自己手里的包是最新的
    try {
      rmSync(join(WEB_ROOT, ".packfix"), { recursive: true, force: true });
    } catch {
      /* 尽力而为：删不掉不影响结论，`.gitignore` 已经挡着它 */
    }
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
