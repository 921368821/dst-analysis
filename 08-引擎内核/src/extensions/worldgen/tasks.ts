/**
 * L4 · 世界任务表（按 tick 周期性地维护世界）
 *
 * 世界生成是一次性的；世界里真正长期发生的是"每隔一段时间做一件事" ——
 * 资源再生、季节切换、群系回填。这张表就是那个"每隔一段时间"。
 *
 * ★★ 四条承重决定：
 *
 * ① **表是纯数据，不是函数**（与行为树同一原则）。
 *    `{ id, periodTicks, phase, biomes, picksPerRun }` 全部可 `canonicalize`。
 *    一旦允许写 `() => {...}`，表就不能存档、不能比对、不能从编辑器改 ——
 *    而这些恰恰是"任务表"唯一需要的属性。判据里有一条直接断言整表能过规范化序列化。
 *
 * ② **只吃 tick，不吃秒/墙钟**。
 *    秒会随帧率变化，墙钟会让"暂停"和"存档回档"产生分歧。
 *    tick 是唯一单调且与真实时间解耦的量（`FixedStepScheduler` 的 tick 从 1 起）。
 *
 * ③ ★★ **一次推进里，每个任务最多触发一次，并把"漏了几次"报出来**。
 *    这就是"离线 8 小时回来，不能瞬间把地图刷满"的那条线。
 *    如果把跳时间当成"补齐 N 次执行"，1000 tick 的跳跃会让 `periodTicks=10` 的任务
 *    连跑 100 次 —— 每一次都要 spawn、要写存档、要发事件。
 *    所以 `advanceTo()` 的语义是**一次推进**而不是"逐 tick 模拟"，
 *    `missed` 把"本该发生的次数"变成调用方可见的事实（而不是悄悄吞掉）。
 *    需要逐 tick 精确行为（比如刷怪要落在具体 tick 上做动画）的调用方，
 *    自己按 1 tick 反复调用 —— 代价明确，收益明确。
 *
 * ④ **随机由 (任务 id, 首次到期 tick) 派生**，不用一条连续流。
 *    连续流会让结果依赖"任务在表里的位置"和"别的任务跑了几次"，
 *    于是往表里插一个任务就会改变所有其它任务的产出。
 *    派生式 RNG 让每个任务是**独立的**：判据里有一条专门验"表的声明顺序不影响单任务输出"。
 *
 * ★ 为什么 `run` **不在** seed 里（这是写变异时才发现的第一版错误）：
 *   把 run 混进 seed 会让"同一 tick 的产出"依赖执行历史 ——
 *   读档后重建实例、推进到同一个 tick，run 从 1 重新数，于是刷到**另一批**格子上，
 *   可重放性当场失效。内容寻址的随机必须只依赖内容（id + tick），不依赖历史。
 *   `run` 因此只用于诊断（`runCounts()`）与"跳时间后有没有复位"这类断言。
 *   `run` 仍然**单调递增、不因跳时间复位** —— 它记录的是"这条任务一共跑过几次"，
 *   与"产出什么"无关（后者只看 id + tick）。
 */

import { fingerprintOf } from "../../foundation/canonical.ts";
import { XorShift128 } from "../../foundation/random.ts";
import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import { isBiomeKind, isPassable, type BiomeKind, type WorldPlan } from "./worldgen.ts";

/** 表结构版本。字段语义变了就升它 —— 旧表在新代码里必须能被拒绝，而不是"看起来能用"。 */
export const WORLD_TASK_SCHEMA = 1;

export const TASK_BAD_TABLE = "TASK.BAD_TABLE";
export const TASK_BAD_TICK = "TASK.BAD_TICK";

export interface WorldTask {
  /** 全局唯一（重复会让"这条 fire 属于谁"说不清）。 */
  readonly id: string;
  /** 每多少 tick 跑一次，整数 ≥ 1。 */
  readonly periodTicks: number;
  /**
   * 相位偏移：命中条件为 `tick % periodTicks === phase`，`0 ≤ phase < periodTicks`（默认 0）。
   * ★ 上界必须硬校验：`phase >= period` 的任务**永远不会触发**，而这个错误
   *   在运行期表现为"这条任务什么都不做" —— 静默，最难查。
   */
  readonly phase?: number;
  /** 每次跑在哪些群系的格子里选点。空数组/省略 = 不选格（纯逻辑任务）。 */
  readonly biomes?: readonly BiomeKind[];
  /** 每次选几个格（0..64）。默认 0。 */
  readonly picksPerRun?: number;
}

export interface WorldTaskTable {
  readonly schema: number;
  readonly tasks: readonly WorldTask[];
}

