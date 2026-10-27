/**
 * L4 · 2.5D 物理
 *
 * 《饥荒》的物理**不是**刚体模拟：角色自己负责移动（Locomotor），
 * 世界只负责"把重叠推出去"（`PushOut`）与"附近有什么"（`FindEntities`）。
 * 这不是简化，而是**正确的选择**：它会走路、会绕树、会被挤开，
 * 但永远不会因为一次 200ms 的卡顿穿墙 —— 因为没有积分。
 *
 * 所以本文件只做两件事：
 *  ① **空间查询**（空间哈希）：`query(x, z, r)` → 附近 body 的 id
 *  ② **推出解算**：动态 body 与静态圆/AABB 重叠时，沿最近法线推开
 *
 * ★ 为什么不依赖 Scene：
 *   物理通过 `PositionAccessor` 读/写位置（两个函数）。
 *   好处：物理可以**独立测试**（不需要造一个 Scene），
 *   而且将来要"服务端跑物理、客户端只做预测"时，适配器换一个就行。
 *
 * ★ 为什么用空间哈希而不是四叉树：
 *   2.5D 世界里实体分布极不均匀（一堆东西挤在营地），四叉树在这种分布下
 *   退化成链表，而哈希表的 cell 是常数成本。饥荒用的也是网格。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import { earliestHit, sweepCircleVsBox, sweepCircleVsCircle, type SweepBox, type SweepHit } from "./sweep.ts";

export interface BodyId {
  readonly nodeId: number;
}

export interface PhysicsBody {
  readonly nodeId: number;
  /** 半径（圆近似）。方形障碍用 `halfExtents` 走 AABB 路径。 */
  readonly radius: number;
  /** 静态体不参与解算（只被推开别人）。 */
  readonly isStatic: boolean;
  /** 非空表示 AABB（半宽/半高，XZ 平面）。 */
  readonly halfExtents?: { readonly x: number; readonly z: number };
}

/** 物理读写位置的唯一入口（由 Scene 适配器实现）。 */
export interface PositionAccessor {
  get(nodeId: number): { x: number; z: number } | undefined;
  set(nodeId: number, x: number, z: number): void;
}

const AUTO_CELL_MIN = 0.5;
const AUTO_CELL_MAX = 16;
/** 自动格宽还没定下来时（还没有任何实体）用的占位值。 */
const AUTO_CELL_FALLBACK = 1;

export interface PhysicsStats {
  readonly bodies: number;
  readonly cells: number;
  readonly queries: number;
  readonly pushes: number;
  /** 迭代到上限仍未分开的次数（说明密度过高或半径不合理）。 */
  readonly unresolved: number;
  /**
   * `resolve()` 外层循环读过的 body 数（含重复迭代）。
   *
   * ★ 为什么必须有它：这三处开销（遍历谁、扫不扫全场、格索引是不是 O(1)）
   *   **在毫秒上抓不住** —— 真实规模下它们只值 2ms，而预算有 8ms，
   *   "从 0.74 退到 2.7" 依然全绿。唯一能钉住的是**次数**：
   *   解算 N 个动态体就该读 N 次，多一次就是遍历错了集合。
   */
  readonly bodyScans: number;
  /** `resolve()` 期间为了让"最大半径"扫过的 body 数（正常应恒为 0：那是缓存的事）。 */
  readonly maxRangeScans: number;
  /** `reindex()` 期间扫过的**格**数（正常应恒为 0：`cellOfBody` 就是用来免掉这次扫描的）。 */
  readonly cellScans: number;
  /**
   * 兜底分离**真的动过东西**的次数。
   *
   * ★ 为什么需要它：判据"静态体不动"有一个天然的假绿 —— 兜底根本没被走到，
   *   静态体当然不动。没有这个计数，那条判据在"兜底没触发"的情形下也全绿。
   */
  readonly settlePasses: number;
  /**
   * 兜底分离里**处理过的「动态-静态」对数**。
   *
   * ★★ 为什么需要它（T345）："静态体不动"这条判据有一个**双重假绿** ——
   *   ① 兜底根本没被触发（`settlePasses` 已经能治这一半）；
   *   ② 兜底触发了，但里面**一对静态都没处理过**：动态体在迭代那一轮就被弹飞了，
   *      `settleOnce` 进去时已无重叠。此时"静态体没动"是**恒真**的，
   *      而把静态体也推（M164）这种真缺陷照样抓不住。
   *   只有这个计数能证明"兜底那条分支真的带着重叠的静态对被走过"。
   */
  readonly settleStaticPushes: number;
  /**
   * `reindex()` 里**真的动了格**的次数（推动 9000 次、跨格 200 次是正常比例）。
   *
   * ★ 为什么要有这一项：`resolve()` 每推一次就 `reindex` 一次，而绝大多数推动
   *   （密集堆叠里 0.1 量级的位移）**根本没跨出格边界**。真正的重分格是
   *   `indexOf` + `splice` + 两次 Map 写 —— 在 64 个体一格的密集场景里，
   *   每次 9000 推动都做一遍这个，就是 "11ms 里的一大半"。
   *   这个计数让"该不该重分格"变成一个**可断言的事实**，而不是"改完好像快了点"。
   */
  readonly cellMoves: number;
  /**
   * 解算期间**真正比过距离**的候选对数（含不重叠的）。
   *
   * ★ 这才是密集布局的成本本体，而 `pushes` 只记"推成了几对"。两者的比值就是
   *   空间哈希的**筛选效率**：2000 体 / 间距 0.5 的实测是 9154 次推动对 ~10 万次
   *   候选检查 —— 也就是"查了 11 个才中 1 个"。这个比值随 (格宽 / 实体直径)² 涨，
   *   所以"密集场景慢"的第一嫌疑永远是**格宽没跟着实体尺寸**，而不是解算算法。
   */
  readonly pairChecks: number;
  /**
   * `query()` 内部**扫过**的条目数（含被距离粗筛排除的）。
   *
   * ★ 漏斗是三层：`candidateScans`（扫）→ `pairChecks`（比距离）→ `pushes`（真推）。
   *   密集布局 2000 体的实测：格宽 4 时 **22 万 → 1.4 万 → 5853**，格宽 0.6 时
   *   **4.3 万 → 0.5 万 → 5853** —— 推动数完全相同，差的全在"白扫了多少个"。
   *   所以"密集场景慢"的归因顺序是：先看这个数，再看格宽，最后才轮到解算算法。
   */
  readonly candidateScans: number;
}

