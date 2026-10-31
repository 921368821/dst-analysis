/**
 * L4 · 传输：`BroadcastChannel`（同源多标签页）与它的可注入替身
 *
 * ★★ 为什么是 BroadcastChannel，而不是先写一个 WebSocket 服务器
 *
 *   这一批要回答的问题不是「运营服怎么搭」，而是「**两个页面能不能一起玩**」。
 *   后者需要一条真链路，但不需要一台服务器：`BroadcastChannel` 是浏览器原生的
 *   同源广播，两个标签页各开一个同名 channel 就行。于是：
 *   · 不用起进程、不用端口、不用证书；
 *   · `?net=host` 与 `?net=client` 各开一个标签页，就是一场真对局；
 *   · 测完把标签页关掉，没有任何东西留在系统里。
 *
 *   代价要写清：**它只在同一台机器、同一个浏览器进程内**成立。跨机器仍然要
 *   Steamworks（datagram）或 WebSocket —— 而那一天的改动只发生在**这里**，
 *   因为上层（`session` / `predict` / `join`）只认 `Transport` 这个接口。
 *
 * ★★ 它与环回（`transport.ts` 的 loopback）的三个差别 —— 每一条都会改变两端行为
 *
 *   ① **消息是异步到达的**。环回知道「这条在第 N 拍送到」，BroadcastChannel 不知道：
 *      收到的那一刻，本端正在跑第几拍是实现细节。所以这里给到达时刻的定义是
 *      「**上一次 `receive()` 的 tick**」，语义是「这一拍之后收到的，下一拍才可见」。
 *      这比"假装它按时到了"诚实：假装会让客户端在收到快照的**同一拍**就用它，
 *      而真实网络里那一刻它还在一段 JSON 里。
 *
 *   ② **消息要过结构化克隆**。`NetMessage` 全是纯数据（快照本身就是 JSON 字符串），
 *      所以这条路今天不会抛。但克隆是**不报错地丢东西**的（`Map`/`Node`/函数会被
 *      换成 `{}` 或直接 `DataCloneError`），所以收到的东西要**过一遍形状校验**，
 *      不能 `as NetMessage` 了事 —— 一个空对象会让会话层按"未知种类"静默丢弃，
 *      而症状是「客户端一直连不上，日志里什么都没有」。校验不过的记进 `malformed`
 *      （与 `unknownKinds` **分开**数，理由见那个字段的注释）。
 *
 *   ③ **自己发的自己收不到**（BroadcastChannel 的语义）。这正是两端模型要的：
 *      环回里"发给对端"是显式算出来的，这里由通道保证。
 *
 * ★ 依赖注入而不是直接 `new BroadcastChannel`：判据要在 Node 里跑同一条代码路径，
 *   而"用真 BroadcastChannel 跑判据"会引入异步投递与真实时间（一条 20 拍的判据
 *   要等 20 次事件循环）。`ChannelLike` 只要求三样东西，内存总线三行就能实现。
 */

import type { NetMessage, PeerId, Transport, TransportStats } from "./transport.ts";

/**
 * `BroadcastChannel` 里我们用到的那三样。
 *
 * ★ 不用 `instanceof BroadcastChannel` 判类型：小游戏里没有这个全局，
 *   而判据里的替身也不应该为了过 `instanceof` 去继承它。
 */
export interface ChannelLike {
  postMessage(data: unknown): void;
  close(): void;
  /** 与 `BroadcastChannel` 同形：赋值一个处理器，`null` 表示不接。 */
  onmessage: ((ev: { readonly data: unknown }) => void) | null;
  /** 只用于诊断（`stats` 里报哪条通道）。缺省当作 `""`。 */
  readonly name?: string;
}

/** 已知的消息种类。收到表外的 `kind` 一律丢弃并计入 `unknownKinds`。 */
const KNOWN_KINDS: ReadonlySet<string> = new Set([
  "intent",
  "snapshot",
  "snapshot-delta",
  "resync",
  "join",
  "join-reply",
]);

export interface BroadcastTransportOptions {
  readonly channel: ChannelLike;
  /** 本端标识。**由宿主的 URL 参数决定**（host = 0 / client = 1）。 */
  readonly self: PeerId;
}

