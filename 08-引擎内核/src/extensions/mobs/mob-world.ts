/**
 * L4 · 世界里的生物群（**一个模块管住"谁在动、谁在打、死了掉什么"**）
 *
 * 到批65 为止，`ai/move`、`combat`、`loot` 都各自有判据，但**没有任何东西
 * 把它们装在一起**。演示页里因此只有玩家一个人在走 —— 世界是活的，但看不见活物。
 *
 * 这个模块就是那条装配线，并且刻意只做三件事：
 *   ① 按格子放生物（模板 → `spawnMob`）；
 *   ② 每 tick 用**一个**大脑同时喂 `move`（想去哪格）与 `combat`（想打谁）；
 *   ③ 击杀时把该模板的战利品发给**击杀者**，发不出去要计数。
 *
 * ★★ 四个决定：
 *
 * ① **一个大脑喂两个模块**（见 `mob-brain.ts` 文件头）。这里额外做一件事：
 *    `update` 先自己对每只生物问一次，再交给两个模块 —— 于是"这一 tick 有多少只在追人"
 *    是白拿的统计，而两个模块的重复提问被同一张缓存吃掉。
 *    不这么做的话，想知道"有几只在追"就得再感知一遍（第三遍）。
 *
 * ② **战利品发给击杀者，不是发给"玩家"**。看起来绕，但它让"猎狗打死兔子"
 *    这件事有了正确的语义：猎狗没有背包 ⇒ `LOOT.NO_OWNER` ⇒ 计入 `lootNoRecipient`。
 *    而 `lootNoRecipient` 与 `lootLost` 必须分开：前者是"没人能收"（设计如此），
 *    后者是"包满了"（要提示玩家）。混在一起会让人去清背包。
 *
 * ③ **生物节点被销毁后从名单里摘掉**（每 tick 惰性清理）。
 *    不清的代价不是内存（几十个 id），而是统计里的 `mobs` 会只增不减 ——
 *    而"世界里有多少活物"正是这个模块存在的理由。
 *
 * ④ **不放物理体**。生物之间、生物与树之间会互相穿过。
 *    加物理体需要处理"被推挤后路径失效"（`move` 的 `nearestIndexOnPath` 已经支持，
 *    但没人验过"二十只生物挤在门口"），那是另一批的事；
 *    这一批的目标是"看得见会动的活物"，把物理一起塞进来会让判据说不清是哪一个坏了。
 */

import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { Services } from "../../core/tokens.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { createMoveModule, type MoveModuleHandle } from "../ai/move.ts";
import type { NavGrid } from "../nav/nav-grid.ts";
import { createCombatModule, type CombatModuleHandle, type HitInfo } from "../combat/combat-module.ts";
import { createThreatTable, type ThreatTable } from "../combat/threat.ts";
import type { Factions } from "../combat/faction.ts";
import { grantLoot, lootOfNode } from "../combat/loot.ts";
import { type CorpseGround, spawnCorpse } from "../combat/corpse.ts";
import { type MobHandle, spawnMob } from "./spawn-mob.ts";
import { type MobBrain, createMobBrain } from "./mob-brain.ts";

export const MOB_WORLD_BAD_MODULE = "MOB_WORLD.BAD_MODULE";

export interface MobSpot {
  /** 用第几个模板（`templates` 的下标）。 */
  readonly template: number;
  /** 放在哪一格（格子下标）。 */
  readonly cell: number;
}

export interface MobWorldOptions {
  /** 导航网格（生物只在可走格上出生与漫游）。 */
  readonly grid: NavGrid;
  readonly factions: Factions;
  /** 模板会被 `spawnMob` 校验；这里放原始配置即可。 */
  readonly templates: readonly unknown[];
  readonly spots: readonly MobSpot[];
  /** 大脑参数（感知半径等）。 */
  readonly range: number;
  readonly seed?: number;
  readonly wanderEvery?: number;
  readonly leashCells?: number;
  /**
   * 命中回调：**原样转发**给内部战斗模块（表现层用它做受击闪烁与伤害数字）。
   *
   * ★ 为什么要在这里开一个口子，而不是让宿主直接 `attack()`：
   *   生物的攻击是战斗模块驱动的（`decide` → `attack`），宿主没有那一帧的
   *   扣血报告。宿主若为了效果自己去 `attack()` 一遍，就等于**打了两下**。
   */
  readonly onHit?: (info: HitInfo) => void;
  /**
   * 仇恨记忆多久（tick，默认 150 ≈ 5 秒 @30Hz）。`0` = **关闭记仇**（回到只看感知）。
   *
   * ★ 这个值决定"打了就跑"能不能成立，所以它是**玩法参数**，不是实现细节：
   *   太短（<1 秒）= 记忆形同虚设；太长（>30 秒）= 跑遍全图甩不掉，玩家会觉得被针对。
   */
  readonly threatDecayTicks?: number;
  /** 记仇的追击半径（格；默认 = `leashCells`，0 = 不限）。 */
  readonly aggroCells?: number;
  /**
   * 死亡时在**原地留一具尸体**（批123）。不给 = 老行为（战利品直接进击杀者背包）。
   *
   * ★★ 为什么是选项而不是默认行为：改成默认的话，所有"击杀 → 背包多了几块肉"的
   *   判据会同时变红（`lootGranted` 全变 0），而那些判据验的是另一件事。
   *   玩法上的差别是真实的（"地上有具尸体"要玩家自己走过去翻），所以它必须由
   *   宿主**明说**，而不是被一个默认值悄悄接管。
   * ★ 尸体放不下时（`CORPSE.NO_SPACE`）**退回老路**：战利品进击杀者背包。
   *   不退回的话，"四周全是水"这种地形会让掉落凭空消失 —— 而画面上只是
   *   地上没有尸体，玩家不会想到去怀疑地形。
   */
  readonly corpse?: MobCorpseOptions;
  readonly id?: string;
}

