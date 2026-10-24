/**
 * L4 · AI 目标选择（阶段 3：**盯住哪一个**）
 *
 * 感知给了"看得见什么"，本文件回答"盯哪一个、什么时候换"。
 *
 * ★ 这个文件存在的唯一理由：**不抖动**。
 *   最朴素的写法是每 tick 取最近的 —— 于是两个同样近的目标会让人物每帧来回改主意
 *   （猎狗在两棵果树之间左右横跳，一步也走不出去）。而"每帧改主意"在日志里
 *   完全看不出来：它每一帧都是"正确的最近目标"。
 *
 *   所以这里用**迟滞（hysteresis）**：已经盯着的目标只有在新目标**明显更近**时才换。
 *   `stickiness` 就是这个"明显"的量化：0.2 表示"新目标必须近 20% 以上"。
 *   这个数不是拍出来的 —— 它把"换目标的收益"和"换目标要走的路"绑在同一个量纲上。
 *
 * ★ 平手必须可判：`(距离², 节点 id)` 升序。否则"两个同距目标"谁被选中取决于
 *   感知列表的顺序，而那是遍历序（见 `perception.ts` 文件头 ①）。
 *
 * ★ 目标丢了也要有个过渡：`graceTicks` 内保留原目标（追到一半跟丢了不该立刻忘），
 *   超过就放弃。**不能让"看不见"等于"没有"**，也不能等于"永远记得"。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, ok } from "../../foundation/result.ts";
import type { Sensed } from "./perception.ts";

export type TargetPolicy = "nearest" | "farthest" | "preferred";

export const AI_BAD_TARGET = "AI.BAD_TARGET";

export interface TargetOptions {
  /** 默认 `nearest`。 */
  readonly policy?: TargetPolicy;
  /**
   * `preferred` 用：类型优先级（排在前面的更想要）。列表外的类型不会被选中。
   * 省略时 `preferred` 退化为 `nearest` —— 但**会写在报告里**（不静默）。
   */
  readonly preferred?: readonly string[];
  /**
   * 迟滞系数 0..1（默认 0.2）：新目标要比当前近 `stickiness` 比例才换。
   * 0 = 每 tick 都取最优（会抖，但可测）；1 = 除非当前没了，否则绝不换。
   */
  readonly stickiness?: number;
  /** 目标跟丢后还保留多少 tick（默认 0）。 */
  readonly graceTicks?: number;
}

/** 一次选择的报告。判据需要"为什么选了它"，所以把候选数也带出来。 */
export interface TargetChoice {
  readonly nodeId: number | null;
  /** 本轮参与比较的候选数（不含 `stale` 的，除非开了 grace）。 */
  readonly candidates: number;
  /** `true` = 与上轮相同，**没有**换目标。 */
  readonly kept: boolean;
  /** `true` = 当前目标是记忆里的（stale）且在 grace 内。 */
  readonly stale: boolean;
}

export class TargetTracker {
  private readonly policy: TargetPolicy;
  private readonly preferred: readonly string[];
  private readonly stickiness: number;
  private readonly graceTicks: number;

  private target: number | null = null;
  private lastSeenTick = -1;

  constructor(options: TargetOptions = {}) {
    const stick = options.stickiness ?? 0.2;
    if (!(stick >= 0 && stick <= 1)) throw new RangeError(`stickiness 必须在 [0,1] 内，得到 ${String(stick)}`);
    const grace = options.graceTicks ?? 0;
    if (!Number.isInteger(grace) || grace < 0) throw new RangeError(`graceTicks 必须是 >= 0 的整数，得到 ${String(grace)}`);
    this.policy = options.policy ?? "nearest";
    this.preferred = options.preferred ?? [];
    this.stickiness = stick;
    this.graceTicks = grace;
  }

  current(): number | null {
    return this.target;
  }

  reset(): void {
    this.target = null;
    this.lastSeenTick = -1;
  }

