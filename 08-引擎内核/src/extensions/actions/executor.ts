/**
 * L3 · 意图执行器（**唯一的一处"把请求变成世界变化"**）
 *
 * 玩家按空格、AI 锁目标、将来的脚本与回放 —— 都从这里进去。这个文件做的事只有三件：
 * ① 形状校验（`actionProblem`，不碰世界）；② 按 kind 调到对应的现有实现；
 * ③ 把 `Result<_, EngineError>` 归一成三态（`ActionOutcome`）。
 *
 * ★★ 四个决定：
 *
 * ① **不重写错误文案、不动执行顺序**。真正干活的是 `attack()` / `pickupNearby()` /
 *    `eat()` —— 它们各自的校验顺序是花了批次定下来的（"所有校验在状态变更之前"
 *    "尸体不会吃东西"）。这里再判一遍就是把那条纪律复制成两份，迟早有一份忘改。
 *    所以本文件**只做分类，不做判断**。
 *
 * ② **失败是常态，不是异常**：返回 `ActionOutcome` 而不是 `Result<_, EngineError>`。
 *    每拍每只怪都可能"够不着"，那是正常现象；用 `Result` 的 `err` 来表达它，
 *    会让调用方把正常分支写成异常分支，而真正需要人看的配置错误混在同一堆里。
 *
 * ③ **一个坏意图不会打断整局**：形状错 ⇒ 就地返回 `fatal`，绝不抛。
 *    宿主每拍可能收到几十个意图，其中一个畸形不该让世界停下 —— 它只该被数出来。
 *
 * ④ **`applied === 0` 不是失败**（见 `ActionOutcome.applied`）：`pickup` 在空地上
 *    按一下是 `ok: true, applied: 0`，但判定是 `fatal`（这附近没东西，换地方）。
 *    "世界接受了吗"与"下一步该干什么"是两个问题，答在两个字段里。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { engineError, type EngineError } from "../../foundation/result.ts";
import { attack, type AttackOutcome } from "../combat/attack.ts";
import type { Factions } from "../combat/faction.ts";
import { pickupNearby, type PickupResult } from "../inventory/pickup.ts";
import { eat, type EatReport, type FoodTable } from "../survival/food.ts";
import {
  INTENT_BAD_SHAPE,
  INTENT_OK,
  actionProblem,
  verdictOf,
  type ActionIntent,
  type ActionOutcome,
} from "./intent.ts";

/** 发起者不在场景里。 */
export const INTENT_NO_ACTOR = "INTENT.NO_ACTOR";
/** `pickup` 既没带半径、执行器也没配默认值。 */
export const INTENT_NO_RADIUS = "INTENT.NO_RADIUS";
/** 执行器没配食物表，`use` 用不了。 */
export const INTENT_NO_FOOD_TABLE = "INTENT.NO_FOOD_TABLE";

/**
 * 执行意图需要的世界侧参数（都是"环境"，不是"这次请求"）。
 *
 * ★ `friendlyFire` / `factions` 与 `attack()` 同名同义 —— 这里不新增语义，
 *   只做透传。想改友伤规则就改 `attack()`，两条路（玩家/AI）同时改，不可能只改一半。
 */
export interface IntentWorld {
  readonly scene: Scene;
  /** 阵营关系表（不给 = 不检查友伤，同 `attack()`）。 */
  readonly factions?: Factions;
  /** 显式允许友伤（默认 false）。 */
  readonly friendlyFire?: boolean;
  /** `pickup` 的默认半径（世界单位）。 */
  readonly pickupRadius?: number;
  /** 拾走一格之后交还名额（`task-module.releaseCell`），与 `pickupNearby` 同一个回调。 */
  readonly onRelease?: (cell: number) => boolean;
  /** 食物表（`use` 必需；不给则该意图判 `fatal`）。 */
  readonly food?: FoodTable;
}

/**
 * 带**原始报告**的结果。
 *
 * ★ 报告留在执行器这一层、不放进 `intent.ts`：那个文件是纯类型 + 纯函数，
 *   一旦它 import `AttackOutcome`，`actions/intent` 就与 `combat/attack` 绑死，
 *   而"意图"这个概念本该与"用什么方式实现攻击"无关。
 */
export interface ExecutedIntent extends ActionOutcome {
  /** `attack` 成功时的原始报告（表现层要 before/after/overkill/dead）。 */
  readonly hit?: AttackOutcome;
  /** `pickup` 的原结果（要读 remaining / inRange）。 */
  readonly picked?: PickupResult;
  /** `use` 的原结果（要读 hungerBefore / healed）。 */
  readonly ate?: EatReport;
}

