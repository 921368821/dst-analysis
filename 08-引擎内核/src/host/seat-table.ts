/**
 * L6 · 座位表：把「几号玩家」落成「场景里的哪个实体」
 *
 * ★★ 为什么需要这一层（批164 之前的那条捷径）
 *
 *   批163 为了让「客户端预测」第一次跑在真游戏里，做了一个够用但难看的假设：
 *   `planNetWiring` 把**任何端点**都映射到同一个座位，于是两个窗口同控主机世界里的
 *   同一个角色。它能证明预测在真链路上是活的（客户端确实需要"一个自己能推的实体"），
 *   但它同时掩掉了联机里最难的那几件事：谁是谁、每人一个角色、掉线了角色归谁。
 *
 *   这一层把那件事补上：**主机的握手（`net/join.ts` 的 `Room`）分配座位 →
 *   座位表给这个座位造一个实体 → 归属写进场景（`net.identity`）**。
 *   于是 `session.admit` 的比对第一次是真的在比对（`owner === playerOf(from)`），
 *   而不是"反正大家都一样"。
 *
 * ★★ 三条契约
 *
 * ① **座位号 → 实体是一对一，且可重复调用**（`join` 幂等）。
 *    `Room.onJoin` 只在新座位上调一次，但"只调一次"是靠另一层保证的 —— 这一层
 *    再补一道：同一个座位第二次 `join` 返回**同一个**实体，不造第二个。
 *    不补的后果是"重连后我多了一个我"（两个实体同属一人，客户端只认 id 最小的那个，
 *    另一个永远站在他离开的地方，看起来像"我的分身"）。
 *
 * ② **释放 ≠ 删除**（`release` 把归属交还 `AUTHORITY`，实体留在原地）。
 *    掉线超时之后角色该归 AI / 权威继续演，而不是从世界里消失 —— 消失会让
 *    "他走了"和"他被怪打死了"变成同一件事。等到他重连回来，`join` 会把归属
 *    再写回他的座位（同一个实体、同一个位置）。
 *
 * ③ **造不出来必须能被数出来**（`stats().failed` + `lastError`）。
 *    "没有可用格子"、"身份组件没注册"、"玩家组件没注册" 全都表现为
 *    「客户端进了房，但世界里没有他」—— 而所有计数都是对的（座位数 1、在线 1）。
 *    这类失败静默掉的代价是：排障时只能猜。
 *
 * ★ 为什么它不在 `net/` 里：它认识场景与生成计划（`spawnPlayerAt` / `pickJoinCell`），
 *   而 `net/` 那一层刻意只认识"消息"与"归属这个数字"。反过来放，`net` 就得依赖
 *   `worldgen`，而握手是**与游戏内容无关**的东西（换一个游戏还是这一套）。
 */

import type { NodeId } from "../core/scene/node.ts";
import type { Scene } from "../core/scene/scene.ts";
import { AUTHORITY, NET_IDENTITY_TYPE, NetIdentity, assignOwner, type PlayerId } from "../extensions/net/identity.ts";
import { PLAYER_TYPE, spawnPlayerAt, type PlayerSpawn } from "../extensions/worldgen/spawn.ts";
import { pickJoinCell, type WorldPlan } from "../extensions/worldgen/worldgen.ts";

/** 座位号不合法（负数 / 非整数 —— `AUTHORITY` 是"权威"，不是能分配给玩家的座位）。 */
export const SEAT_BAD_ID = "SEAT.BAD_ID";
/** 场景里没有 `net.identity` ⇒ 造出来的玩家谁都驱动不了（不参与联机）。 */
export const SEAT_NO_IDENTITY = "SEAT.NO_IDENTITY";
/** 没有可用格子。 */
export const SEAT_NO_ROOM = "SEAT.NO_ROOM";

export interface SeatTableOptions {
  readonly scene: Scene;
  readonly plan: WorldPlan;
  /** 从哪一格开始找"最近的位置"（主机的出生格）。 */
  readonly origin: number;
  /** 额外可站判定（宿主传导航：树摆在格中心，只看地形会让新玩家生在树里）。 */
  readonly free?: (cell: number) => boolean;
}

export interface SeatTableStats {
  /** 现在有几个座位有实体。 */
  readonly seats: number;
  readonly spawned: number;
  /** 同一个座位重复 `join` 的次数（重连 / 重复请求）。 */
  readonly reused: number;
  readonly released: number;
  readonly failed: number;
  readonly lastError: string | null;
}

export interface SeatTable {
  /**
   * 给这个座位造一个实体（或复用已有的那个）。返回节点 id；`null` = 没造出来
   * （原因进 `stats().lastError`）。
   */
  join(playerId: PlayerId): NodeId | null;
  /** 掉线超时：归属交还权威。返回 `false` = 这个座位没有实体（或已经没有归属可交）。 */
  release(playerId: PlayerId): boolean;
  entityOf(playerId: PlayerId): NodeId | null;
  stats(): SeatTableStats;
}

