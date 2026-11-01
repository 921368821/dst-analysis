/**
 * `WsTransport` 的判据（批169）
 *
 * ★ 这一层有四件事**在真实浏览器里几乎不可能复现**，所以只能在替身上钉：
 *   ① `hello` 到达之前 `self` 是 `UNASSIGNED`（那是一个只有几十毫秒的窗口）；
 *   ② 连接没建立就 `send`（本地几乎瞬间就连上了）；
 *   ③ 收到的字节不是合法 JSON / 不是这个协议（真实对端不会发）；
 *   ④ `dispose` 与 `onclose` 的先后（谁先谁后取决于当时的调度）。
 *
 * ★ 替身 `FakeSocket` 刻意**不继承** `WebSocket`：继承会让判据依赖一个只有浏览器
 *   才有的基类，而这里要验的是 `SocketLike` 这个接口上的契约
 *   （`broadcast-transport.ts` 对 `BroadcastChannel` 是同一条规矩）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { UNASSIGNED, createWsTransport, type SocketLike } from "../../src/extensions/net/ws-transport.ts";
import type { NetMessage } from "../../src/extensions/net/transport.ts";

class FakeSocket implements SocketLike {
  readonly sent: string[] = [];
  onopen: ((ev: unknown) => void) | null = null;
  onmessage: ((ev: { readonly data: unknown }) => void) | null = null;
  onclose: ((ev: unknown) => void) | null = null;
  onerror: ((ev: unknown) => void) | null = null;
  readyState = 0;
  closeCalls = 0;

  send(data: string): void {
    if (this.readyState !== 1) throw new Error("还没 open 就 send");
    this.sent.push(data);
  }

  close(): void {
    this.closeCalls++;
    this.readyState = 3;
  }

  /** 模拟浏览器派发 `open`。 */
  open(): void {
    this.readyState = 1;
    this.onopen?.({});
  }

  /** 模拟对面发来一条消息（对象会被序列化成 JSON，字符串原样送）。 */
  deliver(data: unknown): void {
    this.onmessage?.({ data: typeof data === "string" ? data : JSON.stringify(data) });
  }

  /** 模拟对面关连接。 */
  drop(): void {
    this.readyState = 3;
    this.onclose?.({});
  }
}

function rig(): { sock: FakeSocket; t: ReturnType<typeof createWsTransport> } {
  const sock = new FakeSocket();
  const t = createWsTransport({ socket: sock });
  return { sock, t };
}

const intent = (seq: number, tick: number): NetMessage => ({
  kind: "intent",
  from: 0,
  tick,
  seq,
  entity: 1,
  intent: { kind: "move.dir", dx: 1, dz: 0 },
});

// ---------------------------------------------------------------- ① 连接状态

test("★★ 未 open 时 send 返回 false 并**单独计数**（与「连接断了」分开：前者是启动时序）", () => {
  const { t } = rig();
  assert.equal(t.send(intent(0, 0)), false, "没连上就发出去 = 上层会以为在预测一个没人收到的东西");
  assert.equal(t.stats().sent, 0);
  assert.equal(t.stats().dropped, 1);
  assert.equal(t.sendBeforeOpen, 1, "启动时序的丢弃要与故障分开数，否则「每局开头丢 3 条」看起来像丢包");
  assert.equal(t.sendAfterClose, 0, "这条不是「关闭之后」");
});

test("★ open 之后 send 走 socket，且载荷是 JSON（`NetMessage` 全是纯数据）", () => {
  const { sock, t } = rig();
  sock.open();
  assert.equal(t.ready, true);
  assert.equal(t.send(intent(3, 7)), true);
  assert.equal(sock.sent.length, 1);
  assert.deepEqual(JSON.parse(sock.sent[0] ?? ""), {
    kind: "intent",
    from: 0,
    tick: 7,
    seq: 3,
    entity: 1,
    intent: { kind: "move.dir", dx: 1, dz: 0 },
  });
});

