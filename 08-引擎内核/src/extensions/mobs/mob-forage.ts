/**
 * L4 · 捡与吃（**把树的两条新分支接到意图执行器上**，批166）
 *
 * 树只产出决定（`forage` / `eat`），决定本身不改世界。这一层是那条执行线：
 * 取决定 → 拼意图 → `executeIntent` → 计数。位移与攻击走的是另外两个子模块
 * （`ai/move` 与 `combat-module`），它们各自有自己的每拍驱动；捡与吃没有 ——
 * 因为它们不是"持续态"，而是**一次尝试**（同 `actions/intent.ts` 的分类）。
 *
 * ★★ 四个决定：
 *
 * ① **不新建模块，做一个纯函数 + 一趟遍历**。原因不是省事：新模块要自己维护
 *    一份"哪些 id 是我的生物"的名单，而那份名单已经有两份了（`mob-world.ids`、
 *    场景里挂 `mover` 的那批）。第三份名单的第一个 bug 就是"死掉的怪还在捡东西"。
 *
 * ② **只做决定里写明的动作，不替树兜底**。`decide()` 返回 `hunt` / `wander` 时
 *    这一层**什么都不做** —— 那两条路各有自己的执行者。在这里加一句"没有可拾的就
 *    随便捡一下"会让树的语义变成两份。
 *
 * ③ **拾取半径 = 一个身位（默认 1.2 世界单位），不是"看得见的范围"**。
 *    看得见（`forageRadius`，默认 6）是**决策**用的，"捡得到"是**执行**用的。
 *    两者合成一个数的话，拾荒者会隔着半张地图把草吸进包里 —— 而计数全对。
 *
 * ④ **失败要分档，不能合成一个数**（与 `lootNoRecipient` / `lootLost` 同一条纪律）：
 *    - `retried`：背包满（`INVENTORY.FULL`）—— 会自己好（吃掉一个就有位置了）；
 *    - `failed` ：其余（目标没了、没有背包、没有食物表）—— 要人去看配置。
 *    混在一起的话，"它一直在捡但捡不起来"与"它根本没去捡"看起来一样。
 */

import type { Scene } from "../../core/scene/scene.ts";
import type { FoodTable } from "../survival/food.ts";
import { INVENTORY_FULL } from "../inventory/inventory.ts";
import { executeIntent, type ExecutedIntent } from "../actions/executor.ts";
import type { ActionIntent } from "../actions/intent.ts";
import type { Decision } from "./mob-facts.ts";

/** 执行一趟的产物（喂给 `MobWorldStats`）。 */
export interface ForageReport {
  /**
   * 拾取成功的**次数**（一堆算一次，与 `ActionOutcome.applied` 同一口径）。
   *
   * ★ 不是"件数"：`pickupNearby` 一次可以拿走一整堆，而它只报告"拿了几堆"。
   *   要件数得读背包（`countItem`），把两件事混进一个字段，数字看起来一样而含义不同。
   */
  readonly foraged: number;
  /** 吃了几次（次数，不是点数和）。 */
  readonly ate: number;
  /** 背包满导致的"下次再来"次数。 */
  readonly retried: number;
  /** 其它失败次数（目标没了 / 配置缺）。 */
  readonly failed: number;
  /** 最近一次失败的错误码（正常时为空串）。 */
  readonly lastError: string;
}

export const EMPTY_FORAGE: ForageReport = { foraged: 0, ate: 0, retried: 0, failed: 0, lastError: "" };

/** 默认拾取半径（见文件头 ③）。 */
export const DEFAULT_FORAGE_PICKUP_RADIUS = 1.2;

/**
 * 决定 → 意图（**纯函数**：判据不必搭世界就能验「哪些决定会变成动作」）。
 *
 * @returns `null` = 这条决定不该由这两条分支执行（追 / 漫游 / `eat` 缺 `item`）。
 */
export function forageIntentOf(d: Decision, actor: number, tick: number, radius: number): ActionIntent | null {
  if (d.kind === "forage") {
    return { kind: "pickup", actor, tick, origin: "ai", radius };
  }
  if (d.kind === "eat") {
    const item = d.item;
    // 没有"吃哪一个"就发不出 `use`：`actionProblem` 会把它判成 BAD_SHAPE，
    // 而那会被计进 `failed` —— 一条配置错误伪装成"它捡不到东西"
    if (item === undefined || item === "") return null;
    return { kind: "use", actor, tick, origin: "ai", item };
  }
  return null;
}

export interface ForagePassOptions {
  readonly scene: Scene;
  /** 要跑哪几只（`MobWorld.ids`）。 */
  readonly ids: readonly number[];
  /** 决定从哪来（`brain.decide`，只取 `forage` / `eat` 两种）。 */
  readonly decide: (agentId: number, tick: number) => Decision | null;
  readonly tick: number;
  /** 拾取半径（见文件头 ③）。 */
  readonly radius?: number;
  /** 食物表（`eat` 必需；不给 ⇒ 吃了也报 NO_FOOD_TABLE，计入 `failed`）。 */
  readonly food?: FoodTable;
}

/**
 * 跑一趟：对每只生物取决定，若是捡/吃就执行一次。
 *
 * ★ 顺序按 `ids` 原样（`mob-world` 给的是升序）—— 谁先捡到那丛草是确定的。
 */
export function runForagePass(o: ForagePassOptions): ForageReport {
  const radius = o.radius ?? DEFAULT_FORAGE_PICKUP_RADIUS;
  let foraged = 0;
  let ate = 0;
  let retried = 0;
  let failed = 0;
  let lastError = "";
  for (const id of o.ids) {
    const d = o.decide(id, o.tick);
    if (d === null) continue;
    const it = forageIntentOf(d, id, o.tick, radius);
    if (it === null) continue;
    const out: ExecutedIntent = executeIntent(
      {
        scene: o.scene,
        ...(o.food === undefined ? {} : { food: o.food }),
      },
      it,
    );
    if (it.kind === "use") {
      if (out.ok) ate++;
      else {
        failed++;
        lastError = out.code;
      }
      continue;
    }
    // pickup：`ok + applied > 0` 才算真捡到了（`applied === 0` 是"附近没东西"，见 executor ④）
    if (out.ok && out.applied > 0) foraged += out.applied;
    else if (out.verdict === "retry" || out.code === INVENTORY_FULL) retried++;
    else {
      failed++;
      lastError = out.ok ? "FORAGE.NOTHING" : out.code;
    }
  }
  return { foraged, ate, retried, failed, lastError };
}
