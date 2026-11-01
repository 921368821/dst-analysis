/**
 * L4 · RFC 6455 的最小帧编解码 —— **只有网关用**，浏览器不需要（它自带 `WebSocket`）
 *
 * ★★ 为什么手写，而不是加 `ws` 依赖
 *
 *   这个仓库的依赖只有 `wasmoon` 一个。加 `ws` 的代价不是"多一个包"，而是三件事：
 *   ① CI 从 `node --test` 变成必须 `npm install`（今天 `npm test` 在裸检出上就能跑）；
 *   ② 判据里"帧被打坏了会怎样"只能靠 `ws` 的内部行为，而那是别人的实现细节；
 *   ③ 帧层是我们**唯一**能校验收到的东西是不是 WebSocket 的地方（形状校验在它之上），
 *      交给一个库就等于把这条判据外包给"相信它是对的"。
 *
 *   而我们真正需要的只有：文本帧、close、ping/pong、分片重组。
 *   这一段约 200 行，全是纯函数，可以在 Node 里逐字节喂语料。
 *
 * ★★ 服务端与客户端的不对称（这是最容易漏的一条）
 *
 *   · **客户端发出的帧必须 mask**（RFC 6455 §5.3，不 mask 服务端必须关连接 1002）；
 *   · **服务端发出的帧不许 mask**（mask 了客户端会关连接）。
 *
 *   把这条写反的症状是"连接建立、第一条消息之后立刻断开"，而握手日志完全正常 ——
 *   于是很容易被误判成"业务层协议不对"。所以编解码两端口径都收在这个文件里，
 *   一处 encode、一处 decode，不各写一份。
 *
 * ★★ 掩码键**不是随机数**，是确定性的
 *
 *   真客户端（浏览器）的掩码是它自己实现的；我们这边的 `mask` 只用于**判据里模拟
 *   客户端**。用 `Math.random()` 有两个具体代价：
 *   ① 它过不了确定性闸门（`tools/determinism-scan.mjs` 的 `random` 规则）——
 *      而那条闸门的价值恰恰在于"每多一处就逼人看一眼"，给它开例外等于拆掉它；
 *   ② 判据要能复现："同一条语料跑两次得到同样字节"是逐字节比对的前提。
 *
 *   于是掩码键来自一个**自增轮换号**（splitmix32 一步混合）。它保证"每帧的键不同"
 *   （RFC 6455 §5.3 的动机之一），而**不**保证不可预测 —— 这一条必须写清：
 *   这个函数不该被当成客户端的掩码实现拿去用。真要写客户端，掩码交给平台的
 *   `WebSocket`（它自己会加），或者用 `node:crypto`。
 */

/** 帧类型。用 `const` 对象而不是 `enum`：Node 的类型剥离不支持 `enum`（`tools/` 里直接 import 本文件）。 */
export const Opcode = {
  Continuation: 0x0,
  Text: 0x1,
  Binary: 0x2,
  Close: 0x8,
  Ping: 0x9,
  Pong: 0xa,
} as const;

export type Opcode = (typeof Opcode)[keyof typeof Opcode];

/** 单帧载荷上限。超过就按协议错误关连接，而不是让它把网关的内存吃光。 */
export const MAX_PAYLOAD = 8 * 1024 * 1024;

export interface Frame {
  readonly opcode: number;
  /** 已解掩码、已重组分片的完整载荷。控制帧与数据帧一视同仁。 */
  readonly payload: Uint8Array;
}

/**
 * 增量帧读取器：`push()` 喂字节，`next()` 取帧。
 *
 * ★ 为什么不写成 `parseFrames(buffer)`：TCP 不保证一次 `data` 事件正好是一帧。
 *   快照 JSON 一次几十万字节，必然被拆成多个 TCP 段；一条只处理"完整缓冲"的实现
 *   会在本地环回上跑得好好的（一次就发完了），跨机器时第一条大消息就卡死。
 *   这个类就是那条"不完整的留在缓冲里、下一段接着拼"的规则本身。
 */
export class FrameReader {
  private buf = new Uint8Array(0);
  private off = 0;
  /** 第一个错误。设上之后 `next()` 永远返回 `null` —— 出了协议错误的连接没有"之后"。 */
  private fail: string | null = null;

  /** 分片重组：一条消息的起始 opcode + 已收到的段。`null` = 当前没有未完成的分片消息。 */
  private fragOpcode: number | null = null;
  private fragParts: Uint8Array[] = [];

  /** 已消费但还没压缩掉的字节数（用来看缓冲有没有在漏）。 */
  get pending(): number {
    return this.buf.length - this.off;
  }

