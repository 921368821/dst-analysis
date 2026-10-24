/**
 * L4 · 生命值（阶段 3：**能被扣、能归零**）
 *
 * 在它之前，"目标"只是"要靠近的东西" —— 走过去了没有任何后果。
 * 这个文件只回答一件事：**一个东西还剩多少血、被扣一下之后还剩多少**。
 *
 * ★★ 四个刻意的设计决定：
 *
 * ① **血量是整数**。浮点血量在"扣 0.1 扣十次"之后会剩 `-1.4e-16` 或 `5.5e-16`，
 *    于是"死了没有"取决于累加次序 —— 同种子同世界的两个人会在不同帧倒下。
 *    伤害也必须是整数，小数伤害直接拒绝（不是四舍五入：静默取整会让
 *    "打 1.4 点伤害"变成"打 1 点"，而配表的人以为自己在调细粒度）。
 *
 * ② **扣血不销毁节点**。这一层只改数字；"死了以后世界该怎么变"（消失 / 变尸体 /
 *    掉落 / 播动画）是玩法决定。混进来的后果是：判据里想验"血够不够"必须先造一个
 *    会自己删自己的场景，而"血算错了"和"死得太早"纠缠在一起分不清。
 *    销毁由 `combat-module.ts` 做，并且**只在真的归零时**做。
 *
 * ③ **归零后不再接受伤害**（`COMBAT.TARGET_DEAD`），而不是返回 0。
 *    静默返回 0 会让"打尸体"看起来像"打中了但没伤害"，调用方永远发现不了
 *    自己的目标选择出了问题（锁着一个已经死掉的节点）。
 *
 * ④ **无敌帧按 tick 计**（`invulnUntil`），不按毫秒。
 *    和 AI 的等待同一个理由：dt 会让"同种子同世界"在掉帧时失效。
 *    `invulnUntil` 是**运行期字段**，不进 schema —— 存档读回来时无敌早已过期，
 *    把"还剩几 tick 无敌"存进去反而会让读档后的第一次命中被无声吞掉。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 生命值组件类型。 */
export const HEALTH_TYPE = "combat.health";

/** 目标节点不存在。 */
export const COMBAT_NO_TARGET = "COMBAT.NO_TARGET";
/** 目标身上没有 `combat.health`。 */
export const COMBAT_NO_HEALTH = "COMBAT.NO_HEALTH";
/** 伤害不是正整数（0、负数、小数、NaN 全部拒绝）。 */
export const COMBAT_BAD_AMOUNT = "COMBAT.BAD_AMOUNT";
/** 目标已经归零。 */
export const COMBAT_TARGET_DEAD = "COMBAT.TARGET_DEAD";
/** 还在无敌帧里。 */
export const COMBAT_INVULNERABLE = "COMBAT.INVULNERABLE";

export class Health extends Component {
  /** 当前血量（整数，>= 0）。 */
  hp = 10;
  /** 上限（整数，> 0）。 */
  maxHp = 10;

  readonly schema: ComponentSchema = {
    type: HEALTH_TYPE,
    fields: { hp: FieldType.Int, maxHp: FieldType.Int },
  };

  /**
   * 无敌截止 tick（运行期，见文件头 ④）：`tick < invulnUntil` 时不受伤害。
   * `-1` = 从来不无敌。
   */
  invulnUntil = -1;
}

export function registerHealthComponent(registry: {
  has(t: string): boolean;
  register(s: ComponentSchema, f: () => Component): void;
}): void {
  if (!registry.has(HEALTH_TYPE)) registry.register(new Health().schema, () => new Health());
}

export function isDead(h: Health): boolean {
  return h.hp <= 0;
}

export interface DamageOptions {
  /** 当前 tick（给了才检查无敌帧；不给就当作"不看无敌"）。 */
  readonly tick?: number;
  /** 命中后给多少 tick 无敌（默认 0 = 不给）。 */
  readonly invulnTicks?: number;
}

