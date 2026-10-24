/**
 * L4 · 世界任务表测试
 *
 * 这张表要兑现的承诺只有一句：「每隔一段时间做一件事，且离线跳时间回来不会瞬间刷满」。
 * 拆成可验证的四块：
 *   ① 表是**纯数据**（能规范化序列化，写函数进去要报错）；
 *   ② 校验把"永不触发 / 除零 / 重名 / 越界"这些**静默失败**变成报错；
 *   ③ 时序：周期与相位按 tick 命中，tick 不许倒退；
 *   ④ ★ 跳时间：一次推进**每个任务最多跑一次**，漏掉的次数由 `missed` 如实报出。
 *
 * ★ 第 ④ 条是本文件的重心。它有两种写法，结果差 100 倍：
 *   · "补齐" —— 跳 1000 tick，period=10 的任务连跑 100 次（每次都要 spawn/写存档/发事件）；
 *   · "一次 + 报告" —— 只跑 1 次，`missed=99` 让调用方知道发生了什么。
 *   判据里两条都跑一遍，用 `stats().runs`（100 vs 1）把这件事钉死。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { CANON_UNSUPPORTED, canonicalize } from "../../src/foundation/canonical.ts";
import { isPassable, type BiomeKind, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import {
  TASK_BAD_TABLE,
  TASK_BAD_TICK,
  WORLD_TASK_SCHEMA,
  WorldTasks,
  taskTableDigest,
  validateTaskTable,
  type TaskFire,
  type WorldTask,
  type WorldTaskTable,
} from "../../src/extensions/worldgen/tasks.ts";

/**
 * 最小计划：`WorldTasks` 只用 `kinds`（选格）—— 它不校验指纹，那是装配的职责。
 * 所以这里直接构造，不必走 `generateWorld`。
 */
function planOf(width: number, height: number, kinds: BiomeKind[]): WorldPlan {
  return { seed: 0, width, height, kinds, sites: [], bridges: [], fingerprint: "" };
}

function tableOf(...tasks: WorldTask[]): WorldTaskTable {
  return { schema: WORLD_TASK_SCHEMA, tasks };
}