  /** 协议错误（`null` = 没出错）。一旦非 `null`，这个读取器就废了，调用方应当关连接。 */
  error(): string | null {
    return this.fail;
  }

  push(chunk: Uint8Array): void {
    if (this.fail !== null) return;
    if (chunk.length === 0) return;
    // 先把已经消费掉的前缀丢掉，再拼 —— 否则长连接上缓冲会随连接时长线性增长。
    // 阈值不是"省一次拷贝"，而是"别在每帧都拷贝一遍整个缓冲"。
    if (this.off > 0 && this.off >= this.buf.length) {
      this.buf = new Uint8Array(0);
      this.off = 0;
    } else if (this.off > 65536 && this.off * 2 >= this.buf.length) {
      this.buf = this.buf.slice(this.off);
      this.off = 0;
    }
    const merged = new Uint8Array(this.buf.length - this.off + chunk.length);
    merged.set(this.buf.subarray(this.off), 0);
    merged.set(chunk, this.buf.length - this.off);
    this.buf = merged;
    this.off = 0;
  }

  /**
   * 取一帧。
   *
   * 返回 `null` 有两种含义，靠 `error()` 区分：**还要更多数据**（正常）与**协议错误**
   * （连接该关了）。合成一个返回值是刻意的 —— 调用方在"没数据"时唯一该做的事就是
   * 等下一段，而"出错"时唯一该做的事是关连接，两者都不会继续循环。
   */
  next(): Frame | null {
    if (this.fail !== null) return null;
    const b = this.buf;
    const start = this.off;
    if (b.length - start < 2) return null;

    const b0 = b[start] ?? 0;
    const b1 = b[start + 1] ?? 0;
    const fin = (b0 & 0x80) !== 0;
    const opcode = b0 & 0x0f;
    const masked = (b1 & 0x80) !== 0;
    let need = b1 & 0x7f;
    let p = start + 2;

    // ★ RSV 位：我们没有协商任何扩展（没有 permessage-deflate），所以必须为 0。
    //   容忍它会让"对面以为是压缩的、我们当成明文"变成一堆乱码 JSON —— 那种症状
    //   会一路表现成"形状校验失败"，离真正的原因差着三层。
    if ((b0 & 0x70) !== 0) return this.setFail("RSV 位非零（未协商扩展）");

    if (need === 126) {
      if (b.length - p < 2) return null;
      need = ((b[p] ?? 0) << 8) | (b[p + 1] ?? 0);
      p += 2;
    } else if (need === 127) {
      if (b.length - p < 8) return null;
      // 8 字节长度里高 4 字节必须为 0：大于 4GB 的帧我们一律不支持（也永远不会有）。
      if ((b[p] ?? 0) !== 0 || (b[p + 1] ?? 0) !== 0 || (b[p + 2] ?? 0) !== 0 || (b[p + 3] ?? 0) !== 0) {
        return this.setFail("帧长度超过 4GB");
      }
      need = (((b[p + 4] ?? 0) << 24) | ((b[p + 5] ?? 0) << 16) | ((b[p + 6] ?? 0) << 8) | (b[p + 7] ?? 0)) >>> 0;
      p += 8;
    }

    // ★ 上限检查放在**读载荷之前**：一个声称 2GB 的帧头就足以让"等到齐再判断"的实现
    //   把进程撑死 —— 而攻击者只要发 10 个字节就能宣称这个长度。
    if (need > MAX_PAYLOAD) return this.setFail(`单帧 ${String(need)} 字节，超过上限`);

    // 控制帧：FIN 必须为 1、载荷 ≤ 125（RFC 6455 §5.5）。这两条都是"对端实现有问题"，
    // 容忍它们的代价是分片重组状态机被一个 ping 打乱。
    if (opcode >= 0x8) {
      if (!fin) return this.setFail("控制帧不许分片");
      if (need > 125) return this.setFail("控制帧载荷超过 125 字节");
    }

    const maskAt = p;
    if (masked) {
      if (b.length - p < 4) return null;
      p += 4;
    }
    if (b.length - p < need) return null;

    const payload = new Uint8Array(need);
    payload.set(b.subarray(p, p + need));
    if (masked) {
      const k0 = b[maskAt] ?? 0;
      const k1 = b[maskAt + 1] ?? 0;
      const k2 = b[maskAt + 2] ?? 0;
      const k3 = b[maskAt + 3] ?? 0;
      for (let i = 0; i < need; i++) {
        const k = i & 3;
        const m = k === 0 ? k0 : k === 1 ? k1 : k === 2 ? k2 : k3;
        payload[i] = (payload[i] ?? 0) ^ m;
      }
    }
    p += need;
    this.off = p;

    // ---- 分片重组
    //
    // ★ 控制帧**不进**重组状态：RFC 允许 ping/pong/close 插在分片消息中间，
    //   把它当成"分片的一部分"会让整条消息的字节序错乱，而错乱的 JSON 只会
    //   报"形状不对"，指不回分片。
    if (opcode === Opcode.Continuation) {
      if (this.fragOpcode === null) return this.setFail("收到了不属于任何消息的续帧");
      this.fragParts.push(payload);
      if (!fin) return this.next();
      const total = this.fragParts.reduce((n, c) => n + c.length, 0);
      // 重组后的总量也要过上限：单帧都合规、拼起来 100MB 一样能把网关撑死。
      if (total > MAX_PAYLOAD) return this.setFail(`分片总长 ${String(total)} 字节，超过上限`);
      const joined = new Uint8Array(total);
      let at = 0;
      for (const c of this.fragParts) {
        joined.set(c, at);
        at += c.length;
      }
      const out: Frame = { opcode: this.fragOpcode, payload: joined };
      this.fragOpcode = null;
      this.fragParts = [];
      return out;
    }

    if (!fin) {
      if (opcode >= 0x8) return this.setFail("控制帧不许分片");
      this.fragOpcode = opcode;
      this.fragParts = [payload];
      return this.next();
    }

    return { opcode, payload };
  }

