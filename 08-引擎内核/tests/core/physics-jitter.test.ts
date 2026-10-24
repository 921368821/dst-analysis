/**
 * L4 · 物理的**抖振兜底**（迭代用尽之后不许来回摆）
 *
 * ★ 现象与代价：三四个实体挤在角落时，`maxIterations`（默认 3）用尽仍有重叠。
 *   没有兜底时，每帧的表现是"推一点、下一帧又被推回来"—— 位置在小范围里抖，
 *   画面上是"实体在颤"，而 `unresolved` 只记了一个计数，完全看不出在颤。
 *
 * ★ 兜底不是"多迭代几轮"：多迭代会把成本乘上迭代数，而且密集场景里它**也收敛不了**
 *   （推挤工作量与重叠对数成正比，见 `physics-perf.test.ts`）。兜底是**一次**把仍然重叠的
 *   对按重叠量分开，让每一帧都严格往"分开"的方向走一步。
 *
 * ★ 三条性质必须有判据：确定性（不许随机方向）、静态体不动、每对只处理一次。
 *   少任何一条，兜底都比抖动更糟 —— 它会悄悄改存档、改回放、改碰撞规则。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { SpatialHashWorld, type PositionAccessor } from "../../src/extensions/physics/physics.ts";

function makeWorld(maxIterations = 1, cellSize = 4): { world: SpatialHashWorld; pos: Map<number, { x: number; z: number }> } {
  const pos = new Map<number, { x: number; z: number }>();
  const accessor: PositionAccessor = {
    get: (id) => pos.get(id),
    set: (id, x, z) => void pos.set(id, { x, z }),
  };
  return { world: new SpatialHashWorld(accessor, { cellSize, maxIterations }), pos };
}

/** 全场"最深的那个重叠"（>0 表示还有挤在一起的）。 */
function worstOverlap(world: SpatialHashWorld, pos: Map<number, { x: number; z: number }>, radius: number): number {
  const ids = [...pos.keys()];
  let worst = 0;
  for (let i = 0; i < ids.length; i++) {
    for (let j = i + 1; j < ids.length; j++) {
      const a = pos.get(ids[i]!);
      const b = pos.get(ids[j]!);
      if (a === undefined || b === undefined) continue;
      const dist = Math.hypot(a.x - b.x, a.z - b.z);
      worst = Math.max(worst, radius * 2 - dist);
    }
  }
  void world;
  return worst;
}

// ── ① 抖振消失：每一步都在往分开的方向走 ─────────────────────

test("★★ 4 个实体挤在同一点：连续解算 8 次，最深重叠**单调下降**（不再来回摆）", () => {
  const { world, pos } = makeWorld(1);
  const R = 0.5;
  for (let i = 0; i < 4; i++) {
    pos.set(i + 1, { x: 0, z: 0 }); // 完全重合：最坏情况
    world.add({ nodeId: i + 1, radius: R, isStatic: false });
  }

  let prev = worstOverlap(world, pos, R);
  assert.ok(prev > 0.5, `初始重叠只有 ${prev.toFixed(2)} —— 判据没有分辨力`);
  const trail: number[] = [prev];

  for (let step = 0; step < 8; step++) {
    world.resolve();
    const now = worstOverlap(world, pos, R);
    trail.push(now);
    // ★ 单调不增：允许持平（三角堆叠一帧只能挪一点），但**绝不允许变大**
    assert.ok(
      now <= prev + 1e-9,
      `第 ${step + 1} 次解算之后重叠从 ${prev.toFixed(4)} 涨到 ${now.toFixed(4)} —— 在抖：${trail.map((v) => v.toFixed(3)).join(" → ")}`,
    );
    prev = now;
  }
  assert.ok(prev < 0.05, `8 次解算后仍有 ${prev.toFixed(3)} 重叠 —— 兜底没有把它推进收敛`);
});

test("★ 兜底确实被触发：完全重合时 unresolved 会涨，且位置真的变了", () => {
  const { world, pos } = makeWorld(1);
  for (let i = 0; i < 3; i++) {
    pos.set(i + 1, { x: 0, z: 0 });
    world.add({ nodeId: i + 1, radius: 0.5, isStatic: false });
  }
  const before = [...pos.entries()].map(([k, v]) => [k, v.x, v.z] as const);
  world.resolve();
  assert.ok(world.stats().unresolved > 0, "迭代用尽却没计数 —— 兜底分支根本没进");
  const after = [...pos.entries()].map(([k, v]) => [k, v.x, v.z] as const);
  assert.notDeepEqual(after, before, "位置一点没动 —— 兜底是空转");
});

// ── ② 确定性 ────────────────────────────────────────────────

test("★★ 兜底不引入随机：同样的初始状态跑两次，逐节点位置**完全一致**", () => {
  const run = (): string => {
    const { world, pos } = makeWorld(1);
    for (let i = 0; i < 5; i++) {
      pos.set(i + 1, { x: 0, z: 0 });
      world.add({ nodeId: i + 1, radius: 0.5, isStatic: false });
    }
    for (let i = 0; i < 5; i++) world.resolve();
    return [...pos.entries()]
      .sort((a, b) => a[0] - b[0])
      .map(([k, v]) => `${k}:${v.x.toFixed(6)},${v.z.toFixed(6)}`)
      .join("|");
  };
  assert.equal(run(), run(), "两次运行结果不同 —— 兜底里有随机（存档比对与回放会全线失效）");
});