export interface PhysicsConfig {
  /** 空间哈希 cell 边长（世界单位）。取"典型实体直径的 2~3 倍"最省。 */
  readonly cellSize?: number;
  /** 单次解算最多迭代几轮（防止一堆实体互推死循环）。 */
  readonly maxIterations?: number;
  /** 推出后保留的微小间隙，避免"刚好相切"时下一步又判定重叠。 */
  readonly skin?: number;
}

export interface IPhysicsWorld {
  add(body: PhysicsBody): void;
  remove(nodeId: number): void;
  has(nodeId: number): boolean;

  /** 附近 `r` 半径内的 body id（**包含**自身，若自身在范围内）。 */
  query(x: number, z: number, r: number): readonly number[];

  /**
   * `query` 的**饥荒同签名**别名：`FindEntities(x, z, r)`。
   *
   * ★ 为什么不是把 `query` 改名：`query` 是引擎内部（行为树/拾取/感知都用它），
   *   而 `FindEntities` 是**内容层**的名字 —— 153 万行 DST Lua 调的就是它。
   *   两边都要活，所以别名与真身必须**逐字节同一份实现**（不是转发到另一套逻辑），
   *   否则"内容层对、引擎错"这种事会各测各的绿。
   */
  findEntities(x: number, z: number, r: number): readonly number[];

  /**
   * 解算一次。返回被推动的 body 数。
   * ★ 只推动**动态** body；静态体不动（树不会因为你撞它而位移）。
   */
  resolve(): number;

  /**
   * 连续碰撞（扫掠）：这一步会不会**穿过去**（[ADR-0013](docs/adr/0013-continuous-collision.md)）。
   *
   * `resolve()` 回答的是"现在是不是叠在一起"；它按**当前**坐标找重叠对，
   * 对"一拍之内从墙的这侧到那侧"完全无能为力 —— 跨过去之后两侧不重叠，
   * 下一拍再也不会被推开。那个症状是「这只怪偶尔会穿过箱子」，而且同一个种子复现不了。
   *
   * ★ 只扫**静态**体：只有静态障碍是"解算永远救不回来"的（它不会动过来。
   *   动态体撞上之后 `resolve()` 会把两边分开，扫掠一遍反而会让两只怪互相卡住）。
   * ★ 只回答、**不改位置**：移动是调用方的事（它才知道要不要停、要不要滑、要不要播动画）。
   */
  sweepMove(nodeId: number, dx: number, dz: number): SweepHit | null;

