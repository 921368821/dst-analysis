/**
 * L4 · 传输（Transport）：把「消息怎么到对面」与「到了之后谁算」切开
 *
 * ★★ 这一层的边界只有一句话：**只管投递，不管权威**。
 *
 *   谁算这个世界（主机 / 专用服 / 单机自己）、算完怎么回传，都属于上层（主机权威、
 *   预测回滚）的事；传输只知道三件事：这条消息属于哪一拍、发件人是谁、它什么时候
 *   可以交给收件人。这条边界一旦破了（比如「发送时顺手把消息应用到本地世界」），
 *   环回、WebSocket、Steam 数据报就再也不能互换 —— 因为它们对「何时算送到」的定义不同，
 *   而本地世界被改动的那一刻已经把语义写死了。
 *
 * ★★ 为什么第一版是「环回（loopback）」而不是「先写个 WebSocket 客户端类」
 *
 *   联机要验的东西里，绝大多数**不需要两台机器**：
 *   · 同一串输入，第二台机器算出来的世界与第一台逐字节一致吗？
 *   · 晚到三拍的消息，追平之后结果还一样吗？
 *   · 丢了一条，接收方能不能发现（而不是把后面的当成前面那条）？
 *   这三条在环回上完全可测 —— 只要环回**能配延迟和丢包**。反过来，先把 WebSocket
 *   写出来，这三条就要靠"两台机器 + 人眼看"，也就等于不测（本项目对"看起来在用"的
 *   判据标准见 `docs/PROGRESS.md` 里反复出现的假绿案例）。
 *
 * ★ 三个刻意的约束：
 *
 * ① **按 tick 取，不回调**：`receive(tick)` 而不是 `onMessage(cb)`。回调会把消息的
 *    投递时刻绑到真实时间（毫秒）上，而联机的正确性判据全部是「第几拍能看到什么」。
 *    按 tick 取让「网络」与「仿真」两个时钟解耦，判据也不必等真实毫秒 —— 一条判据
 *    跑 20 拍就是 0 毫秒，而不是 sleep 20 × 33ms。
 *
 * ② **消息是可序列化的纯数据**：意图本身就是纯数据（见 `motion/intent.ts`），快照用
 *    JSON 字符串而不是对象 —— 两端不必共享内存结构，也就不会出现"本地跑得通、过网就错"。
 *
 * ③ **丢包记在发送方**：接收方永远不知道该来的是什么（这正是要 `seq` 的原因）。
 *    把丢包记在接收方等于假装它知道，而"以为自己知道"正是这类 bug 的起点。
 *
 * ④ **`receive` 可以按消息种类取，取走的不再重复**（`kinds` 参数）。
 *    联机不是"一个消费者读一条线"：加入握手读 `join` / `join-reply`，会话读
 *    `intent` / `snapshot`。没有这个参数时，先跑的那个会把另一类消息**吃掉**
 *    （会话把它当协议违规计一笔，握手永远等不到回复），而症状是「客户端连不上，
 *    主机日志说有人发了不该发的消息」。过滤是"不匹配的留在队列里"，
 *    不是"不匹配的丢掉"—— 后者只是把"吃消息"换了个地方发生。
 *    代价：**先取握手、后取会话**这个顺序成了调用方的责任（`net/join.ts` 文件头）。
 */

import { XorShift128, type IRandom } from "../../foundation/random.ts";
import type { NodeId } from "../../core/scene/node.ts";
import type { MoveIntent } from "../motion/intent.ts";
import type { JoinReply, JoinRequest } from "./join.ts";

/** 对端标识。环回里只有 0 与 1；真实的会话层可以把它映射成连接号。 */
export type PeerId = number;

/** 所有消息共有的信封字段。 */
export interface NetEnvelope {
  readonly from: PeerId;
  /**
   * 发送方产生这条消息的逻辑步。
   *
   * ★ 它同时是投递时刻的基准（到达时刻 = 本字段 + 延迟），所以**消息只能在它所属的
   *   那一拍产生**。想让一条消息"晚两拍再发"是另一件事（本地排队），不是改这个字段 ——
   *   改了它，接收方就再也分不清"这条是早发的还是晚到的"。
   */
  readonly tick: number;
  /**
   * 同一发送方单调递增的序号。
   *
   * ★ 存在的唯一理由是**让丢包可发现**：接收方拿不到"应该有几条"，只看得到现有的
   *   序号。序号出现缺口 = 中间丢了，后面那条不能顶替前面那条。
   */
  readonly seq: number;
}