/** 尸体模式（见 `MobWorldOptions.corpse`）。 */
export interface MobCorpseOptions {
  /** 尸体落在哪片地上（通常就是同一个 `NavGrid`）。 */
  readonly ground: CorpseGround;
  /** 腐烂时长（tick；`0`/省略 = 永不腐烂）。 */
  readonly decayTicks?: number;
  /** 找落点的搜索半径（格，默认 2）。 */
  readonly searchCells?: number;
}

export interface MobWorldStats {
  /** 还活着的生物数。 */
  readonly mobs: number;
  /** 这一 tick 在追人的。 */
  readonly hunting: number;
  /** 这一 tick 在漫游的。 */
  readonly wandering: number;
  /** 这一 tick 什么都不做的。 */
  readonly idle: number;
  readonly kills: number;
  /** 真的进了击杀者背包的件数。 */
  readonly lootGranted: number;
  /** 背包满了没放进去的件数（要提示玩家）。 */
  readonly lootLost: number;
  /** 击杀者没有背包（猎狗打死兔子）—— **不是错误**。 */
  readonly lootNoRecipient: number;
  /** 原地留下的尸体数（`corpse` 没开时恒 0）。 */
  readonly corpsesSpawned: number;
  /** 尸体没放成、退回"进背包"的次数（`CORPSE.NO_SPACE` / 找不到死亡位置）。 */
  readonly corpsesFailed: number;
  /** 上一次尸体失败的原因（正常时为空串）。 */
  readonly lastCorpseError: string;
  /** 有仇恨的生物数（`threatDecayTicks: 0` 时恒为 0）。 */
  readonly threatTargets: number;
  /** 仇恨表里一共几条（生物 × 攻击者）。 */
  readonly threatEntries: number;
  readonly lastLootError: string;
}

export interface MobWorldHandle extends IModule {
  update(tick: number, dt: number): void;
  readonly stats: MobWorldStats;
  /** 还活着的生物节点 id（**升序**：判据与日志读它不会因出生顺序而变）。 */
  readonly nodeIds: readonly number[];
  /** 某个节点用的模板（诊断用）。 */
  templateOf(nodeId: number): string | null;
  /**
   * **外部命中的记仇入口**（玩家手动攻击用）。
   *
   * ★★ 为什么必须有它：玩家的攻击走 `attackNearest()` → `attack()`，
   *   **不经过** `combat-module`（那是"每 tick 由 decide 驱动"的那条路）。
   *   没有这个入口时，"打怪一下"在生物的记忆里**等于没发生过** ——
   *   于是"打了就跑"这个核心体验是坏的，而所有 Node 判据都是绿的
   *   （它们打的是"生物打生物"那条路）。
   * ★ 返回 `false` = 没记仇（没开记仇 / 伤害不合法 / 自己打自己）。
   * ★ 批123 后期：原来这里还有一个 `lootTableOf` —— 已删除。
   *   战利品表改成挂在实体上的组件（`loot.ts` 的 `LOOT_TYPE`），
   *   于是"玩家打死的东西掉什么"不再需要问本模块，也就不会因为读档换了一批
   *   节点而查不到表。
   */
  noteHit(info: { attackerId: number; targetId: number; applied: number; tick: number }): boolean;
}

