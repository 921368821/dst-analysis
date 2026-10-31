/**
 * L4 · 会话（Session）：把「传输」接到「世界」上 —— 客户端只发意图，主机每 N 拍广播快照
 *
 * ★★ 一条边界：**只有主机改世界**。
 *
 *   客户端发的是「我想怎么走」，不是「我在哪」。这条一旦破了（客户端也改位置），
 *   两台机器就会各自算出一份世界，然后靠"谁后写"决定收敛到哪里 —— 那是一种
 *   永远查不干净的漂移。所以客户端拿到快照之后是**整场替换**，不是"把差异合过来"。
 *
 * ★★ 三个刻意的设计，每个都对应一个会静默发生的 bug：
 *
 * ① **输入按「每拍最多消化一条」排队，不是到了就执行**
 *    一次 200ms 的卡顿之后，5 条意图会在同一拍一起到达。全部执行 ⇒ 角色瞬移 5 拍
 *    （画面上是"跳了一下"，数值上位置完全正确，所以任何"终态一致"的判据都是绿的）。
 *    排队之后：每拍消化一条，多出来的留在队列里；队列超过上限时**丢最老的**
 *    （丢最新的会让角色的时间轴永久落后，而丢最老的只是丢掉最早那段输入）。
 *
 * ② **授权在收下的那一刻判断，不是在执行的那一刻**
 *    "这条意图发出来的时候，发送方拥有这个实体吗" 才是正确的问题。放到执行时判断，
 *    一次交接（房主换人）会把前任发在路上的意图应用到新主人身上 —— 症状是交接后
 *    新角色自己走了一小段，而两边都不知道为什么。
 *
 * ③ **两种角色收到的消息种类是互斥的**：主机只该收到 `intent`，客户端只该收到
 *    `snapshot`。收到另一种不是"忽略就好"，而是**协议违规**：它意味着有第二个主机、
 *    或者有客户端在往上广播世界。必须计数可见，否则这条线断了没人知道。
 *
 * ★ 主机**自己的**输入不走网络（`local` 直接执行）：主机权威的本地输入不该有 RTT，
 *   这不是后门 —— 它过的是**同一道授权检查**（`owner === self`），所以"主机能驱动
 *   别人的角色"这件事不会因为它绕开网络而重新出现。
 *
 * ★★ 归属比对用的是**座位号**，不是端点号（`playerOf`）
 *
 *   信封上的 `from` 是「这根线是几号口」，由传输盖章；`net.identity.owner` 里存的是
 *   「这个实体归几号玩家」，由主机的加入握手盖章（`net/join.ts`）。两者今天在环回里
 *   都是 0/1，所以最省事的写法是直接比 —— 而那样一来，「重连后你还是你」就变成了
 *   「重连后你拿到了同一个端口」，在真实传输里根本不成立（每次连接都是新 handle），
 *   且所有关于归属的判据照样全绿。`playerOf` 就是这个转换点，缺省恒等（单机 / 环回）。
 *
 *   映射返回 `null` 时给的是 `no-seat` 而不是 `not-owner`：这两句话对应完全不同的
 *   行动（「这个连接没有座位」vs「这不是你的角色」），压成一个码之后，掉线之后还在
 *   发的那串意图会看起来像有人在抢别人的角色。
 *
 * ★ 快照用 `mode: "rollback"` 导出（见 `core/scene/component.ts`）：
 *   网络快照不是「新会话的存档」，而是「第 T 拍的世界」。两者对缓存的语义相反 ——
 *   存档里寻路路径是过期的，快照里它必须一致。用错模式不会报错，只会让客户端的
 *   副本与主机在第 T 拍差一个字段。
 *
 * ★★ 增量快照（批160）：广播发的是「相对上一份的差」，不再是整棵树
 *
 *   口径（哪些字段算变化量、为什么按组件整体而不按字段）全在 `net/delta.ts`
 *   的文件头 —— 那是唯一的规格，这里只写**会话层**要多管的三件事：
 *
 *   ① **基线是「上一份成功发出去的内容」，不是「上一拍的世界」。**
 *      `sentSnap` 只在 `transport.send` 返回 `true` 之后才前移。环回能知道「这条当场
 *      就丢了」，真实传输不知道 —— 所以还有 ②。差别在于：拿「上一拍的世界」当基线时，
 *      丢一份快照会让客户端**永久**对不上（后面每份增量都是基于它没有的世界），
 *      而症状是「客户端某几个东西再也不动」，位置却停在一个合理的地方。
 *
 *   ② **对不上就明说**：客户端发现 `base` 与自己的基线不一致 / 增量读不回来 /
 *      增量与基线严丝合缝地对不上，就发一条 `resync`，主机下一份广播改成全量。
 *      不做「等下一次关键帧」：等待时长 = `keyframeEvery × snapshotEveryTicks` 拍，
 *      30Hz 默认配置下是 1.5 秒，玩家看到的是「人全冻住了」。
 *
 *   ③ **客户端的世界仍然是整场替换**（`loadScene`）。增量只在**数据层**合成 ——
 *      先把增量应用到上一份快照上得到完整快照，再整场装载。这条边界是批152 立的，
 *      破了它就会出现两套增量修改逻辑各差一个字段。代价诚实地说：客户端每份快照的
 *      CPU 代价仍是 O(节点数)，省下的是带宽，不是装载时间。
 *
 * ★ `seq` 是「这一族消息内」单调的（`transport.ts` ⑤）：会话的广播与意图、房间的
 *   回复、客户端的 `resync` 各自从 0 数。所以 `base` 只可能指向会话自己发过的快照，
 *   不会与房间的 `join-reply` 撞号。
 */

