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

// ------------------------------------------------------------------ 冻结（批73 · hitstop）
//
// 这一组守的是文件头 ★★ 的那三条：冻结是**独立通道**（不借 paused / timeScale）、
// 时长按逻辑步指定而按真实时间消耗（帧率无关）、到期不补跑。
// 每条都配了"实现写错会怎样"—— 特别是 ②，按帧数消耗是**最顺手的错法**
// （`freezeTicks--` 写在 advance 开头），而它在 60Hz 上看不出任何问题。

test("冻结期间一步都不走，且渲染侧仍能拿到帧（advance 返回 0 但不抛）", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  const seen: number[] = [];
  s.onStep((t) => seen.push(t));
  s.freeze(2);
  assert.equal(s.frozen, true);
  assert.equal(s.advance(1 / 60), 0, "冻结中一步都不跑");
  assert.equal(s.advance(1 / 60), 0);
  assert.equal(s.tick, 0);
  assert.deepEqual(seen, [], "回调一次都不该发生");
});

test("★ 冻结时长 = 步数 × fixedDt 的**真实时间**：60Hz 与 144Hz 冻得一样久", () => {
  // 按帧数消耗（每帧 -1）是最顺手的错法：60Hz 上完全看不出问题，
  // 只有把两种帧率放在一起比才会暴露 —— 144Hz 下会只冻一半久。
  const run = (dt: number): number => {
    const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
    s.freeze(2);
    let frames = 0;
    let real = 0;
    while (s.frozen) {
      s.advance(dt);
      frames++;
      real += dt;
      if (frames > 1000) throw new Error("冻结不结束");
    }
    return real;
  };
  const at60 = run(1 / 60);
  const at144 = run(1 / 144);
  // 2 步 × 1/30 秒 = 1/15 秒（两种帧率下都允许一帧的舍入）
  assert.ok(Math.abs(at60 - 1 / 15) <= 1 / 60, `60Hz 应冻 1/15 秒，实际 ${at60.toFixed(4)}`);
  assert.ok(Math.abs(at144 - 1 / 15) <= 1 / 144, `144Hz 应冻 1/15 秒，实际 ${at144.toFixed(4)}`);
});

test("★ 到期不补跑：剩余真实时间丢弃，恢复后的第一帧不跳步", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, maxStepsPerFrame: 10 });
  s.freeze(1);
  s.advance(0.02); // 20ms < 33.3ms，还在冻
  assert.equal(s.frozen, true);
  s.advance(0.02); // 累计 40ms：消耗 1 步冻结，剩 6.7ms
  assert.equal(s.frozen, false, "40ms 够 1 步冻结");
  assert.equal(s.tick, 0, "到期那一帧不许补跑一步");
  // 补跑的写法会让下一帧直接跑 1 步（6.7ms 不够，但如果累加器没被正确处理就会）
  assert.equal(s.advance(0.02), 0, "20ms 不够一个逻辑步");
  assert.equal(s.advance(0.02), 1, "再 20ms 才够一步");
  assert.equal(s.tick, 1);
});

test("★ 到期时剩余的真实时间**不留给下一次冻结**（否则第二次顿帧莫名短一截）", () => {
  // 一次大帧（0.25s 被 maxFrameDt 收满）冻 1 步：消耗 1/30，剩余约 0.217s。
  // 这剩余必须丢弃 —— 留着的话下一次冻结一开始就"预支"了 0.2 秒，瞬间结束。
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, maxStepsPerFrame: 10 });
  s.freeze(1);
  s.advance(0.25);
  assert.equal(s.frozen, false, "一帧就收掉了 1 步");
  // 第二次冻结必须拿满时长：两个 10ms 帧还不够一步
  s.freeze(1);
  s.advance(0.01);
  assert.equal(s.frozen, true, "第一次 10ms：不该被上一次的剩余顶掉");
  s.advance(0.01);
  assert.equal(s.frozen, true, "第二次 10ms：仍不够一步（残留会让它在这里结束）");
  s.advance(0.01);
  s.advance(0.01);
  assert.equal(s.frozen, false, "40ms 才该结束");
});

