/**
 * L4 · 尸体（C18 的第三项：**死了以后地上留一具**）
 *
 * 批61 让目标会死，批65 让战利品知道该给谁，但它们都假设"东西直接进背包"。
 * `loot.ts` 的文件头早把这条路的尽头写清楚了：想要「地上有块肉」，得先让世界
 * 认识 `carcass` 这个种类 —— 否则 `drop-to-world.ts` 记过的那种
 * 「能放下、但采不动、也刷不出」的资源点会立刻出现。这一层就是那一批。
 *
 * ★★ 六个决定：
 *
 * ① **尸体不是资源**。它不进 `world.tasks` 的 `occupied` 索引、不占 `alive`、
 *    不受 `maxResources` 限制。走 `placeResource` 的话症状极隐蔽：杀一只怪就吃掉
 *    一个资源名额，4096 只之后**森林再也不长** —— 而那一刻没有任何报错，
 *    所有计数自洽（`alive` 就是满的）。所以尸体有自己的节点、自己的占用表。
 *    ★ 反过来，尸体**也不占**资源那套索引 ⇒ 再生可能长在尸体的格子上。这是有意
 *    接受的（资源不是障碍，玩家本来就站在树下砍），换来的是两套账互不污染。
 *
 * ② **格子是尸体的身份**。一具尸体一格（`findCorpseCell`：先试死亡格，再环形外扩），
 *    于是"这一格的尸体"永远只有一具，拾取时不用在"同格两具"之间选。
 *
 * ③ **腐烂按绝对 tick 存**（`decayAtTick`），不是"还剩多少 tick"。
 *    存剩余量的话，读档会把腐烂时刻往后推一个存档周期 —— 而"读档能保鲜"这种
 *    利用会变成玩家的标准玩法。反过来 `decayAtTick = 0` 是**永不腐烂**的哨兵，
 *    也是字段缺失时的默认值：旧档/坏档读回来时尸体永久存在，是**安全方向**（不丢东西）。
 *
 * ④ **物品清单是字符串数组**（`"kind:count"`，按 kind 升序）。
 *    `Component` 的 schema 里没有"结构体数组"，而有 `StringArray`；把它写成
 *    定长槽位（`slot0Kind/slot0Count/...`）会把"配表最多几项"变成一个魔法上限。
 *    ★ 解码用 `lastIndexOf(":")`：kind 是配置里来的字符串，理论上能含冒号；
 *      用 `indexOf` 的话 `"a:b":2` 会被读成 kind = `a`、数量解析失败。
 *    ★ 编码走 `normalizeLoot`（排序 + 合并重复项），所以**同一张表的两种写法**
 *      （`[肉, 皮]` 与 `[皮, 肉]`）产出**逐字节相同**的存档。
 *
 * ⑤ **取东西的顺序与 `harvestInto` 一致：先看 → 先进包 → 最后扣尸体**。
 *    反过来的症状是"尸体空了、背包没多"（背包满时最常发生），而画面上
 *    只是地上少了一具尸体 —— 没有异常。
 *    多条目时是**全成或全不成**：中途失败把已经进包的原样退回（`addItem` 的
 *    "要么全装下、要么一点不动"依赖这条）。
 *
 * ⑥ **`decayTicks` 默认 0（永不腐烂）**。默认成"10 秒后消失"的话，任何忘记传参的
 *    宿主都会在玩家跑过去的路上把战利品吃掉 —— 而且日志里什么都不会有。
 *    要腐烂的宿主必须**显式**说要烂多久。
 */

import { Component, FieldType, type ComponentRegistry, type ComponentSchema } from "../../core/scene/component.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { Services } from "../../core/tokens.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { addItem, takeItem } from "../inventory/inventory.ts";
import { cellsInRing } from "../worldgen/cell-ring.ts";
import {
  decodeItems,
  encodeItems,
  type LootEntry,
  type LootTable,
  lootTotal,
  normalizeLoot,
} from "./loot.ts";

/**
 * ★ 批123 后期：`encodeItems` / `decodeItems` 搬到了 `loot.ts`，这里只做**再导出**。
 *   理由：尸体与"活着的东西身上的战利品表"（`LootHolding`）用的是**同一套编码**，
 *   而同一套编码写在两个文件里，就会在某一个边界输入上分叉（`"a:b":2` 这种）。
 */
export { decodeItems, encodeItems };

/** 尸体组件类型。 */
export const CORPSE_TYPE = "world.corpse";

