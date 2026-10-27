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

  // ---- 资产浏览器（批86）
  // 清单是一次 HTTP 读、在启动时发起 ⇒ 这里等一下（最多 3 秒）。
  // 不等的话会读到空目录，而这批新加的判据会红在一个与资产无关的地方。
  for (let i = 0; i < 60 && E.assetInfo().count === 0; i++) await sleep(50);
  const ai = E.assetInfo();
  const aRows = document.querySelectorAll("#assetlist .arow").length;
  add(
    "资产面板列出了清单里的文件（条数、DOM 行数、可加入数三者对得上）",
    // 12 = 14 个文件里除掉两个非位图（ui-font.fnt / ui-skin.json）
    ai.count === 14 && aRows === 14 && ai.usable === 12,
    "count=" + ai.count + " rows=" + aRows + " usable=" + ai.usable + " problem=" + String(ai.problem),
  );

  // ★★ 这一批的核心观测点：图集是**从 web/assets 烘出来的**，不是程序化假贴图。
  //   两者在画面上**长得一样**（都有树有石头），只有这个数字分得开 ——
  //   来源是「procedural」意味着 10 张真图全都没读到，而没人会报错。
  add(
    "★★ 图集来自真实资产（不是程序化兜底），且帧数对得上",
    ai.atlasSource === "assets" && ai.frames === 12 && String(ai.atlasNote).length > 0,
    "source=" + ai.atlasSource + " frames=" + ai.frames + " note=" + ai.atlasNote,
  );

  // ★★ 生物帧：程序化图集里**没有** rabbit / hound ⇒ 编辑器世界里
  //   "生物在走但看不见"（渲染只 warn 一次）。这条钉的就是那个缺陷不再回来。
  const names = E.assets().map((a) => a.name);
  add(
    "★★ 生物用的帧真的在图集里（rabbit / hound —— 否则有东西在动却看不见）",
    names.indexOf("rabbit") >= 0 && names.indexOf("hound") >= 0 &&
      E.assetPick("hound.png") === true,
    "names=" + names.join(","),
  );

  // ★ 这一条是「别让人点了没反应」的前半：无帧的资产要在**列表里**就看得出来，
  //   而不是等他点完「加入场景」再读一行红字。
  //   语料用 ui-font.fnt：它是**文本**资产，名字与 ui-font.png 撞了 ——
  //   只看帧名的话它会被算成「有帧」，点下去就造出一个指向字体图的精灵。
  const noFrame = E.assets().filter((a) => !a.inAtlas).map((a) => a.path);
  const pickFnt = E.assetPick("ui-font.fnt");
  const addBtn = document.getElementById("asset-add");
  add(
    "★ 无帧的资产被标出来（ui-font.fnt 是文本，按钮也就不可用）",
    noFrame.length === 2 && noFrame.indexOf("ui-font.fnt") >= 0 && pickFnt === false &&
      addBtn.disabled === true,
    "noFrame=" + noFrame.join(",") + " pickable=" + String(pickFnt) + " btnDisabled=" + String(addBtn.disabled),
  );

  const nodesBefore = E.stats().nodes;
  const pickHound = E.assetPick("hound.png");
  const added = E.assetAdd("hound.png");
  const pTree = E.panel();
  const frameField = findField(pTree, "render.sprite", "frame");
  add(
    "★★ 加入场景：节点 +1、精灵挂上、帧也写进去了",
    pickHound === true && added.ok === true && E.stats().nodes === nodesBefore + 1 &&
      frameField !== null && frameField.value === "hound",
    JSON.stringify(added) + " nodes=" + E.stats().nodes + " frame=" +
      JSON.stringify(frameField ? frameField.value : null),
  );

  // ★ 一次撤销要退掉**整件事**：节点 + 精灵。压两条历史的话这里只剩一个空节点，
  //   而画面上什么都没少（那个节点没精灵）。
  const undoAdd = E.undo();
  add(
    "★★ 撤销一次：节点退回（加资产是一条历史，不是两条）",
    undoAdd.kind === "done" && E.stats().nodes === nodesBefore,
    JSON.stringify(undoAdd) + " nodes=" + E.stats().nodes,
  );

  const rejected = E.assetAdd("ui-font.fnt");
  const errText = document.getElementById("err").textContent || "";
  add(
    "★ 无帧的资产被拒：错误码对、节点数不变、错误行有字",
    rejected.ok === false && rejected.code === "EDIT.NO_FRAME" && E.stats().nodes === nodesBefore &&
      errText.length > 0,
    JSON.stringify(rejected) + " nodes=" + E.stats().nodes + " err=" + errText.slice(0, 60),
  );

  // ---------------- 拖资产到画布（批89）：落点必须是指针，不是视图中心
  //
  // ★ 用合成 PointerEvent 走**真实**那条接线（与场景树拖放同一个理由）：
  //   命令面直接传坐标只能验"落点算得对"，验不到"拖拽有没有接上"。
  const cvRect = document.getElementById("cv").getBoundingClientRect();
  const dragAssetTo = (path, clientX, clientY) => {
    const row = document.querySelector('.arow[data-path="' + path + '"]');
    if (!row) return false;
    const rr = row.getBoundingClientRect();
    const sx = rr.left + 4;
    const sy = rr.top + rr.height / 2;
    row.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, button: 0, clientX: sx, clientY: sy }));
    // 先动几像素越过阈值（否则按"这只是一次点击"处理，与双击加资产打架）
    document.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: sx + 10, clientY: sy + 4 }));
    document.dispatchEvent(new PointerEvent("pointermove", { bubbles: true, clientX: clientX, clientY: clientY }));
    document.dispatchEvent(new PointerEvent("pointerup", { bubbles: true, clientX: clientX, clientY: clientY }));
    return true;
  };
  const P1 = { x: Math.round(cvRect.width * 0.32), y: Math.round(cvRect.height * 0.66) };
  const P2 = { x: Math.round(cvRect.width * 0.72), y: Math.round(cvRect.height * 0.28) };
  const W1 = E.screenToWorld(P1.x, P1.y);
  const W2 = E.screenToWorld(P2.x, P2.y);
  const WCenter = E.screenToWorld(cvRect.width / 2, cvRect.height / 2);

  const nDrop0 = E.stats().nodes;
  const okDrag1 = dragAssetTo("rock.png", cvRect.left + P1.x, cvRect.top + P1.y);
  const prim1 = E.stats().primary;
  const drop1 = prim1 === null ? null : E.pos(prim1);
  const nearCenter1 =
    drop1 === null ? true : Math.abs(drop1.x - WCenter.x) < 1e-4 && Math.abs(drop1.z - WCenter.z) < 1e-4;
  add(
    "★★ 拖资产到画布：节点 +1，且落在**指针**那个世界点上（不是视图中心）",
    okDrag1 && E.stats().nodes === nDrop0 + 1 && drop1 !== null &&
      Math.abs(drop1.x - W1.x) < 1e-4 && Math.abs(drop1.z - W1.z) < 1e-4 && !nearCenter1,
    "nodes " + nDrop0 + "->" + E.stats().nodes + " pos=" + JSON.stringify(drop1) +
      " 期望 " + JSON.stringify(W1) + " 中心=" + JSON.stringify(WCenter),
  );

  // 换个落点再拖一个：位置差必须等于世界点之差（常数偏移的实现会在这里露馅）
  const okDrag2 = dragAssetTo("tree.png", cvRect.left + P2.x, cvRect.top + P2.y);
  const prim2 = E.stats().primary;
  const drop2 = prim2 === null ? null : E.pos(prim2);
  add(
    "★ 换个落点：两个节点的位置差 = 两个世界点的差（落点真的跟着指针走）",
    okDrag2 && drop1 !== null && drop2 !== null &&
      Math.abs(drop2.x - drop1.x - (W2.x - W1.x)) < 1e-4 &&
      Math.abs(drop2.z - drop1.z - (W2.z - W1.z)) < 1e-4,
    "Δpos=" + JSON.stringify(drop1 !== null && drop2 !== null ? { x: drop2.x - drop1.x, z: drop2.z - drop1.z } : null) +
      " Δworld=" + JSON.stringify({ x: W2.x - W1.x, z: W2.z - W1.z }),
  );

  // 松手在画布外（属性面板上）：一个节点都不该多出来，而且要留一句人话
  const nOutside0 = E.stats().nodes;
  const propsRect = document.getElementById("props").getBoundingClientRect();
  const okDrag3 = dragAssetTo("berry.png", propsRect.left + 8, propsRect.top + 8);
  const cntText = document.getElementById("assetcount").textContent || "";
  add(
    "★ 松手在画布外：不加节点，并且留一句说明（不是静默丢掉）",
    okDrag3 && E.stats().nodes === nOutside0 && cntText.indexOf("没落") >= 0,
    "nodes=" + E.stats().nodes + " count=" + cntText.slice(0, 40),
  );

  // 无帧的资产拖不动：与按钮同一个条件（inAtlas），松开之后场景里什么都不该多
  const nNoFrame0 = E.stats().nodes;
  const okDrag4 = dragAssetTo("ui-font.fnt", cvRect.left + P1.x, cvRect.top + P1.y);
  add(
    "★ 无帧的资产拖不动（拖动与按钮受同一个条件约束）",
    okDrag4 && E.stats().nodes === nNoFrame0,
    "nodes=" + E.stats().nodes,
  );

  // ---------------- 试玩（PIE）：世界真的会动，而且试玩改的东西会回滚
  //
  // ★ 这一组盯的是一个**整整漏掉的接线**：控制器模块两个宿主都装了、都每 tick 驱动，
  //   但 src/ 里没有任何一处把 game.controller 挂到节点上 ⇒ driven 恒为 0 ⇒
  //   按 WASD 谁也不动。模块单测是绿的（它自己造了带控制器的节点），
  //   **接线问题 Node 证不到**，只能在这里证。
  //
  // ★ 整段是同步的（中间没有 await sleep）：requestAnimationFrame 不会插进来，
  //   于是"走几步"就是真的只走了这几步，判据不会因为机器快慢而时红时绿。
  E.stop(); // 先把可能残留的会话关掉（前一节加资产/撤销都不该留下会话）
  const heroId = E.hero();
  const heroPos0 = heroId >= 0 ? E.pos(heroId) : null;
  add(
    "玩家节点存在（试玩要靠它验证『世界真的会动』）",
    heroId >= 0 && heroPos0 !== null,
    "hero=#" + heroId + " pos=" + JSON.stringify(heroPos0),
  );

  const docBeforePlay = E.docSave();
  const t0Play = docBeforePlay.text;
  const undoLen0 = E.history().undo.length;
  // ★ 基线现读，不写魔法数字：控制器默认速度是 4.5（见 PlayerController.speed），
  //   把它硬编码进判据的话，改一次默认值就会红，而红的原因跟回滚毫无关系 ——
  //   "期望值写错"和"功能坏了"必须能一眼分开。
  E.select(heroId);
  const speed0 = findField(E.panel(), "game.controller", "speed");
  add(
    "玩家身上有 game.controller.speed（运行时改属性的靶子）",
    speed0 !== null,
    JSON.stringify(speed0 ? speed0.value : null),
  );

  // ★★ **先按住键再单步第一帧**，顺序不能反。
  //   反过来的话第一帧没按键 ⇒ 世界一个字节都没变 ⇒ "会话快照拍在哪一刻"这件事
  //   在这条判据里**没有可观察差异**（变异 M403 就是在这一步假绿的）：
  //   把 beginPlay 改成"每次 step 都重拍"照样绿，因为它拍到的和原来一样。
  //   先按键，第一帧就把世界弄脏 ⇒ 重拍快照的人会把基准拍在脏之后 ⇒ 红。
  const KEY = "KeyD";
  window.dispatchEvent(new KeyboardEvent("keydown", { code: KEY, bubbles: true }));
  E.step(1); // 开会话（快照在这一帧之前）→ 走一帧（这一帧就挪了）⇒ 控制器真的被驱动过
  const info1 = E.playInfo();
  add(
    "★★ 试玩里控制器真的驱动到了节点（driven > 0 —— 玩家不是只挂了个标记）",
    info1.driven > 0 && info1.active === true,
    "driven=" + info1.driven + " active=" + String(info1.active),
  );

  // 再单步 10 帧 ⇒ 玩家位置必须变。
  // ★ 这条同时证三件事：控制器挂上了、按键接到了输入后端、位移真的写回了节点。
  E.step(10);
  window.dispatchEvent(new KeyboardEvent("keyup", { code: KEY, bubbles: true }));
  const heroPos1 = E.pos(heroId);
  add(
    "★★ 按住方向键单步：玩家真的挪了（不是只有 tick 在涨）",
    heroPos0 !== null && heroPos1 !== null && Math.abs(heroPos1.x - heroPos0.x) > 0.05,
    "x " + (heroPos0 ? heroPos0.x.toFixed(3) : "?") + " -> " + (heroPos1 ? heroPos1.x.toFixed(3) : "?"),
  );

  // 试玩期间改一个字段：立刻生效（这就是「运行时改属性」的一半）
  const speedSet = E.setField(heroId, "game.controller", "speed", 9);
  const editsLive = E.playInfo().edits;
  add(
    "★ 试玩期间改组件字段：立刻写进世界，并且记在会话账上",
    speedSet.ok === true && speedSet.value === 9 && editsLive === 1,
    JSON.stringify(speedSet) + " edits=" + editsLive,
  );

  // 停止试玩 ⇒ 世界回滚到进播放那一刻，文档逐字节回去
  const stop1 = E.stop();
  const docAfterStop = E.docSave().text;
  E.select(heroId);
  const speedAfter = findField(E.panel(), "game.controller", "speed");
  add(
    "★★ 停止试玩：试玩期间改的字段被回滚，文档逐字节回到进播放前",
    stop1.ok === true && stop1.rolledBack === true && docAfterStop === t0Play &&
      speedAfter !== null && speed0 !== null && speedAfter.value === speed0.value,
    JSON.stringify(stop1) + " docSame=" + String(docAfterStop === t0Play) +
      " speed=" + JSON.stringify(speedAfter ? speedAfter.value : null) +
      " 期望 " + JSON.stringify(speed0 ? speed0.value : null),
  );

  // ★ 试玩期间的改动不该进撤销栈：历史记的是**文档**，而试玩没改文档。
  //   塞进去的后果不是"多一条"，而是下一次撤销会把一个已经不存在的变化重放一遍。
  add(
    "★ 试玩期间的改动没进撤销栈（历史条数不变）",
    E.history().undo.length === undoLen0,
    "undo " + undoLen0 + " -> " + E.history().undo.length,
  );

  // ★ 没让世界跑就停止 ⇒ 不重建场景。重建那一步是 loadScene：它先 clear 再重建所有节点，
  //   "点一下播放又立刻停"却把整个工程换一遍实例，画面上完全看不出来。
  E.step(0);
  const stopClean = E.stop();
  add(
    "★ 世界没变时停止试玩：不重建场景（rolledBack=false）",
    stopClean.ok === true && stopClean.rolledBack === false && stopClean.edits === 0,
    JSON.stringify(stopClean),
  );

  // ---------------- 工程（多场景，批90）
  //
  // ★ 放在**最后**：这一组会真的把整个场景换掉，放前面会让后面的判据面对另一份世界。
  // ★ 也必须在 E.stop() 之后：试玩会话还开着时切场景会被拒（那本身就是最后一条判据）。
  //
  // ★★ 这一组最要紧的观测点是 nodeSerial：节点 id 写在文档里，切走再切回**id 一模一样**，
  //   但 Node 实例已经被 scene.clear() 换成新的了。只看 id / 名字 / 节点数，
  //   「重建了」和「没重建」是同一个结果 —— 那就是假绿。
  const hasNodeNamed = (nm) => E.outline().some((r) => r.name === nm);
  // ★★ 面板必须**真的画出来**。上面所有断言走的都是命令面（E.scenes()），
  //   而命令面读的是模型 —— 面板没接上（refreshScenes 忘了调、少了某一行 DOM）
  //   时它们**全绿**，而人打开页面看到的是一块空列表。所以这里读 DOM。
  const srows = () => document.querySelectorAll("#scenelist .srow").length;
  const selNames = () => [...document.querySelectorAll("#scenelist .srow.sel")].map((e) => e.dataset.name);
  const sc0 = E.scenes();
  add(
    "工程里已经有一份场景（列表非空，当前项就是列表里那个）",
    sc0.list.length === 1 && sc0.current === sc0.list[0] && sc0.current.length > 0 &&
      srows() === 1 && selNames().length === 1 && selNames()[0] === sc0.current,
    JSON.stringify(sc0) + " 面板行数=" + srows() + " 高亮=" + JSON.stringify(selNames()),
  );

  const heroSerial0 = heroId >= 0 ? E.nodeSerial(heroId) : -1;
  E.select(heroId);
  const undoN0 = E.history().undo.length;
  const selfSwitch = E.sceneSwitch(sc0.current);
  add(
    "★★ 切到当前场景：noop（节点实例一个都没换，历史与选中也都还在）",
    selfSwitch.ok === true && selfSwitch.kind === "noop" &&
      heroSerial0 > 0 && E.nodeSerial(heroId) === heroSerial0 &&
      E.history().undo.length === undoN0 && E.stats().selected.length === 1,
    JSON.stringify(selfSwitch) + " serial " + heroSerial0 + "->" + E.nodeSerial(heroId) +
      " undo=" + E.history().undo.length + "（期望 " + undoN0 + "）sel=" + E.stats().selected.length,
  );

  // 在 main 里留一处**没有保存**的改动：切走时若不保存它，切回来就没了
  const addM = E.addNode("只属于 main");
  const created = E.sceneNew();
  const sc1 = E.scenes();
  add(
    "★★ 新建场景：列表 +1、当前切到新场景，而且新场景是空的（只剩根）",
    addM.ok === true && created.ok === true && sc1.list.length === 2 && sc1.current === created.name &&
      E.stats().nodes === 1 && E.outline().length === 1 &&
      srows() === 2 && selNames().length === 1 && selNames()[0] === created.name,
    JSON.stringify(created) + " list=" + JSON.stringify(sc1.list) + " current=" + sc1.current +
      " nodes=" + E.stats().nodes + " 面板行数=" + srows() + " 高亮=" + JSON.stringify(selNames()),
  );

  // 新场景里也放一个自己的节点（用来验两边不会互相覆盖）
  const addS = E.addNode("只属于新场景");

  const backM = E.sceneSwitch("main");
  add(
    "★★ 切回 main：切走时自动保存了，那个没保存的节点还在；新场景的节点没有跟过来",
    addS.ok === true && backM.ok === true && backM.kind === "switched" &&
      hasNodeNamed("只属于 main") && !hasNodeNamed("只属于新场景") &&
      E.nodeSerial(heroId) !== heroSerial0,
    JSON.stringify(backM) + " main=" + String(hasNodeNamed("只属于 main")) +
      " 串场=" + String(hasNodeNamed("只属于新场景")) +
      " serial " + heroSerial0 + "->" + E.nodeSerial(heroId),
  );

  const backS = E.sceneSwitch(created.name);
  add(
    "★★ 再切回新场景：它自己的节点也还在（两份文档谁也不会覆盖谁）",
    backS.ok === true && hasNodeNamed("只属于新场景") && !hasNodeNamed("只属于 main"),
    JSON.stringify(backS) + " 新场景=" + String(hasNodeNamed("只属于新场景")) +
      " 串场=" + String(hasNodeNamed("只属于 main")),
  );

  const dropped = E.sceneDelete();
  add(
    "★★ 删掉当前场景：切到邻居（main），列表回到 1 项，场景里是 main 的内容",
    dropped.ok === true && E.scenes().list.length === 1 && E.scenes().current === "main" &&
      hasNodeNamed("只属于 main") && !hasNodeNamed("只属于新场景") &&
      srows() === 1 && selNames()[0] === "main",
    JSON.stringify(dropped) + " list=" + JSON.stringify(E.scenes().list) +
      " current=" + E.scenes().current + " 面板行数=" + srows() + " 高亮=" + JSON.stringify(selNames()),
  );

  const droppedLast = E.sceneDelete();
  add(
    "★ 只剩一个场景时删除被拒（EDIT.LAST_SCENE），列表一个字节都没动",
    droppedLast.ok === false && droppedLast.code === "EDIT.LAST_SCENE" &&
      E.scenes().list.length === 1 && E.scenes().current === "main" &&
      srows() === 1 &&
      document.getElementById("scene-del").disabled === true,
    JSON.stringify(droppedLast) + " list=" + JSON.stringify(E.scenes().list) +
      " 面板行数=" + srows() + " 删除按钮 disabled=" + String(document.getElementById("scene-del").disabled),
  );

  // ★★ 试玩期间切场景必须被拒：endPlaySession 的回滚会把**进试玩那一刻**的文档装回去，
  //   而那时场景已经是另一份了 —— 静默数据错乱。所以宁可"切不动"。
  const serialBeforeBusy = E.nodeSerial(heroId);
  E.step(1); // 开一个试玩会话（这一步一定会让它存在）
  const busy = E.sceneNew();
  const serialBusy = E.nodeSerial(heroId);
  const toStop = E.scenes().list.length;
  E.stop();
  add(
    "★★ 试玩期间切场景被拒（EDIT.PLAYING），场景一个节点实例都没动",
    busy.ok === false && busy.code === "EDIT.PLAYING" && serialBusy === serialBeforeBusy &&
      toStop === 1 && E.scenes().list.length === 1 && srows() === 1,
    JSON.stringify(busy) + " serial " + serialBeforeBusy + "->" + serialBusy +
      " list=" + E.scenes().list.length + " 面板行数=" + srows(),
  );

  // ================================================================ 存档（落盘）
  // ★ 上面那些验的都是**模型层**（工程对象里多了一份、当前项换了）。这一段验的是
  //   "存档媒介里真的有东西" —— 面板上写着「已存 1234 字节」而 localStorage 是空的，
  //   是最典型的一类假绿：判据全绿，关掉页面什么都没了。
  const PKEY = "dst.editor.project.v1";
  const archText = () => localStorage.getItem(PKEY);
  const archParsed = () => {
    try {
      return JSON.parse(archText() || "null");
    } catch (e) {
      return null;
    }
  };
  const sInfo0 = E.saveInfo();
  const archRaw = archText();
  const sp0 = archParsed();
  add(
    "★★ 存档真的落在 localStorage 里（键在、字节数与面板一致、内容是一份工程）",
    archRaw !== null && sInfo0.storedBytes > 0 &&
      new TextEncoder().encode(archRaw).length === sInfo0.storedBytes &&
      sp0 !== null && sp0.format === "dst.editor.project" && sp0.current === "main" &&
      Array.isArray(sp0.scenes) && sp0.scenes.length === 1 && sp0.scenes[0].name === "main",
    "bytes=" + sInfo0.storedBytes + " note=" + sInfo0.note + " 解析=" +
      (sp0 === null ? "失败" : sp0.scenes.length + " 场景 / current=" + sp0.current),
  );

  const persistNode = E.addNode("落盘之后才加的");
  const sp1 = archParsed();
  add(
    "★★ 加一个节点之后存档里有它（存的是**当前**内容，不是上次切场景时那份）",
    persistNode.ok === true && sp1 !== null &&
      sp1.scenes.some((r) => r.name === "main" && r.text.indexOf("落盘之后才加的") >= 0),
    "node=" + JSON.stringify(persistNode) + " 存档里有=" +
      (sp1 === null ? "解析失败" : String(sp1.scenes.some((r) => r.text.indexOf("落盘之后才加的") >= 0))),
  );

  const bytesBeforePlay = E.saveInfo().storedBytes;
  const nodesBeforePlay = E.stats().nodes;
  E.step(1); // 开一个试玩会话
  const inPlayNode = E.addNode("试玩中加的");
  const nodesInPlay = E.stats().nodes;
  const noteInPlay = E.saveInfo().note;
  const bytesInPlay = E.saveInfo().storedBytes;
  E.stop(); // 停播 ⇒ 回滚，那个节点会消失
  add(
    "★★ 试玩期间不写存档（世界被控制器跑过、被临时改过，那不是文档）",
    inPlayNode.ok === true && nodesInPlay === nodesBeforePlay + 1 &&
      bytesInPlay === bytesBeforePlay && noteInPlay.indexOf("试玩") >= 0,
    "节点 " + nodesBeforePlay + "->" + nodesInPlay + " 存档 " + bytesBeforePlay + "->" + bytesInPlay +
      " note=" + noteInPlay,
  );

  const madeD = E.sceneNew("落盘场景");
  const markD = E.addNode("落盘标记");
  const sp2 = archParsed();
  add(
    "★★ 新建的场景连内容一起进存档（2 个场景、当前是新场景、两份文本各归各的）",
    madeD.ok === true && markD.ok === true && sp2 !== null && sp2.scenes.length === 2 &&
      sp2.current === "落盘场景" &&
      sp2.scenes.some((r) => r.name === "落盘场景" && r.text.indexOf("落盘标记") >= 0) &&
      sp2.scenes.some((r) => r.name === "main" && r.text.indexOf("落盘之后才加的") >= 0),
    "made=" + JSON.stringify(madeD) + " 存档=" +
      (sp2 === null ? "解析失败" : sp2.scenes.length + " 场景 / current=" + sp2.current),
  );

  const backD = E.sceneSwitch("main");
  const sp3 = archParsed();
  add(
    "★ 切回 main 之后存档的当前项也跟着变（存档与工程说的是同一件事）",
    backD.ok === true && sp3 !== null && sp3.current === "main" && sp3.scenes.length === 2,
    "back=" + JSON.stringify(backD) + " 存档 current=" + (sp3 === null ? "解析失败" : sp3.current) +
      " 场景数=" + (sp3 === null ? "?" : sp3.scenes.length),
  );

  // ---------------- 试玩中的跳转（批92）
  //
  // ★ 三条各验一件事，不许互相顶替：
  //   ① 不在试玩里调 playJump 要被拒（"试玩是沙盒"这个前提本身要能验）；
  //   ② 命令面跳转 + 携带 + 停播回滚（跳转一个槽位都不写）；
  //   ③ ★★ 玩家脚下有门 ⇒ 推进一步就自动跳。只验 ② 的话，门这一整套
  //      （collectPortals / PortalWatcher / autoPortal）可以一行都没接上而判据全绿。
  //
  // ★ 目标用已有的「落盘场景」而不是新建一个：这一段结束时工程必须还是 2 个场景
  //   （刷新之后那个探针就按这个数验），为了夹具再造一个场景会让后面的判据红在一个
  //   与它无关的数字上。
  const notPlaying = E.playJump("main");
  add(
    "★ 不在试玩中调 playJump 被拒（EDIT.NOT_PLAYING）—— 那时候该走场景面板",
    notPlaying.ok === false && notPlaying.code === "EDIT.NOT_PLAYING",
    JSON.stringify(notPlaying),
  );

  // 目标场景里造一个"像样"的玩家（标记 + 控制器 + 血 + 饥饿 + 背包）
  const inTgt = E.sceneSwitch("落盘场景");
  const tPlayer = E.addNode("player");
  const attached = ["world.player", "game.controller", "combat.health", "game.hunger", "game.inventory"]
    .map((t) => E.compAttach(t, tPlayer.id).ok);
  const tOnly = E.addNode("只在目标场景里");
  const backMain0 = E.sceneSwitch("main");
  add(
    "★ 目标场景里备好一个玩家（否则跳过去会 NO_SPAWN）",
    inTgt.ok === true && tPlayer.ok === true && attached.every((x) => x === true) &&
      tOnly.ok === true && backMain0.ok === true,
    "player=" + JSON.stringify(tPlayer) + " 组件=" + JSON.stringify(attached) +
      " tOnly=" + JSON.stringify(tOnly) + " back=" + JSON.stringify(backMain0),
  );

  // main 这边的玩家：血 7/10、饱食 50、背包里 5 个木头，脚下还有一扇通往目标的门
  const heroM = E.hero();
  E.select(heroM);
  E.compAttach("combat.health", heroM);
  E.setField(heroM, "combat.health", "hp", "7");
  E.setField(heroM, "combat.health", "maxHp", "10");
  E.compAttach("game.hunger", heroM);
  E.setField(heroM, "game.hunger", "value", "50");
  E.compAttach("game.inventory", heroM);
  const wood = E.addNode("item/wood");
  E.compAttach("game.item", wood.id);
  E.setField(wood.id, "game.item", "kind", "wood");
  E.setField(wood.id, "game.item", "count", "5");
  const door = E.compAttach("flow.portal", heroM);
  E.setField(heroM, "flow.portal", "to", "落盘场景");
  E.setField(heroM, "flow.portal", "radius", "1024");
  add(
    "★ 夹具：main 的玩家有血 / 饱食 / 背包，脚下有一扇通往「落盘场景」的门",
    wood.ok === true && door.ok === true && E.compCount("flow.portal", heroM) === 1,
    JSON.stringify({ wood, door }) + " portal=" + E.compCount("flow.portal", heroM),
  );

  E.step(1);
  const jumpedTo = E.playScene();
  const heroT = E.hero();
  E.select(heroT);
  const pnl = E.panel();
  const valOf = (type, key) => {
    const g = pnl.groups.find((x) => x.type === type);
    const f = g === undefined ? undefined : g.fields.find((x) => x.key === key);
    return f === undefined ? null : f.value;
  };
  const namesJump = E.outline().map((r) => r.name);
  const selRow = document.querySelector("#scenelist .srow.sel");
  add(
    "★★ 玩家脚下有一扇门：推进一步就自动跳过去（「每 tick 喂一次位置」这条接线真的接上了）",
    jumpedTo === "落盘场景" && namesJump.includes("只在目标场景里") &&
      !namesJump.includes("只属于 main"),
    "playScene=" + JSON.stringify(jumpedTo) + " 节点=" + JSON.stringify(namesJump),
  );
  add(
    "★★ 跳过去之后血 / 饱食 / 背包都跟着人走（不是「换了个人」）",
    valOf("combat.health", "hp") === 7 && valOf("game.hunger", "value") === 50 &&
      namesJump.includes("item/wood"),
    "hp=" + JSON.stringify(valOf("combat.health", "hp")) +
      " 饱食=" + JSON.stringify(valOf("game.hunger", "value")) +
      " 节点=" + JSON.stringify(namesJump),
  );
  add(
    "★★ 场景面板高亮「试玩现在在哪一份」并标着 ▶（世界换了，面板不能还停在原来那行）",
    selNames().length === 1 && selNames()[0] === "落盘场景" &&
      (selRow === null ? "" : selRow.textContent).indexOf("▶") > 0,
    "高亮=" + JSON.stringify(selNames()) + " 文案=" +
      JSON.stringify(selRow === null ? null : selRow.textContent),
  );

  const stoppedJ = E.stop();
  const namesBack = E.outline().map((r) => r.name);
  add(
    "★★ 停播回滚：工程回到进试玩那一刻（试玩里跳过的场景一个槽位都没被改写）",
    stoppedJ.ok === true && stoppedJ.rolledBack === true &&
      E.scenes().current === "main" && namesBack.includes("只属于 main") &&
      !namesBack.includes("只在目标场景里"),
    JSON.stringify(stoppedJ) + " current=" + E.scenes().current +
      " 节点=" + JSON.stringify(namesBack),
  );

  // ---- 路径 B：真实播放（requestAnimationFrame 驱动 loop）
  //
  // ★★ 为什么必须再来一遍：上面那次跳转走的是**命令面 E.step()**（直接推帧），
  //   而"人点播放按钮"走的是 loop() 里的 rAF 分支。这两条路**各自**要喂一次玩家位置，
  //   只验 step 那条的话，把 loop 里那一句删掉判据照样全绿 —— 而那正是人真正会用的那条路。
  //   （批89 的教训是"命令面判据 ≠ 接线判据"，这里是它的另一面：命令面判据只覆盖命令面。）
  E.play();
  const tPlay0 = Date.now();
  while (Date.now() - tPlay0 < 1500 && E.playScene() !== "落盘场景") {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const jumpedByPlay = E.playScene();
  E.pause();
  const stoppedP = E.stop();
  add(
    "★★ 点「播放」走进门也会跳（loop 那条帧路径与命令面 step 各喂一次）",
    jumpedByPlay === "落盘场景" && stoppedP.ok === true && stoppedP.rolledBack === true,
    "playScene=" + JSON.stringify(jumpedByPlay) + " stop=" + JSON.stringify(stoppedP) +
      " current=" + E.scenes().current,
  );

  // ---- 路径 C：关着的门（批95）
  //
  // ★★ 为什么必须**另起一段会话**，而不是塞进上面那一段：
  //   会话快照是在开播那一刻拍的。若在同一段里先关门再测，快照里门就是关着的，
  //   停播回滚会把门恢复成关着 —— 于是后面每一条用例都在"门关着的世界"里跑。
  //   我第一次就是这么写的，报错是 playScene 仍是 main，
  //   看起来像 loop 那条帧路径没接线（而上一条断言刚刚证明它接了）。
  //   **回滚点在哪，夹具的边界就在哪**：改世界的夹具要么整体在会话之外，要么单独一段。
  const shutSet = E.setField(E.hero(), "flow.portal", "open", "false");
  E.play();
  const tShut0 = Date.now();
  while (Date.now() - tShut0 < 1200 && E.playScene() !== "落盘场景") {
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  const shutScene = E.playScene();
  E.pause();
  const stoppedShut = E.stop();
  // 恢复成开着：后面的用例（存档/读档）还要用这扇门，而停播已经把世界回滚成
  // "门关着"的那一份（快照在关门之后才拍）。
  const reopen = E.setField(E.hero(), "flow.portal", "open", "true");
  add(
    "★ 门关着时真的走不过去：真播放 1.2 秒仍在原来那一关（关着的门不是「跳过去再跳回来」）",
    shutSet.ok === true && shutScene === "main" && stoppedShut.ok === true && reopen.ok === true,
    "set=" + JSON.stringify(shutSet) + " playScene=" + JSON.stringify(shutScene) +
      " 恢复=" + JSON.stringify(reopen),
  );

  // ---------------- 试玩存档：这一局能存、能读回去、走过的不重置（批93）
  //
  // ★ 四件事各验一次，不许互相顶替：
  //   ① 不在试玩里存档要被拒（"进度是玩出来的"这个前提本身要能验）；
  //   ② 存下来的东西**在媒介上**（对着 localStorage 核，不看面板自己的变量 —— 批91 的教训）；
  //   ③ ★★ 回访一个去过的场景不重置：这是我这一批的核心行为，而它只能在**接线层**看见
  //      —— Node 判据走的是模型层，证明不了命令面/按钮这条路真的接上了；
  //   ④ ★★ 读档回到存档里的那一关，且那一关的世界按存档恢复。
  const saveIdle = E.playSave();
  add(
    "★ 不在试玩中存档被拒（EDIT.NOT_PLAYING）—— 进度只在试玩里产生",
    saveIdle.ok === false && saveIdle.code === "EDIT.NOT_PLAYING",
    JSON.stringify(saveIdle),
  );

  // step(0)：开会话但一步都不推 —— 脚下那扇门会在推帧时立刻把人送走，这里要留在 main
  E.step(0);
  const psFirst = E.playSave();
  const psInfo0 = E.playSaveInfo();
  add(
    "★ 试玩中存档落在存档媒介上（字节数问的是 localStorage，不是面板上那句话）",
    psFirst.ok === true && psInfo0.bytes > 0 && psInfo0.current === "main" && psInfo0.scenes.length === 1,
    JSON.stringify(psFirst) + " 媒介=" + JSON.stringify(psInfo0),
  );

  // 跳去目标场景，在那一关留下一个"砍倒的树"
  const j1 = E.playJump("落盘场景");
  const heroJ = E.hero();
  E.select(heroJ);
  const chop = E.addNode("在目标场景里砍的树");
  const j2 = E.playJump("main");
  const j3 = E.playJump("落盘场景");
  const namesR = E.outline().map((r) => r.name);
  add(
    "★★ 回访一个去过的场景不重置（我砍掉的树还在，不是又按文档重建了）",
    j1.ok === true && j2.ok === true && j3.ok === true &&
      (j3.ok === true ? j3.reused : false) === true && namesR.includes("在目标场景里砍的树"),
    JSON.stringify({ j1, j2, j3 }) + " 节点=" + JSON.stringify(namesR),
  );

  const psSecond = E.playSave();
  const psInfo1 = E.playSaveInfo();
  add(
    "★ 存档记的是「这一局走过哪几关」（当前那一关 + 走过的那一关，共 2 份）",
    psSecond.ok === true && psInfo1.current === "落盘场景" && psInfo1.scenes.length === 2,
    JSON.stringify(psSecond) + " 媒介=" + JSON.stringify(psInfo1),
  );

  // 回到 main，再读档 ⇒ 人应该回到存档里的那一关，而"砍的树"还在
  const backForLoad = E.playJump("main");
  const loadedP = E.playLoad();
  const namesL = E.outline().map((r) => r.name);
  add(
    "★★ 读档：回到存档里的那一关（当前场景与那一关的世界都按存档恢复）",
    backForLoad.ok === true && loadedP.ok === true && E.playScene() === "落盘场景" &&
      namesL.includes("在目标场景里砍的树"),
    JSON.stringify(loadedP) + " playScene=" + JSON.stringify(E.playScene()) +
      " 节点=" + JSON.stringify(namesL),
  );

  const stopS = E.stop();
  add(
    "★★ 存档不动工程槽位：停播之后 current 还是 main（进度是进度，设计是设计）",
    stopS.ok === true && E.scenes().current === "main",
    JSON.stringify(stopS) + " current=" + E.scenes().current,
  );

  const backT = E.sceneSwitch("落盘场景");
  const hasOnly = E.outline().some((r) => r.name === "只在目标场景里");
  const backM2 = E.sceneSwitch("main");
  add(
    "★★ 跳转没有污染目标场景的槽位（切过去它自己的节点还在，当前项也回得来）",
    backT.ok === true && hasOnly === true && backM2.ok === true &&
      E.scenes().current === "main",
    JSON.stringify({ backT, backM2 }) + " 有只在目标里=" + String(hasOnly) +
      " current=" + E.scenes().current,
  );

  // ★ 清理：门是这一段的夹具，留在工程里会让「之后每次试玩一进去就跳」。
  const unDoor = E.compDetach("flow.portal", heroM);
  add(
    "★ 收尾：把夹具那扇门卸掉（否则之后每次试玩一进去就跳）",
    unDoor.ok === true && E.compCount("flow.portal", heroM) === 0,
    JSON.stringify(unDoor) + " 剩余门=" + E.compCount("flow.portal", heroM),
  );

  return rows;
})()
`;

/**
 * 刷新之后的探针（阶段 2）。
 *
 * ★ 必须**换一张页面**才能验"关掉再打开还在"：同一个 JS 上下文里的 `project` 变量
 *   本来就在，刷新才真的走一遍"读存档 → 装世界"。
 *   这一段的每一条都同时在验"启动时没有把默认世界写进存档"—— 真那么做了的话，
 *   刷新后只剩 1 个场景（默认世界的名字），而其余判据全绿。
 */
const PROBE2 = `
(async () => {
  const rows = [];
  const add = (name, ok, detail) => {
    rows.push({ name, ok: ok === true, detail: String(detail) });
  };
  const E = window.__editor;
  const PKEY = "dst.editor.project.v1";
  const raw = localStorage.getItem(PKEY);
  let parsed = null;
  try {
    parsed = JSON.parse(raw || "null");
  } catch (e) {
    parsed = null;
  }
  const sc = E.scenes();
  const want = ["main", "落盘场景"].sort().join(",");
  add(
    "★★ 刷新之后工程还在（2 个场景 / 当前是 main）—— 启动没有拿默认世界覆盖存档",
    raw !== null && parsed !== null && parsed.scenes.length === 2 &&
      sc.list.length === 2 && sc.list.slice().sort().join(",") === want && sc.current === "main",
    "list=" + JSON.stringify(sc.list) + " current=" + sc.current +
      " 存档场景数=" + (parsed === null ? "解析失败" : parsed.scenes.length),
  );

  const info = E.saveInfo();
  add(
    "★ 打开页面会说出「已恢复」（恢复这件事在界面上有痕迹，不是悄悄发生的）",
    info.note.indexOf("已恢复") >= 0 && info.storedBytes > 0,
    "note=" + info.note + " bytes=" + info.storedBytes,
  );

  // ★★ 这一条是 M421 逼出来的：原先只验"切过去能看到标记"，而**切场景本身**就会
  //   从槽位装载目标内容 ⇒ 就算启动时压根没装当前场景，那一条照样绿（假绿）。
  //   要验"打开页面装的是存档里 current 的那份"，只能在**不切场景**的前提下看当前场景里
  //   有没有那个只存在于存档的节点 —— 刚 boot 出来的世界根本没有它。
  const hasBoot = E.outline().some((r) => r.name === "落盘之后才加的");
  add(
    "★★ 打开页面装的是存档里**当前场景**的内容（不是刚 boot 出来那个世界）",
    hasBoot === true,
    "当前场景里有「落盘之后才加的」=" + String(hasBoot) +
      " 节点数=" + E.stats().nodes + " current=" + E.scenes().current,
  );

  const sw = E.sceneSwitch("落盘场景");
  const has = E.outline().some((r) => r.name === "落盘标记");
  add(
    "★★ 恢复出来的是**内容**不只是名字：切到「落盘场景」能看到刷新前加的那个节点",
    sw.ok === true && has === true && E.scenes().current === "落盘场景",
    JSON.stringify(sw) + " 有落盘标记=" + String(has) + " current=" + E.scenes().current,
  );

  // ★★ 试玩存档跨页面活着：进度如果不是落在媒介上，刷新一次就"回到第一关"了。
  //   这一条与上面几条验的不是同一件事：上面验"存了能读"，这里验"存的东西活过了刷新"。
  const pinfo = E.playSaveInfo();
  add(
    "★★ 刷新页面之后那一局的存档还在（当前场景 / 走过几关都活过了刷新）",
    pinfo.bytes > 0 && pinfo.current === "落盘场景" && pinfo.scenes.length === 2,
    JSON.stringify(pinfo),
  );

  return rows;
})()
`;

/**
 * 刷新同一张页面，再跑一遍 `PROBE2`。
 *
 * ★ 返回 `null` 表示"这一段没验到"（刷新失败 / 探针抛了），调用方必须把它当失败：
 *   把"没验"当成"验过了"，正是这个仓库最忌讳的那类假绿。
 */
async function reloadAndProbe(client) {
  try {
    await client.send("Page.enable");
    await client.send("Page.reload", { ignoreCache: true });
  } catch (e) {
    console.error(`  ! 刷新失败：${e instanceof Error ? e.message : String(e)}`);
    return null;
  }
  // 刷新会换掉 JS 上下文：`__editor` 要等新的一份 boot 完才出现。
  const deadline = Date.now() + 30_000;
  let ready = false;
  while (Date.now() < deadline) {
    await sleep(250);
    try {
      const r = await client.send("Runtime.evaluate", {
        expression: "!!(window.__editor && window.__editor.ready())",
        returnByValue: true,
      });
      if (r?.result?.value === true) {
        ready = true;
        break;
      }
    } catch {
      // 刷新瞬间旧上下文已经没了 —— 继续等，这不是失败。
    }
  }
  if (!ready) {
    console.error("  ! 刷新之后 30 秒内编辑器没有就绪");
    return null;
  }
  const r = await client.send("Runtime.evaluate", {
    expression: PROBE2,
    awaitPromise: true,
    returnByValue: true,
  });
  if (r?.exceptionDetails !== undefined) {
    console.error(`  ! 刷新后的探针抛异常：${r.exceptionDetails.exception?.description ?? r.exceptionDetails.text}`);
    return null;
  }
  const v = r?.result?.value;
  return Array.isArray(v) ? v : null;
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
    let rows = r?.result?.value ?? [];
    if (!Array.isArray(rows) || rows.length === 0) {
      console.error("✗ 探针没有返回任何断言结果");
      process.exit(EXIT_FAIL);
    }

    // ---------------- 阶段 2：刷新页面，验"关掉再打开还在"
    // ★ 只在阶段 1 全绿时才跑：阶段 1 已经红了的话，刷新只会把现场搅得更难读。
    if (rows.every((x) => x.ok === true)) {
      const more = await reloadAndProbe(client);
      if (more === null) {
        console.error("✗ 刷新之后的那一段没有跑起来 —— 存档恢复等于没验（不许拿阶段 1 全绿顶替）");
        process.exit(EXIT_FAIL);
      }
      rows = rows.concat(more);
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
