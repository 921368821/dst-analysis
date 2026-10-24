/**
 * L4 · 世界任务模块（把 `WorldTasks` 的触发落到场景里）
 *
 * `tasks.ts` 只回答"什么时候该做"，这个文件回答"做出来的东西在场景里长什么样"。
 * 分成两层不是为了好看：**调度可以脱离场景测**（批35 就是），
 * 而"往世界里放东西"必须碰 `Scene`，两件事的判据完全不同。
 *
 * ★★ 三条承重决定：
 *
 * ① **去重按格子，不按任务**。
 *    同一个格子上已经有资源（计划投放的 `world.site` 或之前刷出来的 `world.resource`）
 *    就不再放第二个。否则每次周期都往同一格叠一层 —— 而画面上完全看不出来
 *    （叠在同一位置的精灵只显示最上面那个），只有 `countOf()` 会一路涨。
 *    去重集合里**两种组件都算**：计划投放的资源已经在那儿了，再生不该覆盖它。
 *
 * ② ★ **离线跳时间不会爆刷**，这条在场景层再验一次。
 *    `tasks.ts` 已经保证"一次推进每个任务最多跑一次"，但那只保证了"不连跑 100 次"；
 *    "跑的那一次别把 100 个周期该刷的量一次性刷完"是**另一件事**（由 `picksPerRun` 管）。
 *    这里的判据是：跳 10000 tick 之后场景里只多出 `picksPerRun` 个节点，
 *    不是 `picksPerRun × 1000` 个。
 *
 * ③ **全局上限必须有**。
 *    再生是"只增不减"的（世界里没有"资源被采走"的模拟），所以没有上限的任务表
 *    会让节点数单调增长。上限到了就停止刷并计数 —— 不静默丢弃，也不假装成功。
 *
 * ★ 模块自己 `flush()`：它不在 `scene.step` 的调用栈里（由调度器的 `onStep` 驱动），
 *   没有别人会替它把命令队列冲掉。等宿主去 flush 的后果是"资源晚一帧出现"，
 *   而那会让"这一帧刷了几个"的判据变成时序猜谜。
 */

import type { ComponentRegistry, ComponentSchema } from "../../core/scene/component.ts";
import { Component, FieldType } from "../../core/scene/component.ts";
import type { Scene } from "../../core/scene/scene.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import { Services } from "../../core/tokens.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { isPassable, type SiteKind, type WorldPlan } from "./worldgen.ts";
import { SITE_TYPE, SiteMarker } from "./assemble.ts";
import { WorldTasks, type WorldTaskTable, type TaskFire } from "./tasks.ts";

export const RESOURCE_TYPE = "world.resource";
/** 场景取不到（既没传进 options，`ModuleContext` 里也没有 `Services.Scene`）。 */
export const TASK_NO_SCENE = "TASK.NO_SCENE";
/** 放置：格子越界（不在 `[0, width*height)` 里）。 */
export const TASK_BAD_CELL = "TASK.BAD_CELL";
/** 放置：地形不可通行（水 / 岩石）。 */
export const TASK_BAD_TERRAIN = "TASK.BAD_TERRAIN";
/** 放置：这一格已经有资源了（去重索引命中）。 */
export const TASK_CELL_TAKEN = "TASK.CELL_TAKEN";
/** 放置：全局资源上限到了。 */
export const TASK_CAP = "TASK.CAP";

export const RESOURCE_SCHEMA: ComponentSchema = {
  type: RESOURCE_TYPE,
  fields: {
    cell: FieldType.Int,
    kind: FieldType.String,
    /** 哪一次触发刷出来的（= `TaskFire.tick`）。诊断用，也用来验"重复触发没被合并"。 */
    bornTick: FieldType.Int,
  },
};

/** 再生出来的资源点。与 `world.site`（计划自带的投放点）刻意分开：来源不同，删改策略也不同。 */
export class ResourceMarker extends Component {
  readonly schema: ComponentSchema = RESOURCE_SCHEMA;
  cell = 0;
  kind: SiteKind = "tree";
  bornTick = 0;
}

export function registerResourceComponent(registry: ComponentRegistry): void {
  if (!registry.has(RESOURCE_TYPE)) registry.register(RESOURCE_SCHEMA, () => new ResourceMarker());
}

