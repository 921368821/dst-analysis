/**
 * L4 · 顿帧（hitstop）：「打中了」的那一瞬间，把世界冻住几个逻辑步
 *
 * 批69 交付了闪色/挤压/伤害数字 —— 那些是**被打的那个**的表现。
 * 顿帧是另一种东西：它让**整个世界**停一下，于是"这一下很重"不用文字也说得出。
 * （没有它的时候，命中与未命中的画面差别只有血条短了一截。）
 *
 * ★★ 四个决定：
 *
 * ① **时长按逻辑步指定，由调度器按真实时间消耗**（帧率无关）。
 *    本文件只传步数，不碰毫秒：按毫秒指定的话，144Hz 屏上顿帧会短一半
 *    （与 `feedback.ts` 文件头 ★ 同一条理由，也与 `cooldownTicks` 同口径）。
 *    换算在 `FixedStepScheduler.freeze()` 里，全引擎只有一处。
 *
 * ② **策略是函数，不是配置项**。`(info) => ticks` 而不是 `{ ticks, onlyKills }`：
 *    "什么命中值得冻"是玩法判断（玩家打中冻、击杀多冻、怪打玩家不冻——
 *    群战里每个怪都冻会让画面一帧一停，而**冻结本身不报错**，只是手感变怪）。
 *    枚举永远覆盖不了这类判断，而枚举不到的字段会被宿主用 if 拼出来。
 *    返回值 0 = 不冻；非法值（负数/小数/NaN）**拒绝并入账**，不夹取。
 *
 * ③ **不累加，取最长**（在调度器里做）。连击时冻结越来越久的话，
 *    "冻多久"变成取决于历史的东西 —— 回放对不上，且玩家说不清自己在等什么。
 *
 * ④ **触发点只有一处**：宿主的 `onHit`。玩家手动打与生物按 decide 打
 *    都必须经过它（否则会出现"我打人有顿帧、怪打我没有"），而两边代码都对。
 *    本模块不订阅场景事件自己找命中 —— 那会和 `combat-module` 的 `onHit`
 *    长出两条判定路径。
 *
 * ★ 与 `tween/`（批72）的关系：顿帧**不是**补间。补间是"一个值随时间变化"，
 *   顿帧是"时间本身停一下"。硬把顿帧写成 timeScale 补间会得到慢动作而不是冻结
 *   （调度器的 `timeScale` setter 明确拒绝 0：世界只是变慢，tick 照走）。
 *   它被归在 P0-2 第二批，是因为它是**第一个时间消费者** —— 它定义了
 *   "跨帧状态位该挂在谁身上"这个问题的答案：挂在调度器上，不挂在组件上
 *   （冻结是全局的，没有任何一个实体拥有它）。
 */

import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { FixedStepScheduler } from "../../core/scheduler/scheduler.ts";
import { Services } from "../../core/tokens.ts";
import type { HitInfo } from "./combat-module.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 模块没拿到调度器（`Services.Scheduler` 没注册 —— 宿主没建 GameApp？）。 */
export const HITSTOP_BAD_MODULE = "HITSTOP.BAD_MODULE";
/** 策略返回了非法步数（负数 / 小数 / NaN / Infinity）。 */
export const HITSTOP_BAD_TICKS = "HITSTOP.BAD_TICKS";

/**
 * 顿帧策略：这一次命中冻几个逻辑步。
 *
 * ★ 0 = 不冻（"这次命中不需要顿帧"是正常答案，不是错误）。
 * ★ 必须是正整数；非法值会被拒绝并计入 `rejected`，**不会**被夹取到 0 或 1
 *   —— 静默夹取会让"配了 3.5 步"看起来像没配。
 */
export type HitstopPolicy = (info: HitInfo) => number;

export interface HitstopReport {
  /** 这一次请求的步数（0 = 策略说不冻）。 */
  readonly ticks: number;
  /** 请求之后调度器里的剩余（可能大于 `ticks`：取最长，见文件头 ③）。 */
  readonly remaining: number;
  /** `true` = 本来就在冻，这一次只是把剩余时间**延长**了。 */
  readonly extended: boolean;
}

