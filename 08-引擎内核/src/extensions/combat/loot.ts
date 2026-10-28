/**
 * L4 · 击杀战利品（阶段 3：**打死之后要留下点什么**）
 *
 * 批61 让目标会死，但死完什么也不留：杀了 10 只兔子，背包里一块肉也没有。
 * 这一层补"击杀 → 产出"的最后一段，并且只做这一件事：**把一张配表变成背包里的物品**。
 *
 * ★★ 为什么是"进击杀者背包"而不是"掉在地上"
 *
 * 世界侧能表达的东西是 `ResourceMarker`，它的 `kind` 是 `SiteKind`（树/浆果/石头/燧石/草丛/芦苇），
 * 没有"肉"。硬塞一个不在 `SiteKind` 里的字符串，`drop-to-world.ts` 文件头已经记过结果：
 * 得到一个**能放下、但采不动、也刷不出**的资源点 —— 比"没掉落"更难查。
 * 要真的"地上有块肉"，得给 `SiteKind` 加 `carcass` 并同步图集、群系投放表、
 * 存档校验、导入管线 —— 那是另一批的事，届时这层的契约不用改
 *（它返回的是"没进包的那部分"，落地与否是宿主的决定）。
 *
 * ★★ 四个决定：
 *
 * ① **进不去的部分要报告，绝不静默**。
 *    背包满时静默丢的代价是"打了 10 只兔子只拿到 8 块肉，且不知道为什么"。
 *    所以 `LootGrant` 里 `granted` 与 `lost` 是**两个**清单，`lost` 每项带错误码，
 *    宿主可以据此弹提示、或者换个容器补发。**引擎报告事实，策略归宿主**。
 *
 * ② **失败即停，不跳过继续试下一种**。
 *    背包满了再去加别的种类只会更满（`addItem` 是按堆算名额的）。
 *    继续试的症状是"有的拿到了、有的没拿到"，而玩家看到的是"少了几样"；
 *    停在某一项上，`stoppedAt` 就是一句能说清的话。
 *
 * ③ **配表顺序不可信，一律按 `kind` 升序发**。
 *    背包格子（`maxStacks`）里"哪个先占位"在存档里是**可见**的，
 *    而它取决于对象字面量的书写顺序 —— 改一个字段的位置就会换存档内容。
 *    同一个理由在 `planRoles`（按 id 升序填配额）上已经用过一次。
 *
 * ④ **`count = 0` 报错，不当作"跳过"**。
 *    `0` 几乎总是配表里的占位符（"先写上，回头再定数"）。静默跳过之后，
 *    人会以为配好了，然后疑惑"为什么这只怪什么都不掉"。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { Component, FieldType, type ComponentRegistry, type ComponentSchema } from "../../core/scene/component.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { INVENTORY_TYPE, addItem } from "../inventory/inventory.ts";

/** 配表不合法（不是数组 / kind 为空 / count 非正整数）。 */
export const LOOT_BAD_TABLE = "LOOT.BAD_TABLE";
/** 击杀者不在场景里，或者没有背包组件。 */
export const LOOT_NO_OWNER = "LOOT.NO_OWNER";
/** 要挂战利品表的那个节点不在场景里。 */
export const LOOT_NO_NODE = "LOOT.NO_NODE";
/** 身上的物品清单读不出来（存档被改坏 / 来自更新版本）。 */
export const LOOT_BAD_ITEMS = "LOOT.BAD_ITEMS";
/** 场景的组件注册表里没有战利品组件。 */
export const LOOT_NO_COMPONENT = "LOOT.NO_COMPONENT";

export interface LootEntry {
  /** 物品种类（字符串：引擎不认识"肉"是什么）。 */
  readonly kind: string;
  readonly count: number;
}

export type LootTable = readonly LootEntry[];

export interface LootLost {
  readonly kind: string;
  readonly count: number;
  /** 为什么没放下（`INVENTORY.FULL` 之类，便于宿主决定怎么补）。 */
  readonly code: string;
}

export interface LootGrant {
  /** 真的进了包的（按 kind 升序）。 */
  readonly granted: readonly LootEntry[];
  readonly grantedCount: number;
  /** 没进包的（同上顺序；正常情况下是"某一段连续的尾部"）。 */
  readonly lost: readonly LootLost[];
  readonly lostCount: number;
  /** 从哪个 kind 开始没放下（`null` = 全放下）。 */
  readonly stoppedAt: string | null;
}

function isPositiveInt(n: unknown): n is number {
  return typeof n === "number" && Number.isInteger(n) && n > 0;
}

/**
 * 校验 + 规整一张配表：**合并重复 kind（相加）→ 按 kind 升序**。
 *
 * 合并而不是覆盖：`[{a,1},{a,2}]` 是"两个来源各给一份"的自然写法，
 * 覆盖会静默只给 2 个；而重复两次累加又会让"写错了两遍"多发一份 ——
 * 所以选择**合并**（词义上就是"加起来"），并把结果写进返回的清单，
 * 让"我配了两条 a"这件事在判据里可见。
 */
