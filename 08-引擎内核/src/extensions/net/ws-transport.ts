/**
 * L4 · 传输：WebSocket（跨机器）与它的可注入替身
 *
 * ★★ 它和 `broadcast-transport.ts` 的关系：**同一层接口的第二个实现**，不是替代品
 *
 *   `BroadcastChannel` 只在同一台机器的同一个浏览器进程内成立。跨机器需要一条真链路，
 *   而 `Transport` 这个接口从第一天就是为了"两条链路可以互换"设计的
 *   （`session` / `predict` / `join` 里没有任何一处认识 `BroadcastChannel`）。
 *   所以这一批的改动**只发生在传输层 + 网关 + 接线**，会话、预测、握手、插值一行没动。
 *
 * ★★ 三个与环回 / BroadcastChannel 都不一样的约束
 *
 *   ① **`self` 是运行期才知道的**（网关分配）。环回里两端是构造参数，跨标签页里是
 *      URL 参数（host = 0 / client = 1），**两者都是"我自称我是谁"**。跨机器时这条
 *      路径必须断掉：端点号由网关在连接建立时给出（`hello`），客户端在它到达之前
 *      不知道自己几号。`Transport.self` 因此是一个 getter，初值 `UNASSIGNED = -1`。
 *
 *      这一条不是洁癖：`join.ts` 的 `Joiner.reply()` 里有 `msg.to !== this.selfPeer`
 *      这道检查，`selfPeer` 错了就会把**每一份**合法的加入回复当成"不是给我的"丢掉。
 *      症状是"客户端连上了、网关日志说转发了、主机日志说分配了座位，但客户端上
 *      什么也没有" —— 三层日志全都正常。
 *
 *   ② **`from` 由网关盖章，客户端写什么都不算**。环回里由端点在 `send` 时覆盖
 *      （`transport.ts` 的 `LoopbackEnd.send`），跨标签页里由通道语义保证不同源自收。
 *      跨机器时唯一可信的"这条消息从哪来"是**连接本身**，所以网关在转发前把
 *      `from` 重写成它分配的那个号。少了这一步，一个客户端在消息里写 `from: 0`
 *      就能冒充主机，而基于 `from` 的授权检查（`owner === from`）会全部放行 ——
 *      且任何"世界一致"的判据都照样绿（两边算的是同一份世界，只是驱动它的是坏人）。
 *
 *   ③ **连接会断，而且断在这里是常态**（关页面、切 Wi-Fi、待机）。环回与
 *      BroadcastChannel 都没有"对面不在了"这个概念。网关把断开转成 `peer-left`，
 *      这里消化掉、交给宿主（`room.drop`）—— 与 `hello` 一样**不进 `NetMessage`**：
 *      它们是这条链路自己的控制面，不属于"世界"的协议，混进去会让
 *      `KNOWN_KINDS` 多两个只有一条链路认识的值。
 *
 * ★ 到达时刻的定义与 `broadcast-transport.ts` **逐字一致**：「上一次 `receive()` 的
 *   tick」。两条链路对"第几拍能看到什么"给同一个答案，判据才能跨链路复用。
 *   反过来（WebSocket 用真实时间戳）会让同一份世界在两条链路上跑出不同结果，
 *   而那正是"本地能玩、上线就崩"的来源。
 */

import {
  isKnownKind,
  isNetMessage,
  type NetMessage,
  type PeerId,
  type Transport,
  type TransportStats,
} from "./transport.ts";

/**
 * 还没拿到端点号。
 *
 * ★ 用一个负数而不是 0：0 是**主机的座位号**，也是一个合法端点号。用 0 占位会让
 *   "还没连上"与"我是主机"在 `playerOf()` 里得到同一个答案（`null`），
 *   而那是两件事——前者会自愈，后者永远不会。
 */
export const UNASSIGNED: PeerId = -1;

/** 网关说的"你是谁"。 */
export interface PeerHello {
  readonly peer: PeerId;
  readonly role: "host" | "client";
}

/**
 * `WebSocket` 里我们用到的那几样。
 *
 * ★ 不用 `instanceof WebSocket`：Node 与浏览器各有一个，小游戏里没有，
 *   而判据里的替身也不该为了过 `instanceof` 去继承它（`broadcast-transport.ts`
 *   对 `BroadcastChannel` 是同一条规矩）。
 */
export interface SocketLike {
  send(data: string): void;
  close(code?: number, reason?: string): void;
  onopen: ((ev: unknown) => void) | null;
  onmessage: ((ev: { readonly data: unknown }) => void) | null;
  onclose: ((ev: unknown) => void) | null;
  onerror?: ((ev: unknown) => void) | null;
  /** `WebSocket.OPEN === 1`。判据里的替身可以不给。 */
  readonly readyState?: number;
}

