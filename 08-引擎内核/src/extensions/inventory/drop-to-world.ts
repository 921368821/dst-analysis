/**
 * L4 · 背包 → 世界（丢弃到地面的**组合层**）
 *
 * ★ 为什么与 `harvest-into.ts` 对称地单独一个文件：这两个函数是**同一枚硬币的两面** ——
 *   那个是"世界少一个、背包多一个"，这个是"背包少一个、世界多一个"。
 *   放在同一层，顺序契约就能互相印证：那边是「先看 → 进包 → 再摘」，
 *   这边是「先找格 → 放下 → 再出包」—— 都是**可能失败的一步放在前面**，
 *   失败时两边状态一点都不动。
 *
 * ★★ 丢 `n` 个 = 地上一堆 `n` 个（批122 改了这条，之前是 `n` 张图散开）。
 *   改写的原因是当时留在这段注释里的那句预告兑现了：`ResourceMarker` 加了 `count`，
 *   采摘变成"取 `min(上限, count)`、见底才销毁" —— 于是"丢 40 个只用 1 格"
 *   不再意味着"捡一次只回来 1 个"，剩下的 39 个就躺在那堆里。
 *
 *   **为什么当初不能只放 1 张图**：那时一个节点 = 一个单位，丢 40 个只放 1 个，
 *   再捡回来只有 1 个，其余 39 个凭空消失（背包扣了、世界没多够）——
 *   而画面上只是地上少了几张图，没有任何异常。所以"一一对应"不是将就，
 *   是**没有 count 时唯一自洽的答案**。批122 把这个前提换掉了，结论才跟着换。
 *
 *   ★ 合并优先于新建：先找半径内最近的**同类**堆叠上去（不占新格、不耗名额、
 *   不新增节点），找不到才新建一堆。不合并的话，丢 1 个就留一个碎堆，
 *   地上很快全是同一格一颗的图 —— 而堆叠存在的理由正是消掉这些碎堆。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { isPassable, isSiteKind, type SiteKind, type WorldPlan } from "../worldgen/worldgen.ts";
import { RESOURCE_TYPE, ResourceMarker, type WorldTaskModuleHandle } from "../worldgen/task-module.ts";
import { countItem, INVENTORY_TYPE, takeItem, type Inventory } from "./inventory.ts";

/** 附近找不到足够多的空地（全被占用 / 不可通行 / 越界）。 */
export const DROP_NO_SPACE = "DROP.NO_SPACE";
/** 包里有这个世界不认识的种类（跨版本存档带过来的）。 */
export const DROP_UNKNOWN_KIND = "DROP.UNKNOWN_KIND";

export interface DropIntoWorldOptions {
  /** 从哪个世界坐标附近找格（通常是玩家位置，单位 = 格）。 */
  readonly x: number;
  readonly z: number;
  /** 世界计划（边界 + 可通行性）。 */
  readonly plan: WorldPlan;
  /** 世界任务模块（占格 + 放置 + 名额）。 */
  readonly tasks: WorldTaskModuleHandle;
  /** 出生 tick（由调用方给：回放时不能变成"当前时钟"）。 */
  readonly bornTick: number;
  /** 搜索半径（格，默认 3）。Chebyshev 距离，环状由近到远；不够会自动外扩。 */
  readonly searchCells?: number;
}

export interface Dropped {
  /**
   * 落在了哪一格。
   * ★ 批122 起**永远只有一格**：丢 `n` 个 = 地上一堆 `n` 个，不再是 `n` 张图散开。
   */
  readonly cell: number;
  /** 那一堆的资源节点 id。 */
  readonly nodeId: number;
  /** 这一堆现在的总数（含之前就在地上的）。 */
  readonly count: number;
  /** 实际出包了多少个（= 请求的 n；失败时这个结构体不会出现）。 */
  readonly dropped: number;
  /**
   * `true` = 叠进了已有的同类堆；`false` = 新建了一堆。
   * ★ 判据必须能分辨这两条路径：它们的账目**完全不同**
   *   （叠堆不动 `spawned`/`alive`/`occupied`，只动 `stacked`），
   *   只验"背包少了 n 个"的话，两条路写反了也照样绿。
   */
  readonly merged: boolean;
}

