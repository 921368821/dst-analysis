/**
 * L4 · 饱食度（阶段 3：「肉有用了」）
 *
 * 在它之前，打猎的产物只能"占一格背包"。这个文件只回答一件事：
 * **一个东西还剩多少饱食、吃下去之后还剩多少、以及饿急了会怎样**。
 *
 * ★★ 四个刻意的决定（与 `combat/health.ts` 同一个思路，理由也同一个）：
 *
 * ① **饱食度是整数**。浮点在"每 tick 扣 0.01"之后一定会出现
 *    "读档回来差 1e-14"，而"饿到 0"是个**精确事件** —— 它决定玩家什么时候开始掉血。
 *    同种子同世界的两个人会在不同帧倒下，回放对不上。
 *
 * ② **归零不等于死**。`value === 0` 只是"饿着"，真正掉血由 `survival-module` 按
 *    「每 N tick 掉 M 点」去做。把两者混在一起的话，"饿多久会死"就变成一条
 *    藏在别处的隐式规则，配表的人改不动它。
 *
 * ③ **`feed` 允许溢出，并如实报告 `wasted`**；而"吃一个物品"（`food.ts` 的 `eat`）
 *    **先判满再扣物品**。两层语义不同：`feed` 是"喂进去多少"，`eat` 是"吃一个东西"。
 *    只有一层的话，"吃饱了还吃"必然会导致"少了一块肉但什么都没发生"。
 *
 * ④ **饱食度是组件字段，衰减速率是模块参数**。把 `decayPerTick` 写进组件的话，
 *    每个存档都会带一份"当时的难度配置"，改平衡就再也改不动老存档。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 饱食度组件类型。 */
export const HUNGER_TYPE = "game.hunger";

/** 节点不存在。 */
export const HUNGER_NO_OWNER = "HUNGER.NO_OWNER";
/** 节点身上没有 `game.hunger`。 */
export const HUNGER_NO_COMPONENT = "HUNGER.NO_COMPONENT";
/** 数值不是有限数（负数、NaN、小数都按"配置写错"处理，见文件头 ①）。 */
export const HUNGER_BAD_AMOUNT = "HUNGER.BAD_AMOUNT";

export class Hunger extends Component {
  /** 当前饱食度（整数，>= 0）。0 = 饿着（见文件头 ②）。 */
  value = 100;
  /** 上限（整数，> 0）。 */
  max = 100;

  readonly schema: ComponentSchema = {
    type: HUNGER_TYPE,
    fields: { value: FieldType.Int, max: FieldType.Int },
  };
}

export function registerHungerComponent(registry: {
  has(t: string): boolean;
  register(s: ComponentSchema, f: () => Component): void;
}): void {
  if (!registry.has(HUNGER_TYPE)) registry.register(new Hunger().schema, () => new Hunger());
}

/** 是否饿着（注意：饿着**不等于**死了，见文件头 ②）。 */
export function isStarving(h: Hunger): boolean {
  return h.value <= 0;
}

/**
 * 造一个 `Hunger` 并挂上。
 *
 * ★ `start` 省略时**满值**：默认值必须是"安全的一侧"。
 *   把默认设成 0 的后果是"新生成的角色一出现就在饿死倒计时里"，
 *   而这类错误只会在有人真的去玩的时候才被发现。
 */