export function createMobWorldModule(options: MobWorldOptions): MobWorldHandle {
  let scene: Scene | null = null;
  let brain: MobBrain | null = null;
  /** 仇恨表（`threatDecayTicks: 0` 时是 null = 完全不记仇）。 */
  let threat: ThreatTable | null = null;
  let moveMod: MoveModuleHandle | null = null;
  let combatMod: CombatModuleHandle | null = null;

  const corpse = options.corpse;
  const kindOf = new Map<number, string>();
  /** 存活名单（每 tick 惰性清理，见文件头 ③）。 */
  let ids: number[] = [];

  let mobs = 0;
  let hunting = 0;
  let wandering = 0;
  let idle = 0;
  let lootGranted = 0;
  let lootLost = 0;
  let lootNoRecipient = 0;
  let lastLootError = "";
  let corpsesSpawned = 0;
  let corpsesFailed = 0;
  let lastCorpseError = "";

  /** 见文件头 ③。头部与尾部各调一次：本 tick 开始时与结束时都要准。 */
  function prune(): void {
    const s = scene;
    if (s === null || ids.length === 0) {
      mobs = 0;
      return;
    }
    const alive = ids.filter((id) => s.find(id) !== undefined);
    if (alive.length !== ids.length) ids = alive;
    mobs = ids.length;
  }

  const handle: MobWorldHandle = {
    id: options.id ?? "world.mobs",
    get stats(): MobWorldStats {
      return {
        mobs,
        hunting,
        wandering,
        idle,
        kills: combatMod?.stats.kills ?? 0,
        lootGranted,
        lootLost,
        lootNoRecipient,
        corpsesSpawned,
        corpsesFailed,
        lastCorpseError,
        threatTargets: threat?.stats().targets ?? 0,
        threatEntries: threat?.stats().entries ?? 0,
        lastLootError,
      };
    },
    get nodeIds(): readonly number[] {
      return [...ids].sort((a, b) => a - b);
    },
    templateOf(nodeId: number): string | null {
      return kindOf.get(nodeId) ?? null;
    },
    noteHit(info): boolean {
      if (threat === null) return false;
      return threat.add(info.targetId, info.attackerId, info.applied, info.tick).ok;
    },
    init(ctx: ModuleContext): Result<void, EngineError> {
      const got = ctx.services.get(Services.Scene);
      if (got === undefined) {
        return err(engineError(MOB_WORLD_BAD_MODULE, "生物群需要一个 Scene（先注册 Services.Scene）"));
      }
      scene = got;
      const grid = options.grid;
      // ★ 顺序：先有表、再有大脑。反过来的话大脑拿到 null，**不报错**，
      //   只是永远不记仇 —— 而"记仇没生效"与"没打中"在统计上完全一样。
      const decay = options.threatDecayTicks ?? 150;
      if (!Number.isInteger(decay) || decay < 0) {
        return err(engineError(MOB_WORLD_BAD_MODULE, `threatDecayTicks 必须是 >= 0 的整数，收到 ${String(decay)}`));
      }
      threat = decay === 0 ? null : createThreatTable({ decayTicks: decay });
      brain = createMobBrain({
        factions: options.factions,
        range: options.range,
        ...(options.seed === undefined ? {} : { seed: options.seed }),
        ...(options.wanderEvery === undefined ? {} : { wanderEvery: options.wanderEvery }),
        ...(options.leashCells === undefined ? {} : { leashCells: options.leashCells }),
        ...(options.aggroCells === undefined ? {} : { aggroCells: options.aggroCells }),
        ...(threat === null ? {} : { threat }),
      });

      // ---- ① 放生物。**任何一只失败都整体失败**（见 `spawnMobs` 的理由：
      //       "少了三只兔子"不该看起来像随机）
      const placed: MobHandle[] = [];
      for (let i = 0; i < options.spots.length; i++) {
        const spot = options.spots[i]!;
        const tpl = options.templates[spot.template];
        if (tpl === undefined) {
          return err(
            engineError(MOB_WORLD_BAD_MODULE, `第 ${String(i)} 个出生点引用了不存在的模板 ${String(spot.template)}`, {
              index: i,
              template: spot.template,
            }),
          );
        }
        const c = grid.centerOf(spot.cell);
        const r = spawnMob(got, tpl, c.x, c.z, { name: `mob#${String(i)}` });
        if (!r.ok) return r;
        placed.push(r.value);
      }
      for (const m of placed) {
        ids.push(m.nodeId);
        kindOf.set(m.nodeId, m.template.kind);
      }
      mobs = ids.length;

      // ---- ② 两个子模块共用同一个大脑（见文件头 ①）
      const b = brain;
      moveMod = createMoveModule({
        grid,
        decide: (agentId, tick) => b.decide(got, agentId, tick, grid)?.cell ?? null,
        id: "world.mobs.move",
      });
      combatMod = createCombatModule({
        // 表现层的输入：原样转发（见 `MobWorldOptions.onHit`）
        onHit: (info) => {
          // ★ 记仇在**转发之前**：表现层可以有 bug、可以抛错，但"谁打过我"这件事
          //   是玩法状态，不该被一个渲染回调的异常影响。
          threat?.add(info.targetId, info.attackerId, info.applied, info.tick);
          options.onHit?.(info);
        },
        decide: (agentId, tick) => {
          const d = b.decide(got, agentId, tick, grid);
          return d !== null && d.kind === "hunt" ? d.targetNodeId : null;
        },
        factions: options.factions,
        id: "world.mobs.combat",
        // ---- ③ 战利品：发给击杀者（见文件头 ②）
        onKill: (targetId, killerId, tick) => {
          // ★ 被杀的那个作为**目标**整条清掉；同时它作为**攻击者**也不该再被记着
          //   （它已经不在场景里，留着的话 AI 会朝一个不存在的 id 走一辈子）
          if (threat !== null) {
            threat.forgetOne(targetId, killerId);
            threat.forget(targetId);
          }
          // ★ 战利品表**从实体身上读**（`game.loot`），不从模块旁表读 ——
          //   旁表按 id 索引，读档换了场景就查不到了（见 `loot.ts` 的 `LOOT_TYPE`）。
          const lootR = lootOfNode(got, targetId);
          if (!lootR.ok) {
            // 表在、但读不出来：不能当成"没有掉落"，否则东西凭空消失且无日志
            lastLootError = lootR.error.code;
            return;
          }
          const loot = lootR.value;
          if (loot === null) return;
          // ① 尸体模式：先试着留在原地（见 `MobWorldOptions.corpse` 的 ★）
          if (corpse !== undefined) {
            const dead = got.find(targetId);
            if (dead !== undefined) {
              const placed = spawnCorpse(got, loot, {
                ground: corpse.ground,
                x: dead.localPosition.x,
                z: dead.localPosition.y,
                nowTick: tick,
                ...(corpse.decayTicks === undefined ? {} : { decayTicks: corpse.decayTicks }),
                ...(corpse.searchCells === undefined ? {} : { searchCells: corpse.searchCells }),
              });
              if (placed.ok) {
                corpsesSpawned++;
                return;
              }
              // 放不下 ⇒ 退回老路（战利品不许凭空消失）：记一笔，再往下走
              corpsesFailed++;
              lastCorpseError = placed.error.code;
            } else {
              // `onKill` 在**销毁之前**调用，读不到位置说明调用方改了顺序
              corpsesFailed++;
              lastCorpseError = "MOB_WORLD.NO_DEAD_NODE";
            }
          }
          // ② 老路：直接进击杀者背包
          const g = grantLoot(got, killerId, loot);
          if (!g.ok) {
            lootNoRecipient++;
            lastLootError = g.error.code;
            return;
          }
          lootGranted += g.value.grantedCount;
          if (g.value.lostCount > 0) {
            lootLost += g.value.lostCount;
            lastLootError = g.value.stoppedAt === null ? "" : `INVENTORY.FULL@${g.value.stoppedAt}`;
          }
        },
      });

      const im = moveMod.init(ctx) as { ok: boolean } | undefined;
      if (im !== undefined && !im.ok) return err(engineError(MOB_WORLD_BAD_MODULE, "移动子模块初始化失败"));
      const ic = combatMod.init(ctx) as { ok: boolean } | undefined;
      if (ic !== undefined && !ic.ok) return err(engineError(MOB_WORLD_BAD_MODULE, "战斗子模块初始化失败"));
      return ok(undefined);
    },
    update(tick: number, dt: number): void {
      const s = scene;
      const b = brain;
      if (s === null || b === null || moveMod === null || combatMod === null) return;

      // 先自己问一遍（顺带出统计），两个子模块随后提问会命中同一张缓存
      let h = 0;
      let w = 0;
      let i0 = 0;
      for (const id of ids) {
        const d = b.decide(s, id, tick, options.grid);
        if (d === null) i0++;
        else if (d.kind === "hunt") h++;
        else w++;
      }
      hunting = h;
      wandering = w;
      idle = i0;

      moveMod.update(tick, dt);
      combatMod.update(tick, dt);
      // ★ 尾部**再清一次**：击杀发生在 `combatMod.update` 里面，只清头部的话
      //   `stats.mobs` 会滞后一 tick —— 而"世界里还有几只"正是这个模块存在的理由，
      //   一个滞后一 tick 的数字比没有更糟（人会去查"为什么少了一只"）。
      prune();
    },
    stop(): void {
      moveMod?.stop?.();
      combatMod?.stop?.();
      // 不清 `ids`：这个模块被 stop 之后再 start 时，名单还在（世界没变）
    },
    describe(): string {
      return `生物：${String(mobs)} 只（追 ${String(hunting)} / 游 ${String(wandering)}），击杀 ${String(
        combatMod?.stats.kills ?? 0,
      )}`;
    },
  };

  return handle;
}