import type { ComponentRegistry } from "../../core/scene/component.ts";
import type { NodeId } from "../../core/scene/node.ts";
import type { Scene } from "../../core/scene/scene.ts";
import { loadScene, sceneFromJson, sceneToJson, type SceneSnapshot } from "../../core/scene/scene-io.ts";
import { applyDelta, deltaFromJson, deltaToJson, diffSnapshot, snapshotOfScene } from "./delta.ts";
import { CONTROLLER_TYPE, PlayerController } from "../input/player-controller.ts";
import { dirStep, type MoveIntent } from "../motion/intent.ts";
import { AUTHORITY, NET_IDENTITY_TYPE, NetIdentity, assignOwner, ownedBy, type PlayerId } from "./identity.ts";
import {
  ResyncReason,
  type IntentMessage,
  type PeerId,
  type ResyncMessage,
  type SnapshotDeltaMessage,
  type SnapshotMessage,
  type Transport,
} from "./transport.ts";

export type NetRole = "host" | "client";

/** 方向型意图。目前只有这一种能过网，理由见 `NetReject.UnsupportedKind`。 */
type DirIntent = Extract<MoveIntent, { kind: "move.dir" }>;

function isDirIntent(i: MoveIntent): i is DirIntent {
  return i.kind === "move.dir";
}

/**
 * 一条本地输入：谁想怎么走。
 *
 * ★ 带上 `entity` 而不是"默认本端的角色"：一个对端拥有几个实体（分屏、观战、
 *   交接间隙）从第一天就会发生，而"默认第一个"这种约定在第二次改动时就会变成
 *   不可解释的行为。
 */
export interface LocalCommand {
  readonly entity: NodeId;
  readonly intent: MoveIntent;
}

/** 被拒原因。**每一个都要能被计数**：不计数就等于静默丢弃。 */
export const NetReject = {
  /** 场景里没有这个节点（已被销毁，或客户端发错了 id）。 */
  NoEntity: "no-entity",
  /** 节点没挂 `net.identity` —— 它不参与联机，谈不上归属。 */
  NoIdentity: "no-identity",
  /** 发送方不是它的所有者（伪造 / 交接后仍在路上的旧意图）。 */
  NotOwner: "not-owner",
  /** 不是 `game.controller` 实体：没有速度来源，驱动它只会得到"什么都没发生"。 */
  NoController: "no-controller",
  /**
   * 发送方当前没有座位（没握手 / 座位已超时被清 / 掉线中）。
   *
   * ★ 与 `NotOwner` 分开：前者是「这个连接不属于任何玩家」（握手层的事），
   *   后者是「它属于某个玩家，但不是这条实体的主人」（玩法层的事）。
   */
  NoSeat: "no-seat",
  /** 目前只支持方向型意图（`move.cell` 要主机自己持有寻路状态，见文件头）。 */
  UnsupportedKind: "unsupported-kind",
} as const;

export type NetRejectReason = (typeof NetReject)[keyof typeof NetReject];