  stats(): PhysicsStats;
  clear(): void;
}

const EPS = 1e-9;

export class SpatialHashWorld implements IPhysicsWorld {
  private cellSize: number;
  private readonly autoCell: boolean;
  private readonly maxIterations: number;
  private readonly skin: number;
  private readonly bodies = new Map<number, PhysicsBody>();
  /** cell key → body id 列表 */
  private readonly cells = new Map<string, number[]>();
  /**
   * body id → 它现在在哪个格键里。
   *
   * ★ 没有它的时候，`reindex` 只能**遍历所有格**去找这个 id（`indexOf`）——
   *   O(#格) 每次。密集场景里每一步要推几千次，于是 2000 实体 × 250 格 = 几十万次
   *   `indexOf`，实测把 2.8ms 的解算拖到 21ms。性能闸门（physics-perf.test.ts）
   *   第一次跑就把这笔账算出来了。
   */
  private readonly cellOfBody = new Map<number, string>();
  /**
   * 全场最大 `rangeOf` 的缓存。
   *
   * ★ 它原来是在 `resolve()` 的内层循环里**每个体每次迭代都重算一遍**（O(n)），
   *   于是整个解算是 O(n²·迭代)。而实体只在 add/remove 时增减 —— 这是个纯缓存问题，
   *   不是算法问题：`maxRadiusNearby()` 现在 O(1)。
   *   失效点只有 add / remove / clear 三处（body 的半径是 add 时定的，之后不可变）。
   */
  private maxRange = 0;
  /** 工作量计数（见 `PhysicsStats` 的三个同名注释）：只增不减，`clear()` 归零。 */
  private _bodyScans = 0;
  private _maxRangeScans = 0;
  private _cellScans = 0;
  private _settlePasses = 0;
  private _settleStaticPushes = 0;
  private _cellMoves = 0;
  private _pairChecks = 0;
  private _candidateScans = 0;
  /**
   * 动态体的 id 集合。
   *
   * ★ `resolve()` 原来遍历**所有** body 再 `if (b.isStatic) continue` ——
   *   于是"加 1900 棵静态树"会让 50 个动态体的解算慢 4.6 倍（实测），
   *   而静态树本不该影响动态体的成本。维护一个集合就把这一侧的开销从 O(全场)
   *   变成 O(动态数)。
   * ★ 不变量：`isStatic` 在 `add` 时确定，之后不可变（要变就先 remove 再 add）。
   */
  private readonly dynamicIds = new Set<number>();
  private readonly pos: PositionAccessor;

  private _queries = 0;
  private _pushes = 0;
  private _unresolved = 0;

  constructor(pos: PositionAccessor, cfg: PhysicsConfig = {}) {
    this.pos = pos;
    // ★★ 显式给了就听；没给就**按实体尺寸自己定**（见 `resizeCellsIfNeeded`）。
    this.autoCell = cfg.cellSize === undefined;
    this.cellSize = cfg.cellSize ?? AUTO_CELL_FALLBACK;
    this.maxIterations = cfg.maxIterations ?? 3;
    this.skin = cfg.skin ?? 0.001;
    if (!(this.cellSize > 0)) throw new RangeError("cellSize 必须 > 0");
  }

  /**
   * ★★ 自动格宽（T338）：`cellSize ≈ 2 × 全场最大 range`。
   *
   * 为什么是这个值 —— 一次解算的候选扫描量是
   *   `(覆盖格数) × (每格占用) ≈ (2r_q / cellSize + 1)² × (cellSize / 间距)²·n`
   * 其中 `r_q = 自身 range + 最大 range ≤ 2R`。格宽远大于实体尺寸时，"每格占用"
   * 按平方涨；远小于时，"覆盖格数"按平方涨。实测（2000 体 / 间距 0.5 / R=0.3）：
   * `cellSize=4`（默认值）**13.8ms** → `cellSize=1.6` 7.4ms → `1.0` 6.7ms → `0.7` **6.3ms**。
   * 最优点正好落在 `2R = 0.6` 附近。这是**成本模型**，不是"把场景调快"。
   *
   * 为什么只在**跨档**时才重建（而不是每次 add 都试）：
   *   重建是 O(n)。若按半径从小到大的顺序加载，每次 add 都想缩格 ⇒ 退化成 O(n²)。
   *   所以只有当新尺寸与当前尺寸相差 ≥ 2 倍时才重建 —— 每次重建都至少让尺寸减半/翻倍，
   *   一次加载里最多重建 O(log) 次。
   */
  private resizeCellsIfNeeded(): void {
    if (!this.autoCell) return;
    const want = Math.min(AUTO_CELL_MAX, Math.max(AUTO_CELL_MIN, 2 * this.maxRange));
    if (this.cells.size > 0) {
      const ratio = want / this.cellSize;
      if (ratio < 2 && ratio > 0.5) return;
    }
    this.cellSize = want;
    // 重建：格键里编码了格宽，旧键全部作废
    this.cells.clear();
    this.cellOfBody.clear();
    for (const [id] of this.bodies) {
      const p = this.pos.get(id);
      if (p === undefined) continue;
      const [cx, cz] = this.cellOf(p.x, p.z);
      const k = this.key(cx, cz);
      let list = this.cells.get(k);
      if (list === undefined) {
        list = [];
        this.cells.set(k, list);
      }
      list.push(id);
      this.cellOfBody.set(id, k);
      this._cellMoves++;
    }
  }

