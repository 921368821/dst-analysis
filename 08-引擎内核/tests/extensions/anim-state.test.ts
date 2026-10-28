/**
 * 动画状态机判据（C15）
 *
 * 守三件事：
 *   ① **构造期把数据错误变成错误码** —— 同一 (from, event) 两条转移、转移指向不存在的状态、
 *      空事件名。这些在运行时都表现为「某条动画不播」，而那时已经离根因很远；
 *   ② **未声明的事件不许改变状态** —— 这是这一层最容易被"省事写法"破坏的一条；
 *   ③ **三个布尔量各说各的** —— `consumed` / `changed` / `restart` 在自转移上首次分叉，
 *      合并任意两个都会让「连按跑步键重播起跑」这件事二者不可兼得。
 *
 * ★ 端到端那条（状态机 + clip）验的是「换状态 ⇒ 清零时钟 ⇒ 新 clip 第 0 帧」这条链：
 *   前一层的 `restart` 如果只是"返回了 true 但没人用"，症状是换装后动作从上一段的
 *   进度中间接着播 —— 单看状态机是绿的。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  ANIM_STATE_ERR,
  hasState,
  initialState,
  makeStateMachine,
  stateClip,
  stepState,
  type AnimStateMachineInput,
} from "../../src/extensions/render/anim-state.ts";
import { makeAnimationClip, sampleClip } from "../../src/extensions/render/animation.ts";

/** 一个典型的三角色状态机：idle ⇄ walk，walk → hurt → idle。 */
function machineInput(over: Partial<AnimStateMachineInput> = {}): AnimStateMachineInput {
  return {
    id: "hero",
    states: { idle: "clip.idle", walk: "clip.walk", hurt: "clip.hurt" },
    initial: "idle",
    transitions: [
      { from: "idle", event: "move", to: "walk" },
      { from: "walk", event: "stop", to: "idle" },
      { from: "walk", event: "hit", to: "hurt" },
      { from: "idle", event: "hit", to: "hurt" },
      { from: "hurt", event: "recover", to: "idle" },
    ],
    ...over,
  };
}

function okMachine(over: Partial<AnimStateMachineInput> = {}) {
  const r = makeStateMachine(machineInput(over));
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  return r.value;
}

// ---------------------------------------------------------------- 构造期校验

test("构造成功：状态与转移全部冻结（多实体共享，运行期改不动）", () => {
  const m = okMachine();
  assert.equal(Object.isFrozen(m), true);
  assert.equal(Object.isFrozen(m.states), true);
  assert.throws(() => {
    (m.states as Record<string, string>).idle = "hacked";
  }, TypeError);
  assert.equal(stateClip(m, "idle"), "clip.idle", "冻结失败会让所有实体一起被改掉");
});

test("★ 一个状态都没有时报 EMPTY（不是「默认状态」能糊过去的）", () => {
  const r = makeStateMachine({ id: "m", states: {}, initial: "idle" });
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, ANIM_STATE_ERR.EMPTY);
});

test("★ 初始状态不在表里报 BAD_INITIAL", () => {
  const r = makeStateMachine(machineInput({ initial: "fly" }));
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, ANIM_STATE_ERR.BAD_INITIAL);
});

test("★ 转移起点 / 目标不在表里都报 BAD_TARGET（走到一个没有 clip 的状态）", () => {
  const badFrom = makeStateMachine(
    machineInput({ transitions: [{ from: "fly", event: "x", to: "idle" }] }),
  );
  assert.equal(badFrom.ok, false);
  if (!badFrom.ok) assert.equal(badFrom.error.code, ANIM_STATE_ERR.BAD_TARGET);

  const badTo = makeStateMachine(machineInput({ transitions: [{ from: "idle", event: "x", to: "dead" }] }));
  assert.equal(badTo.ok, false);
  if (!badTo.ok) assert.equal(badTo.error.code, ANIM_STATE_ERR.BAD_TARGET);
});

test("★★ 同一 (状态, 事件) 两条转移必须报 DUPLICATE（对象字面量会静默覆盖，数组才看得见）", () => {
  const r = makeStateMachine(
    machineInput({
      transitions: [
        { from: "idle", event: "move", to: "walk" },
        { from: "idle", event: "move", to: "hurt" },
      ],
    }),
  );
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, ANIM_STATE_ERR.DUPLICATE);
});

test("★ 去重键不会撞车：状态名/事件名里带分隔符也分得开", () => {
  // 若内部用 `from:event` 拼串，这两条会被当成同一条并误报 DUPLICATE。
  const r = makeStateMachine(
    machineInput({
      states: { "a:b": "c1", a: "c2" },
      initial: "a",
      transitions: [
        { from: "a:b", event: "c", to: "a" },
        { from: "a", event: "b:c", to: "a" },
      ],
    }),
  );
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
});