export function createSeatTable(opts: SeatTableOptions): SeatTable {
  const { scene, plan, origin } = opts;
  const entities = new Map<PlayerId, NodeId>();
  let spawned = 0;
  let reused = 0;
  let released = 0;
  let failed = 0;
  let lastError: string | null = null;

  function fail(code: string): null {
    failed++;
    lastError = code;
    return null;
  }

  function join(playerId: PlayerId): NodeId | null {
    // ★ 负数与小数在这里拦掉：`AUTHORITY`（-1）在 `net.identity` 里是一个**真实取值**
    //   （NPC 归它），拿它当座位会让"由权威驱动"与"由 0 号玩家驱动"混成同一件事。
    if (!Number.isInteger(playerId) || playerId < 0) return fail(SEAT_BAD_ID);
    // ★ 身份组件必须先注册：没有它，`spawnPlayerAt` 会造出一个完整但**不参与联机**的
    //   玩家（`admit` 一律 `no-identity`），而画面上他站着、能被怪打、存档也在。
    if (!scene.components.has(NET_IDENTITY_TYPE)) return fail(SEAT_NO_IDENTITY);

    const had = entities.get(playerId);
    if (had !== undefined) {
      // 实体被别的系统销毁了（怪杀了他 / 世界重载）：那就重新造一个，不能返回死 id。
      if (scene.find(had) === undefined) {
        entities.delete(playerId);
      } else {
        // ★ 重连路径：把归属再写一次。上一次 `release` 可能已经把它交给权威了，
        //   而"座位坐回来了、归属还在权威手里"的症状是——他看得到自己的角色，
        //   但按键不动（所有输入被 `not-owner` 拒掉）。
        assignOwner(scene, had, playerId);
        reused++;
        return had;
      }
    }

    // 已占用的格子：以场景里的 `world.player` 为准（不只是本表记着的那几个）——
    // 开局那位玩家不是这张表造的，而新来的人不能生在他身上。
    const taken: number[] = [];
    for (const marker of scene.componentsOf<PlayerSpawn>(PLAYER_TYPE)) {
      taken.push(marker.cell);
    }
    const cell = pickJoinCell(plan, origin, opts.free === undefined ? { taken } : { taken, free: opts.free });
    if (cell === null) return fail(SEAT_NO_ROOM);

    const made = spawnPlayerAt(scene, plan, { cell, name: `player:${String(playerId)}` });
    if (!made.ok) return fail(made.error.code);

    // 归属：**先**挂组件（缺省是 `AUTHORITY`），再用唯一的写入点改成这个座位。
    // ★ 不直接 `new NetIdentity(); n.owner = playerId` 之后 attach：`identity.ts` 立的
    //   规矩是「写归属只有 `assignOwner` 一个入口」，绕过它的人在重连/交接那两条
    //   路径上会各写一次，而两次写法的差异只在"重连后归属没回来"这种情形里暴露。
    const attached = scene.attach(made.value.nodeId, () => new NetIdentity());
    if (!attached.ok) {
      // 注册表里没有 `net.identity`（上面查过，所以这条只在并发改注册表时发生）。
      // 造出来的这个节点是一个"不参与联机"的玩家：让他站着不如说出来。
      return fail(SEAT_NO_IDENTITY);
    }
    scene.flush();
    if (!assignOwner(scene, made.value.nodeId, playerId)) {
      return fail(SEAT_NO_IDENTITY);
    }
    entities.set(playerId, made.value.nodeId);
    spawned++;
    return made.value.nodeId;
  }

  function release(playerId: PlayerId): boolean {
    const id = entities.get(playerId);
    if (id === undefined) return false;
    if (scene.find(id) === undefined) {
      entities.delete(playerId);
      return false;
    }
    if (!assignOwner(scene, id, AUTHORITY)) return false;
    released++;
    return true;
  }

  return {
    join,
    release,
    entityOf: (playerId: PlayerId): NodeId | null => entities.get(playerId) ?? null,
    stats: (): SeatTableStats => ({
      seats: entities.size,
      spawned,
      reused,
      released,
      failed,
      lastError,
    }),
  };
}

/**
 * 场景里**现在**有几个玩家实体（含开局那位）。
 *
 * ★ 与 `SeatTable.stats().seats` 不是同一个数：那个是"这张表造出来的座位数"，
 *   这个是"世界里站着几个玩家"。主机侧正常情况下两者差 1（开局那位不在表里）
 *   —— 差别的方向能区分"少造了"（`seats + 1 > players`）与"多造了"（`players` 更大）。
 * ★ 按 `world.player` 数而不是按 `net.identity`：单机里玩家**没有**归属组件
 *   （见 `identity.ts` ②），按归属数会得到 0 个玩家 —— 那不是"世界里没人"。
 */
export function countPlayers(scene: Scene): number {
  let n = 0;
  for (const c of scene.componentsOf<PlayerSpawn>(PLAYER_TYPE)) {
    if (c.node !== null) n++;
  }
  return n;
}
