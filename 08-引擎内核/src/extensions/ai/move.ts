/**
 * L4 · AI 移动（阶段 3：**从"盯着"到"走过去"**）
 *
 * 链条的前三段已经有了：看见什么（`perception.ts`）、盯谁（`targeting.ts`）、谁去（`team.ts`）。
 * 这一段把它们接到真实位移上：**目标格 → 路径 → 每 tick 挪一点**。
 *
 * ★ 为什么 `decide` 是回调而不是内建策略：
 *   引擎不该规定"怪物先追谁、追不到怎么办"。本文件只负责
 *   "给定想去哪一格，把它走过去，并且不要做蠢事"。策略留在调用方
 *   （未来的怪物 AI / 编辑器 PIE / 测试语料），于是三块逻辑可以分别演进。
 *
 * ★★ 五个刻意的设计决定（每条都对应一类"看起来在动、其实坏了"的失效）：
 *
 * ① **不可达要退避**。目标在海对面时 `findPath` 每 tick 都失败 ——
 *    一次 A* 可能展开上万格，二十只怪就是二十倍的每帧开销，
 *    而画面上只是"它们站着不动"。所以失败记 `(goalCell, retryTick)`，
 *    退避窗口内不再算路。**退避不是放弃**：窗口过了会重试（目标可能被桥接通了）。
 *
 * ② **到达后不重算**。目标没变、路已走完 ⇒ 这一 tick 什么都不做。
 *    不这样写的话，站在目标上会每 tick 跑一次 A*，得到一条长度为 1 的路径再走 0 距离。
 *    这个 bug 不会让任何位置判据变红，只会让 CPU 在无事可做时最忙。
 *
 * ③ **卡住要有出口**。物理挤在一起、路点被占、速度被改小 —— 都会表现成
 *    "`moved` 一直是 0 而路径还没走完"。连续 `stuckTicks` 次没挪动就**丢弃当前路径重算**，
 *    否则这只怪会永远停在原地等一个不会变的路点。
 *
 * ④ **决定谁先动要排序**。`componentsOf` 的遍历序是存储序，虽然同一份存档下稳定，
 *    但"谁先占位、谁被挤开"会让最终位置有细微差别。按节点 id 升序驱动，
 *    再加一层写死的顺序 —— 回放只认字节。
 *
 * ⑤ **坐标用世界坐标读、用增量写**。见 `step()` 里的注释：直接写 `localPosition`
 *    在"代理挂在有位移的父节点下"时会走错方向，而世界坐标读出来是对的，
 *    所以取"世界坐标的增量"回写到 local —— 父级只有平移（最常见）时两者等价。
 *
 * ⑥ **一拍之内的位移要夹到"第一次接触"之前**（[ADR-0013](docs/adr/0013-continuous-collision.md)）。
 *    导航格只知道地形，不知道物理障碍：`speed * dt` 一跨 0.05 宽的箱子，
 *    起终点都不重叠 ⇒ `resolve()` 永远推不回来，看起来就是「这只怪偶尔穿过箱子」。
 *    所以每 tick 的位移在**落笔之前**过一次扫掠，撞上就停在接触点前。
 *    ★ 夹住之后**游标不前进**：没走到那个路点，下一 tick 还得朝它走。
 *      一直走不动就交给卡住检测（③）去丢路径重算 —— 那才是"路被挡住了"的出口，
 *      如果让游标照常前进，怪会贴着墙一路"空走"到终点再宣布到达。
 *
 * ⑦ **朝向跟的是"实际挪了多少"，不是"想去哪"**。
 *    节点上有 `motion.facing` 时，这一拍拿**真实位移**去转（`faceTo`），
 *    限速由 `turnRate` 决定。三个后果都是想要的：
 *      · 被物理挡住的那一拍位移为 0 ⇒ 朝向不动（贴着墙原地转身是最假的动作）；
 *      · 绕角走时朝向是**路的方向**而不是"目标方向"，精灵与视野锥都跟着路走；
 *      · 限速大于 0 时，"瞬时对准"不存在 —— 否则视野锥等于全向（见 `motion/facing.ts`）。
 *    ★ 没有 `motion.facing` 的节点**一个字节都不变**：老内容/老存档行为不变，
 *      这也是这条接线可以放心加在核心移动循环里的原因。
 */

import { Component, FieldType, type ComponentSchema } from "../../core/scene/component.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Scene } from "../../core/scene/scene.ts";
import type { Node } from "../../core/scene/node.ts";
import { Services } from "../../core/tokens.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { FACING_TYPE, type Facing } from "../motion/facing.ts";
import type { NavGrid } from "../nav/nav-grid.ts";
import { cellStep } from "../motion/intent.ts";

