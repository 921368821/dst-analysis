/**
 * L4 · 食物表与进食（阶段 3：把"打猎的产物"接回去）
 *
 * 只做一件有后果的事：**吃掉背包里一个东西，换回饱食度（以及可能的回血）**。
 *
 * ★★ 三个决定：
 *
 * ① **先判"能不能吃"，再扣物品**。顺序反了的表现是"吃饱了还咬一口，肉没了、
 *    饱食没涨" —— 而玩家看到的是"这游戏吃东西会吞东西"。这条在批56 的
 *    `dropIntoWorld` 上踩过一次（先建节点、再发现没空间）。
 *
 * ② **未知 kind 报错，不静默跳过**。静默跳过的代价是"配表漏了一项 ⇒
 *    这个东西一辈子不能吃"，而它在背包里长得和能吃的东西一样（都是 `kind` 字符串）。
 *
 * ③ **死人不能吃**（`FOOD.DEAD`）。这条要显式判：`heal()` 对尸体是报错的，
 *    若不提前拦，玩家会在"饿死之后还能给自己回血"这条路上把尸体救活一半。
 *
 * ★ 营养值/回血量都是**整数**，理由同 `combat/health.ts` 与 `survival/hunger.ts`：
 *   小数会让"吃几个才饱"取决于累加次序，而"饱了没有"决定玩家会不会死。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { HEALTH_TYPE, heal, isDead, type Health } from "../combat/health.ts";
import { countItem, takeItem } from "../inventory/inventory.ts";
import { HUNGER_NO_COMPONENT, HUNGER_NO_OWNER, HUNGER_TYPE, feed, type Hunger } from "./hunger.ts";

/** 食物表本身不合法（不是对象 / 营养值不是正整数 / 空表）。 */
export const FOOD_BAD_TABLE = "FOOD.BAD_TABLE";
/** 这个东西不在食物表里（见文件头 ②）。 */
export const FOOD_UNKNOWN_KIND = "FOOD.UNKNOWN_KIND";
/** 身上一个都没有。 */
export const FOOD_NOT_HELD = "FOOD.NOT_HELD";
/** 已经吃饱了（见文件头 ①）。 */
export const FOOD_FULL = "FOOD.FULL";
/** 死人不能吃（见文件头 ③）。 */
export const FOOD_DEAD = "FOOD.DEAD";

export interface FoodEntry {
  /** 一份能回多少饱食度（正整数）。 */
  readonly nutrition: number;
  /** 顺带回多少血（正整数；省略 = 不回血）。 */
  readonly health?: number;
}

/** `kind → FoodEntry`。 */
export type FoodTable = Readonly<Record<string, FoodEntry>>;

/**
 * 把"配表原文"变成可信的 `FoodTable`。
 *
 * ★ 每一项非法值都要**点名到具体字段**（`detail.field`）：报"食物表不合法"
 *   让人只能一行行看；报"meat.health 必须是正整数，收到 -1"能直接改。
 */
export function normalizeFoodTable(raw: unknown): Result<FoodTable, EngineError> {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return err(engineError(FOOD_BAD_TABLE, "食物表必须是对象（kind → {nutrition, health?}）"));
  }
  const src = raw as Record<string, unknown>;
  const kinds = Object.keys(src).sort();
  if (kinds.length === 0) {
    // 空表几乎一定是"忘了填"：它能正常工作，只是世界里任何东西都不能吃。
    return err(engineError(FOOD_BAD_TABLE, "食物表是空的 —— 多半是忘了填，而不是真的想让所有东西都不能吃"));
  }
  const out: Record<string, FoodEntry> = {};
  for (const kind of kinds) {
    if (kind === "") {
      return err(engineError(FOOD_BAD_TABLE, "食物表里有一个空字符串 kind"));
    }
    const e = src[kind];
    if (typeof e !== "object" || e === null || Array.isArray(e)) {
      return err(engineError(FOOD_BAD_TABLE, `食物表项 ${kind} 必须是对象`, { field: kind, kind }));
    }
    const n = (e as { nutrition?: unknown }).nutrition;
    if (!Number.isInteger(n) || (n as number) <= 0) {
      return err(
        engineError(FOOD_BAD_TABLE, `食物表项 ${kind}.nutrition 必须是正整数，收到 ${String(n)}`, {
          field: `${kind}.nutrition`,
          kind,
        }),
      );
    }
    const hp = (e as { health?: unknown }).health;
    if (hp !== undefined && (!Number.isInteger(hp) || (hp as number) <= 0)) {
      return err(
        engineError(FOOD_BAD_TABLE, `食物表项 ${kind}.health 必须是正整数，收到 ${String(hp)}（省略 = 不回血）`, {
          field: `${kind}.health`,
          kind,
        }),
      );
    }
    out[kind] =
      hp === undefined
        ? { nutrition: n as number }
        : { nutrition: n as number, health: hp as number };
  }
  return ok(out);
}

