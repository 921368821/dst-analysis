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
 *
 * ⑥ **「用哪棵树」按实体取**（`ai-config.ts` 的 `mobs.ai` 组件，批155）。
 *    一根大脑服务世界里全部生物，所以树不能只挂在脑上 —— 否则「给这一只换脾气」
 *    只能靠换整个世界。这里按实体读组件 → 查 `TreeLibrary` → 用**编译好的实例**
 *    （缓存按树 id，不按实体：同种怪共享一份树与一块板，而板每拍先 `clear`）。
 *    ★ 缺 id **不抛**：一只怪的树被删了不该让整局崩，但必须被数出来（`treeMissing()`）
 *      并在面板上标 `missing` —— 降级路径要有面板 + 计数 + 判据三件套。
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
import { MOB_OPS, createMobTree, type MobTree } from "./mob-tree.ts";
import { TreeLibrary, type TreeLookup } from "./tree-library.ts";
import { treeIdOf } from "./ai-config.ts";

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
  /**
   * 树库（`id → 树`，批155）。给了就会按实体读 `mobs.ai` 组件决定用哪棵树。
   *
   * ★ 与 `tree` **互斥**（同时给会抛 `MOB_BAD_BRAIN`）：两者都是「缺省树」的来源，
   *   同时存在就必须回答「哪个赢」，而任何一种回答都会在某次热重载后变成 bug。
   *   想「换缺省树」→ 把树 `put` 进库并用它的 id 配组件；想「整根脑子换一棵」→ 只给 `tree`。
   */
  readonly library?: TreeLibrary;
}

/**
 * 类型都搬到了 `mob-facts.ts`（黑板 = 纯数据），这里只为保持既有 import 路径不变而转出。
 * 判据与外部代码继续 `import type { Decision } from "./mob-brain.ts"` 即可。
 */
export type { Decision, DecisionReason, MobCandidate, MobFacts, MobGrid } from "./mob-facts.ts";

/**
 * 「它这一拍照什么做的决定」——`explain()` 的产物，面板与判据共用。
 *
 * ★ `wanted` 与 `treeId` 分开：`wanted` 是配置里写的（可能是错的），
 *   `treeId` 是**实际跑的**那棵。合成一个字段的话，「配错了树」与「配对了」
 *   在面板上完全一样 —— 而那正是最需要看见的一刻。
 */
export interface MobExplain {
  readonly nodeId: number;
  readonly tick: number;
  /** 配置里写的树 id（`""` = 没配）。 */
  readonly wanted: string;
  /** 实际用的树 id（缺 id 时是内置树）。 */
  readonly treeId: string;
  readonly treeSource: "asset" | "default" | "missing";
  readonly decision: Decision | null;
  readonly facts: MobFacts;
  /** 这一拍黑板上的全部键（`mob-tree.ts` 的 `K`）。 */
  readonly board: Readonly<Record<string, number>>;
}

