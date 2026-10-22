/**
 * L2 · 调度器测试
 *
 * 每条正向断言都配一条"如果实现写错会怎样"的说明 —— 这样将来改实现时，
 * 知道哪条断言在守什么（而不是"改了红了就放宽阈值"）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { FixedStepScheduler } from "../../src/core/scheduler/scheduler.ts";

test("固定步长：60Hz 帧率下每两帧推进一个 30Hz 逻辑步", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  // 第一帧只累积（1/60 < 1/30），不应推进
  assert.equal(s.advance(1 / 60), 0);
  assert.equal(s.tick, 0);
  // 第二帧累积到 1/30 ⇒ 推进 1 步
  assert.equal(s.advance(1 / 60), 1);
  assert.equal(s.tick, 1);
  assert.equal(s.time, 1 / 30);
});

test("追帧：一次喂 1 秒只跑 maxSteps 步，其余**丢弃并记账**（不静默）", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, maxStepsPerFrame: 5, maxFrameDt: 10 });
  const steps = s.advance(1.0);
  assert.equal(steps, 5, "上限就是 5 步");
  assert.equal(s.tick, 5);
  // 1 秒 = 30 步，跑了 5 步 ⇒ 至少 25 步被丢（可能多一点，因为累加器余量）
  assert.ok(s.stats().droppedSteps >= 25, `应记录丢弃步数，实际 ${s.stats().droppedSteps}`);
});

test("单帧上限：超长 dt 被截断到 maxFrameDt（切标签页回来不跑 18000 步）", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, maxStepsPerFrame: 100, maxFrameDt: 0.25 });
  const steps = s.advance(600); // 10 分钟
  // 0.25 秒 ≈ 7.5 步 ⇒ 最多 8 步
  assert.ok(steps <= 8, `截断后应 ≤8 步，实际 ${steps}`);
  assert.ok(s.tick <= 8);
});

test("幂等：stepTo 回退返回 0 且世界不回退", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  const seen: number[] = [];
  s.onStep((t) => seen.push(t));
  s.stepTo(3);
  assert.equal(s.tick, 3);
  assert.deepEqual(seen, [1, 2, 3]);
  // 回退：不重放
  assert.equal(s.stepTo(1), 0);
  assert.equal(s.tick, 3);
  assert.deepEqual(seen, [1, 2, 3], "不允许重复回调同一个 tick");
});

test("暂停：不推进；恢复后**不补跑**暂停期间的真实时间", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, maxFrameDt: 10 });
  s.advance(1 / 30);
  assert.equal(s.tick, 1);

  s.paused = true;
  // 暂停 5 秒（多帧）
  for (let i = 0; i < 300; i++) s.advance(1 / 60);
  assert.equal(s.tick, 1, "暂停期间 tick 不许动");

  s.paused = false;
  // ★ 恢复后的第一帧只推进"这一帧"的时间，不是暂停期累积的 5 秒
  const steps = s.advance(1 / 30);
  assert.equal(steps, 1, `恢复后第一帧应只跑 1 步，实际 ${steps}`);
  assert.equal(s.tick, 2);
});

test("alpha 在 [0,1) 且用于插值（不参与逻辑）", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  s.advance(1 / 60); // 半拍
  const a = s.alpha;
  assert.ok(a > 0.4 && a < 0.6, `半拍时 alpha 应≈0.5，实际 ${a}`);
  s.advance(1 / 60); // 满一拍，余 0
  assert.ok(s.alpha < 0.05, `满拍后 alpha 应≈0，实际 ${s.alpha}`);
});

test("负 dt 不推进（时钟回退是宿主 bug，但不许让世界倒退）", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  s.advance(1 / 30);
  assert.equal(s.advance(-1), 0);
  assert.equal(s.tick, 1);
});

test("timeScale 影响累积速度，但不改变单步语义", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, timeScale: 2 });
  assert.equal(s.advance(1 / 60), 1, "2 倍速下 1/60 秒 = 1 个逻辑步");
  assert.equal(s.time, 1 / 30);
});

test("resetTo：读档时把 tick 设回来，不执行中间步", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  const seen: number[] = [];
  s.onStep((t) => seen.push(t));
  s.stepTo(3);
  seen.length = 0;
  s.resetTo(100);
  assert.equal(s.tick, 100);
  assert.equal(s.time, 100 / 30);
  assert.deepEqual(seen, [], "resetTo 不许执行任何 step");
  // 接着推进必须从 101 开始（幂等记录也要跟着设）
  s.stepTo(101);
  assert.deepEqual(seen, [101]);
});
