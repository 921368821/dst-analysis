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
 * ④ **放物理体，但只放动态体**（批124；原来这一条写的是"不放"）。
 *    体是**每 tick 维护出来的不变量**（`syncBodies`），不是"init 时加一次"——
 *    物理表会在读档时被清空，而"清空之后忘了补"的症状是所有数字都对、只有画面变。
 *    给的是 `isStatic: false` 的圆体：于是它被树挡住、被玩家挡住、彼此也挡住，
 *    而"挡住"是 `resolve()` 的软推，不是扫掠的硬停（理由见 `MobWorldOptions.physics`
 *    的 ★，那里同时是 C18「动态障碍」三个问题的答案）。
 *
 * ⑤ **生物的移动不注入 `sweep`**。看起来是漏了，其实是量级问题：生物每拍最多走
 *    `speed × dt` = 3.0 / 30 = 0.1 单位，而最薄的障碍（半径 0.55 的树）加上体半径后
 *    接触距离 0.83~0.9 —— "一步跨过去"这件事根本不存在，扫掠没有可回答的问题。
 *    而扫掠在这条路上是**硬停**：`move` 的 `clampToContact` 夹到接触点、游标回退，
 *    症状是"顶着树抖"；软推会带一点切向分量，怪自己就滑过去了。
 *
 * ⑥ **障碍必须同时进导航**（`NavGrid.blockCells`，批124）。只放物理体是不够的：
 *    树摆在格中心、路点也是格中心，两者落在同一个点阵上 —— 导航若认为那格可走，
 *    怪就会**正对着树心**走，推力与走的方向正好相反、净位移 0。
 *    换句话说，"动态体"这件事真正的门槛不在物理层，而在**导航是否知道障碍存在**。
 */

import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { Services } from "../../core/tokens.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { createMoveModule, type MoveModuleHandle } from "../ai/move.ts";
import type { IPhysicsWorld } from "../physics/physics.ts";
import type { NavGrid } from "../nav/nav-grid.ts";
import { createCombatModule, type CombatModuleHandle, type HitInfo } from "../combat/combat-module.ts";
import { createThreatTable, type ThreatTable } from "../combat/threat.ts";
import type { Factions } from "../combat/faction.ts";
import { grantLoot, lootOfNode } from "../combat/loot.ts";
import { type CorpseGround, spawnCorpse } from "../combat/corpse.ts";
import { type MobHandle, spawnMob } from "./spawn-mob.ts";
import { type MobTemplate, validateTemplate } from "./mob-template.ts";
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
  /**
   * 物理世界（批124）。给了 = 每只生物长一个**动态体**；不给 = 老行为（互相穿过）。
   *
   * ★★ 为什么是动态体、不是静态障碍体：静态体在物理层的含义是"不会动、也不该被
   *   推开"（树 / 石头 / 立牌）。生物会动，登记成静态体会同时错两处：
   *   ① `resolve()` 不推动静态体 ⇒ 它踩进树里之后永远出不来；
   *   ② `sweepMove()` **只扫静态体** ⇒ 它变成一堵会走路的墙，别的单位"贴着怪走"
   *      会莫名其妙停住，而怪一走开那堵墙也跟着走。
   *
   * ★ C18「动态障碍」的三问，答案都在这里：
   *   ① **AI 追人的那个碰撞体参不参与扫掠** —— 不参与。动态体被跨过去**不是**
   *      "一去不回"（`resolve()` 下一拍还能把两侧分开），而扫掠要读对方**这一拍的
   *      旧坐标**，症状是"它明明走开了我却停住"。判据在 `physics-sweep.test.ts`
   *      的「sweepMove 只扫静态体」。
   *   ② **静态体每帧重插还是移动体扫掠** —— 都不做。静态体整局不动，重插是纯成本；
   *      "节点位置变了"由空间哈希按增量重分格（`cellMoves`）负责；而真正会穿过去的
   *      只有移动体，它的位移在这一层小到不需要扫掠（见文件头 ⑤）。
   *   ③ **谁会动** —— 生物（本选项）与玩家（宿主那条路）。装饰与尸体不动。
   */
  readonly physics?: IPhysicsWorld;
  /**
   * 猎物再生（批126）：让"地图上再没有猎物可打"不再出现。
   *
   * ★★ 为什么这是引擎能力、而不是宿主的配表：捕食者没有"吃饱"、猎物不会再生，
   *   那么**任何**有限数量都会被吃掉 —— 这不是数值没调好，是缺一条规则。
   *   演示里 3 只猎狗 3.5 秒吃光 10 只兔子，之后地图上只剩猎狗可打；
   *   调伤害/冷却只能把它推迟到 15 秒，仍然会归零（`docs/PROGRESS.md` 批126 有算术）。
   * ★ 谁来挑落点：宿主（`pickCell`）。引擎不知道玩家在哪、也不知道"离玩家多远
   *   才算看得见"，那是产品决定；引擎只负责"数一数、到点了、要一只"。
   * ★ 不给 = 老行为（世界里的生物只减不增）。
   */
  readonly respawn?: MobRespawnOptions;
  readonly id?: string;
}

