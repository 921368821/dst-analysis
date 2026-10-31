/**
 * L4 · 加入握手（Join）：从「一条能发消息的线」到「一个知道自己是谁的会话」
 *
 * ★★ 这一层只回答一句话：**这个连接是几号玩家，他能看到哪一个世界**。
 *
 *   会话层（`session.ts`）从第一天起就假设「我已经知道自己拥有谁」—— `admit()` 与
 *   `owned` 全按一个数字比对归属。那个数字从哪来？批152 留的是一个诚实但难看的答案：
 *   **从第一份广播快照里猜**（客户端第 0 拍不发意图，见 `net-session.test.ts` 文件头）。
 *   握手把这件事从「猜」变成「主机盖章」，并且把「先给你归属、再给你世界」这个顺序
 *   固定下来 —— 顺序反了，客户端会拿到一份「世界里没有我」的快照，然后要靠下一份
 *   广播才动得了，症状恰好是「连上了，但前几拍走不动」。
 *
 * ★★ 座位号（`PlayerId`）为什么必须与端点号（`PeerId`）分开
 *
 *   端点号是「这根线是几号口」，座位号是「你是几号玩家」。两者今天在环回里恰好都从
 *   0/1 开始，所以看起来可以合并成一个数字 —— 而这正是它危险的地方：一旦合并，
 *   「重连后你还是你」就退化成「重连后你拿到了同一个端口」（真实传输里根本不成立：
 *   Steam 每次连接都是一个新 handle），而所有关于归属的判据照样全绿。分开之后，
 *   「重连」才有一个可验证的含义：**同一个 PlayerId，落在另一个端点上**。
 *
 * ★★ 五条契约，每条都对应一个静默 bug
 *
 * ① **拒绝是完整的拒绝**：`JoinReply` 是判别联合（`accepted` 收窄），被拒时类型上就
 *    没有 `playerId` / `json`。写成「`accepted: false` 但字段还在」的形状，实现里一定
 *    会有一条路径把半份回复当成功处理 —— 症状是客户端进了房、世界里没有任何东西能动。
 * ② **票据只用来恢复身份，不用来授权**：授权永远看 `PlayerId`（`session.admit`）。
 *    票据一旦被当成令牌，一次泄露就是永久的（没有任何地方会去收回它）。
 * ③ **掉线不清归属，超时才清，而且清的理由要交出来**：掉线的角色还站在原地等（世界
 *    不该因为网线拔了就把角色交给 AI）。但超时之后必须把归属交还 `AUTHORITY` ——
 *    这件事 Room 做不到（它不认识场景），所以 `sweep()` **返回名单**，而不是自己悄悄
 *    收走。忘了交接 ⇒ 角色被一个不存在的玩家占着，谁都推不动，而所有计数都是对的。
 * ④ **先检查后分配**：版本不符 / 满员在**分配之前**拒绝，所以号不会被拒掉的尝试消耗；
 *    而「世界还没准备好」只能分配之后才知道（要先给角色再拍照），于是那种拒绝会消耗
 *    一个号 —— 号**单调不复用**，因为复用会让一张老票据意外匹配到新玩家。
 * ⑤ **一个坏加入不阻断别人**：版本不符 / 满员 / 未就绪各有各的码，各自计数。压成一个
 *    `false` 之后，面板只能说「加入失败」，而玩家要的是「你该更新」还是「房满了，等会儿」。
 *
 * ★ 房间发现（`discoverRooms`）刻意**不过滤**版本不符的房间：过滤掉的后果是列表空白，
 *   玩家看到的是「没有房间」，而事实是「有三个房间，但都要更新」。列表里每一个都带
 *   `joinable` 与 `reason`，让界面自己决定怎么解释。
 */

import { XorShift128, type IRandom } from "../../foundation/random.ts";
import type { NetEnvelope, PeerId } from "./transport.ts";
import type { PlayerId } from "./identity.ts";

/**
 * 协议版本。**任何一条消息的形状变了就要 +1**：这个数字的全部意义是让「老客户端」
 * 与「新主机」在握手那一刻就分开，而不是让它们连上之后在某个字段上读出 `undefined`。
 */
