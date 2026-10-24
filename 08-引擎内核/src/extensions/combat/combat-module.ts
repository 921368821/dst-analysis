/**
 * L4 · 战斗驱动（每 tick 一次：决定打谁 → 检查 → 命中 → 可能击杀）
 *
 * 这一层只做"把 `attack()` 按 tick 驱动起来"和"击杀后世界怎么变"。
 * 打谁由调用方的 `decide` 决定（与 `ai/move.ts` 同一个形状：引擎不规定策略）。
 *
 * ★★ 三个决定：
 *
 * ① **击杀默认销毁节点**，并且是**先统计、再销毁**。
 *    顺序反了的话，"销毁"会把后续统计需要的节点拿掉 —— 而表现是
 *    "杀了但 kills 不涨"，或者更糟：`onKill` 里读目标位置读不到。
 *
 * ② **失败要分类计数**，不是笼统一句"没打中"。
 *    射程不够、冷却没好、目标已死、配置坏了，这四类在**修复方式上完全不同**
 *    （走近 / 等 / 换目标 / 改配表）。混成一个数会让人去调射程，而问题在配表。
 *
 * ③ **驱动顺序按节点 id 升序**（与 AI 移动同一理由）：谁先打死目标，
 *    决定了另一个攻击者这一 tick 是"命中"还是"目标已死"。
 *    这个差别在画面上看不出来，但在统计和回放里是可见的。
 *
 * ④ **`onKill` 必须带"谁杀的"**（批65 补）。原来的签名只有
 *    `(targetNodeId, tick)`，于是战利品不知道发给谁 —— 宿主只能靠
 *    "最近一次命中的是谁"这种外部状态去猜，而多打一的时候必然猜错。
 *    **回调少给一个参数，调用方就得自己重构状态**，这是接口缺陷不是用法问题。
 *    参数顺序定成 `(target, killer, tick)`：前两个都是 id，容易写反，
 *    所以判据里专门有一条"两个猎人打同一只兔子，补最后一刀的那个拿到战利品"。
 *
 * ⑤ **友伤拦截次数单独计数**（`friendlyFire`）。不单独计数的话，
 *    "AI 老是站着不打"与"射程不够"在统计上长得一模一样 ——
 *    而这两者的修法完全相反（改关系表 / 调射程）。
 */

import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { Services } from "../../core/tokens.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { ATTACKER_TYPE, Attacker, attack } from "./attack.ts";
import type { Factions } from "./faction.ts";

export const COMBAT_BAD_MODULE = "COMBAT.BAD_MODULE";

/** 一次真的扣到血的命中（表现层的唯一输入，见 `CombatModuleOptions.onHit`）。 */
export interface HitInfo {
  /** 打人的那个。 */
  readonly attackerId: number;
  /** 被打的那个。 */
  readonly targetId: number;
  /** 扣血前 / 后。 */
  readonly before: number;
  readonly after: number;
  /** 实际扣掉的血（伤害数字要显示它，不是 `attacker.damage`）。 */
  readonly applied: number;
  /** 溢出伤害（血只有 3，打了 10 ⇒ overkill 7）。 */
  readonly overkill: number;
  /** 这一下之后是否归零。 */
  readonly dead: boolean;
  readonly tick: number;
}

export interface CombatStats {  /** 带 `combat.attacker` 的节点数。 */
  readonly attackers: number;
  /** 累计命中次数（**不是**这一 tick 的 —— 与 `kills` 同口径，方便算"几下打死一个"）。 */
  readonly hits: number;
  /** 累计击杀数。 */
  readonly kills: number;
  /** 累计：射程不够（应该由移动去解决）。 */
  readonly outOfRange: number;
  /** 累计：冷却没好（正常现象，不是错误）。 */
  readonly cooldown: number;
  /** 累计：因为目标是友军而**没有**出手（见文件头 ⑤）。 */
  readonly friendlyFire: number;
  /** 累计：其它失败（目标已死 / 目标消失 / 配置坏了）—— 这一类才需要人看。 */
  readonly errors: number;
  /** 最近一次**错误类**失败的码，用于诊断（正常时为空串）。 */
  readonly lastError: string;
}