/** 猎物再生（见 `MobWorldOptions.respawn`）。 */
export interface MobRespawnOptions {
  /** 每隔多少 tick 检查一次（>= 1）。同一个窗口里最多补一只（不批量刷）。 */
  readonly everyTicks: number;
  /** 维护哪一类（按模板 `kind` 计数，初始那批也算在内）。 */
  readonly kind: string;
  /** 这一类**同时最多**活几只。到了上限就什么都不做。 */
  readonly max: number;
  /** 用哪个模板出生（必须能在 `templates` 里找到同 `kind` 的）。 */
  readonly template: string;
  /**
   * 挑落脚格（宿主给）；`-1` = 这一轮没地方，下一个窗口再试。
   *
   * ★ 让它返回格子而不是坐标：格子是导航的单位，坐标由模块 `centerOf` 换算 ——
   *   这样"一出生就站在水里"这类错在类型上就不可能。
   */
  readonly pickCell: (tick: number) => number;
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
  /**
   * 猎物再生补过几只（批126；`respawn` 没给时恒 0）。
   *
   * ★ 必须能读到："地图上还有兔子"有两个来源 —— 从来没被杀光，或者补过。
   *   只读"现在有几只"的话，"再生一次都没跑"与"再生在正常工作"分不开，
   *   而前者正是这个功能最可能的坏法（`pickCell` 一直返回 -1 / 窗口条件写反）。
   */
  readonly respawned: number;
  /** 上一次再生落在哪一格（`-1` = 还没补过）。 */
  readonly lastRespawnCell: number;
  /** 上一次再生失败的原因（`MOB.SPAWN_FAILED` 等；正常时为空串）。 */
  readonly lastRespawnError: string;
  /** 现在**真的有物理体**的生物数（`physics` 没给时恒 0）。 */
  readonly bodies: number;
  /** 撤掉过的生物物理体数（见 `prune`：死掉的不撤就是**一堵看不见的墙**）。 */
  readonly bodiesRemoved: number;
  /** 加过多少次生物物理体（**含读档后的重建**，见 `syncBodies`）。 */
  readonly bodiesAdded: number;
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
  /**
   * **当场**把物理表拉回"每只活着的生物都有体"，返回这一次补了几个（批125）。
   *
   * ★★ 为什么必须有这个入口（`update` 里已经在做同一件事了）：
   *   宿主的读档走 `physics.clear()` + 重建摆件与玩家，那一步发生在**两个 tick 之间**。
   *   只靠 `update` 里的 `syncBodies` 的话，读档后的 33ms（30Hz 一拍）里
   *   生物是**没有体**的：它们互相穿过、也穿过玩家，而所有计数都自洽。
   *   "下一拍会好"不足以兜住它 —— 33ms 在 30Hz 下就是一个可观测的帧。
   * ★ 幂等：已经有体的不会再补，所以可以在任何安全点重复调用。
   */
  resyncBodies(): number;
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
  /** nodeId → 模板半径（体要用**模板的**尺寸，不是常数，见 `syncBodies`）。 */
  const radiusOfNode = new Map<number, number>();
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
  let bodiesRemoved = 0;
  let bodiesAdded = 0;
  let respawned = 0;
  let lastRespawnCell = -1;
  let lastRespawnError = "";
  /** 上一次**检查**再生的 tick（不是"上一次补"：没补也要记，否则每 tick 都问一遍）。 */
  let lastRespawnCheck = Number.NEGATIVE_INFINITY;
  /** 再生用的模板（`init` 里按 `kind` 查好，采样期不再查表）。 */
  let respawnTpl: MobTemplate | null = null;

