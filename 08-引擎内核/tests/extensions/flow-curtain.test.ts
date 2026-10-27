/**
 * L4 · 过场幕布的拍表（批98）
 *
 * 这一层是纯状态机，所以判据能**逐拍**写 —— 而它的全部内容就在"第几拍发生了什么"里。
 *
 * ★★ 唯一要守的不变量：
 *   **幕布落满之前，世界一个字节都不许动**（也就是 `fire` 必须与 alpha === 1 同拍）。
 *   把这条写成"跑完看结果"是验不到的：跑完之后世界确实换了、幕布也确实回到 0 ——
 *   换早三拍与换晚三拍，终局完全一样。所以下面每一条都按拍断言，
 *   并且专门有一条"前 N-1 拍一次都不许交火"。
 *
 * ★ 失败路径没有补偿分支（见 `curtain.ts` 文件头），所以判据必须证明
 *   **不补偿也是对的**：交火之后什么都不做、继续推进，幕布自己淡回 0。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  CURTAIN_IDLE,
  CURTAIN_IN_TICKS,
  CURTAIN_OUT_TICKS,
  DEFAULT_CURTAIN_SPEC,
  advanceCurtain,
  cancelCurtain,
  curtainAlpha,
  requestCurtain,
  type CurtainPhase,
  type CurtainState,
  type CurtainTarget,
} from "../../src/extensions/flow/curtain.ts";
import type { PortalSpec } from "../../src/extensions/flow/portal.ts";

const SPEC = DEFAULT_CURTAIN_SPEC;

function door(to: string): PortalSpec {
  return {
    name: `门-${to}`,
    to,
    radius: 64,
    open: true,
    requires: "",
    requiresCount: 1,
    requiresScene: "",
    consume: false,
    x: 0,
    z: 0,
  };
}

function target(to = "b"): CurtainTarget {
  return { scene: to, via: door(to) };
}

/** 一直推进到 idle（最多给 200 拍，防止写错时死循环）。 */
function runToIdle(start: CurtainState): {
  state: CurtainState;
  fires: CurtainTarget[];
  alphas: number[];
  phases: CurtainPhase[];
} {
  let s = start;
  const fires: CurtainTarget[] = [];
  const alphas: number[] = [curtainAlpha(s, SPEC)];
  const phases: CurtainPhase[] = [s.phase];
  for (let i = 0; i < 200; i++) {
    const step = advanceCurtain(s, SPEC);
    s = step.state;
    if (step.fire !== null) fires.push(step.fire);
    alphas.push(curtainAlpha(s, SPEC));
    phases.push(s.phase);
    if (s.phase === "idle") return { state: s, fires, alphas, phases };
  }
  throw new Error("幕布没有回到 idle —— 状态机卡住了");
}

// ── ① 起点 ────────────────────────────────────────────────────

test("★ 起点：没有幕布、alpha 为 0、没有任何待办", () => {
  assert.equal(CURTAIN_IDLE.phase, "idle");
  assert.equal(CURTAIN_IDLE.elapsed, 0);
  assert.equal(CURTAIN_IDLE.target, null);
  assert.equal(curtainAlpha(CURTAIN_IDLE, SPEC), 0, "没有幕布时画面必须是世界原样");
  assert.equal(CURTAIN_IDLE.fired, 0);
  assert.equal(CURTAIN_IDLE.refused, 0);
});

test("★ 幕布不推就不动：空推进返回同一个状态，不交火", () => {
  const r = advanceCurtain(CURTAIN_IDLE, SPEC);
  assert.equal(r.fire, null);
  assert.equal(r.state, CURTAIN_IDLE, "idle 下推进应当原样返回（同一个对象，不是一份拷贝）");
});

// ── ② 不变量：落满之前不许换世界 ──────────────────────────────

