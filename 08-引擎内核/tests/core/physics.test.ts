/**
 * L4 · 物理测试
 *
 * 重点覆盖"确定性"与"不静默"：
 *  · 完全重合时给**固定**分离方向（用随机数就不可回放）
 *  · 迭代到上限仍未分开要**计数**（说明密度过高，是可观测的事实）
 *  · query 必须与暴力枚举**完全一致**（空间哈希最常见的 bug 是漏格）
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { SpatialHashWorld, makeSceneAccessor } from "../../src/extensions/physics/physics.ts";

interface P {
  x: number;
  z: number;
}

function world(init: Array<[number, P]>) {
  const pos = new Map<number, P>(init);
  const w = new SpatialHashWorld({
    get: (id) => pos.get(id),
    set: (id, x, z) => {
      pos.set(id, { x, z });
    },
  });
  return { w, pos };
}

test("重叠的两个圆被推开到刚好相切（半径和）", () => {
  const { w, pos } = world([
    [1, { x: 0, z: 0 }],
    [2, { x: 0.5, z: 0 }],
  ]);
  w.add({ nodeId: 1, radius: 1, isStatic: false });
  w.add({ nodeId: 2, radius: 1, isStatic: false });
  const moved = w.resolve();
  assert.ok(moved > 0, "应发生推动");
  const a = pos.get(1)!;
  const b = pos.get(2)!;
  const d = Math.hypot(a.x - b.x, a.z - b.z);
  assert.ok(d >= 2 - 0.01, `推开后距离 ${d.toFixed(4)} 应 ≥ 2（含 skin 会略大）`);
  assert.ok(d <= 2 + 0.1, `不应推得过远：${d.toFixed(4)}`);
});

test("静态体不动（树不会因为你撞它而移位）", () => {
  const { w, pos } = world([
    [1, { x: 0, z: 0 }],
    [2, { x: 0.2, z: 0 }],
  ]);
  w.add({ nodeId: 1, radius: 1, isStatic: true });
  w.add({ nodeId: 2, radius: 1, isStatic: false });
  w.resolve();
  assert.deepEqual(pos.get(1), { x: 0, z: 0 }, "静态体位置不变");
  assert.notDeepEqual(pos.get(2), { x: 0.2, z: 0 }, "动态体被推走");
});

test("不重叠就不动（解算不该引入漂移）", () => {
  const { w, pos } = world([
    [1, { x: 0, z: 0 }],
    [2, { x: 10, z: 0 }],
  ]);
  w.add({ nodeId: 1, radius: 1, isStatic: false });
  w.add({ nodeId: 2, radius: 1, isStatic: false });
  assert.equal(w.resolve(), 0);
  assert.deepEqual(pos.get(1), { x: 0, z: 0 });
  assert.deepEqual(pos.get(2), { x: 10, z: 0 });
});

test("完全重合：给**固定**分离方向（确定，可回放）", () => {
  const run = (): P => {
    const { w, pos } = world([
      [1, { x: 5, z: 5 }],
      [2, { x: 5, z: 5 }],
    ]);
    w.add({ nodeId: 1, radius: 1, isStatic: true });
    w.add({ nodeId: 2, radius: 1, isStatic: false });
    w.resolve();
    return pos.get(2)!;
  };
  const a = run();
  const b = run();
  assert.deepEqual(a, b, "两次解算必须给出同一结果（不能用随机方向）");
  assert.ok(a.x > 5, `应沿 +x 推开（确定方向），实际 ${a.x}`);
});

test("query 与暴力枚举完全一致（空间哈希最容易漏格）", () => {
  const { w, pos } = world([]);
  // 撒 200 个确定位置的点（跨多个 cell）
  let seed = 12345;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
  for (let i = 1; i <= 200; i++) {
    const p = { x: rnd() * 100 - 50, z: rnd() * 100 - 50 };
    pos.set(i, p);
    w.add({ nodeId: i, radius: 0.5, isStatic: true });
  }

  for (let k = 0; k < 20; k++) {
    const qx = rnd() * 100 - 50;
    const qz = rnd() * 100 - 50;
    const r = 3 + rnd() * 5;
    const got = new Set(w.query(qx, qz, r));
    const want = new Set<number>();
    for (const [id, p] of pos) {
      const dx = p.x - qx;
      const dz = p.z - qz;
      if (dx * dx + dz * dz <= (r + 0.5) * (r + 0.5) + 1e-9) want.add(id);
    }
    const missing = [...want].filter((x) => !got.has(x));
    const extra = [...got].filter((x) => !want.has(x));
    assert.equal(missing.length, 0, `漏了 ${missing.length} 个（半径 ${r}）`);
    assert.equal(extra.length, 0, `多了 ${extra.length} 个`);
  }
});

test("移动后 reindex 才能被查到（文档里写明的调用契约）", () => {
  const { w, pos } = world([[1, { x: 0, z: 0 }]]);
  w.add({ nodeId: 1, radius: 1, isStatic: true });
  pos.set(1, { x: 50, z: 50 });
  // ★ query 是"粗筛（格子）+ 精确判定（真实距离）"两段。
  //   所以未 reindex 时的后果是**漏**，不是**错**：
  //   · 旧格 (0,0) 里还有它的 id，但精确判定会把它排除 ⇒ 不返回错误结果
  //   · 新格 (50,50) 里没有它 ⇒ 也查不到（这才是真正的代价）
  assert.ok(!w.query(0, 0, 2).includes(1), "旧格不该返回（精确判定已排除）");
  assert.ok(!w.query(50, 50, 2).includes(1), "未 reindex 时新格查不到（=漏）");
  w.reindex(1);
  assert.ok(w.query(50, 50, 2).includes(1), "reindex 后新格能查到");
});

test("密集堆叠：迭代到上限仍未分开要计数（不静默）", () => {
  // ★ 必须先有位置再 add（add 会读位置；没有就抛）——这一条本身就是"早失败"的设计
  const { w, pos } = world([]);
  for (let i = 1; i <= 20; i++) {
    pos.set(i, { x: i * 0.0001, z: 0 });
    w.add({ nodeId: i, radius: 1, isStatic: false });
  }
  const moved = w.resolve();
  const st = w.stats();
  assert.ok(moved > 0, "应发生推动");
  // 20 个半径 1 的实体挤在 0.002 宽度里，3 轮迭代不可能全分开
  assert.ok(st.unresolved > 0, `密集堆叠应记录 unresolved（实际 ${st.unresolved}, pushes ${st.pushes}）`);
});

test("add 时半径 <= 0 立刻抛（而不是生成一个查不到的 body）", () => {
  const { w } = world([[1, { x: 0, z: 0 }]]);
  assert.throws(() => w.add({ nodeId: 1, radius: 0, isStatic: false }), /半径/);
});

test("add 时没有位置立刻抛（PositionAccessor 违约要早失败）", () => {
  const { w } = world([]);
  assert.throws(() => w.add({ nodeId: 99, radius: 1, isStatic: false }), /没有位置/);
});

test("AABB：沿方向投影半径，不与圆混用", () => {
  const { w, pos } = world([
    [1, { x: 0, z: 0 }],
    [2, { x: 1.2, z: 0 }],
  ]);
  // 1 是 2x0.4 的墙（沿 x 半宽 2，沿 z 半高 0.4）
  w.add({ nodeId: 1, radius: 0.4, isStatic: true, halfExtents: { x: 2, z: 0.4 } });
  w.add({ nodeId: 2, radius: 0.5, isStatic: false });
  w.resolve();
  const p = pos.get(2)!;
  // 沿 x 方向的投影半径 = 2，加上 0.5 ⇒ 需要 |dx| >= 2.5
  assert.ok(Math.abs(p.x) >= 2.4, `应被推到墙外（x=${p.x.toFixed(3)}）`);
});

test("makeSceneAccessor：把 Node 的 (x,y) 映射成世界的 (x,z)", () => {
  const nodes = new Map<number, { id: number; wp: { x: number; y: number }; set: (x: number, y: number) => void }>();
  const n = {
    id: 1,
    wp: { x: 3, y: 7 },
    set(x: number, y: number) {
      n.wp = { x, y };
    },
  };
  nodes.set(1, n);
  const acc = makeSceneAccessor((id) => {
    const m = nodes.get(id);
    if (m === undefined) return undefined;
    return {
      id: m.id,
      worldPosition: () => m.wp,
      setLocalPosition: (x: number, y: number) => m.set(x, y),
    };
  });
  assert.deepEqual(acc.get(1), { x: 3, z: 7 });
  acc.set(1, -2, 4);
  assert.deepEqual(acc.get(1), { x: -2, z: 4 });
});

test("★ findEntities 与 query 是同一份实现（饥荒同签名别名，不许另写一遍）", () => {
  const { w, pos } = world([]);
  let seed = 999;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
  // 混入圆与 AABB（halfExtents）两种体，半径也混
  for (let i = 1; i <= 120; i++) {
    const p = { x: rnd() * 60 - 30, z: rnd() * 60 - 30 };
    pos.set(i, p);
    const box = i % 3 === 0;
    w.add(box ? { nodeId: i, radius: 0.4, isStatic: true, halfExtents: { x: 0.6, z: 1.4 } }
              : { nodeId: i, radius: 0.5, isStatic: true });
  }
  for (let k = 0; k < 15; k++) {
    const qx = rnd() * 60 - 30;
    const qz = rnd() * 60 - 30;
    const r = 0.5 + rnd() * 6;
    assert.deepEqual(w.findEntities(qx, qz, r), w.query(qx, qz, r),
      `别名与真身必须在同一点 (${qx.toFixed(2)}, ${qz.toFixed(2)}) r=${r.toFixed(2)} 给出同一数组`);
  }
  // 边界输入同样要一致（负半径 / 0 半径）
  assert.deepEqual(w.findEntities(0, 0, -1), w.query(0, 0, -1));
  assert.deepEqual(w.findEntities(0, 0, 0), w.query(0, 0, 0));
});