/** 周围几格都没有能放尸体的地（全不可走 / 已经各有一具）。 */
export const CORPSE_NO_SPACE = "CORPSE.NO_SPACE";
/** 战利品表里一件东西都没有 —— 生成一具空尸体没有意义。 */
export const CORPSE_EMPTY = "CORPSE.EMPTY";
/** 腐烂时长不是 >= 0 的整数。 */
export const CORPSE_BAD_DECAY = "CORPSE.BAD_DECAY";
/** 这一格没有尸体 / 尸体里没有要的那种东西。 */
export const CORPSE_NONE = "CORPSE.NONE";
/** 场景的组件注册表里没有尸体组件。 */
export const CORPSE_NO_COMPONENT = "CORPSE.NO_COMPONENT";

/**
 * 尸体组件的字段表。
 * ★ 单独提出来是因为注册表要的是 schema 本身（不想为了拿它 new 一个组件）。
 * ★ 顺序即序列化顺序（字节确定）：先"在哪一格"，再"什么时候烂"，最后"里面有什么"。
 */
const CORPSE_SCHEMA: ComponentSchema = {
  type: CORPSE_TYPE,
  fields: { cell: FieldType.Int, decayAtTick: FieldType.Int, items: FieldType.StringArray },
};

export class Corpse extends Component {
  /** 所在格子（见文件头 ②）。 */
  cell = 0;

  /**
   * 腐烂时刻（绝对 tick）。`0` = **永不腐烂**（见文件头 ③）。
   * ★ 默认值写在类初始化器里：`Component.load` 在字段缺失时保留实例值，
   *   所以旧档/坏档读回来是"永久尸体"，而不是"立刻消失"。
   */
  decayAtTick = 0;

  /**
   * 里面有什么：`"kind:count"`，按 `kind` 升序（见文件头 ④）。
   * ★ 存成字符串数组而不是 JSON：schema 的字段类型是唯一可校验的形状，
   *   而 `StringArray` 是仓库里已有的类型（标签、配方都走它）。
   */
  items: string[] = [];

  readonly schema: ComponentSchema = CORPSE_SCHEMA;
}

export function registerCorpseComponent(registry: ComponentRegistry): void {
  if (!registry.has(CORPSE_TYPE)) registry.register(CORPSE_SCHEMA, () => new Corpse());
}

/**
 * 尸体能落在哪片地上 —— 只要三个能力（`NavGrid` 直接满足它，不需要适配）。
 * ★ 不 import `WorldPlan` / `NavGrid`：这一层关心的是"这一格能不能站人"，
 *   而不是世界是怎么生成的。传计划进来会把这层绑死在 worldgen 上。
 */
export interface CorpseGround {
  readonly width: number;
  readonly height: number;
  isWalkableIndex(cell: number): boolean;
  centerOf(cell: number): { readonly x: number; readonly z: number };
}

/** 一具尸体的落点。 */
export interface CorpseSpawn {
  readonly cell: number;
  readonly nodeId: number;
  readonly items: LootTable;
  /** 腐烂时刻（绝对 tick；`0` = 永不）。 */
  readonly decayAtTick: number;
}

export interface SpawnCorpseOptions {
  readonly ground: CorpseGround;
  /** 死亡位置（世界坐标，1 格 = 1 单位）。 */
  readonly x: number;
  readonly z: number;
  /** 当前 tick（腐烂的起点）。 */
  readonly nowTick: number;
  /** 多久之后消失（tick；`0`/省略 = 永不，见文件头 ⑥）。 */
  readonly decayTicks?: number;
  /** 搜索半径（格，默认 2）：死亡格被占时往外找。 */
  readonly searchCells?: number;
}

/**
 * 死亡格优先、否则环形外扩找一格空地 —— 顺序由 `cellsInRing` 定死
 * （由近到远、环内 cell 升序），回放依赖这条。
 *
 * ★ 只避开"可走性"和"已经有尸体"两件事：资源格可以有尸体（见文件头 ①）。
 */
export function findCorpseCell(
  scene: Scene,
  ground: CorpseGround,
  x: number,
  z: number,
  searchCells = 2,
): number | null {
  const cx = Math.floor(x);
  const cz = Math.floor(z);
  const base = Math.max(0, Math.floor(searchCells));
  const occupied = new Set<number>();
  for (const c of scene.componentsOf<Corpse>(CORPSE_TYPE)) {
    if (c.node !== null) occupied.add(c.cell);
  }
  const ring: number[] = [];
  for (let r = 0; r <= base; r++) {
    ring.length = 0;
    cellsInRing(ground.width, ground.height, cx, cz, r, ring);
    for (const cell of ring) {
      if (!ground.isWalkableIndex(cell)) continue;
      if (occupied.has(cell)) continue;
      return cell;
    }
  }
  return null;
}

/**
 * 在死亡位置生成一具尸体。
 *
 * 顺序：**校验配表 → 校验腐烂时长 → 找格 → 生成 → 写字段**。
 * 校验都在"世界动过"之前，所以失败时场景里一个节点都不多。
 */
