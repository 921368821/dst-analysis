/**
 * L4 · 生物本能（**这一 tick 想干什么**：追谁 / 走去哪）
 *
 * `ai/move.ts` 只要"想去哪一格"，`combat` 只要"想打哪个节点"。两者本来是
 * 同一个决定的两半 —— 于是这一层把它算一次，两边各自取自己那一半。
 * 分成两个回调各算一次的话，两次感知之间世界可能已经变了（目标被同伴打死），
 * 结果是"追着一具尸体走"或"隔着半张地图挥拳"。
 *
 * ★★ 四个决定：
 *
 * ① **有没有 `combat.attacker` 就是"凶不凶"**，不额外加 `aggressive` 开关。
 *    模板里 `damage: 0` 的生物不挂攻击组件，于是它只漫游 ——
 *    "配了伤害却永远不出手"的怪是配置错误，不该用一个布尔把它合法化。
 *
 * ② **漫游必须是 `(seed, id, epoch)` 的纯函数**，不用状态、不用 `Math.random`。
 *    同一个种子跑两遍，生物走同一条路 —— 否则回放与"同种子同世界"都失效，
 *    而症状只是"这次跑起来和上次不一样"，没人能复现。
 *
 * ③ **友军不追**（`stanceOf === "ally"`），中立照追。
 *    把"中立"也排除掉会让新加的阵营（还没配关系）变成谁都不理的摆设；
 *    而 `stanceOf` 已经把"同队/表/默认中性"三件事写死在一处。
 *
 * ④ **同一 tick 只感知一次**（按 `(agentId, tick)` 记住上一次结果）。
 *    宿主每 tick 要向两个模块各问一次；不缓存就是两倍的"遍历整棵树"，
 *    而二十只生物 × 每 tick 两次 = 一秒一千多次全树扫描，画面上只表现为"有点卡"。
 *
 * ⑤ **决策的执行者是树，不是 `if`**（`mob-tree.ts`）。这个文件只负责
 *    「把世界读成事实」，之后交给 `MobTree.decide`。`chooseFromFacts` 留着，
 *    身份是**语义规范**：树是它的编译产物，判据逐条对账两者。
 *    于是「给这只怪换一套脾气」= 传一棵树，不改这里的任何一行。
 */

import type { Scene } from "../../core/scene/scene.ts";
import type { AiNode, AiOps } from "../ai/behavior.ts";
import { ATTACKER_TYPE } from "../combat/attack.ts";
import { type Factions, teamOf } from "../combat/faction.ts";
import { HEALTH_TYPE } from "../combat/health.ts";
import { Perception } from "../ai/perception.ts";
import { isDead, type Health } from "../combat/health.ts";
import type { ThreatTable } from "../combat/threat.ts";
import {
  wanderTarget,
  type Decision,
  type MobCandidate,
  type MobFacts,
  type MobGrid,
  type MobGrudge,
} from "./mob-facts.ts";
import { createMobTree, type MobTree } from "./mob-tree.ts";

/** 大脑参数不合法（半径、视野、漫游周期）。 */
export const MOB_BAD_BRAIN = "MOB.BAD_BRAIN";

export interface MobBrainOptions {
  readonly factions: Factions;
  /** 感知半径（世界单位）。 */
  readonly range: number;
  /** 漫游半径（格，默认 4）。 */
  readonly wanderRadiusCells?: number;
  /** 多少 tick 换一次漫游目标（默认 24）。**不影响"追人"**：追人每 tick 重算。 */
  readonly wanderEvery?: number;
  /** 追出多少格就放弃（默认 0 = 不限）。用**格**而不是世界单位：与导航同一套坐标。 */
  readonly leashCells?: number;
  /** 感知什么组件（默认只看血量：能被打的东西才值得追）。 */
  readonly watch?: readonly string[];
  /**
   * 仇恨表（给了才会"记仇"；不给 = 只靠看见，与批69 之前完全一致）。
   *
   * ★ 为什么记忆在**大脑之外**：同一张仇恨表要同时被"移动"与"战斗"两个子模块
   *   共享，而且它要在生物**被销毁之后**仍然能被清理（`forget`）。
   *   塞进大脑会变成"每个大脑记自己的"，而大脑是每个世界一份、不是每只生物一份。
   */
  readonly threat?: ThreatTable;
  /** 记仇的追击半径（格；默认 `leashCells`，0 = 不限）。 */
  readonly aggroCells?: number;
  readonly seed?: number;
  /**
   * 换一棵决策树（**「给角色配 AI」的唯一入口**，见文件头 ⑤）。
   * 缺省 `MOB_TREE`：记仇 > 看见 > 漫游。
   */
  readonly tree?: AiNode;
  /** 与 `tree` 配套的 op 表（树里写了新 op 就要一起给）。缺省 `MOB_OPS`。 */
  readonly ops?: AiOps;
}

