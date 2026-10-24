/**
 * L4 · 攻击（阶段 3：**够得着才打、打完要等**）
 *
 * `health.ts` 只管数字，本文件补上"一次攻击"的完整语义：**谁打谁、够不够近、冷却好了没有**。
 *
 * ★★ 四个决定：
 *
 * ① **所有校验在状态变更之前**（和采集/丢弃同一条纪律）。
 *    "先扣血再看够不够近"会让隔山打牛也掉血，而且掉得不多 —— 看起来像"伤害偏小"。
 *
 * ② **距离用平方比，不开方**。理由同 `perception.ts`：`Math.sqrt` 允许 1 ulp 差异，
 *    "正好在射程边缘"的判定不该取决于平台。
 *
 * ③ **冷却按 tick 计，且只认调用方传进来的 tick**。
 *    不读墙钟、不读 `performance.now()` —— 那会让回放与跨宿主存档失去意义。
 *    不传 tick 就不检查冷却（供单点判据/编辑器试打使用），并且**这一点写在报告里**
 *    （`cooldownChecked`），不让人误以为"验过冷却"。
 *
 * ④ **自己打自己要报错**，不是"忽略"。忽略的写法会让 AI 的黑板填错时
 *    "锁定自己"变成一个永远打不死的循环，而没有任何错误浮出来。
 *
 * ⑤ **友伤默认拦截**（批65）。混战里"照队友后背砍"在统计上完全看不出来 ——
 *    `hits` 照涨、`kills` 照涨，只有盯着屏幕才发现自己人在掉血。
 *    默认拦、显式放（`friendlyFire: true`）是唯一能让人**看见自己做了这个选择**的方向。
 *    关系判定在**距离之前**：阵营是静态条件，先判它能少一整类误导
 *    （"打不到"会让人去调射程，而实际是友军挡在前面）。
 *    不传 `factions` 就不检查，并且把这一点写进报告（`stanceChecked`）——
 *    与 ③ 的 `cooldownChecked` 同一个理由：**"没验"和"验过了"必须在返回值里能分开**。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import {
  COMBAT_NO_HEALTH,
  COMBAT_NO_TARGET,
  COMBAT_TARGET_DEAD,
  HEALTH_TYPE,
  type DamageReport,
  type Health,
  damage,
  isDead,
} from "./health.ts";
import { type Factions, type Stance, teamOf } from "./faction.ts";

/** 攻击者组件类型。 */
export const ATTACKER_TYPE = "combat.attacker";

/** 攻击者节点不存在（或没有 `combat.attacker`）。 */
export const COMBAT_NO_ATTACKER = "COMBAT.NO_ATTACKER";
/** 攻击者就是目标。 */
export const COMBAT_SELF = "COMBAT.SELF";
/** 目标超出射程。 */
export const COMBAT_OUT_OF_RANGE = "COMBAT.OUT_OF_RANGE";
/** 冷却还没好。 */
export const COMBAT_COOLDOWN = "COMBAT.COOLDOWN";
/** 目标是友军（同队，或关系表里写了 ally），且没有显式允许友伤。 */
export const COMBAT_FRIENDLY_FIRE = "COMBAT.FRIENDLY_FIRE";

export class Attacker extends Component {
  /** 每下多少伤害（整数，见 `health.ts` 文件头 ①）。 */
  damage = 1;
  /** 射程（世界单位）。 */
  range = 1.6;
  /** 两下之间至少隔多少 tick（0 = 每 tick 都能打）。 */
  cooldownTicks = 20;

  readonly schema: ComponentSchema = {
    type: ATTACKER_TYPE,
    fields: { damage: FieldType.Int, range: FieldType.Float, cooldownTicks: FieldType.Int },
  };

  /** 上次成功命中的 tick（运行期，不进存档 —— 读档后的第一下不该"欠一次冷却"）。 */
  lastHitTick = Number.NEGATIVE_INFINITY;
}

export function registerAttackerComponent(registry: {
  has(t: string): boolean;
  register(s: ComponentSchema, f: () => Component): void;
}): void {
  if (!registry.has(ATTACKER_TYPE)) registry.register(new Attacker().schema, () => new Attacker());
}

export interface AttackOptions {
  /** 当前 tick。给了才检查冷却（见文件头 ③）。 */
  readonly tick?: number;
  /** 命中后给目标多少 tick 无敌（默认 0）。 */
  readonly invulnTicks?: number;
  /** 阵营关系表。不传 = **不检查友伤**（报告里 `stanceChecked` 为 false）。 */
  readonly factions?: Factions;
  /** 显式允许友伤（默认 false）。沙盒/测试用；见文件头 ⑤。 */
  readonly friendlyFire?: boolean;
}

export interface AttackOutcome {
  readonly attackerId: number;
  readonly targetId: number;
  /** 双方距离（世界单位，只用于报告/日志；判定用的是平方）。 */
  readonly distance: number;
  /** `true` = 这一次真的检查了冷却。 */
  readonly cooldownChecked: boolean;
  /** 判定用到的立场（没检查阵营时恒为 `neutral`，配合 `stanceChecked` 读）。 */
  readonly stance: Stance;
  /** `true` = 这一次真的查了阵营关系。 */
  readonly stanceChecked: boolean;
  readonly report: DamageReport;
}