// ── ③ 静态体不动 ────────────────────────────────────────────

test("★★ 兜底不推静态体：夹心拓扑，重叠**真的活进兜底**，静态体一位都不动", () => {
  // ★★ T345：这条判据原来是**弱**的 —— 它只能证明"静态体没被推"，证明不了
  //   "兜底那条分支真的带着重叠的静态对被走过"。试过的四种拓扑（一个静态+一个动态、
  //   1×1 方框、0.5 间距方框、六个静态围成的笼子）全都失败在同一个地方：
  //   `maxIterations=1` 的那一轮里，内层循环会把动态体与**每一个**重叠静态体各推一次，
  //   于是等 `settleOnce` 上场时动态体早被弹飞了，里面一对静态都不剩。
  //
  // ★ 解法不是"再试一种拓扑"，而是让拓扑**利用迭代的顺序性**：
  //   `near` 按 id 升序，内层循环对每个重叠体各推一次、推完不回头。
  //   所以只要"最后一次推动把动态体送回**先处理过**的那个静态体怀里"，
  //   这个重叠就能活过迭代，`settleOnce` 不得不处理一对"动态-静态"。
  //
  //   具体布置（半径全是 1，`maxIterations=1`）：
  //     · 静态 A：id 1，x = 2.5（覆盖 1.5..3.5）
  //     · 静态 B：id 2，x = -1（覆盖 -2..0）
  //     · 动态 D：id 100，x = 0
  //   迭代那一轮：A 距 D 2.5 ≥ 2 ⇒ 不在候选里（`query` 的粗筛就是 r+range）；
  //                B 距 D 1 ⇒ 推 1.0，D 落到 x = 1.0 —— **正落在 A 怀里**（距 1.5 < 2）。
  //   A 在这一轮已经处理过了（id 更小、在 `near` 里排在 B 前面），不会回头 ⇒ 重叠活着进兜底。
  const { world, pos } = makeWorld(1);
  pos.set(1, { x: 2.5, z: 0 });
  pos.set(2, { x: -1, z: 0 });
  pos.set(100, { x: 0, z: 0 });
  world.add({ nodeId: 1, radius: 1, isStatic: true });
  world.add({ nodeId: 2, radius: 1, isStatic: true });
  world.add({ nodeId: 100, radius: 1, isStatic: false });

  const statics = [1, 2].map((id) => ({ ...pos.get(id)! }));
  const before = pos.get(100)!;
  world.resolve();
  const st = world.stats();

  // ① 静态体一位都不动（M164 的靶子：兜底把静态体也推）
  for (const [i, id] of [1, 2].entries()) {
    assert.deepEqual(pos.get(id), statics[i], `静态体 ${id} 被兜底推动了 —— 物理规则在最后一帧变了`);
  }
  // ② 兜底真的被调用，而且里面**处理过动态-静态对**（没有这个计数，①在
  //    "兜底一对静态都没处理"时是恒真的 —— 那正是原来抓不住 M164 的原因）
  assert.ok(st.settlePasses >= 1, "兜底没被触发 —— 这条判据在空转");
  assert.ok(st.settleStaticPushes >= 1, "兜底里一对静态都没处理 ——「静态体不动」是恒真的（T345 的假绿）");
  // ③ 重叠确实活着进了兜底，而且兜底**真的处理了它**：D 最终仍与 B 相交（1.499 < 2）。
  //    这个状态只有"兜底推过 A"才达得到 —— 若兜底跳过静态对，D 会停在 x = 1.001
  //    （距 B 2.001，不相交），两者可区分。注意 A 在 D 被推开后已退出 `near` 的
  //    距离粗筛（2.001 > r+range），所以活下来的重叠是 **B**，不是 A。
  const d = pos.get(100)!;
  assert.ok(Math.hypot(d.x - (-1), d.z) < 2 - 1e-9, `D 与静态 B 已不相交（${d.x.toFixed(3)}）—— 兜底没有真的处理静态对`);
  assert.ok(d.x !== before.x, "D 完全没动 —— 拓扑没有产生任何推挤，判据在空转");
});

// ── ④ 每对只处理一次 ────────────────────────────────────────

test("★ 每对只分离一次：两个重合的动态体分开后，间距 ≈ 2R + skin（不是 4R）", () => {
  const { world, pos } = makeWorld(1);
  pos.set(1, { x: 0, z: 0 });
  pos.set(2, { x: 0, z: 0 });
  world.add({ nodeId: 1, radius: 0.5, isStatic: false });
  world.add({ nodeId: 2, radius: 0.5, isStatic: false });
  world.resolve();
  const a = pos.get(1)!;
  const b = pos.get(2)!;
  const gap = Math.hypot(a.x - b.x, a.z - b.z);
  // 一帧内：迭代推一点、兜底再按剩余重叠对半分 ⇒ 间距落在 (0, 2R + skin] 上，绝不会翻倍。
  // ★ 上限带 skin（默认 0.001）：那是对的 —— 留一条细缝才不会下一步又判定"刚好相切"。
  assert.ok(gap > 0, "两个完全重合的体一帧之后还在一起");
  assert.ok(gap <= 1.02, `间距 ${gap.toFixed(3)} 超过 2R+skin —— 同一对被推了两遍（每对只该处理一次）`);
});