export const PROTOCOL_VERSION = 1;

/** 被拒原因。**每一个都要能被计数**：不计数就等于静默丢弃。 */
export const JoinReject = {
  /** **你**比对方旧。 */
  VersionOld: "version-old",
  /** **你**比对方新（主机该更新了）。 */
  VersionNew: "version-new",
  /** 房间满了（掉线未超时的人仍占位）。 */
  Full: "full",
  /** 房间已关闭。 */
  Closed: "closed",
  /** 主机自己不能入房 —— 这是编程错误，不是玩家可行动项。 */
  Host: "host",
  /** 主机还没有世界（第 0 拍之前 / 场景未装载）。可重试。 */
  Behind: "behind",
} as const;

export type JoinRejectReason = (typeof JoinReject)[keyof typeof JoinReject];

/** 客户端 → 主机：我想进这个房间。 */
export interface JoinRequest extends NetEnvelope {
  readonly kind: "join";
  /** 我这边的协议版本。 */
  readonly protocolVersion: number;
  /** 昵称（只进日志与座位表，不参与任何判定）。 */
  readonly name: string;
  /** 上次主机发的票据。带上它 = 我想回到原来那个座位。 */
  readonly ticket?: string;
}

/** 主机 → 客户端：收下了，这是你的座位、你的票据，和**这一刻**的世界。 */
export interface JoinAccepted extends NetEnvelope {
  readonly kind: "join-reply";
  /** 这条回给哪个端点。客户端拿它过滤「不是给我的回复」。 */
  readonly to: PeerId;
  readonly accepted: true;
  readonly playerId: PlayerId;
  readonly ticket: string;
  /** `true` = 复用了一个掉线座位（同一个 `playerId`），不是新玩家。 */
  readonly reconnected: boolean;
  /** 全量快照（`sceneToJson(saveScene(scene, { mode: "rollback" }))`）。 */
  readonly json: string;
}

/** 主机 → 客户端：不能进，以及为什么。 */
export interface JoinRefused extends NetEnvelope {
  readonly kind: "join-reply";
  readonly to: PeerId;
  readonly accepted: false;
  readonly reason: JoinRejectReason;
  /** 版本不符时带 `{ host, client }`：界面要能说清「谁该更新」。 */
  readonly detail?: Readonly<Record<string, number>>;
}

export type JoinReply = JoinAccepted | JoinRefused;

export interface RoomInfo {
  readonly id: string;
  readonly name: string;
  readonly protocolVersion: number;
  /** 占位人数（含掉线未超时的人）。 */
  readonly players: number;
  readonly maxPlayers: number;
}

export interface RoomCandidate extends RoomInfo {
  readonly joinable: boolean;
  /** `joinable === false` 时为什么。 */
  readonly reason: JoinRejectReason | null;
}

export const DEFAULT_MAX_PLAYERS = 4;
/** 掉线后座位保留多久（逻辑步）。30Hz 下 300 拍 = 10 秒。 */
export const DEFAULT_RECONNECT_WINDOW = 300;

export interface RoomOptions {
  readonly id: string;
  readonly name: string;
  readonly protocolVersion?: number;
  /** 含主机自己。缺省 4。 */
  readonly maxPlayers?: number;
  /** 掉线后座位保留多少拍。缺省 300。 */
  readonly reconnectWindowTicks?: number;
  /** 主机的端点号（回复从这里发出，也用来拒绝「主机自己入房」）。缺省 0。 */
  readonly hostPeer?: PeerId;
  /** 票据随机流的种子（同种子 ⇒ 同一串票据，判据可复现）。缺省 1。 */
  readonly seed?: number;
  /**
   * 全量快照来源。返回 `null` = 世界还没准备好 ⇒ 这次加入被拒（`behind`）。
   *
   * ★ 做成回调而不是「调用方先拍好一份传进来」：快照必须在**分配角色之后**拍，
   *   而这个顺序只有 Room 自己知道（见 `accept` 里的注释）。
   */
  readonly snapshot?: (tick: number) => string | null;
  /**
   * 新座位落定时把角色交出去（`assignOwner` / 生成角色 / 上 NPC 脚本）。
   *
   * ★ 只在**新座位**上调用一次：重连与重复加入不调 —— 再调一次会造出第二个角色，
   *   而客户端那边看到的是「我进房后有两个我能动」。
   * ★ 调用时机在拍照**之前**：否则第一份快照里没有任何实体归他。
   */
  readonly onJoin?: (playerId: PlayerId, tick: number) => void;
}

