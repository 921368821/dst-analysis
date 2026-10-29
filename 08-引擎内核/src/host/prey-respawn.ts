/**
 * L4 · 猎物重生的落点（**纯函数**，批126）
 *
 * 演示世界的问题不是"打不死怪"，而是**打完之后没有怪了**：3 只猎狗 3.5 秒吃光
 * 10 只兔子，之后地图上只剩猎狗。捕食者不会吃饱、猎物不会再生 ⇒ 任何有限数量
 * 都会被吃光（调伤害/冷却只是把归零推迟，算术见 `docs/PROGRESS.md` 批126）。
 *
 * 引擎侧只负责"数一数、到点了、要一只"（`mob-world.ts` 的 `respawn`），
 * **落点由宿主决定** —— 因为"离玩家多远才算看得见"是产品决定，引擎不该知道。
 *
 * ★★ 为什么抽成纯函数而不是写在 `browser-entry.ts` 里：
 *   落点规则有四条约束（可走 / 离玩家不太近也不太远 / 别压在活物身上 / 同参数同结果），
 *   每一条都可能写错，而写错的表现全是"地图上偶尔没兔子"—— 在那一片 32×24 的
 *   随机地形里靠眼看根本分不清是规则错还是运气差。抽出来之后，Node 判据可以
 *   造出"整张图只有一格满足条件"的语料，一条一条逼。
 *   这与批123 的 `attack-target-policy.ts` 是同一个做法（那次是"玩家击杀当场撤节点
 *   导致浏览器里再也造不出那个场景"）。
 */

import type { NavGrid } from "../extensions/nav/nav-grid.ts";

/** `pickPreyCell` 的输入。 */
export interface PreySpawnQuery {
  /** 导航网格（只用它的格数 / 可走 / 格心换算三件事）。 */
  readonly grid: Pick<NavGrid, "total" | "isWalkableIndex" | "cellX" | "cellZ" | "width">;
  /** 玩家现在在哪一格。 */
  readonly playerCell: number;
  /**
   * 现在**不能**重生到那里的格：活物脚下、以及它们周围 `blockRadius` 格。
   *
   * ★ 为什么要一整圈而不只是脚下那一格：兔子生成在一只猎狗的 1 格外 =
   *   生成即被杀（"再生看起来很健康，地图上还是空的"）。
   */
  readonly blocked: ReadonlySet<number>;
  /** 离玩家的**最小值**（切比雪夫格数）。贴脸重生 = 凭空出现。 */
  readonly minCells: number;
  /** 离玩家的**最大值**（切比雪夫格数）。太远 = 玩家永远遇不到。 */
  readonly maxCells: number;
  /** 轮换种子（宿主传 tick）。同一个 tick 必须给同一格，否则回放对不上。 */
  readonly salt: number;
  readonly seed: number;
}

/** 32 位混合（同 `(seed, salt)` 必得同值）。 */
function mix32(a: number, b: number): number {
  let h = (a ^ 0x9e3779b9) >>> 0;
  h = (Math.imul(h ^ (b + 0x85ebca6b), 0xcc9e2d51) >>> 0) ^ (h >>> 13);
  h = (Math.imul(h ^ 0x27d4eb2f, 0x165667b1) >>> 0) ^ (h >>> 15);
  return h >>> 0;
}

/**
 * 挑一个猎物重生格；`-1` = 这一轮没有合格的格子（宿主下一轮再试）。
 *
 * ★ 为什么是"先收集再按下标取"而不是"从某个起点往下扫、取第一个合格的"：
 *   后者在地形上**总是偏向扫描起点那一侧**（重生点会长期聚集在图的左上角），
 *   而这种偏移在截图里看起来完全正常。按下标取能把候选摊平。
 * ★ 代价是每次 O(全图)：768 格、3 秒一次 —— 不值一提，换来"落点均匀且可判"。
 */
export function pickPreyCell(q: PreySpawnQuery): number {
  if (!(q.maxCells >= q.minCells) || q.minCells < 0) return -1;
  const px = q.grid.cellX(q.playerCell);
  const pz = q.grid.cellZ(q.playerCell);
  if (px < 0 || pz < 0) return -1;

  const cand: number[] = [];
  for (let i = 0; i < q.grid.total; i++) {
    if (!q.grid.isWalkableIndex(i)) continue;
    if (q.blocked.has(i)) continue;
    const dx = Math.abs(q.grid.cellX(i) - px);
    const dz = Math.abs(q.grid.cellZ(i) - pz);
    const d = Math.max(dx, dz);
    if (d < q.minCells || d > q.maxCells) continue;
    cand.push(i);
  }
  if (cand.length === 0) return -1;
  const pick = mix32(q.seed, q.salt) % cand.length;
  return cand[pick] ?? -1;
}

/**
 * 把"某一格周围 r 格内"全塞进 `out`（越界自己跳）。
 *
 * ★ 与 `pickPreyCell` 放在一起，因为两者必须同一个口径（切比雪夫 / 格下标）：
 *   一个用切比雪夫算距离、另一个用欧氏把格子圈出来，"别生成在猎狗身边"就会
 *   留出一圈斜角漏洞 —— 而兔子恰好是从斜角被咬死的。
 */
export function blockAround(
  grid: Pick<NavGrid, "total" | "cellX" | "cellZ" | "width">,
  cell: number,
  r: number,
  out: Set<number>,
): void {
  const cx = grid.cellX(cell);
  const cz = grid.cellZ(cell);
  if (cx < 0 || cz < 0) return;
  for (let dx = -r; dx <= r; dx++) {
    for (let dz = -r; dz <= r; dz++) {
      const x = cx + dx;
      const z = cz + dz;
      if (x < 0 || z < 0) continue;
      // 用 `width` 反推下标：不依赖 `cellAt`（那个要格心坐标，容易差半格）
      const i = z * grid.width + x;
      if (i < 0 || i >= grid.total) continue;
      out.add(i);
    }
  }
}

/** 落点策略里"属于世界"的那几个数（配表在 `host/demo-mobs.ts`）。 */
export interface PreySpawnConfig {
  readonly minCells: number;
  readonly maxCells: number;
  /** 活物周围多少格内不许重生（切比雪夫）。 */
  readonly blockCells: number;
  readonly seed: number;
}

/**
 * 从"玩家在哪 + 活物都站在哪"直接算出重生格（`-1` = 这一轮没地方）。
 *
 * ★ 把"哪些格被占"这一步也收进纯函数：宿主只负责**收集活物的格**（那是场景查询，
 *   没有可测的规则），"占多宽、离玩家多远"是可测的规则，全在这里。
 *   这样 `browser-entry.ts` 里只剩三行取值 —— 接线越薄，越不容易在那里藏错。
 */
export function pickPreyCellAround(
  grid: Pick<NavGrid, "total" | "isWalkableIndex" | "cellX" | "cellZ" | "width">,
  playerCell: number,
  liveCells: readonly number[],
  tick: number,
  cfg: PreySpawnConfig,
): number {
  const blocked = new Set<number>();
  // 玩家脚下一圈也算"别在这生成"（`blockCells` 只管活物 —— 玩家不该被猎狗半径牵着走）
  blockAround(grid, playerCell, 1, blocked);
  for (const c of liveCells) blockAround(grid, c, cfg.blockCells, blocked);
  return pickPreyCell({
    grid,
    playerCell,
    blocked,
    minCells: cfg.minCells,
    maxCells: cfg.maxCells,
    salt: tick,
    seed: cfg.seed,
  });
}
