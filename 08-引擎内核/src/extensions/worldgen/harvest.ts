/**
 * L4 · 采集（把资源节点从世界上摘掉，并把名额还回去）
 *
 * ★ 为什么这一层必须存在：在它之前，世界里只有"长出来"，没有"被拿走" ——
 *   于是任务表是一条**单调增长**曲线，只为它加了一个全局上限兜底（见 `task-module.ts`）。
 *   而"采不走"这件事在画面上完全看不出来：资源就一直在那儿。
 *
 * ★★ 采集是**两块状态**同时变化，只做一半就会出两类静默 bug：
 *   ① 场景侧：节点要被销毁（否则砍完了树还在画面上）；
 *   ② 去重索引侧：格子名额要被释放（否则那一格永远刷不出新东西，
 *      而现场表现是"这片林子砍空了就再也不长了"，没人会怀疑是索引）。
 *   所以 `harvestAt` 接受一个可选的 `onRelease` 回调 —— 由宿主/模块把名额还回去，
 *   而**测试可以两边都验**。只把节点删掉不管索引的写法，任何单个判据都抓不住。
 *
 * ★ 采集什么都不给（没有物品栏）：这一层只回答"东西没了"，"玩家得到了什么"属于
 *   物品/背包系统，不该顺手塞进世界生成。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { SiteKind } from "./worldgen.ts";
import { SITE_TYPE, SiteMarker } from "./assemble.ts";
import { RESOURCE_TYPE, ResourceMarker } from "./task-module.ts";

/** 这一格上什么都没有（空地 / 越界 / 已经被采过）。 */
export const HARVEST_NOTHING = "HARVEST.NOTHING";
/** 格子下标不合法（负数 / 小数 / NaN）。 */
export const HARVEST_BAD_CELL = "HARVEST.BAD_CELL";
/** 这一次采几个不合法（0 / 负数 / NaN）—— 0 个的采摘是调用方 bug，不是"什么都不做"。 */
export const HARVEST_BAD_AMOUNT = "HARVEST.BAD_AMOUNT";

/** 这一格上有什么（**只看，不动场景**）。 */
export interface PeekedResource {
  readonly kind: SiteKind;
  readonly source: "resource" | "site";
  /** 这一格还有几个物品（`site` 恒为 1：投放点没有堆叠概念）。 */
  readonly count: number;
}

export interface Harvested {
  readonly cell: number;
  readonly kind: SiteKind;
  /** 这一格上资源的节点 id。★ `left === 0` 时它已经失效 —— 那正是"被销毁"的证据。 */
  readonly nodeId: number;
  /** 这一次拿走几个（= `min(请求量, 原有 count)`）。 */
  readonly taken: number;
  /** 这一格还剩几个。**0 表示堆已见底**（节点已销毁、名额已释放）。 */
  readonly left: number;
  /** `resource` = 任务表刷出来的；`site` = 计划里自带的投放点。 */
  readonly source: "resource" | "site";
}

export interface HarvestOptions {
  /**
   * 名额释放回调（把格子从去重索引里去掉）。
   * 返回 `false` 表示索引里本来就没有这一格 —— 不当作错误，但会被记在结果的语义里：
   * `harvestAt` 只在**这一堆真的见底**时才调用它。
   */
  readonly onRelease?: (cell: number) => boolean;
  /**
   * 这一次**最多**拿走几个。省略 = 能拿多少拿多少（`Infinity`）。
   *
   * ★ 语义在批122 变了，而且只变了这一处：以前它是"这一格的产量"（节点必被销毁），
   *   现在是"这一次的上限"（拿不完就留在地上）。同一件事的两种说法在
   *   `count = 1` 的自然节点上**完全等价** —— 这正是老调用方一行不改也照样对的原因。
   * ★ 传 0 或负数会报 `HARVEST.BAD_AMOUNT`，不是"什么都不做"：
   *   静默返回 `taken = 0` 会让调用方以为采到了东西。
   */
  readonly amount?: number;
}

function isCellIndex(v: number): boolean {
  return Number.isInteger(v) && v >= 0;
}