function create(table: WorldTaskTable, plan?: WorldPlan): WorldTasks {
  const r = WorldTasks.create(table, plan);
  assert.ok(r.ok, r.ok ? "" : `建表失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function boomTable(table: WorldTaskTable, plan?: WorldPlan): { code: string; message: string } {
  const r = WorldTasks.create(table, plan);
  assert.equal(r.ok, false, "本该报错却建表成功了");
  if (r.ok) throw new Error("unreachable");
  return r.error;
}

function advance(w: WorldTasks, tick: number): readonly TaskFire[] {
  const r = w.advanceTo(tick);
  assert.ok(r.ok, r.ok ? "" : `推进失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

const GRASS9: BiomeKind[] = new Array<BiomeKind>(9).fill("grass");

// ── ① 表是纯数据 ──────────────────────────────────────────────

test("整表能过规范化序列化（「每隔一段时间」这张表必须可存档、可比对）", () => {
  const table = tableOf({ id: "regrow.berry", periodTicks: 20, phase: 3, biomes: ["grass", "forest"], picksPerRun: 4 });
  const r = canonicalize(table);
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  assert.match(r.value, /"periodTicks":20/);
});

test("表里塞函数 ⇒ 规范化序列化报错（纯数据不是靠约定，是靠类型与判据）", () => {
  const r = canonicalize({ schema: WORLD_TASK_SCHEMA, tasks: [{ id: "x", periodTicks: 5, run: () => 1 }] });
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, CANON_UNSUPPORTED);
});

test("表指纹覆盖声明顺序（数组顺序是内容的一部分，不是排版）", () => {
  const a = tableTable(["a", "b"]);
  const b = tableTable(["b", "a"]);
  const da = taskTableDigest(a);
  const db = taskTableDigest(b);
  assert.ok(da.ok && db.ok);
  assert.notEqual(da.value, db.value);
});

function tableTable(ids: string[]): WorldTaskTable {
  return tableOf(...ids.map((id) => ({ id, periodTicks: 10 })));
}

// ── ② 校验：把静默失败变成报错 ────────────────────────────────

test("schema 版本不符 ⇒ 拒绝（旧表不许「勉强能用」）", () => {
  const e = boomTable({ schema: 0, tasks: [{ id: "a", periodTicks: 5 }] });
  assert.equal(e.code, TASK_BAD_TABLE);
  assert.match(e.message, /版本/);
});

test("periodTicks ≤ 0 或非整数 ⇒ 报错（不然就是每 tick 跑或除零）", () => {
  for (const bad of [0, -3, 2.5]) {
    const e = boomTable(tableOf({ id: "a", periodTicks: bad }));
    assert.equal(e.code, TASK_BAD_TABLE, `periodTicks=${bad} 没被拒绝`);
  }
});

test("phase 越界 ⇒ 报错（phase ≥ period 的任务永不触发，这是最典型的静默失败）", () => {
  const e = boomTable(tableOf({ id: "a", periodTicks: 5, phase: 5 }));
  assert.equal(e.code, TASK_BAD_TABLE);
  assert.match(e.message, /永不触发/);
  assert.equal(boomTable(tableOf({ id: "a", periodTicks: 5, phase: -1 })).code, TASK_BAD_TABLE);
});

test("任务 id 重复 ⇒ 报错（两条任务共用一个 seed 与一个计数）", () => {
  const e = boomTable(tableOf({ id: "dup", periodTicks: 5 }, { id: "dup", periodTicks: 7 }));
  assert.equal(e.code, TASK_BAD_TABLE);
  assert.match(e.message, /重复/);
});

test("picksPerRun 越界 ⇒ 报错（一次选空整张地图也是「合法」输入，但没人想要）", () => {
  assert.equal(boomTable(tableOf({ id: "a", periodTicks: 5, picksPerRun: 65 })).code, TASK_BAD_TABLE);
  assert.equal(boomTable(tableOf({ id: "a", periodTicks: 5, picksPerRun: -1 })).code, TASK_BAD_TABLE);
});

test("群系名未知 ⇒ 报错（不是 TypeError，也不是空候选）", () => {
  const e = boomTable(tableOf({ id: "a", periodTicks: 5, biomes: ["lava" as BiomeKind] }));
  assert.equal(e.code, TASK_BAD_TABLE);
  assert.match(e.message, /群系名未知/);
});

test("要按群系选格却没给计划 ⇒ 报错（静默给空数组会让「没刷出来」看起来像「没跑到」）", () => {
  const e = boomTable(tableOf({ id: "a", periodTicks: 5, biomes: ["grass"], picksPerRun: 3 }));
  assert.equal(e.code, TASK_BAD_TABLE);
  assert.match(e.message, /WorldPlan/);
  // 给了计划就正常
  const ok = WorldTasks.create(tableOf({ id: "a", periodTicks: 5, biomes: ["grass"], picksPerRun: 3 }), planOf(3, 3, GRASS9));
  assert.ok(ok.ok);
});

test("校验是纯函数：不改表，且返回的 id 集合与输入一致", () => {
  const table = tableOf({ id: "a", periodTicks: 5 }, { id: "b", periodTicks: 6, phase: 2 });
  const before = JSON.stringify(table);
  const r = validateTaskTable(table);
  assert.ok(r.ok);
  assert.deepEqual(
    r.value.map((t) => t.id),
    ["a", "b"],
  );
  assert.equal(JSON.stringify(table), before);
});

// ── ③ 时序 ────────────────────────────────────────────────────

test("周期命中：period=5 在 tick 5/10 触发，逐 tick 推进时 missed 恒为 0", () => {
  const w = create(tableOf({ id: "a", periodTicks: 5 }));
  const hits: number[] = [];
  let missed = 0;
  for (let t = 1; t <= 12; t++) {
    for (const f of advance(w, t)) {
      hits.push(f.tick);
      missed += f.missed;
    }
  }
  assert.deepEqual(hits, [5, 10]);
  assert.equal(missed, 0);
  assert.equal(w.stats().runs, 2);
});

test("相位生效：period=5, phase=2 在 tick 2/7/12 触发（不是 5/10）", () => {
  const w = create(tableOf({ id: "a", periodTicks: 5, phase: 2 }));
  const hits: number[] = [];
  for (let t = 1; t <= 12; t++) for (const f of advance(w, t)) hits.push(f.tick);
  assert.deepEqual(hits, [2, 7, 12]);
});

test("tick 不许倒退（回档会重复执行同一个 tick）", () => {
  const w = create(tableOf({ id: "a", periodTicks: 5 }));
  advance(w, 10);
  const r = w.advanceTo(9);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, TASK_BAD_TICK);
  assert.match(r.error.message, /倒退/);
  // 停在原地是允许的（幂等）
  assert.equal(advance(w, 10).length, 0);
});