  /** 见文件头 ③。头部与尾部各调一次：本 tick 开始时与结束时都要准。 */
  function prune(): void {
    const s = scene;
    if (s === null || ids.length === 0) {
      mobs = 0;
      return;
    }
    const phys = options.physics;
    const alive: number[] = [];
    for (const id of ids) {
      if (s.find(id) !== undefined) {
        alive.push(id);
        continue;
      }
      // ★★ 节点没了，**物理体必须跟着没**（批124）。
      //   不撤的话原地留下一个半径 0.3 的圆：画面上什么都没有，走过去却过不去。
      //   它也不会自己消失 —— `resolve()` 只推动态体，而"那里已经没有节点了"
      //   恰恰意味着位置访问器读不到坐标（`sweepMove` 直接返回 null）。
      //   最阴的是**所有数字都对**：生物数、尸体数、战利品数全都自洽。
      if (phys !== undefined && phys.has(id)) {
        phys.remove(id);
        bodiesRemoved++;
      }
    }
    if (alive.length !== ids.length) ids = alive;
    mobs = ids.length;
  }

  /**
   * **把物理表拉回"每只活着的生物都有体"**（批124）。
   *
   * ★★ 为什么是"每 tick 维护"而不是"init 时加一次"：物理表会在**别处**被清空 ——
   *   最典型的是读档（`applyLoad` 里 `physics.clear()` 之后只重建了摆件与玩家）。
   *   一次性加的话，读档之后生物就**静默地**开始互相穿过：所有计数照旧，只有画面变了。
   *   这类"外部把表清了"的路径没法靠"记得在每个出口补一遍"来覆盖 ——
   *   摆件与玩家的补写已经散在宿主里两份了。
   * ★ 代价是每 tick 每只一次 `has()`：13 只 = 13 次 Map 查询，不值一提。
   * ★ 也因为它，`init` 里不需要 `scene.enqueue` 那种"晚一批"的写法：第一次
   *   `update` 就会把体补齐（那时组合根已经能读到场景）。
   */
  function syncBodies(): number {
    const s = scene;
    const phys = options.physics;
    if (s === null || phys === undefined) return 0;
    // ★ 返回值 = 这一次补了几个（批125）。用 `bodiesAdded` 的前后差算，**不改循环体**：
    //   循环里那两行是 M780/M782 的靶子，往里插一行计数器就会让它们"靶子漂移"。
    const before = bodiesAdded;
    for (const id of ids) {
      if (phys.has(id)) continue;
      const radius = radiusOfNode.get(id);
      if (radius === undefined) continue;
      if (s.find(id) === undefined) continue;
      phys.add({ nodeId: id, radius, isStatic: false });
      bodiesAdded++;
    }
    return bodiesAdded - before;
  }

