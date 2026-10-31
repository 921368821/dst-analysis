/**
 * L6 · 联机装配：把「模式的决策」变成「真的接上的会话」
 *
 * ★★ 为什么这一层必须存在（批165）
 *
 *   `demo-game.ts` 是 3600 行的组合根。批163/164 把联机接进去的时候，接线写在
 *   那个文件里的一段 `if (role === "host") { … } else { … }` 里 —— 它能跑，
 *   但它**没有任何判据能打到**：Node 判据不 import 组合根（那要 CANVAS、要 DOM、
 *   要一整套资产），浏览器探针又只能读到页面上的最终结果。
 *
 *   于是出现了一条静默的缝：`if (reply.reconnected) seats?.join(reply.playerId)`
 *   这一行（重连要把归属补回来）**只写在注释里**，判据一条都没有。
 *   它坏掉时的症状是：重连的人看得到自己的角色、世界在动，但按键不动
 *   （每条输入 `not-owner`），而所有计数都是对的（座位 1、在线 1、reconnects 1）。
 *
 *   这一层把那一段接线搬出来，只依赖「场景 + 会话 + 房间 + 座位表」这四样
 *   —— 每一件在 Node 里都能造真的（`tests/host/net-assembly.test.ts`）。
 *   组合根缩成「收集 env → 调这里 → 存句柄」，不再承载任何**判断**。
 *
 * ★★ 三条契约（各有一条判据钉着）
 *
 * ① **座位号只有一个来源：握手。** 主机自己那一份由 `Room` 构造时给出（0 号），
 *    客户端那一份来自 `join-reply`。这一层不接受任何「我自称我是谁」的入参。
 *
 * ② **重连要补一次归属。** `Room` 的重连路径刻意不调 `onJoin`（重连不该造第二个
 *    实体），可它也不知道「上一次超时清扫已经把归属交还权威了」。这一层补上，
 *    且靠 `SeatTable.join` 的幂等性保证「补」不会变成「造第二个我」。
 *
 * ③ **装完世界要重指主角。** `loadScene` 把客户端的节点全换掉，宿主手里那些
 *    节点 id 全部指向不存在的节点 —— 相机、HUD、背包静默失效。
 *    这不是「顺手做一下」，是装载回调存在的唯一理由。
 *
 * ★ 为什么 `local` 的读取两端共用一份（`localCommand`）
 *   两端的差别只有「我的座位号从哪来」；`pickLocalEntity` + `directionFromMap`
 *   那两步一模一样。写两份的话，将来只改一处的症状是「主机转得动、客户端转不动」
 *   —— 而两边的判据各自都绿。
 */

import type { NodeId } from "../core/scene/node.ts";
import type { Scene } from "../core/scene/scene.ts";
import { sceneToJson } from "../core/scene/scene-io.ts";
import type { InputMap } from "../extensions/input/input-map.ts";
import { directionFromMap } from "../extensions/input/player-controller.ts";
import type { InputSnapshot } from "../platform/input/device.ts";
import { NET_IDENTITY_TYPE, NetIdentity, type PlayerId } from "../extensions/net/identity.ts";
import { createRoom, type Joiner, type JoinReply, type JoinRequest, type Room } from "../extensions/net/join.ts";
import { snapshotOfScene } from "../extensions/net/delta.ts";
import { attachSession, type LocalCommand, type NetSession, type SessionHost } from "../extensions/net/session.ts";
import type { PeerId, Transport } from "../extensions/net/transport.ts";
import type { WorldPlan } from "../extensions/worldgen/worldgen.ts";
import { createSeatTable, type SeatTable } from "./seat-table.ts";
import { pickLocalEntity } from "./net-mode.ts";

/** 这一拍的输入（已经 poll 过的那一份 —— 再 poll 会吞掉"刚按下"）。 */
export interface NetInputProbe {
  readonly map: InputMap;
  readonly snapshot: InputSnapshot;
}

/**
 * 「我这一拍想干什么」——两端共用。
 *
 * ★ 返回 `null` 的三种情形都是**同一件事**（这一拍没有本地意图）：
 *   输入探针还没建、世界里还没有我的实体（还没握上手）、方向是零。
 *   分开写三个分支没有意义，反而会让「没实体」与「没按键」各自被漏测一次。
 */
export function localCommand(
  scene: Scene,
  player: PlayerId | null,
  input: NetInputProbe | null,
): LocalCommand | null {
  if (input === null) return null;
  const entity = pickLocalEntity(scene, player);
  if (entity === null) return null;
  const d = directionFromMap(input.map, input.snapshot);
  if (d.dx === 0 && d.dz === 0) return null;
  return { entity, intent: { kind: "move.dir", dx: d.dx, dz: d.dz } };
}

// ---------------------------------------------------------------- 主机侧

