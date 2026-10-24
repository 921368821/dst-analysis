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
 */

import type { Scene } from "../../core/scene/scene.ts";
import { ATTACKER_TYPE } from "../combat/attack.ts";
import { type Factions, teamOf } from "../combat/faction.ts";
import { HEALTH_TYPE } from "../combat/health.ts";
import { Perception } from "../ai/perception.ts";
import { isDead, type Health } from "../combat/health.ts";
import type { ThreatTable } from "../combat/threat.ts";

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
}

export interface Decision {
  /** `hunt` = 有目标；`wander` = 闲逛。 */
  readonly kind: "hunt" | "wander";
  /** 要打/要追的节点；`wander` 时是 `-1`。 */
  readonly targetNodeId: number;
  /** 移动目标格（`move` 模块直接用这个）。 */
  readonly cell: number;
}

interface Grid {
  cellAt(x: number, z: number): number;
  cellX(index: number): number;
  cellZ(index: number): number;
  isWalkable(cx: number, cz: number): boolean;
}

/** 32 位混合：同 `(seed,id,epoch)` 必得同值，且相邻 epoch 不呈线性（否则生物会走直线）。 */
function mix32(a: number, b: number, c: number): number {
  let h = (a ^ 0x9e3779b9) >>> 0;
  h = (Math.imul(h ^ (b + 0x85ebca6b), 0xcc9e2d51) >>> 0) ^ (h >>> 13);
  h = (Math.imul(h ^ (c + 0xc2b2ae35), 0x1b873593) >>> 0) ^ (h >>> 15);
  return h >>> 0;
}

export class MobBrain {
  private readonly o: Required<Omit<MobBrainOptions, "watch" | "threat">> & {
    watch: readonly string[];
    threat: ThreatTable | null;
  };
  private readonly perception: Perception;
  /**
   * 见文件头 ④。**按 `id → 决定` 存一整张表**，不是只存"上一次"：
   * `move` 与 `combat` 是两个模块，它们各自遍历全部生物 ——
   * 只记最后一条的话，第二次遍历的第一只就已经把缓存冲掉了
   *（于是"缓存"实际只对同一只生物连续问两次才生效，而这几乎不发生）。
   */
  private cacheTick = Number.NaN;
  private cache = new Map<number, Decision | null>();
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
  }

  /** 感知调用次数（判据用它证"同一 tick 只算一次"）。 */
  get senseCount(): number {
    return this.senses;
  }

  /**
   * 决定这一 tick 干什么。
   *
   * @returns `null` = 什么都不用做（找不到自己 / 没有可走的漫游格）。
   */
  decide(scene: Scene, agentId: number, tick: number, grid: Grid): Decision | null {
    // 见文件头 ④：同一 tick 同一 id 复用
    if (this.cacheTick !== tick) {
      this.cacheTick = tick;
      this.cache.clear();
    }
    const hit = this.cache.get(agentId);
    if (hit !== undefined || this.cache.has(agentId)) return hit ?? null;

    const self = scene.find(agentId);
    if (self === undefined) {
      this.remember(agentId, tick, null);
      return null;
    }

    const homeCell = grid.cellAt(self.worldPosition.x, self.worldPosition.y);
    const me = teamOf(scene, agentId).team;

    // 见文件头 ①：没有攻击组件 = 和平生物，只漫游
    if (self.get(ATTACKER_TYPE) !== undefined) {
      // ----  hatred 优先于感知：打了就跑的人**仍然**被追（这才是「记忆」的意义）
      //      放在感知之前，是因为感知会跳过"看不见但打过我"的人；
      //      反过来（先感知）的话，记仇只在"恰好还看得见"时生效，等于没有记忆。
      const grudge = this.avenge(scene, agentId, tick, grid, me);
      if (grudge !== null) {
        this.remember(agentId, tick, grudge);
        return grudge;
      }
      this.senses++;
      const sensed = this.perception.sense(scene, agentId, tick);
      if (sensed.ok) {
        for (const s of sensed.value) {
          // 见文件头 ③
          const other = teamOf(scene, s.nodeId).team;
          if (this.o.factions.stanceOf(me, other) === "ally") continue;
          if (this.o.leashCells > 0 && s.dist2 > this.o.leashCells * this.o.leashCells) continue;
          const cell = grid.cellAt(s.x, s.z);
          if (cell < 0) continue;
          const d: Decision = { kind: "hunt", targetNodeId: s.nodeId, cell };
          this.remember(agentId, tick, d);
          return d;
        }
      }
      // 感知失败（自我不存在等）不该让生物停摆 —— 落到漫游
    }

    const cell = this.wanderCell(grid, agentId, tick, homeCell);
    const d: Decision | null = cell < 0 ? null : { kind: "wander", targetNodeId: -1, cell };
    this.remember(agentId, tick, d);
    return d;
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
    grid: Grid,
    me: string,
  ): Decision | null {
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
    return { kind: "hunt", targetNodeId: targetId, cell };
  }

  /**
   * 漫游目标格（见文件头 ②：纯函数）。
   *
   * ★ 取**第一个可走**的候选而不是"取最近的/最远的"：后者会让所有生物
   *   挤向同一片空地（同一个 epoch 的候选序是同一个函数），画面上像一队人。
   */
  private wanderCell(grid: Grid, agentId: number, tick: number, homeCell: number): number {
    if (homeCell < 0) return -1;
    const cx = grid.cellX(homeCell);
    const cz = grid.cellZ(homeCell);
    const r = this.o.wanderRadiusCells;
    const epoch = Math.floor(tick / this.o.wanderEvery);
    let h = mix32(this.o.seed, agentId, epoch);
    // 6 次尝试：半径 4 的方框里 81 格里总有可走的，除非它站在孤岛上
    for (let k = 0; k < 6; k++) {
      h = (Math.imul(h, 1664525) + 1013904223) >>> 0;
      const span = 2 * r + 1;
      const dx = (h % span) - r;
      const dz = (Math.floor(h / span) % span) - r;
      if (dx === 0 && dz === 0) continue;
      if (grid.isWalkable(cx + dx, cz + dz)) return this.cellIndex(grid, cx + dx, cz + dz);
    }
    return -1;
  }

  /** 用 `cellAt` 反查下标（避免再引入一个 `indexOf` 依赖）。 */
  private cellIndex(grid: Grid, cx: number, cz: number): number {
    // 格心坐标 → 下标
    return grid.cellAt(cx + 0.5, cz + 0.5);
  }

  private remember(agentId: number, tick: number, d: Decision | null): void {
    if (this.cacheTick !== tick) {
      this.cacheTick = tick;
      this.cache.clear();
    }
    this.cache.set(agentId, d);
  }
}

export function createMobBrain(options: MobBrainOptions): MobBrain {
  return new MobBrain(options);
}

/** 把大脑接到 `move` 模块的 `decide` 上（只要"想去哪一格"）。 */
export function moveDecider(brain: MobBrain, scene: Scene, grid: Grid): (agentId: number, tick: number) => number | null {
  return (agentId, tick) => brain.decide(scene, agentId, tick, grid)?.cell ?? null;
}

/** 把大脑接到 `combat` 模块的 `decide` 上（只要"想打哪个节点"）。 */
export function combatDecider(brain: MobBrain, scene: Scene, grid: Grid): (agentId: number, tick: number) => number | null {
  return (agentId, tick) => {
    const d = brain.decide(scene, agentId, tick, grid);
    return d !== null && d.kind === "hunt" ? d.targetNodeId : null;
  };
}
