/**
 * L4 · UI 事件判据
 *
 * 三条语义各自对应一类真实失效：
 *   ① 捕获：拖出去松手 → 不能算点击，但 up 仍要投给原目标；
 *   ② click 判定：同目标 **且** 位移小于阈值（缺任一条都会误判）；
 *   ③ 冒泡 + stopPropagation（缺了它，每个控件都要自己写"不归我管就往上交"）。
 *
 * ★ 断言用「事件类型序列」而不是"监听器被调用了几次"：
 *   前者能同时看出顺序（enter 在 down 之前、up 在 click 之前），后者不能。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Rect } from "../../src/foundation/math/index.ts";
import { buildUiTree, layoutTree, type UiNodeConfig } from "../../src/extensions/ui/layout.ts";
import { UiInputRouter, type UiEvent } from "../../src/extensions/ui/events.ts";

const BOUNDS = new Rect(0, 0, 400, 300);

/** root > btn(0,0,100×50, 可交互不透明) + blank(200,200,100×50) */
function scene(): ReturnType<typeof buildUiTree> {
  const cfg: UiNodeConfig = {
    id: "root",
    children: [
      { id: "btn", size: { w: 100, h: 50 }, interactive: true, opaque: true },
      { id: "blank", size: { w: 50, h: 50 }, offset: { x: 300, y: 200 }, interactive: true, opaque: true },
    ],
  };
  const tree = buildUiTree(cfg);
  layoutTree(tree, BOUNDS);
  return tree;
}

const types = (evts: readonly UiEvent[]): string[] => evts.map((e) => e.type);

test("按下 → pointerdown 冒泡到根；抬起同目标 → pointerup 后接 click", () => {
  const r = new UiInputRouter(scene());
  const down = r.update({ x: 10, y: 10, down: true });
  assert.ok(types(down).includes("pointerdown"));

  const delivered: Array<[string, string]> = [];
  const up = r.update({ x: 10, y: 10, down: false }, (ev) => {
    delivered.push([ev.type, ev.currentTarget.id]);
  });
  assert.deepEqual(types(up).filter((t) => t !== "pointermove"), ["pointerup", "click"]);
  // 冒泡：先按钮、后根
  assert.deepEqual(
    delivered.filter(([t]) => t === "click").map(([, id]) => id),
    ["btn", "root"],
    "click 必须从目标冒到根",
  );
});

test("★ 拖出去再松手：有 pointerup，但**不能**算 click", () => {
  const r = new UiInputRouter(scene());
  r.update({ x: 10, y: 10, down: true });
  r.update({ x: 200, y: 150, down: true }); // 拖到按钮外
  const evts = r.update({ x: 200, y: 150, down: false });
  const ts = types(evts).filter((t) => t !== "pointermove");
  assert.ok(ts.includes("pointerup"), "抬起事件仍要投给捕获目标（否则控件收不到结束信号）");
  assert.equal(ts.includes("click"), false, "在同目标之外松手不能触发点击");
  // up 的目标必须是**原按钮**，不是松手位置的空白
  const up = evts.find((e) => e.type === "pointerup");
  assert.equal(up?.target.id, "btn");
});

/** root > a(0,0,100×50) + b(100,0,100×50)：两个可交互控件**紧贴**，中间没有缝 */
function adjacent(): ReturnType<typeof buildUiTree> {
  const cfg: UiNodeConfig = {
    id: "root",
    children: [
      { id: "a", size: { w: 100, h: 50 }, interactive: true, opaque: true },
      { id: "b", size: { w: 100, h: 50 }, offset: { x: 100, y: 0 }, interactive: true, opaque: true },
    ],
  };
  const tree = buildUiTree(cfg);
  layoutTree(tree, BOUNDS);
  return tree;
}

test("★ 位移在阈值内、但松手落在**另一个**控件上：不是 click", () => {
  // ★ 这条补的是一个 2×2 矩阵的缺格，而缺格的原因很值得记：
  //   click 的条件是「同目标 **且** 位移 ≤ 阈值」，两个条件各写一条用例是不够的 ——
  //   「同目标」那条固定住位移、「超阈值」那条固定住目标，于是**两个条件的合取
  //   从未被真正测到**。M285（去掉同目标校验）就是从这个空档里穿过去的：
  //   变异后所有既有用例依然全绿，因为没有任何一条**同时**满足
  //   "位移很小" 和 "按下与抬起不是同一个控件"。
  //   真实的坏结果也很具体：两个挨着的按钮，手指按住 A 抖 3px 滑到 B，
  //   A 没反应、B 被点了。
  const r = new UiInputRouter(adjacent()); // 默认阈值 8
  r.update({ x: 98, y: 20, down: true }); // 在 a 上，距右边界 2px
  const evts = r.update({ x: 101, y: 20, down: false }); // 位移 3px，已落在 b 上
  const ts = types(evts).filter((t) => t !== "pointermove");
  assert.ok(ts.includes("pointerup"), "抬起照样要投出去");
  assert.equal(
    ts.includes("click"),
    false,
    "同目标才叫点击：位移只有 3px，但按下的地方和抬起的地方是两个不同控件",
  );
  // 而且 up 必须投给按下时锁定的那个，不是松手位置命中的那个 —— 否则 B 会收到
  // 一个"从没按下过的抬起"，比多点一次更糟。
  const up = evts.find((e) => e.type === "pointerup");
  assert.equal(up?.target.id, "a", "抬起事件投给按下时锁定的控件，不是松手位置的命中");
});

