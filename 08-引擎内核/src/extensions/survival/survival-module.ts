/**
 * L4 · 生存驱动（每 tick 一次：掉饱食 → 饿着就掉血 → 可能饿死）
 *
 * 这一层只做"把 `hunger.ts` 的数字按 tick 推进起来"。
 * 它**不决定**饿死之后世界怎么变（见文件头 ③）。
 *
 * ★★ 三个决定：
 *
 * ① **按 tick 计，不按 dt 计**。`dt` 会让"同种子同世界"在掉帧时失效：
 *    卡一下饿得慢一点、快进一下饿得快一点，回放就对不上。
 *    这和 AI 的等待、无敌帧是同一个理由（同一套取舍在本项目已出现四次）。
 *
 * ② **`tick > 0` 才开始扣**。tick 0 是"世界刚建好"，不是一个时间单位的末尾；
 *    在 tick 0 扣第一点会让"刚生出来就少了一点"，而且让"跑 N tick 掉多少"
 *    变成 N+1 —— 判据里最容易写错的那种 off-by-one。
 *
 * ③ **饿死只回调、不销毁节点**。血量归零之后"消失 / 变尸体 / 游戏结束"
 *    是玩法决定；混进来的后果是玩家一饿死，节点连同背包一起消失，
 *    连"我为什么死了"都来不及看。`combat-module` 销毁的是**击杀**，
 *    和"饿死"不是同一件事，不该共用一条路径。
 */

import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { Services } from "../../core/tokens.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { HEALTH_TYPE, damage, isDead, type Health } from "../combat/health.ts";
import { HUNGER_TYPE, isStarving, type Hunger } from "./hunger.ts";

export const SURVIVAL_BAD_MODULE = "SURVIVAL.BAD_MODULE";

export interface SurvivalOptions {
  readonly id?: string;
  /** 每多少 tick 掉 1 点饱食（默认 30）。必须是正整数。 */
  readonly decayEveryTicks?: number;
  /** 饿着的时候每多少 tick 掉一次血（默认 30）。必须是正整数。 */
  readonly starveEveryTicks?: number;
  /** 每次掉多少血（默认 1）。必须是正整数。 */
  readonly starveDamage?: number;
  /** 饿着掉了一次血（`nodeId`, `tick`）。 */
  readonly onStarve?: (nodeId: number, tick: number) => void;
  /** 这次掉血把它**饿死了**（`nodeId`, `tick`）。见文件头 ③：不销毁节点。 */
  readonly onStarveDeath?: (nodeId: number, tick: number) => void;
}

export interface SurvivalStats {
  /** 带 `game.hunger` 的节点数。 */
  readonly tracked: number;
  /** 当前**饿着**的节点数（`value === 0`）。每 tick 重算，不是累计值。 */
  readonly starving: number;
  /** 累计：饿着掉血的次数（**次数**不是点数，方便算"饿了多久"）。 */
  readonly starveTicks: number;
  /** 累计：饿死的节点数。 */
  readonly starveDeaths: number;
  /** 最近一次失败的错误码（正常时为空串）。 */
  readonly lastError: string;
}

export interface SurvivalHandle extends IModule {
  readonly stats: SurvivalStats;
  /**
   * 每 tick 推进一次（宿主在 `scheduler.onStep` 里调）。
   * ★ 与 `tick()` **同一个实现**：两个入口只是"谁来编号"不同 ——
   *   `update` 由帧循环给 tick，`tick` 由判据给 tick（判据不该起整个帧循环）。
   *   分成两份实现的那天，就是"判据里对、真跑起来不对"的那天。
   */
  update(tick: number, dt?: number): void;
  /** 手动推进一次（不算 tick）。见 `update`。 */
  tick(tick: number): void;
}

function positive(name: string, v: number | undefined, dflt: number): number {
  const n = v ?? dflt;
  if (!Number.isInteger(n) || n <= 0) {
    throw new RangeError(`${name} 必须是正整数，收到 ${String(v)}`);
  }
  return n;
}

export function createSurvivalModule(options: SurvivalOptions = {}): SurvivalHandle {
  const decayEvery = positive("decayEveryTicks", options.decayEveryTicks, 30);
  const starveEvery = positive("starveEveryTicks", options.starveEveryTicks, 30);
  const starveDmg = positive("starveDamage", options.starveDamage, 1);

  let scene: Scene | null = null;
  let tracked = 0;
  let starving = 0;
  let starveTicks = 0;
  let starveDeaths = 0;
  let lastError = "";

  const handle: SurvivalHandle = {
    id: options.id ?? "game.survival",
    deps: [],

    get stats(): SurvivalStats {
      return { tracked, starving, starveTicks, starveDeaths, lastError };
    },

    init(ctx: ModuleContext): Result<void, EngineError> {
      const got = ctx.services.get(Services.Scene);
      if (got === undefined) {
        return err(engineError(SURVIVAL_BAD_MODULE, "生存模块需要一个 Scene（先注册 Services.Scene）"));
      }
      scene = got;
      return ok(undefined);
    },

    update(tick: number): void {
      handle.tick(tick);
    },

    stop(): void {
      // 不清统计：这个模块被 stop 之后再 start 时，"已经饿了几次"仍然是事实
    },

    describe(): string {
      return `生存：追踪 ${String(tracked)} / 饿着 ${String(starving)} / 饿死 ${String(starveDeaths)}`;
    },

    tick(tick: number): void {
      const s = scene;
      if (s === null) return;

      // 见文件头 ① ③：按 id 升序，谁先饿死是确定的
      const list = [...s.componentsOf<Hunger>(HUNGER_TYPE)].sort(
        (a, b) => (a.node?.id ?? -1) - (b.node?.id ?? -1),
      );
      tracked = list.length;
      let stillStarving = 0;

      for (const h of list) {
        const node = h.node;
        if (node === null || !node.activeInHierarchy) continue;

        // ---- 衰减（见文件头 ②：tick 0 不扣）
        if (tick > 0 && tick % decayEvery === 0 && h.value > 0) {
          h.value--;
        }
        if (!isStarving(h)) continue;
        stillStarving++;

        // ---- 饿着掉血
        if (tick <= 0 || tick % starveEvery !== 0) continue;
        const health = node.get<Health>(HEALTH_TYPE);
        // 没有血量组件的实体只会"饿着"而不会死（例：一口箱子）
        if (health === undefined || isDead(health)) continue;

        const r = damage(s, node.id, starveDmg, { tick });
        if (!r.ok) {
          // 无敌帧之类：**不算一次饿伤**，也不该刷屏
          lastError = r.error.code;
          continue;
        }
        starveTicks++;
        options.onStarve?.(node.id, tick);
        if (r.value.dead) {
          starveDeaths++;
          // 见文件头 ③：只回调，不销毁
          options.onStarveDeath?.(node.id, tick);
        }
      }

      starving = stillStarving;
    },
  };

  return handle;
}