/**
 * 类型都搬到了 `mob-facts.ts`（黑板 = 纯数据），这里只为保持既有 import 路径不变而转出。
 * 判据与外部代码继续 `import type { Decision } from "./mob-brain.ts"` 即可。
 */
export type { Decision, DecisionReason, MobCandidate, MobFacts, MobGrid } from "./mob-facts.ts";

export class MobBrain {
  private readonly o: Required<Omit<MobBrainOptions, "watch" | "threat" | "tree" | "ops">> & {
    watch: readonly string[];
    threat: ThreatTable | null;
  };
  private readonly perception: Perception;
  /** 决策树（见文件头 ⑤）。一根大脑一棵，服务这个世界里**全部**生物。 */
  private readonly mobTree: MobTree;
  /**
   * 见文件头 ④。**按 `id → 决定` 存一整张表**，不是只存"上一次"：
   * `move` 与 `combat` 是两个模块，它们各自遍历全部生物 ——
   * 只记最后一条的话，第二次遍历的第一只就已经把缓存冲掉了
   *（于是"缓存"实际只对同一只生物连续问两次才生效，而这几乎不发生）。
   */
  private cacheTick = Number.NaN;
  /**
   * 缓存的是「看到什么」，不是「决定什么」。
   *
   * ★ 只留一份缓存：两份（facts + decision）一定会有不同步的那一刻，
   *   而那一刻的症状是「同一 tick 两次问给两个答案」—— 恰好是最难复现的一类。
   *   决定由 facts 算出来（`chooseFromFacts` 是 O(1) 纯函数），不需要缓存。
   */
  private factsCache = new Map<number, MobFacts>();
  private senses = 0;

  constructor(options: MobBrainOptions) {
    if (!(options.range > 0) || !Number.isFinite(options.range)) {
      throw new RangeError(`${MOB_BAD_BRAIN}: 感知半径必须是 > 0 的有限数，得到 ${String(options.range)}`);
    }
    const wr = options.wanderRadiusCells ?? 4;
    if (!Number.isInteger(wr) || wr <= 0) {
      throw new RangeError(`${MOB_BAD_BRAIN}: wanderRadiusCells 必须是正整数，得到 ${String(wr)}`);
    }
    const we = options.wanderEvery ?? 24;
    if (!Number.isInteger(we) || we <= 0) {
      throw new RangeError(`${MOB_BAD_BRAIN}: wanderEvery 必须是正整数，得到 ${String(we)}`);
    }
    const leash = options.leashCells ?? 0;
    if (!Number.isInteger(leash) || leash < 0) {
      throw new RangeError(`${MOB_BAD_BRAIN}: leashCells 必须是 >= 0 的整数，得到 ${String(leash)}`);
    }
    const aggro = options.aggroCells ?? leash;
    if (!Number.isInteger(aggro) || aggro < 0) {
      throw new RangeError(`${MOB_BAD_BRAIN}: aggroCells 必须是 >= 0 的整数，得到 ${String(aggro)}`);
    }
    this.o = {
      factions: options.factions,
      range: options.range,
      wanderRadiusCells: wr,
      wanderEvery: we,
      leashCells: leash,
      aggroCells: aggro,
      threat: options.threat ?? null,
      watch: options.watch ?? [HEALTH_TYPE],
      seed: options.seed ?? 1,
    };
    this.perception = new Perception({ range: this.o.range, watch: this.o.watch });
    // 坏树在这里抛（`MOB.BAD_TREE`）：那是配置错误，不该等第 500 拍才炸
    this.mobTree = createMobTree({ tree: options.tree, ops: options.ops });
  }

