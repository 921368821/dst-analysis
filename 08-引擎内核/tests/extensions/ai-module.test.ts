/**
 * L4 · AI 模块测试 —— 「真的接上了」
 *
 * `behavior.test.ts` 验的是"树算得对不对"；本文件验的是另一件事：
 * **它有没有真的被 tick 驱动**。这两件事必须分开验，否则
 * "树是对的但从来没被调用"会显示成绿色 —— 这正是本项目反复踩的那类坑
 * （迁移链声明了没人调、`selftest.html` 14 条断言从没跑起来过、`actualBackends` 从没被调用）。
 *
 * 所以这里的驱动**一律走真的 `FixedStepScheduler`**，不手搓 `update` 循环。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { FixedStepScheduler } from "../../src/core/scheduler/scheduler.ts";
import { AI_NO_SUCH_AGENT, AI_TOO_MANY_AGENTS, createAiModule } from "../../src/extensions/ai/ai-module.ts";
import { Board, bt, type AiNode, type AiOps, type Status } from "../../src/extensions/ai/behavior.ts";

const FD = 1 / 30;

/**
 * ★ `maxFrameDt` 必须调大：默认 0.25 秒会把 `advance(10/30 = 0.333)` **截断**成 7 步
 *   （这是调度器对"刚切回来"的保护，是正确行为，它自己有判据）。
 *   我们要验的是"AI 不吃 dt"，不是"调度器怎么截断" —— 两件事混在一起，
 *   判据红了会分不清是谁的问题。
 */
function mkScheduler(): FixedStepScheduler {
  return new FixedStepScheduler({ fixedDt: FD, maxStepsPerFrame: 1000, maxFrameDt: 10 });
}

/** 记录被调用（按顺序）的 op 名与 tick。 */
function recorder(): { ops: AiOps; log: string[] } {
  const log: string[] = [];
  const mk = (name: string, st: Status) => (ctx: { tick: number }) => {
    log.push(`${name}@${String(ctx.tick)}`);
    return st;
  };
  const ops: AiOps = {
    ok: mk("ok", "success"),
    no: mk("no", "failure"),
    spin: mk("spin", "running"),
  };
  return { ops, log };
}

test("★ 真接线：scheduler 的每一步都驱动 agent 一次", () => {
  const { ops, log } = recorder();
  const m = createAiModule();
  assert.ok(m.spawn({ tree: bt.do("d", "ok"), ops }).ok);

  const sch = mkScheduler();
  sch.onStep((tick, dt) => {
    m.update(tick, dt);
  });

  sch.advance(FD * 4);
  assert.equal(log.length, 4, `4 步却只驱动了 ${String(log.length)} 次`);
  // ★ tick 是 **1 起**的：FixedStepScheduler 先自增再回调（"第几步"从 1 数，与 0 起的数组下标区分开）
  assert.deepEqual(log, ["ok@1", "ok@2", "ok@3", "ok@4"]);
  assert.deepEqual(m.stats(), { agents: 1, steps: 4, errors: 0, lastTick: 4 });
});

test("暂停时不被驱动（接线的另一半：不该动的时候真的不动）", () => {
  const { ops, log } = recorder();
  const m = createAiModule();
  assert.ok(m.spawn({ tree: bt.do("d", "ok"), ops }).ok);
  const sch = mkScheduler();
  sch.onStep((t, dt) => {
    m.update(t, dt);
  });
  sch.advance(FD * 3);
  assert.equal(log.length, 3);
  sch.paused = true;
  sch.advance(FD * 10);
  assert.equal(log.length, 3, "暂停期间还在驱动");
});

test("★ 不吃 dt：一次推进 10 步 与 分 10 次各推 1 步，结果必须一样", () => {
  const run = (chunked: boolean): string[] => {
    const { ops, log } = recorder();
    const m = createAiModule();
    // wait(3) + 一个动作：决策序列对"被 step 了几次"敏感，对 dt 完全不敏感
    assert.ok(m.spawn({ tree: bt.sequence("s", bt.wait("w", 3), bt.do("d", "ok")), ops }).ok);
    const sch = mkScheduler();
    sch.onStep((t, dt) => {
      m.update(t, dt);
    });
    if (chunked) {
      for (let i = 0; i < 10; i++) sch.advance(FD);
    } else {
      sch.advance(FD * 10);
    }
    return log;
  };
  const a = run(true);
  const b = run(false);
  // wait(3) 在第 3 个 tick 完成 ⇒ 10 步跑 3 整轮（tick 3 / 6 / 9），不是 2 轮
  assert.equal(a.length, 3, `10 步里 wait(3)+do 应跑 3 整轮，实际 ${String(a.length)} 次动作`);
  assert.deepEqual(a, b);
});