export interface RoomStats {
  /** 占位人数（含主机、含掉线未超时）。 */
  readonly players: number;
  readonly online: number;
  readonly lost: number;
  readonly maxPlayers: number;
  readonly accepted: number;
  readonly refused: Readonly<Record<JoinRejectReason, number>>;
  readonly reconnects: number;
  /** 票据对不上（降级成新玩家）的次数。 */
  readonly ticketStale: number;
  /** 同一端点重复入房的次数（幂等，不占新座位）。 */
  readonly duplicates: number;
  /** 因超时被清掉的座位数。 */
  readonly expired: number;
  readonly closed: boolean;
}

export interface Room {
  readonly id: string;
  info(): RoomInfo;
  /**
   * 处理一条加入请求（首次 / 重连 / 重复）。
   *
   * ★ `peer` 必须是**传输盖章的那个端点号**，不是请求里自报的 `from`：
   *   自报的 `from` 只说明「这条消息里写了什么」，与「这条消息从哪来」是两件事
   *   （与 `transport.ts` 端点盖章同一条纪律）。
   */
  accept(req: JoinRequest, peer: PeerId, tick: number): JoinReply;
  /** 连接断了：座位保留，等 `reconnectWindowTicks` 拍。返回被标掉的玩家号。 */
  drop(peer: PeerId, tick: number): PlayerId | null;
  /**
   * 超时清扫。**返回被清掉的玩家号** —— 调用方要把这些实体的归属交还 `AUTHORITY`
   * （Room 不认识场景，所以它只报告，不代劳）。
   */
  sweep(tick: number): readonly PlayerId[];
  /** 这个端点现在是几号玩家。掉线 / 未入房 ⇒ `null`。可直接传给 `session.playerOf`。 */
  playerOf(peer: PeerId): PlayerId | null;
  /** 在线端点的座位号，按座位号升序。 */
  seats(): readonly PlayerId[];
  stats(): RoomStats;
  close(): void;
}

interface Seat {
  readonly playerId: PlayerId;
  peer: PeerId;
  readonly name: string;
  ticket: string;
  readonly joinedTick: number;
  /** `null` = 在线；否则是掉线的那一拍。 */
  lostAt: number | null;
}

/** 被拒时绝不带成功字段：运行时也这么保证（`"playerId" in reply === false`）。 */
function refusedReply(
  from: PeerId,
  to: PeerId,
  tick: number,
  seq: number,
  reason: JoinRejectReason,
  detail?: Readonly<Record<string, number>>,
): JoinRefused {
  const base = { kind: "join-reply" as const, from, to, tick, seq, accepted: false as const, reason };
  return detail === undefined ? base : { ...base, detail };
}

class RoomImpl implements Room {
  readonly id: string;
  private readonly name: string;
  private readonly version: number;
  private readonly max: number;
  private readonly window: number;
  private readonly hostPeer: PeerId;
  private readonly snapshot: (tick: number) => string | null;
  private readonly onJoin: ((playerId: PlayerId, tick: number) => void) | null;
  private readonly rng: IRandom;

  private seatsIn: Seat[] = [];
  private nextPlayerId = 1;
  private outSeq = 0;
  private ticketSeq = 0;
  private isClosed = false;

  private accepted = 0;
  private reconnects = 0;
  private ticketStale = 0;
  private duplicates = 0;
  private expired = 0;
  private readonly refused: Record<JoinRejectReason, number>;