/**
 * `attackerId` 打 `targetId` 一下。
 *
 * 失败时**一点状态都不动**（连冷却都不会被消费）。成功时：
 * 扣血、记 `lastHitTick`、（可选）给目标无敌帧。
 */
export function attack(
  scene: Scene,
  attackerId: number,
  targetId: number,
  opts: AttackOptions = {},
): Result<AttackOutcome, EngineError> {
  if (attackerId === targetId) {
    return err(engineError(COMBAT_SELF, `节点 ${String(attackerId)} 想打自己 —— 通常是目标选择填错了`));
  }
  const attackerNode = scene.find(attackerId);
  if (attackerNode === undefined || attackerNode === null) {
    return err(engineError(COMBAT_NO_ATTACKER, `攻击者 ${String(attackerId)} 不在场景里`));
  }
  const atk = attackerNode.get<Attacker>(ATTACKER_TYPE);
  if (atk === undefined) {
    return err(engineError(COMBAT_NO_ATTACKER, `节点 ${String(attackerId)} 没有 ${ATTACKER_TYPE}`));
  }
  if (!Number.isInteger(atk.damage) || atk.damage <= 0) {
    return err(
      engineError(COMBAT_NO_ATTACKER, `节点 ${String(attackerId)} 的伤害配置不合法：${String(atk.damage)}（必须是正整数）`),
    );
  }
  if (!(atk.range > 0) || !Number.isFinite(atk.range)) {
    return err(
      engineError(COMBAT_NO_ATTACKER, `节点 ${String(attackerId)} 的射程配置不合法：${String(atk.range)}`),
    );
  }
  if (!Number.isInteger(atk.cooldownTicks) || atk.cooldownTicks < 0) {
    return err(
      engineError(COMBAT_NO_ATTACKER, `节点 ${String(attackerId)} 的冷却配置不合法：${String(atk.cooldownTicks)}`),
    );
  }

  const targetNode = scene.find(targetId);
  if (targetNode === undefined || targetNode === null) {
    return err(engineError(COMBAT_NO_TARGET, `目标 ${String(targetId)} 不在场景里`));
  }
  const hp = targetNode.get<Health>(HEALTH_TYPE);
  if (hp === undefined) {
    return err(engineError(COMBAT_NO_HEALTH, `目标 ${String(targetId)} 没有 ${HEALTH_TYPE}`));
  }
  if (isDead(hp)) {
    return err(engineError(COMBAT_TARGET_DEAD, `目标 ${String(targetId)} 已经归零（hp=${String(hp.hp)}）`));
  }

  // ---- 阵营（见文件头 ⑤）：静态条件先判，免得"友军挡在前面"被报成"太远"
  const factions = opts.factions;
  let stance: Stance = "neutral";
  if (factions !== undefined) {
    const mine = teamOf(scene, attackerId).team;
    const theirs = teamOf(scene, targetId).team;
    stance = factions.stanceOf(mine, theirs);
    if (stance === "ally" && opts.friendlyFire !== true) {
      return err(
        engineError(
          COMBAT_FRIENDLY_FIRE,
          `目标 ${String(targetId)} 是友军（阵营「${mine}」）—— 要允许友伤请显式传 friendlyFire: true`,
        ),
      );
    }
  }

  const a = attackerNode.worldPosition;
  const t = targetNode.worldPosition;
  const dx = t.x - a.x;
  const dz = t.y - a.y;
  const dist2 = dx * dx + dz * dz;
  if (dist2 > atk.range * atk.range) {
    return err(
      engineError(
        COMBAT_OUT_OF_RANGE,
        `目标 ${String(targetId)} 距离 ${Math.sqrt(dist2).toFixed(3)} 超出射程 ${String(atk.range)}`,
      ),
    );
  }

  const tick = opts.tick;
  const checkCd = tick !== undefined && Number.isInteger(tick);
  if (checkCd && tick - atk.lastHitTick < atk.cooldownTicks) {
    return err(
      engineError(
        COMBAT_COOLDOWN,
        `冷却未好：tick ${String(tick)} 距上次命中 ${String(atk.lastHitTick)} 只隔 ${String(tick - atk.lastHitTick)}（需要 ${String(atk.cooldownTicks)}）`,
      ),
    );
  }

  const dmg = damage(scene, targetId, atk.damage, {
    tick: checkCd ? tick : undefined,
    invulnTicks: opts.invulnTicks,
  });
  if (!dmg.ok) return dmg; // 无敌帧等由 damage 报错，这里原样上抛

  if (checkCd) atk.lastHitTick = tick;

  return ok({
    attackerId,
    targetId,
    distance: Math.sqrt(dist2),
    cooldownChecked: checkCd,
    stance,
    stanceChecked: factions !== undefined,
    report: dmg.value,
  });
}