/** 客户端 → 主机：这个实体这一拍想干什么。 */
export interface IntentMessage extends NetEnvelope {
  readonly kind: "intent";
  /**
   * 这条意图要给**哪个**实体。
   *
   * ★ 必须点名，不能靠"发件人反查它拥有谁"：一个对端拥有几个实体（分屏、观战、
   *   交接间隙）从第一次改动起就会发生，而"默认第一个"这种约定在第二次改动时
   *   就会变成不可解释的行为。点名之后，主机那边只有一道检查 ——
   *   `owner(entity) === from`（见 `session.ts` 的 `admit`）。
   */
  readonly entity: NodeId;
  readonly intent: MoveIntent;
}

/** 主机 → 客户端：这一拍的世界长什么样（`sceneToJson(saveScene(scene))`）。 */
export interface SnapshotMessage extends NetEnvelope {
  readonly kind: "snapshot";
  readonly json: string;
}

/**
 * 一条能过网的消息。
 *
 * ★ 四种里只有两种属于会话层（`intent` / `snapshot`），另两种属于加入握手
 *   （`join` / `join-reply`，见 `net/join.ts`）。合在一个联合里不是图省事：它们
 *   共用同一条线、同一套信封、同一个 `seq` 缺口诊断 —— 分开定义就会出现第二份
 *   「怎么算送到」。
 */
export type NetMessage = IntentMessage | SnapshotMessage | JoinRequest | JoinReply;

/** 诊断计数（面板与判据读这一份，避免各算一套）。 */
export interface TransportStats {
  /** 本端成功交出去的条数（不含被丢的）。 */
  readonly sent: number;
  /** 本端取走的条数。 */
  readonly received: number;
  /** 本端发出时被丢的条数（含关闭后继续发的）。 */
  readonly dropped: number;
  /** 还在路上、按当前 tick 还取不到的条数。 */
  readonly queued: number;
}

export interface Transport {
  readonly self: PeerId;
  /**
   * 交给传输层。**不在本地应用**，也不等待对面确认。
   *
   * 返回 `false` 表示本端当场就知道它被丢了（环回的丢包模型就是这样）。
   * 真实传输可能永远返回 `true` —— 所以**不要**用它判断"对面收到了"，
   * 那只能靠 `seq` 的缺口。
   */
  send(msg: NetMessage): boolean;
  /**
   * 取出所有「到达时刻 ≤ tick」的消息，按发送顺序；取走的不再重复。
   *
   * ★ 给了 `kinds` 时只取这些种类，**其余留在队列里**（下一个消费者还能取到）。
   *   这不是「顺手做的优化」：会话与握手是两个消费者，吃掉对方的消息会让
   *   "客户端连不上"与"有人发了不该发的消息"同时出现，而两者都不指向真正的原因。
   */
  receive(tick: number, kinds?: readonly NetMessage["kind"][]): readonly NetMessage[];
  stats(): TransportStats;
  /** 关闭：清空在途队列，之后的 `send` 一律返回 `false`。幂等。 */
  dispose(): void;
}

export interface LoopbackOptions {
  /** 固定延迟（逻辑步）。0 = 同一拍就能收到。缺省 0。 */
  readonly delayTicks?: number;
  /** 丢包概率 [0, 1]。缺省 0。 */
  readonly lossRate?: number;
  /** 丢包用的种子。**同种子 ⇒ 同一串丢包**（判据要能复现，而不是"重跑一次看看"）。 */
  readonly seed?: number;
}

interface Pending {
  readonly at: number;
  readonly msg: NetMessage;
}

interface Counters {
  sent: number;
  received: number;
  dropped: number;
}

/**
 * 环回的"线"：两端共用一条，持有延迟 / 丢包 / 两个方向的队列。
 *
 * ★ 只有一条随机流（不是每端一条）：这样"种子相同 ⇒ 整场实验相同"，
 *   而不用额外规定"哪一端的随机流先走"。
 */
class LoopbackWire {
  private readonly delay: number;
  private readonly loss: number;
  private readonly rng: IRandom;
  private readonly queues = new Map<PeerId, Pending[]>();
  private readonly counters = new Map<PeerId, Counters>();
  private open = true;

  constructor(opts: LoopbackOptions) {
    this.delay = opts.delayTicks ?? 0;
    this.loss = opts.lossRate ?? 0;
    this.rng = new XorShift128(opts.seed ?? 1);
    for (const p of [0, 1] as const) {
      this.queues.set(p, []);
      this.counters.set(p, { sent: 0, received: 0, dropped: 0 });
    }
  }