test("★ 关掉之后 send 返回 false 且计入 sendAfterClose（不抛 —— 抛会让一帧的收尾整段跳过）", () => {
  const { sock, t } = rig();
  sock.open();
  t.dispose();
  assert.equal(t.send(intent(0, 0)), false);
  assert.equal(t.sendAfterClose, 1);
  assert.equal(t.closedBy, "self");
});

test("★ dispose 幂等，且**不覆盖** closedBy（先断的可能是对面）", () => {
  const { sock, t } = rig();
  sock.open();
  sock.drop();
  assert.equal(t.closedBy, "peer");
  t.dispose();
  t.dispose();
  assert.equal(t.closedBy, "peer", "「对面先断」这条诊断被 dispose 抹掉了");
  // ★ 已经断了就**不该再 close**：对已关闭的 `WebSocket` 调 `close()` 是合法的，
  //   但对**正在 CLOSING** 的那个会打出 "WebSocket is already in CLOSING or CLOSED state"。
  //   判据钉在这里，是因为这条路径只会在"对面先断、宿主随后清理"时走到。
  assert.equal(sock.closeCalls, 0, "已经断了还去 close：一条控制台警告，而它出现在掉线时最难查");
});

// ---------------------------------------------------------------- ② hello

test("★★ `self` 在 hello 之前是 UNASSIGNED，到达之后变成网关给的号（getter，不是快照）", () => {
  const { sock, t } = rig();
  sock.open();
  assert.equal(t.self, UNASSIGNED, "还没握手就自称某个号，正是批164 拆掉的「我自称我是谁」");
  assert.equal(t.hello, null);
  sock.deliver({ kind: "hello", peer: 3, role: "client" });
  assert.equal(t.self, 3);
  assert.deepEqual(t.hello, { peer: 3, role: "client" });
});

test("★★ hello **不进 inbox**（它是这条链路的控制面，不是世界的协议）", () => {
  const { sock, t } = rig();
  sock.open();
  sock.deliver({ kind: "hello", peer: 3, role: "client" });
  assert.equal(t.receive(0).length, 0, "hello 漏进会话层会被计成「未知种类」协议违规");
  assert.equal(t.stats().received, 0);
  assert.equal(t.unknownKinds, 0);
});

test("★ 注册得比 hello 晚也要回调一次（时序竞争换一晚排查）", () => {
  const { sock, t } = rig();
  sock.open();
  const seen: number[] = [];
  // 先注册、后到：正常路径
  t.onHello((h) => seen.push(h.peer));
  sock.deliver({ kind: "hello", peer: 2, role: "client" });
  // 再注册一次：此时 hello 已经在手，必须**同步补一次**
  t.onHello((h) => seen.push(h.peer * 10));
  assert.deepEqual(seen, [2, 20]);
});

test("★ 退订之后不再回调", () => {
  const { sock, t } = rig();
  sock.open();
  let n = 0;
  const off = t.onHello(() => n++);
  off();
  sock.deliver({ kind: "hello", peer: 1, role: "client" });
  assert.equal(n, 0);
});

test("★ peer-left 交给宿主（不计数成未知种类）", () => {
  const { sock, t } = rig();
  sock.open();
  const left: { peer: number; reason: string }[] = [];
  t.onPeerLeft((peer, reason) => left.push({ peer, reason }));
  sock.deliver({ kind: "peer-left", peer: 4, reason: "gone" });
  assert.deepEqual(left, [{ peer: 4, reason: "gone" }]);
  assert.equal(t.unknownKinds, 0);
  assert.equal(t.receive(0).length, 0);
});

// ---------------------------------------------------------------- ③ 到达时刻

test("★★ 到达时刻 = 上一次 `receive()` 的 tick（与 broadcast 逐字一致）", () => {
  const { sock, t } = rig();
  sock.open();
  t.receive(10); // 基准 = 10：这一刻之后收到的消息，最早在第 10 拍可见
  sock.deliver(intent(0, 99)); // 消息自称 tick 99 —— 与它何时到达无关
  assert.equal(t.receive(9).length, 0, "第 10 拍之后收到的，第 9 拍当然看不到");
  assert.equal(t.receive(10).length, 1, "「上一次 receive 的 tick」就是它的到达时刻");
});