export interface SessionOptions {
  readonly role: NetRole;
  readonly transport: Transport;
  readonly scene: Scene;
  readonly registry: ComponentRegistry;
  /**
   * 主机每几拍广播一次快照。缺省 5（30Hz 下约 6.7 次/秒）。
   *
   * ★ 这是「带宽 vs 客户端看到的世界有多旧」的刻度盘。设 1 时客户端逐拍精确，
   *   但每个客户端每拍都要收一整棵树；设太大时客户端的位置是"抽帧"的。
   *   预测/插值该在这条线的上层做，不该靠把这个数改成 1 来掩盖。
   */
  readonly snapshotEveryTicks?: number;
  /**
   * 增量快照：每多少份广播里至少有一份**全量**（关键帧）。缺省 10。
   *
   * ★ 设 1 = 关掉增量（每次全量）。这既是**对照实验的开关**（带宽判据就是拿它
   *   与 10 比出来的），也是排障的第一步：客户端一直对不上时先设成 1，
   *   世界立刻就对 ⇒ 问题在增量层，不在会话层。
   * ★ 不提供「永不发全量」：增量链越长，一次「两边理解不同」的窗口就越长。
   *   关键帧是兜底，真正的主路径是重同步请求（它不用等）。
   */
  readonly keyframeEvery?: number;
  /**
   * 每个实体最多积压几条未消化的意图。缺省 3。
   *
   * ★ 上限不是"性能考虑"，是正确性：没有上限时一次长卡顿会积压几百条，
   *   恢复之后角色要花几百拍"补作业"，而玩家早就松手了。
   */
  readonly maxQueuedIntents?: number;
  /**
   * 端点号 → 座位号。缺省恒等（单机 / 环回）。
   *
   * ★ 由加入握手提供（`playerOf: room.playerOf` 主机侧、`() => joiner.playerId()`
   *   客户端侧）。**两端的来源不同，但都必须来自握手** —— 任何一端自己编号，
   *   归属就会在重连时分叉。返回 `null` = 这个端点现在没有座位。
   */
  readonly playerOf?: (peer: PeerId) => PlayerId | null;
  /**
   * 本地输入来源。主机 = 玩家输入，客户端 = 要发出去的意图。
   *
   * ★ 做成"每拍问一次"而不是"推一条进来"：推送会让"这一拍有没有输入"取决于
   *   调用次数，而每拍问一次时，"没有输入"就是 `null`，不多不少。
   */
  readonly local?: (tick: number) => LocalCommand | null;
}

export interface SessionStats {
  readonly role: NetRole;
  /** 主机：真正落到世界上的本地输入条数。 */
  readonly localApplied: number;
  /** 主机：真正落到世界上的远程输入条数。 */
  readonly remoteApplied: number;
  /** 主机：被拒的输入（按原因分）。 */
  readonly rejected: Readonly<Record<NetRejectReason, number>>;
  /** 主机：因为队列满而丢掉的条数（丢的是最老的）。 */
  readonly backlogDropped: number;
  /** 主机：上行意图的 seq 缺口总数（丢包可发现）。 */
  readonly intentGaps: number;
  /** 客户端：下行快照的 seq 缺口总数。 */
  readonly snapshotGaps: number;
  /** 客户端：拒绝应用的旧快照条数（乱序 / 重放）。 */
  readonly staleSnapshots: number;
  /** 客户端：解析或装载失败的快照条数。 */
  readonly badSnapshots: number;
  /** 两种角色：收到了不该收到的消息种类。 */
  readonly protocolViolations: number;
  /** 主机：发出去的广播总份数（全量 + 增量）。 */
  readonly snapshotsSent: number;
  /** 主机：其中的全量份数。 */
  readonly keyframesSent: number;
  /** 主机：其中的增量份数。 */
  readonly deltasSent: number;
  /**
   * 主机：快照负载的字符数总和（UTF-16 码元）。
   *
   * ★ 叫「字节」会撒谎（多字节字符时不等长），叫「带宽」更不行（还有信封）。
   *   它唯一的用途是**同一场景下两种策略的相对比较** —— 那一比较里两端用同一把尺子。
   */
  readonly snapshotCharsSent: number;
  /** 客户端：应用成功的份数（全量 + 增量）。 */
  readonly snapshotsApplied: number;
  /** 客户端：其中全量的份数。 */
  readonly keyframesApplied: number;
  /** 客户端：其中增量的份数。 */
  readonly deltasApplied: number;
  /** 客户端：对不上基线而放弃应用的份数（每份都会触发一次重同步请求）。 */
  readonly desyncs: number;
  /** 客户端：发出去的重同步请求条数。 */
  readonly resyncsSent: number;
  /** 主机：收到的重同步请求条数。 */
  readonly resyncsReceived: number;
  readonly intentsSent: number;
  /** 客户端：最近一次应用成功的快照属于哪一拍（-1 = 还没收到过）。 */
  readonly lastSnapshotTick: number;
  /** 本端当前能驱动的实体数（客户端读它决定"给谁发意图"）。 */
  readonly owned: number;
  /** 还在主机队列里等消化的条数。 */
  readonly queued: number;
}