test("★ 空事件名报 BAD_EVENT（否则「没有事件」与「某个事件」混同）", () => {
  const r = makeStateMachine(machineInput({ transitions: [{ from: "idle", event: "", to: "walk" }] }));
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, ANIM_STATE_ERR.BAD_EVENT);
});

// ---------------------------------------------------------------- 转移

test("★ 有声明的事件：换状态、换 clip、三量全为真", () => {
  const m = okMachine();
  const s = stepState(m, "idle", "move");
  assert.equal(s.state, "walk");
  assert.equal(s.clip, "clip.walk");
  assert.equal(s.consumed, true);
  assert.equal(s.changed, true);
  assert.equal(s.restart, true);
});

test("★★ 自转移：状态不变但算「消费了」且要重播（连按跑步键重播起跑）", () => {
  const m = okMachine({
    transitions: [
      { from: "idle", event: "move", to: "walk" },
      { from: "walk", event: "move", to: "walk" },
    ],
  });
  const s = stepState(m, "walk", "move");
  assert.equal(s.state, "walk");
  assert.equal(s.changed, false, "状态名没变");
  assert.equal(s.consumed, true, "事件确实被这个状态接了");
  assert.equal(s.restart, true, "要重播 —— 与 changed 合并就丢了这条");
});

test("★★ 未声明的事件不改变状态、也不重播（不许静默回到 initial）", () => {
  const m = okMachine();
  const s = stepState(m, "walk", "ui.pause");
  assert.equal(s.state, "walk", "跑步时一个无关事件把状态打回待机是最坏的写法");
  assert.equal(s.clip, "clip.walk");
  assert.equal(s.consumed, false);
  assert.equal(s.changed, false);
  assert.equal(s.restart, false, "没发生转移就不该清零时钟");
});

test("★ 同一事件在不同状态走不同目标（转移是上下文敏感的）", () => {
  const m = okMachine();
  assert.equal(stepState(m, "idle", "hit").state, "hurt");
  assert.equal(stepState(m, "walk", "hit").state, "hurt");
  assert.equal(stepState(m, "idle", "stop").consumed, false, "idle 没接 stop");
});

test("★ 未知的当前状态抛 TypeError（不是返回空串让下游「找不到 clip」）", () => {
  const m = okMachine();
  assert.throws(() => stepState(m, "fly", "move"), TypeError);
  assert.throws(() => stateClip(m, "fly"), TypeError);
});

test("hasState：存档里的旧状态名要先问一句", () => {
  const m = okMachine();
  assert.equal(hasState(m, "walk"), true);
  assert.equal(hasState(m, "fly"), false);
});

test("initialState：初始状态 + 该播的 clip，且标记为「要重播」", () => {
  const m = okMachine();
  const s = initialState(m);
  assert.equal(s.state, "idle");
  assert.equal(s.clip, "clip.idle");
  assert.equal(s.consumed, false);
  assert.equal(s.changed, true);
  assert.equal(s.restart, true);
});

test("转移表为空也能构造（单状态机：任何事件都不改变它）", () => {
  const r = makeStateMachine({ id: "static", states: { idle: "clip.idle" }, initial: "idle" });
  assert.ok(r.ok);
  const s = stepState(r.value, "idle", "anything");
  assert.equal(s.state, "idle");
  assert.equal(s.consumed, false);
});

test("构造不就地改入参：同一份 transitions 数组可以再构造一次", () => {
  const input = machineInput();
  const before = JSON.stringify(input.transitions);
  okMachine(input);
  assert.equal(JSON.stringify(input.transitions), before);
  assert.equal(input.transitions!.length, 5, "构造不该吞掉或改写数组");
});

// ---------------------------------------------------------------- 端到端

test("★★★ 端到端：换状态 ⇒ 时钟清零 ⇒ 新 clip 第 0 帧（restart 真的被用上）", () => {
  const idle = makeAnimationClip({ id: "clip.idle", frames: ["i0", "i1"], durationsMs: [50, 50] });
  const walk = makeAnimationClip({ id: "clip.walk", frames: ["w0", "w1"], durationsMs: [50, 50] });
  assert.ok(idle.ok && walk.ok);
  const m = okMachine();

  // 在 walk 里播到 70ms（第 0 轮、第 1 帧；总时长 100ms）
  assert.equal(sampleClip(walk.value, 70).frame, "w1");

  // 收到 stop：回到 idle，restart ⇒ 调用方把时钟清零
  const s = stepState(m, "walk", "stop");
  assert.equal(s.state, "idle");
  assert.equal(s.restart, true);
  let timeMs = 70;
  if (s.restart) timeMs = 0;
  assert.equal(sampleClip(idle.value, timeMs).frame, "i0", "不清零会从上一段进度中间接着播");

  // 反过来：未声明事件不清零
  const untouched = stepState(m, "walk", "ui.pause");
  assert.equal(untouched.restart, false);
  assert.equal(sampleClip(walk.value, 70).frame, "w1");
});