  private key(cx: number, cz: number): string {
    return cx + "," + cz;
  }

  private cellOf(x: number, z: number): [number, number] {
    return [Math.floor(x / this.cellSize), Math.floor(z / this.cellSize)];
  }

  add(body: PhysicsBody): void {
    if (!(body.radius > 0)) {
      throw new RangeError(`body ${body.nodeId} 的半径必须 > 0（收到 ${body.radius}）`);
    }
    const p = this.pos.get(body.nodeId);
    if (p === undefined) {
      throw new Error(`body ${body.nodeId} 没有位置（PositionAccessor 返回 undefined）`);
    }
    this.bodies.set(body.nodeId, body);
    const [cx, cz] = this.cellOf(p.x, p.z);
    const k = this.key(cx, cz);
    let list = this.cells.get(k);
    if (list === undefined) {
      list = [];
      this.cells.set(k, list);
    }
    list.push(body.nodeId);
    this.cellOfBody.set(body.nodeId, k);
    if (!body.isStatic) this.dynamicIds.add(body.nodeId);
    const r = this.rangeOf(body);
    if (r > this.maxRange) {
      this.maxRange = r;
      // ★ 最大实体变了 ⇒ 最优格宽可能变了（见 resizeCellsIfNeeded）
      this.resizeCellsIfNeeded();
    }
  }

  remove(nodeId: number): void {
    const k = this.cellOfBody.get(nodeId);
    const wasMax = this.bodies.get(nodeId) !== undefined && this.rangeOf(this.bodies.get(nodeId)!) >= this.maxRange;
    if (k !== undefined) {
      const list = this.cells.get(k);
      if (list !== undefined) {
        const i = list.indexOf(nodeId);
        if (i >= 0) list.splice(i, 1);
        if (list.length === 0) this.cells.delete(k);
      }
      this.cellOfBody.delete(nodeId);
    }
    this.bodies.delete(nodeId);
    this.dynamicIds.delete(nodeId);
    // ★ 只有"删掉的正是最大者"才重算：否则缓存仍然有效（重算是 O(n)，不该每次 remove 都做）
    if (wasMax) {
      this.recomputeMaxRange();
      this.resizeCellsIfNeeded();
    }
  }

  has(nodeId: number): boolean {
    return this.bodies.has(nodeId);
  }

  /**
   * 重新分格。**移动后必须调用**（由调用方每帧对动态体调一次）。
   * ★ 不做"每帧全量重建"：几千个实体全量重建的分配开销远大于"只更新动过的"。
   *   代价是调用方要记得调 —— 所以 `resolve()` 会顺带校验"位置是否还在原 cell"，
   *   不匹配就自动重分格（**容错但可观测**：`stats().staleCells` 会体现）。
   */
  reindex(nodeId: number): void {
    const b = this.bodies.get(nodeId);
    if (b === undefined) return;
    const p = this.pos.get(nodeId);
    // ★★ 快路径：**没跨出格边界就直接返回**（T338）。
    //   原来每次推动都走完整的"删索引 → 重算格 → 插回"：`indexOf` 扫整格列表、
    //   `splice` 搬数组、两次 Map 写。而密集堆叠里一次推动只有 0.1 量级，
    //   绝大多数根本不出格 —— 在一个 64 体/格的场景里，这是 9000 次/步 的白工。
    //   判据不在毫秒上：`stats().cellMoves`（真的动了几次格）必须是推动数的一小部分。
    if (p !== undefined) {
      const [ncx, ncz] = this.cellOf(p.x, p.z);
      const nk = this.key(ncx, ncz);
      if (this.cellOfBody.get(nodeId) === nk) return;
    }
    const oldKey = this.findCellOf(nodeId);
    if (oldKey !== undefined) {
      const old = this.cells.get(oldKey);
      if (old !== undefined) {
        const i = old.indexOf(nodeId);
        if (i >= 0) old.splice(i, 1);
        if (old.length === 0) this.cells.delete(oldKey);
      }
      this.cellOfBody.delete(nodeId);
    }
    if (p === undefined) return;
    const [cx, cz] = this.cellOf(p.x, p.z);
    const k = this.key(cx, cz);
    let list = this.cells.get(k);
    if (list === undefined) {
      list = [];
      this.cells.set(k, list);
    }
    list.push(nodeId);
    this.cellOfBody.set(nodeId, k);
    this._cellMoves++;
  }