/** 会自己走路的代理。 */
export const MOVER_TYPE = "ai.mover";
/** 配置非法。 */
export const AI_BAD_MOVE = "AI.BAD_MOVE";

/**
 * 停在接触点**之前**留的缝（世界单位）。
 *
 * ★ 恰好相切在浮点上是五五开：下一 tick 的扫掠可能把 `t` 报成 0，
 *   而 0 的语义是"起点已重叠" ⇒ 这一拍不动 ⇒ 看起来像"被墙吸住、推都推不动"。
 *   留一条缝之后，下一 tick 是一个**正**的 `t`，夹到 0 与"没碰到"可以区分。
 */
export const SWEEP_SKIN = 1e-3;

/**
 * 扫掠命中。与 `physics/sweep.ts` 的 `SweepHit` **同形**，但这里不 import 它：
 * AI 层不该为了一个四字段的记录依赖物理层（顺序是 physics ← ai）。
 * 结构化类型让 `world.sweepMove` 直接能传进来，判据里也能传假实现。
 */
export interface MoveSweepHit {
  /** 接触时刻，`[0, 1]`：这一步的位移参数。 */
  readonly t: number;
  /** 接触法线（指向"把圆推出去"的方向）。 */
  readonly nx: number;
  readonly nz: number;
  /** 碰到的节点 id（诊断用）。 */
  readonly nodeId: number;
}

export class Mover extends Component {
  /** 每秒走多少世界单位。 */
  speed = 2.2;

  readonly schema: ComponentSchema = {
    type: MOVER_TYPE,
    fields: { speed: FieldType.Float },
    /**
     * 回滚快照才带的运行期状态（批151）。
     *
     * ★★ 这份清单与下面那段注释并不矛盾，因为它们是**两种语义**：
     *   · **存档**：局面可能已经变了 ⇒ 路径是过期的 ⇒ 存进去会让读档后沿老路走；
     *   · **回滚到 tick N**：局面与 N 完全一致 ⇒ 路径不是过期的，是必须一致的，重算会分叉。
     *   所以它们不是「该不该进档」，而是「进哪种档」—— 由 `saveScene(scene, {mode})` 决定。
     *
     * ★ 为什么六个别都在这儿，而不只是 `path` / `cursor`：
     *   判据问的是「回滚之后下一拍会不会走出不同的路」。凡是**影响下一拍**的状态都得在，
     *   而这条路径上有两处历史：`failCell`/`retryTick`（算路失败后的退避）与
     *   `stuckTicks`（连续没挪动的计数，到阈值就丢路径重算）。漏掉它们的症状是
     *   「回滚之后这只怪多转了一次身」—— 位置差一格，无人报错。
     *
     * ★ 新增运行期状态时**必须回来加**。`snapshot-any-tick.test.ts` 里有一条对账判据：
     *   把 `Mover` 上所有非 schema 字段与这份清单求差集，差集非空就红 —— 它不判断
     *   「这个字段该不该进」，只保证「加了字段没声明」这件事不会静默发生。
     */
    rollback: ["path", "cursor", "goalCell", "arrived", "failCell", "retryTick", "stuckTicks"],
  };

  // ---- 以下全部是**运行期状态**，不进 `fields`（= 不进存档、不进指纹）。
  //      它们进**回滚快照**（`rollback` 清单），两种语义的区别见上面那段注释。
  /** 当前路径（格子下标序列）。 */
  path: number[] = [];
  /** 下一个要去的路点下标。 */
  cursor = 0;
  /** 当前路径对应的目标格；-1 = 没有目标。 */
  goalCell = -1;
  /** 已经走到目标上了（等目标变化再重算）。 */
  arrived = false;
  /** 上次算路失败的目标格与退避截止 tick（见文件头 ①）。 */
  failCell = -1;
  retryTick = 0;
  /** 连续没挪动的 tick 数（见文件头 ③）。 */
  stuckTicks = 0;
}

export function registerMoverComponent(registry: {
  has(t: string): boolean;
  register(s: ComponentSchema, f: () => Component): void;
}): void {
  if (!registry.has(MOVER_TYPE)) registry.register(new Mover().schema, () => new Mover());
}

export interface MoveStats {
  /** 带 `ai.mover` 的代理数。 */
  readonly agents: number;
  /** 这一 tick 真的挪动了的代理数。 */
  readonly moving: number;
  /** 这一 tick 走到目标上的代理数。 */
  readonly arrived: number;
  /** 没有目标（`decide` 返回 null）的代理数。 */
  readonly idle: number;
  /** 累计：算路成功次数（诊断"是不是每 tick 都在算"）。 */
  readonly paths: number;
  /** 累计：算路失败次数。 */
  readonly unreachable: number;
  /** 累计：因卡住而丢弃路径的次数。 */
  readonly stuck: number;
  /** 累计：被**物理障碍**挡住的次数（扫掠夹到了接触点，见文件头 ⑥）。 */
  readonly blocked: number;
}