  constructor(opts: RoomOptions) {
    const max = opts.maxPlayers ?? DEFAULT_MAX_PLAYERS;
    if (!Number.isInteger(max) || max < 2) {
      throw new RangeError(`maxPlayers 必须是 ≥2 的整数（主机自己占一个），收到 ${String(max)}`);
    }
    const win = opts.reconnectWindowTicks ?? DEFAULT_RECONNECT_WINDOW;
    if (!Number.isInteger(win) || win < 0) {
      throw new RangeError(`reconnectWindowTicks 必须是非负整数，收到 ${String(win)}`);
    }
    this.id = opts.id;
    this.name = opts.name;
    this.version = opts.protocolVersion ?? PROTOCOL_VERSION;
    this.max = max;
    this.window = win;
    this.hostPeer = opts.hostPeer ?? 0;
    this.snapshot = opts.snapshot ?? (() => null);
    this.onJoin = opts.onJoin ?? null;
    this.rng = new XorShift128(opts.seed ?? 1);
    this.refused = {
      [JoinReject.VersionOld]: 0,
      [JoinReject.VersionNew]: 0,
      [JoinReject.Full]: 0,
      [JoinReject.Closed]: 0,
      [JoinReject.Host]: 0,
      [JoinReject.Behind]: 0,
    };
    // 主机自己从第 0 拍就在座（它不经过握手）。
    this.seatsIn.push({
      playerId: 0,
      peer: this.hostPeer,
      name: opts.name,
      ticket: "",
      joinedTick: 0,
      lostAt: null,
    });
  }

  info(): RoomInfo {
    return {
      id: this.id,
      name: this.name,
      protocolVersion: this.version,
      players: this.seatsIn.length,
      maxPlayers: this.max,
    };
  }

  accept(req: JoinRequest, peer: PeerId, tick: number): JoinReply {
    if (this.isClosed) return this.refuse(peer, tick, JoinReject.Closed);
    // 主机自己入房是编程错误：它没有「加入」这个动作。放过去会让 0 号座位被覆盖。
    if (peer === this.hostPeer) return this.refuse(peer, tick, JoinReject.Host);

    // ★ 畸形版本号按「比谁都旧」处理：网络上的数据可以是任何东西，
    //   而 `NaN < 1` 为 false ⇒ 不做这一步的话 NaN 会被当成「更新」放过去。
    const want = Number.isInteger(req.protocolVersion) ? req.protocolVersion : -1;
    if (want !== this.version) {
      const reason = want < this.version ? JoinReject.VersionOld : JoinReject.VersionNew;
      return this.refuse(peer, tick, reason, { host: this.version, client: want });
    }

    // ---- 同一端点重复入房：幂等（给回同一个座位）。把人踢成新号是最坏的实现。
    const dup = this.online(peer);
    if (dup !== undefined) {
      this.duplicates++;
      const json = this.snapshot(tick);
      if (json === null) return this.refuse(peer, tick, JoinReject.Behind);
      this.accepted++;
      return this.acceptedReply(peer, tick, dup, json, true);
    }

    // ---- 票据：只认「掉线且等待中」的座位。在线座位的票据被重放时不许抢人。
    const ticket = req.ticket;
    if (ticket !== undefined && ticket.length > 0) {
      const seat = this.seatsIn.find((s) => s.ticket === ticket && s.lostAt !== null);
      if (seat !== undefined) {
        const json = this.snapshot(tick);
        if (json === null) return this.refuse(peer, tick, JoinReject.Behind);
        seat.peer = peer;
        seat.lostAt = null;
        this.reconnects++;
        this.accepted++;
        return this.acceptedReply(peer, tick, seat, json, true);
      }
      // 票据不认 ⇒ 降级成新玩家（不是拒绝）：主机重启 / 超时之后玩家仍要能进来。
      // ★ 但这件事必须可见 —— 降级意味着「你的角色没了」，界面上与「你是新来的」不同。
      this.ticketStale++;
    }

    // ---- 容量：掉线未超时的人仍占位（否则他重连回来位子已经被别人坐了）。
    if (this.seatsIn.length >= this.max) return this.refuse(peer, tick, JoinReject.Full);

    // ★ 先给角色再拍照（见文件头）。于是「世界还没准备好」只能在这之后发现，
    //   也就只能消耗一个号 —— 号单调不复用，宁可留空号。
    const seat: Seat = {
      playerId: this.nextPlayerId++,
      peer,
      name: req.name,
      ticket: this.newTicket(),
      joinedTick: tick,
      lostAt: null,
    };
    this.seatsIn.push(seat);
    this.onJoin?.(seat.playerId, tick);
    const json = this.snapshot(tick);
    if (json === null) {
      this.seatsIn = this.seatsIn.filter((s) => s !== seat);
      return this.refuse(peer, tick, JoinReject.Behind);
    }
    this.accepted++;
    return this.acceptedReply(peer, tick, seat, json, false);
  }