test("★★ 同一条消息（同一个 `msg.tick`）在两种到达时刻下可见时刻不同 —— 证明用的是 now", () => {
  // ★ 这条是上面那条的**判别性更强的版本**：两条语料只差"本端现在第几拍"，
  //   消息内容完全相同（`msg.tick` 都是 0）。于是：
  //     · 用 `now`：a 在第 5 拍收到 ⇒ 第 6 拍可见；b 在第 20 拍收到 ⇒ 第 6 拍不可见；
  //     · 用 `msg.tick`：两边都 `0 <= 6` ⇒ **两条都可见**，b 的断言当场红。
  //   用单条语料是抓不住的：`msg.tick` 大于当前拍时两种实现都"取不到"，
  //   小于时两种都"取得到" —— 必须让同一个 `msg.tick` 落在两种 now 的**两侧**。
  const a = rig();
  a.sock.open();
  a.t.receive(5);
  a.sock.deliver(intent(0, 0));
  assert.equal(a.t.receive(6).length, 1, "第 5 拍收到的，第 6 拍该可见");

  const b = rig();
  b.sock.open();
  b.t.receive(20);
  b.sock.deliver(intent(0, 0));
  assert.equal(
    b.t.receive(6).length,
    0,
    "同一个 msg.tick 在第 20 拍到达却在第 6 拍就可见 ⇒ 到达时刻被换成了 msg.tick，网络延迟这个维度消失了",
  );
});

// ---------------------------------------------------------------- ④ 形状与种类

test("★★ 坏 JSON / 非字符串 / 缺字段 都记 `malformed`，且**不进** inbox", () => {
  const { sock, t } = rig();
  sock.open();
  sock.deliver("这不是 JSON");
  sock.deliver({ kind: "intent" }); // 缺 tick/seq
  sock.onmessage?.({ data: 42 }); // 根本不是字符串
  assert.equal(t.malformed, 3);
  assert.equal(t.unknownKinds, 0, "这些不是「对面版本不同」，混着数会让版本线索被淹掉");
  assert.equal(t.receive(10).length, 0);
});

test("★ 未知 kind 记 `unknownKinds`（= 对面是另一个版本），与 malformed 分开", () => {
  const { sock, t } = rig();
  sock.open();
  sock.deliver({ kind: "world-reset", tick: 1, seq: 0 });
  assert.equal(t.unknownKinds, 1);
  assert.equal(t.malformed, 0);
});

test("★★ `kinds` 过滤是「不匹配的留在队列里」，不是「丢掉」", () => {
  const { sock, t } = rig();
  sock.open();
  t.receive(0);
  sock.deliver(intent(0, 0));
  sock.deliver({ kind: "snapshot", from: 0, tick: 0, seq: 0, json: "{}" });
  // 握手先来取 join 族：一条也不该丢
  assert.equal(t.receive(1, ["join", "join-reply"]).length, 0);
  assert.equal(t.stats().queued, 2, "被过滤掉的两条必须还在队里");
  const all = t.receive(2);
  assert.deepEqual(
    all.map((m) => m.kind),
    ["intent", "snapshot"],
    "顺序也要保持：按到达顺序取，不按种类分组",
  );
});

// ---------------------------------------------------------------- ⑤ 计数口径

test("★ 四个计数与环回 / broadcast 同一张表（切换链路时丢包率要可比）", () => {
  const { sock, t } = rig();
  const s0 = t.stats();
  assert.deepEqual(Object.keys(s0).sort(), ["dropped", "queued", "received", "sent"]);
  sock.open();
  t.send(intent(0, 0));
  sock.deliver(intent(1, 1));
  const s1 = t.stats();
  assert.equal(s1.sent, 1);
  assert.equal(s1.received, 1);
  assert.equal(s1.dropped, 0);
  assert.equal(s1.queued, 1);
});
