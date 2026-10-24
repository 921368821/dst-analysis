/**
 * L4 · 生物模板（**纯校验**，不碰场景）
 *
 * 演示页里"放一只兔子"要挂五个组件（精灵 / 血量 / 阵营 / 移动 / 攻击），
 * 少一个的症状各不相同且都不明显：
 *   · 少精灵 ⇒ 它在世界里走着，但你看不见（只有 AI 统计里有）；
 *   · 少血量 ⇒ 打不动（`COMBAT.NO_HEALTH`），而 AI 会一直锁定它；
 *   · 少阵营 ⇒ 谁都能打它，它也打谁 —— "友军"这个概念对它不存在；
 *   · 少移动 ⇒ 站着不动的靶子；
 *   · 少攻击 ⇒ 会追上来，然后贴着玩家不动。
 *
 * 所以模板必须在**装配之前**一次性校验完，并且校验规则要能逐条被钉住。
 *
 * ★ 三条决定：
 *
 * ① **数值一律走与运行时相同的边界**（正整数 / > 0 / >= 0）。
 *    模板放行 `hp: 0` 的话，生物一出生就是尸体，而 `damage()` 报的是
 *    `TARGET_DEAD` —— 看起来像"它被别人打死了"。
 *
 * ② **`team` 允许空串**（= 中立），但**不允许纯空白**。
 *    `" "` 与 `""` 在关系表里是两个不同的组名，而人眼完全看不出差别 ——
 *    这种"看不见的差异"是排查成本最高的一类。
 *
 * ③ **战利品表复用 `normalizeLoot`**，不在这里重写一遍。
 *    两份实现必然漂移（一份合并重复 kind、一份覆盖），而漂移只在
 *    "配表里写了两条 meat"时才暴露。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import { type LootEntry, type LootTable, normalizeLoot } from "../combat/loot.ts";

/** 模板不合法。`detail.field` 指明是哪个字段。 */
export const MOB_BAD_TEMPLATE = "MOB.BAD_TEMPLATE";

export interface MobTemplate {
  /** 模板名，也是节点名前缀（`rabbit` → `rabbit/0`…）。 */
  readonly kind: string;
  /** 图集帧名。 */
  readonly frame: string;
  /** 精灵世界尺寸。 */
  readonly width: number;
  readonly height: number;
  /** 物理半径（用于碰撞体）。 */
  readonly radius: number;
  readonly maxHp: number;
  /** 每下伤害。**`0` = 和平生物**（不挂攻击组件），见 `spawn-mob.ts` 文件头 ③。 */
  readonly damage: number;
  readonly range: number;
  readonly cooldownTicks: number;
  readonly speed: number;
  /** 阵营名。`""` = 中立。 */
  readonly team: string;
  readonly loot: LootTable;
}

function bad(field: string, message: string): Result<MobTemplate, EngineError> {
  return err(engineError(MOB_BAD_TEMPLATE, message, { field }));
}

function isPosInt(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v) && v > 0;
}

function isPosFinite(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v) && v > 0;
}

/**
 * 校验一份模板（`unknown` 进、`MobTemplate` 出）。
 *
 * 收 `unknown` 而不是 `MobTemplate`：模板来自宿主的配置对象，
 * 类型在运行时不存在，而"配置写错"正是要在这里挡掉的东西。
 */
export function validateTemplate(raw: unknown): Result<MobTemplate, EngineError> {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return bad("", `生物模板必须是对象，收到 ${Array.isArray(raw) ? "数组" : typeof raw}`);
  }
  const t = raw as Partial<MobTemplate>;

  if (typeof t.kind !== "string" || t.kind.length === 0) {
    return bad("kind", `kind 必须是非空字符串，收到 ${JSON.stringify(t.kind)}`);
  }
  if (typeof t.frame !== "string" || t.frame.length === 0) {
    return bad("frame", `「${t.kind}」的 frame 必须是非空字符串（缺帧 ⇒ 生物能走但看不见）`);
  }
  if (!isPosFinite(t.width)) return bad("width", `「${t.kind}」的 width 必须是 > 0 的有限数，收到 ${String(t.width)}`);
  if (!isPosFinite(t.height)) {
    return bad("height", `「${t.kind}」的 height 必须是 > 0 的有限数，收到 ${String(t.height)}`);
  }
  if (!isPosFinite(t.radius)) return bad("radius", `「${t.kind}」的 radius 必须是 > 0 的有限数，收到 ${String(t.radius)}`);
  // 见文件头 ①
  if (!isPosInt(t.maxHp)) return bad("maxHp", `「${t.kind}」的 maxHp 必须是正整数，收到 ${String(t.maxHp)}`);
  // `0` 是合法的：和平生物（兔子）不该挂攻击组件 —— 见 spawn-mob.ts 文件头 ③
  if (typeof t.damage !== "number" || !Number.isInteger(t.damage) || t.damage < 0) {
    return bad("damage", `「${t.kind}」的 damage 必须是 >= 0 的整数（0 = 和平生物），收到 ${String(t.damage)}`);
  }
  if (!isPosFinite(t.range)) return bad("range", `「${t.kind}」的 range 必须是 > 0 的有限数，收到 ${String(t.range)}`);
  if (typeof t.cooldownTicks !== "number" || !Number.isInteger(t.cooldownTicks) || t.cooldownTicks < 0) {
    return bad("cooldownTicks", `「${t.kind}」的 cooldownTicks 必须是 >= 0 的整数，收到 ${String(t.cooldownTicks)}`);
  }
  if (!isPosFinite(t.speed)) return bad("speed", `「${t.kind}」的 speed 必须是 > 0 的有限数，收到 ${String(t.speed)}`);
  if (typeof t.team !== "string") return bad("team", `「${t.kind}」的 team 必须是字符串，收到 ${typeof t.team}`);
  // 见文件头 ②
  if (t.team.length > 0 && t.team.trim().length === 0) {
    return bad("team", `「${t.kind}」的 team 是纯空白 —— 空串表示中立，纯空白是一个看不见的阵营名`);
  }

  // 见文件头 ③
  const loot = normalizeLoot(t.loot ?? []);
  if (!loot.ok) return bad("loot", `「${t.kind}」的战利品表不合法：${loot.error.message}`);

  return ok({
    kind: t.kind,
    frame: t.frame,
    width: t.width,
    height: t.height,
    radius: t.radius,
    maxHp: t.maxHp,
    damage: t.damage,
    range: t.range,
    cooldownTicks: t.cooldownTicks,
    speed: t.speed,
    team: t.team,
    loot: loot.value as readonly LootEntry[],
  });
}