export interface MoveModuleOptions {
  readonly grid: NavGrid;
  /**
   * 返回"想去哪一格"（格子下标）；`null` = 这一 tick 不动。
   * 越界/不可站的返回值按"不可达"处理（会退避，不会崩）。
   */
  readonly decide: (agentNodeId: number, tick: number) => number | null;
  readonly id?: string;
  /** 连续多少 tick 没挪动算卡住（默认 12）。 */
  readonly stuckTicks?: number;
  /** 一 tick 挪动小于这个距离算"没动"（默认 1e-3）。 */
  readonly stuckEps?: number;
  /** 算路失败后多少 tick 内不重试（默认 30）。 */
  readonly retryTicks?: number;
  /**
   * 连续碰撞：这一拍从当前位置走 `(dx, dz)` 会不会撞上静态障碍（见文件头 ⑥）。
   * 不传 = 不扫掠（老行为：一格一格地挪，快不起来也穿不过去）。
   * `IPhysicsWorld.sweepMove` 直接能传进来 —— 它只回答、不改位置。
   */
  readonly sweep?: (nodeId: number, dx: number, dz: number) => MoveSweepHit | null;
}

export interface MoveModuleHandle extends IModule {
  update(tick: number, dt: number): void;
  readonly stats: MoveStats;
  /** 诊断：某个代理当前的路径（副本）。 */
  pathOf(nodeId: number): readonly number[];
}