export function normalizeLoot(table: unknown): Result<LootTable, EngineError> {
  if (!Array.isArray(table)) {
    return err(engineError(LOOT_BAD_TABLE, `战利品表必须是数组，收到 ${typeof table}`));
  }
  const merged = new Map<string, number>();
  for (let i = 0; i < table.length; i++) {
    const e = table[i] as Partial<LootEntry> | undefined;
    if (e === undefined || typeof e !== "object") {
      return err(engineError(LOOT_BAD_TABLE, `第 ${String(i)} 项不是对象`));
    }
    if (typeof e.kind !== "string" || e.kind.length === 0) {
      return err(engineError(LOOT_BAD_TABLE, `第 ${String(i)} 项的 kind 必须是非空字符串，收到 ${JSON.stringify(e.kind)}`));
    }
    if (!isPositiveInt(e.count)) {
      // 见文件头 ④
      return err(
        engineError(LOOT_BAD_TABLE, `第 ${String(i)} 项「${e.kind}」的 count 必须是正整数，收到 ${String(e.count)}`),
      );
    }
    merged.set(e.kind, (merged.get(e.kind) ?? 0) + e.count);
  }
  const out: LootEntry[] = [...merged.entries()].map(([kind, count]) => ({ kind, count }));
  // 见文件头 ③
  out.sort((x, y) => (x.kind < y.kind ? -1 : x.kind > y.kind ? 1 : 0));
  return ok(out);
}

/** 配表的总件数（校验失败按 0 计 —— 它只用于日志/统计）。 */
export function lootTotal(table: LootTable): number {
  let n = 0;
  for (const e of table) n += e.count;
  return n;
}

/**
 * 把配表发给 `ownerId` 的背包。
 *
 * 顺序：**先校验（配表 + 拥有者），再逐项发放**。校验不过时一点状态都不动 ——
 * 与 `harvestInto`（先看→进包→再摘）、`dropIntoWorld`（预检→找格→放下）同一条纪律。
 *
 * ★ 拥有者检查放在**发放之前**：否则"击杀者没有背包"会以
 *   `lost` 的形式出现，而 `lost` 的语义是"背包满了"，两者混在一起会让人去清背包。
 */
export function grantLoot(scene: Scene, ownerId: number, table: unknown): Result<LootGrant, EngineError> {
  const norm = normalizeLoot(table);
  if (!norm.ok) return norm;
  const entries = norm.value;

  const owner = scene.find(ownerId);
  if (owner === undefined || owner === null) {
    return err(engineError(LOOT_NO_OWNER, `击杀者 ${String(ownerId)} 不在场景里（战利品没有去处）`));
  }
  if (owner.get(INVENTORY_TYPE) === undefined) {
    return err(engineError(LOOT_NO_OWNER, `击杀者 ${String(ownerId)} 没有背包组件 —— 先 makeInventory()`));
  }

  const granted: LootEntry[] = [];
  const lost: LootLost[] = [];
  let stoppedAt: string | null = null;

  for (let i = 0; i < entries.length; i++) {
    const e = entries[i]!;
    if (stoppedAt !== null) {
      // 已经停了：后面的**全部**记为没拿到（见文件头 ②）
      lost.push({ kind: e.kind, count: e.count, code: "LOOT.SKIPPED" });
      continue;
    }
    const r = addItem(scene, ownerId, e.kind, e.count);
    if (r.ok) {
      granted.push({ kind: e.kind, count: e.count });
      continue;
    }
    stoppedAt = e.kind;
    lost.push({ kind: e.kind, count: e.count, code: r.error.code });
  }

  return ok({
    granted,
    grantedCount: lootTotal(granted),
    lost,
    lostCount: lootTotal(lost),
    stoppedAt,
  });
}

// ---------------------------------------------------------------------------
// 战利品表**跟着实体走**（批123）
// ---------------------------------------------------------------------------

/**
 * 实体身上的战利品表组件。
 *
 * ★★ 为什么不是模块里的旁表（`Map<nodeId, table>`）：旁表是**进程内状态**，
 *   而实体是**场景里的东西**。两者一旦不同步，症状极隐蔽 ——
 *   读档会把整个场景换成存档里的那批节点（`loadScene`），旁表却还按旧 id 索引：
 *   于是"读档之后打死的怪什么都不掉"，而且没有任何报错。
 *   （同一类事在 `lootOf` 之前已经在 `kindOf` 上发生过一次。）
 * ★ 挂在实体上之后，**任何**有血量的东西都能带战利品表 —— 判据可以自己造
 *   "会掉东西的靶子"，不必等世界里碰巧还有一只活着的兔子。
 */
export const LOOT_TYPE = "game.loot";

/**
 * 物品清单的字段名与格式：`"kind:count"`，按 `kind` 升序。
 *
 * ★ 与尸体里的那份**是同一套编码**（`corpse.ts` 直接复用这里的两个函数）：
 *   两份编码的那天，"身上的表"与"地上的表"会在某个边界输入上分叉，
 *   而症状是"肉变成了 kind = `a:b`"。
 * ★ 存成字符串数组而不是 JSON：`Component` 的 schema 里唯一可校验的数组类型
 *   就是 `StringArray`（标签、配方都走它）。
 */
