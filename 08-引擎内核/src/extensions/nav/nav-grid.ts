/**
 * L4 · 导航网格（阶段 3：**能不能走过去、怎么走**）
 *
 * 感知回答"看得见什么"，目标选择回答"盯谁"，但在那之后还有一步：
 * **从 A 到 B 中间隔着一条河。** 直线位移的写法在俯视角地图上必然撞墙 ——
 * 表现为怪物贴着海岸线原地抖动，而"它确实在朝目标移动"这句话每帧都成立。
 *
 * 本文件只做两件事：**一格能不能站**（可通行栅格）、**从这格到那格怎么走**（A*）。
 * 位移本身在 `move-along.ts`，AI 的接线在 `ai/move.ts` —— 三层分开的理由是
 * "路径算错了"和"沿着路径走错了"是两种完全不同的失效，混在一起时判据会互相掩盖。
 *
 * ★★ 五个刻意的设计决定：
 *
 * ① **代价用整数**（直走 10 / 斜走 14），启发式用八向 octile。
 *    浮点代价在"两条路径总长几乎相等"时会让 A* 的选择取决于累加次序，
 *    同种子同地图可能给出两条不同的路 —— 回放只认字节。
 *    14 而不是 `10√2≈14.14`：**宁可略高估也不引入无理数**。整数尺度下
 *    最优性只在"路径代价差 ≥ 1"时保证，这个精度对格子图完全够。
 *
 * ② **禁止切角**（diagonal 要求两个正交邻格都可走）。
 *    不禁止的话怪物会从两块礁石的斜缝里穿过去，画面上看起来像"卡了一下然后出现在对面"。
 *    更隐蔽的是：它让"可通行区域"在视觉上是连的、在物理上是断的。
 *
 * ③ **平手可判**：堆的比较是 `(f, h, cell 下标)` 三层升序。
 *    只比 `f` 的话，同代价路径谁先出堆取决于入堆顺序 —— 那是邻居遍历序，
 *    于是"同一张图两次寻路给出不同路径"，而两条路径都对。
 *
 * ④ **连通分量与寻路用同一套邻居规则**。
 *    分量用 4 邻接、寻路用 8 邻接（或反过来）会得到一个自相矛盾的结论：
 *    "这两格连通"但"寻不到路"。所以两者共用 `neighborsOf`。
 *    判据里直接断言 `componentOf(a)===componentOf(b) ⟺ findPath(a,b) 成功`。
 *
 * ⑤ **越界是错误，不是障碍**。查询越界返回 `NAV.OUT_OF_RANGE` 而不是 `false`：
 *    把"坐标算错了"混进"这里走不了"，会让一个坐标 bug 表现成"地图设计不好"。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { TERRAIN_TYPE, type TerrainArea } from "../worldgen/assemble.ts";
import { isPassable, type WorldPlan } from "../worldgen/worldgen.ts";

/** 栅格宽高/掩码长度自相矛盾。 */
export const NAV_BAD_GRID = "NAV.BAD_GRID";
/** 格子下标越界。 */
export const NAV_OUT_OF_RANGE = "NAV.OUT_OF_RANGE";
/** 起点或终点附近连一格能站的地方都没有。 */
export const NAV_BLOCKED = "NAV.BLOCKED";
/** 两格之间确实没有路（被水/悬崖隔断）。 */
export const NAV_NO_PATH = "NAV.NO_PATH";
/** 展开节点数超过上限（地图过大或目标不可达时防止卡死）。 */
export const NAV_TOO_COMPLEX = "NAV.TOO_COMPLEX";

/** 直走一格的代价。 */
export const STRAIGHT_COST = 10;
/** 斜走一格的代价（`14 ≈ 10√2`，取整以避免无理数）。 */
export const DIAGONAL_COST = 14;

/** 八个方向：前四个正交、后四个对角。顺序写死（见文件头 ③）。 */
const DIRS: readonly (readonly [number, number, number])[] = [
  [1, 0, STRAIGHT_COST],
  [-1, 0, STRAIGHT_COST],
  [0, 1, STRAIGHT_COST],
  [0, -1, STRAIGHT_COST],
  [1, 1, DIAGONAL_COST],
  [1, -1, DIAGONAL_COST],
  [-1, 1, DIAGONAL_COST],
  [-1, -1, DIAGONAL_COST],
];

