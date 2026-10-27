/**
 * 连续碰撞（扫掠）判据
 *
 * 这一层要守的是**时刻**，不是"有没有重叠"：
 *   ① 高速体一步跨过薄墙 ⇒ 必须停在墙前（这是整批的存在理由）；
 *   ② 角上必须是**精确解** —— 把盒子放大 r 再做线段求交，45° 打角会给 0.146，
 *      而真实接触在 0.45。这条判据专门钉这个差，改回近似就红；
 *   ③ 撞上之后沿墙滑：位移的**法向分量**去掉，剩下的继续走，且**不许凭空加能量**
 *      （路径长度恒 ≤ 原始位移长度）。
 *
 * 数字全部手算过：夹具盒 2×2 在原点、圆半径 0.5 ⇒ 放大后 2.5。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  earliestHit,
  moveSwept,
  sweepCircleVsBox,
  sweepCircleVsCircle,
  type SweepBox,
} from "../../src/extensions/physics/sweep.ts";
import { SpatialHashWorld, type PhysicsBody } from "../../src/extensions/physics/physics.ts";

/** 定位夹具：中心原点、半宽 2、半高 2、nodeId 7。 */
const WALL: SweepBox = { cx: 0, cz: 0, hx: 2, hz: 2, nodeId: 7 };
const R = 0.5;

function near(a: number, b: number, eps = 1e-9): void {
  assert.ok(Math.abs(a - b) <= eps, `期望 ${String(b)}，实际 ${String(a)}（差 ${String(a - b)}）`);
}

// ── ① 基本求交 ──────────────────────────────────────────────

test("★ 正对着墙走：t = 7.5/20（墙面在 −2.5），法线朝外", () => {
  const h = sweepCircleVsBox(-10, 0, 20, 0, R, WALL);
  assert.ok(h !== null);
  near(h.t, 0.375);
  near(h.nx, -1);
  near(h.nz, 0);
  assert.equal(h.nodeId, 7);
});

test("★ 从另一侧（右往左）对称：t = 0.375，法线朝 +x", () => {
  const h = sweepCircleVsBox(10, 0, -20, 0, R, WALL);
  assert.ok(h !== null);
  near(h.t, 0.375);
  near(h.nx, 1);
  near(h.nz, 0);
});

test("★ 沿 z 轴进入也一样（两个 z 面的法线分量在 nz 上，写错成 nx 会把远侧报成命中）", () => {
  const h = sweepCircleVsBox(0, -10, 0, 20, R, WALL);
  assert.ok(h !== null);
  near(h.t, 0.375);
  near(h.nx, 0);
  near(h.nz, -1);
});

test("★★ 薄墙 + 高速一步跨过：扫掠报告 t，直接加位移则会穿透", () => {
  const thin: SweepBox = { cx: 0, cz: 0, hx: 0.05, hz: 5, nodeId: 3 };
  const h = sweepCircleVsBox(-10, 0, 20, 0, R, thin);
  assert.ok(h !== null);
  // 墙面（放大后）= −0.05 − 0.5 = −0.55 ⇒ t = (−0.55 + 10)/20
  near(h.t, 9.45 / 20);
  // 按 t 停下 ⇒ 圆心停在 −0.55，仍在墙的左侧
  near(-10 + 20 * h.t, -0.55, 1e-9);
  // 不加扫掠的那一步：圆心直接到 +10（穿过去了，而且下一拍再也不会被推开）
  assert.ok(-10 + 20 > thin.cx + thin.hx, "不扫掠就是穿透 —— 这正是要防的那件事");
});

test("反向离开不会命中（法线同向的那一面要被跳过）", () => {
  assert.equal(sweepCircleVsBox(-10, 0, -20, 0, R, WALL), null);
});

test("★ 擦过：z=2.6 差 0.1 没碰到；z=2.4 碰到的是**先到的那个角**，法线斜着", () => {
  assert.equal(sweepCircleVsBox(-10, 2.6, 20, 0, R, WALL), null);
  const h = sweepCircleVsBox(-10, 2.4, 20, 0, R, WALL);
  assert.ok(h !== null);
  // ★ 先碰到的是**近角** (−2,2)，不是正前方那个角：(x+2)² + 0.4² = 0.25 ⇒ x = −2.3
  //   ⇒ t = 7.7/20；法线 (−0.3, 0.4)/0.5。
  //   只算"正对着的那个角"会得到 0.585 —— 那是**后到的**那次接触。
  near(h.t, 7.7 / 20);
  near(h.nx, -0.6);
  near(h.nz, 0.8);
});