export interface NetSession {
  readonly role: NetRole;
  /**
   * 推进一拍。
   *
   * ★ 一个入口同时覆盖主机与客户端（而不是 `hostTick` / `clientTick` 两个）：
   *   两条入口一定有一条会被下一次改动落下（本仓库反复踩过），而这里两者的差别
   *   只在「收到什么、发什么」，那本来就该是一段 if。
   *
   * ★ 只能**一拍调一次**：同一拍调两次会让一个实体在一拍里消化两条意图 ——
   *   而队列存在的全部意义就是防这件事。走 `attachSession` 时由调度器的幂等保护
   *   兜住（`runStep` 对同一个 tick 绝不回调两次）；直接调用的判据要自己保证。
   */
  step(tick: number, dt: number): void;
  /** 主机：把实体的归属交给某个对端（交接 / 加入）。客户端调用会被拒并计数。 */
  assign(nodeId: NodeId, peer: PeerId): boolean;
  /**
   * 主机：下一份广播发全量（关键帧）。
   *
   * ★ 用在「世界在会话背后被改过」的时刻，最典型的是加入握手刚给完归属
   *   （`net/join.ts` 的 `snapshot` 回调里拍的快照与会话的基线不是同一份）。
   *   不调也不会错：客户端的 `base` 会对不上，它自己会 `resync` 要一份 ——
   *   代价是一个往返还可能丢，而且从日志看像一次网络故障。
   * ★ 客户端调用按协议违规计：只有权威知道「世界什么时候被偷偷改过」。
   */
  requestKeyframe(): void;
  stats(): SessionStats;
}

interface Admitted {
  readonly ok: true;
  readonly intent: DirIntent;
}
interface Refused {
  readonly ok: false;
  readonly reason: NetRejectReason;
}
type Admission = Admitted | Refused;

class Session implements NetSession {
  /** 角色是公开的：面板与判据要按角色解释同一份计数器。 */
  readonly role: NetRole;
  private readonly transport: Transport;
  private readonly scene: Scene;
  private readonly registry: ComponentRegistry;
  private readonly snapshotEvery: number;
  private readonly keyframeEvery: number;
  private readonly maxQueued: number;
  private readonly local: ((tick: number) => LocalCommand | null) | null;
  private readonly playerOf: (peer: PeerId) => PlayerId | null;

  /** 待消化的方向意图，按实体分组。**插入序即到达序**（传输保序）。 */
  private readonly queues = new Map<NodeId, DirIntent[]>();
  /** 每个发送方最后看到的意图 seq。 */
  private readonly intentSeq = new Map<PeerId, number>();

  private outSeq = 0;
  /** 客户端：见过的最大快照 `seq`（含**没能应用**的那份）。缺口与乱序都靠它。 */
  private seenSeq = -1;
  /**
   * 客户端：手上这份世界对应哪一份快照的 `seq`。
   *
   * ★ 与 `seenSeq` 分开：一份增量「收到了但没能应用」时，`seenSeq` 该前移
   *   （否则下一份的缺口会被算成丢包），而基数**不能**前移（否则下一份增量会
   *   合到一份不是它基线的世界上）。
   */
  private baseSeq = -1;
  /** 客户端：基数那份快照的内容（增量只在这个数据层上合成）。 */
  private baseSnap: SceneSnapshot | null = null;
  private lastSnapshotTick = -1;

  /** 主机：上一份**成功发出去**的内容（增量的基线）。`null` = 还没发过，下一份必须是全量。 */
  private sentSnap: SceneSnapshot | null = null;
  /** 主机：`sentSnap` 那份的 `seq`（增量里的 `base`）。 */
  private sentSeq = -1;
  /** 主机：距离上一份全量发了几份。 */
  private sinceKeyframe = 0;
  /** 主机：有客户端说对不上，下一份改全量。 */
  private forceFull = false;
  /** 客户端：重同步请求自己的序号（**不与意图共用**，见文件头末尾）。 */
  private ctrlSeq = 0;

