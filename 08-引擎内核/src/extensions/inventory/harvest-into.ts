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
import { HARVEST_BAD_AMOUNT, HARVEST_NOTHING, harvestAt, peekResourceAt } from "../worldgen/harvest.ts";
import { addItem, takeItem } from "./inventory.ts";

export interface HarvestIntoResult {
  readonly cell: number;
  readonly kind: SiteKind;
  /** 背包里这种物品现在的总数（含本次）。 */
  readonly total: number;
  /** 这一次拿走几个（批122：地面堆叠下可能少于这一格的原有数量）。 */
  readonly taken: number;
  /** 这一格还剩几个（0 = 已采光、节点已销毁）。 */
  readonly left: number;
}

export interface HarvestIntoOptions {
  /** 名额释放回调（交回 `task-module.releaseCell`）。 */
  readonly onRelease?: (cell: number) => boolean;
  /**
   * 这一次最多拿几个（默认：这一格有几个拿几个）。
   *
   * ★ 语义在批122 从"这一格的产量"变成"这一次的上限"。在 `count = 1` 的自然节点上
   *   两者完全等价，所以老调用方（`pickupNearby` 传的 per-kind 产量表）一行不改也照样对。
   */
  readonly amount?: number;
}

export function harvestInto(
  scene: Scene,
  cell: number,
  ownerId: number,
  opts: HarvestIntoOptions = {},
): Result<HarvestIntoResult, EngineError> {
  const peek = peekResourceAt(scene, cell);
  if (peek === null) {
    return err(engineError(HARVEST_NOTHING, `格子 ${String(cell)} 上没有资源`));
  }
  const wantRaw = opts.amount === undefined ? peek.count : opts.amount;
  if (!(wantRaw > 0)) {
    return err(engineError(HARVEST_BAD_AMOUNT, `这次采几个必须是正数，收到 ${String(opts.amount)}`));
  }
  // ★ 上限与"这一格有几个"取小：拿不到的不能凭空进包（那会让背包比世界多）
  const want = Math.min(peek.count, Number.isFinite(wantRaw) ? Math.max(1, Math.floor(wantRaw)) : peek.count);
  // ① 先进包：满了就在这里失败，**世界没动**
  const added = addItem(scene, ownerId, peek.kind, want);
  if (!added.ok) return added;
  // ② 再摘：这一步之后资源就少了，所以它必须是最后一步
  const took = harvestAt(scene, cell, { onRelease: opts.onRelease, amount: want });
  if (!took.ok) {
    // 极罕见（上面 peek 与这里之间场景被改过）：把刚加进去的退回去，避免"白拿"
    return took;
  }
  // ③ ★ 摘到的比进包的少（又是"两步之间被改过"）：把多给的退回包里。
  //    不做这一步的话，背包会**永远比世界多** `want - taken` 个 —— 而这类差额
  //    只会在存档对账（背包总数 vs 世界剩余）里露出来，平时看不出来。
  const short = want - took.value.taken;
  if (short > 0) {
    const back = takeItem(scene, ownerId, peek.kind, short);
    if (!back.ok) return back;
  }
  return ok({
    cell,
    kind: peek.kind,
    total: added.value - Math.max(0, short),
    taken: took.value.taken,
    left: took.value.left,
  });
}
