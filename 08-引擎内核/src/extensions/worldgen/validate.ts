/**
 * L4 · 世界计划校验
 *
 * ★ 这个文件存在的唯一理由：**一条永远报绿的校验等于没有校验**。
 *   所以它有两件事必须做到：
 *   ① 真的能报出"有陆地到不了"（判据里用 `repair:false` 生成的世界验证这一点）；
 *   ② 报出的不是一句"不连通"，而是**可行动的信息**：多少格、在哪、最大分量多大。
 *      只报一个布尔值的校验器，第一次红的时候没人知道该看哪儿。
 *
 * ★ 为什么不把校验塞进 `generateWorld`：
 *   生成和校验分开，才能拿"别人给的计划"（比如从存档读回来的、或者编辑器里手改的）
 *   走同一套校验。合并在一起就只能校验自己刚生成的东西 —— 那叫自证，不叫校验。
 */

import type { WorldPlan } from "./worldgen.ts";
import { findComponents, isPassable } from "./worldgen.ts";

export interface WorldValidation {
  readonly ok: boolean;
  readonly passable: number;
  readonly impassable: number;
  /** 可通行区域被分成了几块。1 表示全连通（或根本没有陆地）。 */
  readonly components: number;
  /** 最大分量的格数。 */
  readonly largest: number;
  /**
   * 最大分量的分量编号（没有可通行格时为 -1）。
   * ★ 必须显式给出，否则调用方只能自己再扫一遍 `regionOf` 去"猜"哪个是主分量 ——
   *   而猜法（"第一个非 -1 的编号"）在分量按最小下标排序、最大分量却不一定是第 0 个时是错的。
   */
  readonly mainRegion: number;
  /** 非最大分量的可通行格数 —— 这就是"玩家永远走不到的地方"。 */
  readonly unreachable: number;
  /** 每格的连通分量编号，不可通行格为 -1。与 `plan.kinds` 同序。 */
  readonly regionOf: readonly number[];
  /** 最多 8 个不可达格的格子下标（按升序），够定位就行，不必全列。 */
  readonly unreachableSamples: readonly number[];
  readonly sites: number;
  /** 落在不可通行格上的投放点数（资源刷在海里 = 玩家永远拿不到）。 */
  readonly sitesOnImpassable: number;
  /** 越界的投放点数（坐标超出 `[0, width*FIXED_UNITS)`）。 */
  readonly sitesOutOfBounds: number;
}

const MAX_SAMPLES = 8;

/**
 * 校验一个世界计划。
 *
 * `ok` 的判据只有三条，且都是"玩家能不能玩到"级别的硬条件：
 *   ① 没有到不了的陆地；
 *   ② 没有刷在不可通行格上的资源点；
 *   ③ 没有越界的资源点。
 * 好玩不好玩、平衡不平衡**不在**这里管 —— 那是设计问题，不是可机器验证的问题。
 */
export function validateWorld(plan: WorldPlan): WorldValidation {
  const { width, height, kinds } = plan;
  const total = width * height;
  const { regionOf, groups } = findComponents(width, height, kinds);

  let passable = 0;
  for (let i = 0; i < total; i++) {
    if (isPassable(kinds[i]!)) passable++;
  }
  const impassable = total - passable;

  let largest = 0;
  let mainIdx = -1;
  for (let i = 0; i < groups.length; i++) {
    const n = groups[i]!.length;
    if (n > largest) {
      largest = n;
      mainIdx = i;
    }
  }
  const unreachable = passable - largest;

  const unreachableSamples: number[] = [];
  if (unreachable > 0) {
    for (let i = 0; i < total && unreachableSamples.length < MAX_SAMPLES; i++) {
      const r = regionOf[i]!;
      if (r !== -1 && r !== mainIdx) unreachableSamples.push(i);
    }
  }

  let sitesOnImpassable = 0;
  let sitesOutOfBounds = 0;
  const limitX = width * 256;
  const limitZ = height * 256;
  for (const s of plan.sites) {
    if (s.x < 0 || s.z < 0 || s.x >= limitX || s.z >= limitZ) {
      sitesOutOfBounds++;
      continue;
    }
    const cx = Math.floor(s.x / 256);
    const cz = Math.floor(s.z / 256);
    const cell = cz * width + cx;
    if (!isPassable(kinds[cell]!)) sitesOnImpassable++;
  }

  return {
    ok: unreachable === 0 && sitesOnImpassable === 0 && sitesOutOfBounds === 0,
    passable,
    impassable,
    components: groups.length,
    largest,
    mainRegion: mainIdx,
    unreachable,
    regionOf: Array.from(regionOf),
    unreachableSamples,
    sites: plan.sites.length,
    sitesOnImpassable,
    sitesOutOfBounds,
  };
}