export interface WsTransportOptions {
  readonly socket: SocketLike;
  /**
   * 已连接（构造时 socket 就是 OPEN 的）。
   *
   * ★ 只在判据里会出现：真实浏览器里 `new WebSocket(...)` 之后要等 `open` 事件。
   *   不给时按 `readyState === 1` 判断 —— 这条兜底让"替身忘了发 open"不至于
   *   变成"所有消息都发不出去而计数说没发过"。
   */
  readonly opened?: boolean;
}

export interface WsTransport extends Transport {
  /** 网关给的端点号，`hello` 之前是 `null`。 */
  readonly hello: PeerHello | null;
  /** 连接已建立（`open` 事件到达）。与 `hello` 无关：门开了才轮得到握手。 */
  readonly ready: boolean;
  /** 收到了、但 JSON 都读不回来的条数。 */
  readonly malformed: number;
  /** 收到了、`kind` 不认识（对面是**另一个版本**）的条数。 */
  readonly unknownKinds: number;
  /** 连接还没建立就试图发送的条数。 */
  readonly sendBeforeOpen: number;
  /** 连接已经关掉之后试图发送的条数。 */
  readonly sendAfterClose: number;
  /** 谁先关的。`null` = 还开着。 */
  readonly closedBy: "self" | "peer" | null;
  /**
   * `hello` 到达时调一次。
   *
   * ★ 如果注册时 `hello` 已经在手（网关回得比宿主注册还快），**立刻同步调一次**。
   *   不这么做的话，那个回调永远不会被调用，而症状是"端点号一直是 -1，
   *   但 `hello` 明明收到了" —— 一次时序竞争换来一整晚的排查。
   * 返回退订函数。
   */
  onHello(cb: (h: PeerHello) => void): () => void;
  /** 某个端点断了（网关转发）。返回退订函数。 */
  onPeerLeft(cb: (peer: PeerId, reason: string) => void): () => void;
}

/** 网关 → 客户端。**只在这条链路上存在**，不进 `NetMessage`（见文件头 ③）。 */
interface HelloWire {
  readonly kind: "hello";
  readonly peer: PeerId;
  readonly role: "host" | "client";
}

interface PeerLeftWire {
  readonly kind: "peer-left";
  readonly peer: PeerId;
  readonly reason: string;
}

function isHello(v: unknown): v is HelloWire {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  return o["kind"] === "hello" && typeof o["peer"] === "number";
}

function isPeerLeft(v: unknown): v is PeerLeftWire {
  if (typeof v !== "object" || v === null) return false;
  const o = v as Record<string, unknown>;
  return o["kind"] === "peer-left" && typeof o["peer"] === "number";
}

interface Arrived {
  readonly at: number;
  readonly msg: NetMessage;
}

