/**
 * 编辑器自检的**自动化**：无头浏览器打开 `web/editor.html`，用 `window.__editor` 命令面
 * 走一遍"树 → 选中 → 改属性 → 单步 → 播放/暂停"，逐条比对。
 *
 * ★ 为什么不能只跑 Node 判据：`extensions/editor/*` 的 76 条判据证明的是
 *   「模型算得对」，证明不了「面板真的连上了世界」——
 *   `select()` 之后 DOM 里有没有输入框、`step(3)` 之后场景 tick 有没有真的走 3 格，
 *   这两件事只有把页面开起来才知道。
 *   本项目在 JPEG 上踩过一次"模块各自全绿、接缝全错"，所以接线判据不嫌多。
 *
 * ★ 为什么断言写在 Node 侧、写在页面侧：页面里放断言 = 判据与被测代码同源，
 *   改页面的人顺手就把断言改了。这里的页面只知道"提供命令"，不知道"被考什么"。
 *
 * ★ 三种退出码（与 `browser-selftest.mjs` 同一口径，必须分开）：
 *   0 = 通过；1 = 真的有断言失败；2 = 环境里没有浏览器 / 起不来。
 *
 * ★ `--build`：先跑 `npm run build:web` 再自检。变异校验要用它 ——
 *   改了 `src/**.ts` 之后页面读的还是上一次的 `web/editor.js`，
 *   不重建就会得到"变异没被抓住"的**假结论**（其实改的东西根本没上页面）。
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
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
import { startStaticServer } from "./static-server.mjs";

/** 与页面里 `add(...)` 的名字逐条对应：少跑一条也要红。 */
const DECLARED = [
  "场景树建起来了（>50 个节点）",
  "树真的画到了 DOM 上",
  "outline 行数与 stats().nodes 一致",
  "找到一个 Int 字段用于改属性",
  "选中后属性面板出字段",
  "DOM 里出现了输入框",
  "★ Int 字段拒绝 3.5（不静默取整）",
  "★ 非法输入没有写进组件",
  "合法整数写进去了",
  "改字段进了历史（换目标与 label 都对）",
  "★ 撤销一次：字段回到改之前的值",
  "重做一次：字段回到改之后的值",
  "新建节点：树里真的多了一个",
  "★ 撤销新建：节点数退回",
  "新建之后自动选中它（否则「新建」之后无处可操作）",
  "删除选中：节点真的没了",
  "★ 撤销删除：同一个 id 的节点回来了（id 变了等于场景里所有引用都断了）",
  "★ 历史走空之后撤销是 empty，不是失败（两者在 UI 上都只表现为按钮变灰）",
  "step(3) 推进 3 个 tick",
  "播放后 tick 会涨",
  "暂停后 tick 不再涨",
  "文档保存到文本（长度 > 0，且真的写进了文本框）",
  "★★ 打开坏文档：报错，且场景原样还在",
  "★★ 打开合法文档：节点数回到保存时，且历史被清空",
  "新建空场景：只剩根，历史清空",
];