  private localApplied = 0;
  private remoteApplied = 0;
  private backlogDropped = 0;
  private intentGaps = 0;
  private snapshotGaps = 0;
  private staleSnapshots = 0;
  private badSnapshots = 0;
  private protocolViolations = 0;
  private snapshotsSent = 0;
  private keyframesSent = 0;
  private deltasSent = 0;
  private snapshotCharsSent = 0;
  private snapshotsApplied = 0;
  private keyframesApplied = 0;
  private deltasApplied = 0;
  private desyncs = 0;
  private resyncsSent = 0;
  private resyncsReceived = 0;
  private intentsSent = 0;
  private readonly rejected: Record<NetRejectReason, number>;

  constructor(opts: SessionOptions) {
    const every = opts.snapshotEveryTicks ?? 5;
    if (!Number.isInteger(every) || every < 1) {
      throw new RangeError(`snapshotEveryTicks 必须是 ≥1 的整数，收到 ${String(every)}`);
    }
    const queued = opts.maxQueuedIntents ?? 3;
    if (!Number.isInteger(queued) || queued < 1) {
      throw new RangeError(`maxQueuedIntents 必须是 ≥1 的整数，收到 ${String(queued)}`);
    }
    const keyframe = opts.keyframeEvery ?? 10;
    if (!Number.isInteger(keyframe) || keyframe < 1) {
      throw new RangeError(`keyframeEvery 必须是 ≥1 的整数（1 = 关掉增量），收到 ${String(keyframe)}`);
    }
    this.role = opts.role;
    this.transport = opts.transport;
    this.scene = opts.scene;
    this.registry = opts.registry;
    this.snapshotEvery = every;
    this.keyframeEvery = keyframe;
    this.maxQueued = queued;
    this.local = opts.local ?? null;
    this.playerOf = opts.playerOf ?? ((peer: PeerId): PlayerId => peer);
    this.rejected = {
      [NetReject.NoEntity]: 0,
      [NetReject.NoIdentity]: 0,
      [NetReject.NotOwner]: 0,
      [NetReject.NoController]: 0,
      [NetReject.NoSeat]: 0,
      [NetReject.UnsupportedKind]: 0,
    };
  }

  step(tick: number, dt: number): void {
    // ---- ① 收：两种角色收到的合法消息互斥，另一种算协议违规
    for (const msg of this.transport.receive(tick)) {
      if (this.role === "host") {
        if (msg.kind === "intent") this.onIntent(msg);
        else if (msg.kind === "resync") this.onResync(msg);
        else this.protocolViolations++;
      } else {
        if (msg.kind === "snapshot") this.onSnapshot(msg, tick);
        else if (msg.kind === "snapshot-delta") this.onDelta(msg, tick);
        else this.protocolViolations++;
      }
    }

    // ---- ② 本地：主机直接执行，客户端封装成一条消息发出去
    const cmd = this.local === null ? null : this.local(tick);
    if (cmd !== null) {
      if (this.role === "host") this.applyLocal(cmd, dt);
      else this.sendIntent(cmd, tick);
    }

    if (this.role !== "host") return;

    // ---- ③ 每拍每个实体最多消化一条（见文件头 ①）
    this.drainOnePerEntity(dt);

    // ---- ④ 广播：在移动**之后**，于是这条快照描述的是第 tick 拍的世界
    if (tick % this.snapshotEvery === 0) this.broadcast(tick);
  }

  assign(nodeId: NodeId, peer: PeerId): boolean {
    if (this.role !== "host") {
      // ★ 不静默返回 false：客户端改归属是协议违规，必须和"别人的意图"一样可见。
      this.protocolViolations++;
      return false;
    }
    return assignOwner(this.scene, nodeId, peer);
  }

  requestKeyframe(): void {
    if (this.role !== "host") {
      // ★ 客户端没有「强制关键帧」这个动作：它连基线都对不上时该做的是 `resync`。
      //   静默忽略会让一行接错的代码永远不报错。
      this.protocolViolations++;
      return;
    }
    this.forceFull = true;
  }

