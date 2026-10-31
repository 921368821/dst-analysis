/**
 * L3 · 动作意图（**一个动作的请求**：谁、想做什么、对谁）
 *
 * 位移意图在 `motion/intent.ts`（批147）：玩家与 AI 已经共用「意图 → 一步位移」。
 * 这个文件是它的**姊妹**，管另一类事 —— 位移是**持续态**（每拍刷新目标），
 * 动作是**瞬时事件**（一次尝试，成败当拍就有答案）。两者一起构成"这一 tick 想干什么"：
 *
 * ```
 * GameIntent = MoveIntent (motion/intent.ts) | ActionIntent (本文件)
 * ```
 *
 * ★★ 六个决定：
 *
 * ① **动作意图不重复定义位移**：`MoveIntent` 只有一份，本文件只把它并进 `GameIntent`。
 *    两套定义的那天，就是"玩家按方向键走 A 逻辑、AI 走 B 逻辑"重演的那天（批147 之前）。
 *
 * ② **判定是三态，不是布尔**：
 *    - `ok`    世界真的变了（掉了血 / 进了包 / 吃了）
 *    - `retry` 这一次不成，但**下一拍可能成**（射程不够、冷却没好、暂时饱着）⇒ 保持目标
 *    - `fatal` 这条路走不通（目标死了、没有攻击组件、配置坏了）⇒ 换目标或换计划
 *    布尔会把「走近一点就能打」与「这个目标根本打不了」压成同一个 false，
 *    于是树只剩两种反应：全都放弃（怪永远不追人），或全都不放弃（怪抱着尸体走）。
 *
 * ③ **未知码默认 `fatal`**，不是 `retry`。这是"默认值选安全的一侧"：
 *    未知码 retry ⇒ 一个配置写错变成"每拍重试、世界毫无变化、CPU 打满"，
 *    症状是"有点卡"，只有采样才看得出来；fatal ⇒ 那只怪放弃这个目标，
 *    症状是"它不打我"，一眼能看见并去查配置。
 *
 * ④ **发起者种类叫 `origin`，不叫 `source`**：`motion/intent.ts` 里的 `IntentSource`
 *    是「谁能产出意图」的接口（有 `produce`）。两个同名不同义的东西放在一个仓库里，
 *    读代码的人迟早会拿错。
 *
 * ⑤ **`origin` 只进日志，不进判定**。权威来自实体身份，不来自自称 ——
 *    与 `net/identity.ts` 同一条纪律。若哪天有人写 `if (origin === "player")`，
 *    同一份世界会出现两套结果，而那正是这一层要消灭的东西。
 *
 * ⑥ **纯数据**：只有数字与字符串，没有节点、没有组件、没有闭包。于是它能进日志、
 *    进快照、进回放，也能过网 —— P2 的预测要预测的正是"意图的执行结果"。
 */

import type { MoveIntent } from "../motion/intent.ts";
import { COMBAT_COOLDOWN, COMBAT_OUT_OF_RANGE } from "../combat/attack.ts";
import { INVENTORY_FULL } from "../inventory/inventory.ts";
import { FOOD_FULL } from "../survival/food.ts";
import { engineError, type EngineError } from "../../foundation/result.ts";

/** 三个动词。★ 没有 `move`：它已经是 `MoveIntent`（见文件头 ①）。 */
export type ActionKind = "attack" | "pickup" | "use";

/** 谁发起的（见文件头 ④⑤）。 */
export type IntentOrigin = "player" | "ai" | "script" | "replay";

/** 三态判定（见文件头 ②）。 */
export type ActionVerdict = "ok" | "retry" | "fatal";

/** 全部意图 = 位移 + 动作。调用方按 `kind` 分支，两边的 `kind` 不撞。 */
export type GameIntent = MoveIntent | ActionIntent;

/** 执行成功（没有错误码）。 */
export const INTENT_OK = "OK";

/** 意图的**形状**不对（缺字段 / 负数 / 非整数）。这一条在执行之前就拦下，不碰世界。 */
export const INTENT_BAD_SHAPE = "INTENT.BAD_SHAPE";

/**
 * 一次动作请求。
 *
 * 字段全是可选的：`attack` 要 `target`，`use` 要 `item`，`pickup` 要 `radius`
 * （或由执行器给默认值）。**形状校验在 `actionProblem`**，不在类型里做联合 ——
 * 联合会让每个调用方都写一遍 narrowing，而漏掉的那一支就是"少了 target 的攻击"。
 */