/**
 * 找离 (x,z) 最近的**同种类**资源堆，用作合并落点（批122）。
 *
 * ★ 为什么它优先于"新建一堆"：不合并的话，丢 1 个就留一个碎堆，
 *   地上很快全是同一格一颗的图 —— 而堆叠这个功能存在的理由正是消掉这些碎堆。
 * ★ 顺序确定：先比 Chebyshev 距离，同距离取**小 cell**。回放依赖这条
 *   （同一世界同一位置丢 100 次，落的必须是同一堆）。
 * ★ 只认 `world.resource`：`world.site`（计划自带的投放点）是地图的一部分，
 *   往里叠玩家丢的东西会把"这张图长什么样"和"玩家干了什么"混成一件事。
 * ★ 半径与 `findFreeCells` 同一口径（`searchCells + 2` 圈）：两个搜索的覆盖范围
 *   不一样时，「叠不到、只能新建」与「找不到空地」会互相矛盾。
 */
export function findStackCell(
  scene: Scene,
  plan: WorldPlan,
  x: number,
  z: number,
  kind: SiteKind,
  searchCells = 3,
): number | null {
  const cx = Math.floor(x);
  const cz = Math.floor(z);
  const reach = Math.max(0, Math.floor(searchCells)) + 2;
  let best = -1;
  let bestD = Number.POSITIVE_INFINITY;
  for (const r of scene.componentsOf<ResourceMarker>(RESOURCE_TYPE)) {
    if (r.node === null || r.kind !== kind) continue;
    const gx = r.cell % plan.width;
    const gz = (r.cell - gx) / plan.width;
    const d = Math.max(Math.abs(gx - cx), Math.abs(gz - cz));
    if (d > reach) continue;
    if (d < bestD || (d === bestD && (best < 0 || r.cell < best))) {
      best = r.cell;
      bestD = d;
    }
  }
  return best < 0 ? null : best;
}

/**
 * 找 `n` 个"界内 + 可通行 + 空闲"的格子，由近到远。
 *
 * ★ 可通行性必须在这里查（而不是交给 `placeResource` 报错）：调用方要的是
 *   "下一格放哪"，而"整片湖都不可通行"时逐个试错会让它在第一格就撞
 *   `BAD_TERRAIN` —— 看起来像"放不下了"，实际是"这一带没有陆地"。
 * ★ 半径不够就外扩（最多 3 圈）：丢 40 个时脚下 3 格（49 格）不一定够，
 *   而"背包里 40 个只丢出 20 个就停"比"多找两圈"更难解释。
 * ★ 顺序确定（环状 + 环内字典序）：同一世界同一位置，丢 100 次落在同一批格，
 *   回放才成立。
 */
export function findFreeCells(
  plan: WorldPlan,
  tasks: WorldTaskModuleHandle,
  x: number,
  z: number,
  n: number,
  searchCells = 3,
): number[] | null {
  if (n <= 0) return [];
  const width = plan.width;
  const height = plan.height;
  const cx = Math.floor(x);
  const cz = Math.floor(z);
  const base = Math.max(0, Math.floor(searchCells));
  const out: number[] = [];
  for (let r = 0; r <= base + 2 && out.length < n; r++) {
    for (let dz = -r; dz <= r && out.length < n; dz++) {
      for (let dx = -r; dx <= r && out.length < n; dx++) {
        // 只扫这一圈的"环"：内圈在更小的 r 上已经扫过
        if (r > 0 && Math.abs(dx) !== r && Math.abs(dz) !== r) continue;
        const gx = cx + dx;
        const gz = cz + dz;
        if (gx < 0 || gx >= width || gz < 0 || gz >= height) continue;
        const cell = gz * width + gx;
        if (!isPassable(plan.kinds[cell]!)) continue;
        if (tasks.isOccupied(cell)) continue;
        out.push(cell);
      }
    }
  }
  return out.length >= n ? out : null;
}