export interface NavPath {
  /** 含起点与终点的格子下标序列（相邻两步满足邻居规则）。 */
  readonly cells: readonly number[];
  /** 累计代价（整数，见文件头 ①）。 */
  readonly cost: number;
  /** A* 展开的节点数（诊断用；也能用来发现"地图太绕"）。 */
  readonly expanded: number;
  /** `true` = 起点或终点被吸附到了附近的空格（原格不可站）。 */
  readonly snapped: boolean;
  /** 吸附后的实际起点格。 */
  readonly from: number;
  /** 吸附后的实际终点格。 */
  readonly to: number;
}

export interface FindPathOptions {
  /** 展开上限，默认 200000（约等于 450×450 全图铺开）。 */
  readonly maxExpanded?: number;
  /** 起终点不可站时向周围找几圈（切比雪夫半径），默认 6。 */
  readonly snapRadius?: number;
}

/** 最小堆：三列平行数组存 `(f, h, cell)`，比较规则见文件头 ③。 */
class OpenHeap {
  private readonly f: number[] = [];
  private readonly h: number[] = [];
  private readonly c: number[] = [];

  get size(): number {
    return this.c.length;
  }

  push(f: number, h: number, c: number): void {
    this.f.push(f);
    this.h.push(h);
    this.c.push(c);
    let i = this.c.length - 1;
    while (i > 0) {
      const p = (i - 1) >> 1;
      if (!this.less(i, p)) break;
      this.swap(i, p);
      i = p;
    }
  }

  pop(): number {
    const top = this.c[0]!;
    const lastIdx = this.c.length - 1;
    this.swap(0, lastIdx);
    this.f.pop();
    this.h.pop();
    this.c.pop();
    let i = 0;
    for (;;) {
      const l = i * 2 + 1;
      const r = l + 1;
      let best = i;
      if (l < this.c.length && this.less(l, best)) best = l;
      if (r < this.c.length && this.less(r, best)) best = r;
      if (best === i) break;
      this.swap(i, best);
      i = best;
    }
    return top;
  }

  private less(i: number, j: number): boolean {
    const fi = this.f[i]!;
    const fj = this.f[j]!;
    if (fi !== fj) return fi < fj;
    const hi = this.h[i]!;
    const hj = this.h[j]!;
    if (hi !== hj) return hi < hj;
    return this.c[i]! < this.c[j]!;
  }

  private swap(i: number, j: number): void {
    const f = this.f[i]!;
    this.f[i] = this.f[j]!;
    this.f[j] = f;
    const h = this.h[i]!;
    this.h[i] = this.h[j]!;
    this.h[j] = h;
    const c = this.c[i]!;
    this.c[i] = this.c[j]!;
    this.c[j] = c;
  }
}

export interface NavStats {
  readonly width: number;
  readonly height: number;
  readonly walkable: number;
  readonly blocked: number;
  /** 惰性算出的连通分量数；-1 = 还没算过。 */
  readonly components: number;
}

/**
 * 可通行栅格 + A*。
 *
 * ★ 构造之后内部掩码**不再变更**（没有 `setWalkable`）：
 *   地图改动（架桥、拆墙）应该重建网格。允许原地改的话，惰性算出的连通分量
 *   会与掩码不一致，而那种不一致只在"走了很久以后某条路突然寻不到"时暴露。
 */
export class NavGrid {
  readonly width: number;
  readonly height: number;
  private readonly mask: Uint8Array;
  /** 连通分量标号；-1 = 未标。惰性填充，见 `componentOf`。 */
  private readonly labels: Int32Array;
  private labelCount = 0;
  /** ★ 单独一个布尔：全图不可站时 `labelCount` 也是 0，用它区分"没算过"和"算出来是 0 个"。 */
  private labeled = false;

