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
import { AUTHORITY, NET_IDENTITY_TYPE, NetIdentity, assignOwner, ownedBy, type PlayerId } from "../extensions/net/identity.ts";
import { createRoom, type Joiner, type JoinReply, type JoinRequest, type Room } from "../extensions/net/join.ts";
import { snapshotOfScene } from "../extensions/net/delta.ts";
import { attachSession, type LocalCommand, type NetSession, type SessionHost } from "../extensions/net/session.ts";
import type { Interpolator } from "../extensions/net/interpolate.ts";
import type { PeerId, Transport } from "../extensions/net/transport.ts";
import type { WorldPlan } from "../extensions/worldgen/worldgen.ts";
import { createSeatTable, type SeatTable } from "./seat-table.ts";
import { pickLocalEntity } from "./net-mode.ts";

/**
 * 「有端点断了」这个能力**只有 WebSocket 链路有**。
 *
 * ★ 环回与 `BroadcastChannel` 里没有"对面不在了"这个概念（它们是同一进程/同一机器，
 *   连接的生命周期就是页面/进程的生命周期）。所以不把它塞进 `Transport` 接口 ——
 *   那会逼着两条不上报的链路实现一个永远返回空的钩子，而"永远为空"正是
 *   `docs/PROGRESS.md` 里反复出现的那种假绿（判据能过，因为它本来就没东西可验）。
 */
export interface PeerLeftSource {
  onPeerLeft(cb: (peer: PeerId, reason: string) => void): () => void;
}

function readPeerLeft(t: Transport): PeerLeftSource["onPeerLeft"] | null {
  const fn = (t as Partial<PeerLeftSource>).onPeerLeft;
  return typeof fn === "function" ? fn.bind(t) : null;
}

/**
 * 超时清扫：把被清掉的座位的归属交还权威。
 *
 * ★ 抽成独立函数（而不是写在 `scheduler.onStep` 的闭包里）有两个理由：
 *   ① `assembleHostNet` 内部 `createRoom()`，判据**注入不了**一个"刚好有人超时"的房间；
 *      而这里只要求参数有 `sweep`，传一个 `{ sweep: () => [7] }` 就能验；
 *   ② 归属交还这一步是**唯一**会把 `net.identity.owner` 改回 `AUTHORITY` 的地方，
 *      它坏掉的症状是"下一个坐进这个号的人一动，动的是别人"，而所有计数都正常。
 *
 * ★ 参数用**结构化类型**而不是 `Room`：判据不必为一个方法造 12 个空实现。
 *   这在 TS 里是免费的解耦，不削弱任何契约（调用点仍然传真 `Room`）。
 */
export function sweepExpired(
  room: { sweep(tick: number): readonly PlayerId[] },
  scene: Scene,
  tick: number,
): readonly PlayerId[] {
  const gone = room.sweep(tick);
  for (const playerId of gone) {
    // ★ 只交还归属，**不销毁实体**：他还站在原地（世界不该因为网线拔了就少一个人），
    //   只是不再"归某人"。
    for (const id of ownedBy(scene, playerId)) assignOwner(scene, id, AUTHORITY);
  }
  return gone;
}

/**
 * 一个端点断了：把它的座位标成"掉线"，等重连窗口。
 *
 * ★ 只标掉线、**不清座位**：`Room` 的 `reconnectWindowTicks` 是"网线拔了又插上"
 *   这段窗口，清掉的话回来的人会拿到一个新座位号（背包、位置、归属全丢）。
 *   真正的清理由 `sweepExpired` 在窗口之后做。
 */
export function notePeerLeft(
  room: { drop(peer: PeerId, tick: number): PlayerId | null },
  peer: PeerId,
  tick: number,
  reason: string,
  warn: (msg: string) => void,
): PlayerId | null {
  const gone = room.drop(peer, tick);
  // ★ `null` 是常态（还没握手的端点、或者已经清掉过的）：不告警。
  //   每次都告警会让日志里充满"某个陌生人断了"，真正的掉线反而看不见。
  // ★ 文案**只在这里拼一处**：调用点再拼一遍的话，改的人只会改一处。
  if (gone !== null) {
    warn(`端点 ${String(peer)} 断开（${reason}），座位 ${String(gone)} 先留着等重连`);
  }
  return gone;
}

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
  /**
   * 解绑全部三样：会话订阅、超时清扫、断开监听。幂等。
   *
   * ★ 只解绑会话是不够的：清扫订阅在 `scheduler.onStep` 上，留着它会在世界已经
   *   `loadScene` 换掉之后继续跑 `ownedBy(scene)` —— 而那时的场景里没有那些座位，
   *   于是每拍白跑一遍（没有任何症状，只是"关掉联机之后帧时间慢慢涨"）。
   */
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

  // ---- 掉线与超时清扫（批169）
  //
  // ★★ 这两件事在批164 就写好了接口（`Room.drop` / `Room.sweep`），
  //   **而 `src/` 里一个调用点都没有**。原因是当时没有任何一条链路能给出
  //   「谁断了」—— 环回与 `BroadcastChannel` 里"对面不在了"这件事根本不存在。
  //   网关是第一个知道的一方，所以接线落在这里。
  //
  // ★ 不做的后果不是"少一个功能"，而是一个**永远不释放的座位**：
  //   一个人关掉页面之后 `maxPlayers` 满了，之后谁也进不来，而房间账本上
  //   "在线 N"永远不变 —— 所有计数都对，只有"新玩家进不来"。
  let tickNow = 0;

  /**
   * 清扫订阅。**必须在 `attachSession` 之前注册**：`scheduler.onStep` 按
   * 注册顺序执行，而这一拍要先把超时座位的归属交还权威，会话的 `admit`
   * 才看得到那个结果 —— 反过来的话，掉线的人这一拍还能再走一步。
   */
  const offSweep = o.app.scheduler.onStep((tick) => {
    tickNow = tick;
    sweepExpired(room, scene, tick);
  });

  const onPeerLeft = readPeerLeft(transport);
  const offPeerLeft: () => void =
    onPeerLeft === null
      ? () => {}
      : onPeerLeft((peer, reason) => {
          notePeerLeft(room, peer, tickNow, reason, o.warn);
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

  let offed = false;
  return {
    room,
    seats,
    session: attached.session,
    off: () => {
      // ★ 幂等：调用方可能在页面卸载与显式关闭两处都调。
      if (offed) return;
      offed = true;
      attached?.off();
      offSweep();
      offPeerLeft();
    },
  };
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
  /**
   * 视觉插值器：宿主把它原样交给渲染模块（`createRenderModule({ visual })`）。
   *
   * ★ 这里只是**透传**，不在这一层建：起点的采样要发生在 `loadScene` 的那一侧，
   *   而那个时机只有会话的 `commit` 知道（见 `NetSession.visual` 的注释）。
   */
  readonly visual: Interpolator | null;
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

  return { session: side.session, visual: side.session.visual, off: side.off };
}