  /** 感知调用次数（判据用它证"同一 tick 只算一次"）。 */
  get senseCount(): number {
    return this.senses;
  }

  /** 当前这棵树（编辑器 / 面板要显示「这只怪在跑哪棵树」）。 */
  get tree(): AiNode {
    return this.mobTree.tree;
  }

  /**
   * 树上还记着几处 `running`。**恒为 0** —— 决策树是瞬时的。
   * 非 0 说明有人往树里塞了 `wait`：那不是风格问题，那是「决定带上了不在快照里的历史」。
   */
  treeMemory(): number {
    return this.mobTree.memorySize();
  }

  /**
   * 决定这一 tick 干什么（= 感知一次 + 纯函数决策）。
   *
   * @returns `null` = 什么都不用做（找不到自己 / 没有可走的漫游格）。
   */
  decide(scene: Scene, agentId: number, tick: number, grid: MobGrid): Decision | null {
    // 见文件头 ④：同一 tick 同一 id 复用（感知是这里最贵的一步）
    if (this.cacheTick !== tick) {
      this.cacheTick = tick;
      this.factsCache.clear();
    }
    let f = this.factsCache.get(agentId);
    if (f === undefined) {
      f = this.sense(scene, agentId, tick, grid);
      this.factsCache.set(agentId, f);
    }
    // 见文件头 ⑤：决定由树算（纯函数，不吃 dt、不留跨拍记忆）
    return this.mobTree.decide(f);
  }

  /**
   * 最近一次感知到的世界事实（调试面板用它显示「它看见了什么、为什么这么决定」）。
   *
   * ★ 返回的是**当拍**的事实：`tick` 与当前 `cacheTick` 不同时返回 `undefined`，
   *   而不是「上一拍的旧事实」。旧事实会让面板显示一只已经改主意的生物。
   */
  facts(agentId: number): MobFacts | undefined {
    const f = this.factsCache.get(agentId);
    if (f === undefined || f.tick !== this.cacheTick) return undefined;
    return f;
  }

  /** 把世界读成事实（**本文件唯一读场景的地方**，除 `avenge` 的仇恨表查询）。 */
  private sense(scene: Scene, agentId: number, tick: number, grid: MobGrid): MobFacts {
    const self = scene.find(agentId);
    if (self === undefined) {
      return { agentId, tick, selfCell: -1, aggressive: false, grudge: null, visible: [], wanderCell: -1 };
    }
    const selfCell = grid.cellAt(self.worldPosition.x, self.worldPosition.y);
    const me = teamOf(scene, agentId).team;
    // 见文件头 ①：没有攻击组件 = 和平生物，只漫游（连感知都不做）
    const aggressive = self.get(ATTACKER_TYPE) !== undefined;

    let grudge: MobGrudge | null = null;
    let visible: MobCandidate[] = [];
    if (aggressive) {
      // ---- 仇恨优先于感知：打了就跑的人**仍然**被追（这才是「记忆」的意义）
      //      放在感知之前，是因为感知会跳过「看不见但打过我」的人；
      //      反过来（先感知）的话，记仇只在「恰好还看得见」时生效，等于没有记忆。
      grudge = this.avenge(scene, agentId, tick, grid, me);
      if (grudge === null) {
        this.senses++;
        const sensed = this.perception.sense(scene, agentId, tick);
        if (sensed.ok) visible = this.filterSensed(scene, sensed.value, grid, me);
      }
    }

    // 见文件头 ③：漫游目标只在「用得上」时算（有仇人 / 看得见人时用不到）
    const wanderCell =
      grudge === null && visible.length === 0
        ? wanderTarget(grid, selfCell, agentId, tick, {
            seed: this.o.seed,
            radiusCells: this.o.wanderRadiusCells,
            every: this.o.wanderEvery,
          })
        : -1;

    return { agentId, tick, selfCell, aggressive, grudge, visible, wanderCell };
  }