test("★★ 落幕：前 11 拍一次都不交火，第 12 拍 alpha 恰好 1 且同时交火", () => {
  const req = requestCurtain(CURTAIN_IDLE, target("b"));
  assert.ok(req.accepted, "idle 状态下第一次请求必须被接");
  assert.equal(req.state.phase, "out");
  assert.equal(req.state.target?.scene, "b", "待办必须记下来 —— 否则落满那一拍不知道要跳哪儿");

  let s = req.state;
  for (let i = 1; i < CURTAIN_OUT_TICKS; i++) {
    const step = advanceCurtain(s, SPEC);
    s = step.state;
    assert.equal(step.fire, null, `第 ${String(i)} 拍就交火了 —— 那时幕布只有 ${String(curtainAlpha(s, SPEC))}`);
    assert.ok(curtainAlpha(s, SPEC) < 1, `第 ${String(i)} 拍的幕布不透明度必须还小于 1`);
  }
  const last = advanceCurtain(s, SPEC);
  assert.notEqual(last.fire, null, "落满的那一拍必须交火（否则世界永远不会换）");
  assert.equal(last.fire?.scene, "b");
  assert.equal(curtainAlpha(last.state, SPEC), 1, "交火那一拍的 alpha 必须是 1 —— 换世界那一帧要被整个盖住");
});

test("★★ 落幕曲线逐拍单调不减，且第 0 拍是 0（不是「一上来就半黑」）", () => {
  let s = requestCurtain(CURTAIN_IDLE, target()).state;
  let prev = curtainAlpha(s, SPEC);
  assert.equal(prev, 0, "刚请求幕布时画面还是世界原样");
  for (let i = 0; i < CURTAIN_OUT_TICKS; i++) {
    s = advanceCurtain(s, SPEC).state;
    const a = curtainAlpha(s, SPEC);
    assert.ok(a >= prev, `第 ${String(i + 1)} 拍的 alpha 掉下来了：${String(prev)} → ${String(a)}`);
    prev = a;
  }
  assert.equal(prev, 1);
});

test("★★ 落幕最后一拍（交火前一拍）必须逼近 1：每拍等分 1/outTicks", () => {
  // ★ 为什么单独来一条：交火那一拍的 alpha 来自**起幕**分支（恒为 1），所以
  //   "落幕根本没走到 1"是看不见的 —— 曲线会在换世界那一刻从 0.5 直接跳到 1，
  //   画面上是"黑到一半忽然全黑"，而所有"到过 1"的断言都还是绿的。
  let s = requestCurtain(CURTAIN_IDLE, target()).state;
  const seq = [curtainAlpha(s, SPEC)];
  for (let i = 0; i < CURTAIN_OUT_TICKS - 1; i++) {
    s = advanceCurtain(s, SPEC).state;
    seq.push(curtainAlpha(s, SPEC));
  }
  assert.equal(seq.length, CURTAIN_OUT_TICKS, "交火前应当恰好有 outTicks-1 次推进");
  assert.equal(s.phase, "out", "推到这里还该在落幕阶段");
  for (let i = 1; i < seq.length; i++) {
    const step = (seq[i] ?? 0) - (seq[i - 1] ?? 0);
    assert.ok(
      Math.abs(step - 1 / CURTAIN_OUT_TICKS) < 1e-9,
      `第 ${String(i)} 拍的步长是 ${String(step)}，应当恰好 1/${String(CURTAIN_OUT_TICKS)}`,
    );
  }
  assert.ok((seq[seq.length - 1] ?? 0) >= 0.9, "交火前幕布应当已经接近全黑（至少 0.9）");
});

// ── ③ 起幕 ────────────────────────────────────────────────────