export function spawnCorpse(scene: Scene, table: unknown, opts: SpawnCorpseOptions): Result<CorpseSpawn, EngineError> {
  if (!scene.components.has(CORPSE_TYPE)) {
    return err(engineError(CORPSE_NO_COMPONENT, `场景的组件注册表里没有 ${CORPSE_TYPE} —— 先 registerCorpseComponent()`));
  }
  const norm = normalizeLoot(table);
  if (!norm.ok) return norm;
  const items = norm.value;
  if (items.length === 0) {
    return err(engineError(CORPSE_EMPTY, "战利品表是空的 —— 不生成空尸体（那具尸体只会让玩家白跑一趟）"));
  }
  const decayTicks = opts.decayTicks ?? 0;
  if (!Number.isInteger(decayTicks) || decayTicks < 0) {
    return err(engineError(CORPSE_BAD_DECAY, `腐烂时长必须是 >= 0 的整数（0 = 永不），收到 ${String(opts.decayTicks)}`));
  }
  const cell = findCorpseCell(scene, opts.ground, opts.x, opts.z, opts.searchCells);
  if (cell === null) {
    return err(
      engineError(
        CORPSE_NO_SPACE,
        `(${opts.x.toFixed(2)}, ${opts.z.toFixed(2)}) 附近没有能放尸体的空地（已外扩到 ${String(Math.max(0, Math.floor(opts.searchCells ?? 2)))} 格）`,
      ),
    );
  }
  const c = opts.ground.centerOf(cell);
  const node = scene.spawn("corpse", null);
  if (!node.ok) return node;
  node.value.setLocalPosition(c.x, c.z);
  const made = scene.attach(node.value.id, () => new Corpse());
  if (!made.ok) {
    // 挂不上组件的话，刚 spawn 的节点是**画面上看得见、账上没有**的孤儿
    scene.destroy(node.value.id);
    scene.flush();
    return made;
  }
  made.value.cell = cell;
  made.value.decayAtTick = decayTicks === 0 ? 0 : opts.nowTick + decayTicks;
  made.value.items = encodeItems(items);
  scene.flush();
  return ok({ cell, nodeId: node.value.id, items, decayAtTick: made.value.decayAtTick });
}

/** 某一格上的尸体（没有就 `null`）。同格最多一具（见文件头 ②）。 */
export function corpseAt(scene: Scene, cell: number): Corpse | null {
  for (const c of scene.componentsOf<Corpse>(CORPSE_TYPE)) {
    if (c.node === null) continue;
    if (c.cell === cell) return c;
  }
  return null;
}

export interface CorpseModuleStats {
  /** 场上还有几具。 */
  readonly corpses: number;
  /** 累计烂掉了几具。 */
  readonly decayed: number;
}

export interface CorpseModuleHandle extends IModule {
  /**
   * ★ `init` / `start` / `update` 在这里写成了**必选**（`IModule` 里 `start` 是可选的）：
   *   调用方（宿主、判据）拿到的是这个 handle，而不是 `IModule`；
   *   留着可选就得写 `mod.start?.()` —— 而"忘了调 start"的症状是
   *   "尸体永远不烂"，与"腐烂逻辑坏了"长得一模一样。
   */
  init(ctx: ModuleContext): Result<void, EngineError>;
  start(): void;
  update(tick: number, dt: number): void;
  readonly stats: CorpseModuleStats;
}

export interface CorpseModuleOptions {
  readonly scene?: Scene;
  readonly id?: string;
}

/**
 * 腐烂驱动：每 tick 扫一遍，到点的销毁。
 *
 * ★ 判据口径是 **`tick >= decayAtTick` 就消失**（不是 `>`）："说好 600 tick" 就是
 *   第 600 tick 没的，晚一 tick 会让"第 600 tick 还看得见"变成可复现的错。
 * ★ `flush` 只在真的删了东西时调用：每 tick 一次空 flush 会让命令队列永远是脏的。
 */