/** 主机侧握手要用的四样东西（判据直接打 `handleJoinRequest`，不必建整个装配）。 */
export interface HostJoinDeps {
  readonly room: Room;
  readonly seats: SeatTable | null;
  /** 把回复交出去（`transport.send`；走同一条通道、同一个发送计数）。 */
  readonly send: (reply: JoinReply) => void;
  /** 让下一份广播改全量（会话装好了才可能调 —— 握手期间它可能还是 `null`）。 */
  readonly requestKeyframe: () => void;
  /** 造不出实体时要留证据（否则所有计数都是对的，只有"他没角色"）。 */
  readonly warn: (msg: string) => void;
}

/**
 * 主机收到一个加入请求：分配座位 → 回包 →（重连时）补归属 → 要一份全量。
 *
 * ★★ 顺序不能换：`room.accept` 必须在 `seats.join` **之前** ——
 *   回复里要带「你是几号」。反过来的话座位表拿不到号，只能猜。
 *
 * ★★ `requestKeyframe` 只在新座位与重连时都要调：客户端刚装上的那份世界
 *   不在会话的序号链上（见 `session.adopt`），而「链从哪开始」要由主机说了算 ——
 *   不等它 `resync` 一次（那要多一个往返，还可能丢）。
 */
export function handleJoinRequest(
  deps: HostJoinDeps,
  req: JoinRequest,
  from: PeerId,
  tick: number,
): JoinReply {
  const reply = deps.room.accept(req, from, tick);
  deps.send(reply);

  if (reply.accepted) {
    // ★★ 重连要**补一次** `seats.join`。`Room` 的重连路径刻意不调 `onJoin`
    //   （那是对的 —— 重连不该造第二个实体），可它也不知道「上一次超时清扫
    //   已经把归属交还权威了」。不补的症状非常安静：他看得到自己的角色、
    //   世界在动，但按键不动（每条输入都被 `not-owner` 拒掉）。
    //   `join` 是幂等的：复用同一个实体 + 把归属写回去。
    if (reply.reconnected) {
      const seat = deps.seats?.join(reply.playerId) ?? null;
      // ★ 座位表本身是 `null`（世界还没生成）也算「找不回」：那种情况下他重连上来
      //   会看到一个没有自己的世界 —— 与「座位表在、实体造失败」是同一种结局，
      //   所以走同一条告警路径（`lastError` 分辨不出时给 `NO_PLAN`）。
      if (seat === null) {
        deps.warn(
          `重连的座位 ${String(reply.playerId)} 没能找回实体：${deps.seats?.stats().lastError ?? "NO_PLAN"}`,
        );
      }
    }
    deps.requestKeyframe();
  }
  return reply;
}

export interface HostNetOptions {
  readonly app: SessionHost;
  readonly scene: Scene;
  readonly transport: Transport;
  /** 主机自己的角色就是 0 号座位（`Room` 构造时已经把它给了自己）。 */
  readonly heroId: NodeId;
  /** 没有生成计划就没有座位表 —— `snapshot` 也会返回 `null`（`Room` 因此以 `behind` 拒客）。 */
  readonly plan: WorldPlan | null;
  /** 导航网格：树摆在格中心，只看地形会把新玩家生进树里（两台机器推的方向不一定一样）。 */
  readonly nav: { readonly isWalkableIndex: (cell: number) => boolean } | null;
  /** 主机开局那位站着的格 —— 新玩家从它出发找最近的空位。 */
  readonly origin: number;
  readonly room: string;
  readonly maxPlayers?: number;
  readonly snapshotEveryTicks?: number;
  /** 世界准备好了没有。没准备好时 `snapshot` 返回 `null`。 */
  readonly assembled: () => boolean;
  readonly input: () => NetInputProbe | null;
  readonly warn: (msg: string) => void;
}

export interface HostNetSide {
  readonly room: Room;
  readonly seats: SeatTable | null;
  readonly session: NetSession;
  readonly off: () => void;
}