test("★★ 沿对角线穿过方块：先撞**近角**，且是精确解（不是放大盒的 0.1464）", () => {
  const sq: SweepBox = { cx: 0, cz: 0, hx: 1, hz: 1 };
  const u = Math.SQRT1_2;
  const h = sweepCircleVsBox(1 - 5 * u, 1 - 5 * u, 10 * u, 10 * u, R, sq);
  assert.ok(h !== null);
  // 手算：起点到近角 (−1,−1) 的距离 = hypot(1.5355, 1.5355) = 2.1716；
  // 位移正对这个角、长度 10 ⇒ 接触时刻 t = (2.1716 − 0.5)/10。
  // ★ 只算"正前方的那个角"会漏掉**先到的近角** —— 第一次写这条判据时我就漏了，
  //   而算错的方向是"看起来更宽的容差"，判据照样绿。
  near(h.t, (2.17157287525381 - 0.5) / 10, 1e-12);
  near(h.nx, -u, 1e-12);
  near(h.nz, -u, 1e-12);
  // 放大盒（半宽 1 + 半径 0.5）给的入口是 x = −1.5 ⇒ t = 0.1464：**早了 0.02**，
  // 也就是"还有 0.21 个单位就走到了却先停住"。
  assert.ok(h.t > 0.1465, "放大盒的 0.1464 是错解；角圆必须参与");
});

test("★★ 放大盒会把「还差一点点才碰到」误报成「已经重叠」，角圆不会", () => {
  const sq: SweepBox = { cx: 0, cz: 0, hx: 1, hz: 1 };
  // 起点 (1.45,1.45)：在放大盒（半宽 1.5）之内，但到角 (1,1) 的距离是 0.636 > 0.5 ⇒ 没碰到
  const h = sweepCircleVsBox(1.45, 1.45, 0, -3, R, sq);
  assert.ok(h !== null);
  // 接触条件：(0.45 − 3t)² + 0.45² = 0.25 ⇒ t = (0.45 − √0.0475)/3 ≈ 0.0774
  near(h.t, (0.45 - Math.sqrt(0.0475)) / 3, 1e-12);
  assert.ok(h.t > 0, "放大盒在这里会报 t=0（假的「已经重叠」）");
});

test("★ 起点已经重叠 ⇒ t = 0，法线沿**穿透最浅**的轴", () => {
  const inside: SweepBox = { cx: 0, cz: 0, hx: 4, hz: 0.5 };
  const h = sweepCircleVsBox(0, 0.2, 10, 0, R, inside);
  assert.ok(h !== null);
  assert.equal(h.t, 0);
  // 上边 0.3、下边 0.7、左右各 4 ⇒ 最浅是 +z 方向
  near(h.nx, 0);
  near(h.nz, 1);
});

test("起点在角上但还没重叠（0.707 > 0.5）⇒ 这一步不动就是 null，不出 NaN", () => {
  const sq: SweepBox = { cx: 0, cz: 0, hx: 1, hz: 1 };
  assert.equal(sweepCircleVsBox(1.45, 1.45, 0, 0, R, sq), null);
});

test("零位移 + 不重叠 ⇒ null（不要算出 0/0）", () => {
  assert.equal(sweepCircleVsBox(-10, 0, 0, 0, R, WALL), null);
});

test("非法输入直接抛（编程错误，不是可配置字段）", () => {
  assert.throws(() => sweepCircleVsBox(Number.NaN, 0, 1, 0, R, WALL), TypeError);
  assert.throws(() => sweepCircleVsBox(0, 0, 1, Number.POSITIVE_INFINITY, R, WALL), TypeError);
  assert.throws(() => sweepCircleVsBox(0, 0, 1, 0, 0, WALL), RangeError);
});

// ── ② 圆 vs 圆 ──────────────────────────────────────────────

test("圆 vs 圆：半径和 1.5 ⇒ t = 3.5/10", () => {
  const h = sweepCircleVsCircle(-5, 0, 10, 0, R, 0, 0, 1, 11);
  assert.ok(h !== null);
  near(h.t, 0.35);
  near(h.nx, -1);
  near(h.nz, 0);
  assert.equal(h.nodeId, 11);
});

test("圆 vs 圆：这一步走不到 ⇒ null", () => {
  assert.equal(sweepCircleVsCircle(-5, 0, 1, 0, R, 0, 0, 1), null);
});

// ── ③ 取最早 ────────────────────────────────────────────────

