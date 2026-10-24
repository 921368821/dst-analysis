/**
 * L4 · AI 感知（阶段 3 的最后一块之一：**看得见什么**）
 *
 * 行为树回答"该干什么"，而"该干什么"的第一个输入是"周围有什么"。
 * 本文件只做这件事：**把场景里"我看得见的东西"变成一个排好序的列表**。
 *
 * ★ 四个刻意的设计决定（每一条都对应一类难查的 bug）：
 *
 * ① **输出必须排序**：按 `(距离², 节点 id)` 升序。
 *    不排序的话，顺序取决于 `scene.root.walk` 的遍历序 —— 而那是节点插入序，
 *    将来加个对象池复用节点就会变。行为树里"取第一个"的分支会跟着变，
 *    表现为"同种子同世界，怪物有时往左有时往右"，而回放只认字节。
 *
 * ② **用距离平方，不开方**：`Math.sqrt` 在不同平台是**允许**有 1 ulp 差异的
 *    （IEEE 754 不要求正确舍入）。感知结果如果参与存档或决策，"几乎相等的两个距离"
 *    可能在一台机器上判为 A 更近、另一台判为 B 更近。少一次开方就少一处这类风险。
 *
 * ③ **记忆带 TTL，且只在"真的看见"时刷新**：
 *    看不见的目标记"最后位置"，超过 `memoryTicks` 就忘。判据要能证明
 *    "记得住、也会忘" —— 只会记得不算记忆，那是缓存泄漏。
 *
 * ④ **视野用角度差，不用点积**：
 *    点积在"正好在边界上"时会放大浮点误差（`cos(90°)` 不是 0）；
 *    角度差是同一个量纲上的比较，边界行为可以写成判据（半角 ±0.01° 两边各验一次）。
 *
 * ★ 不做什么：**不做遮挡**（视线被树挡住）。2.5D 俯视角里没有可靠的遮挡语义，
 *   硬做会得到一个"看起来在算、实际在猜"的东西。真需要时应该走导航网格/可见性图，
 *   那是另一批。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import type { Scene } from "../../core/scene/scene.ts";

export const AI_NO_SELF = "AI.NO_SELF";
export const AI_BAD_SENSE = "AI.BAD_SENSE";

export interface SenseConfig {
  /** 感知半径（世界单位，必须 > 0）。 */
  readonly range: number;
  /**
   * 关心哪些组件类型。**顺序即优先级**：一个节点同时带两种类型时，
   * 报告里的 `type` 取排在前面的那个 —— 顺序写死，避免"谁先注册谁优先"。
   */
  readonly watch: readonly string[];
  /**
   * 视野半角（度）。省略 = 全向（360°）。
   * `90` 表示"前方 180° 的扇区"（半角 90°）。
   */
  readonly halfAngleDeg?: number;
  /** 看不见之后还能记多少 tick（默认 0 = 立刻忘）。 */
  readonly memoryTicks?: number;
}

/** 一个被感知到的目标。 */
export interface Sensed {
  readonly nodeId: number;
  /** `watch` 里第一个命中的类型。 */
  readonly type: string;
  readonly x: number;
  readonly z: number;
  /** 距离**平方**（理由见文件头 ②）。 */
  readonly dist2: number;
  /** 最后一次**真的看见**它的 tick（来自记忆时为旧值）。 */
  readonly seenTick: number;
  /** `true` 表示这一轮看不见，是记忆里的位置。 */
  readonly stale: boolean;
}

interface Remembered {
  readonly x: number;
  readonly z: number;
  readonly type: string;
  seenTick: number;
}

const DEG = Math.PI / 180;

/** 把 `sensed` 排成"决策可用"的顺序：距离升序，同距离按节点 id 升序。 */
function byDistance(a: Sensed, b: Sensed): number {
  if (a.dist2 !== b.dist2) return a.dist2 - b.dist2;
  return a.nodeId - b.nodeId;
}

/**
 * 感知器（**有状态**：它记东西）。
 *
 * 为什么是一个类而不是纯函数：记忆是"每个 agent 一份"的运行时状态，
 * 纯函数版本必须让调用方自己搬一个 Map 进来 —— 那和"每个 agent 一份 Board"
 * 是同一个取舍（见 `behavior.ts` 文件头）。
 */
export class Perception {
  private readonly cfg: Required<Omit<SenseConfig, "halfAngleDeg">> & { halfAngleDeg: number | undefined };
  private readonly memory = new Map<number, Remembered>();
  /** 上一轮真的看见的节点 id 集合（`stale` 判定用它，不用再扫一遍场景）。 */
  private visibleNow = new Set<number>();