export interface BroadcastTransport extends Transport {
  /**
   * 收到的、`kind` 不认识的消息条数。
   *
   * ★ 为什么单独计数而不是静默丢：跨标签页时"对面发了个我这版没有的消息"
   *   是**版本不一致**的唯一线索。丢掉它不报警，症状就是「两个页面各玩各的」。
   */
  readonly unknownKinds: number;
  /**
   * 收到了，但**连消息的形状都不对**（不是对象、或缺 `kind`/`tick`/`seq`）的条数。
   *
   * ★★ 为什么与 `unknownKinds` 分开：两者的成因不同、处置也不同。
   *   · `unknownKinds` = 对面是**另一个版本**（该提示"两边版本不一致"）；
   *   · `malformed` = 消息在这条链路上被打坏了（结构化克隆丢了字段，或者别的东西
   *     也在这个通道名上广播）。
   *   合在一起数的话，`{"chrome.extension": …}` 这类无关广播会把"版本不一致"
   *   这条唯一线索淹掉 —— 诊断信号的**纯度**比票数重要。
   */
  readonly malformed: number;
  /** 因为通道已关闭而没发出去的条数。 */
  readonly sendAfterClose: number;
}

interface Arrived {
  readonly at: number;
  readonly msg: NetMessage;
}

/** 形状校验：只认「有 kind、有 tick、有 seq」的对象。 */
function isNetMessage(v: unknown): v is NetMessage {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  return typeof o["kind"] === "string" && typeof o["tick"] === "number" && typeof o["seq"] === "number";
}

export function createBroadcastTransport(opts: BroadcastTransportOptions): BroadcastTransport {
  const { channel, self } = opts;
  const inbox: Arrived[] = [];
  let now = 0;
  let closed = false;
  const counters = { sent: 0, received: 0, dropped: 0 };
  let unknownKinds = 0;
  let malformed = 0;
  let sendAfterClose = 0;

  channel.onmessage = (ev: { readonly data: unknown }): void => {
    if (closed) return;
    const data = ev.data;
    if (!isNetMessage(data)) {
      // ★ 与「未知种类」分开数（见 `malformed` 的注释）：这一条是"链路/通道名被别的东西
      //   污染了"，而未知种类是"对面版本不同"。合起来数会让后者失去意义。
      counters.dropped++;
      malformed++;
      return;
    }
    if (!KNOWN_KINDS.has(data.kind)) {
      counters.dropped++;
      unknownKinds++;
      return;
    }
    // ★ 到达时刻 = **上一次 receive 的 tick**（文件头 ①）。首次 receive 之前
    //   收到的东西记在 0 拍 —— 它会在第一拍就被取走，这与"页面刚起来对面就发了"吻合。
    inbox.push({ at: now, msg: data });
    counters.received++;
  };

  const transport: BroadcastTransport = {
    self,
    send(msg: NetMessage): boolean {
      if (closed) {
        // ★ 关闭之后仍然要**返回 false**（而不是抛）：上层用它决定"发不出去就别预测"，
        //   抛出去会让一帧的收尾逻辑整段跳过。
        sendAfterClose++;
        counters.dropped++;
        return false;
      }
      try {
        channel.postMessage(msg);
      } catch {
        // 结构化克隆失败（消息里混进了不可克隆的东西）—— 这是**我们的** bug，
        // 但对上层来说仍然是"这条没发出去"，所以按丢包记账，不抛。
        counters.dropped++;
        return false;
      }
      counters.sent++;
      return true;
    },

    receive(tick: number, kinds?: readonly NetMessage["kind"][]): readonly NetMessage[] {
      if (tick > now) now = tick;
      const out: NetMessage[] = [];
      let kept = 0;
      for (const a of inbox) {
        if (a.at <= tick && (kinds === undefined || kinds.includes(a.msg.kind))) out.push(a.msg);
        else inbox[kept++] = a;
      }
      inbox.length = kept;
      return out;
    },

    stats(): TransportStats {
      // ★ `sent` / `received` / `dropped` / `queued` 四个数的口径与环回完全一致（同一张表），
      //   否则面板上"丢包率"在两个传输之间不可比 —— 而那正是切换链路时唯一想看的数。
      return {
        sent: counters.sent,
        received: counters.received,
        dropped: counters.dropped,
        // 到了但还没被取走的：真实链路上它就是"在途"，与环回的 `queued` 同义。
        queued: inbox.length,
      };
    },

    dispose(): void {
      if (closed) return;
      closed = true;
      channel.onmessage = null;
      inbox.length = 0;
      try {
        channel.close();
      } catch {
        // 替身的 close 可能什么都不做；真 BC 关两次也不抛。这里不关心。
      }
    },

    get unknownKinds(): number {
      return unknownKinds;
    },
    get malformed(): number {
      return malformed;
    },
    get sendAfterClose(): number {
      return sendAfterClose;
    },
  };

  return transport;
}
