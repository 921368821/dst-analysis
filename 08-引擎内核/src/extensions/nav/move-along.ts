/**
 * L4 · 沿路径行走（阶段 3：**把格子路径变成每帧位移**）
 *
 * `nav-grid.ts` 给出"该经过哪些格子"，本文件把它换成"这一 tick 该挪多少"。
 * 分开的理由：路径错了（绕远、穿墙）和行走错了（速度不匀、抖动、冲过头）
 * 是两种失效，判据也必须能分别指名。
 *
 * ★★ 三个刻意的设计决定：
 *
 * ① **剩余距离要跨路点结转**。
 *    朴素写法是"每 tick 朝当前路点走 `speed*dt`，到了就把游标 +1，**剩下的距离作废**"。
 *    于是速度取决于路点密度：路点越密，每段末尾浪费得越多，实际速度越慢。
 *    在格子图上，斜走段的中心点间距是 1.414、直走是 1.0 ——
 *    同一条路上"斜着走比直着走慢"，而画面上看起来只是"有点拖沓"。
 *    判据：一条 8 格直线 + 一条 8 个路点的折线（总长相同），用时必须相同。
 *
 * ② **不冲过头**（剩余预算大于本段长度时先走完本段再继续），也不会在
 *    "刚好差 0.0001" 时原地抖动 —— 用 `EPS` 判到点，且到点后把坐标**吸附**到
 *    格子中心，避免浮点误差累积成"永远差一点点，游标永远不前进"。
 *
 * ③ **`nearestIndexOnPath` 平手取更大下标**。
 *    被推挤/传送之后游标会落后，重找位置时若平手取小下标，人物会**往回走一格**再前进，
 *    看起来像"卡在路点上学步"。取更大下标 = 宁可往前，符合"已经走过的不重走"。
 */

import type { NavGrid } from "./nav-grid.ts";

/** 到点判定阈值（世界单位）。小于它就算踩到了这个路点。 */
export const ARRIVE_EPS = 1e-6;

export interface WalkResult {
  readonly x: number;
  readonly z: number;
  /** 下一个要走的路点下标；`>= path.length` 表示走完了。 */
  readonly cursor: number;
  readonly done: boolean;
  /** 这一 tick 实际挪了多少世界单位（用来判"被卡住"）。 */
  readonly moved: number;
}

/**
 * 沿 `path` 从 `(x, z)` 走 `speed * dt` 的距离。
 *
 * `cursor` 是"下一个要去的路点下标"：`0` 表示还没出发，`1` 表示已经站在 `path[0]` 上。
 * 纯函数：不改入参，返回新坐标与新游标。
 */
export function stepAlong(
  grid: NavGrid,
  path: readonly number[],
  cursor: number,
  x: number,
  z: number,
  speed: number,
  dt: number,
): WalkResult {
  let i = Math.max(0, Math.min(cursor, path.length));
  let px = x;
  let pz = z;
  let moved = 0;
  let budget = speed * dt;

  if (!Number.isFinite(px) || !Number.isFinite(pz)) {
    // 坐标坏了不要静默继续：原地不动且不推进（调用方会看到 moved === 0）
    return { x, z, cursor: i, done: i >= path.length, moved: 0 };
  }
  if (!(budget > 0) || !Number.isFinite(budget)) {
    return { x: px, z: pz, cursor: i, done: i >= path.length, moved: 0 };
  }

  while (budget > 0 && i < path.length) {
    const c = grid.centerOf(path[i]!);
    const dx = c.x - px;
    const dz = c.z - pz;
    const d = Math.hypot(dx, dz);

    if (d <= ARRIVE_EPS) {
      // 已经在这一格上：吸附 + 换下一个（吸附让浮点误差不会累积）
      px = c.x;
      pz = c.z;
      i++;
      continue;
    }
    if (d <= budget) {
      // 预算够走到这个路点：走完，**剩余预算继续用于下一段**（见文件头 ①）
      px = c.x;
      pz = c.z;
      moved += d;
      budget -= d;
      i++;
      continue;
    }
    // 预算不够：朝这个路点走满预算，游标停在它上面
    px += (dx / d) * budget;
    pz += (dz / d) * budget;
    moved += budget;
    budget = 0;
  }

  return { x: px, z: pz, cursor: i, done: i >= path.length, moved };
}

/** 路径总长（世界单位）。用于诊断与"这条弯路值不值"的比较。 */
export function pathLength(grid: NavGrid, path: readonly number[], fromX?: number, fromZ?: number): number {
  if (path.length === 0) return 0;
  let total = 0;
  let px = fromX;
  let pz = fromZ;
  for (const cell of path) {
    const c = grid.centerOf(cell);
    if (px !== undefined && pz !== undefined) total += Math.hypot(c.x - px, c.z - pz);
    px = c.x;
    pz = c.z;
  }
  return total;
}

/**
 * 当前位置在路径上的"最靠后的近似下标"。
 *
 * 用于被推挤/传送后重对齐游标。只往回找**已走过**的那一段不划算，
 * 所以整条路径都扫（路径长度通常几十，扫描代价可忽略）。
 */
export function nearestIndexOnPath(grid: NavGrid, path: readonly number[], x: number, z: number): number {
  let best = 0;
  let bestD2 = Infinity;
  for (let i = 0; i < path.length; i++) {
    const c = grid.centerOf(path[i]!);
    const dx = c.x - x;
    const dz = c.z - z;
    const d2 = dx * dx + dz * dz;
    // 平手取更大下标（见文件头 ③）
    if (d2 < bestD2 || (d2 === bestD2 && i > best)) {
      best = i;
      bestD2 = d2;
    }
  }
  return best;
}
