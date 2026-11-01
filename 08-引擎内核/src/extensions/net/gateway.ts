/**
 * 联机网关：把 N 条 WebSocket 接成「一个主机 + 若干客户端」
 *
 * ★★ 它做的三件事，每一件都是**只有中心节点能做**的
 *
 *   ① **分配端点号**。跨机器时客户端不可能知道自己几号（环回里是构造参数、
 *      跨标签页里是 URL 参数，两者都是"我自称我是谁"）。号由连接分配，
 *      并且通过 `hello` 告诉对方。这是 `join.ts` 里 `msg.to !== selfPeer` 那道
 *      检查能成立的前提。
 *
 *   ② **盖章 `from`**。唯一可信的"这条消息从哪来"是**连接本身**。转发前一律重写成
 *      所连连接的端点号 —— 客户端写进去的 `from` 丢弃。少了这一步，一个改了
 *      DevTools 的人写 `from: 0` 就是主机，而 `owner === from` 那道授权会全部放行，
 *      且两边算的是同一份世界（任何"世界一致"的判据都绿）。
 *
 *   ③ **扇出**。主机的每一份广播要复制给所有客户端。客户端上行只给主机（客户端之间
 *      不该有直接通路 —— 那会造出第二条权威路径，而"谁算了这一步"就再也答不上来）。
 *
 * ★★ 为什么手写 RFC 6455 握手与帧，而不是加 `ws` 依赖
 *   见 `ws-frame.ts` 的文件头。这里只用 `node:http` + `node:crypto` 做一个 101 升级，
 *   帧编解码在 `ws-frame.ts`（纯函数、可逐字节喂语料）。
 *
 * ★ 它**不认识世界**：不解析快照、不校验意图、不知道谁是玩家。
 *   它只看信封（`kind` / `from`）与连接状态。这一条是刻意的 ——
 *   网关一旦"懂一点世界"，它就成了第二个权威，而两边不一致时没人说得清是谁对。
 *
 * ★★ 为什么住在 `src/` 而不是 `tools/`
 *   第一版写在 `tools/net-gateway.mjs` 里，于是**它一行类型检查都没有** ——
 *   而它要处理的是"任意 TCP 连接发来的任意字节"。挪进 `src/` 之后
 *   `npm run typecheck` 覆盖它，`tests/host/net-gateway.test.ts` 也能直接 import
 *   （`.mjs` 没有声明文件，tsc 会报 TS7016）。CLI 留在 `tools/net-gateway.mjs`，两层。
 */

import { createServer, type IncomingMessage } from "node:http";
import type { Duplex } from "node:stream";
import type { Socket } from "node:net";
import { createHash, randomBytes } from "node:crypto";

import { FrameReader, Opcode, decodeText, encodeFrame, encodeText } from "./ws-frame.ts";

/** RFC 6455 §1.3 的固定 GUID。拼在 `Sec-WebSocket-Key` 后面取 SHA-1 再 base64。 */
const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/** 主机端点号。客户端的号从 1 开始，**永不复用**（复用会让 seq 缺口诊断错位）。 */
const HOST_PEER = 0;

type Role = "host" | "client";

interface Conn {
  readonly peer: number;
  readonly socket: Duplex;
  readonly role: Role;
  alive: boolean;
}

export interface GatewayOptions {
  /** 0 = 让系统分配（判据用这个，避免端口冲突）。 */
  readonly port?: number;
  /** 监听地址。缺省 `127.0.0.1`（判据）；CLI 传 `0.0.0.0`。 */
  readonly host?: string;
  /** 带 `?token=` 且匹配的连接成为主机。缺省随机生成并打印。 */
  readonly hostToken?: string;
  readonly maxClients?: number;
  readonly log?: (msg: string) => void;
  /** 心跳间隔。0 = 不发（判据用 0，真部署用 30000）。 */
  readonly pingMs?: number;
}

export interface GatewayStats {
  readonly accepted: number;
  readonly rejected: number;
  readonly forwardedHostToClients: number;
  readonly forwardedClientToHost: number;
  readonly droppedNoHost: number;
  readonly malformed: number;
  readonly closed: number;
  readonly peers: number;
  readonly host: boolean;
}

export interface Gateway {
  readonly port: number;
  readonly hostToken: string;
  readonly url: string;
  readonly stats: () => GatewayStats;
  readonly close: () => Promise<void>;
}