  /**
   * 根据这一轮的感知结果决定目标。
   *
   * @param candidates 感知结果（**必须**已按 `perception.ts` 的规则排序；
   *                   本函数不重新排序 —— 它要能证明"排序是感知的契约"）。
   */
  update(candidates: readonly Sensed[], tick: number): Result<TargetChoice, EngineError> {
    if (this.policy === "preferred" && this.preferred.length === 0) {
      return {
        ok: false,
        error: engineError(AI_BAD_TARGET, "policy=preferred 但没给 preferred 列表 —— 想要什么没定义"),
      };
    }

    const usable = candidates.filter((c) => this.accepts(c));
    let best: Sensed | null = null;
    for (const c of usable) {
      if (best === null || this.better(c, best)) best = c;
    }

    // ---- 当前目标还在吗
    const cur = this.target === null ? undefined : candidates.find((c) => c.nodeId === this.target);
    if (cur !== undefined && !cur.stale) {
      this.lastSeenTick = tick;
    }

    // ---- 没目标：直接用最优
    if (this.target === null) {
      this.target = best === null ? null : best.nodeId;
      if (this.target !== null) this.lastSeenTick = best!.stale ? best!.seenTick : tick;
      return ok({ nodeId: this.target, candidates: usable.length, kept: false, stale: best?.stale ?? false });
    }

    // ---- 有目标但这一轮看不见：grace 内保留，超时放弃后重选
    if (cur === undefined || cur.stale) {
      const since = cur === undefined ? tick - Math.max(this.lastSeenTick, 0) : tick - cur.seenTick;
      if (cur !== undefined && since <= this.graceTicks) {
        return ok({ nodeId: this.target, candidates: usable.length, kept: true, stale: true });
      }
      if (cur === undefined && this.graceTicks > 0 && tick - this.lastSeenTick <= this.graceTicks) {
        // 目标已经从场景里消失（节点被销毁）：grace 内仍记着它，坐标由调用方从记忆里取
        return ok({ nodeId: this.target, candidates: usable.length, kept: true, stale: true });
      }
      this.target = best === null ? null : best.nodeId;
      if (this.target !== null) this.lastSeenTick = best!.stale ? best!.seenTick : tick;
      return ok({ nodeId: this.target, candidates: usable.length, kept: false, stale: best?.stale ?? false });
    }

    // ---- 目标可见：只有当新目标"明显更好"才换（迟滞）
    if (best === null || best.nodeId === this.target) {
      return ok({ nodeId: this.target, candidates: usable.length, kept: true, stale: false });
    }
    if (this.clearlyBetter(best, cur)) {
      this.target = best.nodeId;
      this.lastSeenTick = tick;
      return ok({ nodeId: this.target, candidates: usable.length, kept: false, stale: false });
    }
    return ok({ nodeId: this.target, candidates: usable.length, kept: true, stale: false });
  }

  /** 这个候选能不能被选（`preferred` 会过滤掉列表外的类型）。 */
  private accepts(c: Sensed): boolean {
    if (this.policy !== "preferred") return true;
    return this.preferred.includes(c.type);
  }

  /** 比较两个候选：`policy` 决定方向，平手按节点 id 升序。 */
  private better(a: Sensed, b: Sensed): boolean {
    switch (this.policy) {
      case "farthest":
        return a.dist2 !== b.dist2 ? a.dist2 > b.dist2 : a.nodeId < b.nodeId;
      case "preferred": {
        const ra = this.preferred.indexOf(a.type);
        const rb = this.preferred.indexOf(b.type);
        if (ra !== rb) return ra < rb;
        return a.dist2 !== b.dist2 ? a.dist2 < b.dist2 : a.nodeId < b.nodeId;
      }
      case "nearest":
      default:
        return a.dist2 !== b.dist2 ? a.dist2 < b.dist2 : a.nodeId < b.nodeId;
    }
  }

  /**
   * 迟滞判定：新目标要"明显更好"才换。
   *
   * ★ 三种策略各自的"更好"方向不同，**不能用"取相反数再统一比大小"糊过去** ——
   *   第一版就是那样写的：`farthest` 下距离取负，`new < cur * 0.8` 让负得越多越容易通过，
   *   于是"远一点点"也立刻换目标，迟滞等于没有。方向不同的量不该共用一个阈值公式。
   */
  private clearlyBetter(next: Sensed, cur: Sensed): boolean {
    const s = this.stickiness;
    switch (this.policy) {
      case "farthest":
        // 越远越好：要远出 `s` 比例才换
        return next.dist2 > cur.dist2 * (1 + s);
      case "preferred": {
        const rn = this.preferred.indexOf(next.type);
        const rc = this.preferred.indexOf(cur.type);
        if (rn !== rc) return rn < rc;
        return next.dist2 < cur.dist2 * (1 - s);
      }
      case "nearest":
      default:
        return next.dist2 < cur.dist2 * (1 - s);
    }
  }
}