  /**
   * 感知结果的过滤（友军 / 超 leash / 不在地图上）。
   *
   * ★ 过滤留在感知这一侧而不是决策那一侧：这些条件讲的是「我这只生物够得着什么」，
   *   属于感知的语义。留在决策里的话，同一份黑板喂给玩家控制的角色时行为会不同。
   * ★ 顺序沿用 `Perception` 给的排序（距离平方升序、同距离按节点 id 升序），
   *   这里**不重排** —— 重排就是第二份排序规则，两份迟早不一致。
   */
  private filterSensed(
    scene: Scene,
    sensed: readonly { readonly nodeId: number; readonly x: number; readonly z: number; readonly dist2: number }[],
    grid: MobGrid,
    me: string,
  ): MobCandidate[] {
    const out: MobCandidate[] = [];
    for (const s of sensed) {
      // 见文件头 ③
      const other = teamOf(scene, s.nodeId).team;
      if (this.o.factions.stanceOf(me, other) === "ally") continue;
      if (this.o.leashCells > 0 && s.dist2 > this.o.leashCells * this.o.leashCells) continue;
      const cell = grid.cellAt(s.x, s.z);
      if (cell < 0) continue;
      out.push({ nodeId: s.nodeId, cell, dist2: s.dist2 });
    }
    return out;
  }

  /**
   * 从仇恨表里挑出"要追的那个人"（`null` = 没有人打过我 / 都忘了 / 都够不着）。
   *
   * ★ 三个过滤都必须有：
   *   · 已经没有血量组件（被销毁/从没活过）→ 不追。否则会朝一个不存在的 id 走一辈子；
   *   · 已经死了但节点还在（`hp === 0`）→ 不追。否则尸体会把一群生物钉在原地；
   *   · 友军 → 不追。否则"打错人"会让整队人内讧（批65 的阵营就白做了）。
   * ★ 距离用**格**（与 leash 同一套坐标），不是世界单位：
   *   记仇的追击半径是"跑出几个格子就放弃"，那是地图概念。
   */
  private avenge(
    scene: Scene,
    agentId: number,
    tick: number,
    grid: MobGrid,
    me: string,
  ): MobGrudge | null {
    const t = this.o.threat;
    if (t === null) return null;
    const targetId = t.best(agentId, tick, (id) => {
      const n = scene.find(id);
      if (n === undefined || n === null || !n.activeInHierarchy) return false;
      const hp = n.get<Health>(HEALTH_TYPE);
      if (hp === undefined || isDead(hp)) return false;
      return this.o.factions.stanceOf(me, teamOf(scene, id).team) !== "ally";
    });
    if (targetId === null) return null;
    const target = scene.find(targetId);
    if (target === undefined || target === null) return null;
    const cell = grid.cellAt(target.worldPosition.x, target.worldPosition.y);
    if (cell < 0) return null;
    if (this.o.aggroCells > 0) {
      const self = scene.find(agentId);
      if (self === undefined) return null;
      const dx = target.worldPosition.x - self.worldPosition.x;
      const dz = target.worldPosition.y - self.worldPosition.y;
      if (dx * dx + dz * dz > this.o.aggroCells * this.o.aggroCells) return null;
    }
    return { nodeId: targetId, cell };
  }

}

export function createMobBrain(options: MobBrainOptions): MobBrain {
  return new MobBrain(options);
}

/** 把大脑接到 `move` 模块的 `decide` 上（只要"想去哪一格"）。 */
export function moveDecider(brain: MobBrain, scene: Scene, grid: MobGrid): (agentId: number, tick: number) => number | null {
  return (agentId, tick) => brain.decide(scene, agentId, tick, grid)?.cell ?? null;
}

/** 把大脑接到 `combat` 模块的 `decide` 上（只要"想打哪个节点"）。 */
export function combatDecider(brain: MobBrain, scene: Scene, grid: MobGrid): (agentId: number, tick: number) => number | null {
  return (agentId, tick) => {
    const d = brain.decide(scene, agentId, tick, grid);
    return d !== null && d.kind === "hunt" ? d.targetNodeId : null;
  };
}