/** 一次任务执行。 */
export interface TaskFire {
  readonly taskId: string;
  /** 区间 `(上次 tick, 本次 tick]` 内**第一次**命中的 tick。用它做 seed，而不是本次 tick。 */
  readonly tick: number;
  /** 该任务第几次执行（1 起，**单调递增**；跳时间也不复位）。 */
  readonly run: number;
  /** 本次推进里本该发生但因为跳时间而**没发生**的次数（0 = 逐 tick 推进）。 */
  readonly missed: number;
  /** 本次选中的格子下标（升序）。没选格的任务是空数组。 */
  readonly cells: readonly number[];
}

export interface WorldTasksStats {
  readonly tasks: number;
  readonly runs: number;
  readonly missed: number;
  readonly lastTick: number;
}

interface TaskState {
  readonly task: WorldTask;
  runs: number;
  missed: number;
}

/** 字符串 → 32 位整数（FNV-1a）。用于把任务 id 混进 seed。 */
function hashString(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/**
 * 区间 `(from, to]` 内满足 `t % period === phase` 的**第一次**命中与总次数。
 * 返回 `first = -1` 表示一次都没有。
 */
function dueRange(period: number, phase: number, from: number, to: number): { first: number; count: number } {
  if (to <= from) return { first: -1, count: 0 };
  // 大于 from 的最小命中 tick
  const rem = (((phase - (from % period)) % period) + period) % period;
  const first = from + (rem === 0 ? period : rem);
  if (first > to) return { first: -1, count: 0 };
  return { first, count: Math.floor((to - first) / period) + 1 };
}

/**
 * 校验表结构。
 *
 * ★ 每一条都是"静默失败"的入口：
 *   · `periodTicks ≤ 0` → 除零或每 tick 跑；
 *   · `phase ≥ period` → 永不触发；
 *   · 重复 id → 两条任务共用一个 seed 与一个 run 计数；
 *   · `picksPerRun` 超上限 → 一次执行把整张地图选空。
 *   所以这里一律**报错**，不做"合理默认"。
 */
export function validateTaskTable(table: WorldTaskTable): Result<readonly WorldTask[], EngineError> {
  if (table.schema !== WORLD_TASK_SCHEMA) {
    return err({
      code: TASK_BAD_TABLE,
      message: `表结构版本 ${String(table.schema)} 不是 ${WORLD_TASK_SCHEMA}（旧表必须被拒绝，而不是勉强能用）`,
    });
  }
  const seen = new Set<string>();
  const out: WorldTask[] = [];
  for (let i = 0; i < table.tasks.length; i++) {
    const t = table.tasks[i]!;
    if (typeof t.id !== "string" || t.id.length === 0) {
      return err({ code: TASK_BAD_TABLE, message: `第 ${i} 条任务没有 id` });
    }
    if (seen.has(t.id)) {
      return err({ code: TASK_BAD_TABLE, message: `任务 id 重复：${t.id}` });
    }
    seen.add(t.id);
    if (!Number.isInteger(t.periodTicks) || t.periodTicks < 1) {
      return err({
        code: TASK_BAD_TABLE,
        message: `任务 ${t.id} 的 periodTicks 必须是 ≥1 的整数，得到 ${String(t.periodTicks)}`,
      });
    }
    const phase = t.phase ?? 0;
    if (!Number.isInteger(phase) || phase < 0 || phase >= t.periodTicks) {
      return err({
        code: TASK_BAD_TABLE,
        message: `任务 ${t.id} 的 phase 必须落在 [0, ${t.periodTicks})，得到 ${String(phase)} —— 越界会让它永不触发`,
      });
    }
    const picks = t.picksPerRun ?? 0;
    if (!Number.isInteger(picks) || picks < 0 || picks > 64) {
      return err({
        code: TASK_BAD_TABLE,
        message: `任务 ${t.id} 的 picksPerRun 必须是 0..64 的整数，得到 ${String(picks)}`,
      });
    }
    if (t.biomes !== undefined) {
      for (const b of t.biomes) {
        if (!isBiomeKind(b)) {
          return err({ code: TASK_BAD_TABLE, message: `任务 ${t.id} 的群系名未知：${String(b)}` });
        }
      }
    }
    out.push(t);
  }
  return ok(out);
}

/** 表的内容指纹（不含"跑过几次"这类运行期状态 —— 表是可存档的内容，状态不是）。 */
export function taskTableDigest(table: WorldTaskTable): Result<string, EngineError> {
  return fingerprintOf(table);
}

/**
 * 世界任务表运行器。
 *
 * `plan` 可选：没有计划时只做纯逻辑计时（`cells` 恒为空）；
 * 有计划时按任务的 `biomes` 选格。**不给计划却要选格 ⇒ 报错**，
 * 而不是静默返回空数组（那会让"资源没刷出来"看起来像"任务没跑"）。
 */
export class WorldTasks {
  private readonly states: TaskState[];
  private readonly plan: WorldPlan | undefined;
  private _lastTick = 0;
  private _runs = 0;
  private _missed = 0;

  private constructor(states: TaskState[], plan: WorldPlan | undefined) {
    this.states = states;
    this.plan = plan;
  }

  static create(table: WorldTaskTable, plan?: WorldPlan): Result<WorldTasks, EngineError> {
    const valid = validateTaskTable(table);
    if (!valid.ok) return valid;
    const needsPlan = valid.value.some((t) => (t.picksPerRun ?? 0) > 0 && (t.biomes?.length ?? 0) > 0);
    if (needsPlan && plan === undefined) {
      return err({
        code: TASK_BAD_TABLE,
        message: "表里有任务要按群系选格，但没有给 WorldPlan —— 静默返回空数组会让「没刷出来」看起来像「没跑到」",
      });
    }
    return ok(
      new WorldTasks(
        valid.value.map((task) => ({ task, runs: 0, missed: 0 })),
        plan,
      ),
    );
  }

  get lastTick(): number {
    return this._lastTick;
  }

  /**
   * 推进到 `tick`（含），返回本次推进触发的执行。
   *
   * ★ 只能前进：倒退会让同一个 tick 被执行两次（读档回档时的经典坑），必须报错。
   * ★ 顺序：先按 `tick` 升序（区间内各任务的首次命中），再按表内声明顺序 ——
   *   "按 tick 再按声明序"是确定的；只按声明序会让同一 tick 内多任务的先后
   *   依赖表里谁写在前，而这个顺序会进 seed 之外的副作用（日志、事件）。
   */
  advanceTo(tick: number): Result<readonly TaskFire[], EngineError> {
    if (!Number.isInteger(tick)) {
      return err({ code: TASK_BAD_TICK, message: `tick 必须是整数，得到 ${String(tick)}` });
    }
    if (tick < this._lastTick) {
      return err({
        code: TASK_BAD_TICK,
        message: `时间不能倒退：上次 ${this._lastTick}，这次 ${tick}（回档请重建任务表）`,
      });
    }

    const due: { fire: TaskFire; order: number }[] = [];
    for (let i = 0; i < this.states.length; i++) {
      const st = this.states[i]!;
      const period = st.task.periodTicks;
      const phase = st.task.phase ?? 0;
      const { first, count } = dueRange(period, phase, this._lastTick, tick);
      if (first < 0) continue;

      st.runs += 1;
      st.missed += count - 1;
      this._runs += 1;
      this._missed += count - 1;

      due.push({
        order: i,
        fire: {
          taskId: st.task.id,
          tick: first,
          run: st.runs,
          missed: count - 1,
          cells: this.pickCells(st.task, first, st.runs),
        },
      });
    }

    this._lastTick = tick;
    due.sort((a, b) => (a.fire.tick !== b.fire.tick ? a.fire.tick - b.fire.tick : a.order - b.order));
    return ok(due.map((d) => d.fire));
  }

  /**
   * 按群系确定性选格：候选 = 计划里"群系属于 biomes 且可通行"的格子（升序）。
   *
   * ★★ seed 只由 **(任务 id, 首次到期 tick)** 决定，**不含 `run`**。
   *   第一版把 `run` 也混了进去，写变异时才发现两个问题：
   *   ① 它让"同一 tick 的产出"依赖**执行历史** —— 读档后重建实例、推进到同一个 tick，
   *      会得到另一批格子（`run` 从 1 重新数），可重放性当场失效；
   *   ② `firstTick` 严格单调递增，`run` 在它之外不带来任何新信息 ——
   *      删掉 `run` 也无法被任何判据抓住。**一条抓不住对应变异的判据等于没写**，
   *      反过来说：一个无法被区分的设计元素也不该留在关键路径上。
   *   所以 `run` 降级为纯诊断字段（`runCounts()` 用）。
   */
  private pickCells(task: WorldTask, firstTick: number, _run: number): readonly number[] {
    const want = task.picksPerRun ?? 0;
    const biomes = task.biomes ?? [];
    if (want === 0 || biomes.length === 0 || this.plan === undefined) return [];

    const allow = new Set<BiomeKind>(biomes);
    const candidates: number[] = [];
    for (let i = 0; i < this.plan.kinds.length; i++) {
      const k = this.plan.kinds[i]!;
      if (!allow.has(k)) continue;
      if (!isPassable(k)) continue;
      candidates.push(i);
    }
    if (candidates.length === 0) return [];

    const seed = (hashString(task.id) ^ Math.imul(firstTick, 0x9e3779b1)) | 0;
    const rng = new XorShift128(seed);
    rng.shuffle(candidates);
    return candidates.slice(0, Math.min(want, candidates.length)).sort((a, b) => a - b);
  }

  stats(): WorldTasksStats {
    return {
      tasks: this.states.length,
      runs: this._runs,
      missed: this._missed,
      lastTick: this._lastTick,
    };
  }

  /** 每条任务跑了多少次（诊断/编辑器面板用）。 */
  runCounts(): ReadonlyMap<string, number> {
    const out = new Map<string, number>();
    for (const st of this.states) out.set(st.task.id, st.runs);
    return out;
  }
}