export interface DamageReport {
  readonly nodeId: number;
  /** 扣血前 / 后。 */
  readonly before: number;
  readonly after: number;
  /** 实际扣掉的血（可能小于请求值，因为血不会低于 0）。 */
  readonly applied: number;
  /** 溢出伤害（血已经不够扣的部分）。 */
  readonly overkill: number;
  /** 这一下之后是否归零。 */
  readonly dead: boolean;
}

/**
 * 对 `targetId` 扣 `amount` 点血。**不销毁节点、不广播事件**（见文件头 ②）。
 *
 * 校验顺序：数量 → 节点 → 组件 → 是否已死 → 无敌帧 → 扣血。
 * 前四步任何一步失败都**一点状态都不动**。
 */
export function damage(
  scene: Scene,
  targetId: number,
  amount: number,
  opts: DamageOptions = {},
): Result<DamageReport, EngineError> {
  if (!Number.isInteger(amount) || amount <= 0) {
    return err(
      engineError(COMBAT_BAD_AMOUNT, `伤害必须是正整数，收到 ${String(amount)}（小数会让"死了没有"取决于累加次序）`),
    );
  }
  const node = scene.find(targetId);
  if (node === undefined || node === null) {
    return err(engineError(COMBAT_NO_TARGET, `节点 ${String(targetId)} 不在场景里`));
  }
  const h = node.get<Health>(HEALTH_TYPE);
  if (h === undefined) {
    return err(engineError(COMBAT_NO_HEALTH, `节点 ${String(targetId)} 没有 ${HEALTH_TYPE}（先 attach 一个 Health）`));
  }
  if (isDead(h)) {
    return err(
      engineError(COMBAT_TARGET_DEAD, `节点 ${String(targetId)} 已经归零（hp=${String(h.hp)}）—— 打尸体通常是目标选择出错`),
    );
  }
  if (opts.tick !== undefined && Number.isInteger(opts.tick) && opts.tick < h.invulnUntil) {
    return err(
      engineError(
        COMBAT_INVULNERABLE,
        `节点 ${String(targetId)} 还在无敌帧里（tick ${String(opts.tick)} < ${String(h.invulnUntil)}）`,
      ),
    );
  }

  const before = h.hp;
  const after = Math.max(0, before - amount);
  h.hp = after;
  if (opts.invulnTicks !== undefined && opts.invulnTicks > 0 && opts.tick !== undefined) {
    h.invulnUntil = opts.tick + opts.invulnTicks;
  }

  return ok({
    nodeId: targetId,
    before,
    after,
    applied: before - after,
    overkill: Math.max(0, amount - before),
    dead: after === 0,
  });
}

/**
 * 回血（整数、夹到上限）。
 *
 * ★ 单独一个函数而不是 `damage(-n)`：负数伤害在签名上是"合法"的，
 *   于是任何一处漏校验都会把回血当伤害用。两个方向分开写，类型就替你拦掉一半。
 */
export function heal(scene: Scene, targetId: number, amount: number): Result<number, EngineError> {
  if (!Number.isInteger(amount) || amount <= 0) {
    return err(engineError(COMBAT_BAD_AMOUNT, `回血量必须是正整数，收到 ${String(amount)}`));
  }
  const node = scene.find(targetId);
  if (node === undefined || node === null) {
    return err(engineError(COMBAT_NO_TARGET, `节点 ${String(targetId)} 不在场景里`));
  }
  const h = node.get<Health>(HEALTH_TYPE);
  if (h === undefined) {
    return err(engineError(COMBAT_NO_HEALTH, `节点 ${String(targetId)} 没有 ${HEALTH_TYPE}`));
  }
  if (isDead(h)) {
    return err(engineError(COMBAT_TARGET_DEAD, `节点 ${String(targetId)} 已经归零 —— 回血不复活（复活要有单独的语义）`));
  }
  const before = h.hp;
  h.hp = Math.min(h.maxHp, before + amount);
  return ok(h.hp - before);
}
