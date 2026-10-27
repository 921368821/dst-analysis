/**
 * 跨帧状态表判据（ADR-0012）
 *
 * 这张表要守的性质不是"能缓存"，而是**两类状态的失效时机不同**：
 *   派生（文本量算）可以随时丢；权威（滚动位置）丢了就是丢了。
 * 所以判据的重点全在"谁被清掉了"，而不是"值对不对"：
 *   · `invalidateDerived()` 只清派生 ⇒ 滚动位置必须还在；
 *   · `reset()` 两类都清 ⇒ 换界面/回滚之后不能读到上一份世界的值；
 *   · 键是 `uid` ⇒ 两个节点用同一段文本也**不共享**（改一个不改另一个）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Color } from "../../src/foundation/math/index.ts";
import { FontRegistry } from "../../src/extensions/ui/font.ts";
import { UiStateStore } from "../../src/extensions/ui/state.ts";
import { makeFontWith, makeTestFont } from "./ui-fixtures.ts";

function registry(): FontRegistry {
  const r = new FontRegistry();
  r.register(makeTestFont());
  return r;
}

/** 宽度断言用：夹具里每个非空格字形前进 12。 */
const ADV = 12;

test("同 uid 同键 ⇒ 第二次命中；命中数只涨在 hit 上", () => {
  const fonts = registry();
  const st = new UiStateStore();
  const a = st.text(1, fonts, "test", "ABC", {});
  const b = st.text(1, fonts, "test", "ABC", {});
  assert.equal(a?.width, 3 * ADV);
  assert.equal(a, b, "同一次排版应返回同一个对象（缓存真的生效）");
  assert.deepEqual([st.hits, st.misses], [1, 1]);
});

test("★ 改了文本 / 字号 / 颜色 / 换行宽，都不命中（键里各有一维）", () => {
  const fonts = registry();
  const st = new UiStateStore();
  st.text(1, fonts, "test", "AB", {});
  st.text(1, fonts, "test", "ABC", {});
  st.text(1, fonts, "test", "ABC", { scale: 2 });
  st.text(1, fonts, "test", "ABC", { scale: 2, color: new Color(1, 0, 0, 1) });
  st.text(1, fonts, "test", "ABC", { scale: 2, color: new Color(1, 0, 0, 1), maxWidth: 40 });
  assert.equal(st.misses, 5, "五次都该是未命中");
  assert.equal(st.hits, 0);
});

test("★ 键是 uid：两个节点用同一段文本**不共享**（改一个不该影响另一个）", () => {
  const fonts = registry();
  const st = new UiStateStore();
  const one = st.text(1, fonts, "test", "ABC", {});
  const two = st.text(2, fonts, "test", "ABC", {});
  assert.equal(st.misses, 2, "不同 uid 各排一次");
  // 改节点 1 的文本之后，节点 2 必须仍然拿到原来的排版
  const oneNew = st.text(1, fonts, "test", "A", {});
  assert.equal(oneNew?.width, ADV);
  assert.equal(two?.width, 3 * ADV);
  assert.equal(one?.width, 3 * ADV);
});

test("字体不存在 ⇒ null（不是空排版：空排版会让标签静默塌成 0 宽）", () => {
  const st = new UiStateStore();
  assert.equal(st.text(1, registry(), "nope", "AB", {}), null);
  assert.equal(st.misses, 0, "查不到字体不该记一次排版未命中");
});

test("forget 只丢指定的那个节点", () => {
  const fonts = registry();
  const st = new UiStateStore();
  st.text(1, fonts, "test", "AB", {});
  st.text(2, fonts, "test", "AB", {});
  st.forget(1);
  st.text(1, fonts, "test", "AB", {});
  st.text(2, fonts, "test", "AB", {});
  assert.equal(st.misses, 3, "1 被丢过 ⇒ 重排；2 仍命中");
  assert.equal(st.hits, 1);
  assert.equal(st.stats.evictions, 1);
});

// ── 两类状态的分界 ──────────────────────────────────────────

test("★★ invalidateDerived 只丢派生：滚动位置必须**保留**", () => {
  const fonts = registry();
  const st = new UiStateStore();
  st.text(1, fonts, "test", "AB", {});
  st.setScroll(7, 120);
  const epoch = st.epoch;
  st.invalidateDerived();
  assert.equal(st.epoch, epoch + 1, "代次 +1（旧代次的持有者能自查过期）");
  assert.equal(st.scrollOf(7), 120, "换字体不该让用户正看着的列表回顶");
  st.text(1, fonts, "test", "AB", {});
  assert.equal(st.misses, 2, "派生缓存确实被丢了");
});

test("★★ reset 两类都丢：回滚/换界面之后读不到上一份世界的值", () => {
  const fonts = registry();
  const st = new UiStateStore();
  st.setScroll(7, 120);
  st.text(1, fonts, "test", "AB", {});
  st.reset();
  assert.equal(st.scrollOf(7), 0);
  assert.equal(st.stats.layouts, 0);
  st.text(1, fonts, "test", "AB", {});
  assert.equal(st.misses, 2);
});

test("epoch 只增不减（诊断用：两次报错之间没变 ⇒ 不是缓存导致的）", () => {
  const st = new UiStateStore();
  const e0 = st.epoch;
  st.invalidateDerived();
  st.reset();
  st.reset();
  assert.equal(st.epoch, e0 + 3);
});

// ── 滚动（权威态） ──────────────────────────────────────────

test("scrollOf 未设置 = 0；setScroll 负数夹到 0", () => {
  const st = new UiStateStore();
  assert.equal(st.scrollOf(1), 0);
  st.setScroll(1, -20);
  assert.equal(st.scrollOf(1), 0);
  st.setScroll(1, 40);
  assert.equal(st.scrollOf(1), 40);
});