/**
 * 启动网关。
 *
 * ★ 返回 `Promise` 而不是同步对象：端口是异步绑定的（`listen` 的回调里才有真端口），
 *   而"端口 0"的整个意义就是"绑完才知道是几"。
 */
export async function startGateway(opts: GatewayOptions = {}): Promise<Gateway> {
  const hostToken = opts.hostToken ?? randomBytes(9).toString("base64url");
  const maxClients = opts.maxClients ?? 8;
  const log = opts.log ?? ((msg: string): void => console.log(msg));
  const pingMs = opts.pingMs ?? 0;
  const bindHost = opts.host ?? "127.0.0.1";

  /** peerId → 连接。主机是 0，其余是客户端。 */
  const peers = new Map<number, Conn>();
  /** 下一个要分配的客户端号。**单调递增**（见 `HOST_PEER` 的注释）。 */
  let nextPeer = 1;
  let hostPeer: number | null = null;
  const counters = {
    accepted: 0,
    rejected: 0,
    forwardedHostToClients: 0,
    forwardedClientToHost: 0,
    droppedNoHost: 0,
    malformed: 0,
    closed: 0,
  };

  const server = createServer((_req, res) => {
    // 普通 HTTP 请求：给一个能看的状态页，而不是 404。运维第一件事就是"打开看看"。
    res.writeHead(200, { "content-type": "text/plain; charset=utf-8" });
    res.end(`net-gateway\nhost: ${hostPeer === null ? "（还没连）" : "在线"}\npeers: ${String(peers.size)}\n`);
  });

  server.on("upgrade", (req: IncomingMessage, socket: Duplex, head: Buffer): void => {
    const key = req.headers["sec-websocket-key"];
    const version = req.headers["sec-websocket-version"];
    const url = new URL(req.url ?? "/", "http://x");
    const wantsHost = url.searchParams.get("token") === hostToken;

    // ★ 版本必须是 13。低版本（hixie-76）的握手完全不一样，而我们只实现这一版 ——
    //   放过去的话会走到"升级成功但帧读不出来"，那是最难查的一种。
    if (typeof key !== "string" || version !== "13") {
      counters.rejected++;
      reject(socket, 400, "Bad Request", "需要 Sec-WebSocket-Key 且 Sec-WebSocket-Version: 13");
      return;
    }
    if (wantsHost && hostPeer !== null) {
      counters.rejected++;
      reject(socket, 409, "Conflict", "主机已经在线");
      return;
    }
    const clients = peers.size - (hostPeer === null ? 0 : 1);
    if (!wantsHost && clients >= maxClients) {
      counters.rejected++;
      reject(socket, 503, "Service Unavailable", `客户端已满（${String(maxClients)}）`);
      return;
    }

    const accept = createHash("sha1")
      .update(key + WS_GUID)
      .digest("base64");
    socket.write(
      "HTTP/1.1 101 Switching Protocols\r\n" +
        "Upgrade: websocket\r\n" +
        "Connection: Upgrade\r\n" +
        `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
    );

    const peer = wantsHost ? HOST_PEER : nextPeer++;
    if (wantsHost) hostPeer = peer;
    counters.accepted++;
    const conn: Conn = { peer, socket, role: wantsHost ? "host" : "client", alive: true };
    peers.set(peer, conn);
    // ★ `@types/node` 把 upgrade 的 socket 标成 `Duplex`，运行时其实是 `net.Socket`
    //   （`remoteAddress` / `remotePort` 在它上面）。这个断言是类型定义与运行时的已知
    //   差距，不是"我知道得更多"—— 拿掉的代价是日志里少一个"谁连上来的"。
    log(`[gw] + peer ${String(peer)} (${conn.role}) from ${(socket as Socket).remoteAddress ?? "?"}`);

    // ★ `hello` 必须**在升级响应之后立刻发**，且要在此之前不接受任何转发。
    //   客户端靠它才知道自己几号（`Joiner.reply` 的 `to` 检查），而它比客户端
    //   发出的第一条 `join` 一定更早（同一条 TCP 上的 FIFO）。
    sendJson(conn, { kind: "hello", peer, role: conn.role });

    const reader = new FrameReader();
    if (head.length > 0) reader.push(head);

    socket.on("data", (chunk: Buffer) => {
      reader.push(chunk);
      for (;;) {
        const frame = reader.next();
        if (frame === null) break;
        if (!onFrame(conn, frame)) return;
      }
      const err = reader.error();
      if (err !== null) {
        log(`[gw] peer ${String(peer)} 帧错误：${err}`);
        closeConn(conn, 1002, err);
      }
    });

    socket.on("close", () => closeConn(conn, 1001, "socket closed"));
    socket.on("error", () => closeConn(conn, 1001, "socket error"));
  });

  /**
   * 关一条连接，并通知主机（如果是客户端）。
   *
   * ★ 通知是必需的，不是"顺手做一下"：`Room` 有 `drop()` + `sweep()`，但**没有任何
   *   人调它们**（批164 留下的空接口）。不通知的话，一个人关掉页面之后座位永远占着，
   *   `maxPlayers` 满了之后谁也进不来，而房间账本上"在线 3"永远不变。
   */
  function closeConn(conn: Conn, code: number, reason: string): void {
    if (!conn.alive) return;
    conn.alive = false;
    peers.delete(conn.peer);
    counters.closed++;
    try {
      conn.socket.write(encodeFrame(Opcode.Close, closePayload(code, reason)));
    } catch {
      /* 已经断了 */
    }
    try {
      conn.socket.end();
    } catch {
      /* 同上 */
    }
    if (conn.role === "host") {
      hostPeer = null;
      log(`[gw] - peer 0 (host) ${reason}`);
      // ★ 主机走了：把所有客户端也关掉。留着它们只会让它们在"一个没有权威的世界"里
      //   继续跑（位置全靠预测，谁也纠不回来）。让它们重连，比让它们假装还在玩好。
      for (const c of [...peers.values()]) closeConn(c, 1001, "host gone");
      return;
    }
    log(`[gw] - peer ${String(conn.peer)} (${reason})`);
    const host = hostPeer === null ? undefined : peers.get(hostPeer);
    if (host !== undefined) sendJson(host, { kind: "peer-left", peer: conn.peer, reason });
  }

  /** 处理一帧。返回 `false` 表示连接已经不能再用（调用方该停）。 */
  function onFrame(conn: Conn, frame: { readonly opcode: number; readonly payload: Uint8Array }): boolean {
    if (frame.opcode === Opcode.Close) {
      closeConn(conn, 1000, "peer close");
      return false;
    }
    if (frame.opcode === Opcode.Ping) {
      try {
        conn.socket.write(encodeFrame(Opcode.Pong, frame.payload));
      } catch {
        closeConn(conn, 1001, "write failed");
        return false;
      }
      return true;
    }
    if (frame.opcode === Opcode.Pong) return true;
    if (frame.opcode !== Opcode.Text) {
      // 我们只用文本帧（`NetMessage` 全是 JSON）。二进制帧说明对面不是这个协议。
      closeConn(conn, 1003, "只支持文本帧");
      return false;
    }
    const text = decodeText(frame.payload);
    if (text === null) {
      counters.malformed++;
      closeConn(conn, 1007, "不是合法的 UTF-8");
      return false;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      // ★ 坏 JSON 只记账**不关连接**：一条坏消息不该让玩家掉线。
      counters.malformed++;
      return true;
    }
    if (typeof parsed !== "object" || parsed === null) {
      counters.malformed++;
      return true;
    }
    const msg = parsed as Record<string, unknown>;
    if (typeof msg["kind"] !== "string") {
      counters.malformed++;
      return true;
    }

    // ★★ 盖章。**唯一一处**重写 `from` 的地方，且不看原值。
    //   不用 `msg.from ?? peer` —— 那是"客户端说了算，没写才轮到我们"。
    const stamped = { ...msg, from: conn.peer };
    const wire = encodeText(JSON.stringify(stamped));

    if (conn.role === "host") {
      // 主机 → 所有客户端。一份广播复制 N 份（"多客户端收据分流"就发生在这里：
      // 收据本身是「按实体索引的全量表」，每个客户端只剪自己那一行，所以**不需要**
      // 给不同客户端裁剪不同的 acks —— 那会造出 N 份世界状态摘要，而它们必然不同步）。
      let sent = 0;
      for (const p of peers.values()) {
        if (p.role === "host") continue;
        try {
          p.socket.write(wire);
          sent++;
        } catch {
          closeConn(p, 1001, "write failed");
        }
      }
      counters.forwardedHostToClients += sent;
      return true;
    }

    // 客户端 → 主机（单播）。主机不在就丢，并计数 —— 客户端会每 15 拍重发 `join`，
    // 所以"主机后上线"能自愈，不需要网关排队（排队会在主机长时间不在时吃满内存）。
    const host = hostPeer === null ? undefined : peers.get(hostPeer);
    if (host === undefined) {
      counters.droppedNoHost++;
      return true;
    }
    try {
      host.socket.write(wire);
      counters.forwardedClientToHost++;
    } catch {
      closeConn(host, 1001, "write failed");
    }
    return true;
  }

  function sendJson(conn: Conn, obj: unknown): void {
    try {
      conn.socket.write(encodeText(JSON.stringify(obj)));
    } catch {
      closeConn(conn, 1001, "write failed");
    }
  }

  return await new Promise<Gateway>((resolve) => {
    let pingTimer: ReturnType<typeof setInterval> | null = null;
    server.listen(opts.port ?? 8787, bindHost, () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr !== null ? addr.port : 0;
      if (pingMs > 0) {
        pingTimer = setInterval(() => {
          for (const p of peers.values()) {
            try {
              p.socket.write(encodeFrame(Opcode.Ping, new Uint8Array(0)));
            } catch {
              closeConn(p, 1001, "ping failed");
            }
          }
        }, pingMs);
        // ★ `unref()`：心跳不该让进程活着。判据跑完不退出是最烦人的一种"卡住"。
        if (typeof pingTimer.unref === "function") pingTimer.unref();
      }
      log(`[gw] listening ws://${bindHost}:${String(port)}`);
      log(`[gw] host token: ${hostToken}`);
      resolve({
        port,
        hostToken,
        url: `ws://${bindHost}:${String(port)}`,
        stats: () => ({ ...counters, peers: peers.size, host: hostPeer !== null }),
        close: () =>
          new Promise<void>((done) => {
            if (pingTimer !== null) clearInterval(pingTimer);
            for (const p of [...peers.values()]) closeConn(p, 1001, "gateway closing");
            // ★★ 关停要有**兜底超时**，不能无条件等 `server.close()` 的回调。
            //
            //   `server.close()` 要等所有 socket 都断开才回调，而 `peers` 只是我们的
            //   账本 —— 任何"不在账本里但还开着"的连接都会让关停永远挂住。
            //   实测到的那条路径：变异 M1138 去掉「第二个主机被拒」之后，新连接占用了
            //   peer 0 并把旧主机从 `peers` 里挤掉，旧 socket 再也无人关闭 ⇒
            //   `gw.close()` 永不返回，判据跟着挂到 90 秒超时。真实世界里的对应场景是
            //   "某个连接在 closeConn 的 try 里抛了"或者"它在 upgrade 中途断掉"。
            //   关停挂住的症状很糟：进程不退出、端口不释放、下一次启动 bind 失败。
            //
            // ★ 顺序是"先礼貌、后强断"：正常路径靠 `server.close()` 的回调完成，
            //   强断只兜异常路径。反过来的话每条判据都会走 RST，客户端的 `WebSocket`
            //   收不到 close 帧 —— 实测那会让 `node --test` 挂在事件循环上不退出。
            //   300ms 是**只在异常路径上付**的代价（正常路径 `clearTimeout` 掉）。
            let finished = false;
            const finish = (): void => {
              if (finished) return;
              finished = true;
              done();
            };
            const hard = setTimeout(() => {
              server.closeAllConnections();
              finish();
            }, 300);
            // ★ `unref()`：这个兜底定时器不该让进程多活哪怕 300ms（判据每条建一个网关）。
            if (typeof hard.unref === "function") hard.unref();
            server.close(() => {
              clearTimeout(hard);
              finish();
            });
          }),
      });
    });
  });
}

/** close 帧的载荷：2 字节大端状态码 + UTF-8 原因（≤123 字节）。 */
function closePayload(code: number, reason: string): Uint8Array {
  const text = new TextEncoder().encode(String(reason).slice(0, 100));
  const out = new Uint8Array(2 + text.length);
  out[0] = (code >> 8) & 0xff;
  out[1] = code & 0xff;
  out.set(text, 2);
  return out;
}

/** 握手失败：回一个正经的 HTTP 响应再断。**不能**只 `destroy()`（客户端看到的是"连不上"）。 */
function reject(socket: Duplex, status: number, phrase: string, detail: string): void {
  try {
    const body = `${String(status)} ${phrase}: ${detail}\n`;
    socket.write(
      `HTTP/1.1 ${String(status)} ${phrase}\r\n` +
        "Connection: close\r\n" +
        "content-type: text/plain; charset=utf-8\r\n" +
        `content-length: ${String(new TextEncoder().encode(body).length)}\r\n\r\n` +
        body,
    );
    socket.end();
  } catch {
    socket.destroy();
  }
}