  drop(peer: PeerId, tick: number): PlayerId | null {
    const seat = this.online(peer);
    if (seat === undefined) return null;
    if (seat.playerId === 0) return null; // 主机不会掉线（它就是权威）
    seat.lostAt = tick;
    return seat.playerId;
  }

  sweep(tick: number): readonly PlayerId[] {
    const gone: PlayerId[] = [];
    const kept: Seat[] = [];
    for (const s of this.seatsIn) {
      if (s.lostAt === null || tick - s.lostAt < this.window) {
        kept.push(s);
        continue;
      }
      gone.push(s.playerId);
      this.expired++;
    }
    this.seatsIn = kept;
    gone.sort((a, b) => a - b);
    return gone;
  }

  /**
   * ★ 这个方法会被直接交给 `session.playerOf`（`playerOf: room.playerOf`），
   *   所以必须是**绑定过的箭头属性**：写成原型方法时，脱离 `this` 调用会在运行期
   *   抛出「读不到 seatsIn」，而类型检查看不出来。
   */
  readonly playerOf = (peer: PeerId): PlayerId | null => {
    const seat = this.online(peer);
    return seat === undefined ? null : seat.playerId;
  };

  seats(): readonly PlayerId[] {
    return this.seatsIn.filter((s) => s.lostAt === null).map((s) => s.playerId).sort((a, b) => a - b);
  }

  stats(): RoomStats {
    let online = 0;
    for (const s of this.seatsIn) if (s.lostAt === null) online++;
    return {
      players: this.seatsIn.length,
      online,
      lost: this.seatsIn.length - online,
      maxPlayers: this.max,
      accepted: this.accepted,
      refused: { ...this.refused },
      reconnects: this.reconnects,
      ticketStale: this.ticketStale,
      duplicates: this.duplicates,
      expired: this.expired,
      closed: this.isClosed,
    };
  }

  close(): void {
    this.isClosed = true;
  }

  // ---------------------------------------------------------------- 内部

  /** 在线座位（掉线的不算：掉线的连接不能再驱动角色）。 */
  private online(peer: PeerId): Seat | undefined {
    return this.seatsIn.find((s) => s.peer === peer && s.lostAt === null);
  }

  private newTicket(): string {
    // ★ 只保证「房间内唯一」，**不保证不可猜**：票据不是授权令牌（见文件头 ②），
    //   被猜到最多让你顶掉一个掉线玩家的座位。真联网时这一层要换成 CSPRNG + 服务端
    //   签发，而那时它仍然是「恢复身份」的凭据，不是「持续授权」的令牌。
    const n = this.ticketSeq++;
    return `t${String(n)}-${this.rng.int(0, 0x1000000).toString(16).padStart(6, "0")}`;
  }

  private refuse(
    to: PeerId,
    tick: number,
    reason: JoinRejectReason,
    detail?: Readonly<Record<string, number>>,
  ): JoinRefused {
    this.refused[reason]++;
    return refusedReply(this.hostPeer, to, tick, this.outSeq++, reason, detail);
  }

  private acceptedReply(peer: PeerId, tick: number, seat: Seat, json: string, reconnected: boolean): JoinAccepted {
    return {
      kind: "join-reply",
      from: this.hostPeer,
      to: peer,
      tick,
      seq: this.outSeq++,
      accepted: true,
      playerId: seat.playerId,
      ticket: seat.ticket,
      reconnected,
      json,
    };
  }
}

export function createRoom(opts: RoomOptions): Room {
  return new RoomImpl(opts);
}