/**
 * 从 `ownerId` 的背包里丢 `n` 个 `kind` 到 (x,z) 附近的世界里。
 *
 * ★ `kind` 收**字符串**而不是 `SiteKind`：背包是"不认识世界"的一层（见 inventory.ts
 *   文件头），跨版本存档里可能带着这一版世界不认识的种类。拒绝它（`DROP.UNKNOWN_KIND`）
 *   比把非法值写进 `ResourceMarker.kind`（类型是 SiteKind）诚实 —— 后者的症状是
 *   一个"能放下、但采不动/刷不出"的资源点。
 *
 * 顺序（见文件头）：**预检 → 找格 → 全放下 → 出包**。
 * 预检让"包里没有这么多"在**任何修改之前**失败；找格让"没有空地"在出包之前失败；
 * 放下中途失败（全局上限）会**回滚已放下的节点**，绝不留下"世界多几个、背包没少"。
 */
export function dropIntoWorld(
  scene: Scene,
  ownerId: number,
  kind: string,
  n: number,
  opts: DropIntoWorldOptions,
): Result<Dropped, EngineError> {
  if (!Number.isInteger(n) || n <= 0) {
    return err(engineError("INVENTORY.BAD_COUNT", `丢弃数量必须是正整数，收到 ${String(n)}`));
  }
  if (!isSiteKind(kind)) {
    return err(engineError(DROP_UNKNOWN_KIND, `这个世界不认识「${kind}」，放不下去`));
  }
  const owner = scene.find(ownerId);
  if (owner === undefined) {
    return err(engineError("INVENTORY.NO_OWNER", `节点 ${String(ownerId)} 不在场景里`));
  }
  if (owner.get<Inventory>(INVENTORY_TYPE) === undefined) {
    return err(engineError("INVENTORY.NO_OWNER", `节点 ${String(ownerId)} 没有背包组件`));
  }
  // ① 预检：不够就整体失败，两边一点都不动
  const has = countItem(scene, ownerId, kind);
  if (has < n) {
    return err(engineError("INVENTORY.NOT_ENOUGH", `只有 ${String(has)} 个 ${kind}，要丢 ${String(n)} 个`));
  }

  // ② 先看能不能**叠到已有的同类堆**上：不占新格、不耗名额、不新增节点
  const stackAt = findStackCell(scene, opts.plan, opts.x, opts.z, kind, opts.searchCells);
  if (stackAt !== null) {
    const stackedUp = opts.tasks.stackResource(stackAt, kind, n);
    // 失败时世界没动（`stackResource` 要么整个成功、要么一个字段没碰）
    if (!stackedUp.ok) return stackedUp;
    // ③ 出包。**这里不可能失败**：① 已预检过同样的 (owner, kind, n)，
    //    而 ② 只改了一个 count、没碰背包 —— 单线程下中间没有任何人能动包。
    //    真失败了也把错误透出去（宿主 toast 会说出来），而不是假装成功。
    const tookMerged = takeItem(scene, ownerId, kind, n);
    if (!tookMerged.ok) return tookMerged;
    return ok({ cell: stackAt, nodeId: stackedUp.value.nodeId, count: stackedUp.value.count, dropped: n, merged: true });
  }

  // ④ 没有可叠的堆 ⇒ 新建一堆。只需要**一格**（n 个在同一格里，这正是堆叠）
  const cells = findFreeCells(opts.plan, opts.tasks, opts.x, opts.z, 1, opts.searchCells);
  if (cells === null) {
    return err(
      engineError(
        DROP_NO_SPACE,
        `附近没有空地放下 ${String(n)} 个${kind}（已外扩到 ${String(Math.max(0, Math.floor(opts.searchCells ?? 3)) + 2)} 格）`,
      ),
    );
  }
  const cell = cells[0]!;
  // ★ `count = n`：这一堆从出生就带着 n 个。少了的话丢 40 个只有 1 个能捡回来，
  //   其余 39 个**凭空消失**（背包扣了、世界没多够）—— 而这在画面上看不出来。
  const placed = opts.tasks.placeResource(cell, kind, opts.bornTick, n);
  // 失败（越界/不可通行/被抢/上限）时世界没动 —— `placeResource` 的每个失败分支
  // 都在 `spawn` 之前 return，或把刚 spawn 的孤儿撤掉，不留半份。
  if (!placed.ok) return placed;
  const took = takeItem(scene, ownerId, kind, n);
  if (!took.ok) return took;
  return ok({ cell, nodeId: placed.value, count: n, dropped: n, merged: false });
}
