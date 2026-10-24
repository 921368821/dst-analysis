/**
 * L4 · 仇恨表（谁打过我、我记多久）
 *
 * ★ 这个文件的重点是三处"看起来对、实际分不出来"的语料：
 *   ① **累加 vs 取最大**：只打一次的话两者相同。必须让同一个人打两下、且第二下更小。
 *   ② **平手取小 id**：先插入的恰好是小 id 时，任何实现都对。
 *      所以要**故意按 id 降序插入**（这与 M190「创建顺序恰好等于期望顺序」同一类）。
 *   ③ **过期的边界**：`decay-1` tick 时还在、`decay` tick 时不在。
 *      只验"很久以后忘了"的话，写 `>=` 还是 `>` 分不出来 ——
 *      而"忘得太早"与"忘得太晚"是两种不同的bug。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { THREAT_BAD_AMOUNT, THREAT_BAD_OPTIONS, createThreatTable } from "../../src/extensions/combat/threat.ts";

const MOB = 10;

test("[仇恨] 打一下就记住：best 返回攻击者", () => {
  const t = createThreatTable({ decayTicks: 100 });
  assert.deepEqual(t.add(MOB, 7, 3, 0), { ok: true });
  assert.equal(t.best(MOB, 0), 7);
  assert.equal(t.amountOf(MOB, 7, 0), 3);
});

test("[仇恨] ★ 同一个人打两下是**累加**（不是取最大、也不是两条）", () => {
  const t = createThreatTable({ decayTicks: 100 });
  t.add(MOB, 7, 5, 0);
  t.add(MOB, 7, 2, 1); // 第二下更小：取最大的实现会是 5
  assert.equal(t.amountOf(MOB, 7, 1), 7, "5 + 2 = 7");
  assert.equal(t.sizeOf(MOB, 1), 1, "同一个人只该有一条（每下一条的实现在这里是 2）");
});

test("[仇恨] 打得多的人更招恨（best 跟着数值走，不跟着插入顺序走）", () => {
  const t = createThreatTable({ decayTicks: 100 });
  t.add(MOB, 7, 1, 0);
  t.add(MOB, 8, 9, 0);
  assert.equal(t.best(MOB, 0), 8);
});

test("[仇恨] ★ 平手时取**小 id**：故意按 id 降序插入（顺序不等于答案）", () => {
  const t = createThreatTable({ decayTicks: 100 });
  // 先插入 9、再插入 3。返回 3 才说明真的在比 id，而不是"谁先写进 Map 谁优先"。
  t.add(MOB, 9, 4, 0);
  t.add(MOB, 3, 4, 0);
  assert.equal(t.best(MOB, 0), 3, `平手应取小 id（3），实际 ${String(t.best(MOB, 0))}`);
});

test("[仇恨] ★ 过期的边界：decay-1 还在，decay 时忘掉", () => {
  const t = createThreatTable({ decayTicks: 10 });
  t.add(MOB, 7, 5, 0);
  assert.equal(t.best(MOB, 9), 7, "第 9 tick（差 9 < 10）还该记得");
  assert.equal(t.best(MOB, 10), null, "第 10 tick（差 10）该忘了");
});

test("[仇恨] ★ 忘了之后表也要收缩（targets 不能只涨不跌）", () => {
  const t = createThreatTable({ decayTicks: 5 });
  t.add(MOB, 7, 5, 0);
  assert.equal(t.stats().targets, 1);
  assert.equal(t.best(MOB, 5), null);
  assert.equal(t.stats().targets, 0, "没有仇恨的目标必须从表里删掉（否则 size 只涨不跌）");
  assert.equal(t.stats().entries, 0);
  assert.equal(t.stats().expired, 1, "剔除次数要能被看到");
});

test("[仇恨] 再挨打会续命（since 被刷新）", () => {
  const t = createThreatTable({ decayTicks: 10 });
  t.add(MOB, 7, 1, 0);
  t.add(MOB, 7, 1, 8); // 续命
  assert.equal(t.best(MOB, 15), 7, "第 15 tick 时距上次只有 7，还该记得");
});

test("[仇恨] 表满时丢**最不恨**的那条（不是丢最早的那条）", () => {
  const t = createThreatTable({ decayTicks: 100, maxPerTarget: 2 });
  t.add(MOB, 7, 9, 0); // 最恨（最早插入）
  t.add(MOB, 8, 1, 1); // 最不恨
  t.add(MOB, 9, 5, 2); // 挤掉 8
  assert.equal(t.amountOf(MOB, 7, 2), 9, "最恨的那条必须还在");
  assert.equal(t.amountOf(MOB, 9, 2), 5);
  assert.equal(t.amountOf(MOB, 8, 2), 0, "最不恨的那条被挤掉了");
  assert.equal(t.stats().evicted, 1);
});

test("[仇恨] forget：一个攻击者死了，所有目标都该忘掉他", () => {
  const t = createThreatTable({ decayTicks: 100 });
  t.add(MOB, 7, 5, 0);
  t.add(MOB + 1, 7, 5, 0);
  t.add(MOB + 1, 8, 1, 0);
  assert.equal(t.forget(7), 2, "两个目标各一条");
  assert.equal(t.best(MOB, 0), null);
  assert.equal(t.best(MOB + 1, 0), 8, "别人的仇恨不该被动");
});

test("[仇恨] forgetOne：只忘掉一对", () => {
  const t = createThreatTable({ decayTicks: 100 });
  t.add(MOB, 7, 5, 0);
  t.add(MOB, 8, 3, 0);
  assert.equal(t.forgetOne(MOB, 8), true);
  assert.equal(t.forgetOne(MOB, 8), false, "第二次没有了");
  assert.equal(t.best(MOB, 0), 7);
});

test("[仇恨] ★ alive 过滤器不删记录（打不到 ≠ 不恨了）", () => {
  const t = createThreatTable({ decayTicks: 100 });
  t.add(MOB, 7, 9, 0);
  t.add(MOB, 8, 1, 0);
  const best = t.best(MOB, 0, (id) => id !== 7);
  assert.equal(best, 8, "7 暂时打不到（比如它隐身了），退而求其次选 8");
  assert.equal(t.amountOf(MOB, 7, 0), 9, "但 7 的那条**不能**被删掉");
});

test("[仇恨] 非法输入一律拒绝，且不动任何状态", () => {
  const t = createThreatTable({ decayTicks: 10 });
  for (const bad of [0, -1, Number.NaN, Number.POSITIVE_INFINITY]) {
    const r = t.add(MOB, 7, bad, 0);
    assert.deepEqual(r, { ok: false, code: THREAT_BAD_AMOUNT });
  }
  const self = t.add(MOB, MOB, 1, 0);
  assert.deepEqual(self, { ok: false, code: THREAT_BAD_AMOUNT }, "自己打自己不该被记住");
  assert.equal(t.best(MOB, 0), null);
  assert.equal(t.stats().entries, 0);
});

test("[仇恨] 构造参数非法抛 RangeError", () => {
  for (const bad of [0, -1, 2.5, Number.NaN]) {
    assert.throws(() => createThreatTable({ decayTicks: bad }), RangeError);
  }
  assert.throws(() => createThreatTable({ decayTicks: 10, maxPerTarget: 0 }), RangeError);
  assert.throws(() => createThreatTable({ decayTicks: 10, maxPerTarget: 1.5 }), RangeError);
  assert.equal(typeof THREAT_BAD_OPTIONS, "string");
});