  stats(): SessionStats {
    let queued = 0;
    for (const q of this.queues.values()) queued += q.length;
    // ★ 没有座位时 `owned` 必须是 0，不能退化成「归 AUTHORITY 的都算我的」：
    //   那样一个还没握手的客户端会以为自己拥有满场 AI。
    const mine = this.playerOf(this.transport.self);
    return {
      role: this.role,
      localApplied: this.localApplied,
      remoteApplied: this.remoteApplied,
      rejected: { ...this.rejected },
      backlogDropped: this.backlogDropped,
      intentGaps: this.intentGaps,
      snapshotGaps: this.snapshotGaps,
      staleSnapshots: this.staleSnapshots,
      badSnapshots: this.badSnapshots,
      protocolViolations: this.protocolViolations,
      snapshotsSent: this.snapshotsSent,
      keyframesSent: this.keyframesSent,
      deltasSent: this.deltasSent,
      snapshotCharsSent: this.snapshotCharsSent,
      snapshotsApplied: this.snapshotsApplied,
      keyframesApplied: this.keyframesApplied,
      deltasApplied: this.deltasApplied,
      desyncs: this.desyncs,
      resyncsSent: this.resyncsSent,
      resyncsReceived: this.resyncsReceived,
      intentsSent: this.intentsSent,
      lastSnapshotTick: this.lastSnapshotTick,
      owned: mine === null ? 0 : ownedBy(this.scene, mine).length,
      queued,
    };
  }

  // ---------------------------------------------------------------- 收

  private onIntent(msg: IntentMessage): void {
    // seq 缺口 = 中间丢了。主机没法让丢的那条重来，但**必须留下证据**：
    // 否则"玩家说按了没反应"与"网络丢了"在日志里长得一模一样。
    const prev = this.intentSeq.get(msg.from);
    if (prev !== undefined && msg.seq > prev + 1) this.intentGaps += msg.seq - prev - 1;
    if (prev === undefined || msg.seq > prev) this.intentSeq.set(msg.from, msg.seq);

    const a = this.admit(msg.from, msg.entity, msg.intent);
    if (!a.ok) {
      this.rejected[a.reason]++;
      return;
    }
    let q = this.queues.get(msg.entity);
    if (q === undefined) {
      q = [];
      this.queues.set(msg.entity, q);
    }
    q.push(a.intent);
    // ★ 丢最老的：丢最新的会让实体永久落后于时间轴（越丢越晚），
    //   而丢最老的只是放弃最早那段输入，位置最终仍然追得上。
    while (q.length > this.maxQueued) {
      q.shift();
      this.backlogDropped++;
    }
  }

  /**
   * 序号诊断（**只看收到过什么**，不看应用成功没成功）。
   *
   * ★ 两个计数器要分开，否则「收到但没应用」会被记成「丢了」：
   *   `seenSeq` 管缺口与乱序，`baseSeq` 管「我这份世界是哪一份」。合成一个时，
   *   一次坏增量会让下一份好增量的缺口凭空 +1 —— 而丢包本来是要能被数清的。
   *
   * 返回 `false` = 这份比手上看过的旧（乱序 / 重放），一律不应用。
   */
  private noteSeq(seq: number): boolean {
    if (this.seenSeq >= 0) {
      const missed = seq - this.seenSeq - 1;
      if (missed > 0) this.snapshotGaps += missed;
      if (seq <= this.seenSeq) {
        // 乱序 / 重放：旧快照不许覆盖新世界。用 `<=` 而不是 `<` 是因为
        // 同一 seq 到达两次时，第二次应用没有意义（整场替换代价不小）。
        this.staleSnapshots++;
        return false;
      }
    }
    this.seenSeq = seq;
    return true;
  }

  private onSnapshot(msg: SnapshotMessage, tick: number): void {
    if (!this.noteSeq(msg.seq)) return;

    const parsed = sceneFromJson(msg.json);
    if (!parsed.ok) {
      this.badSnapshots++;
      this.askFull(tick, ResyncReason.Bad);
      return;
    }
    if (!this.commit(parsed.value)) {
      this.badSnapshots++;
      this.askFull(tick, ResyncReason.Bad);
      return;
    }
    this.baseSnap = parsed.value;
    this.baseSeq = msg.seq;
    this.snapshotsApplied++;
    this.keyframesApplied++;
    this.lastSnapshotTick = msg.tick;
  }