export interface WorldTaskModuleOptions {
  readonly tasks: WorldTaskTable;
  readonly plan: WorldPlan;
  /** 不传则从 `ModuleContext.services` 取 `Services.Scene`（模块的标准取法）。 */
  readonly scene?: Scene;
  /** 全局资源上限（默认 4096）。到了就不再刷，并计入 `skippedCap`。 */
  readonly maxResources?: number;
}

export interface WorldTaskModuleStats {
  readonly fires: number;
  /** 累计刷出过的数量（含后来被采走的）。 */
  readonly spawned: number;
  /** 当前还活着的资源数（= 累计刷出 − 被采走）。**上限按这个数算**，不按累计数。 */
  readonly alive: number;
  /** 被采走并释放了名额的格子数。 */
  readonly released: number;
  /** 因为格子上已有资源而跳过（去重生效）。 */
  readonly skippedExisting: number;
  /** 因为到了全局上限而跳过。 */
  readonly skippedCap: number;
  /**
   * 去重索引里现在有多少格。
   *
   * ★ 为什么必须能读到这个数：索引与账目是**两套状态**（`Set<number>` vs `alive` 计数量），
   *   它们只在"刷"和"采"两条路径上同步改。任何一处漏改，单看 `alive` 或逐格问
   *   `isOccupied` 都发现不了 —— 而 `occupied !== alive` 是一个**一次就能算出来**的对账。
   *   索引还没建（懒建，见 `ensureIndex`）时是 0，不代表世界上没有资源。
   */
  readonly occupied: number;
  readonly lastTick: number;
}

export interface WorldTaskModuleHandle extends IModule {
  readonly tasks: WorldTasks;
  /** 由调度器的 `onStep` 调用（也可以手动调，判据里两条路都走）。 */
  update(tick: number, dt: number): void;
  stats(): WorldTaskModuleStats;
  /** 最近一次 `update` 触发的执行（诊断）。 */
  lastFires(): readonly TaskFire[];
  /**
   * 释放一个格子的名额（资源被采走时调用）。
   * 返回 `false` 表示这一格本来就不在索引里 —— **不报错**（重复采集/错格采集是调用方的事，
   * 但"没东西可放"和"放错了"必须能被区分，所以返回值而不是 void）。
   */
  releaseCell(cell: number): boolean;
  /** 这一格现在有没有资源（去重索引的只读视图，采集方用它避免空挥）。 */
  isOccupied(cell: number): boolean;
  /**
   * 往世界里**放一个**资源（丢弃到地面的世界侧原语）。
   *
   * ★ 与 `update` 里的再生走**同一套账**：占格、`spawned`、`alive`、全局上限都一起改。
   *   少改任何一样的症状是"丢的东西会刷新、或者丢一份世界多算一个名额"，
   *   而画面上只是地上多了一个图标，看不出来。
   * ★ `bornTick` 由调用方给（宿主知道当前 tick）：模块自己不看时钟，
   *   于是"跳时间回放"不会把丢的东西记成别的 tick 出生。
   */
  placeResource(cell: number, kind: SiteKind, bornTick: number): Result<number, EngineError>;
}

const DEFAULT_MAX_RESOURCES = 4096;