  private setFail(msg: string): null {
    this.fail = msg;
    return null;
  }
}

/** 掩码键的轮换号。**不是随机数**（见文件头）。 */
let maskRound = 0;

/**
 * 下一把掩码键。只要求"每一帧都不同"，不要求不可预测 —— 用途见文件头。
 *
 * 混合用 splitmix32 的一步：单步就足以让相邻轮换号的四个字节互不相同，
 * 而"加密安全"在这个用途上没有意义（这一侧是服务端，服务端不发掩码帧）。
 */
function nextMaskKey(): readonly [number, number, number, number] {
  maskRound = (maskRound + 1) >>> 0;
  let x = Math.imul(maskRound, 0x9e3779b1) >>> 0;
  x = (x ^ (x >>> 16)) >>> 0;
  return [x & 0xff, (x >>> 8) & 0xff, (x >>> 16) & 0xff, (x >>> 24) & 0xff];
}

/**
 * 编一帧。
 *
 * `mask = true` 是**客户端**口径（RFC 要求），服务端必须 `false`。
 * 掩码键每次重新生成：复用同一个键在密码学上等于不掩码，虽然这里只用于判据模拟，
 * 但"两套口径"的分叉正是下一次踩坑的地方。
 */
export function encodeFrame(opcode: number, payload: Uint8Array, mask = false): Uint8Array {
  const len = payload.length;
  let head: number;
  if (len < 126) head = 2;
  else if (len < 65536) head = 4;
  else head = 10;
  const total = head + (mask ? 4 : 0) + len;
  const out = new Uint8Array(total);

  out[0] = (0x80 | opcode) & 0xff; // FIN = 1：我们不产生分片
  const maskBit = mask ? 0x80 : 0;
  if (len < 126) {
    out[1] = maskBit | len;
  } else if (len < 65536) {
    out[1] = maskBit | 126;
    out[2] = (len >> 8) & 0xff;
    out[3] = len & 0xff;
  } else {
    out[1] = maskBit | 127;
    // 高 4 字节恒 0（JS 数组长度到不了 2^32）
    out[2] = 0;
    out[3] = 0;
    out[4] = 0;
    out[5] = 0;
    out[6] = (len >>> 24) & 0xff;
    out[7] = (len >>> 16) & 0xff;
    out[8] = (len >>> 8) & 0xff;
    out[9] = len & 0xff;
  }

  let at = head;
  if (mask) {
    const k = nextMaskKey();
    out[at] = k[0] ?? 0;
    out[at + 1] = k[1] ?? 0;
    out[at + 2] = k[2] ?? 0;
    out[at + 3] = k[3] ?? 0;
    at += 4;
    for (let i = 0; i < len; i++) {
      out[at + i] = (payload[i] ?? 0) ^ (k[i & 3] ?? 0);
    }
  } else {
    out.set(payload, at);
  }
  return out;
}

/** 文本帧的 UTF-8 载荷。网关只用文本（`NetMessage` 全是 JSON）。 */
export function encodeText(text: string, mask = false): Uint8Array {
  return encodeFrame(Opcode.Text, new TextEncoder().encode(text), mask);
}

/** 载荷转字符串。`fatal: true` 让坏 UTF-8 抛出来，而不是悄悄换成 U+FFFD。 */
export function decodeText(payload: Uint8Array): string | null {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(payload);
  } catch {
    return null;
  }
}
