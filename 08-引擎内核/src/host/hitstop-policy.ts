/**
 * 演示世界的顿帧策略（批73 写下，批74 修正分支顺序）。
 *
 * ★ 为什么单独一个文件：策略是**玩法判断**（"什么命中值得冻"），而玩法判断
 *   必须能被单测钉住。写在 `browser-entry.ts` 里就意味着只有浏览器能验它 ——
 *   而批74 的 bug（见下）正是在浏览器里时红时绿跑了很久才被抓到。
 *
 * ★★ 批74 修正的分支顺序：第一版写成
 *      `info.dead ? 12 : info.attackerId === heroId ? 3 : 0`
 *    —— "任何死亡都冻 12 步"。于是**猎狗咬死兔子也冻**：演示世界有 3 只猎狗
 *    常年追杀 10 只兔子，世界被冻得一顿一顿，而冻结不报错、只是手感变怪。
 *    浏览器自检的两条顿帧判据因此时红时绿（tick 被野怪冻住，观测窗口全乱）——
 *    CI 上 M292 报"还原不干净"，根因就是这条。
 *    意图（见 `browser-entry.ts` 的注释）：**只有玩家的命中值得冻**。
 *    攻击者判断必须在死亡判断**之前**，这不是风格问题：
 *    "打死东西"本身不值得冻，"被玩家打死"才值得。
 */

import type { HitInfo } from "../extensions/combat/combat-module.ts";

/** 玩家打中时冻几步（30Hz ⇒ 3 ≈ 0.1s：刚好够"看见"世界顿了一下）。 */
export const HITSTOP_HIT_TICKS = 3;
/** 玩家击杀时冻几步（≈0.4s，与受击闪同长：让"打死了一个东西"有分量）。 */
export const HITSTOP_KILL_TICKS = 12;

/**
 * 演示世界的一票策略：**玩家**的命中冻（击杀 12 步 / 普通 3 步），其余一律不冻。
 *
 * 覆盖的四种情况（都有单测钉住）：
 *   ① 玩家击杀 ⇒ 12；② 玩家普通命中 ⇒ 3；
 *   ③ 怪打怪（含击杀）⇒ 0；④ 怪打玩家（含击杀玩家）⇒ 0。
 */
export function demoHitstopPolicy(info: HitInfo, heroId: number): number {
  if (info.attackerId !== heroId) return 0;
  return info.dead ? HITSTOP_KILL_TICKS : HITSTOP_HIT_TICKS;
}