test("★ setScroll 拒绝非有限数并**保持原值**（夹成 0 会伪装成\"用户滑回顶部\"）", () => {
  const st = new UiStateStore();
  st.setScroll(1, 40);
  st.setScroll(1, Number.NaN);
  assert.equal(st.scrollOf(1), 40);
  st.setScroll(1, Number.POSITIVE_INFINITY);
  assert.equal(st.scrollOf(1), 40);
});

test("drop 同时丢掉该节点的派生与权威状态", () => {
  const fonts = registry();
  const st = new UiStateStore();
  st.text(1, fonts, "test", "AB", {});
  st.setScroll(1, 33);
  st.drop(1);
  assert.equal(st.scrollOf(1), 0);
  assert.equal(st.stats.layouts, 0);
});

// ── 上限 ────────────────────────────────────────────────────

test("排版缓存超过上限时整表清空，并记账到 evictions（不静默无限增长）", () => {
  const fonts = registry();
  const st = new UiStateStore();
  for (let uid = 1; uid <= 1024; uid++) st.text(uid, fonts, "test", "AB", {});
  assert.equal(st.stats.layouts, 1024);
  assert.equal(st.stats.evictions, 0);
  st.text(1025, fonts, "test", "AB", {});
  assert.equal(st.stats.layouts, 1, "整表清空后只剩新写进去的这一条");
  assert.equal(st.stats.evictions, 1024);
});

test("stats 是快照（改了内部状态之后旧快照不变）", () => {
  const fonts = registry();
  const st = new UiStateStore();
  const before = st.stats;
  st.text(1, fonts, "test", "AB", {});
  assert.equal(before.layouts, 0);
  assert.equal(st.stats.layouts, 1);
});

// ── 字体表的变更通知 ────────────────────────────────────────

test("★★ FontRegistry.register 触发通知：热重载字体后旧排版必须能被作废", () => {
  const fonts = new FontRegistry();
  const st = new UiStateStore();
  const off = fonts.onRegister(() => {
    st.invalidateDerived();
  });
  fonts.register(makeTestFont());
  st.text(1, fonts, "test", "AB", {});
  const before = st.epoch;
  // 同 id 换一个字体（热重载）⇒ 旧排版里的 page/UV 指向旧图集
  fonts.register(makeFontWith([65, 66], "test"));
  assert.equal(st.epoch, before + 1, "通知到了 ⇒ 派生态作废");
  off();
  fonts.register(makeTestFont());
  assert.equal(st.epoch, before + 1, "退订之后不再被通知");
});

test("onRegister 的退订是幂等的（重复调用不抛）", () => {
  const fonts = new FontRegistry();
  const off = fonts.onRegister(() => {});
  off();
  off();
  fonts.register(makeTestFont());
  assert.deepEqual(fonts.ids(), ["test"]);
});

// ------------------------------------------------------------------ 富文本进键（批114）

const RED = new Color(1, 0, 0, 1);
const BLUE = new Color(0, 0, 1, 1);

test("★★ runs 必须进键：同一段 text 换配色 ⇒ 重排（否则「改了配色不刷新」）", () => {
  const fonts = registry();
  const st = new UiStateStore();
  const a = st.text(1, fonts, "test", "AB", {}, [
    { text: "AB", color: RED },
  ]);
  // ★ 两次的 `text` 完全相同 —— 只有 runs 里的颜色变了
  const b = st.text(1, fonts, "test", "AB", {}, [
    { text: "AB", color: BLUE },
  ]);
  assert.deepEqual([st.hits, st.misses], [0, 2], "颜色进了键 ⇒ 第二次必须重排");
  assert.equal(a?.quads[0]?.r, 1, "第一次是红的");
  assert.equal(b?.quads[0]?.r, 0, "第二次是蓝的");
  assert.equal(b?.quads[0]?.b, 1);
  // 反向：同样的 runs 再来一次 ⇒ 命中（键不能宽到永不命中）
  const c = st.text(1, fonts, "test", "AB", {}, [
    { text: "AB", color: BLUE },
  ]);
  assert.equal(c, b, "同 runs ⇒ 同一个对象");
  assert.deepEqual([st.hits, st.misses], [1, 2]);
});

test("★★ 有 runs 时 text 退出键与排版（两个字段同时生效就是两套真相）", () => {
  const fonts = registry();
  const st = new UiStateStore();
  // text 里塞了字体没有的 Z：若还按 text 排版，width 会是 12 + 8（缺字占位）+ 12
  const a = st.text(1, fonts, "test", "ZAB", {}, [{ text: "AB" }]);
  assert.equal(a?.width, 2 * ADV, "只按 runs 排，Z 不参与");
  assert.deepEqual([...(a?.missing ?? [])], [], "Z 不该被报成缺字");
  // 换一个 text、runs 不变 ⇒ 仍然是命中（text 不在键里）
  const b = st.text(1, fonts, "test", "QWE", {}, [{ text: "AB" }]);
  assert.equal(b, a, "text 变了但 runs 没变 ⇒ 复用同一份排版");
  assert.equal(st.misses, 1);
});

test("★ 空 runs 数组等价于没有（都表示「这一段是单样式」）", () => {
  const fonts = registry();
  const st = new UiStateStore();
  const a = st.text(1, fonts, "test", "AB", {}, []);
  const b = st.text(1, fonts, "test", "AB", {});
  assert.equal(a?.width, 2 * ADV);
  assert.equal(b, a, "空数组与 undefined 是同一个键");
  assert.equal(st.misses, 1);
});