export interface CombatModuleOptions {
  /** 返回"要打哪个节点"；`null` = 这一 tick 不打。 */
  readonly decide: (attackerNodeId: number, tick: number) => number | null;
  /**
   * **命中回调**：扣血成功之后、`onKill` 之前调用（表现层用它做闪烁/伤害数字）。
   *
   * ★ 只在**真的扣到血**时回调：射程不够、冷却没好、友军、目标已死都不回调。
   *   把这些也算成"命中"的话，屏幕上会给打不到的一下也冒一个数字 ——
   *   而那正是玩家最不能容忍的假反馈。
   * ★ 必须在 `onKill` **之前**：`onKill` 可能销毁目标（默认就销毁），
   *   之后的回调读不到位置/组件，"伤害数字"会冒在世界原点。
   */
  readonly onHit?: (info: HitInfo) => void;
  /**
   * 击杀回调（在销毁**之前**调用，于是它能读到目标的位置/组件）。
   *
   * @param targetNodeId 被击杀的节点。
   * @param killerNodeId **补最后一刀的那个**（不是"第一个动手的"）。
   * @param tick 当前 tick。
   */
  readonly onKill?: (targetNodeId: number, killerNodeId: number, tick: number) => void;
  /** 击杀后销毁目标节点（默认 `true`：留着的话 AI 会继续锁定一个死目标）。 */
  readonly destroyOnKill?: boolean;
  /** 阵营关系表（不给就**不检查友伤**，见 `attack()` 文件头 ⑤）。 */
  readonly factions?: Factions;
  /** 显式允许友伤（默认 false）。 */
  readonly friendlyFire?: boolean;
  readonly id?: string;
}

export interface CombatModuleHandle extends IModule {
  update(tick: number, dt: number): void;
  readonly stats: CombatStats;
}

export function createCombatModule(opts: CombatModuleOptions): CombatModuleHandle {
  const destroyOnKill = opts.destroyOnKill ?? true;
  let scene: Scene | null = null;
  let hits = 0;
  let kills = 0;
  let outOfRange = 0;
  let cooldown = 0;
  let friendlyFire = 0;
  let errors = 0;
  let lastError = "";

  const handle: CombatModuleHandle = {
    id: opts.id ?? "combat",
    get stats(): CombatStats {
      const s = scene;
      return {
        attackers: s === null ? 0 : [...s.componentsOf<Attacker>(ATTACKER_TYPE)].length,
        hits,
        kills,
        outOfRange,
        cooldown,
        friendlyFire,
        errors,
        lastError,
      };
    },
    init(ctx: ModuleContext): Result<void, EngineError> {
      const got = ctx.services.get(Services.Scene);
      if (got === undefined) {
        return err(engineError(COMBAT_BAD_MODULE, "战斗模块需要一个 Scene（先注册 Services.Scene）"));
      }
      scene = got;
      return ok(undefined);
    },
    update(tick: number): void {
      const s = scene;
      if (s === null) return;

      const attackers = [...s.componentsOf<Attacker>(ATTACKER_TYPE)];
      // 见文件头 ③
      attackers.sort((a, b) => (a.node?.id ?? -1) - (b.node?.id ?? -1));

      for (const atk of attackers) {
        const node = atk.node;
        if (node === null || !node.activeInHierarchy) continue;
        const target = opts.decide(node.id, tick);
        if (target === null) continue;

        const r = attack(s, node.id, target, { tick, factions: opts.factions, friendlyFire: opts.friendlyFire });
        if (!r.ok) {
          switch (r.error.code) {
            case "COMBAT.OUT_OF_RANGE":
              outOfRange++;
              break;
            case "COMBAT.COOLDOWN":
              cooldown++;
              break;
            case "COMBAT.FRIENDLY_FIRE":
              // 不是错误：这是**规则生效了**。单独计数，见文件头 ⑤
              friendlyFire++;
              break;
            default:
              errors++;
              lastError = r.error.code;
              break;
          }
          continue;
        }

        hits++;
        // 见 `onHit` 的注释：扣血成功之后、onKill 之前（onKill 可能销毁目标）
        opts.onHit?.({
          attackerId: node.id,
          targetId: target,
          before: r.value.report.before,
          after: r.value.report.after,
          applied: r.value.report.applied,
          overkill: r.value.report.overkill,
          dead: r.value.report.dead,
          tick,
        });
        if (!r.value.report.dead) continue;

        // ---- 击杀：先回调（能读到目标），再统计，最后销毁（见文件头 ①）
        //      回调带上 `node.id`（补最后一刀的那个），见文件头 ④
        kills++;
        opts.onKill?.(target, node.id, tick);
        if (destroyOnKill) {
          s.destroy(target);
          s.flush();
        }
      }
    },
    describe(): string {
      return `战斗：命中 ${String(hits)} / 击杀 ${String(kills)}`;
    },
  };

  return handle;
}