export interface HitstopStats {
  /** 累计：真的冻了（含"只是延长"的那些）。 */
  readonly triggers: number;
  /** 累计：触发时本来就在冻（延长）。 */
  readonly extended: number;
  /** 累计：策略返回 0，主动不冻。 */
  readonly skipped: number;
  /** 累计：策略返回非法值 —— **要人看**（通常是配表写错）。 */
  readonly rejected: number;
  /** 最近一次**成功**请求的步数（0 = 最近一次是跳过/拒绝）。 */
  readonly lastTicks: number;
  /** 调度器当前是否在冻（透传，方便宿主一处读齐）。 */
  readonly frozen: boolean;
  /** 调度器剩余冻结步数（透传）。 */
  readonly freezeTicks: number;
}

export interface HitstopOptions {
  readonly policy: HitstopPolicy;
  readonly id?: string;
}

export interface HitstopHandle extends IModule {
  /**
   * 请求一次顿帧。在 `onHit` 里**同步**调用 —— 调度器会在下一步开始生效
   * （触发那一步照常跑完：伤害数字与闪色都在那一步里应用，冻住才留得住画面）。
   */
  trigger(info: HitInfo): Result<HitstopReport, EngineError>;
  readonly stats: HitstopStats;
}

export function createHitstopModule(opts: HitstopOptions): HitstopHandle {
  let sched: FixedStepScheduler | null = null;
  let triggers = 0;
  let extended = 0;
  let skipped = 0;
  let rejected = 0;
  let lastTicks = 0;

  const handle: HitstopHandle = {
    id: opts.id ?? "combat.hitstop",
    deps: [],
    get stats(): HitstopStats {
      return {
        triggers,
        extended,
        skipped,
        rejected,
        lastTicks,
        frozen: sched === null ? false : sched.frozen,
        freezeTicks: sched === null ? 0 : sched.freezeTicks,
      };
    },
    init(ctx: ModuleContext): Result<void, EngineError> {
      const got = ctx.services.get(Services.Scheduler);
      if (got === undefined) {
        return err(engineError(HITSTOP_BAD_MODULE, "顿帧模块需要一个调度器（先提供 Services.Scheduler）"));
      }
      sched = got;
      return ok(undefined);
    },
    stop(): void {
      // 不清统计：与其它模块同一条纪律，"已经顿过几次"在 stop 之后仍是事实
    },
    describe(): string {
      return `顿帧：触发 ${String(triggers)} / 延长 ${String(extended)} / 跳过 ${String(skipped)} / 拒绝 ${String(rejected)}`;
    },
    trigger(info: HitInfo): Result<HitstopReport, EngineError> {
      const s = sched;
      if (s === null) {
        // 接线 bug，不是玩法问题：单独一条错误码，不混进 rejected
        return err(engineError(HITSTOP_BAD_MODULE, "顿帧模块还没 init（拿不到调度器）就收到了命中"));
      }
      const ticks = opts.policy(info);
      if (!Number.isInteger(ticks) || ticks < 0) {
        rejected++;
        return err(
          engineError(
            HITSTOP_BAD_TICKS,
            `顿帧策略返回了 ${String(ticks)}（必须是 ≥0 的整数；0 = 不冻）`,
          ),
        );
      }
      if (ticks === 0) {
        skipped++;
        lastTicks = 0;
        return ok({ ticks: 0, remaining: s.freezeTicks, extended: false });
      }
      const wasFrozen = s.frozen;
      // 调度器负责取最长与按真实时间消耗；这里只负责校验与记账
      s.freeze(ticks);
      triggers++;
      if (wasFrozen) extended++;
      lastTicks = ticks;
      return ok({ ticks, remaining: s.freezeTicks, extended: wasFrozen });
    },
  };
  return handle;
}
