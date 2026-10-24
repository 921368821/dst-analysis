/**
 * L4 · 物理的**工作量**判据（不是毫秒判据）
 *
 * ★★ 为什么这一组必须存在，而毫秒闸门不够：
 *   2000 体 30Hz 的解算预算是 8ms，现实布局实测 0.74ms。三处 O(n²) 开销
 *   （`maxRadiusNearby` 每体重算 / `reindex` 遍历所有格 / `resolve` 遍历静态体）
 *   在真实规模下加起来只值 ~2ms —— **从 0.74 退到 2.7 依然全绿**。
 *   于是"性能已修好"这句话在毫秒上永远没有证据。
 *
 *   唯一钉得住的是**次数**：解算 N 个动态体就该读 N 次；缓存的事就不该在解算里扫全场；
 *   格索引是 O(1) 就该一次格都不遍历。次数与机器快慢无关，与缓存局部性无关，
 *   而且**回归时会精确地翻倍**，不会像毫秒那样被噪声吃掉。
 *
 * ★ 这一组判据写出来当天就抓到一个真缺陷：`maxRadiusNearby()` 的注释写着 O(1)，
 *   代码却是 `for (const b of this.bodies.values())` —— 缓存 `maxRange` 一直在维护，
 *   **却没有任何地方读它**。一次 2000 体的解算因此多扫了 6000 个 body。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { SpatialHashWorld, type PositionAccessor, type PhysicsBody } from "../../src/extensions/physics/physics.ts";

/** 用一张 Map 当"场景位置"，避免判据依赖 Scene。 */
function makeWorld(n: { dynamic: number; staticBody: number }, cellSize = 4): {
  world: SpatialHashWorld;
  pos: Map<number, { x: number; z: number }>;
} {
  const pos = new Map<number, { x: number; z: number }>();
  const accessor: PositionAccessor = {
    get: (id) => pos.get(id),
    set: (id, x, z) => void pos.set(id, { x, z }),
  };
  const world = new SpatialHashWorld(accessor, { cellSize, maxIterations: 3 });
  // 稀疏排布：互不重叠 ⇒ 一次迭代就收敛（把"迭代次数"这个变量按住）
  let id = 1;
  for (let i = 0; i < n.dynamic; i++) {
    const x = (i % 40) * 6;
    const z = Math.floor(i / 40) * 6;
    pos.set(id, { x, z });
    world.add({ nodeId: id, radius: 0.4, isStatic: false } satisfies PhysicsBody);
    id++;
  }
  for (let i = 0; i < n.staticBody; i++) {
    const x = 300 + (i % 40) * 6;
    const z = Math.floor(i / 40) * 6;
    pos.set(id, { x, z });
    world.add({ nodeId: id, radius: 0.5, isStatic: true } satisfies PhysicsBody);
    id++;
  }
  return { world, pos };
}

// ── ① 遍历谁 ─────────────────────────────────────────────────

test("★★ resolve 只读动态体：2000 静态 + 2 动态 ⇒ bodyScans 恰好 2", () => {
  const { world } = makeWorld({ dynamic: 2, staticBody: 2000 });
  const before = world.stats().bodyScans;
  world.resolve();
  const after = world.stats().bodyScans;
  // 稀疏布局一次迭代就收敛 ⇒ 增量 = 动态体数
  assert.equal(after - before, 2, `读了 ${after - before} 个 body —— 遍历到静态体上去了（那是 O(n) 白扫）`);
});

test("★ 迭代会重复读：重叠的 3 个体会让 bodyScans > 3（说明计数是「每次读」而不是「多少个体」）", () => {
  const pos = new Map<number, { x: number; z: number }>();
  const world = new SpatialHashWorld(
    { get: (id) => pos.get(id), set: (id, x, z) => void pos.set(id, { x, z }) },
    { cellSize: 4, maxIterations: 3 },
  );
  for (let i = 0; i < 3; i++) {
    pos.set(i + 1, { x: 0.05 * i, z: 0 }); // 全挤在一起
    world.add({ nodeId: i + 1, radius: 0.5, isStatic: false });
  }
  world.resolve();
  const s = world.stats();
  assert.ok(s.bodyScans > 3, `bodyScans=${s.bodyScans} —— 三个重叠体至少要被读两轮`);
  assert.ok(s.bodyScans <= 3 * 3, `bodyScans=${s.bodyScans} 超过 3 轮上限`);
});

// ── ② 解算期间不许扫全场 ─────────────────────────────────────