test("tick 必须是整数（1.5 这种会让「命中」依赖浮点）", () => {
  const w = create(tableOf({ id: "a", periodTicks: 5 }));
  const r = w.advanceTo(1.5);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, TASK_BAD_TICK);
});

// ── ④ ★ 跳时间：一次推进最多跑一次 ────────────────────────────

test("★ 跳时间只跑一次：跳 1000 tick，period=10 的任务跑 1 次、missed=99", () => {
  const w = create(tableOf({ id: "a", periodTicks: 10 }));
  const fires = advance(w, 1000);
  assert.equal(fires.length, 1, "一次推进触发了多条 —— 这就是「补齐 100 次」的写法");
  const f = fires[0]!;
  assert.equal(f.tick, 10, "触发 tick 是区间内第一次命中，不是本次 tick");
  assert.equal(f.run, 1);
  assert.equal(f.missed, 99);
  assert.equal(w.stats().missed, 99);
});

test("★ 逐 tick 推进 vs 一次跳时间：同样的时间跨度，执行次数 100 vs 1", () => {
  const perTick = create(tableOf({ id: "a", periodTicks: 10 }));
  for (let t = 1; t <= 1000; t++) advance(perTick, t);
  assert.equal(perTick.stats().runs, 100);
  assert.equal(perTick.stats().missed, 0);

  const jumped = create(tableOf({ id: "a", periodTicks: 10 }));
  advance(jumped, 1000);
  assert.equal(jumped.stats().runs, 1, "跳时间被「补齐」了 —— 离线 8 小时回来会瞬间刷满");
  assert.equal(jumped.stats().missed, 99);
});

test("跳时间后 run 不复位：同一任务下一次执行仍递增（否则会刷在同一批格子）", () => {
  const w = create(tableOf({ id: "a", periodTicks: 10, biomes: ["grass"], picksPerRun: 3 }), planOf(4, 4, new Array<BiomeKind>(16).fill("grass")));
  const first = advance(w, 1000)[0]!;
  const second = advance(w, 1010)[0]!;
  assert.equal(first.run, 1);
  assert.equal(second.run, 2, "run 复位了");
  assert.equal(second.missed, 0);
  // 不同 (tick, run) ⇒ 不同 seed ⇒ 不同格子。这是概率性断言，但 16 选 3 的空间足够大。
  assert.notDeepEqual(second.cells, first.cells);
});

test("同输入 ⇒ 同输出：两个独立实例跑到同一 tick，格子完全一致（可重放）", () => {
  const plan = planOf(6, 6, new Array<BiomeKind>(36).fill("forest"));
  const mk = (): WorldTasks => create(tableOf({ id: "regen", periodTicks: 7, biomes: ["forest"], picksPerRun: 5 }), plan);
  const a = mk();
  const b = mk();
  for (let t = 1; t <= 21; t++) assert.deepEqual(advance(a, t), advance(b, t));
});

test("表的声明顺序不影响单任务的输出（每个任务的随机是独立派生的）", () => {
  const plan = planOf(6, 6, new Array<BiomeKind>(36).fill("grass"));
  const a: WorldTask = { id: "a", periodTicks: 5, biomes: ["grass"], picksPerRun: 4 };
  const b: WorldTask = { id: "b", periodTicks: 5, biomes: ["grass"], picksPerRun: 4 };
  const wa = create(tableOf(a, b), plan);
  const wb = create(tableOf(b, a), plan);
  const fa = advance(wa, 5).find((f) => f.taskId === "a")!;
  const fb = advance(wb, 5).find((f) => f.taskId === "a")!;
  assert.deepEqual(fa, fb, "换个声明顺序就换了产出 —— 说明随机来自一条共享的流");
});

test("一次推进里多任务触发：先按命中 tick 升序，同 tick 再按声明顺序", () => {
  // 表里 late 写在前，但它的命中 tick（8）晚于 early（3）⇒ 输出必须 early 在前
  const w = create(tableOf({ id: "late", periodTicks: 10, phase: 8 }, { id: "early", periodTicks: 10, phase: 3 }));
  const fires = advance(w, 20);
  assert.deepEqual(
    fires.map((f) => [f.taskId, f.tick, f.missed]),
    [
      ["early", 3, 1],
      ["late", 8, 1],
    ],
    "每条任务在这一次推进里只跑一次，各自区间内只剩第一次命中；missed 记下漏掉的另一次",
  );
});