export interface ActionIntent {
  readonly kind: ActionKind;
  /** 发起者节点 id。 */
  readonly actor: number;
  /** 战斗/移动规则都按 tick 走，意图也一样：不读墙钟。 */
  readonly tick: number;
  /** 见文件头 ⑤：只进日志。 */
  readonly origin: IntentOrigin;
  /** `attack` 打谁。 */
  readonly target?: number;
  /** `pickup` 的半径（世界单位）。不给就用执行器的默认值。 */
  readonly radius?: number;
  /** `use` 用哪种物品。 */
  readonly item?: string;
}

/** 执行结果。`intent` 原样带回来 —— 日志与回放要能一行说清"请求了什么、结果是什么"。 */
export interface ActionOutcome {
  readonly intent: ActionIntent;
  /** 世界接受了吗。**人看这个**（提示条 / 面板）。 */
  readonly ok: boolean;
  /** **决策层看这个**（见文件头 ②）。 */
  readonly verdict: ActionVerdict;
  /** `INTENT_OK` 或原模块的错误码（**不重写文案**，一份）。 */
  readonly code: string;
  readonly message: string;
  /** 世界真的变了多少：伤害 / 拾到几堆 / 回多少饱食。0 不等于失败。 */
  readonly applied: number;
}

/**
 * 下一拍**可能**做得成的码。只收"条件没满足"，不收"这条路走错了"。
 *
 * ★ 这四个的共同点：**世界状态会自己变**。走近了射程就够、等一拍冷却就好、
 *   饿了就不饱、用掉一个背包就有空位。其余任何码（含未知）都归 `fatal`（见文件头 ③）。
 */
const RETRYABLE: ReadonlySet<string> = new Set([
  COMBAT_OUT_OF_RANGE,
  COMBAT_COOLDOWN,
  FOOD_FULL,
  INVENTORY_FULL,
]);

/** 码 → 三态。纯函数，判据直接打这张表（不必搭世界）。 */
export function verdictOf(code: string): ActionVerdict {
  if (code === INTENT_OK) return "ok";
  return RETRYABLE.has(code) ? "retry" : "fatal";
}

/**
 * 形状校验（**执行之前**，不碰世界）。
 *
 * ★ 不校验"这个 id 存不存在、够不够得着"—— 那属于世界，属于执行器与它下面那层。
 *   这里只回答"这个请求本身说得通吗"。分开的好处：一个畸形意图**永远不会**走到
 *   `attack()` 里被判成 `NO_TARGET`，于是 `NO_TARGET` 这个码只表示真事（目标没了）。
 */
export function actionProblem(it: ActionIntent): EngineError | null {
  if (!Number.isInteger(it.actor) || it.actor < 0) {
    return engineError(INTENT_BAD_SHAPE, `actor 要是 >= 0 的整数，收到 ${String(it.actor)}`);
  }
  if (!Number.isInteger(it.tick) || it.tick < 0) {
    return engineError(INTENT_BAD_SHAPE, `tick 要是 >= 0 的整数，收到 ${String(it.tick)}`);
  }
  switch (it.kind) {
    case "attack":
      if (it.target === undefined || !Number.isInteger(it.target) || it.target < 0) {
        return engineError(INTENT_BAD_SHAPE, `attack 必须带 target（>= 0 的整数），收到 ${String(it.target)}`);
      }
      return null;
    case "pickup":
      if (it.radius !== undefined && (!(it.radius >= 0) || !Number.isFinite(it.radius))) {
        return engineError(INTENT_BAD_SHAPE, `pickup 的 radius 必须 >= 0，收到 ${String(it.radius)}`);
      }
      return null;
    case "use":
      if (it.item === undefined || it.item.trim().length === 0) {
        return engineError(INTENT_BAD_SHAPE, "use 必须带 item（物品名），收到空");
      }
      return null;
  }
}

/**
 * 一行诊断文案（**全 ASCII**：面板与日志共用，与 `mob-inspector.ts` 同一条理由）。
 */
export function intentText(it: ActionIntent): string {
  const who = `${it.origin}#${String(it.actor)}`;
  switch (it.kind) {
    case "attack":
      return `${who} attack->${String(it.target ?? -1)} @${String(it.tick)}`;
    case "pickup":
      return it.radius === undefined
        ? `${who} pickup @${String(it.tick)}`
        : `${who} pickup r${String(it.radius)} @${String(it.tick)}`;
    case "use":
      return `${who} use ${it.item ?? ""} @${String(it.tick)}`;
  }
}

/** 结果一行（诊断 / 面板）。成功与失败的前缀相同，好按列对齐看。 */
export function outcomeText(o: ActionOutcome): string {
  const head = intentText(o.intent);
  if (o.code === INTENT_OK) return `${head} => ok/${String(o.applied)}`;
  return `${head} => ${o.code}/${o.verdict}`;
}