test("★ dt 完全不参与决策：dt 从 1e-9 到 100 乱跳，wait(3) 仍然 3 次完成", () => {
  // 上面那条"一次推进 vs 分次推进"用的是**同一个** fixedDt —— 调度器每次都传一样的值，
  // 所以它证明不了"dt 不影响决策"。要证明这一点，必须**直接**把 dt 变起来。
  const { ops, log } = recorder();
  const m = createAiModule();
  assert.ok(m.spawn({ tree: bt.sequence("s", bt.wait("w", 3), bt.do("d", "ok")), ops }).ok);
  const dts = [1e-9, 0.001, 100, 0, 42, 1 / 30, 7, 0.25];
  for (let i = 0; i < 12; i++) m.update(100 + i, dts[i % dts.length]!);
  // 12 步 / 每 3 步一轮 ⇒ 4 次动作；若 dt 参与了决策，次数或 tick 就会对不上
  assert.deepEqual(log, ["ok@102", "ok@105", "ok@108", "ok@111"]);
});

test("驱动顺序 = spawn 顺序（不依赖容器迭代顺序）", () => {
  const log: string[] = [];
  const mkOps = (tag: string): AiOps => ({
    tag: (ctx) => {
      log.push(`${tag}@${String(ctx.tick)}`);
      return "success";
    },
  });
  const m = createAiModule();
  for (const tag of ["a", "b", "c"]) {
    // op 名是 "tag"；tag 只是记录用的标签（写成 bt.do("d", tag) 会变成未注册的 op）
    assert.ok(m.spawn({ tree: bt.do("d", "tag"), ops: mkOps(tag) }).ok);
  }
  m.update(7, FD);
  assert.deepEqual(log, ["a@7", "b@7", "c@7"]);
});

test("★ 一个 agent 抛异常要隔离：其他 agent 继续被驱动，且错误被计数", () => {
  const log: string[] = [];
  const boomOps: AiOps = {
    boom: () => {
      throw new Error("行为炸了");
    },
  };
  const okOps: AiOps = {
    ok: (ctx) => {
      log.push(`ok@${String(ctx.tick)}`);
      return "success";
    },
  };
  const m = createAiModule();
  assert.ok(m.spawn({ tree: bt.do("d", "boom"), ops: boomOps }).ok);
  assert.ok(m.spawn({ tree: bt.do("d", "ok"), ops: okOps }).ok);

  m.update(0, FD);
  m.update(1, FD);
  assert.deepEqual(log, ["ok@0", "ok@1"], "第二个 agent 被第一个的异常带崩了");
  const st = m.stats();
  assert.equal(st.errors, 2);
  assert.equal(st.steps, 2, "抛异常的 agent 不该计入 steps");
});

test("★ 异常后重置记忆：后面的 tick 从**根**重来，而不是续在出错的兄弟上", () => {
  // ★ 这条判据的第一版是假的：当时用 sequence[wait(3), do(boom)]，
  //   断言"再等 3 tick 才炸第二次"。但 wait 在成功那一刻就把进度清了，
  //   抛出时记忆本来就是干净的 ⇒ 重置与不重置**行为完全一样**，
  //   变异 M96（删掉 reset）根本抓不住。**一条抓不住对应变异的判据，等于没写。**
  //
  // 能区分两者的构造：让抛出发生在**靠后的兄弟**上，此时父节点的 cursor 停在那个兄弟，
  //   · 重置 ⇒ 下一 tick 从根重来，前面的兄弟会再被调用一次；
  //   · 不重置 ⇒ 直接从出错的那个兄弟续，前面的兄弟被跳过。
  //   于是"前面兄弟被调用几次"就是可观测的差别。
  let countCalls = 0;
  let flakyCalls = 0;
  const ops: AiOps = {
    count: () => {
      countCalls++;
      return "failure"; // 让 selector 继续往右走
    },
    flaky: () => {
      flakyCalls++;
      if (flakyCalls === 1) return "running"; // 先卡住 ⇒ 父节点的 cursor 停在它身上
      if (flakyCalls <= 3) throw new Error("第二次、第三次炸");
      return "success";
    },
  };
  const m = createAiModule();
  assert.ok(m.spawn({ tree: bt.selector("q", bt.do("a", "count"), bt.do("b", "flaky")), ops }).ok);

  for (let t = 1; t <= 4; t++) m.update(t, FD);

  // 重置版：t1 count + b 卡住；t2 b 炸（err=1）并重置；t3 从根 → count 再来 + b 又炸（err=2）；
  //         t4 从根 → count 再一次 + b 成功 ⇒ count 共 3 次、err 共 2 次
  // 不重置版：t2 炸后 cursor 仍指向 b，t3/t4 直接从 b 续 ⇒ **count 只被调用 1 次**
  assert.equal(m.stats().errors, 2);
  assert.equal(countCalls, 3, `count 被调用 ${String(countCalls)} 次：1 次说明异常后没有从根重来`);
});