test("★★ 起幕：从 1 逐拍降到 0，第 18 拍回到 idle；全程恰好交火一次", () => {
  const run = runToIdle(requestCurtain(CURTAIN_IDLE, target()).state);
  assert.equal(run.fires.length, 1, `交火了 ${String(run.fires.length)} 次 —— 只能一次（多一次就是连着换了两次世界）`);
  assert.equal(run.state.phase, "idle");
  assert.equal(curtainAlpha(run.state, SPEC), 0, "结束时画面必须完全露出");
  assert.equal(run.state.fired, 1, "`fired` 是交火次数的账，必须和实际一致");
  // 曲线：交火之后单调下降
  const atFire = CURTAIN_OUT_TICKS;
  assert.equal(run.alphas[atFire], 1, "第 12 拍（下标 12）必须是满的");
  for (let i = atFire + 1; i < run.alphas.length; i++) {
    assert.ok(
      (run.alphas[i] ?? 0) <= (run.alphas[i - 1] ?? 0),
      `第 ${String(i)} 拍的 alpha 回升了：${String(run.alphas[i - 1])} → ${String(run.alphas[i])}`,
    );
  }
  // 总拍数 = 落幕 + 起幕（一个不多一个不少：多一拍就是「黑着不动」）
  assert.equal(run.alphas.length, CURTAIN_OUT_TICKS + CURTAIN_IN_TICKS + 1, "总拍数与两个常量对不上");
  // ★★ 起幕的最后一拍必须已经接近 0：只验"回到 idle 时 alpha 是 0"是验不到的 ——
  //   相一变 idle，alpha 就恒为 0，于是"这之前一直停在半黑"完全看不见（M470 的坑）。
  const inSeq = run.alphas.filter((_, i) => run.phases[i] === "in");
  assert.ok(inSeq.length >= 2, "起幕阶段应当有若干拍");
  assert.ok(
    (inSeq[inSeq.length - 1] ?? 1) <= 1 / CURTAIN_IN_TICKS + 1e-9,
    `起幕最后一拍的 alpha 是 ${String(inSeq[inSeq.length - 1])} —— 应当已经接近 0（≤ ${String(1 / CURTAIN_IN_TICKS)}）`,
  );
});

test("★ 落幕比起幕快（遮得快、露得慢）—— 两个常量不许写成相等", () => {
  assert.ok(CURTAIN_OUT_TICKS < CURTAIN_IN_TICKS, "这条是观感约定：遮的时候人已经决定走了，露的时候他在认新地方");
});

// ── ④ 换世界失败：不补偿也是对的 ──────────────────────────────

test("★★ 交火之后什么都不做（世界没换成功）⇒ 幕布自己淡回 0，状态机不卡住", () => {
  // 模拟"幕布落满、jump 被拒（门锁了）"：调用方拿到 fire 之后什么都没做
  let s = requestCurtain(CURTAIN_IDLE, target()).state;
  for (let i = 0; i < CURTAIN_OUT_TICKS; i++) s = advanceCurtain(s, SPEC).state;
  assert.equal(s.phase, "in", "落满那一拍状态机关就已经进 in 了 —— 这就是「失败不需要补偿」的来源");
  for (let i = 0; i < CURTAIN_IN_TICKS; i++) s = advanceCurtain(s, SPEC).state;
  assert.equal(s.phase, "idle", "不补偿也要能自己回到 idle");
  assert.equal(curtainAlpha(s, SPEC), 0);
  assert.equal(s.target, null, "待办必须已经被清掉 —— 留着它下一拍会再跳一次");
});

// ── ⑤ 忙：拒绝而不是排队 ──────────────────────────────────────

test("★★ 幕布在动时再请求：拒掉并记一笔，状态其余字段一个字都不动", () => {
  let s = requestCurtain(CURTAIN_IDLE, target("b")).state;
  s = advanceCurtain(s, SPEC).state;
  const before = s;

  const again = requestCurtain(s, target("c"));
  assert.equal(again.accepted, false, "幕布在动时不许接第二跳");
  assert.equal(again.state.refused, before.refused + 1, "被拒必须记上（静默忽略会变成「这扇门没反应」）");
  assert.equal(again.state.phase, before.phase, "拒绝不许改相");
  assert.equal(again.state.elapsed, before.elapsed, "拒绝不许改拍数");
  assert.equal(again.state.target?.scene, "b", "待办仍是先到的那一个 —— 不许被后来的顶掉");
});