/** 主机侧：座位表 + 房间 + 会话，三样接成一条。 */
export function assembleHostNet(o: HostNetOptions): HostNetSide {
  const { scene, transport } = o;

  // ★ 主机自己的归属先写上（0 号座位）。先判有没有再 attach：重复 attach 同类型
  //   组件会让「谁才是那份归属」多一个答案。
  const hero = scene.find(o.heroId);
  if (hero !== undefined && hero.get(NET_IDENTITY_TYPE) === undefined) {
    scene.attach(o.heroId, () => {
      const ident = new NetIdentity();
      ident.owner = 0;
      return ident;
    });
    scene.flush();
  }

  const seats: SeatTable | null =
    o.plan === null
      ? null
      : createSeatTable({
          scene,
          plan: o.plan,
          origin: o.origin,
          ...(o.nav === null ? {} : { free: (c: number) => o.nav?.isWalkableIndex(c) === true }),
        });

  const room: Room = createRoom({
    id: o.room,
    name: `demo:${o.room}`,
    maxPlayers: o.maxPlayers ?? 4,
    // ★ 现拍而不是「开局拍一份存着」：`Room` 保证**先分配座位、再调这个回调**，
    //   于是一个刚坐下的人在回复里就已经在世界上。先存的那份里没有他 ——
    //   客户端进房第一眼「世界里没有我」，而下一份广播要等 5 拍。
    snapshot: () => (o.assembled() ? sceneToJson(snapshotOfScene(scene)) : null),
    onJoin: (playerId: number) => {
      // ★ 造不出来必须留证据：`seats.join` 返回 null 时所有计数都是对的
      //   （座位 1、在线 1、accepted 1），唯一的症状是「客户端进了房却没有角色」。
      const made = seats === null ? null : seats.join(playerId);
      if (made === null) {
        o.warn(`座位 ${String(playerId)} 没有落到实体上：${seats?.stats().lastError ?? "NO_PLAN"}`);
      }
    },
  });

  // ★ 循环引用：`onJoinRequest` 里要调 `session.requestKeyframe()`，而会话是
  //   `attachSession` 的**返回值**。回调在运行时才执行，那时 `attached` 已经赋好；
  //   用 `?.` 兜住「回调早于赋值」（单机不会，但判据里可能构造出来）。
  let attached: { readonly session: NetSession; readonly off: () => void } | null = null;
  attached = attachSession(o.app, {
    role: "host",
    transport,
    ...(o.snapshotEveryTicks === undefined ? {} : { snapshotEveryTicks: o.snapshotEveryTicks }),
    // ★ 端点 → 座位来自房间，**不是**「任何端点都是同一个座位」（批163 的捷径）。
    playerOf: room.playerOf,
    onJoinRequest: (req, from, tick) => {
      handleJoinRequest(
        {
          room,
          seats,
          send: (reply) => {
            // 回复也是 `NetMessage`：走同一条通道、同一个发送计数。
            transport.send(reply);
          },
          requestKeyframe: () => attached?.session.requestKeyframe(),
          warn: o.warn,
        },
        req,
        from,
        tick,
      );
    },
    // ★ 主机自己的输入走**同一道**授权检查（`admit` 用的是 `room.playerOf`）。
    local: () => localCommand(scene, room.playerOf(transport.self), o.input()),
  });

  return { room, seats, session: attached.session, off: attached.off };
}

// ---------------------------------------------------------------- 客户端侧

export interface ClientNetOptions {
  readonly app: SessionHost;
  readonly scene: Scene;
  readonly transport: Transport;
  readonly joiner: Joiner;
  readonly input: () => NetInputProbe | null;
  /** 主角换了（`loadScene` 之后重指）。宿主用它更新相机/背包等一切持有 id 的地方。 */
  readonly onHero: (id: NodeId) => void;
  /** 给玩家看的提示（被拒的原因、世界装不上）。 */
  readonly notify: (msg: string) => void;
}

export interface ClientNetSide {
  readonly session: NetSession;
  readonly off: () => void;
}

/** 客户端侧：会话 + 握手回复的应用 + 世界装载后的重指。 */
export function assembleClientNet(o: ClientNetOptions): ClientNetSide {
  const { scene, joiner } = o;
  /** 只在**理由变化**时提示：客户端每 15 拍重发一次，每条都弹会闪成一团。 */
  let lastRefusal: string | null = null;

  let side: { readonly session: NetSession; readonly off: () => void } | null = null;
  side = attachSession(o.app, {
    role: "client",
    transport: o.transport,
    // 客户端没有座位表：它的座位是主机回复里的那个数字。`null` = 还没握上手 ——
    // 此时 `localCommand` 也拿不到实体，于是**发不出意图**（不需要额外的开关）。
    playerOf: () => joiner.playerId(),
    local: () => localCommand(scene, joiner.playerId(), o.input()),
    onJoinReply: (reply) => {
      // ★ `reply()` 返回 `false` = 不是给我的 / 迟到的 / 半份的。一律不应用
      //   （同一份回复应用两遍 = 凭空回滚一次世界）。
      if (!joiner.reply(reply)) return;
      if (!reply.accepted) {
        if (lastRefusal !== reply.reason) {
          lastRefusal = reply.reason;
          // ★ 拒绝要能说清「我该怎么办」：版本不对与满员是两件事。
          const detail = reply.detail;
          o.notify(
            detail === undefined
              ? `进房被拒：${reply.reason}`
              : `进房被拒：${reply.reason}（主机 ${String(detail["host"])} / 我 ${String(detail["client"])}）`,
          );
        }
        return;
      }
      lastRefusal = null;
      const json = joiner.takeSnapshot();
      // ★ 装的是「主机在这个座位刚坐定时拍的世界」：里面有我。装载成功会触发
      //   `onWorldLoaded`，我们在那里把主角重指到我的实体上。
      if (json !== null) {
        const ok = side?.session.adopt(json) ?? false;
        if (!ok) o.notify("进房的世界装不上（存档格式比引擎新？）");
      }
    },
    onWorldLoaded: () => {
      // ★ 重指主角：`loadScene` 把客户端的节点全换掉了，原来的 id 现在指向一个
      //   不存在的节点 —— 相机、HUD、背包全都静默失效（世界在动，但你在看别人）。
      const id = pickLocalEntity(scene, joiner.playerId());
      if (id !== null) o.onHero(id);
    },
  });

  return { session: side.session, off: side.off };
}
