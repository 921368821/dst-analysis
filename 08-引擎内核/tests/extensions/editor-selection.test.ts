/**
 * L4 · 编辑器：选中集
 *
 * ★ 为什么要给"选中什么"单独写判据：它不是 UI 细节。
 *   属性面板、删除、拖拽、批量改属性全部读它；它一旦"顺序随点击变"
 *   或者"留着一个已死 id"，故障表现都是"面板显示错的东西"，
 *   而人第一反应会去查面板的渲染代码。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { createSelection } from "../../src/extensions/editor/selection.ts";

test("[编辑器·选中] 单选是替换，不是累加", () => {
  const s = createSelection();
  s.select(5);
  s.select(2);
  assert.deepEqual(s.ids(), [2], "第二次 select 必须把第一次的挤掉");
  assert.equal(s.primary, 2);
  assert.equal(s.size, 1);
});

test("[编辑器·选中] ids 升序，不随点击顺序变", () => {
  const s = createSelection();
  for (const id of [9, 3, 7, 1]) s.toggle(id);
  assert.deepEqual(s.ids(), [1, 3, 7, 9], "面板行序必须与点击顺序无关");
  // 换一个点击顺序，结果必须一样
  const t = createSelection();
  for (const id of [1, 7, 3, 9]) t.toggle(id);
  assert.deepEqual(t.ids(), s.ids(), "同一集合、不同点击序 ⇒ 同一快照");
});

test("[编辑器·选中] toggle 返回值是「操作后是否在集合里」", () => {
  const s = createSelection();
  assert.equal(s.toggle(4), true, "加入 ⇒ true");
  assert.equal(s.toggle(4), false, "移除 ⇒ false");
  assert.equal(s.has(4), false);
  assert.equal(s.size, 0);
});

test("[编辑器·选中] toggle 掉 primary：primary 回落到剩下的最小 id", () => {
  const s = createSelection();
  s.select(8);
  s.toggle(3);
  s.toggle(6);
  assert.deepEqual(s.ids(), [3, 6, 8]);
  assert.equal(s.primary, 6, "primary 是最后一次加入的那个");

  s.toggle(6);
  assert.equal(s.primary, 3, `primary 被删后必须回落，实际 ${String(s.primary)}（悬空 primary ⇒ 面板显示上一轮内容）`);
  assert.equal(s.has(6), false);

  s.toggle(3);
  assert.equal(s.primary, 8);
  s.toggle(8);
  assert.equal(s.primary, null, "清空后 primary 必须是 null，不是 0 也不是残留 id");
});

test("[编辑器·选中] prune 清掉已死 id 并回报它们，primary 不悬空", () => {
  const s = createSelection();
  // ★ primary 必须**正好是死掉的那个** —— 第一版把 primary 留在活着的 5 上，
  //   于是"回落"那段代码根本没被执行，变异 M220 抓不住（判据假绿）。
  s.toggle(5);
  s.toggle(2);
  assert.equal(s.primary, 2, "前置条件：primary 指向即将被销毁的 2");
  const gone = s.prune((id) => id === 5);
  assert.deepEqual(gone, [2], "被清掉的 id 要回报（UI 才能提示「选中项消失了」）");
  assert.deepEqual(s.ids(), [5]);
  assert.equal(s.primary, 5, `primary 指向已销毁节点时必须回落，实际 ${String(s.primary)}`);
});

test("[编辑器·选中] prune 不动活着的，也不改顺序", () => {
  const s = createSelection();
  for (const id of [7, 2, 9]) s.toggle(id);
  assert.deepEqual(s.prune(() => true), [], "全都活着时什么也不清");
  assert.deepEqual(s.ids(), [2, 7, 9]);
});

test("[编辑器·选中] snapshot 是快照：改它不影响内部", () => {
  const s = createSelection();
  s.select(3);
  const snap = s.snapshot();
  (snap.ids as number[]).push(99);
  assert.deepEqual(s.ids(), [3], "快照被外部改了不能污染内部状态");
  assert.deepEqual(s.snapshot().ids, [3]);
});
