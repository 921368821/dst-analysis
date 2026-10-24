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
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { INVENTORY_TYPE, addItem } from "../inventory/inventory.ts";

/** 配表不合法（不是数组 / kind 为空 / count 非正整数）。 */
export const LOOT_BAD_TABLE = "LOOT.BAD_TABLE";
/** 击杀者不在场景里，或者没有背包组件。 */
export const LOOT_NO_OWNER = "LOOT.NO_OWNER";

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