export function createMoveModule(opts: MoveModuleOptions): MoveModuleHandle {
  const { grid } = opts;
  const stuckLimit = opts.stuckTicks ?? 12;
  const stuckEps = opts.stuckEps ?? 1e-3;
  const retryTicks = opts.retryTicks ?? 30;

  let scene: Scene | null = null;
  let paths = 0;
  let unreachable = 0;
  let stuck = 0;
  let blocked = 0;
  let moving = 0;
  let arrived = 0;
  let idle = 0;

  /**
   * 把这一拍的位移夹到**第一次接触之前**（见文件头 ⑥）。
   * 没注入 `sweep`、或者没碰到 ⇒ 原样返回目标点。
   */
  function clampToContact(
    nodeId: number,
    fromX: number,
    fromZ: number,
    toX: number,
    toZ: number,
  ): { x: number; z: number; hit: MoveSweepHit | null } {
    const sweep = opts.sweep;
    if (sweep === undefined) return { x: toX, z: toZ, hit: null };
    const dx = toX - fromX;
    const dz = toZ - fromZ;
    const len = Math.hypot(dx, dz);
    if (!(len > 0)) return { x: toX, z: toZ, hit: null };
    const hit = sweep(nodeId, dx, dz);
    if (hit === null) return { x: toX, z: toZ, hit: null };
    const back = Math.max(0, hit.t - SWEEP_SKIN / len);
    return { x: fromX + dx * back, z: fromZ + dz * back, hit };
  }

  const handle: MoveModuleHandle = {
    id: opts.id ?? "ai.move",
    get stats(): MoveStats {
      const s = scene;
      return {
        agents: s === null ? 0 : [...s.componentsOf<Mover>(MOVER_TYPE)].length,
        moving,
        arrived,
        idle,
        paths,
        unreachable,
        stuck,
        blocked,
      };
    },
    pathOf(nodeId: number): readonly number[] {
      const s = scene;
      if (s === null) return [];
      for (const m of s.componentsOf<Mover>(MOVER_TYPE)) {
        if (m.node?.id === nodeId) return m.path.slice();
      }
      return [];
    },
    init(ctx: ModuleContext): Result<void, EngineError> {
      const got = ctx.services.get(Services.Scene);
      if (got === undefined) {
        return err(engineError(AI_BAD_MOVE, "移动模块需要一个 Scene（先注册 Services.Scene）"));
      }
      scene = got;
      return ok(undefined);
    },
    update(tick: number, dt: number): void {
      const s = scene;
      if (s === null) return;
      moving = 0;
      arrived = 0;
      idle = 0;

      const agents = [...s.componentsOf<Mover>(MOVER_TYPE)];
      // 见文件头 ④：按节点 id 升序驱动
      agents.sort((a, b) => (a.node?.id ?? -1) - (b.node?.id ?? -1));

      for (const m of agents) {
        const node = m.node;
        if (node === null || !node.activeInHierarchy) continue;
        if (!(m.speed > 0) || !Number.isFinite(m.speed)) {
          // 速度没配好：不动、也不算卡住（卡住是"该动却动不了"）
          idle++;
          continue;
        }

        const goal = opts.decide(node.id, tick);
        if (goal === null) {
          m.path.length = 0;
          m.cursor = 0;
          m.goalCell = -1;
          m.arrived = false;
          idle++;
          continue;
        }

        // ---- 目标没变且已到达：什么都不做（见文件头 ②）
        if (m.arrived && goal === m.goalCell) {
          idle++;
          continue;
        }
        // ---- 退避窗口内不重算（见文件头 ①）
        if (goal === m.failCell && tick < m.retryTick) {
          idle++;
          continue;
        }
        // ---- 目标变了（或还没算过路）⇒ 重算
        if (goal !== m.goalCell || m.path.length === 0) {
          if (!plan(m, node, goal, tick)) {
            idle++;
            continue;
          }
        }

        const wp = node.worldPosition;
        const cursorBefore = m.cursor;
        // ★ 批147：位移这一步走 `motion/intent.ts` 的 `cellStep`，与玩家那条路共用同一个
        //   「意图 → 位移」实现。这里只负责把「目标格」包成意图、并交进当前寻路状态；
        //   寻路本身仍在本文件（有缓存与失效，不该塞进纯函数）。
        const r = cellStep(
          { kind: "move.cell", cell: goal },
          { grid, path: m.path, cursor: m.cursor, x: wp.x, z: wp.y, speed: m.speed, dt },
        );
        m.cursor = r.cursor;
        // 见文件头 ⑥：落笔之前先夹到接触点（物理障碍不在导航格上）
        const aim = clampToContact(node.id, wp.x, wp.y, wp.x + r.dx, wp.y + r.dz);
        if (aim.hit !== null) {
          // 没走到那个路点 ⇒ 游标不前进（见文件头 ⑥ 的后半句）
          m.cursor = cursorBefore;
          blocked++;
        }
        const stepX = aim.x - wp.x;
        const stepZ = aim.z - wp.y;
        const movedNow = Math.hypot(stepX, stepZ);
        if (movedNow > 0) {
          // 见文件头 ⑤：把世界坐标的增量回写到 local
          const lp = node.localPosition;
          node.setLocalPosition(lp.x + stepX, lp.y + stepZ);
          moving++;
          // 见文件头 ⑦：朝向跟**实际位移**走。被挡住的那一拍游标会回退、位移为 0，
          // 于是这条 `movedNow > 0` 守卫就是「没动就不转身」的唯一一处保证。
          const facing = node.get<Facing>(FACING_TYPE);
          if (facing !== undefined) facing.faceTo(stepX, stepZ, facing.maxTurn(dt));
        }

        // ★ 被挡住时不许宣布到达：`r.done` 说的是"预算走完了这条路"，
        //   而实际位移被夹在半路上 —— 那正是"贴着墙空走到终点"的来源。
        if (aim.hit === null && r.done) {
          m.arrived = true;
          m.stuckTicks = 0;
          arrived++;
          continue;
        }

        // ---- 卡住检测（见文件头 ③）
        if (movedNow <= stuckEps) {
          m.stuckTicks++;
          if (m.stuckTicks >= stuckLimit) {
            m.path.length = 0;
            m.cursor = 0;
            m.goalCell = -1;
            m.arrived = false;
            m.stuckTicks = 0;
            stuck++;
          }
        } else {
          m.stuckTicks = 0;
        }
      }
    },
    describe(): string {
      return `AI 移动：${String(moving)} 个代理在走，累计算路 ${String(paths)} 次 / 不可达 ${String(unreachable)} 次 / 被物理挡住 ${String(blocked)} 次`;
    },
  };

  /** 算一次路并写进代理状态；失败写退避窗口。返回是否成功。 */
  function plan(m: Mover, node: Node, goal: number, tick: number): boolean {
    const wp = node.worldPosition;
    const from = grid.cellAt(wp.x, wp.y);
    if (from < 0) {
      // 代理跑到地图外了（传送/坐标 bug）：按不可达处理，不要静默吸附到别处
      m.failCell = goal;
      m.retryTick = tick + retryTicks;
      unreachable++;
      return false;
    }
    const res = grid.findPath(from, goal);
    if (!res.ok) {
      m.failCell = goal;
      m.retryTick = tick + retryTicks;
      m.path.length = 0;
      m.cursor = 0;
      m.goalCell = -1;
      m.arrived = false;
      unreachable++;
      return false;
    }
    const p = res.value;
    m.path = p.cells.slice();
    // 路径第一格就是当前格时，游标从 1 开始（否则会"先走回格子中心"）
    m.cursor = p.cells.length > 0 && p.cells[0] === from ? 1 : 0;
    m.goalCell = goal;
    m.arrived = false;
    m.stuckTicks = 0;
    m.failCell = -1;
    m.retryTick = 0;
    paths++;
    return true;
  }

  return handle;
}