/** 页面里跑的脚本。**不引用外部变量**：它是被 CDP 求值的字符串。 */
const PROBE = `
(async () => {
  const E = window.__editor;
  const rows = [];
  const add = (name, ok, detail) => {
    rows.push({ name: name, ok: ok === true, detail: String(detail === undefined ? "" : detail) });
  };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const findField = (panel, type, key) => {
    if (!panel) return null;
    const g = panel.groups.find((x) => x.type === type);
    if (!g) return null;
    return g.fields.find((f) => f.key === key) || null;
  };

  const st0 = E.stats();
  add("场景树建起来了（>50 个节点）", st0.nodes > 50, "nodes=" + st0.nodes);
  const domRows = document.querySelectorAll("#tree .row").length;
  add("树真的画到了 DOM 上", domRows > 0, "rows=" + domRows);

  const list = E.outline();
  add("outline 行数与 stats().nodes 一致", list.length === st0.nodes, "rows=" + list.length + " nodes=" + st0.nodes);

  let target = null;
  const withComp = list.filter((r) => r.types.length > 0).slice(0, 40);
  for (const r of withComp) {
    if (!E.select(r.id)) continue;
    const p = E.panel();
    if (!p) continue;
    for (const g of p.groups) {
      for (const f of g.fields) {
        if (f.type === "i32") { target = { id: r.id, comp: g.type, key: f.key, value: f.value }; break; }
      }
      if (target) break;
    }
    if (target) break;
  }
  add("找到一个 Int 字段用于改属性", target !== null, JSON.stringify(target || {}));
  if (target === null) return rows;

  const p1 = E.panel();
  add("选中后属性面板出字段", p1 !== null && p1.node === target.id, "panel=" + (p1 ? p1.node : "null"));
  const inputs = document.querySelectorAll("#props input").length;
  add("DOM 里出现了输入框", inputs > 0, "inputs=" + inputs);

  const bad = E.setField(target.id, target.comp, target.key, "3.5");
  add("★ Int 字段拒绝 3.5（不静默取整）", bad.ok === false && bad.code === "EDIT.BAD_VALUE", JSON.stringify(bad));
  const afterBad = findField(E.panel(), target.comp, target.key);
  add("★ 非法输入没有写进组件", afterBad !== null && afterBad.value === target.value,
      "now=" + JSON.stringify(afterBad ? afterBad.value : null));

  const good = E.setField(target.id, target.comp, target.key, String(target.value + 1));
  const afterGood = findField(E.panel(), target.comp, target.key);
  add("合法整数写进去了", good.ok === true && afterGood !== null && afterGood.value === target.value + 1,
      JSON.stringify(good) + " now=" + JSON.stringify(afterGood ? afterGood.value : null));

  // ---------------------------------------------------------------- 撤销栈
  // ★ 这里验的是「反向操作在**真场景**里真的把值退回去了」，不是「栈的计数对不对」
  //   （后者在 Node 判据里）。两层都要有：Node 证不到接线，浏览器证不到顺序。
  const h1 = E.history();
  add("改字段进了历史（换目标与 label 都对）", h1.undo.length === 1 && String(h1.undo[0]).indexOf(target.comp) >= 0,
      JSON.stringify(h1));

  const u1 = E.undo();
  const afterUndo = findField(E.panel(), target.comp, target.key);
  add("★ 撤销一次：字段回到改之前的值", u1.kind === "done" && afterUndo !== null && afterUndo.value === target.value,
      JSON.stringify(u1) + " now=" + JSON.stringify(afterUndo ? afterUndo.value : null) + " 期望=" + target.value);

  const r1 = E.redo();
  const afterRedo = findField(E.panel(), target.comp, target.key);
  add("重做一次：字段回到改之后的值", r1.kind === "done" && afterRedo !== null && afterRedo.value === target.value + 1,
      JSON.stringify(r1) + " now=" + JSON.stringify(afterRedo ? afterRedo.value : null));

  const nodesA = E.stats().nodes;
  const made = E.addNode("自检新建");
  const nodesB = E.stats().nodes;
  add("新建节点：树里真的多了一个", made.ok === true && nodesB === nodesA + 1,
      JSON.stringify(made) + " " + nodesA + "->" + nodesB);

  const u2 = E.undo();
  const nodesC = E.stats().nodes;
  add("★ 撤销新建：节点数退回", u2.kind === "done" && nodesC === nodesA, JSON.stringify(u2) + " nodes=" + nodesC);

  const victim = E.addNode("待删");
  add("新建之后自动选中它（否则「新建」之后无处可操作）",
      victim.ok === true && E.stats().primary === victim.id,
      JSON.stringify(victim) + " primary=" + E.stats().primary);

  const beforeDel = E.stats().nodes;
  const del = E.deleteSelected();
  const afterDel = E.stats().nodes;
  add("删除选中：节点真的没了", del.ok === true && afterDel === beforeDel - 1,
      JSON.stringify(del) + " " + beforeDel + "->" + afterDel);

  const u3 = E.undo();
  const back = E.outline().find((r) => r.id === victim.id);
  add("★ 撤销删除：同一个 id 的节点回来了（id 变了等于场景里所有引用都断了）",
      u3.kind === "done" && back !== undefined && back.name === "待删",
      JSON.stringify(u3) + " 找到=" + JSON.stringify(back || null));

  let guard = 0;
  while (E.history().canUndo && guard < 60) { E.undo(); guard++; }
  const emptyOut = E.undo();
  add("★ 历史走空之后撤销是 empty，不是失败（两者在 UI 上都只表现为按钮变灰）",
      emptyOut.kind === "empty" && E.history().canUndo === false,
      JSON.stringify(emptyOut) + " guard=" + guard);

  E.pause();
  const t0 = E.stats().tick;
  const t1 = E.step(3);
  add("step(3) 推进 3 个 tick", t1 - t0 === 3, "before=" + t0 + " after=" + t1);

  // ★ 顺序：先播放、再暂停。反过来写（先暂停再播放）的话，
  //   "暂停后不涨"这个词条的**前置条件**（世界里本来在跑）不成立 ——
  //   暂停逻辑坏掉了照样绿。这一条最初就是这么写的，被变异 M229 抓出来的。
  const c = E.stats().tick;
  E.play();
  await sleep(450);
  const d = E.stats().tick;
  add("播放后 tick 会涨", d > c, "c=" + c + " d=" + d);

  E.pause();
  const a = E.stats().tick;
  await sleep(450);
  const b = E.stats().tick;
  // ★ a > c：暂停测之前世界必须真的在跑，否则"不涨"是废话
  add("暂停后 tick 不再涨", b === a && a > c, "a=" + a + " b=" + b + " c=" + c);
  E.pause();

  // ---- 文档：保存 / 打开 / 新建（批82）
  // ★ 放在最后：这一组会把场景整体替换掉，放前面会让别的断言面对另一份世界。
  const saved = E.docSave();
  add(
    "文档保存到文本（长度 > 0，且真的写进了文本框）",
    saved.ok === true && (saved.text || "").length > 100 && E.docText() === saved.text,
    "ok=" + saved.ok + " len=" + (saved.text || "").length,
  );
  const nodesAtSave = E.stats().nodes;

  // 制造一处未保存的改动（进历史），然后拿坏文本去打开
  E.addNode("doc-probe");
  const nodesAfterAdd = E.stats().nodes;
  const badDoc = E.docOpen("{ 这不是 JSON");
  add(
    "★★ 打开坏文档：报错，且场景原样还在",
    badDoc.ok === false && badDoc.code === "EDIT.BAD_DOC" && E.stats().nodes === nodesAfterAdd,
    JSON.stringify(badDoc) + " nodes=" + E.stats().nodes + "（打开前 " + nodesAfterAdd + "）",
  );

  const opened = E.docOpen(saved.text);
  const h = E.history();
  add(
    "★★ 打开合法文档：节点数回到保存时，且历史被清空",
    opened.ok === true && E.stats().nodes === nodesAtSave && h.canUndo === false && h.undo.length === 0,
    JSON.stringify(opened) + " nodes=" + E.stats().nodes + "（保存时 " + nodesAtSave + "）undo=" + h.undo.length,
  );

  const fresh = E.docNew();
  const h2 = E.history();
  // ★ stats().nodes 是**含根**的（buildOutline 把根算一个），所以「只剩根」= 1。
  //   存档记录里根是不出现的（collectNodes 排除它），两个口径不同 —— 这里量的是 tree。
  add(
    "新建空场景：只剩根，历史清空",
    fresh.ok === true && E.stats().nodes === 1 && h2.canUndo === false && E.outline().length === 1,
    JSON.stringify(fresh) + " nodes=" + E.stats().nodes + " undo=" + h2.undo.length,
  );

  return rows;
})()
`;

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

  const srv = await startStaticServer({ port: 0 });
  const profile = mkdtempSync(join(tmpdir(), "engine-editor-"));
  const t0 = Date.now();
  let child;
  let client;
  try {
    const page = await openPage(browser, `${srv.origin}/editor.html`, profile, "editor.html");
    child = page.child;
    client = page.client;

    // 主动等：`__editor` 要等 bundle boot + 世界装配 + 模块 start 之后才出现
    const deadline = Date.now() + 30_000;
    let ready = false;
    while (Date.now() < deadline) {
      const r = await client.send("Runtime.evaluate", {
        expression: "!!(window.__editor && window.__editor.ready())",
        returnByValue: true,
      });
      if (r?.result?.value === true) {
        ready = true;
        break;
      }
      await sleep(250);
    }
    if (!ready) {
      console.error("✗ 30 秒内编辑器没有就绪 —— 页面在跑到命令面之前就挂了。");
      const early = consoleProblems(client);
      if (early.length > 0) console.error(`  控制台（${early.length} 条）：\n  ${early.slice(0, 12).join("\n  ")}`);
      else console.error("  控制台是空的 —— 说明连脚本都没开始跑（加载失败？）");
      process.exit(EXIT_FAIL);
    }

    const r = await client.send("Runtime.evaluate", {
      expression: PROBE,
      awaitPromise: true,
      returnByValue: true,
    });
    if (r?.exceptionDetails !== undefined) {
      console.error(`✗ 探针抛异常：${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
      process.exit(EXIT_FAIL);
    }
    const rows = r?.result?.value ?? [];
    if (!Array.isArray(rows) || rows.length === 0) {
      console.error("✗ 探针没有返回任何断言结果");
      process.exit(EXIT_FAIL);
    }

    const pass = rows.filter((x) => x.ok === true).length;
    const fail = rows.length - pass;
    const secs = ((Date.now() - t0) / 1000).toFixed(1);
    console.log(`浏览器：${browser}`);
    console.log(`页面：${srv.origin}/editor.html（${secs}s）`);
    console.log(`断言：声明 ${String(DECLARED.length)} 条 · 页面执行 ${String(rows.length)} 条 · ${String(pass)} 通过 / ${String(fail)} 失败`);

    const problems = [];
    if (fail !== 0) {
      problems.push(`${String(fail)} 条断言失败`);
      for (const x of rows) if (x.ok !== true) console.error(`  × ${x.name}  ${x.detail}`);
    }
    if (rows.length !== DECLARED.length) {
      problems.push(`只跑了 ${String(rows.length)} 条，声明 ${String(DECLARED.length)} 条`);
    }
    for (let i = 0; i < Math.min(rows.length, DECLARED.length); i++) {
      if (rows[i].name !== DECLARED[i]) {
        problems.push(`第 ${String(i + 1)} 条名字不一致：页面「${rows[i].name}」vs 声明「${DECLARED[i]}」`);
        break;
      }
    }

    if (problems.length > 0) {
      console.error(`✗ ${problems.join("；")}`);
      process.exit(EXIT_FAIL);
    }
    console.log("✓ 编辑器自检全部通过");
    process.exit(EXIT_PASS);
  } catch (e) {
    console.error(`✗ 编辑器自检起不来：${e instanceof Error ? e.message : String(e)}`);
    process.exit(EXIT_NO_BROWSER);
  } finally {
    client?.close();
    if (child !== undefined) killTree(child);
    await srv.close();
    try {
      rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 60 });
    } catch {
      /* 留给系统临时目录清理 */
    }
  }
}

await main();