// ── ⑤ 选格 ────────────────────────────────────────────────────

test("选出的格子：群系正确、可通行、数量正确、不重复、升序", () => {
  const kinds: BiomeKind[] = [];
  for (let i = 0; i < 100; i++) kinds.push(i % 2 === 0 ? "grass" : "forest");
  const w = create(tableOf({ id: "a", periodTicks: 5, biomes: ["forest"], picksPerRun: 5 }), planOf(10, 10, kinds));
  const f = advance(w, 5)[0]!;
  assert.equal(f.cells.length, 5);
  assert.equal(new Set(f.cells).size, 5, "选重了");
  for (let i = 1; i < f.cells.length; i++) assert.ok(f.cells[i]! > f.cells[i - 1]!, "没有按升序返回");
  for (const c of f.cells) assert.equal(kinds[c], "forest", `格子 ${c} 不是 forest`);
});

test("候选不够时选满候选为止（不报错、不重复、不编造）", () => {
  const kinds: BiomeKind[] = new Array<BiomeKind>(16).fill("grass");
  kinds[0] = "forest";
  kinds[1] = "forest";
  const w = create(tableOf({ id: "a", periodTicks: 5, biomes: ["forest"], picksPerRun: 8 }), planOf(4, 4, kinds));
  const f = advance(w, 5)[0]!;
  assert.deepEqual(f.cells, [0, 1]);
});

test("没有候选格时返回空数组（不是报错，也不是随便挑一格）", () => {
  const w = create(tableOf({ id: "a", periodTicks: 5, biomes: ["ocean"], picksPerRun: 3 }), planOf(3, 3, GRASS9));
  const f = advance(w, 5)[0]!;
  assert.deepEqual(f.cells, []);
});

test("不选格的任务：cells 恒为空，但计时照常", () => {
  const w = create(tableOf({ id: "tick", periodTicks: 4 }));
  const f = advance(w, 8)[0]!;
  assert.deepEqual(f.cells, []);
  assert.equal(f.tick, 4);
});

// ── ⑥ 运行期状态 ──────────────────────────────────────────────

test("运行不改变表本身（表是内容，计数是运行期状态）", () => {
  const table = tableOf({ id: "a", periodTicks: 5 });
  const before = taskTableDigest(table);
  const w = create(table);
  advance(w, 50);
  const after = taskTableDigest(table);
  assert.ok(before.ok && after.ok);
  assert.equal(after.value, before.value);
  assert.equal(w.runCounts().get("a"), 1);
});

test("stats 自洽：runs = 各任务 runCounts 之和，missed = 各次 fire 的 missed 之和", () => {
  const w = create(tableOf({ id: "a", periodTicks: 5 }, { id: "b", periodTicks: 7 }));
  let missed = 0;
  let fires = 0;
  for (const t of [3, 20, 100, 101]) for (const f of advance(w, t)) {
    fires++;
    missed += f.missed;
  }
  const s = w.stats();
  assert.equal(s.runs, fires);
  assert.equal(s.missed, missed);
  assert.equal(
    [...w.runCounts().values()].reduce((a, b) => a + b, 0),
    fires,
  );
  assert.equal(s.lastTick, 101);
});

test("群系可通行性由 isPassable 决定：不可通行群系即使被写进 biomes 也不会被选中", () => {
  // ocean / cliff 都不可通行 —— 若实现漏了这道判断，会把资源刷到海里
  for (const kind of ["ocean", "cliff"] as const) {
    assert.equal(isPassable(kind), false, `前提失效：${kind} 变成可通行了`);
  }
  const kinds: BiomeKind[] = new Array<BiomeKind>(16).fill("grass");
  kinds[5] = "cliff";
  const w = create(tableOf({ id: "a", periodTicks: 2, biomes: ["grass", "cliff"], picksPerRun: 16 }), planOf(4, 4, kinds));
  const f = advance(w, 2)[0]!;
  assert.ok(!f.cells.includes(5), "把不可通行的悬崖选进去了");
  assert.equal(f.cells.length, 15);
});
