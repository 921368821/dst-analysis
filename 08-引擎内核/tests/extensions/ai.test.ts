/**
 * L4 · AI 行为树测试
 *
 * 这组判据只做一件事：把三条承诺变成**可观测的数字**，而不是靠读代码相信。
 *
 *  · 「只有 running 带记忆」→ 数 `do` 被调用了几次（不是看 cursor 有没有存对）
 *  · 「不吃 dt」→ 把 tick 值跳成 0/100/1000/10000，`wait(3)` 仍然恰好需要 3 次 step
 *  · 「树是纯数据」→ step 前后对树做 JSON 快照，必须逐字节相同
 *
 * ★ 记忆必须挂在 agent 上：这条只有**多个 agent 共用同一棵树**时才暴露，
 *   所以本文件必有一条"两个 agent 互不干扰"。单 agent 的判据永远抓不到这个 bug。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  AI_BAD_TREE,
  AI_DUPLICATE_ID,
  AI_TOO_DEEP,
  AI_UNKNOWN_OP,
  AiAgent,
  Board,
  bt,
  type AiNode,
  type AiOps,
  type AiTick,
} from "../../src/extensions/ai/behavior.ts";

interface Fixture {
  readonly ops: AiOps;
  readonly calls: string[];
}

function fixture(extra: Record<string, (c: AiTick) => "success" | "failure" | "running"> = {}): Fixture {
  const calls: string[] = [];
  const base: Record<string, (c: AiTick) => "success" | "failure" | "running"> = {
    ok: () => "success",
    no: () => "failure",
    spin: () => "running",
    ...extra,
  };
  const ops: AiOps = Object.fromEntries(
    Object.entries(base).map(([name, fn]) => [
      name,
      (c: AiTick) => {
        calls.push(name);
        return fn(c);
      },
    ]),
  );
  return { ops, calls };
}

function mk(tree: AiNode, ops: AiOps): AiAgent {
  const r = AiAgent.create(tree, ops);
  assert.ok(r.ok, r.ok ? "" : `构造失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function mkErr(tree: AiNode, ops: AiOps): { code: string; message: string } {
  const r = AiAgent.create(tree, ops);
  assert.equal(r.ok, false, "本该拒绝这棵树，却构造成功了");
  if (r.ok) throw new Error("unreachable");
  return r.error;
}

let now = 0;
function tick(board = new Board()): AiTick {
  now++;
  return { tick: now, board };
}

// ── sequence / selector / inverter 的短路语义 ────────────────

test("sequence 全成功 → success，每个子节点各跑一次", () => {
  const f = fixture();
  const a = mk(bt.sequence("s", bt.do("1", "ok"), bt.do("2", "ok"), bt.do("3", "ok")), f.ops);
  assert.equal(a.step(tick()), "success");
  assert.deepEqual(f.calls, ["ok", "ok", "ok"]);
});

test("sequence 遇 failure 立刻返回，后面的子节点**不被执行**", () => {
  const f = fixture();
  const a = mk(bt.sequence("s", bt.do("1", "ok"), bt.do("2", "no"), bt.do("3", "ok")), f.ops);
  assert.equal(a.step(tick()), "failure");
  assert.deepEqual(f.calls, ["ok", "no"], "失败之后还在往下跑，说明短路没做");
});

test("sequence 遇 running 记住位置：前面的分支下一 tick 不再执行", () => {
  const f = fixture();
  const a = mk(
    bt.sequence("s", bt.do("1", "ok"), bt.wait("w", 2), bt.do("3", "ok")),
    f.ops,
  );
  assert.equal(a.step(tick()), "running");
  assert.equal(a.step(tick()), "success");
  // ok 只在第一 tick 跑过一次。若每 tick 都从 0 重来，这里会是 2 次。
  assert.deepEqual(f.calls, ["ok", "ok"]);
  assert.equal(a.memorySize(), 0, "整轮成功之后不该留下记忆");
});

test("selector 遇 success 立刻返回，后面的子节点**不被执行**", () => {
  const f = fixture();
  const a = mk(bt.selector("q", bt.do("1", "no"), bt.do("2", "ok"), bt.do("3", "ok")), f.ops);
  assert.equal(a.step(tick()), "success");
  assert.deepEqual(f.calls, ["no", "ok"]);
});

test("selector 全部 failure → failure", () => {
  const f = fixture();
  const a = mk(bt.selector("q", bt.do("1", "no"), bt.do("2", "no")), f.ops);
  assert.equal(a.step(tick()), "failure");
  assert.deepEqual(f.calls, ["no", "no"]);
});

test("selector 遇 running 记住位置：续在同一个分支上，不跳到后面的", () => {
  const f = fixture();
  const a = mk(bt.selector("q", bt.wait("w", 2), bt.do("2", "ok")), f.ops);
  assert.equal(a.step(tick()), "running");
  assert.equal(a.step(tick()), "success");
  // 第二分支（ok）一次都不该被调用：wait 完成后 selector 已经成功
  assert.deepEqual(f.calls, []);
});

test("inverter 三态：success↔failure，running 原样透传", () => {
  const f = fixture();
  assert.equal(mk(bt.inverter("i", bt.do("a", "ok")), f.ops).step(tick()), "failure");
  assert.equal(mk(bt.inverter("i", bt.do("a", "no")), f.ops).step(tick()), "success");
  assert.equal(mk(bt.inverter("i", bt.do("a", "spin")), f.ops).step(tick()), "running");
});

// ── wait：吃 tick，不吃 dt ───────────────────────────────────

test("wait(3) 恰好需要 3 次 step：前两次 running，第三次 success", () => {
  const f = fixture();
  const a = mk(bt.wait("w", 3), f.ops);
  assert.equal(a.step(tick()), "running");
  assert.equal(a.step(tick()), "running");
  assert.equal(a.step(tick()), "success");
  assert.equal(a.memorySize(), 0);
});

test("★ 不吃 dt：把 tick 值跳成 0/1000/100000，wait(3) 仍然恰好 3 次", () => {
  const f = fixture();
  const a = mk(bt.wait("w", 3), f.ops);
  const board = new Board();
  assert.equal(a.step({ tick: 0, board }), "running");
  assert.equal(a.step({ tick: 1000, board }), "running");
  assert.equal(a.step({ tick: 100000, board }), "success", "被 tick 值影响了：说明吃的是 dt");
});

test("wait(0) 当场成功（不是「先等一 tick」）", () => {
  const f = fixture();
  assert.equal(mk(bt.wait("w", 0), f.ops).step(tick()), "success");
});

test("一轮走完后会重新开始：10 个 step 里 wait(2)+do 正好跑 5 轮", () => {
  const f = fixture();
  const a = mk(bt.sequence("s", bt.wait("w", 2), bt.do("d", "ok")), f.ops);
  const board = new Board();
  for (let i = 0; i < 10; i++) a.step({ tick: i, board });
  assert.equal(f.calls.filter((c) => c === "ok").length, 5);
});

// ── 记忆的归属 ───────────────────────────────────────────────

test("★ 同一棵树、两个 agent：记忆互不干扰", () => {
  const f = fixture();
  const tree = bt.sequence("s", bt.wait("w", 3), bt.do("d", "ok"));
  const a = mk(tree, f.ops);
  const b = mk(tree, f.ops);

  // a 走两 tick（wait 还没完成），b 从头开始
  // memorySize = cursor 条数 + elapsed 条数：sequence 记 1 条、wait 记 1 条 ⇒ 2
  assert.equal(a.step(tick()), "running");
  assert.equal(a.step(tick()), "running");
  assert.equal(a.memorySize(), 2);
  assert.equal(b.memorySize(), 0, "b 还没跑过，不该有记忆");

  assert.equal(b.step(tick()), "running");
  assert.equal(a.memorySize(), 2);
  assert.equal(b.memorySize(), 2);

  // a 的第三 tick 完成 wait；b 才第二 tick
  assert.equal(a.step(tick()), "success");
  assert.equal(b.step(tick()), "running", "两个 agent 的记忆串了");
});

test("reset 清掉全部记忆（wait 进度归零）", () => {
  const f = fixture();
  const a = mk(bt.wait("w", 3), f.ops);
  a.step(tick());
  a.step(tick());
  assert.equal(a.memorySize(), 1);
  a.reset();
  assert.equal(a.memorySize(), 0);
  // 归零后重新数：还要 3 次
  assert.equal(a.step(tick()), "running");
  assert.equal(a.step(tick()), "running");
  assert.equal(a.step(tick()), "success");
});

// ── 树是纯数据 ───────────────────────────────────────────────

test("★ step 不改树：跑 5 个 tick 后树的 JSON 快照必须逐字节相同", () => {
  const f = fixture();
  const tree = bt.selector("q", bt.sequence("s", bt.wait("w", 2), bt.do("d", "ok")), bt.do("e", "no"));
  const before = JSON.stringify(tree);
  const a = mk(tree, f.ops);
  for (let i = 0; i < 5; i++) a.step(tick());
  assert.equal(JSON.stringify(tree), before, "记忆被写进树里了");
});

test("树 JSON 往返之后行为完全一致（函数没藏在树里）", () => {
  const f = fixture();
  const tree = bt.sequence("s", bt.wait("w", 2), bt.do("d", "ok"));
  const round = JSON.parse(JSON.stringify(tree)) as AiNode;
  const a = mk(tree, f.ops);
  const b = mk(round, f.ops);
  const seqA: string[] = [];
  const seqB: string[] = [];
  for (let i = 0; i < 6; i++) {
    seqA.push(a.step(tick()));
    seqB.push(b.step(tick()));
  }
  assert.deepEqual(seqA, seqB);
});

test("同一份操作序列跑两次得到同样的状态序列（无隐藏状态）", () => {
  const run = (): string[] => {
    const f = fixture();
    const a = mk(bt.selector("q", bt.wait("w", 2), bt.do("d", "ok")), f.ops);
    const out: string[] = [];
    for (let i = 0; i < 5; i++) out.push(a.step({ tick: i * 37, board: new Board() }));
    return [...out, `calls=${f.calls.join(",")}`];
  };
  assert.deepEqual(run(), run());
});

// ── 构造期校验：坏树要在构造时报，不要跑到那一支才炸 ────────

test("引用未注册的行为 → AI.UNKNOWN_OP（构造时）", () => {
  const f = fixture();
  const e = mkErr(bt.sequence("s", bt.do("1", "nope")), f.ops);
  assert.equal(e.code, AI_UNKNOWN_OP);
  assert.match(e.message, /nope/);
});

test("重复 id → AI.DUPLICATE_ID（否则两个节点共用一份记忆）", () => {
  const f = fixture();
  const e = mkErr(bt.sequence("s", bt.wait("same", 1), bt.do("same", "ok")), f.ops);
  assert.equal(e.code, AI_DUPLICATE_ID);
});

test("sequence 没有子节点 → AI.BAD_TREE", () => {
  const f = fixture();
  assert.equal(mkErr(bt.sequence("s"), f.ops).code, AI_BAD_TREE);
});

test("inverter 子节点数 ≠ 1 → AI.BAD_TREE", () => {
  const f = fixture();
  const e = mkErr({ id: "i", kind: "inverter", children: [bt.do("a", "ok"), bt.do("b", "ok")] }, f.ops);
  assert.equal(e.code, AI_BAD_TREE);
});

test("wait 的 ticks 不是 >= 0 的整数 → AI.BAD_TREE", () => {
  const f = fixture();
  assert.equal(mkErr({ id: "w", kind: "wait", ticks: -1 }, f.ops).code, AI_BAD_TREE);
  assert.equal(mkErr({ id: "w", kind: "wait", ticks: 1.5 }, f.ops).code, AI_BAD_TREE);
  assert.equal(mkErr({ id: "w", kind: "wait" }, f.ops).code, AI_BAD_TREE);
});

test("do/check 带子节点 → AI.BAD_TREE（叶子就该是叶子）", () => {
  const f = fixture();
  const e = mkErr({ id: "d", kind: "do", op: "ok", children: [bt.do("x", "ok")] }, f.ops);
  assert.equal(e.code, AI_BAD_TREE);
});

test("深度超限 → AI.TOO_DEEP（数据里藏了环时表现为这个，而不是栈溢出）", () => {
  const f = fixture();
  let node: AiNode = bt.do("leaf", "ok");
  for (let i = 0; i < 70; i++) node = bt.sequence(`s${String(i)}`, node);
  assert.equal(mkErr(node, f.ops).code, AI_TOO_DEEP);
});

// ── 黑板 ─────────────────────────────────────────────────────

test("黑板只放数字，快照按键升序（便于比对）", () => {
  const b = new Board();
  b.set("z", 2);
  b.set("a", 1);
  assert.deepEqual(Object.keys(b.snapshot()), ["a", "z"]);
  assert.equal(b.get("missing"), 0);
  assert.equal(b.has("missing"), false);
});

test("行为能通过黑板在 tick 之间传递数字（而不是靠闭包变量）", () => {
  const f = fixture({
    bump: (c) => {
      c.board.set("n", c.board.get("n") + 1);
      return "success";
    },
  });
  const board = new Board();
  const a = mk(bt.do("d", "bump"), f.ops);
  a.step({ tick: 1, board });
  a.step({ tick: 2, board });
  assert.equal(board.get("n"), 2);
  assert.deepEqual(board.snapshot(), { n: 2 });
});