  constructor(width: number, height: number, walkable: Uint8Array) {
    if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0) {
      throw new RangeError(`导航网格尺寸必须是正整数，得到 ${String(width)}x${String(height)}`);
    }
    if (walkable.length !== width * height) {
      throw new RangeError(`掩码长度 ${String(walkable.length)} 与 ${String(width)}x${String(height)} 不符`);
    }
    this.width = width;
    this.height = height;
    this.mask = walkable;
    this.labels = new Int32Array(width * height).fill(-1);
  }

  /** 由生成计划构造（`kinds` 走群系表）。 */
  static fromPlan(plan: WorldPlan): Result<NavGrid, EngineError> {
    const total = plan.width * plan.height;
    if (plan.kinds.length !== total) {
      return err(
        engineError(
          NAV_BAD_GRID,
          `计划的 kinds 长度 ${String(plan.kinds.length)} 与 ${String(plan.width)}x${String(plan.height)} 不符`,
        ),
      );
    }
    const mask = new Uint8Array(total);
    for (let i = 0; i < total; i++) mask[i] = isPassable(plan.kinds[i]!) ? 1 : 0;
    return ok(new NavGrid(plan.width, plan.height, mask));
  }

  /**
   * 由**装配后的场景**构造。
   *
   * ★ 只读组件里的 `passable` 字段，不再查群系表。
   *   这正是 `assemble.ts` 里 `sceneComponents` 踩过的坑：两条输入源混在一起时，
   *   "某块地形的 passable 写错了"会被另一条源抹平，判据全绿而地图是错的。
   *   漏格（没有任何地形覆盖）直接报错 —— 缺失不等于"不能走"。
   */
  static fromScene(scene: Scene, width: number, height: number): Result<NavGrid, EngineError> {
    const total = width * height;
    const mask = new Int8Array(total).fill(-1);
    for (const area of scene.componentsOf<TerrainArea>(TERRAIN_TYPE)) {
      for (let dz = 0; dz < area.h; dz++) {
        for (let dx = 0; dx < area.w; dx++) {
          const x = area.cx + dx;
          const z = area.cz + dz;
          if (x < 0 || z < 0 || x >= width || z >= height) {
            return err(
              engineError(
                NAV_BAD_GRID,
                `地形节点越界：(${String(x)}, ${String(z)}) 超出 ${String(width)}x${String(height)}`,
              ),
            );
          }
          mask[z * width + x] = area.passable ? 1 : 0;
        }
      }
    }
    for (let i = 0; i < total; i++) {
      if (mask[i] === -1) {
        return err(engineError(NAV_BAD_GRID, `第 ${String(i)} 格没有地形覆盖，无法建导航网格`));
      }
    }
    const out = new Uint8Array(total);
    for (let i = 0; i < total; i++) out[i] = mask[i] === 1 ? 1 : 0;
    return ok(new NavGrid(width, height, out));
  }

  get total(): number {
    return this.width * this.height;
  }

  /** 格子坐标 → 下标；越界返回 -1。 */
  indexOf(cx: number, cz: number): number {
    if (!Number.isInteger(cx) || !Number.isInteger(cz)) return -1;
    if (cx < 0 || cz < 0 || cx >= this.width || cz >= this.height) return -1;
    return cz * this.width + cx;
  }

  cellX(index: number): number {
    return index % this.width;
  }

  cellZ(index: number): number {
    return (index - (index % this.width)) / this.width;
  }

  /** 格子中心的世界坐标（`+0.5` 与 `spawn.ts` 的出生点同源）。 */
  centerOf(index: number): { x: number; z: number } {
    return { x: this.cellX(index) + 0.5, z: this.cellZ(index) + 0.5 };
  }

  /** 世界坐标 → 格子下标。1 世界单位 = 1 格（`FIXED_UNITS` 除下来正好）。 */
  cellAt(x: number, z: number): number {
    return this.indexOf(Math.floor(x), Math.floor(z));
  }

  isWalkableIndex(index: number): boolean {
    return index >= 0 && index < this.mask.length && this.mask[index] === 1;
  }

  isWalkable(cx: number, cz: number): boolean {
    return this.isWalkableIndex(this.indexOf(cx, cz));
  }

  /**
   * 找离 `(cx, cz)` 最近的可站立格；找不到返回 -1。
   *
   * ★ 同一圈内取**距离平方最小**、平手取**下标最小**，不是"环上第一个遇到的"。
   *   后者取决于扫描方向，于是"被推到海里的怪该回到哪块岸"取决于遍历序 ——
   *   回放里就是另一条路。
   */
  nearestWalkable(cx: number, cz: number, maxRadius = 6): number {
    if (this.isWalkable(cx, cz)) return this.indexOf(cx, cz);
    for (let r = 1; r <= maxRadius; r++) {
      let best = -1;
      let bestD2 = Infinity;
      for (let dz = -r; dz <= r; dz++) {
        for (let dx = -r; dx <= r; dx++) {
          // 只看这一圈的边（内部那一圈已经在上一次迭代里比过了）
          if (Math.max(Math.abs(dx), Math.abs(dz)) !== r) continue;
          const x = cx + dx;
          const z = cz + dz;
          const i = this.indexOf(x, z);
          if (i < 0 || this.mask[i] !== 1) continue;
          const d2 = dx * dx + dz * dz;
          if (d2 < bestD2 || (d2 === bestD2 && i < best)) {
            best = i;
            bestD2 = d2;
          }
        }
      }
      if (best >= 0) return best;
    }
    return -1;
  }

  /**
   * 连通分量标号（惰性全图标注一次）。
   *
   * ★ 与 A* 共用同一套邻居规则（见文件头 ④），否则会出现
   *   "分量说是通的、寻路说没路"这种自相矛盾的报告。
   */
  componentOf(index: number): number {
    if (index < 0 || index >= this.mask.length) return -1;
    if (this.labels[index]! >= 0) return this.labels[index]!;
    if (this.mask[index] !== 1) return -1;
    this.labelAll();
    return this.labels[index]!;
  }

  get componentCount(): number {
    if (!this.labeled) this.labelAll();
    return this.labelCount;
  }

  private labelAll(): void {
    if (this.labeled) return;
    this.labeled = true;
    const labels = this.labels;
    const stack: number[] = [];
    let next = 0;
    for (let start = 0; start < this.mask.length; start++) {
      if (this.mask[start] !== 1 || labels[start]! >= 0) continue;
      // 标号从 0 起（未标保持 -1）—— 于是 `>= 0` 就是"已经算过"
      labels[start] = next;
      stack.push(start);
      while (stack.length > 0) {
        const cur = stack.pop()!;
        const cx = this.cellX(cur);
        const cz = this.cellZ(cur);
        for (const [dx, dz] of DIRS) {
          const n = this.neighborOf(cx, cz, dx, dz);
          if (n < 0 || labels[n]! >= 0) continue;
          labels[n] = next;
          stack.push(n);
        }
      }
      next++;
    }
    this.labelCount = next;
  }

  /**
   * 邻居判定：越界/不可走/切角 → -1。
   *
   * ★ 这是全类唯一一处定义"相邻"的地方，`labelAll` 与 `findPath` 都走它。
   *   抄两份的后果是"分量连通但寻不到路"，而两边的判据各自都绿。
   */
  private neighborOf(cx: number, cz: number, dx: number, dz: number): number {
    const n = this.indexOf(cx + dx, cz + dz);
    if (n < 0 || this.mask[n] !== 1) return -1;
    if (dx !== 0 && dz !== 0) {
      // 禁止切角：两个正交邻格都得能站（见文件头 ②）
      if (!this.isWalkable(cx + dx, cz) || !this.isWalkable(cx, cz + dz)) return -1;
    }
    return n;
  }

  /**
   * A*。`from` / `to` 是格子下标。
   *
   * 起点或终点不可站时先吸附到附近空格（`snapped: true` 会写在结果里）——
   * 静默吸附是危险的，调用方需要知道"它其实走不到你指的那一格"。
   */
  findPath(from: number, to: number, opts: FindPathOptions = {}): Result<NavPath, EngineError> {
    if (from < 0 || from >= this.total || to < 0 || to >= this.total) {
      return err(
        engineError(
          NAV_OUT_OF_RANGE,
          `寻路下标越界：${String(from)} → ${String(to)}（共 ${String(this.total)} 格）`,
        ),
      );
    }
    const maxExpanded = opts.maxExpanded ?? 200000;
    const snapRadius = opts.snapRadius ?? 6;

    let start = from;
    let goal = to;
    let snapped = false;
    if (this.mask[start] !== 1) {
      const s = this.nearestWalkable(this.cellX(from), this.cellZ(from), snapRadius);
      if (s < 0) {
        return err(engineError(NAV_BLOCKED, `起点 ${String(from)} 不可站，附近 ${String(snapRadius)} 格内没有落脚点`));
      }
      start = s;
      snapped = true;
    }
    if (this.mask[goal] !== 1) {
      const g = this.nearestWalkable(this.cellX(to), this.cellZ(to), snapRadius);
      if (g < 0) {
        return err(engineError(NAV_BLOCKED, `终点 ${String(to)} 不可站，附近 ${String(snapRadius)} 格内没有落脚点`));
      }
      goal = g;
      snapped = true;
    }

    if (start === goal) {
      return ok({ cells: [start], cost: 0, expanded: 0, snapped, from: start, to: goal });
    }

    const total = this.total;
    const width = this.width;
    const gScore = new Int32Array(total).fill(-1);
    const back = new Int32Array(total).fill(-1);
    const closed = new Uint8Array(total);
    const heap = new OpenHeap();

    const gx = this.cellX(goal);
    const gz = this.cellZ(goal);
    const guess = (cell: number): number => {
      const dx = Math.abs(this.cellX(cell) - gx);
      const dz = Math.abs(this.cellZ(cell) - gz);
      // octile：沿对角线走 min，再直走剩下的
      return STRAIGHT_COST * (dx + dz) + (DIAGONAL_COST - 2 * STRAIGHT_COST) * Math.min(dx, dz);
    };

    gScore[start] = 0;
    heap.push(guess(start), guess(start), start);
    let expanded = 0;
    let reached = false;

    while (heap.size > 0) {
      const cur = heap.pop();
      // 惰性删除：同一个格子可能被更优的 g 重复入堆
      if (closed[cur] === 1) continue;
      closed[cur] = 1;
      expanded++;
      if (cur === goal) {
        reached = true;
        break;
      }
      if (expanded > maxExpanded) {
        return err(
          engineError(
            NAV_TOO_COMPLEX,
            `A* 展开超过 ${String(maxExpanded)} 个节点仍未到达 ${String(goal)}（起点 ${String(start)}）`,
          ),
        );
      }
      const cx = cur % width;
      const cz = (cur - cx) / width;
      for (const [dx, dz, stepCost] of DIRS) {
        const n = this.neighborOf(cx, cz, dx, dz);
        if (n < 0 || closed[n] === 1) continue;
        const ng = gScore[cur]! + stepCost;
        const old = gScore[n]!;
        if (old >= 0 && ng >= old) continue;
        gScore[n] = ng;
        back[n] = cur;
        const h = guess(n);
        heap.push(ng + h, h, n);
      }
    }

    if (!reached) {
      return err(
        engineError(
          NAV_NO_PATH,
          `从 ${String(start)} 到 ${String(goal)} 没有可走的路（展开 ${String(expanded)} 格；检查是否被水/悬崖隔断）`,
        ),
      );
    }

    const cells: number[] = [];
    let walk = goal;
    while (walk !== -1) {
      cells.push(walk);
      if (walk === start) break;
      walk = back[walk]!;
    }
    cells.reverse();
    return ok({ cells, cost: gScore[goal]!, expanded, snapped, from: start, to: goal });
  }

  stats(): NavStats {
    let walkable = 0;
    for (let i = 0; i < this.mask.length; i++) if (this.mask[i] === 1) walkable++;
    return {
      width: this.width,
      height: this.height,
      walkable,
      blocked: this.total - walkable,
      components: this.labeled ? this.labelCount : -1,
    };
  }

  /** 导出掩码副本（存档/诊断用）。改动返回值不影响网格。 */
  toMask(): Uint8Array {
    return this.mask.slice();
  }
}