export function createWsTransport(opts: WsTransportOptions): WsTransport {
  const { socket } = opts;
  const inbox: Arrived[] = [];
  /**
   * 到达时刻的基准 = **上一次 `receive()` 的 tick**（与 `broadcast-transport.ts` 逐字一致）。
   */
  let now = 0;
  let opened = opts.opened ?? socket.readyState === 1;
  let closed: "self" | "peer" | null = null;
  /** `hello` 之前是 `UNASSIGNED`。**不是 0**（见 `UNASSIGNED` 的注释）。 */
  let self: PeerId = UNASSIGNED;
  let hello: PeerHello | null = null;

  const counters = { sent: 0, received: 0, dropped: 0 };
  let malformed = 0;
  let unknownKinds = 0;
  let sendBeforeOpen = 0;
  let sendAfterClose = 0;

  const helloCbs: ((h: PeerHello) => void)[] = [];
  const leftCbs: ((peer: PeerId, reason: string) => void)[] = [];

  socket.onopen = (): void => {
    opened = true;
  };

  socket.onmessage = (ev: { readonly data: unknown }): void => {
    if (closed !== null) return;
    // ★ 浏览器给的是 string（`binaryType` 缺省时会先把 Blob 读成字符串，但我们只用文本帧）。
    //   非字符串一律按"这条链路上有别的东西"记 `malformed`，与 broadcast 的
    //   "形状不对"同一处置、同一个计数 —— 面板上两条链路的诊断列可直接对比。
    const raw = typeof ev.data === "string" ? ev.data : null;
    if (raw === null) {
      counters.dropped++;
      malformed++;
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      counters.dropped++;
      malformed++;
      return;
    }

    // ---- 控制面（这条链路自己的，先消化，不进 inbox）
    if (isHello(parsed)) {
      hello = { peer: parsed.peer, role: parsed.role === "host" ? "host" : "client" };
      self = parsed.peer;
      for (const cb of helloCbs.slice()) cb(hello);
      return;
    }
    if (isPeerLeft(parsed)) {
      const reason = typeof parsed.reason === "string" ? parsed.reason : "";
      for (const cb of leftCbs.slice()) cb(parsed.peer, reason);
      return;
    }

    // ---- 数据面
    if (!isNetMessage(parsed)) {
      counters.dropped++;
      malformed++;
      return;
    }
    if (!isKnownKind(parsed.kind)) {
      counters.dropped++;
      unknownKinds++;
      return;
    }
    inbox.push({ at: now, msg: parsed });
    counters.received++;
  };

  socket.onclose = (): void => {
    // ★ 对端关的：清空在途消息（它们再也取不到了），但**不**把 `closed` 从 `self` 覆盖掉
    //   —— "我先关的"与"对面关的"在诊断上是两件事（前者是我主动退出，后者是掉线）。
    if (closed === null) closed = "peer";
    inbox.length = 0;
  };

  const transport: WsTransport = {
    // ★ getter 而不是快照：`hello` 之前是 `UNASSIGNED`，之后是网关给的号。
    //   所有调用点（`session.sendIntent` 的信封、`Joiner.request` 的 `from`、
    //   `net-assembly` 的 `room.playerOf(transport.self)`）都**每拍现读**，
    //   所以这里一动，它们全部跟着动 —— 不需要任何"刷新"回调。
    get self(): PeerId {
      return self;
    },
    get hello(): PeerHello | null {
      return hello;
    },
    get ready(): boolean {
      return opened && closed === null;
    },
    get closedBy(): "self" | "peer" | null {
      return closed;
    },

    send(msg: NetMessage): boolean {
      if (closed !== null) {
        // ★ 与 broadcast 同一条规矩：关闭之后**返回 false 而不是抛**。
        //   上层用它决定"发不出去就别预测"，抛出去会让一帧的收尾逻辑整段跳过。
        sendAfterClose++;
        counters.dropped++;
        return false;
      }
      if (!opened) {
        // ★ "还没连上"与"连接断了"分开数：前者是启动时序（几十毫秒，正常），
        //   后者是故障。合成一个 `dropped` 会让"每局开头都有 3 条被丢"看起来像丢包。
        sendBeforeOpen++;
        counters.dropped++;
        return false;
      }
      let text: string;
      try {
        text = JSON.stringify(msg);
      } catch {
        // 消息里混进了循环引用 / BigInt —— 这是**我们的** bug，但对上层仍然是"没发出去"。
        counters.dropped++;
        return false;
      }
      try {
        socket.send(text);
      } catch {
        // 关闭中（`readyState` 已经是 CLOSING/CLOSED，但 `close` 事件还没到）会抛。
        // 这时候连接实际上已经没了，按对端关闭处理是诚实的。
        closed = "peer";
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
      // ★ 四个数的口径与环回 / broadcast **完全一致**（同一张表）。切换链路时
      //   "丢包率"要可比，否则那个数就没有意义。
      return {
        sent: counters.sent,
        received: counters.received,
        dropped: counters.dropped,
        queued: inbox.length,
      };
    },

    dispose(): void {
      if (closed !== null) {
        // ★ 幂等，但**别覆盖 `closedBy`**：先 `dispose()` 之后 `onclose` 会再进来一次，
        //   把 "peer" 改成 "self" 会让"对面先断的"这条诊断信息消失。
        inbox.length = 0;
        return;
      }
      closed = "self";
      socket.onmessage = null;
      socket.onopen = null;
      socket.onclose = null;
      inbox.length = 0;
      try {
        socket.close();
      } catch {
        // 替身的 close 可能什么都不做；真 WebSocket 关两次也不抛。这里不关心。
      }
    },

    get malformed(): number {
      return malformed;
    },
    get unknownKinds(): number {
      return unknownKinds;
    },
    get sendBeforeOpen(): number {
      return sendBeforeOpen;
    },
    get sendAfterClose(): number {
      return sendAfterClose;
    },

    onHello(cb: (h: PeerHello) => void): () => void {
      helloCbs.push(cb);
      // ★ 已经收到了就立刻补一次：见接口上的注释（一次时序竞争换一晚排查）。
      const h = hello;
      if (h !== null) cb(h);
      return () => {
        const i = helloCbs.indexOf(cb);
        if (i >= 0) helloCbs.splice(i, 1);
      };
    },

    onPeerLeft(cb: (peer: PeerId, reason: string) => void): () => void {
      leftCbs.push(cb);
      return () => {
        const i = leftCbs.indexOf(cb);
        if (i >= 0) leftCbs.splice(i, 1);
      };
    },
  };

  return transport;
}