test("冻结中触发（真实路径：onHit 在 step 里调 freeze）：本步照常完成，下一步被冻住", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, maxStepsPerFrame: 10 });
  const seen: number[] = [];
  s.onStep((t) => {
    seen.push(t);
    if (t === 1) s.freeze(3); // 命中发生在这一步的回调里
  });
  assert.equal(s.advance(1 / 30), 1, "触发那一帧照常跑完");
  assert.equal(s.tick, 1);
  assert.equal(s.frozen, true, "下一步开始冻");
  assert.equal(s.advance(1 / 30), 0);
  assert.deepEqual(seen, [1]);
});

test("重复触发取最长剩余，不累加（连击不会越冻越久）", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  s.freeze(4);
  s.freeze(2); // 更短：不该缩短
  assert.equal(s.freezeTicks, 4);
  s.freeze(6); // 更长：延长
  assert.equal(s.freezeTicks, 6);
  // 累加的写法这里会得到 4+6=10
});

test("★ 与 paused 是两条通道：冻结到期不会解除用户的暂停", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, maxStepsPerFrame: 10 });
  s.freeze(1);
  s.paused = true; // 顿帧期间玩家手动暂停
  s.advance(1 / 30);
  assert.equal(s.frozen, true, "暂停期间冻结不消耗（时间不算）");
  assert.equal(s.freezeTicks, 1);
  s.paused = false;
  s.advance(1 / 30); // 恢复后冻结才开始收
  assert.equal(s.frozen, false, "恢复后这一步收掉了冻结");
  assert.equal(s.paused, false);
  // 借道 paused 的实现：到期时写 paused=false 会把用户的暂停也解除 —— 下面这条钉住
  s.paused = true;
  s.freeze(1);
  s.paused = false;
  s.advance(1 / 30);
  assert.equal(s.paused, false, "冻结到期只动冻结，不动暂停位");
});

test("stepTo / stepOnce 旁路冻结（逻辑跳转不消耗真实时间），跳完剩余冻结照旧", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  const seen: number[] = [];
  s.onStep((t) => seen.push(t));
  s.freeze(2);
  assert.equal(s.stepTo(5), 5, "冻结中逻辑跳转照常执行");
  assert.deepEqual(seen, [1, 2, 3, 4, 5]);
  assert.equal(s.freezeTicks, 2, "跳转不消耗冻结预算");
  assert.equal(s.advance(1 / 30), 0, "跳完之后冻结仍然生效");
});

test("resetTo 清掉冻结（读档不该让人物保持被冻住的那一瞬间）", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  s.freeze(5);
  s.resetTo(100);
  assert.equal(s.frozen, false);
  assert.equal(s.freezeTicks, 0);
  assert.equal(s.stats().totalFreezeTicks, 0, "读档不继承冻结账");
});

test("冻结步数入账：totalFreezeTicks 记的是**消耗掉**的，不是请求的", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30, maxStepsPerFrame: 10 });
  s.freeze(2);
  s.advance(1 / 60); // 16.7ms：还不够一步冻结
  assert.equal(s.stats().totalFreezeTicks, 0, "半步不记");
  assert.equal(s.freezeTicks, 2, "半步也不该收掉一步");
  s.advance(1 / 60); // 累计 33.3ms：收掉第一步
  assert.equal(s.stats().totalFreezeTicks, 1, "66ms 收掉第一步");
  assert.equal(s.freezeTicks, 1, "还剩一步");
  s.advance(1 / 60); // 又是半步
  assert.equal(s.stats().totalFreezeTicks, 1, "半步不记");
  s.advance(1 / 60); // 收掉第二步
  assert.equal(s.stats().totalFreezeTicks, 2);
  assert.equal(s.frozen, false);
});

test("非法冻结步数抛错（0 / 负数 / 小数 / NaN），不静默夹取", () => {
  const s = new FixedStepScheduler({ fixedDt: 1 / 30 });
  for (const bad of [0, -1, 1.5, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.throws(() => s.freeze(bad), RangeError, `${String(bad)} 应被拒绝`);
  }
  assert.equal(s.frozen, false, "失败的请求不该留下任何冻结");
});