  /**
   * 这个体现在在哪个格键里。
   *
   * ★ 快路径是 `cellOfBody`（O(1)）。慢路径（遍历所有格）是**兜底**：
   *   表里没有它时（例如有人绕开 `add` 手工往 `cells` 里塞过东西）仍然能找到，
   *   而且会被 `cellScans` 如实计入 —— 否则"索引没建好"会表现成"偶尔慢一下"，
   *   没人会去查。慢路径被**频繁走到**就说明索引出了问题。
   */
  private findCellOf(nodeId: number): string | undefined {
    const fast = this.cellOfBody.get(nodeId);
    if (fast !== undefined) return fast;
    for (const [key, list] of this.cells) {
      this._cellScans++;
      if (list.includes(nodeId)) return key;
    }
    return undefined;
  }

  private rangeOf(b: PhysicsBody): number {
    if (b.halfExtents !== undefined) {
      return Math.max(b.halfExtents.x, b.halfExtents.z);
    }
    return b.radius;
  }

  query(x: number, z: number, r: number): readonly number[] {
    this._queries++;
    if (!(r >= 0)) return [];
    // ★★ 扫描盒要按 `r + 全场最大 range` 算，不能只按 `r`（T338 顺带修掉的真漏格）：
    //   下面的粗筛用的是 `r + 该体自己的 range` —— 也就是说"中心在 r 之外、但边缘伸进来的"
    //   实体也该被返回。只扫 `r` 覆盖的格时，这类实体落在**盒外的相邻格**里，
    //   于是被静默漏掉。旧默认格宽 4 让格边界很粗，这种事几乎撞不上；格宽跟着实体
    //   缩小（1 左右）之后，边界立刻露出来 —— "query 与暴力枚举逐点一致"那条判据一天内就抓到。
    const scanR = r + this.maxRadiusNearby();
    const minCx = Math.floor((x - scanR) / this.cellSize);
    const maxCx = Math.floor((x + scanR) / this.cellSize);
    const minCz = Math.floor((z - scanR) / this.cellSize);
    const maxCz = Math.floor((z + scanR) / this.cellSize);
    const out: number[] = [];
    const seen = new Set<number>();
    for (let cx = minCx; cx <= maxCx; cx++) {
      for (let cz = minCz; cz <= maxCz; cz++) {
        const list = this.cells.get(this.key(cx, cz));
        if (list === undefined) continue;
        for (const id of list) {
          this._candidateScans++;
          if (seen.has(id)) continue;
          seen.add(id);
          const p = this.pos.get(id);
          if (p === undefined) continue;
          const dx = p.x - x;
          const dz = p.z - z;
          // 用"半径 + 实体范围"做粗筛，精确判定留给 (真实的距离测试)
          const b = this.bodies.get(id);
          const reach = r + (b === undefined ? 0 : this.rangeOf(b));
          if (dx * dx + dz * dz <= reach * reach + EPS) out.push(id);
        }
      }
    }
    out.sort((a, b) => a - b); // 顺序稳定 ⇒ 解算结果确定（可回放）
    return out;
  }

  /**
   * `query` 的饥荒同签名别名 —— **同一份实现**，不是转发到另一套逻辑。
   *
   * 判据钉的是"两个名字返回完全相同的数组"，不是"看起来一样"：
   * 一旦有人为了"内容层兼容"另写一遍查询，那条判据立刻红。
   */
  findEntities(x: number, z: number, r: number): readonly number[] {
    return this.query(x, z, r);
  }