test("★★ resolve 期间不做全场扫描：maxRangeScans 增量为 0（缓存就是缓存）", () => {
  const { world } = makeWorld({ dynamic: 200, staticBody: 1800 });
  const before = world.stats().maxRangeScans;
  world.resolve();
  const delta = world.stats().maxRangeScans - before;
  // ★ 这条判据如果红：说明"最大半径"又在解算里重算了。
  //   它原来就是 `maxRadiusNearby()` 里的一句 for 循环，被内层循环每人每轮调一次。
  assert.equal(delta, 0, `解算期间扫了 ${delta} 个 body 算最大半径 —— 这个数只在 add/remove 时才会变`);
});

test("缓存的失效点只有一处：删掉「最大的那个」才会重算，其它增删都不扫", () => {
  const { world, pos } = makeWorld({ dynamic: 50, staticBody: 1950 });
  // add 是 O(1)：只在"新的更大"时更新一个数，不扫全场
  assert.equal(world.stats().maxRangeScans, 0, "add 扫了全场 —— 那 2000 次加法会变成 2000×2000");

  for (let i = 0; i < 10; i++) world.resolve();
  assert.equal(world.stats().maxRangeScans, 0, "解算把缓存又扫了一遍");

  // 删一个**不是最大**的体：缓存不用动
  world.remove(3);
  assert.equal(world.stats().maxRangeScans, 0, "删掉的不是最大半径，不该重算");

  // 加一个特别大的体，再删掉它 —— 这时最大值变化不可知，必须重算
  pos.set(9001, { x: 999, z: 999 });
  world.add({ nodeId: 9001, radius: 40, isStatic: true });
  const before = world.stats().maxRangeScans;
  world.remove(9001);
  assert.ok(world.stats().maxRangeScans > before, "删掉最大半径的体却没重算 —— 之后所有查询都会用偏小的范围（漏碰撞）");

  // 重算之后解算依然不再扫
  const settled = world.stats().maxRangeScans;
  world.resolve();
  assert.equal(world.stats().maxRangeScans, settled);
});

// ── ③ 格索引是 O(1) ─────────────────────────────────────────

test("★★ reindex 不遍历格：cellScans 增量为 0（`cellOfBody` 的用处就在这儿）", () => {
  const { world, pos } = makeWorld({ dynamic: 500, staticBody: 1500 });
  const cells = world.stats().cells;
  assert.ok(cells > 20, `格数只有 ${cells}，判据没有分辨力`);
  const before = world.stats().cellScans;
  // 让 100 个动态体各走一步（跨格），每次都 reindex
  for (let i = 1; i <= 100; i++) {
    const p = pos.get(i);
    assert.ok(p !== undefined);
    pos.set(i, { x: p.x + 5.5, z: p.z });
    world.reindex(i);
  }
  const delta = world.stats().cellScans - before;
  assert.equal(delta, 0, `reindex 扫了 ${delta} 个格 —— 那一次扫描的成本是 O(#格)，而且每帧都要付`);
});

test("索引与格列表一致：reindex 之后该体只在一个格里（慢路径没有偷偷跑）", () => {
  const pos = new Map<number, { x: number; z: number }>();
  const world = new SpatialHashWorld(
    { get: (id) => pos.get(id), set: (id, x, z) => void pos.set(id, { x, z }) },
    { cellSize: 4, maxIterations: 3 },
  );
  pos.set(7, { x: 0.5, z: 0.5 });
  world.add({ nodeId: 7, radius: 0.4, isStatic: false });
  for (let i = 0; i < 20; i++) {
    // 每次跨好几格，确保"旧的删掉、新的加上"
    pos.set(7, { x: 20 + i * 9, z: 3 });
    world.reindex(7);
    const near = world.query(20 + i * 9, 3, 0.1);
    assert.deepEqual([...near], [7], `第 ${i} 次 reindex 之后查不到自己 —— 格列表里留了旧的一份`);
  }
  assert.equal(world.stats().cellScans, 0, "走了慢路径");
});

// ── ④ 计数本身不许失真 ──────────────────────────────────────

test("clear() 把三个工作量计数归零（否则跨关卡的数字没法比较）", () => {
  const { world } = makeWorld({ dynamic: 20, staticBody: 20 });
  world.resolve();
  assert.ok(world.stats().bodyScans > 0);
  world.clear();
  const s = world.stats();
  assert.equal(s.bodyScans, 0);
  assert.equal(s.maxRangeScans, 0);
  assert.equal(s.cellScans, 0);
  assert.equal(s.bodies, 0);
});