export function makeHunger(
  scene: Scene,
  ownerId: number,
  max = 100,
  start?: number,
): Result<Hunger, EngineError> {
  if (!Number.isInteger(max) || max <= 0) {
    return err(engineError(HUNGER_BAD_AMOUNT, `饱食上限必须是正整数，收到 ${String(max)}`));
  }
  const v = start ?? max;
  if (!Number.isInteger(v) || v < 0 || v > max) {
    return err(
      engineError(HUNGER_BAD_AMOUNT, `初始饱食度必须是 [0, ${String(max)}] 里的整数，收到 ${String(v)}`),
    );
  }
  const node = scene.find(ownerId);
  if (node === undefined || node === null) {
    return err(engineError(HUNGER_NO_OWNER, `节点 ${String(ownerId)} 不在场景里`));
  }
  const h = new Hunger();
  h.max = max;
  h.value = v;
  const made = scene.attach(ownerId, () => h);
  if (!made.ok) return made;
  // ★ `attach` 走命令队列，flush 之前 `get()` 读不到 —— 少了这一句，
  //   `makeHunger` 之后立刻 `feed()` 会报 NO_COMPONENT，而"组件明明挂上了"。
  //   （批56 的 `makeInventory` 就是这么栽过一次，这里照抄它的收尾。）
  scene.flush();
  if (node.get<Hunger>(HUNGER_TYPE) === undefined) {
    return err(engineError(HUNGER_NO_COMPONENT, `饱食组件挂上之后又读不到（节点 ${String(ownerId)}）`));
  }
  return ok(h);
}

export interface FeedReport {
  readonly nodeId: number;
  readonly before: number;
  readonly after: number;
  /** 实际吃进去的（可能小于请求值，因为不会超过上限）。 */
  readonly applied: number;
  /** 溢出的部分（见文件头 ③：**报告**，不静默丢）。 */
  readonly wasted: number;
}

/**
 * 往 `ownerId` 的饱食度里加 `nutrition` 点。**不碰背包**（那是 `food.ts` 的事）。
 *
 * 校验顺序：数量 → 节点 → 组件。前两步任何一步失败都**一点状态都不动**。
 */
export function feed(scene: Scene, ownerId: number, nutrition: number): Result<FeedReport, EngineError> {
  if (!Number.isInteger(nutrition) || nutrition <= 0) {
    return err(
      engineError(HUNGER_BAD_AMOUNT, `营养值必须是正整数，收到 ${String(nutrition)}（小数会让"饿了没有"取决于累加次序）`),
    );
  }
  const node = scene.find(ownerId);
  if (node === undefined || node === null) {
    return err(engineError(HUNGER_NO_OWNER, `节点 ${String(ownerId)} 不在场景里`));
  }
  const h = node.get<Hunger>(HUNGER_TYPE);
  if (h === undefined) {
    return err(
      engineError(HUNGER_NO_COMPONENT, `节点 ${String(ownerId)} 没有 ${HUNGER_TYPE}（先 attach 一个 Hunger）`),
    );
  }
  const before = h.value;
  const after = Math.min(h.max, before + nutrition);
  h.value = after;
  return ok({
    nodeId: ownerId,
    before,
    after,
    applied: after - before,
    wasted: nutrition - (after - before),
  });
}

/**
 * 直接扣饱食度（模块每 tick 用它做衰减；也供"中毒 / 诅咒"这类负向效果用）。
 *
 * ★ 与 `feed(-n)` 分开的理由同 `heal()` 与 `damage(-n)`：负数进了签名就是"合法"的，
 *   任何一处漏校验都会把扣和加搞反。
 */
export function drain(scene: Scene, ownerId: number, amount: number): Result<FeedReport, EngineError> {
  if (!Number.isInteger(amount) || amount <= 0) {
    return err(engineError(HUNGER_BAD_AMOUNT, `衰减量必须是正整数，收到 ${String(amount)}`));
  }
  const node = scene.find(ownerId);
  if (node === undefined || node === null) {
    return err(engineError(HUNGER_NO_OWNER, `节点 ${String(ownerId)} 不在场景里`));
  }
  const h = node.get<Hunger>(HUNGER_TYPE);
  if (h === undefined) {
    return err(engineError(HUNGER_NO_COMPONENT, `节点 ${String(ownerId)} 没有 ${HUNGER_TYPE}`));
  }
  const before = h.value;
  const after = Math.max(0, before - amount);
  h.value = after;
  return ok({
    nodeId: ownerId,
    before,
    after,
    applied: before - after,
    wasted: amount - (before - after),
  });
}