  /**
   * 应用一份增量：**先合出一份完整快照，再整场替换**（见文件头 ③）。
   *
   * ★ 三条「不算数」的路径各自对应一种真实故障，而且都必须**要一份全量**：
   *   · `base` 对不上 ⇒ 中间丢了一份（或者我刚从一份全量里恢复，而主机的基线更早）；
   *   · 增量读不回来 ⇒ 包坏了 / 版本不同；
   *   · 补丁指向基线里没有的节点 ⇒ 两边对「基线是什么」理解不同（最隐蔽的一类：
   *     合出来的世界节点一个不少，只有某个字段是旧的）。
   */
  private onDelta(msg: SnapshotDeltaMessage, tick: number): void {
    if (!this.noteSeq(msg.seq)) return;
    if (this.baseSnap === null || msg.base !== this.baseSeq) {
      this.desyncs++;
      this.askFull(tick, ResyncReason.Base);
      return;
    }
    const parsed = deltaFromJson(msg.json);
    if (!parsed.ok) {
      this.badSnapshots++;
      this.askFull(tick, ResyncReason.Bad);
      return;
    }
    const applied = applyDelta(this.baseSnap, parsed.value);
    if (applied.orphans > 0) {
      this.desyncs++;
      this.askFull(tick, ResyncReason.Orphan);
      return;
    }
    if (!this.commit(applied.snap)) {
      this.badSnapshots++;
      this.askFull(tick, ResyncReason.Bad);
      return;
    }
    this.baseSnap = applied.snap;
    this.baseSeq = msg.seq;
    this.snapshotsApplied++;
    this.deltasApplied++;
    this.lastSnapshotTick = msg.tick;
  }

  /**
   * 装载一份完整快照。返回 `false` = 没装成（世界保持原样）。
   *
   * ★ `loadScene` 唯一的失败路径是「格式比引擎新」，它在 `scene.clear()` **之前**
   *   就返回了 —— 所以失败时世界没被动过。这一点不能靠「大概吧」：上面的
   *   `baseSnap` 只有在装载成功之后才前移，靠的就是它。
   */
  private commit(snap: SceneSnapshot): boolean {
    return loadScene(this.scene, snap, this.registry).ok;
  }

  /** 请主机给一份全量。**幂等**：多要一份只浪费一点带宽，所以不做去重与重试上限。 */
  private askFull(tick: number, reason: ResyncReason): void {
    const msg = {
      kind: "resync" as const,
      from: this.transport.self,
      tick,
      seq: this.ctrlSeq++,
      reason,
    };
    if (this.transport.send(msg)) this.resyncsSent++;
  }

  /**
   * 主机收到重同步请求：下一份广播改全量。
   *
   * ★ 不校验发送方有没有座位：会话层不认识座位表（那是 `net/join.ts` 的事），
   *   而多给一份全量最多浪费带宽。在这里加一道「它有座位吗」的检查，会把
   *   「掉线中的人请求恢复」判成攻击，而那种情况下他恰恰最需要一份。
   */
  private onResync(msg: ResyncMessage): void {
    void msg;
    this.resyncsReceived++;
    this.forceFull = true;
  }

  // ---------------------------------------------------------------- 授权与执行

  /**
   * 一条意图能不能被执行。
   *
   * ★ 顺序有意义：先"实体在不在"（客户端发错 id 与交接后实体被销毁都会到这里），
   *   再"归不归你"，最后才看"这种意图能不能驱动它"。反过来时，一个伪造的 id
   *   会先被算成 `unsupported-kind` —— 于是"有人在冒充别人"这条证据就没了。
   */
  private admit(from: PeerId, entity: NodeId, intent: MoveIntent): Admission {
    const node = this.scene.find(entity);
    if (node === undefined) return { ok: false, reason: NetReject.NoEntity };
    const id = node.get<NetIdentity>(NET_IDENTITY_TYPE);
    if (id === undefined) return { ok: false, reason: NetReject.NoIdentity };
    // ★ 先问「这个端点有没有座位」，再问「这个实体是不是他的」：顺序反了时，
    //   一个已经掉线超时的连接会报成 not-owner —— 看起来像"有人在抢角色"。
    const pid = this.playerOf(from);
    if (pid === null) return { ok: false, reason: NetReject.NoSeat };
    if (id.owner !== pid) return { ok: false, reason: NetReject.NotOwner };
    if (!isDirIntent(intent)) return { ok: false, reason: NetReject.UnsupportedKind };
    if (node.get<PlayerController>(CONTROLLER_TYPE) === undefined) {
      return { ok: false, reason: NetReject.NoController };
    }
    return { ok: true, intent };
  }

  private applyLocal(cmd: LocalCommand, dt: number): void {
    // ★ 本地输入走**同一道**授权检查：主机也不许驱动别人的角色。
    //   给它开一条"本地不用查"的捷径，交接之后就会出现"两个人的输入推同一个角色"。
    const a = this.admit(this.transport.self, cmd.entity, cmd.intent);
    if (!a.ok) {
      this.rejected[a.reason]++;
      return;
    }
    this.move(cmd.entity, a.intent, dt);
    this.localApplied++;
  }