  /**
   * 解算重叠。对每对 (动态, 其它)，若重叠则把动态体推开。
   *
   * ★ 为什么"逐对独立解算 + 迭代"而不是"一次性求平均位移"：
   *   后者在"三四个实体挤一个角"时会出现互相抵消、抖动。
   *   迭代式（最多 3 轮）在这个规模下更稳，而且实现只有一个循环。
   *
   * ★★ T338：每一对**每轮只处理一次**，动态-动态各让一半。
   *   原来两侧都会看到对方、各自按**全部**重叠量推 —— 于是同一对被推了两遍
   *   （总位移 2 倍，下一轮又推回来，正是密集场景抖个不停的一半原因）。
   *   两个后果都实测过：
   *   ① 工作量翻倍：密集布局 9154 次推动/步，其中一半是重复的；
   *   ② **结果带有 id 偏差**：先被遍历到的那个体不推、后来的那个被推全程，
   *      所以"挤在一起时总是同一只怪被弹开"，而判据只看距离，看不出来。
   *   现在：`otherId < id` 的动态对由**先遍历到的那一侧**处理（它已经在上一轮/本轮
   *   推过自己这一半），另外半程由对面承担 —— 总位移与原来相同（`overlap + skin`），
   *   但每对每轮只算一次，且两侧对称。
   */
  /**
   * 连续碰撞（扫掠）的实现：把候选体换成"静态障碍"再交给纯函数。
   *
   * ★ 候选集用 `query(起点, 位移长度 + 自身半径 + 最大障碍半径)`：那是**圆**的保守范围。
   *   用轴对齐的方框范围会漏掉斜方向的候选 —— 而漏掉的症状正是"偶尔穿过去"，
   *   与这段代码要修的问题一模一样，所以这里宁可多扫几个。
   */
  sweepMove(nodeId: number, dx: number, dz: number): SweepHit | null {
    const self = this.bodies.get(nodeId);
    if (self === undefined) return null;
    const p = this.pos.get(nodeId);
    if (p === undefined) return null;
    const reach = Math.hypot(dx, dz) + self.radius + this.maxRange;
    const boxes: SweepBox[] = [];
    const circles: { cx: number; cz: number; r: number; nodeId: number }[] = [];
    for (const id of this.query(p.x, p.z, reach)) {
      if (id === nodeId) continue;
      const other = this.bodies.get(id);
      if (other === undefined || !other.isStatic) continue;
      const q = this.pos.get(id);
      if (q === undefined) continue;
      if (other.halfExtents !== undefined) {
        boxes.push({ cx: q.x, cz: q.z, hx: other.halfExtents.x, hz: other.halfExtents.z, nodeId: id });
      } else {
        circles.push({ cx: q.x, cz: q.z, r: other.radius, nodeId: id });
      }
    }
    const fromBoxes = boxes.map((b) => sweepCircleVsBox(p.x, p.z, dx, dz, self.radius, b));
    const fromCircles = circles.map((c) => sweepCircleVsCircle(p.x, p.z, dx, dz, self.radius, c.cx, c.cz, c.r, c.nodeId));
    return earliestHit([...fromBoxes, ...fromCircles]);
  }

  resolve(): number {
    let moved = 0;
    for (let iter = 0; iter < this.maxIterations; iter++) {
      let movedThis = 0;
      for (const id of this.dynamicIds) {
        this._bodyScans++;
        const b = this.bodies.get(id);
        if (b === undefined) continue;
        const p = this.pos.get(id);
        if (p === undefined) continue;
        // ★ 这里只要"自身范围"：query 内部会再扩一个 maxRange，合起来正是
        //   "两体范围内的候选"（旧写法自己加 maxRange，配合上面的修复会扩两遍）
        const near = this.query(p.x, p.z, this.rangeOf(b));
        for (const otherId of near) {
          if (otherId === id) continue;
          this._pairChecks++;
          const ob = this.bodies.get(otherId);
          if (ob === undefined) continue;
          // 动态-动态：由 id 小的那一侧负责这一对（见方法注释）
          if (ob.isStatic !== true && otherId < id) continue;
          const op = this.pos.get(otherId);
          if (op === undefined) continue;
          const dx = p.x - op.x;
          const dz = p.z - op.z;
          const distSq = dx * dx + dz * dz;
          const minDist = this.effectiveRadius(b, dx, dz) + this.effectiveRadius(ob, -dx, -dz);
          if (distSq >= minDist * minDist - EPS) continue;
          let dist = Math.sqrt(distSq);
          let nx: number;
          let nz: number;
          if (dist < EPS) {
            // 完全重合：给一个**确定**的分离方向（不能靠随机，否则不可回放）
            nx = 1;
            nz = 0;
            dist = 0;
          } else {
            nx = dx / dist;
            nz = dz / dist;
          }
          const push = minDist - dist + this.skin;
          this.pos.set(id, p.x + nx * push, p.z + nz * push);
          p.x += nx * push;
          p.z += nz * push;
          this._pushes++;
          movedThis++;
          this.reindex(id);
        }
      }
      moved += movedThis;
      if (movedThis === 0) break;
      if (iter === this.maxIterations - 1 && movedThis > 0) {
        this._unresolved++;
        // ★★ 迭代用尽仍在推 ⇒ 进入**兜底分离**（一次，不是又一轮迭代）。
        //   没有这一步时，密集堆叠的表现是"每帧推一点、下一帧又被推回来"：
        //   位置在抖，而 `unresolved` 只记了一个数，看不出画面在抖。
        moved += this.settleOnce();
      }
    }
    return moved;
  }