function fail(it: ActionIntent, e: EngineError): ExecutedIntent {
  return {
    intent: it,
    ok: false,
    verdict: verdictOf(e.code),
    code: e.code,
    message: e.message,
    applied: 0,
  };
}

/**
 * 执行一条意图。
 *
 * ★ 签名里没有 `Result`：任何失败（含形状错）都从 `outcome.code` 读得出来，
 *   调用方不需要先 `if (!r.ok)` 再解一层 —— 那一层分支在宿主里出现几十次，
 *   每次都要决定"抛还是忽略"，而答案永远是"记下来继续跑"。
 */
export function executeIntent(w: IntentWorld, it: ActionIntent): ExecutedIntent {
  const bad = actionProblem(it);
  if (bad !== null) return fail(it, bad);

  switch (it.kind) {
    case "attack": {
      // `actionProblem` 已保证 target 存在且合法。
      const target = it.target ?? -1;
      const r = attack(w.scene, it.actor, target, {
        tick: it.tick,
        ...(w.factions === undefined ? {} : { factions: w.factions }),
        ...(w.friendlyFire === undefined ? {} : { friendlyFire: w.friendlyFire }),
      });
      if (!r.ok) return fail(it, r.error);
      const out = r.value;
      return {
        intent: it,
        ok: true,
        verdict: "ok",
        code: INTENT_OK,
        message: "",
        applied: out.report.applied,
        hit: out,
      };
    }

    case "pickup": {
      const node = w.scene.find(it.actor);
      if (node === undefined || node === null) {
        return fail(it, engineError(INTENT_NO_ACTOR, `发起者 ${String(it.actor)} 不在场景里`));
      }
      const radius = it.radius ?? w.pickupRadius;
      if (radius === undefined) {
        return fail(
          it,
          engineError(INTENT_NO_RADIUS, "pickup 没带半径，执行器也没有默认半径 —— 不知道该捡多大范围"),
        );
      }
      const p = node.localPosition;
      const r = pickupNearby(w.scene, p.x, p.y, radius, it.actor, {
        ...(w.onRelease === undefined ? {} : { onRelease: w.onRelease }),
      });
      if (!r.ok) return fail(it, r.error);
      const res = r.value;
      if (res.picked.length > 0) {
        return {
          intent: it,
          ok: true,
          // 拿了一部分但停下了（背包满）⇒ 下一拍还能接着拿
          verdict: res.failed === null ? "ok" : "retry",
          code: INTENT_OK,
          message: res.failed === null ? "" : res.failed.message,
          applied: res.picked.length,
          picked: res,
        };
      }
      if (res.failed !== null) {
        // 一个都没拿到、且停在某个格上（背包满 / 无主）—— 那个码才是真原因
        return fail(it, engineError(res.failed.code, res.failed.message));
      }
      // 一个都没找到：**请求没错，但这条路走不通**（见文件头 ④）
      return {
        intent: it,
        ok: true,
        verdict: "fatal",
        code: INTENT_OK,
        message: "附近没有可拾取的东西",
        applied: 0,
        picked: res,
      };
    }

    case "use": {
      if (w.food === undefined) {
        return fail(
          it,
          engineError(INTENT_NO_FOOD_TABLE, "执行器没有食物表 —— use 需要一张已归一化的表（见 food.ts）"),
        );
      }
      const r = eat(w.scene, it.actor, it.item ?? "", w.food);
      if (!r.ok) return fail(it, r.error);
      const rep = r.value;
      return {
        intent: it,
        ok: true,
        verdict: "ok",
        code: INTENT_OK,
        message: "",
        applied: rep.nutrition,
        ate: rep,
      };
    }
  }
}

/** `attack` 的成功报告（表现层要 before/after/overkill/dead）。失败时 `null`。 */
export function hitOf(o: ExecutedIntent): AttackOutcome | null {
  return o.hit ?? null;
}

/** `pickup` 的原结果。 */
export function pickedOf(o: ExecutedIntent): PickupResult | null {
  return o.picked ?? null;
}

/** `use` 的原结果。 */
export function ateOf(o: ExecutedIntent): EatReport | null {
  return o.ate ?? null;
}

/** 形状错（**不是**世界错）—— 宿主可以用它决定"这一个是脏数据，别重试"。 */
export function isBadShape(o: ExecutedIntent): boolean {
  return o.code === INTENT_BAD_SHAPE;
}