  enqueue(from: PeerId, msg: NetMessage): boolean {
    const mine = this.counter(from);
    if (!this.open) {
      mine.dropped++;
      return false;
    }
    // ★ 丢包只影响「这条还在不在」，**不影响顺序**：后面那条不会被提前，
    //   也不会顶替前面那条的位次（接收方靠 seq 缺口看出来）。
    if (this.loss > 0 && this.rng.chance(this.loss)) {
      mine.dropped++;
      return false;
    }
    // 环回只有两端：发给对端。多端路由属于会话层，不在这里假装支持。
    const to: PeerId = from === 0 ? 1 : 0;
    this.queue(to).push({ at: msg.tick + this.delay, msg });
    mine.sent++;
    return true;
  }

  drain(to: PeerId, tick: number, kinds?: readonly NetMessage["kind"][]): NetMessage[] {
    const q = this.queue(to);
    const out: NetMessage[] = [];
    let kept = 0;
    for (const p of q) {
      // ★ `<=` 而不是 `<`：延迟 0 的语义就是"同一拍能收到"。写成 `<` 时
      //   环回会永远慢一拍，而所有"终态一致"的判据照样绿（只是晚一点）。
      //
      // ★ 种类不匹配时**留在队里**（走 else 分支）：它不是「没到」，是「还没轮到
      //   它的消费者」。丢掉它等于让另一个消费者永远等不到。
      if (p.at <= tick && (kinds === undefined || kinds.includes(p.msg.kind))) out.push(p.msg);
      else q[kept++] = p;
    }
    q.length = kept;
    this.counter(to).received += out.length;
    return out;
  }

  statsOf(peer: PeerId): TransportStats {
    const c = this.counter(peer);
    return {
      sent: c.sent,
      received: c.received,
      dropped: c.dropped,
      queued: this.queue(peer).length,
    };
  }

  close(): void {
    this.open = false;
    for (const q of this.queues.values()) q.length = 0;
  }

  private counter(peer: PeerId): Counters {
    const c = this.counters.get(peer);
    if (c === undefined) throw new RangeError(`环回里没有 peer ${String(peer)}`);
    return c;
  }

  private queue(peer: PeerId): Pending[] {
    const q = this.queues.get(peer);
    if (q === undefined) throw new RangeError(`环回里没有 peer ${String(peer)}`);
    return q;
  }
}

class LoopbackEnd implements Transport {
  constructor(
    readonly self: PeerId,
    private readonly wire: LoopbackWire,
  ) {}

  send(msg: NetMessage): boolean {
    // ★★ 信封里的 `from` 由**端点在发送时盖章**，不采信调用方写进去的那个。
    //   理由与真实套接字一致：源地址由栈填，不由报文自称。少了这一次覆盖，
    //   一个客户端只要在消息里写 `from: 0` 就能冒充主机，而基于 `from` 的
    //   授权检查（`owner === from`）会全部放行 —— 且任何"世界一致"的判据都绿。
    //   用断言而不是逐字段重建：`NetMessage` 是判别联合，展开后判别字段在
    //   运行期原样保留，但类型上需要一次收窄，写两个分支只是把同一个字写两遍。
    return this.wire.enqueue(this.self, { ...msg, from: this.self } as NetMessage);
  }

  receive(tick: number, kinds?: readonly NetMessage["kind"][]): readonly NetMessage[] {
    return this.wire.drain(this.self, tick, kinds);
  }

  stats(): TransportStats {
    return this.wire.statsOf(this.self);
  }

  dispose(): void {
    this.wire.close();
  }
}

/**
 * 建一对环回端点：`[0 号, 1 号]`。任一端 `dispose()` 会关掉整条线（两端同生共死）。
 *
 * ★ 配置非法时**当场抛**，不做降级：这些是开发者参数，静默降级会变成
 *   "我明明设了 200ms 延迟，判据却在同一拍收到"—— 而这种错查起来极贵。
 *   运行期的数据（意图里的 NaN）才降级，见 `motion/intent.ts` 的约定。
 */
export function createLoopbackPair(opts: LoopbackOptions = {}): readonly [Transport, Transport] {
  const delay = opts.delayTicks ?? 0;
  if (!Number.isInteger(delay) || delay < 0) {
    throw new RangeError(`delayTicks 必须是非负整数，收到 ${String(delay)}`);
  }
  const loss = opts.lossRate ?? 0;
  if (!Number.isFinite(loss) || loss < 0 || loss > 1) {
    throw new RangeError(`lossRate 必须在 [0, 1]，收到 ${String(loss)}`);
  }
  const wire = new LoopbackWire({ delayTicks: delay, lossRate: loss, seed: opts.seed ?? 1 });
  return [new LoopbackEnd(0, wire), new LoopbackEnd(1, wire)];
}