  /**
   * 兜底分离：**一次性**把仍然重叠的对按重叠量分开，不再迭代。
   *
   * ★ 三条性质必须同时成立，缺一条这个兜底就比抖动更糟：
   *   ① **确定性**：完全重合时沿 +x 分（不给随机方向）—— 否则同种子同操作的两个世界
   *      会跑出不同位置，存档比对与回放全部失效；
   *   ② **静态体不动**：静态体是"墙"，被兜底推动等于物理规则在最后一帧变了；
   *   ③ **每对只处理一次**：用 `id < otherId` 过滤，否则同一对会被推两遍（双倍位移）。
   *
   * 它**不保证**一次分开（三角堆叠仍然需要多帧），但保证"每帧都在往分开的方向走"，
   * 而不是在两个位置之间来回。重叠是否真的消掉仍由调用方看 `unresolved` 与实测决定。
   */
  private settleOnce(): number {
    let moved = 0;
    for (const id of this.dynamicIds) {
      const b = this.bodies.get(id);
      if (b === undefined) continue;
      const p = this.pos.get(id);
      if (p === undefined) continue;
      const near = this.query(p.x, p.z, this.rangeOf(b));
      for (const otherId of near) {
        if (otherId === id) continue;
        const ob = this.bodies.get(otherId);
        if (ob === undefined) continue;
        // ★ 每对只处理一次：动态-动态按 id 小的那一侧处理；**静态体永远由对面那一侧处理**
        //   （静态不在 `dynamicIds` 里，不会被再遍历一次）。
        //   ★★ 第一版写成 `if (otherId <= id) continue` 时，`(动态 100, 静态 1)` 这种对
        //   会被**永久跳过** —— 因为遍历的是动态体，静态体那一侧永远不会来"处理"。
        //   判据 M164 就是拿这个当靶子：静态体能被推动了才说明这一对真被处理过。
        if (ob.isStatic !== true && otherId < id) continue;
        const op = this.pos.get(otherId);
        if (op === undefined) continue;
        const dx = p.x - op.x;
        const dz = p.z - op.z;
        const distSq = dx * dx + dz * dz;
        const minDist = this.effectiveRadius(b, dx, dz) + this.effectiveRadius(ob, -dx, -dz);
        if (distSq >= minDist * minDist - EPS) continue;
        let dist = Math.sqrt(distSq);
        let nx = 1;
        let nz = 0;
        if (dist >= EPS) {
          nx = dx / dist;
          nz = dz / dist;
        } else {
          dist = 0;
        }
        const overlap = minDist - dist + this.skin;
        // 谁动：动的是动态那一侧；两边都动就各走一半（顺序由 id 定，结果确定）
        const bStatic = b.isStatic === true;
        const oStatic = ob.isStatic === true;
        if (bStatic && oStatic) continue;
        // ★ T345：这一对是"动态-静态" ⇒ 记一笔。没有它，"静态体不动"在
        //   "兜底一对静态都没处理"的情形下是恒真的（见 PhysicsStats.settleStaticPushes）。
        if (oStatic) this._settleStaticPushes++;
        const shareSelf = bStatic ? 0 : oStatic ? 1 : 0.5;
        const shareOther = oStatic ? 0 : bStatic ? 1 : 0.5;
        if (shareSelf > 0) {
          this.pos.set(id, p.x + nx * overlap * shareSelf, p.z + nz * overlap * shareSelf);
          p.x += nx * overlap * shareSelf;
          p.z += nz * overlap * shareSelf;
        }
        if (shareOther > 0) {
          this.pos.set(otherId, op.x - nx * overlap * shareOther, op.z - nz * overlap * shareOther);
          op.x -= nx * overlap * shareOther;
          op.z -= nz * overlap * shareOther;
        }
        this._pushes++;
        moved++;
      }
    }
    if (moved > 0) {
      this._settlePasses++;
      for (const id of this.dynamicIds) this.reindex(id);
    }
    return moved;
  }

