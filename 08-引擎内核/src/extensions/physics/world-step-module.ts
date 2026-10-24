/**
 * L4 · 世界步进模块：`scene.step` + `physics.resolve`
 *
 * ★ 为什么这两件事必须在**同一个回调**里、顺序写死：
 *   分成两个模块各自订阅 `onStep` 会依赖"注册顺序"这种隐式约定 ——
 *   物理先于移动解算的后果是"穿墙一帧"（改一次模块列表就复现，而且看不出原因）。
 *
 * ★ 为什么放在 `extensions/` 而不是某个宿主的文件里：
 *   浏览器演示页与编辑器页都只想要"世界往前走一步"这一件事。
 *   留在宿主里时，第二个宿主只有两个选择：抄一遍（于是顺序约定出现两份），
 *   或者干脆不装（于是编辑器里物理不生效，而人只会觉得"编辑器里手感不对"）。
 *   判据：**第二个宿主真的需要它** —— 这就是下沉的理由，不是"代码看起来像库"。
 */

import type { FixedStepScheduler } from "../../core/scheduler/scheduler.ts";
import { Services } from "../../core/tokens.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { SpatialHashWorld } from "./physics.ts";

export interface WorldModuleHooks {
  /** 每个 tick 结束时（在 `scene.step` 与物理解算之后）。 */
  readonly onTick?: (tick: number) => void;
  /** 同一时刻的完整回调（宿主用来驱动脚本/控制器/任务）。 */
  readonly onStep?: (tick: number, dt: number) => void;
}

/**
 * 世界步进模块。
 *
 * 顺序：`scene.step`（组件更新）→ `physics.resolve`（解算重叠）→ 宿主回调。
 * 脚本/控制器放在最后，是因为它们要读到**本 tick 的确定状态**；
 * 放在 `scene.step` 之前的话，脚本看到的位置会晚一个 tick，操作手感会"黏"。
 */
export function createWorldModule(physics: SpatialHashWorld, hooks: WorldModuleHooks = {}): IModule {
  let off: (() => void) | null = null;
  return {
    id: "game.world",
    init(ctx: ModuleContext): void {
      const scene = ctx.services.require(Services.Scene);
      const sched = ctx.services.require<FixedStepScheduler>(Services.Scheduler);
      off = sched.onStep((tick, dt) => {
        scene.step(tick, dt);
        physics.resolve();
        hooks.onStep?.(tick, dt);
        hooks.onTick?.(tick);
      });
    },
    stop(): void {
      off?.();
      off = null;
    },
    describe(): string {
      return `世界：${physics.stats().bodies} 个物理体`;
    },
  };
}