// ---------------------------------------------------------------- 房间发现

/**
 * 把「一张房间表」变成「能进 / 不能进，为什么」。
 *
 * ★ 版本不符的房间**照列**，不静默过滤：过滤之后列表是空的，玩家看到的是
 *   「没有房间」，而事实是「有三个房间，但都要更新」。这两句话对应完全不同的行动。
 * ★ 按 `id` 升序：发现列表的顺序不该取决于谁先上报（网络到达顺序每次都不一样）。
 */
export function discoverRooms(
  rooms: readonly RoomInfo[],
  opts: { readonly protocolVersion?: number } = {},
): readonly RoomCandidate[] {
  const mine = opts.protocolVersion ?? PROTOCOL_VERSION;
  const out: RoomCandidate[] = rooms.map((r) => {
    let reason: JoinRejectReason | null = null;
    if (r.protocolVersion !== mine) {
      // ★ 报的是**你**相对于那个房间：房间比你旧 ⇒ 你比它新。
      reason = r.protocolVersion < mine ? JoinReject.VersionNew : JoinReject.VersionOld;
    } else if (r.players >= r.maxPlayers) {
      reason = JoinReject.Full;
    }
    return { ...r, joinable: reason === null, reason };
  });
  out.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return out;
}

// ---------------------------------------------------------------- 客户端

/**
 * 客户端的握手状态机。
 *
 * ★★ 为什么它必须和 `Room` 写在同一个文件里
 *
 *   客户端这边的每一条判定都是主机那边某一条拒绝的**镜像**（版本怎么比、票据什么时候
 *   还有效、什么样的回复算「半份」）。分成两个文件之后，两边的形状会在某次改动里各走
 *   一步 —— 那种错不会报错，只会让「主机拒了但客户端以为自己进了」变成间歇性现象。
 *
 * ★★ 三条契约
 *
 * ① **没有票据就没有重连**：`drop()` **保留** `playerId` 与票据，`request()` 自动带上。
 *    清掉它们等于把「掉线重连」退化成「以新玩家身份重新加入」—— 症状是回到房间发现
 *    自己的角色归了 `AUTHORITY`（谁都推不动），而客户端显示一切正常。
 * ② **同一份回复只应用一次**：`takeSnapshot()` 取走即清。应用两遍 = 一次凭空回滚，
 *    客户端的插值 / 预测全乱，而终态位置仍然是对的。
 * ③ **回复以主机为准**：`playerId` 永远取回复里的那个，不取自己记着的那个。票据过期
 *    降级成新玩家时两者不同 —— 这时候要**看得见**（`seatChanges`），否则客户端会一直
 *    用旧号发意图，全被 `no-seat` 拒掉，而面板上写的是「已连接」。
 */
export type JoinState = "idle" | "joining" | "joined" | "refused" | "lost";

export interface JoinerOptions {
  /** 本端端点号（回复按 `to` 过滤）。 */
  readonly self: PeerId;
  readonly name: string;
  readonly protocolVersion?: number;
}

export interface JoinerStats {
  readonly state: JoinState;
  /** 发了多少次请求（含重发）。 */
  readonly requests: number;
  /** 以**新玩家**身份进房的次数。 */
  readonly joins: number;
  /** 复用掉线座位的次数。 */
  readonly reconnects: number;
  readonly refusals: number;
  /** 主机给的座位号与本端记着的不一样（票据过期 / 房间重建）。 */
  readonly seatChanges: number;
  /** 不是给我的、或没在等却来的回复。 */
  readonly strayReplies: number;
  /** 形状不完整的回复（缺 `json` / `playerId`）—— 一律不应用，继续等。 */
  readonly badReplies: number;
  readonly drops: number;
  readonly lastRefusal: JoinRejectReason | null;
}