  private drainOnePerEntity(dt: number): void {
    for (const [entity, q] of this.queues) {
      if (q.length === 0) continue;
      const intent = q.shift();
      if (intent === undefined) continue;
      this.move(entity, intent, dt);
      this.remoteApplied++;
    }
  }

  /**
   * 真正改变世界的地方。
   *
   * ★ 只走 `dirStep`：网上的意图与本地玩家、AI 共用同一个位移实现（批147）。
   *   这里如果自己再算一遍归一化，就出现了第二份"对角线速度"。
   */
  private move(entity: NodeId, intent: DirIntent, dt: number): void {
    const node = this.scene.find(entity);
    // 队列里躺着的实体可能在两拍之间被销毁：这不是异常，是"晚到的输入打空"。
    if (node === undefined) return;
    const c = node.get<PlayerController>(CONTROLLER_TYPE);
    if (c === undefined) return;
    const r = dirStep(intent, c.speed, dt);
    if (r.dx === 0 && r.dz === 0) return;
    node.setLocalPosition(node.localPosition.x + r.dx, node.localPosition.y + r.dz);
  }

  // ---------------------------------------------------------------- 发

  private sendIntent(cmd: LocalCommand, tick: number): void {
    const msg: IntentMessage = {
      kind: "intent",
      from: this.transport.self,
      tick,
      // ★ seq 在"准备发"时消耗，不管对面收不收得到 —— 否则丢包就不会留下缺口，
      //   而这正是接收方唯一能发现丢包的证据。
      seq: this.outSeq++,
      entity: cmd.entity,
      intent: cmd.intent,
    };
    if (this.transport.send(msg)) this.intentsSent++;
  }

  /**
   * 广播：全量（关键帧）或增量。
   *
   * ★ `seq` 在**准备发**时消耗，不管对面收不收得到（与 `sendIntent` 同一条规矩）：
   *   否则丢包就不会留下缺口，而缺口是接收方唯一能发现丢包的证据。
   * ★ 但 `sentSnap` / `sentSeq` **只在传出去了之后**才前移：它们是「对面手上有什么」，
   *   而不是「我算出了什么」。见文件头 ①。
   */
  private broadcast(tick: number): void {
    const now = snapshotOfScene(this.scene);
    const seq = this.outSeq++;
    const base = this.sentSnap;
    const keyframe = base === null || this.forceFull || this.sinceKeyframe + 1 >= this.keyframeEvery;
    const json = keyframe ? sceneToJson(now) : deltaToJson(diffSnapshot(base, now));
    const msg: SnapshotMessage | SnapshotDeltaMessage = keyframe
      ? { kind: "snapshot", from: this.transport.self, tick, seq, json }
      : { kind: "snapshot-delta", from: this.transport.self, tick, seq, base: this.sentSeq, json };
    if (!this.transport.send(msg)) return;
    this.snapshotsSent++;
    this.snapshotCharsSent += json.length;
    if (keyframe) {
      this.keyframesSent++;
      this.sinceKeyframe = 0;
      this.forceFull = false;
    } else {
      this.deltasSent++;
      this.sinceKeyframe++;
    }
    this.sentSnap = now;
    this.sentSeq = seq;
  }
}

export function createSession(opts: SessionOptions): NetSession {
  return new Session(opts);
}

/**
 * 装配：把会话挂到调度器上（`GameApp` 的四件套里已有 `scene` / `components` / `scheduler`）。
 *
 * ★ 为什么挂在 `scheduler.onStep` 而不是自己开一个定时器：一拍一步是引擎里唯一的
 *   时间真相（见 `core/scheduler` 的文件头）。自建定时器会让网络拍与逻辑拍错开，
 *   而错开之后"第几拍看到什么"这条判据就再也写不出来。
 *
 * 返回的 `off()` 只退订，不关传输：传输的生死归建它的那方（环回是两端共用一条线）。
 */
export interface SessionHost {
  readonly scene: Scene;
  readonly components: ComponentRegistry;
  readonly scheduler: { onStep(fn: (tick: number, dt: number) => void): () => void };
}

export function attachSession(host: SessionHost, opts: Omit<SessionOptions, "scene" | "registry">): {
  readonly session: NetSession;
  readonly off: () => void;
} {
  const session = createSession({ ...opts, scene: host.scene, registry: host.components });
  const off = host.scheduler.onStep((tick, dt) => {
    session.step(tick, dt);
  });
  return { session, off };
}

/** 权威常量再导出一次，避免调用方为了一个 -1 去 import 两个文件。 */
export { AUTHORITY };