  constructor(config: SenseConfig) {
    if (!(config.range > 0) || !Number.isFinite(config.range)) {
      throw new RangeError(`感知半径必须是 > 0 的有限数，得到 ${String(config.range)}`);
    }
    if (config.watch.length === 0) {
      throw new RangeError("watch 不能为空 —— 一个什么都看不见的感知器和没有感知是一回事");
    }
    if (config.halfAngleDeg !== undefined && !(config.halfAngleDeg > 0 && config.halfAngleDeg <= 180)) {
      throw new RangeError(`halfAngleDeg 必须在 (0, 180] 内，得到 ${String(config.halfAngleDeg)}`);
    }
    if (config.memoryTicks !== undefined && (!Number.isInteger(config.memoryTicks) || config.memoryTicks < 0)) {
      throw new RangeError(`memoryTicks 必须是 >= 0 的整数，得到 ${String(config.memoryTicks)}`);
    }
    this.cfg = {
      range: config.range,
      watch: [...config.watch],
      memoryTicks: config.memoryTicks ?? 0,
      halfAngleDeg: config.halfAngleDeg,
    };
  }

  /** 当前记忆条数（判据用它证"会忘"，也用来兜"记忆无限增长"）。 */
  memorySize(): number {
    return this.memory.size;
  }

  forgetAll(): void {
    this.memory.clear();
    this.visibleNow.clear();
  }

  /**
   * 感知一次。
   *
   * @param facingRad 朝向（弧度）。给了 `halfAngleDeg` 就必须给朝向 ——
   *                  否则"前方"没有定义，只能报错，不能默默当全向。
   */
  sense(scene: Scene, selfId: number, tick: number, facingRad?: number): Result<readonly Sensed[], EngineError> {
    const self = scene.find(selfId);
    if (self === undefined) {
      return err(engineError(AI_NO_SELF, `感知者 ${String(selfId)} 不在场景里`));
    }
    if (this.cfg.halfAngleDeg !== undefined && (facingRad === undefined || !Number.isFinite(facingRad))) {
      return err(
        engineError(AI_BAD_SENSE, "配置了视野半角，但没给朝向 —— 「前方」没有定义，不能当全向处理", {
          selfId,
        }),
      );
    }

    const range2 = this.cfg.range * this.cfg.range;
    const halfDeg = this.cfg.halfAngleDeg;
    const sp = self.worldPosition;
    const visibleNow = new Set<number>();
    const out: Sensed[] = [];

    scene.root.walk((n) => {
      if (n.id === selfId) return;
      // 先看类型（最便宜的过滤）：一个节点可能带多个 watch 类型，取顺序里第一个
      let type: string | undefined;
      for (const t of this.cfg.watch) {
        if (n.get(t) !== undefined) {
          type = t;
          break;
        }
      }
      if (type === undefined) return;
      const p = n.worldPosition;
      const dx = p.x - sp.x;
      const dz = p.y - sp.y;
      const d2 = dx * dx + dz * dz;
      if (d2 > range2) return;
      if (halfDeg !== undefined) {
        // 朝向是弧度、半角是度：先统一成度再比，边界行为才写得出来
        const angDeg = (Math.atan2(dz, dx) / DEG + 360) % 360;
        const faceDeg = ((facingRad! / DEG) % 360 + 360) % 360;
        let diff = Math.abs(angDeg - faceDeg);
        if (diff > 180) diff = 360 - diff;
        if (diff > halfDeg) return;
      }
      visibleNow.add(n.id);
      out.push({ nodeId: n.id, type, x: p.x, z: p.y, dist2: d2, seenTick: tick, stale: false });
    });

    // ---- 更新记忆：看见的刷新、超时且这一轮没看见的遗忘
    // ★ `memoryTicks === 0` 时**根本不记**：先 set 再"永不删除"会让 memory 无限增长
    //   （一个不做记忆的感知器，跑了 10 分钟以后每个节点都还在里面）。
    if (this.cfg.memoryTicks > 0) {
      for (const s of out) this.memory.set(s.nodeId, { x: s.x, z: s.z, type: s.type, seenTick: tick });
      for (const [id, m] of [...this.memory]) {
        if (visibleNow.has(id)) continue;
        if (tick - m.seenTick > this.cfg.memoryTicks) this.memory.delete(id);
      }
      // 记忆里的目标也要进结果（stale），否则"追到一半跟丢了就当场失忆"
      for (const [id, m] of this.memory) {
        if (visibleNow.has(id)) continue;
        const p = scene.find(id)?.worldPosition;
        // ★ 目标已被销毁（node 不在）时用记忆里的坐标；还活着就用当前坐标
        const x = p?.x ?? m.x;
        const z = p?.y ?? m.z;
        const dx = x - sp.x;
        const dz = z - sp.y;
        out.push({ nodeId: id, type: m.type, x, z, dist2: dx * dx + dz * dz, seenTick: m.seenTick, stale: true });
      }
    } else {
      this.memory.clear();
    }
    this.visibleNow = visibleNow;

    out.sort(byDistance);
    return ok(out);
  }

  /** 这一轮真的看见的节点 id（升序）。判据用它区分"看见"与"记得"。 */
  visibleIds(): readonly number[] {
    return [...this.visibleNow].sort((a, b) => a - b);
  }
}