const LOOT_SCHEMA: ComponentSchema = {
  type: LOOT_TYPE,
  fields: { items: FieldType.StringArray },
};

export class LootHolding extends Component {
  /** `"kind:count"`，按 `kind` 升序（空数组 = 不掉东西）。 */
  items: string[] = [];

  readonly schema: ComponentSchema = LOOT_SCHEMA;
}

export function registerLootComponent(registry: ComponentRegistry): void {
  if (!registry.has(LOOT_TYPE)) registry.register(LOOT_SCHEMA, () => new LootHolding());
}

/** 一张配表 → `items` 字段的内容（调用方保证已经过 `normalizeLoot`）。 */
export function encodeItems(table: LootTable): string[] {
  const out: string[] = [];
  for (const e of table) out.push(`${e.kind}:${String(e.count)}`);
  return out;
}

/**
 * `items` 字段 → 配表。**读不出来就报错，不静默丢**（静默丢的症状是
 * "有战利品表但打死了不掉东西"，比报错难查得多）。
 */
export function decodeItems(items: readonly string[]): Result<LootTable, EngineError> {
  const out: LootEntry[] = [];
  for (let i = 0; i < items.length; i++) {
    const s = items[i]!;
    // ★ `lastIndexOf`：kind 是配置里来的字符串，理论上能含冒号。
    //   用 `indexOf` 的话 `"a:b":2` 会被读成 kind = `a`、数量解析失败。
    const at = s.lastIndexOf(":");
    if (at <= 0) {
      return err(engineError(LOOT_BAD_ITEMS, `第 ${String(i)} 项「${s}」不是「种类:数量」`, { index: i, raw: s }));
    }
    const kind = s.slice(0, at);
    const raw = s.slice(at + 1);
    const n = Number(raw);
    // ★ 连"规范写法"一起卡：`02`、`2.0`、`1e1` 都能过 Number，但写回去就对不上了
    if (!Number.isInteger(n) || n <= 0 || String(n) !== raw) {
      return err(engineError(LOOT_BAD_ITEMS, `第 ${String(i)} 项「${s}」的数量不是正整数`, { index: i, raw: s }));
    }
    out.push({ kind, count: n });
  }
  return ok(out);
}

/**
 * 把一张配表挂到 `nodeId` 身上（幂等：已经有就换内容）。
 *
 * 空表 ⇒ 挂一个空组件（**不是**不挂）：不挂的话，"这只怪以前掉东西、
 * 现在改配成不掉了"这种改动会静默保留旧表。
 */
export function attachLoot(scene: Scene, nodeId: number, table: unknown): Result<LootTable, EngineError> {
  const norm = normalizeLoot(table);
  if (!norm.ok) return norm;
  const items = encodeItems(norm.value);
  const node = scene.find(nodeId);
  if (node === undefined) {
    return err(engineError(LOOT_NO_NODE, `节点 ${String(nodeId)} 不在场景里 —— 战利品表没地方挂`));
  }
  const have = node.get<LootHolding>(LOOT_TYPE);
  if (have !== undefined) {
    have.items = items;
    return ok(norm.value);
  }
  if (!scene.components.has(LOOT_TYPE)) {
    // 没有注册就 attach 会失败，但失败原因只说"组件没注册"，不说"是谁要挂" ——
    // 这一层知道是谁，所以在这里就把话说全。
    return err(engineError(LOOT_NO_COMPONENT, `场景的组件注册表里没有 ${LOOT_TYPE} —— 先 registerLootComponent()`));
  }
  const made = scene.attach(nodeId, () => {
    const c = new LootHolding();
    c.items = items;
    return c;
  });
  if (!made.ok) return made;
  // ★ `attach` 是**排队**的（命令队列，下一次 `flush` 才落到节点上）：
  //   不在这里刷一次的话，紧接着的 `node.get(LOOT_TYPE)` 读不到 —— 于是
  //   "同一只怪挂两次表"会真的挂上两个组件，而 `lootOfNode` 取到的是第一个。
  //   `spawnCorpse` 出于同一个理由在同一步 flush。
  scene.flush();
  return ok(norm.value);
}

/**
 * 这个实体被打死会掉什么。
 *
 * ★ 返回 `Result` 而不是裸的 `T | null`：`ok(null)` 与"有表但读不出来"必须分开。
 *   混在一起的话，存档被改坏时玩家的东西凭空消失，而日志里一个字都没有。
 */
export function lootOfNode(scene: Scene, nodeId: number): Result<LootTable | null, EngineError> {
  const c = scene.find(nodeId)?.get<LootHolding>(LOOT_TYPE);
  if (c === undefined) return ok(null);
  const decoded = decodeItems(c.items);
  if (!decoded.ok) return decoded;
  return ok(decoded.value.length === 0 ? null : decoded.value);
}