  /**
   * 猎物再生（批126，见 `MobWorldOptions.respawn`）。
   *
   * ★ 三个"不"：
   *   · **不批量**：一个窗口最多补一只。批量补会让"一次算错"变成"一瞬间冒出十只"，
   *     而那种现象在判据里看起来像"再生一直很健康"。
   *   · **不覆盖**：到了 `max` 就什么都不做（也不重置窗口体感 —— 见下）。
   *   · **不猜落点**：格子由宿主给（`pickCell`），引擎不知道玩家在哪。
   * ★ 窗口按"检查"记而不是"补"记：不然没补成（没地方 / 到上限）之后每一 tick 都会
   *   再问一次宿主 —— `pickCell` 是一次全图扫描，问得比调度器还勤没有意义。
   */
  function respawnPrey(tick: number): void {
    const rp = options.respawn;
    const s = scene;
    if (rp === undefined || s === null || respawnTpl === null) return;
    if (tick - lastRespawnCheck < rp.everyTicks) return;
    lastRespawnCheck = tick;
    let alive = 0;
    for (const id of ids) if (kindOf.get(id) === rp.kind) alive++;
    if (alive >= rp.max) return;
    const cell = rp.pickCell(tick);
    if (cell < 0) return;
    const c = options.grid.centerOf(cell);
    // ★ 名字带 `r` 前缀：出生点那批叫 `mob#0..N`，重生的是 `mob#r1..` ——
    //   存档与 Lua 脚本按名字找节点，两批撞名会"找到另一只"。
    const born = spawnMob(s, respawnTpl, c.x, c.z, { name: `mob#r${String(respawned + 1)}` });
    if (!born.ok) {
      lastRespawnError = born.error.code;
      return;
    }
    ids.push(born.value.nodeId);
    kindOf.set(born.value.nodeId, born.value.template.kind);
    radiusOfNode.set(born.value.nodeId, born.value.template.radius);
    respawned++;
    lastRespawnCell = cell;
    // ★ 顺手把 `mobs` 对齐：`prune` 是这一拍更早的时候算的，不补的话
    //   `stats.mobs` 会比 `stats.bodies` 少一只，而那个差值正是读档对账用的口径。
    mobs = ids.length;
  }

  const handle: MobWorldHandle = {
    id: options.id ?? "world.mobs",
    get stats(): MobWorldStats {
      const phys = options.physics;
      let bodies = 0;
      if (phys !== undefined) for (const id of ids) if (phys.has(id)) bodies++;
      return {
        mobs,
        bodies,
        bodiesRemoved,
        bodiesAdded,
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
        respawned,
        lastRespawnCell,
        lastRespawnError,
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
    resyncBodies(): number {
      // ★ 先 prune：读档会把死掉的那些节点的体也一起清掉，`ids` 里可能还有它们的尸体号。
      //   不 prune 的话这里会对"已经不存在的节点"调用 `add` —— 而 `add` 读不到坐标会抛。
      prune();
      return syncBodies();
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
      // ---- 猎物再生（批126）：配置错误在这里**当场**报，不要等第十秒"少了一只兔子"
      const rp = options.respawn;
      if (rp !== undefined) {
        if (!Number.isInteger(rp.everyTicks) || rp.everyTicks < 1) {
          return err(
            engineError(MOB_WORLD_BAD_MODULE, `respawn.everyTicks 必须是 >= 1 的整数，收到 ${String(rp.everyTicks)}`),
          );
        }
        if (!Number.isInteger(rp.max) || rp.max < 1) {
          return err(engineError(MOB_WORLD_BAD_MODULE, `respawn.max 必须是 >= 1 的整数，收到 ${String(rp.max)}`));
        }
        for (const raw of options.templates) {
          const v = validateTemplate(raw);
          if (v.ok && v.value.kind === rp.template) {
            respawnTpl = v.value;
            break;
          }
        }
        if (respawnTpl === null) {
          return err(
            engineError(MOB_WORLD_BAD_MODULE, `respawn.template 指向一个不存在的模板 ${String(rp.template)}`, {
              template: rp.template,
            }),
          );
        }
      }
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
      // ★ 物理体**不在这里加**（见 `syncBodies` 的 ★★）：init 期间组合根还读不到
      //   场景，此刻 `add` 会抛「body N 没有位置」。体是 `update` 里维护的不变量。
      for (const m of placed) radiusOfNode.set(m.nodeId, m.template.radius);

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
      // ★ 顺序：先 prune（死者出名单）→ 再决定要不要补 → 再由 `syncBodies` 给新生的那只加体。
      //   倒过来的话，新补的那只会被这一拍的 prune 当成"名单外的" —— 它的体没人加，
      //   要等下一拍，于是"再生"自己制造了一次 33ms 空窗（批125 刚修掉的那种）。
      respawnPrey(tick);
      syncBodies();
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
