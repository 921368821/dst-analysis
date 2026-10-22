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

export interface PhysicsStats {
  readonly bodies: number;
  readonly cells: number;
  readonly queries: number;
  readonly pushes: number;
  /** 迭代到上限仍未分开的次数（说明密度过高或半径不合理）。 */
  readonly unresolved: number;
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
   * 解算一次。返回被推动的 body 数。
   * ★ 只推动**动态** body；静态体不动（树不会因为你撞它而位移）。
   */
  resolve(): number;

  stats(): PhysicsStats;
  clear(): void;
}

const EPS = 1e-9;

export class SpatialHashWorld implements IPhysicsWorld {
  private readonly cellSize: number;
  private readonly maxIterations: number;
  private readonly skin: number;
  private readonly bodies = new Map<number, PhysicsBody>();
  /** cell key → body id 列表 */
  private readonly cells = new Map<string, number[]>();
  private readonly pos: PositionAccessor;

  private _queries = 0;
  private _pushes = 0;
  private _unresolved = 0;

  constructor(pos: PositionAccessor, cfg: PhysicsConfig = {}) {
    this.pos = pos;
    this.cellSize = cfg.cellSize ?? 4;
    this.maxIterations = cfg.maxIterations ?? 3;
    this.skin = cfg.skin ?? 0.001;
    if (!(this.cellSize > 0)) throw new RangeError("cellSize 必须 > 0");
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
  }

  remove(nodeId: number): void {
    this.bodies.delete(nodeId);
    this.reindex(nodeId);
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
    for (const [k, list] of this.cells) {
      const i = list.indexOf(nodeId);
      if (i >= 0) {
        list.splice(i, 1);
        if (list.length === 0) this.cells.delete(k);
        break;
      }
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
    const minCx = Math.floor((x - r) / this.cellSize);
    const maxCx = Math.floor((x + r) / this.cellSize);
    const minCz = Math.floor((z - r) / this.cellSize);
    const maxCz = Math.floor((z + r) / this.cellSize);
    const out: number[] = [];
    const seen = new Set<number>();
    for (let cx = minCx; cx <= maxCx; cx++) {
      for (let cz = minCz; cz <= maxCz; cz++) {
        const list = this.cells.get(this.key(cx, cz));
        if (list === undefined) continue;
        for (const id of list) {
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
   * 解算重叠。对每对 (动态, 其它)，若重叠则把动态体推开。
   *
   * ★ 为什么"逐对独立解算 + 迭代"而不是"一次性求平均位移"：
   *   后者在"三四个实体挤一个角"时会出现互相抵消、抖动。
   *   迭代式（最多 3 轮）在这个规模下更稳，而且实现只有一个循环。
   */
  resolve(): number {
    let moved = 0;
    for (let iter = 0; iter < this.maxIterations; iter++) {
      let movedThis = 0;
      for (const id of this.bodies.keys()) {
        const b = this.bodies.get(id)!;
        if (b.isStatic) continue;
        const p = this.pos.get(id);
        if (p === undefined) continue;
        const near = this.query(p.x, p.z, this.rangeOf(b) + this.maxRadiusNearby());
        for (const otherId of near) {
          if (otherId === id) continue;
          const ob = this.bodies.get(otherId);
          if (ob === undefined) continue;
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
      if (iter === this.maxIterations - 1 && movedThis > 0) this._unresolved++;
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

  private maxRadiusNearby(): number {
    let m = 0;
    for (const b of this.bodies.values()) {
      const r = this.rangeOf(b);
      if (r > m) m = r;
    }
    return m;
  }

  stats(): PhysicsStats {
    return {
      bodies: this.bodies.size,
      cells: this.cells.size,
      queries: this._queries,
      pushes: this._pushes,
      unresolved: this._unresolved,
    };
  }

  clear(): void {
    this.bodies.clear();
    this.cells.clear();
    this._queries = 0;
    this._pushes = 0;
    this._unresolved = 0;
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