test("★ 多个障碍取最早的一个；t 相同时取 nodeId 小的（不依赖数组顺序）", () => {
  const nearBox: SweepBox = { cx: 1, cz: 0, hx: 0.5, hz: 4, nodeId: 20 };
  const farBox: SweepBox = { cx: 5, cz: 0, hx: 0.5, hz: 4, nodeId: 21 };
  const h = earliestHit([sweepCircleVsBox(-10, 0, 20, 0, R, farBox), sweepCircleVsBox(-10, 0, 20, 0, R, nearBox)]);
  assert.equal(h?.nodeId, 20);
  // ★ 再按**相反顺序**给一遍：只按上面那条，正确的实现与"取最后一个"恰好同解
  //   （M515 就是靠这一条才被咬住的）。数组顺序取决于空间哈希的格遍历顺序，
  //   它在不同格宽下会变 —— 所以"顺序换过来还对"是这条判据的实质。
  assert.equal(
    earliestHit([sweepCircleVsBox(-10, 0, 20, 0, R, nearBox), sweepCircleVsBox(-10, 0, 20, 0, R, farBox)])?.nodeId,
    20,
  );
  const tieA: SweepBox = { cx: 1, cz: 0, hx: 0.5, hz: 4, nodeId: 30 };
  const tieB: SweepBox = { cx: 1, cz: 0, hx: 0.5, hz: 4, nodeId: 9 };
  assert.equal(earliestHit([sweepCircleVsBox(-10, 0, 20, 0, R, tieA), sweepCircleVsBox(-10, 0, 20, 0, R, tieB)])?.nodeId, 9);
  assert.equal(earliestHit([]), null);
  assert.equal(earliestHit([null, null]), null);
});

// ── ④ 带滑动的移动 ─────────────────────────────────────────

test("★ 正面撞墙：停在墙前，不滑（切向分量为 0），走过的路程 = 接触距离", () => {
  const r = moveSwept(-10, 0, 20, 0, R, [WALL]);
  near(r.x, -2.5, 1e-3);
  near(r.z, 0, 1e-9);
  assert.equal(r.hit, true);
  assert.equal(r.slides, 0);
  near(r.traveled, 7.5, 1e-3);
  assert.equal(r.firstHit, 7);
});

test("★★ 斜撞宽墙：x 停住、沿 z 继续滑 → 滑动一次，终点手算可得", () => {
  const wall: SweepBox = { cx: 0, cz: 0, hx: 5, hz: 2, nodeId: 5 };
  // 起点 (−10, 1.5)，位移 (20, 0.2)：先撞 −x 面（t = 4.5/20 = 0.225），
  // 去掉法向分量后只剩下 (0, 0.2) ⇒ 沿墙面继续往上滑 0.2
  const r = moveSwept(-10, 1.5, 20, 0.2, R, [wall]);
  near(r.x, -5.5, 1e-3);
  near(r.z, 1.5 + 0.2 * 0.225 + 0.2, 1e-3);
  assert.equal(r.slides, 1);
  assert.equal(r.firstHit, 5);
});

test("★★ 滑动不会凭空加能量：走过的路程恒 ≤ 原始位移长度", () => {
  const wall: SweepBox = { cx: 0, cz: 0, hx: 5, hz: 2, nodeId: 5 };
  for (const dz of [-3, -1, 0, 0.2, 2, 9]) {
    const r = moveSwept(-10, 1.5, 20, dz, R, [wall]);
    const len = Math.hypot(20, dz);
    assert.ok(r.traveled <= len + 1e-9, `dz=${String(dz)}：走了 ${String(r.traveled)} > ${String(len)}`);
  }
});

test("★ 起点已经重叠：这一拍一步都不动（交给位置解算去分开，而不是滑出去）", () => {
  const wall: SweepBox = { cx: 0, cz: 0, hx: 5, hz: 5, nodeId: 5 };
  const r = moveSwept(0, 0, 10, 0, R, [wall]);
  assert.equal(r.hit, true);
  near(r.traveled, 0);
  near(r.x, 0);
  near(r.z, 0);
  assert.equal(r.slides, 0, "起点已重叠不算滑动");
  assert.equal(r.firstHit, 5);
  // ★ 带切向分量的那一版才是**真正咬着**这条规则的：只有法向分量时，"减掉法向"正好把
  //   位移清成 0，位置与计数器都看不出差别；一旦有切向分量，去掉法向之后还剩一截能走
  //   —— 那一截就是"从墙里滑出去"。判据只看位置也不够：法向被减掉后位置仍然不动，
  //   差别只在 `slides` 上（诊断面板的"撞了几次"依赖它）。
  const diag = moveSwept(0, 0, 10, 10, R, [wall]);
  near(diag.x, 0);
  near(diag.z, 0);
  near(diag.traveled, 0);
  assert.equal(diag.slides, 0, "有切向分量时也不许滑");
});

