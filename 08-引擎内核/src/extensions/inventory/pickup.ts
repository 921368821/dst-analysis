/**
 * L4 · 半径拾取（一批资源 → 背包）
 *
 * ★ 为什么不是"把 `harvestInto` 循环调一遍"了事：
 *   ① **顺序**：必须先按"最近优先"排序，否则"背包满了"时拿到的是**随机那一个**
 *      —— 玩家会觉得"我明明站在树边上，却捡了远处的草"。所以排序键是
 *      `(距离², nodeId)`：距离相同（同格多资源）时用 id 兜底，保证可回放。
 *   ② **停止条件**：背包满了就**立刻停**，不是继续试下一个。继续试的症状是
 *      "按一次把半径内的东西全试了一遍"，而每个失败的 `addItem` 都会走一遍
 *      合并逻辑（白白 O(堆数)），更重要的是**玩家看不出为什么只捡到一半**。
 *   ③ **报告剩余**：`remaining` 是"半径内没被拾走的有几个"。没有这个数，
 *      "背包满了"与"半径没覆盖到"在画面上都是"东西还在那儿"。
 *
 * ★★ 与 `harvestInto` 的分工：那个函数管**一格**的原子性（先看→进包→再摘），
 *   这个函数管**一批**的顺序与停止条件。两者都不碰世界的生成规则。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { SiteKind } from "../worldgen/worldgen.ts";
import { RESOURCE_TYPE, ResourceMarker } from "../worldgen/task-module.ts";
import { HARVEST_NOTHING } from "../worldgen/harvest.ts";
import { peekResourceAt } from "../worldgen/harvest.ts";
import { harvestInto } from "./harvest-into.ts";

export interface Picked {
  readonly cell: number;
  readonly kind: SiteKind;
  /** 背包里这种物品现在的总数（含本次）。 */
  readonly total: number;
}

export interface PickupFailure {
  readonly cell: number;
  readonly code: string;
  readonly message: string;
}

export interface PickupResult {
  readonly picked: readonly Picked[];
  /** 因为**非"资源没了"**的原因失败的那一次（背包满 / 无主）。null = 一路顺利。 */
  readonly failed: PickupFailure | null;
  /** 半径内还剩几个没被拾走（含因失败而停下的那些）。 */
  readonly remaining: number;
  /** 半径内一共找到几个（`picked + remaining`，用来分辨"半径没覆盖"与"背包满"）。 */
  readonly inRange: number;
}

export interface PickupOptions {
  /**
   * 每个资源给多少个。可以是固定值，也可以是**按种类**的函数 ——
   * 产品上"灌木给 2 个浆果、燧石堆给 1 块"是常态，写死 1 会让
   * "amount 固定 1"成为背包系统的长期缺口。
   */
  readonly amount?: number | ((kind: SiteKind) => number);
  /** 名额释放回调（交回 `task-module.releaseCell`）。 */
  readonly onRelease?: (cell: number) => boolean;
  /** 一次最多拾几个（默认 8）。防止"站在林子里按一下把整片林子吸走"。 */
  readonly max?: number;
}

const DEFAULT_MAX = 8;

/**
 * 拾取 (x,z) 半径 `radius` 内的世界资源，按"最近优先"进背包。
 *
 * ★ 没有任何资源在范围内**不是错误**：返回空结果。它和"背包满了"必须能被区分开
 *   —— 前者是正常情况（站在空地上按了键），后者是要提示玩家的状态。
 */
export function pickupNearby(
  scene: Scene,
  x: number,
  z: number,
  radius: number,
  ownerId: number,
  opts: PickupOptions = {},
): Result<PickupResult, EngineError> {
  if (!(radius >= 0)) return err(engineError("PICKUP.BAD_RADIUS", `拾取半径必须 ≥ 0，收到 ${radius}`));
  const max = Math.max(1, Math.floor(opts.max ?? DEFAULT_MAX));
  // ★ 先落到局部 const 再窄化：直接在闭包里窄化 `opts.amount`（属性访问）不保值，
  //   TS 会把闭包内的类型还原成联合 —— 于是 `amountOf(c.kind)` 的类型是
  //   `number | ((kind)=>number)`，编译期就炸。
  const amountOpt = opts.amount;
  const amountOf = typeof amountOpt === "function" ? amountOpt : () => amountOpt ?? 1;

  // ---- ① 先收集候选（不能在遍历组件的同时销毁节点：那是"边读边改"）
  const cand: Array<{ nodeId: number; cell: number; d2: number; kind: SiteKind }> = [];
  for (const m of scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)) {
    const node = m.node;
    if (node === null) continue;
    const p = node.worldPosition;
    const dx = p.x - x;
    const dz = p.y - z;
    const d2 = dx * dx + dz * dz;
    if (d2 > radius * radius) continue;
    // ★ 种类在这一步就记下来：per-kind 产出要在调 `harvestInto` **之前**知道种类，
    //   而"这一格上是什么"只有世界侧知道（`peekResourceAt` 的单一事实源）。
    const peek = peekResourceAt(scene, m.cell);
    if (peek === null) continue;
    cand.push({ nodeId: node.id, cell: m.cell, d2, kind: peek.kind });
  }
  cand.sort((a, b) => (a.d2 !== b.d2 ? a.d2 - b.d2 : a.nodeId - b.nodeId));

  // 同一格有多条资源标记是不该发生的；真发生时只拾第一次（后一次会拿到"没有资源"）
  const seenCell = new Set<number>();
  const picked: Picked[] = [];
  let failed: PickupFailure | null = null;
  let skippedSameCell = 0;

  for (const c of cand) {
    if (picked.length >= max) break;
    if (seenCell.has(c.cell)) {
      skippedSameCell++;
      continue;
    }
    seenCell.add(c.cell);
    const r = harvestInto(scene, c.cell, ownerId, { amount: amountOf(c.kind), onRelease: opts.onRelease });
    if (!r.ok) {
      // "这一格已经没东西了"是并发/重入的正常结果，不算失败；其它（背包满/无主）要停下来
      if (r.error.code === HARVEST_NOTHING) continue;
      failed = { cell: c.cell, code: r.error.code, message: r.error.message };
      break;
    }
    picked.push({ cell: r.value.cell, kind: r.value.kind, total: r.value.total });
  }

  // 半径内找到的全部候选里，没被成功拾走的数量（含"背包满了"与"超出单次上限"两类）
  return ok({
    picked,
    failed,
    remaining: Math.max(0, cand.length - picked.length),
    inRange: cand.length,
  });
}