export function createWorldTaskModule(opts: WorldTaskModuleOptions): WorldTaskModuleHandle {
  const maxResources = opts.maxResources ?? DEFAULT_MAX_RESOURCES;

  let scene: Scene | null = opts.scene ?? null;
  let ctxRef: ModuleContext | null = null;
  let started = false;

  const tasks = ((): WorldTasks => {
    const r = WorldTasks.create(opts.tasks, opts.plan);
    if (!r.ok) {
      // 建表失败是**配置错误**，应该在 `create` 时就炸（而不是等第三个 tick 才发现）
      throw new Error(`世界任务表不合法：${r.error.code} ${r.error.message}`);
    }
    return r.value;
  })();

  /** 已被占用的格子（计划投放 + 再生）。`null` = 还没扫过（懒建，见 `ensureIndex`）。 */
  let occupied: Set<number> | null = null;
  let fires = 0;
  let spawned = 0;
  let alive = 0;
  let released = 0;
  let skippedExisting = 0;
  let skippedCap = 0;
  let lastFires: readonly TaskFire[] = [];

  /**
   * 懒建去重索引。
   * ★ 为什么不在 `create` 时建：`create` 可能在装配**之前**调用（模块先建、世界后装），
   *   那时场景是空的，索引会漏掉计划投放的资源点 —— 于是第一次再生会盖在已有的资源上。
   */
  function ensureIndex(s: Scene): Set<number> {
    if (occupied !== null) return occupied;
    const set = new Set<number>();
    for (const marker of s.componentsOf<SiteMarker>(SITE_TYPE)) set.add(marker.cell);
    for (const res of s.componentsOf<ResourceMarker>(RESOURCE_TYPE)) set.add(res.cell);
    occupied = set;
    return set;
  }

  const mod: WorldTaskModuleHandle = {
    id: "world.tasks",
    deps: [],
    tasks,

    init(ctx: ModuleContext): Result<void, EngineError> {
      ctxRef = ctx;
      if (scene === null) {
        const got = ctx.services.get(Services.Scene);
        if (got === undefined) {
          return err(
            engineError(
              TASK_NO_SCENE,
              "世界任务模块需要一个 Scene：要么在 options 里传，要么先由宿主注册 Services.Scene",
            ),
          );
        }
        scene = got;
      }
      if (!scene.components.has(RESOURCE_TYPE)) {
        return err(
          engineError(
            TASK_NO_SCENE,
            `场景的组件注册表里没有 ${RESOURCE_TYPE} —— 先 registerResourceComponent(scene.components)`,
          ),
        );
      }
      return ok(undefined);
    },

    start(): void {
      started = true;
    },

    stop(): void {
      started = false;
    },

    update(tick: number, dt: number): void {
      void dt; // ★ 与仓库其余宿主同签名，但**不用**：任务按 tick 走，用 dt 会破坏确定性
      const s = scene;
      if (s === null || !started) return;

      const advanced = tasks.advanceTo(tick);
      if (!advanced.ok) {
        // 时间倒退属于调用方错误（回档该重建模块），报给日志而不是静默继续
        ctxRef?.log.channel("world").warn(`世界任务推进失败：${advanced.error.code} ${advanced.error.message}`);
        lastFires = [];
        return;
      }
      lastFires = advanced.value;
      if (advanced.value.length === 0) return;

      const taken = ensureIndex(s);
      let touched = false;

      for (const fire of advanced.value) {
        fires++;
        for (const cell of fire.cells) {
          if (taken.has(cell)) {
            skippedExisting++;
            continue;
          }
          if (alive >= maxResources) {
            skippedCap++;
            continue;
          }
          const width = opts.plan.width;
          const cx = cell % width;
          const cz = (cell - cx) / width;
          const node = s.spawn(`resource/${kindOf(fire, opts.plan, cell)}`, null);
          if (!node.ok) {
            ctxRef?.log.channel("world").warn(`资源节点创建失败：${node.error.code}`);
            continue;
          }
          // 格子中心：+0.5 格。256 是 2 的幂 ⇒ (cell*256 + 128) / 256 精确
          node.value.setLocalPosition(cx + 0.5, cz + 0.5);
          const made = s.attach(node.value.id, () => new ResourceMarker());
          if (!made.ok) continue;
          made.value.cell = cell;
          made.value.kind = kindOf(fire, opts.plan, cell);
          made.value.bornTick = fire.tick;
          taken.add(cell);
          spawned++;
          alive++;
          touched = true;
        }
      }

      // 模块不在 scene.step 的调用栈里，没人替它 flush（见文件头）
      if (touched) s.flush();
    },

    stats(): WorldTaskModuleStats {
      // ★ `occupied` 直接读索引，不用 `alive` 推 —— 用账目算账目等于没对账。
      //   索引懒建时是 0（那是"还没建"，不是"没有资源"，所以从不用它判断世界内容）。
      return {
        fires,
        spawned,
        alive,
        released,
        skippedExisting,
        skippedCap,
        occupied: occupied === null ? 0 : occupied.size,
        lastTick: tasks.lastTick,
      };
    },

    releaseCell(cell: number): boolean {
      const s = scene;
      if (s === null) return false;
      const taken = ensureIndex(s);
      if (!taken.delete(cell)) return false;
      // ★ 上限按**活着**的资源算：采走一个就该腾出一个名额。
      //   若按累计数算，一个长期运行的世界会"越玩越刷不出来"，而现场看起来毫无异常。
      if (alive > 0) alive--;
      released++;
      return true;
    },

    isOccupied(cell: number): boolean {
      const s = scene;
      if (s === null) return false;
      return ensureIndex(s).has(cell);
    },

    placeResource(cell: number, kind: SiteKind, bornTick: number): Result<number, EngineError> {
      const s = scene;
      if (s === null) {
        return err(engineError(TASK_NO_SCENE, "世界任务模块没有场景，放不了资源"));
      }
      const width = opts.plan.width;
      const size = width * opts.plan.height;
      if (!Number.isInteger(cell) || cell < 0 || cell >= size) {
        return err(engineError(TASK_BAD_CELL, `格子 ${String(cell)} 越界（世界是 ${String(width)}×${String(opts.plan.height)}）`));
      }
      // ★ 地形检查放在占用检查**之前**：水格被占与否都不该放东西，
      //   而先查占用会给调用方一个"换一格就好"的错觉 —— 整片湖都不可通行。
      if (!isPassable(opts.plan.kinds[cell]!)) {
        return err(engineError(TASK_BAD_TERRAIN, `格子 ${String(cell)} 是不可通行地形，不能放资源`));
      }
      const taken = ensureIndex(s);
      if (taken.has(cell)) {
        return err(engineError(TASK_CELL_TAKEN, `格子 ${String(cell)} 上已经有资源了`));
      }
      if (alive >= maxResources) {
        return err(engineError(TASK_CAP, `世界资源已到全局上限（${String(maxResources)}），放不下更多`));
      }
      const cx = cell % width;
      const cz = (cell - cx) / width;
      const node = s.spawn(`resource/${kind}`, null);
      if (!node.ok) return node;
      // 格子中心：+0.5 格（与再生同一条路径，别在这里发明第二种坐标）
      node.value.setLocalPosition(cx + 0.5, cz + 0.5);
      const made = s.attach(node.value.id, () => new ResourceMarker());
      if (!made.ok) {
        // 组件挂不上的话，刚 spawn 的节点就是**没有标记的孤儿**（画面看不见、
        // 账目没算它）—— 必须撤掉再报错，不能像 `update` 里那样 continue 了之。
        s.destroy(node.value.id);
        s.flush();
        return made;
      }
      made.value.cell = cell;
      made.value.kind = kind;
      made.value.bornTick = bornTick;
      taken.add(cell);
      spawned++;
      alive++;
      s.flush();
      return ok(node.value.id);
    },

    lastFires(): readonly TaskFire[] {
      return lastFires;
    },

    describe(): string {
      return `world.tasks：${String(tasks.stats().tasks)} 条任务 / 已刷 ${String(spawned)} / 跳过去重 ${String(skippedExisting)} / 上限 ${String(skippedCap)}`;
    },
  };

  return mod;
}

/**
 * 该格刷什么。
 *
 * ★ 这里刻意**不看** `fire` 里的信息来决定种类（fire 只有 taskId/cells）：
 *   种类由"格子所在的群系"决定，走 `plan` 而不是靠任务表声明。
 *   理由是：同一条任务（"每 200 tick 补一次草"）应该按地图实际地形刷，
 *   而不是把种类写死在表里 —— 后者一改地图就全错。
 */
function kindOf(fire: TaskFire, plan: WorldPlan, cell: number): SiteKind {
  void fire;
  const kind = plan.kinds[cell]!;
  if (!isPassable(kind)) return "grass_tuft"; // 不可通行格本来不会被选中，这里只是兜底
  switch (kind) {
    case "forest":
      return "tree";
    case "grass":
      return "berry";
    case "beach":
      return "flint";
    case "rocky":
      return "rock";
    case "savanna":
      return "grass_tuft";
    case "marsh":
      return "reed";
    default:
      return "grass_tuft";
  }
}