test("maxSlides = 0：第一次接触就停，不发生任何滑动", () => {
  const wall: SweepBox = { cx: 0, cz: 0, hx: 5, hz: 2, nodeId: 5 };
  const r = moveSwept(-10, 1.5, 20, 0.2, R, [wall], { maxSlides: 0 });
  assert.equal(r.slides, 0);
  near(r.x, -5.5, 1e-3);
  near(r.z, 1.5 + 0.2 * 0.225, 1e-3);
});

test("没有任何障碍 ⇒ 直接走完，hit = false", () => {
  const r = moveSwept(0, 0, 3, 4, R, []);
  near(r.x, 3);
  near(r.z, 4);
  assert.equal(r.hit, false);
  assert.equal(r.slides, 0);
  near(r.traveled, 5);
  assert.equal(r.firstHit, -1);
});

// ── ⑤ 接到真世界上（只扫静态体、只回答不改位置） ───────────

function worldWithBodies(bodies: readonly PhysicsBody[]): { world: SpatialHashWorld; pos: Map<number, { x: number; z: number }> } {
  const pos = new Map<number, { x: number; z: number }>(
    bodies.map((b) => [b.nodeId, { x: 0, z: 0 }]),
  );
  const world = new SpatialHashWorld({
    get: (id) => pos.get(id),
    set: (id, x, z) => {
      pos.set(id, { x, z });
    },
  });
  // ★ 必须真的加进世界：`sweepMove` 的候选集来自 `query`（走空间哈希），
  //   只在访问器里塞坐标的话，世界是空的 —— 而它返回 null 看起来像"没有障碍"。
  for (const b of bodies) world.add(b);
  return { world, pos };
}

test("★★ 真世界：高速体会在薄墙前停下（sweepMove 报出 t，且**不改位置**）", () => {
  const thin: PhysicsBody = { nodeId: 1, radius: 0.5, isStatic: false };
  const wall: PhysicsBody = { nodeId: 2, radius: 0.5, isStatic: true, halfExtents: { x: 0.05, z: 5 } };
  const { world, pos } = worldWithBodies([thin, wall]);
  pos.set(1, { x: -10, z: 0 });
  pos.set(2, { x: 0, z: 0 });
  const h = world.sweepMove(1, 20, 0);
  assert.ok(h !== null, "一步跨 20 单位必须报出命中");
  assert.equal(h.nodeId, 2);
  near(h.t, 9.45 / 20, 1e-9);
  assert.deepEqual(pos.get(1), { x: -10, z: 0 }, "sweepMove 只回答，不动位置");
});

test("★ sweepMove 只扫**静态**体：动态体不该让高速体停住（那是位置解算的活）", () => {
  const a: PhysicsBody = { nodeId: 1, radius: 0.5, isStatic: false };
  const b: PhysicsBody = { nodeId: 2, radius: 0.5, isStatic: false, halfExtents: { x: 0.05, z: 5 } };
  const { world, pos } = worldWithBodies([a, b]);
  pos.set(1, { x: -10, z: 0 });
  pos.set(2, { x: 0, z: 0 });
  assert.equal(world.sweepMove(1, 20, 0), null);
});

test("sweepMove：没有 body / 没有位置 ⇒ null（不抛）", () => {
  const a: PhysicsBody = { nodeId: 1, radius: 0.5, isStatic: false };
  const { world } = worldWithBodies([a]);
  assert.equal(world.sweepMove(99, 10, 0), null);
});

test("sweepMove：圆形静态体按**半径和**求交（t = (5 − 1)/5）", () => {
  const a: PhysicsBody = { nodeId: 1, radius: 0.5, isStatic: false };
  const pillar: PhysicsBody = { nodeId: 2, radius: 0.5, isStatic: true };
  const { world, pos } = worldWithBodies([a, pillar]);
  pos.set(1, { x: 0, z: -5 });
  pos.set(2, { x: 0, z: 0 });
  const h = world.sweepMove(1, 0, 5);
  assert.ok(h !== null);
  near(h.t, 0.8);
  near(h.nz, -1);
});

test("sweepMove：起点已经重叠（圆心距 < 半径和）⇒ t = 0", () => {
  const a: PhysicsBody = { nodeId: 1, radius: 0.5, isStatic: false };
  const pillar: PhysicsBody = { nodeId: 2, radius: 0.5, isStatic: true };
  const { world, pos } = worldWithBodies([a, pillar]);
  pos.set(1, { x: 0.9, z: 0 });
  pos.set(2, { x: 0, z: 0 });
  const h = world.sweepMove(1, 20, 0);
  assert.ok(h !== null);
  assert.equal(h.t, 0);
});
