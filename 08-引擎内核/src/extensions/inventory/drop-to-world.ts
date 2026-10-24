/**
 * L4 · 背包 → 世界（丢弃到地面的**组合层**）
 *
 * ★ 为什么与 `harvest-into.ts` 对称地单独一个文件：这两个函数是**同一枚硬币的两面** ——
 *   那个是"世界少一个、背包多一个"，这个是"背包少一个、世界多一个"。
 *   放在同一层，顺序契约就能互相印证：那边是「先看 → 进包 → 再摘」，
 *   这边是「先找格 → 放下 → 再出包」—— 都是**可能失败的一步放在前面**，
 *   失败时两边状态一点都不动。
 *
 * ★★ 一张地图 = 一个单位：丢 `n` 个物品 = 放 `n` 个资源节点。
 *   世界模型里没有"带数量的地面堆叠"（`ResourceMarker` 只有 cell/kind/bornTick），
 *   所以"丢一整堆 40 个"就是脚下散开 40 张图。这不是将就，而是与采摘语义自洽：
 *   采一张图给 `yield` 个，丢 40 张就能捡回 40 个 —— 反过来若只放一张图，
 *   捡一次只回来 1 个，其余 39 个**凭空消失**（背包扣了、世界没多够）。
 *   真要做"地面堆叠"，得给 `ResourceMarker` 加 `count` 并重新定义采摘（摘一半、
 *   不还名额）—— 那是另一批的事，届时这层的契约不用改（仍然是一一对应）。
 */

import type { Scene } from "../../core/scene/scene.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { isPassable, isSiteKind, type WorldPlan } from "../worldgen/worldgen.ts";
import type { WorldTaskModuleHandle } from "../worldgen/task-module.ts";
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
  /** 放在了哪几格（长度 = `dropped`）。 */
  readonly cells: readonly number[];
  /** 对应的新资源节点 id。 */
  readonly nodeIds: readonly number[];
  /** 实际出包了多少个（= 请求的 n；失败时这个结构体不会出现）。 */
  readonly dropped: number;
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

  // ② 找格（找不到 ⇒ 物品还在包里）
  const cells = findFreeCells(opts.plan, opts.tasks, opts.x, opts.z, n, opts.searchCells);
  if (cells === null) {
    return err(
      engineError(
        DROP_NO_SPACE,
        `附近没有足够多的空地放下 ${String(n)} 个${kind}（已外扩到 ${String(Math.max(0, Math.floor(opts.searchCells ?? 3)) + 2)} 格）`,
      ),
    );
  }

  // ③ 全放下。中途失败（上限/占用被抢）就回滚：销毁已放节点 + 归还名额
  const nodeIds: number[] = [];
  for (const cell of cells) {
    const placed = opts.tasks.placeResource(cell, kind, opts.bornTick);
    if (!placed.ok) {
      for (let i = 0; i < nodeIds.length; i++) {
        scene.destroy(nodeIds[i]!);
        opts.tasks.releaseCell(cells[i]!);
      }
      scene.flush();
      return placed;
    }
    nodeIds.push(placed.value);
  }

  // ④ 出包。**这里不可能失败**：① 已预检过同样的 (owner, kind, n)，
  //    而 ②③ 只往世界里加节点、不碰背包 —— 单线程下中间没有任何人能动包。
  //    真失败了也把错误透出去（宿主 toast 会说出来），而不是假装成功。
  const took = takeItem(scene, ownerId, kind, n);
  if (!took.ok) return took;
  return ok({ cells, nodeIds, dropped: n });
}
