/**
 * L4 · 采集 → 背包（两层的**组合**，单独一个文件）
 *
 * ★ 为什么组合放在这里，而不是让 worldgen 依赖 inventory：
 *   世界生成必须是"可以没有玩家"的（离线生成、批量出图、内容指纹）。
 *   一旦它认识背包，"生成一个世界"就会要求"有个玩家"。
 *
 * ★★ 顺序是硬约束：**先看 → 再进包 → 最后摘**。
 *   反过来（先摘再进包）时，背包满了会把资源摘下来又丢不掉 ——
 *   画面上树倒了、玩家什么都没拿到，而所有计数都自洽。这类"东西凭空消失"
 *   在验收里最难发现，因为没有任何异常。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { SiteKind } from "../worldgen/worldgen.ts";
import { HARVEST_NOTHING, harvestAt, peekResourceAt } from "../worldgen/harvest.ts";
import { addItem } from "./inventory.ts";

export interface HarvestIntoResult {
  readonly cell: number;
  readonly kind: SiteKind;
  /** 背包里这种物品现在的总数（含本次）。 */
  readonly total: number;
}

export interface HarvestIntoOptions {
  /** 名额释放回调（交回 `task-module.releaseCell`）。 */
  readonly onRelease?: (cell: number) => boolean;
  /** 这次的产出数量（默认 1）。 */
  readonly amount?: number;
}

export function harvestInto(
  scene: Scene,
  cell: number,
  ownerId: number,
  opts: HarvestIntoOptions = {},
): Result<HarvestIntoResult, EngineError> {
  const amount = opts.amount ?? 1;
  const peek = peekResourceAt(scene, cell);
  if (peek === null) {
    return err(engineError(HARVEST_NOTHING, `格子 ${String(cell)} 上没有资源`));
  }
  // ① 先进包：满了就在这里失败，**世界没动**
  const added = addItem(scene, ownerId, peek.kind, amount);
  if (!added.ok) return added;
  // ② 再摘：这一步之后资源就没了，所以它必须是最后一步
  const took = harvestAt(scene, cell, { onRelease: opts.onRelease });
  if (!took.ok) {
    // 极罕见（上面 peek 与这里之间场景被改过）：把刚加进去的退回去，避免"白拿"
    return took;
  }
  return ok({ cell, kind: peek.kind, total: added.value });
}