test("★ 拖出去又拖回来（位移仍在阈值内）：算 click", () => {
  const r = new UiInputRouter(scene(), { dragThreshold: 40 });
  r.update({ x: 10, y: 10, down: true });
  r.update({ x: 300, y: 250, down: true });
  r.update({ x: 14, y: 12, down: true });
  const evts = r.update({ x: 14, y: 12, down: false });
  // 位移 = 4 ≤ 40 ⇒ 是点击（"拖出去再回来"在 UI 上就是按下-抬起，不算拖拽）
  assert.ok(types(evts).includes("click"));
});

test("★ 同目标但位移超阈值：是拖拽，不是 click（阈值为 8）", () => {
  const r = new UiInputRouter(scene());
  r.update({ x: 10, y: 10, down: true });
  r.update({ x: 60, y: 40, down: true }); // 仍在按钮矩形内，但移动了 58
  const evts = r.update({ x: 60, y: 40, down: false });
  const ts = types(evts);
  assert.ok(ts.includes("pointerup"));
  assert.equal(ts.includes("click"), false, "位移 58 > 阈值 8，这是拖拽");
});

test("悬停：移入产生 enter，移出产生 leave，且只在该变化的那一帧产生", () => {
  const r = new UiInputRouter(scene());
  const first = types(r.update({ x: 10, y: 10, down: false }));
  assert.ok(first.includes("pointerenter"));
  const same = types(r.update({ x: 12, y: 12, down: false }));
  assert.equal(same.includes("pointerenter"), false, "没换目标就不该重复 enter");

  const out = types(r.update({ x: 150, y: 150, down: false }));
  assert.ok(out.includes("pointerleave"));
  assert.equal(r.hovered, null);
});

test("stopPropagation 截断冒泡", () => {
  const r = new UiInputRouter(scene());
  const seen: string[] = [];
  r.update({ x: 10, y: 10, down: true }, (ev) => {
    seen.push(ev.currentTarget.id);
    if (ev.currentTarget.id === "btn") ev.stopPropagation();
  });
  // 该帧可能产生 enter / move / down 三个事件，每个都在 btn 处被截断 ——
  // 于是**没有任何一个**能到 root。断言"集合里只有 btn"而不是数个数：
  // 事件条数会随实现细节（是否发 move）变化，而"能不能冒到根"不该跟着变。
  assert.ok(seen.length > 0, "至少要投递一个事件，否则这条判据是空转");
  assert.deepEqual([...new Set(seen)], ["btn"], "btn 之后不该再收到");
});

test("点在空白处：没有 down/click，捕获为空", () => {
  const r = new UiInputRouter(scene());
  const evts = r.update({ x: 150, y: 150, down: true });
  assert.equal(types(evts).includes("pointerdown"), false);
  assert.equal(r.captured, null);
  const up = r.update({ x: 150, y: 150, down: false });
  assert.equal(types(up).includes("click"), false);
});

test("release() 清掉捕获：失焦后不应还认为在拖拽", () => {
  const r = new UiInputRouter(scene());
  r.update({ x: 10, y: 10, down: true });
  assert.equal(r.captured?.id, "btn");
  r.release();
  assert.equal(r.captured, null);
  const evts = r.update({ x: 10, y: 10, down: false });
  assert.equal(types(evts).includes("click"), false, "释放捕获后抬起不再补发 click");
});

test("事件坐标原样透传（设计坐标，不再换算）", () => {
  const r = new UiInputRouter(scene());
  const evts = r.update({ x: 33.5, y: 12.25, down: true });
  const down = evts.find((e) => e.type === "pointerdown");
  assert.equal(down?.x, 33.5);
  assert.equal(down?.y, 12.25);
});

test("同一帧里 down 与 up 都到位（极快的点击）也能产生 click", () => {
  const r = new UiInputRouter(scene());
  r.update({ x: 10, y: 10, down: true });
  const evts = r.update({ x: 10, y: 10, down: false });
  assert.ok(types(evts).includes("click"));
});