export function createCorpseModule(opts: CorpseModuleOptions = {}): CorpseModuleHandle {
  let scene: Scene | null = opts.scene ?? null;
  let started = false;
  let decayed = 0;

  const mod: CorpseModuleHandle = {
    id: opts.id ?? "world.corpses",
    deps: [],

    init(ctx: ModuleContext): Result<void, EngineError> {
      if (scene === null) {
        const got = ctx.services.get(Services.Scene);
        if (got === undefined) {
          return err(
            engineError(
              CORPSE_NO_COMPONENT,
              "尸体模块需要一个 Scene：要么在 options 里传，要么先由宿主注册 Services.Scene",
            ),
          );
        }
        scene = got;
      }
      return ok(undefined);
    },

    start(): void {
      started = true;
    },

    stop(): void {
      started = false;
    },

    update(tick: number, _dt: number): void {
      const s = scene;
      if (s === null || !started) return;
      // ★ 先收集 id 再删：`destroy` 是结构性修改（走命令队列），
      //   边遍历边删会让 `componentsOf` 的返回数组在脚下变形。
      const due: number[] = [];
      for (const c of s.componentsOf<Corpse>(CORPSE_TYPE)) {
        if (c.node === null) continue;
        if (c.decayAtTick === 0) continue;
        if (tick < c.decayAtTick) continue;
        due.push(c.node.id);
      }
      if (due.length === 0) return;
      for (const id of due) s.destroy(id);
      // ★ flush 在循环**之后**：`destroy` 只是排队，逐条 flush 会让"一 tick 烂 20 具"
      //   做 20 次结构性提交（物理/渲染的中间状态会被看到）。
      s.flush();
      decayed += due.length;
    },

    get stats(): CorpseModuleStats {
      const s = scene;
      return { corpses: s === null ? 0 : s.countOf(CORPSE_TYPE), decayed };
    },
  };
  return mod;
}

export interface CorpseTake {
  readonly cell: number;
  readonly nodeId: number;
  /** 真的进包的（按 kind 升序）。 */
  readonly taken: LootTable;
  readonly takenCount: number;
  /** 尸体里还剩的（同上顺序）。 */
  readonly left: LootTable;
  readonly leftCount: number;
  /** 拿空了 ⇒ 节点已经销毁。 */
  readonly emptied: boolean;
}

export interface TakeCorpseOptions {
  /** 只拿这一种（省略 = 全都拿）。 */
  readonly kind?: string;
  /** 每一种**最多**拿几个（省略 = 拿光）。 */
  readonly amount?: number;
}

/**
 * 从 `cell` 上的尸体里取东西进 `ownerId` 的背包。
 *
 * 顺序见文件头 ⑤：**先看 → 先进包 → 最后扣尸体**。
 * 多条目是"全成或全不成"：中途失败把已经进包的原样退回。
 */
export function takeFromCorpse(
  scene: Scene,
  cell: number,
  ownerId: number,
  opts: TakeCorpseOptions = {},
): Result<CorpseTake, EngineError> {
  const corpse = corpseAt(scene, cell);
  if (corpse === null || corpse.node === null) {
    return err(engineError(CORPSE_NONE, `格子 ${String(cell)} 上没有尸体`));
  }
  const nodeId = corpse.node.id;
  const decoded = decodeItems(corpse.items);
  if (!decoded.ok) return decoded;
  const all = decoded.value;
  // ① 先算清楚"要拿哪些、各几个"：这一步不动任何状态
  let limit = Number.POSITIVE_INFINITY;
  if (opts.amount !== undefined) {
    if (!Number.isInteger(opts.amount) || opts.amount <= 0) {
      return err(engineError("INVENTORY.BAD_COUNT", `一次拿几个必须是正整数，收到 ${String(opts.amount)}`));
    }
    limit = opts.amount;
  }
  const take: LootEntry[] = [];
  for (const e of all) {
    if (opts.kind !== undefined && e.kind !== opts.kind) continue;
    take.push({ kind: e.kind, count: Math.min(e.count, limit) });
  }
  if (take.length === 0) {
    return err(engineError(CORPSE_NONE, `格子 ${String(cell)} 的尸体里没有「${String(opts.kind)}」`));
  }
  // ② 先进包（可能失败；失败时**世界没动**）
  const added: LootEntry[] = [];
  for (const e of take) {
    const r = addItem(scene, ownerId, e.kind, e.count);
    if (!r.ok) {
      // 见文件头 ⑤：全成或全不成 —— 已经进包的退回去
      for (const back of added) {
        const rb = takeItem(scene, ownerId, back.kind, back.count);
        // 退回失败只能透传：继续退回剩下的会掩盖第一处失败
        if (!rb.ok) return rb;
      }
      return r;
    }
    added.push(e);
  }
  // ③ 最后扣尸体（这一步之后尸体才会少东西，所以它必须是最后一步）
  const left: LootEntry[] = [];
  for (const e of all) {
    const keep = opts.kind === undefined || e.kind === opts.kind ? e.count - Math.min(e.count, limit) : e.count;
    if (keep > 0) left.push({ kind: e.kind, count: keep });
  }
  const emptied = left.length === 0;
  if (emptied) {
    scene.destroy(nodeId);
    scene.flush();
  } else {
    corpse.items = encodeItems(left);
  }
  return ok({
    cell,
    nodeId,
    taken: take,
    takenCount: lootTotal(take),
    left,
    leftCount: lootTotal(left),
    emptied,
  });
}