export interface Joiner {
  state(): JoinState;
  /**
   * 生成一条加入请求。
   *
   * ★ 在 `joining` 里再调一次是**重发**（请求丢了就永远连不上，而玩家看到的是
   *   「正在连接…」）。重发节奏归调用方 —— 它知道 tick，本层只保证「重发是安全的」。
   */
  request(tick: number): JoinRequest;
  /** 应用一条回复。返回 `true` = 真的应用了（进了 `joined` 或 `refused`）。 */
  reply(msg: JoinReply): boolean;
  /** 取走入房快照（**一次**）。没有就 `null`。 */
  takeSnapshot(): string | null;
  playerId(): PlayerId | null;
  ticket(): string | null;
  /** 连接断了：保留座位号与票据，下次 `request()` 会带着它们。 */
  drop(): void;
  stats(): JoinerStats;
}

class JoinerImpl implements Joiner {
  private readonly selfPeer: PeerId;
  private readonly name: string;
  private readonly version: number;

  private now: JoinState = "idle";
  /** 已经在等一条回复。用它而不是 `now === "joining"`：重发之后状态可能仍是 `joined`。 */
  private awaiting = false;
  private mine: PlayerId | null = null;
  private held: string | null = null;
  private pending: string | null = null;
  private outSeq = 0;

  private requests = 0;
  private joins = 0;
  private reconnects = 0;
  private refusals = 0;
  private seatChanges = 0;
  private strayReplies = 0;
  private badReplies = 0;
  private drops = 0;
  private lastRefusal: JoinRejectReason | null = null;

  constructor(opts: JoinerOptions) {
    this.selfPeer = opts.self;
    this.name = opts.name;
    this.version = opts.protocolVersion ?? PROTOCOL_VERSION;
  }

  state(): JoinState {
    return this.now;
  }

  request(tick: number): JoinRequest {
    const base = {
      kind: "join" as const,
      from: this.selfPeer,
      tick,
      seq: this.outSeq++,
      protocolVersion: this.version,
      name: this.name,
    };
    this.awaiting = true;
    this.requests++;
    if (this.now !== "joined") this.now = "joining";
    return this.held === null ? base : { ...base, ticket: this.held };
  }

  reply(msg: JoinReply): boolean {
    if (msg.to !== this.selfPeer) {
      this.strayReplies++;
      return false;
    }
    if (!this.awaiting) {
      // 迟到 / 重放 / 重复：同一份回复再应用一次 = 凭空回滚一次世界。
      this.strayReplies++;
      return false;
    }
    if (!msg.accepted) {
      this.awaiting = false;
      this.now = "refused";
      this.refusals++;
      this.lastRefusal = msg.reason;
      return true;
    }
    // ★ 半份回复：类型上不存在（判别联合），运行期可能是坏数据。此时**不动状态**、
    //   继续等 —— 「半连着」比「没连上」难查得多。
    if (
      typeof msg.json !== "string" ||
      msg.json.length === 0 ||
      typeof msg.ticket !== "string" ||
      !Number.isInteger(msg.playerId)
    ) {
      this.badReplies++;
      return false;
    }
    const prev = this.mine;
    this.awaiting = false;
    this.mine = msg.playerId;
    this.held = msg.ticket;
    this.pending = msg.json;
    this.now = "joined";
    if (prev !== null && prev !== msg.playerId) this.seatChanges++;
    if (msg.reconnected) this.reconnects++;
    else this.joins++;
    return true;
  }

  takeSnapshot(): string | null {
    const s = this.pending;
    this.pending = null;
    return s;
  }

  playerId(): PlayerId | null {
    return this.mine;
  }

  ticket(): string | null {
    return this.held;
  }

  drop(): void {
    if (this.now === "idle") return;
    if (this.now === "joined" || this.now === "joining") this.drops++;
    // ★ 座位号与票据都留着：重连靠它们回到同一个座位（见文件头 ①）。
    this.awaiting = false;
    this.pending = null;
    this.now = "lost";
  }

  stats(): JoinerStats {
    return {
      state: this.now,
      requests: this.requests,
      joins: this.joins,
      reconnects: this.reconnects,
      refusals: this.refusals,
      seatChanges: this.seatChanges,
      strayReplies: this.strayReplies,
      badReplies: this.badReplies,
      drops: this.drops,
      lastRefusal: this.lastRefusal,
    };
  }
}

export function createJoiner(opts: JoinerOptions): Joiner {
  return new JoinerImpl(opts);
}