test("★ 起幕阶段也不接新跳（幕布还在往上走，换世界没有视觉证据）", () => {
  let s = requestCurtain(CURTAIN_IDLE, target("b")).state;
  for (let i = 0; i < CURTAIN_OUT_TICKS; i++) s = advanceCurtain(s, SPEC).state;
  assert.equal(s.phase, "in");
  assert.equal(requestCurtain(s, target("c")).accepted, false);
});

test("★ 一个完整的过场结束后可以再请求（拒绝不是永久的）", () => {
  const done = runToIdle(requestCurtain(CURTAIN_IDLE, target("b")).state).state;
  const next = requestCurtain(done, target("c"));
  assert.ok(next.accepted, "回到 idle 之后必须能接下一次 —— 否则走过一次门之后就再也跳不了了");
  assert.equal(next.state.target?.scene, "c");
});

// ── ⑥ 取消 ────────────────────────────────────────────────────

test("★★ 取消：任何阶段都立刻回到 idle（alpha 归 0），并记账", () => {
  const mid = advanceCurtain(requestCurtain(CURTAIN_IDLE, target()).state, SPEC).state;
  assert.ok(curtainAlpha(mid, SPEC) > 0, "先确认幕布真的落下来了一点");
  const c = cancelCurtain(mid);
  assert.equal(c.phase, "idle");
  assert.equal(curtainAlpha(c, SPEC), 0, "停播之后不许留一块黑在屏幕上");
  assert.equal(c.target, null, "取消必须把待办一起丢掉 —— 否则下一局的第一次推进会执行它");
  assert.equal(c.cancelled, 1);
});

test("★ idle 上取消是幂等的（不涨计数、返回原对象）", () => {
  const c = cancelCurtain(CURTAIN_IDLE);
  assert.equal(c, CURTAIN_IDLE);
  assert.equal(c.cancelled, 0);
});

test("★ 取消之后能立刻重新请求（停播再开播不该带着上一局的幕布）", () => {
  const mid = advanceCurtain(requestCurtain(CURTAIN_IDLE, target("b")).state, SPEC).state;
  const c = cancelCurtain(mid);
  const again = requestCurtain(c, target("c"));
  assert.ok(again.accepted);
  assert.equal(again.state.elapsed, 0, "新的一次过场必须从第 0 拍开始");
  assert.equal(again.state.cancelled, 1, "计数要带过去（它是这一局的账，不是这一次过场的账）");
});

// ── ⑦ 拍数下限：0 不是硬切 ────────────────────────────────────

test("★★ 拍数传 0：夹成 1（并在下一拍就落满），不是「永远落不满」也不是 NaN", () => {
  const spec = { outTicks: 0, inTicks: 0 };
  const s = requestCurtain(CURTAIN_IDLE, target()).state;
  assert.equal(curtainAlpha(s, spec), 0, "刚落幕那一拍也要夹 —— 0/0 是 NaN，会一路黑到 GPU");
  const step = advanceCurtain(s, spec);
  assert.notEqual(step.fire, null, "outTicks=0 必须夹成 1 —— 第一拍就落满并交火");
  assert.equal(curtainAlpha(step.state, spec), 1, "alpha 与 advance 必须用同一个夹取口径");
});

test("★★ 负拍数同样夹成 1（NaN 不会漏进 alpha）", () => {
  const spec = { outTicks: -5, inTicks: -1 };
  const s = requestCurtain(CURTAIN_IDLE, target()).state;
  const step = advanceCurtain(s, spec);
  assert.notEqual(step.fire, null);
  assert.ok(Number.isFinite(curtainAlpha(step.state, spec)), "alpha 不许是 NaN —— NaN 传到渲染层是整屏变黑");
});

// ── ⑧ 不可变 ──────────────────────────────────────────────────

test("★ 推进不改原对象（判据要能逐拍存快照再回头比）", () => {
  const s0 = requestCurtain(CURTAIN_IDLE, target()).state;
  const snapshot = { ...s0 };
  const s1 = advanceCurtain(s0, SPEC).state;
  assert.notEqual(s1, s0, "推进必须给出新对象");
  assert.deepEqual(s0, snapshot, "原对象被就地改了 —— 逐拍快照会全部变成最后一个值");
});