/**
 * 看一眼 `cell` 上有什么，**不动场景**。
 *
 * ★ 为什么需要它：`harvestAt` 是破坏性的，而"先收进背包再摘掉"这个顺序要求
 *   在动手之前就知道种类（否则背包满了会把东西摘下来又丢不掉）。
 *   顺序反过来（先摘、再发现背包满）会让资源**凭空消失** —— 画面上树没了，
 *   而玩家什么也没拿到。
 */
export function peekResourceAt(scene: Scene, cell: number): PeekedResource | null {
  for (const r of scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)) {
    if (r.cell === cell && r.node !== null) {
      // ★ 兜底 1：`count` 是可以在存档里被伪造的（0 / 负数），而 0 个的空堆
      //   既采不动也不会被销毁。把它当 1 是唯一能让这个格子"能被打扫干净"的解释。
      return { kind: r.kind, source: "resource", count: Math.max(1, r.count) };
    }
  }
  for (const m of scene.componentsOf<SiteMarker>(SITE_TYPE)) {
    if (m.cell === cell && m.node !== null) return { kind: m.kind, source: "site", count: 1 };
  }
  return null;
}

/**
 * 采走 `cell` 上的资源。
 *
 * 顺序：先找到"是哪一种"，再销毁节点，最后释放名额 —— **销毁是不可逆的**，
 * 所以任何校验都必须在它之前。
 */
export function harvestAt(scene: Scene, cell: number, opts: HarvestOptions = {}): Result<Harvested, EngineError> {
  if (!isCellIndex(cell)) {
    return err(engineError(HARVEST_BAD_CELL, `格子下标必须是 ≥ 0 的整数，收到 ${String(cell)}`));
  }
  const askRaw = opts.amount === undefined ? Number.POSITIVE_INFINITY : opts.amount;
  if (!(askRaw > 0)) {
    return err(engineError(HARVEST_BAD_AMOUNT, `这次采几个必须是正数，收到 ${String(opts.amount)}`));
  }
  // 有限值取整（小数是调用方的错，向下取整比"多给"诚实）；`Infinity` 保持原样
  const ask = Number.isFinite(askRaw) ? Math.max(1, Math.floor(askRaw)) : Number.POSITIVE_INFINITY;

  /**
   * 见底才销毁 + 还名额。**只有这一处**做这件事 ——
   * 两条来源（再生 / 投放点）都从这里出去，写成两份的话变异只会打到第一份，
   * 而"投放点采光了不还名额"的症状是那一格永远刷不出新东西。
   */
  const settle = (nodeId: number, kind: SiteKind, source: "resource" | "site", have: number): Harvested => {
    const taken = Math.min(ask, have);
    const left = have - taken;
    if (left === 0) {
      scene.destroy(nodeId);
      scene.flush();
      opts.onRelease?.(cell);
    }
    return { cell, kind, nodeId, taken, left, source };
  };

  // ★ 先看再生资源，再看计划投放点：同一个格子上如果两种都有（不该发生，但存档可以伪造），
  //   摘掉"后长出来的那个"更符合直觉 —— 而两种都摘会一次调用删两个节点。
  for (const r of scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)) {
    if (r.cell !== cell || r.node === null) continue;
    const have = Math.max(1, r.count);
    const out = settle(r.node.id, r.kind, "resource", have);
    // ★ 记账在 `settle` 之后：它决定"见底了没有"，而 `count` 必须与那个决定一致。
    //   在之前写会让"见底却不销毁"和"销毁了却还剩 1 个"这两种错都变得不可能被看见。
    r.count = out.left;
    return ok(out);
  }
  for (const m of scene.componentsOf<SiteMarker>(SITE_TYPE)) {
    if (m.cell !== cell || m.node === null) continue;
    // 投放点没有堆叠：恒 1 份，采一次就投完了
    return ok(settle(m.node.id, m.kind, "site", 1));
  }

  return err(
    engineError(
      HARVEST_NOTHING,
      `格子 ${String(cell)} 上没有资源（再生 ${String(scene.countOf(RESOURCE_TYPE))} 个 / 投放点 ${String(scene.countOf(SITE_TYPE))} 个）`,
    ),
  );
}
