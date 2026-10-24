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

export interface Harvested {
  readonly cell: number;
  readonly kind: SiteKind;
  readonly nodeId: number;
  /** `resource` = 任务表刷出来的；`site` = 计划里自带的投放点。 */
  readonly source: "resource" | "site";
}

export interface HarvestOptions {
  /**
   * 名额释放回调（把格子从去重索引里去掉）。
   * 返回 `false` 表示索引里本来就没有这一格 —— 不当作错误，但会被记在结果的语义里：
   * `harvestAt` 只在**真的摘掉了节点**时才调用它。
   */
  readonly onRelease?: (cell: number) => boolean;
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
export function peekResourceAt(scene: Scene, cell: number): { readonly kind: SiteKind; readonly source: "resource" | "site" } | null {
  for (const r of scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)) {
    if (r.cell === cell && r.node !== null) return { kind: r.kind, source: "resource" };
  }
  for (const m of scene.componentsOf<SiteMarker>(SITE_TYPE)) {
    if (m.cell === cell && m.node !== null) return { kind: m.kind, source: "site" };
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

  // ★ 先看再生资源，再看计划投放点：同一个格子上如果两种都有（不该发生，但存档可以伪造），
  //   摘掉"后长出来的那个"更符合直觉 —— 而两种都摘会一次调用删两个节点。
  for (const r of scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)) {
    if (r.cell !== cell || r.node === null) continue;
    const nodeId = r.node.id;
    const kind = r.kind;
    scene.destroy(nodeId);
    scene.flush();
    opts.onRelease?.(cell);
    return ok({ cell, kind, nodeId, source: "resource" });
  }
  for (const m of scene.componentsOf<SiteMarker>(SITE_TYPE)) {
    if (m.cell !== cell || m.node === null) continue;
    const nodeId = m.node.id;
    const kind = m.kind;
    scene.destroy(nodeId);
    scene.flush();
    opts.onRelease?.(cell);
    return ok({ cell, kind, nodeId, source: "site" });
  }

  return err(
    engineError(
      HARVEST_NOTHING,
      `格子 ${String(cell)} 上没有资源（再生 ${String(scene.countOf(RESOURCE_TYPE))} 个 / 投放点 ${String(scene.countOf(SITE_TYPE))} 个）`,
    ),
  );
}