export class MobBrain {
  private readonly o: Required<Omit<MobBrainOptions, "watch" | "threat" | "tree" | "ops" | "library">> & {
    watch: readonly string[];
    threat: ThreatTable | null;
  };
  private readonly perception: Perception;
  /** 树库（id → 已校验的树）。没给就按 `options.tree` 建一个只含内置树的。 */
  private readonly library: TreeLibrary;
  /** 建树用的 op 表（`createMobTree` 要用同一份）。 */
  private readonly ops: AiOps;
  /**
   * `树 id → 编译好的实例`（见文件头 ⑥）。
   * ★ 键是**树**不是实体：同种怪共享一份树与一块板（板每拍 `clear`，见 `mob-tree.ts` ②）。
   */
  private readonly trees = new Map<string, MobTree>();
  /** `trees` 是按哪个 revision 建的。库一变就整批作废（`tree-library.ts` 文件头 ②）。 */
  private treeRevision = -1;
  /** 引用过、但库里没有的树 id（去重；`treeMissing()` 读它）。 */
  private readonly missingTrees = new Set<string>();
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
    if (options.library !== undefined && options.tree !== undefined) {
      throw new RangeError(
        `${MOB_BAD_BRAIN}: 同时给了 library 与 tree —— 缺省树有两个来源（见 MobBrainOptions.library 的 ★）`,
      );
    }
    this.ops = options.ops ?? MOB_OPS;
    // 坏树在这里抛（`MOB.BAD_TREE`）：那是配置错误，不该等第 500 拍才炸
    this.library =
      options.library ??
      new TreeLibrary({
        ...(options.ops === undefined ? {} : { ops: options.ops }),
        ...(options.tree === undefined ? {} : { defaultTree: options.tree }),
      });
    this.perception = new Perception({ range: this.o.range, watch: this.o.watch });
  }

  /** 感知调用次数（判据用它证"同一 tick 只算一次"）。 */
  get senseCount(): number {
    return this.senses;
  }

  /**
   * **缺省树**（不是"某一只正在跑的树"）。
   *
   * ★ 批155 之前这个 getter 返回的是"唯一那棵"。现在每只生物可以有自己的树，
   *   所以它只能是缺省那棵；要看某一只的，用 `treeForAgent(scene, id)` 或 `explain`。
   */
  get tree(): AiNode {
    return this.library.resolve("").tree;
  }

  /** 树库（编辑器与判据要 `put` / 看 revision）。 */
  get treeLibrary(): TreeLibrary {
    return this.library;
  }

  /**
   * 树上还记着几处 `running`（**全部已编译的树加起来**）。**恒为 0** —— 决策树是瞬时的。
   * 非 0 说明有人往树里塞了 `wait`：那不是风格问题，那是「决定带上了不在快照里的历史」。
   */
  treeMemory(): number {
    let n = 0;
    for (const t of this.trees.values()) n += t.memorySize();
    return n;
  }

  /**
   * 被引用过、但库里没有的树有几棵（去重，见文件头 ⑥）。
   *
   * ★ 这是**降级路径的计数**：>0 说明场景里有人配了一个不存在的树 id，
   *   而那些生物正在用内置树跑 —— 看起来一切正常。
   */
  treeMissing(): number {
    return this.missingTrees.size;
  }

  /** 那些不存在的树 id（升序；面板要能指名道姓）。 */
  missingTreeIds(): readonly string[] {
    return [...this.missingTrees].sort();
  }

  /**
   * 这只生物这一拍用的树（id + 来源 + 树本身）。
   *
   * 纯查询：不改缓存、不改计数（计数在 `compiledTreeFor` 建缓存时做一次）。
   */
  treeForAgent(scene: Scene, agentId: number): TreeLookup {
    return this.library.resolve(treeIdOf(scene, agentId));
  }

  /**
   * 「它这一拍照什么做的决定」——面板与判据共用这一个入口。
   *
   * ★ 会**重跑一次决策**（纯函数，同 facts 同结果）：板是随树共享的，
   *   上一次写板的是上一只生物。读完 `decide` 立刻取板，才是这一只的数据。
   */
  explain(scene: Scene, agentId: number, tick: number, grid: MobGrid): MobExplain | null {
    const decision = this.decide(scene, agentId, tick, grid);
    const facts = this.facts(agentId);
    if (facts === undefined) return null;
    const { lookup, compiled } = this.compiledTreeFor(scene, agentId);
    return {
      nodeId: agentId,
      tick,
      wanted: lookup.wanted,
      treeId: lookup.id,
      treeSource: lookup.source,
      decision,
      facts,
      board: compiled.boardSnapshot(),
    };
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
    // 见文件头 ⑤ / ⑥：树按实体选，决定由树算（纯函数，不吃 dt、不留跨拍记忆）
    return this.compiledTreeFor(scene, agentId).compiled.decide(f);
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

  /**
   * 按实体取「编译好的树」（见文件头 ⑥）。
   *
   * 三件事按这个顺序：库变了就全作废 → 解析实体要的 id → 没编译过就编译。
   * ★ 缺 id 时缓存键用**默认树**的 id：编译出来的是同一棵树，
   *   而"哪只怪引用了坏 id"由 `missingTrees` 记着，不靠缓存键表达。
   */
  private compiledTreeFor(scene: Scene, agentId: number): { readonly lookup: TreeLookup; readonly compiled: MobTree } {
    if (this.library.revision !== this.treeRevision) {
      this.trees.clear();
      this.treeRevision = this.library.revision;
    }
    const lookup = this.library.resolve(treeIdOf(scene, agentId));
    if (lookup.source === "missing" && !this.missingTrees.has(lookup.wanted)) {
      this.missingTrees.add(lookup.wanted);
    }
    let compiled = this.trees.get(lookup.id);
    if (compiled === undefined) {
      compiled = createMobTree({ tree: lookup.tree, ops: this.ops });
      this.trees.set(lookup.id, compiled);
    }
    return { lookup, compiled };
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