test("maxAgents 超限报 AI_TOO_MANY_AGENTS，且不占号", () => {
  const { ops } = recorder();
  const m = createAiModule({ maxAgents: 2 });
  const a = m.spawn({ tree: bt.do("d", "ok"), ops });
  const b = m.spawn({ tree: bt.do("d", "ok"), ops });
  const c = m.spawn({ tree: bt.do("d", "ok"), ops });
  assert.ok(a.ok && b.ok);
  assert.equal(c.ok, false);
  if (!c.ok) assert.equal(c.error.code, AI_TOO_MANY_AGENTS);
  // 腾出一个位置后还能继续注册，且新 id 不是被拒绝的那次"抢"走的号
  assert.equal(m.despawn(a.value), true);
  const d = m.spawn({ tree: bt.do("d", "ok"), ops });
  assert.ok(d.ok);
  if (d.ok) assert.equal(d.value, 3);
});

test("spawn 坏树返回错误且不改变人数", () => {
  const { ops } = recorder();
  const m = createAiModule();
  const bad: AiNode = { id: "s", kind: "sequence" };
  const r = m.spawn({ tree: bad, ops });
  assert.equal(r.ok, false);
  assert.equal(m.agentCount(), 0);
});

test("despawn 之后不再被驱动；移除不存在的 id 返回 false（不抛）", () => {
  const { ops, log } = recorder();
  const m = createAiModule();
  const id = m.spawn({ tree: bt.do("d", "ok"), ops });
  assert.ok(id.ok);
  m.update(0, FD);
  assert.equal(m.despawn(id.value), true);
  m.update(1, FD);
  assert.equal(log.length, 1);
  assert.equal(m.despawn(9999), false);
});

test("黑板各自独立，且能从模块取到", () => {
  const m = createAiModule();
  const bump: AiOps = {
    bump: (ctx) => {
      ctx.board.set("n", ctx.board.get("n") + 1);
      return "success";
    },
  };
  const a = m.spawn({ tree: bt.do("d", "bump"), ops: bump });
  const b = m.spawn({ tree: bt.do("d", "bump"), ops: bump });
  assert.ok(a.ok && b.ok);
  m.update(0, FD);
  m.update(1, FD);
  m.update(2, FD);
  assert.equal(m.board(a.value)?.get("n"), 3);
  assert.equal(m.board(b.value)?.get("n"), 3);
  assert.notEqual(m.board(a.value), m.board(b.value), "两个 agent 共用了同一个黑板");
  assert.equal(m.board(12345), undefined);
});

test("传入的黑板会被采用（不是被忽略后新建一个）", () => {
  const m = createAiModule();
  const board = new Board();
  board.set("seed", 42);
  const read: AiOps = { read: (ctx) => (ctx.board.get("seed") === 42 ? "success" : "failure") };
  const id = m.spawn({ tree: bt.do("d", "read"), ops: read, board });
  assert.ok(id.ok);
  assert.equal(m.board(id.value), board);
  m.update(0, FD);
  assert.equal(m.stats().steps, 1);
});

test("stats 自洽：steps = 每个 tick 的 agent 数之和（异常次数单列）", () => {
  const { ops } = recorder();
  const m = createAiModule();
  m.spawn({ tree: bt.do("d", "ok"), ops });
  m.update(0, FD);
  m.spawn({ tree: bt.do("d", "ok"), ops });
  m.update(1, FD);
  m.spawn({ tree: bt.do("d", "ok"), ops });
  m.update(2, FD);
  assert.equal(m.stats().steps, 1 + 2 + 3);
});

test("dispose 清空一切（stats 归零，不是保留旧值）", () => {
  const { ops } = recorder();
  const m = createAiModule();
  m.spawn({ tree: bt.do("d", "ok"), ops });
  m.update(5, FD);
  m.dispose?.();
  assert.equal(m.agentCount(), 0);
  assert.deepEqual(m.stats(), { agents: 0, steps: 0, errors: 0, lastTick: -1 });
});

test("describe 里有 agent 数与错误数（诊断要能一眼看出异常）", () => {
  const { ops } = recorder();
  const m = createAiModule();
  m.spawn({ tree: bt.do("d", "ok"), ops });
  m.spawn({ tree: bt.do("d", "ok"), ops });
  const s = m.describe?.() ?? "";
  assert.match(s, /2 agent/);
  assert.match(s, /0 error/);
});

test("没有 agent 时 update 不崩（空跑是合法状态）", () => {
  const m = createAiModule();
  m.update(0, FD);
  assert.equal(m.stats().steps, 0);
});

test("NO_SUCH_AGENT 常量存在且与 despawn 的返回值语义一致", () => {
  // 空转断言：保证常量被真的导出（避免"文档写了、代码里没有"）
  assert.equal(AI_NO_SUCH_AGENT, "AI.NO_SUCH_AGENT");
});
