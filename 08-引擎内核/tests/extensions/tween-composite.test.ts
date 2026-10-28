/**
 * 合成判据：同一 (目标, 属性) 上的多条轨道怎么折成一个值（批117）
 *
 * 这一层是纯函数（没有 player、没有时间），所以每条规则都能**手算**对：
 * 三个算子各一条、顺序一条、分组一条、完成态一条、恒等元一条。
 * 与 `tween-player.test.ts` 分工：那边验"推进与 changed"，这边验"折叠本身"。
 *
 * ★ 值刻意全用**二进制精确**的数（0.5/0.25/0.75/2/4）：`0.5 + 0.2` 在双精度里
 *   是 0.7000000000000001，断言就得写成近似 —— 而写成近似之后"乘法写成加法"
 *   这种错有时也能落到容差里。能用精确值就别用容差。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  COMPOSITE_ERR,
  COMPOSITE_OP,
  composeEntries,
  composeValue,
  isCompositeOp,
  resolveComposite,
  type CompositeEntry,
  type CompositeOp,
} from "../../src/extensions/tween/composite.ts";

/** 造一条待合成条目（默认写 panel 的 opacity）。 */
function entry(op: CompositeOp, value: number, over: Partial<CompositeEntry> = {}): CompositeEntry {
  return { id: `t${String(value)}`, targetId: "panel", prop: "opacity", op, value, done: false, ...over };
}

test("三个算子各按自己的算术：replace 覆盖 / add 相加 / multiply 相乘", () => {
  assert.equal(composeValue(COMPOSITE_OP.Replace, 0.5, 0.25), 0.25, "replace：基底被丢掉");
  assert.equal(composeValue(COMPOSITE_OP.Add, 0.5, 0.25), 0.75, "add：0.5 + 0.25");
  assert.equal(composeValue(COMPOSITE_OP.Multiply, 0.5, 0.5), 0.25, "multiply：0.5 × 0.5");
});

test("★ 第一条的算子不影响结果（add 的恒等元是 0，multiply 是 1）", () => {
  // 三个算子对"只有一个贡献者"必须给出同一个值 —— 否则"第一条写了 add"
  // 会把属性锁死在 0（乘 0），症状是"这条轨道加了没反应"。
  for (const op of Object.values(COMPOSITE_OP)) {
    const out = composeEntries([entry(op, 0.25)]);
    assert.equal(out.length, 1);
    assert.equal(out[0]?.value, 0.25, `只有一条时 ${op} 也该等于自身`);
  }
});

test("★ 同一 (目标, 属性) 合成成一条；不同目标或不同属性各是一条", () => {
  const same = composeEntries([entry(COMPOSITE_OP.Replace, 0.5), entry(COMPOSITE_OP.Multiply, 0.5)]);
  assert.equal(same.length, 1, "同目标同属性 ⇒ 一条");
  assert.equal(same[0]?.value, 0.25);

  // 不同目标：两个面板各自的 opacity 互不相干（用 prop 当分组键会把它们搅在一起）
  const twoTargets = composeEntries([
    entry(COMPOSITE_OP.Replace, 0.5, { targetId: "bag", id: "a" }),
    entry(COMPOSITE_OP.Multiply, 0.5, { targetId: "hud", id: "b" }),
  ]);
  assert.equal(twoTargets.length, 2, "不同目标不合并");
  assert.deepEqual(twoTargets.map((c) => c.value), [0.5, 0.5], "各自的第一条，不该相乘");

  // 同目标不同属性：同理
  const twoProps = composeEntries([
    entry(COMPOSITE_OP.Replace, 0.5, { prop: "opacity", id: "a" }),
    entry(COMPOSITE_OP.Multiply, 0.5, { prop: "scale", id: "b" }),
  ]);
  assert.equal(twoProps.length, 2, "不同属性不合并");
});

test("★ 合成顺序 = 输入顺序（后一条作用在前一条的已合成结果上）", () => {
  // 顺序一：replace(0.5) → add(0.25) ⇒ 0.75
  const a = composeEntries([entry(COMPOSITE_OP.Replace, 0.5, { id: "first" }), entry(COMPOSITE_OP.Add, 0.25, { id: "second" })]);
  assert.equal(a[0]?.value, 0.75);
  // 顺序二：add(0.25) → replace(0.5) ⇒ 0.5（后者把前者盖掉）
  const b = composeEntries([entry(COMPOSITE_OP.Add, 0.25, { id: "first" }), entry(COMPOSITE_OP.Replace, 0.5, { id: "second" })]);
  assert.equal(b[0]?.value, 0.5, "replace 在最后 ⇒ 全部被覆盖");
  assert.notEqual(a[0]?.value, b[0]?.value, "两条顺序必须给出不同的值（否则顺序没接线）");
});

test("三条链：replace → add → multiply 手算 = ((0.5 + 0.25) × 2) = 1.5", () => {
  const out = composeEntries([
    entry(COMPOSITE_OP.Replace, 0.5, { id: "r" }),
    entry(COMPOSITE_OP.Add, 0.25, { id: "a" }),
    entry(COMPOSITE_OP.Multiply, 2, { id: "m" }),
  ]);
  assert.equal(out.length, 1);
  assert.equal(out[0]?.value, 1.5);
  assert.equal(out[0]?.id, "m", "id 是**最后**写它的那条（这个值是谁给的）");
});

test("done = 参与合成的**全部**轨道都完成（一条还在走，这个属性就还在变）", () => {
  const running = composeEntries([
    entry(COMPOSITE_OP.Replace, 0.5, { done: true }),
    entry(COMPOSITE_OP.Add, 0.25, { done: false }),
  ]);
  assert.equal(running[0]?.done, false, "add 那条还在走 ⇒ 整个属性未完");
  const allDone = composeEntries([
    entry(COMPOSITE_OP.Replace, 0.5, { done: true }),
    entry(COMPOSITE_OP.Add, 0.25, { done: true }),
  ]);
  assert.equal(allDone[0]?.done, true);
});

test("输出顺序 = 每组**首次出现**的位置；空输入给空数组；不改入参", () => {
  const entries = [
    entry(COMPOSITE_OP.Replace, 0.5, { targetId: "bag", prop: "opacity", id: "bag.o" }),
    entry(COMPOSITE_OP.Replace, 1, { targetId: "bag", prop: "scale", id: "bag.s" }),
    entry(COMPOSITE_OP.Add, 0.25, { targetId: "bag", prop: "opacity", id: "bag.o2" }),
  ];
  const before = entries.map((e) => e.value);
  const out = composeEntries(entries);
  assert.deepEqual(out.map((c) => c.prop), ["opacity", "scale"], "opacity 先出现 ⇒ 排在前面");
  assert.equal(out[0]?.value, 0.75, "opacity 被 fold 了两次");
  assert.deepEqual(before, entries.map((e) => e.value), "入参没被就地改");
  assert.deepEqual(composeEntries([]), []);
});

test("★ 算子名拼错在构造期报错，不静默变成 replace", () => {
  assert.equal(isCompositeOp("multiply"), true);
  assert.equal(isCompositeOp("multipy"), false);
  const bad = resolveComposite("multipy", "bag.fade");
  assert.equal(bad.ok, false);
  if (!bad.ok) assert.equal(bad.error.code, COMPOSITE_ERR.BAD_OP);
  const dflt = resolveComposite(undefined, "bag.fade");
  assert.equal(dflt.ok, true);
  if (dflt.ok) assert.equal(dflt.value, COMPOSITE_OP.Replace, "缺省是 replace（批76 行为不变）");
});