export interface EatReport {
  readonly nodeId: number;
  readonly kind: string;
  readonly nutrition: number;
  readonly hungerBefore: number;
  readonly hungerAfter: number;
  /** 顺带回的血（0 = 这项不回血，或者血已经满了）。 */
  readonly healed: number;
}

/**
 * 吃掉一个 `kind`。
 *
 * 校验顺序（见文件头 ①）：表 → 节点 → 饱食组件 → 是否已饱 → 是否已死 → 背包。
 * 前五步任何一步失败都**一个物品都不扣**。
 *
 * ★ `table` 传**已归一化**的表（`normalizeFoodTable` 的产物）。这一层不重复校验：
 *   两处各校验一遍的表，迟早会有一处忘了改。
 */
export function eat(
  scene: Scene,
  ownerId: number,
  kind: string,
  table: FoodTable,
): Result<EatReport, EngineError> {
  const entry = table[kind];
  if (entry === undefined) {
    return err(
      engineError(FOOD_UNKNOWN_KIND, `"${kind}" 不在食物表里（能吃的只有：${Object.keys(table).sort().join(" / ")}）`),
    );
  }
  const node = scene.find(ownerId);
  if (node === undefined || node === null) {
    return err(engineError(HUNGER_NO_OWNER, `节点 ${String(ownerId)} 不在场景里`));
  }
  const h = node.get<Hunger>(HUNGER_TYPE);
  if (h === undefined) {
    return err(engineError(HUNGER_NO_COMPONENT, `节点 ${String(ownerId)} 没有 ${HUNGER_TYPE}`));
  }
  const health = node.get<Health>(HEALTH_TYPE);
  if (health !== undefined && isDead(health)) {
    // 见文件头 ③。★ 这一条放在"是否已饱"**之前**：尸体若刚好也是饱的，
    //   报 `FOOD_FULL` 会把人引去看饱食度，而真正的原因是"它已经死了"。
    return err(engineError(FOOD_DEAD, `节点 ${String(ownerId)} 已经死了 —— 尸体不会吃东西`));
  }
  if (h.value >= h.max) {
    // 见文件头 ①：这一步必须在扣物品**之前**
    return err(
      engineError(FOOD_FULL, `已经吃饱了（${String(h.value)}/${String(h.max)}）—— 不该在这时候消耗一个「${kind}」`),
    );
  }
  // 最后才动背包：上面任何一条失败都不该扣东西
  if (countItem(scene, ownerId, kind) < 1) {
    return err(engineError(FOOD_NOT_HELD, `身上没有「${kind}」（背包里有：${Object.keys(table).sort().join(" / ")}）`));
  }
  const taken = takeItem(scene, ownerId, kind, 1);
  if (!taken.ok) return taken as Result<EatReport, EngineError>;

  const fed = feed(scene, ownerId, entry.nutrition);
  if (!fed.ok) {
    // 理论上到不了这里（上面已经判过组件与上限）。留着是为了"万一"时**不静默**：
    // 返回错误比"物品扣了、饱食没涨"好 —— 至少日志里能看见。
    return fed as Result<EatReport, EngineError>;
  }
  let healed = 0;
  if (entry.health !== undefined && health !== undefined) {
    const r = heal(scene, ownerId, entry.health);
    // 回血失败**不回滚**（东西已经吃了）：如实报 healed=0，让 HUD 显示"这口没回血"
    if (r.ok) healed = r.value;
  }
  return ok({
    nodeId: ownerId,
    kind,
    nutrition: entry.nutrition,
    hungerBefore: fed.value.before,
    hungerAfter: fed.value.after,
    healed,
  });
}
