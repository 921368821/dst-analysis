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
/**
 * 与页面里 `add(...)` 的名字逐条对应：少跑一条也要红。
 * **清单本体在 `editor-declared.mjs`**（零副作用的纯数据模块）—— 这样 `tools/docs-check.mjs`
 * 能 import 同一个数组去对账文档里的条数，而不必把无头浏览器拉起来。
 */
import { EDITOR_DECLARED as DECLARED } from "./editor-declared.mjs";

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

  // ---- 组件挂载 / 卸载（批83）
  // ★ 放在文档那一段之前：文档会把场景整体替换掉，之后就没有"已知带组件的节点"了。
  // ★ 先重新选一个**带组件**的节点：上面那几段（删除 / 撤销 / 播放）会把选中清掉或换掉，
  //   直接读 panel() 会拿到 null，四条断言就全变成"什么都没测"。
  const hostForComp = E.outline().find((r) => r.types.length > 0);
  if (hostForComp !== undefined) E.select(hostForComp.id);
  const picked = (() => {
    const p = E.panel();
    if (p === null || p.groups.length === 0) return null;
    return p.groups[0].type;
  })();
  add(
    "★ 选中项上有一个可卸的组件（拿不到的话下面三条都是废话）",
    typeof picked === "string" && picked.length > 0,
    "picked=" + String(picked) + " groups=" + String(E.panel() === null ? -1 : E.panel().groups.length),
  );
  const off = E.compDetach(String(picked));
  add(
    "★★ 卸下组件：节点上没了、面板里也没了，历史里有一条「卸下」",
    off.ok === true &&
      E.compCount(String(picked)) === 0 &&
      E.panel().groups.every((g) => g.type !== picked) &&
      E.history().undo.indexOf("卸下 " + String(picked)) >= 0,
    JSON.stringify(off) + " count=" + String(E.compCount(String(picked))) + " undo=" + E.history().undo.join("/"),
  );
  const undoOff = E.undo();
  add(
    "★★ 撤销卸下：组件回到节点上，字段也回来了（同类型仍然只有一个）",
    undoOff.kind === "done" &&
      E.compCount(String(picked)) === 1 &&
      E.panel().groups.some((g) => g.type === picked),
    JSON.stringify(undoOff) + " count=" + String(E.compCount(String(picked))),
  );
  const dup = E.compAttach(String(picked));
  add(
    "★ 同类型不许挂第二个：被拒，且节点上仍然只有一个",
    dup.ok === false && dup.code === "EDIT.BAD_COMP" && E.compCount(String(picked)) === 1,
    JSON.stringify(dup) + " count=" + String(E.compCount(String(picked))),
  );
  // ★ 反方向也要验：上一条只证明「卸下」进了历史。挂与卸是两条接线，
  //   漏掉任何一条的表现都是「撤销按钮没亮」，看起来像撤销栈坏了。
  E.compDetach(String(picked));
  const reattach = E.compAttach(String(picked));
  add(
    "★ 挂上组件也进历史（卸了再挂回，历史里出现「挂上」）",
    reattach.ok === true &&
      E.compCount(String(picked)) === 1 &&
      E.history().undo.indexOf("挂上 " + String(picked)) >= 0,
    JSON.stringify(reattach) + " count=" + String(E.compCount(String(picked))) + " undo=" + E.history().undo.join("/"),
  );
  const undoAttach = E.undo();
  add(
    "★ 撤销挂上：组件又没了（挂上确实是一条可撤销的操作，不是只压了个标签）",
    undoAttach.kind === "done" && E.compCount(String(picked)) === 0,
    JSON.stringify(undoAttach) + " count=" + String(E.compCount(String(picked))),
  );

  // ---- 画布拖拽（批84）
  // ★ 靶子的选法：**找一个"点下去命中自己"的节点**。
  //   一开始我造了个新节点拖，结果它在原点、和地形重合 —— pickAt 按 zIndex/id
  //   选了地形（这是正确行为），于是"拖的是 A、动的是 B"。
  //   改成从世界现有的节点里挑独占一个位置的，顺便验证了「点中即选中」。
  const cam = E.camInfo();
  const cvEl = document.getElementById("cv");
  const midW = E.screenToWorld(cvEl.clientWidth / 2, cvEl.clientHeight / 2);
  add(
    "★ 画布中心映射到相机中心（dpr 乘错时这条必红）",
    Math.abs(midW.x - cam.x) < 1e-6 && Math.abs(midW.z - cam.z) < 1e-6,
    "mid=(" + String(midW.x) + "," + String(midW.z) + ") cam=(" + String(cam.x) + "," + String(cam.z) +
      ") vw=" + String(cam.vw) + " vh=" + String(cam.vh) +
      " css=" + String(cvEl.clientWidth) + "x" + String(cvEl.clientHeight) +
      " bmp=" + String(cvEl.width) + "x" + String(cvEl.height) +
      " dpr=" + String(window.devicePixelRatio) +
      // ★ 从两次换算反解出**实际用的**缩放比：sx = dx/dcss * zoom，
      //   sy = -dz/dcss * zoom * tiltY。这样就不用猜"到底乘了什么"。
      " 反解sx=" + String(((E.screenToWorld(cvEl.clientWidth, 0).x - E.screenToWorld(0, 0).x) / cvEl.clientWidth) * cam.zoom) +
      " 反解sy=" + String(((E.screenToWorld(0, 0).z - E.screenToWorld(0, cvEl.clientHeight).z) / cvEl.clientHeight) * cam.zoom * cam.tiltY) +
      " 期望sx=" + String(cam.vw / cvEl.clientWidth) + " 期望sy=" + String(cam.vh / cvEl.clientHeight),
  );

  let dragNode = null;
  for (const r of E.outline()) {
    if (r.depth === 0) continue;
    const w0 = E.nodeWorld(r.id);
    if (w0 === null) continue;
    const b0 = E.dragBegin(w0.x, w0.y);
    if (!b0.ok) continue;
    if (b0.node === r.id) {
      dragNode = r.id;
      break;
    }
    // 命中了别人：当场取消（没动过 ⇒ 不压历史），换下一个
    E.dragEnd();
  }
  add(
    "★ 点中即开始拖、并把它选中（命中的必须是自己，不是压在上面的邻居）",
    dragNode !== null && E.stats().primary === dragNode,
    "dragNode=" + String(dragNode) + " primary=" + String(E.stats().primary),
  );
  const dw0 = dragNode === null ? null : E.nodeWorld(dragNode);
  const histBefore = E.history().undo.length;
  const mid = dw0 === null ? { ok: false } : E.dragMove(dw0.x + 1, dw0.y + 2);
  add(
    "★ 拖拽中途**不压历史**（一帧一条的话，撤销只退一个像素）",
    mid.ok === true && E.history().undo.length === histBefore,
    JSON.stringify(mid) + " undo=" + String(E.history().undo.length) + "（按下时 " + String(histBefore) + "）",
  );
  const done = E.dragEnd();
  const dw1 = dragNode === null ? null : E.nodeWorld(dragNode);
  add(
    "★★ 松手：位置真的挪了 (+1,+2)，历史里多了一条「移动」",
    done.ok === true &&
      done.moved === true &&
      dw0 !== null &&
      dw1 !== null &&
      Math.abs(dw1.x - dw0.x - 1) < 1e-6 &&
      Math.abs(dw1.y - dw0.y - 2) < 1e-6 &&
      E.history().undo.some((l) => l.indexOf("移动 ") === 0),
    JSON.stringify(done) + " after=" + JSON.stringify(dw1) + " from=" + JSON.stringify(dw0) +
      " undo=" + E.history().undo.join("/"),
  );
  const undoDrag = E.undo();
  const dw2 = dragNode === null ? null : E.nodeWorld(dragNode);
  add(
    "★★ 撤销拖拽：回到按下时的位置",
    undoDrag.kind === "done" &&
      dw0 !== null &&
      dw2 !== null &&
      Math.abs(dw2.x - dw0.x) < 1e-6 &&
      Math.abs(dw2.y - dw0.y) < 1e-6,
    JSON.stringify(undoDrag) + " back=" + JSON.stringify(dw2),
  );

  // ---- 场景树拖放换父（批85）
  // ★ 用**合成 pointer 事件**而不是直接调命令面：这一组要证明的正是"拖拽这条线接上了"。
  //   直接调 E.reparent 只能证明"那个函数本身能用"，而函数本身由
  //   tests/extensions/editor-reparent-world.test.ts 的 6 条判据管。
  //   合成事件能走通，是因为页面把 pointermove/up 挂在 document 上、落点用
  //   elementFromPoint 自己算 —— 不依赖 setPointerCapture（合成事件下 capture 会抛）。
  const rowOf = (id) => document.querySelector('#tree .row[data-id="' + String(id) + '"]');
  const centerOf = (el) => {
    el.scrollIntoView({ block: "center" });
    const r = el.getBoundingClientRect();
    return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
  };
  const pev = (type, el, pt) =>
    el.dispatchEvent(
      new PointerEvent(type, {
        bubbles: true,
        cancelable: true,
        clientX: pt.x,
        clientY: pt.y,
        pointerId: 1,
        isPrimary: true,
        button: 0,
        buttons: type === "pointerup" ? 0 : 1,
      }),
    );
  // 按下用事件目标（不看坐标），移动/松手才看坐标 —— 与页面的实现一致。
  const dragRows = (fromId, toId) => {
    const a = rowOf(fromId);
    const b = rowOf(toId);
    if (a === null || b === null) return false;
    const pa = centerOf(a);
    pev("pointerdown", a, pa);
    const pb = centerOf(b); // ★ 要在按下之后再取：scrollIntoView 会移动行
    pev("pointermove", document, pb);
    pev("pointerup", document, pb);
    return true;
  };
  const movesIn = () => E.history().undo.filter((l) => l.indexOf("移动 ") === 0).length;

  // ★ 夹具用**已在场景里的两个根级节点**，不用 E.addNode 造两个：
  //   addNode 把新节点挂在**当前选中项**下面（那是人点「新建」的预期），
  //   于是第二个新节点天生就是第一个的子 —— 拖它到第一个上面会直接报
  //   「已经挂在 #N 下面了」，而断言里"父子关系对上了"照样成立（假绿）。
  //   这条差一点就混过去了，靠的是把 err 一起打进 detail 才看见。
  const rootRows = E.outline().filter((r) => r.depth === 1).map((r) => r.id);
  const dParent = rootRows.length > 0 ? rootRows[0] : null;
  const dChild = rootRows.length > 1 ? rootRows[1] : null;
  const childWorld0 = dChild === null ? null : E.nodeWorld(dChild);
  const moves0 = movesIn();
  const dragged = dParent !== null && dChild !== null ? dragRows(dChild, dParent) : false;
  add(
    "★★ 拖放换父：拖到另一行上，父子关系真的变了，历史多一条「移动」",
    dragged === true && E.parentOf(dChild) === dParent && movesIn() === moves0 + 1,
    "dragged=" + String(dragged) + " parent=" + String(E.parentOf(dChild)) + " 期望 " + String(dParent) +
      " 移动条数 " + String(movesIn()) + "（之前 " + String(moves0) + "）",
  );

  // 拖到自己身上 = 取消。它必须**既不报错也不压历史** ——
  // 报错的话人以为操作坏了；压历史的话按一次撤销什么都没发生。
  const errEl = document.querySelector("#err");
  const errBeforeSelf = errEl === null ? "" : errEl.textContent;
  const selfDrag = dParent !== null ? dragRows(dParent, dParent) : false;
  add(
    "★ 拖到自己身上：算取消（不报错、不压历史）",
    selfDrag === true && errEl !== null && errEl.textContent === errBeforeSelf && movesIn() === moves0 + 1,
    "selfDrag=" + String(selfDrag) + " err=" + String(errEl === null ? "?" : errEl.textContent) +
      " 移动条数 " + String(movesIn()),
  );

  // 拖到自己 now-后代身上 = 环：必须报错，且父子关系一个都没动。
  const cycleDrag = dParent !== null && dChild !== null ? dragRows(dParent, dChild) : false;
  add(
    "★ 拖到自己的后代上被拒：报错 EDIT.BAD_PARENT，父子关系不变",
    cycleDrag === true &&
      E.parentOf(dParent) === null &&
      E.parentOf(dChild) === dParent &&
      errEl !== null &&
      errEl.textContent.indexOf("EDIT.BAD_PARENT") >= 0 &&
      movesIn() === moves0 + 1,
    "cycleDrag=" + String(cycleDrag) + " parentOfParent=" + String(E.parentOf(dParent)) +
      " parentOfChild=" + String(E.parentOf(dChild)) + " err=" + String(errEl === null ? "?" : errEl.textContent),
  );

  const undoReparent = E.undo();
  const childWorld1 = dChild === null ? null : E.nodeWorld(dChild);
  add(
    "★★ 撤销拖放：回到原来的父，世界位置也回到原处",
    undoReparent.kind === "done" &&
      E.parentOf(dChild) === null &&
      childWorld0 !== null &&
      childWorld1 !== null &&
      Math.abs(childWorld1.x - childWorld0.x) < 1e-6 &&
      Math.abs(childWorld1.y - childWorld0.y) < 1e-6,
    JSON.stringify(undoReparent) + " parent=" + String(E.parentOf(dChild)) +
      " world=" + JSON.stringify(childWorld1) + "（拖之前 " + JSON.stringify(childWorld0) + "）",
  );

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