  /** AABB 用"沿方向上的投影半径"，圆形直接用半径。 */
  private effectiveRadius(b: PhysicsBody, dx: number, dz: number): number {
    if (b.halfExtents === undefined) return b.radius;
    const l = Math.sqrt(dx * dx + dz * dz);
    if (l < EPS) return Math.max(b.halfExtents.x, b.halfExtents.z);
    return Math.abs((dx / l) * b.halfExtents.x) + Math.abs((dz / l) * b.halfExtents.z);
  }

  /**
   * O(1)：直接读缓存。
   *
   * ★★ 这里曾经是 `for (const b of this.bodies.values())` —— 也就是**注释写着 O(1)，
   *   代码是 O(n)**，而且被 `resolve()` 的内层循环每个体每次迭代各调一次（O(n²·迭代)）。
   *   缓存 `maxRange` 当时就已经在维护了（add / remove / clear 三处都更新），
   *   只是**没有任何地方读它**。批47 引入 `maxRangeScans` 计数后立刻显形：
   *   一次 2000 体的解算扫了 6000 个 body 去算一个从没变过的数。
   */
  private maxRadiusNearby(): number {
    return this.maxRange;
  }

  /**
   * **唯一的**全量扫描入口（自带计数）。
   *
   * ★ 为什么要有这个"唯一入口"：`maxRangeScans` 只有在这里加，才可能在
   *   "有人把缓存换回扫描"时报警。如果扫描能绕过它，计数就是摆设 ——
   *   而摆设比没有更坏：它会让人以为"扫没扫"这件事已经被守住了。
   */
  private scanMaxRange(): number {
    let m = 0;
    for (const b of this.bodies.values()) {
      this._maxRangeScans++;
      const r = this.rangeOf(b);
      if (r > m) m = r;
    }
    return m;
  }

  private recomputeMaxRange(): void {
    this.maxRange = this.scanMaxRange();
  }

  stats(): PhysicsStats {
    return {
      bodies: this.bodies.size,
      cells: this.cells.size,
      queries: this._queries,
      pushes: this._pushes,
      unresolved: this._unresolved,
      bodyScans: this._bodyScans,
      maxRangeScans: this._maxRangeScans,
      cellScans: this._cellScans,
      settlePasses: this._settlePasses,
      settleStaticPushes: this._settleStaticPushes,
      cellMoves: this._cellMoves,
      pairChecks: this._pairChecks,
      candidateScans: this._candidateScans,
    };
  }

  clear(): void {
    this.bodies.clear();
    this.cells.clear();
    this.cellOfBody.clear();
    this.dynamicIds.clear();
    this.maxRange = 0;
    this._queries = 0;
    this._pushes = 0;
    this._unresolved = 0;
    this._bodyScans = 0;
    this._maxRangeScans = 0;
    this._cellScans = 0;
    this._settlePasses = 0;
    this._settleStaticPushes = 0;
    this._cellMoves = 0;
    this._pairChecks = 0;
    this._candidateScans = 0;
  }
}

/**
 * 从 Scene 建物理世界（适配器）。
 * ★ 放在 L4（extensions）而不是 core：物理是**可选能力**，
 *   内核不该知道"世界上有碰撞"这件事。
 */
export interface SceneLike {
  readonly id: number;
  worldPosition(): { x: number; y: number };
  setLocalPosition(x: number, y: number): void;
}

export function makeSceneAccessor(
  lookup: (nodeId: number) => SceneLike | undefined,
): PositionAccessor {
  return {
    get(nodeId: number): { x: number; z: number } | undefined {
      const n = lookup(nodeId);
      if (n === undefined) return undefined;
      const p = n.worldPosition();
      // 2.5D：世界 XZ ← Node 的 (x, y)
      return { x: p.x, z: p.y };
    },
    set(nodeId: number, x: number, z: number): void {
      const n = lookup(nodeId);
      if (n === undefined) return;
      // 注意：这里写的是**局部**位置。父节点非单位变换时会有偏差 ——
      // 已知限制，写在文档里（当前世界的可碰撞实体都是根节点直属子节点）。
      n.setLocalPosition(x, z);
    },
  };
}

export type { EngineError, Result };
export { err, ok };
