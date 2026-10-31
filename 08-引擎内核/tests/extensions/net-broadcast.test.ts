/**
 * L4 · `BroadcastChannel` 传输（`net/broadcast-transport.ts`）
 *
 * 这一层是「两个标签页能不能一起玩」的全部实现。判据用**内存总线**而不是真
 * `BroadcastChannel`：真通道是异步投递 + 真实事件循环，一条 20 拍的判据要等
 * 20 次 macrotask；而这里要验的是**语义**（到达时刻、种类过滤、关闭），
 * 投递时机由 `flush()` 显式控制才看得见。
 *
 * ★ 总线里 `structuredClone` 不是装饰：真实通道会克隆，而克隆**不报错地丢东西**。
 *   判据里也克隆，才能保证「消息必须是纯数据」这条约束真的被行使过。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  createBroadcastTransport,
  type ChannelLike,
} from "../../src/extensions/net/broadcast-transport.ts";
import type { NetMessage } from "../../src/extensions/net/transport.ts";

/** 内存总线：同名通道互达，投递由 `flush()` 显式触发（模拟异步到达）。 */
function createBus(): {
  open(name: string): ChannelLike;
  flush(): void;
  pending(): number;
} {
  type Member = { onmessage: ((ev: { readonly data: unknown }) => void) | null };
  const members = new Map<string, Set<Member>>();
  let queue: (() => void)[] = [];

  function open(name: string): ChannelLike {
    const self: Member & ChannelLike = {
      name,
      onmessage: null,
      postMessage(data: unknown): void {
        const peers = [...(members.get(name) ?? [])].filter((o) => o !== self);
        // 克隆两次：一次模拟"发出去时就冻结了"，一次模拟"每个接收方各拿一份"
        const frozen = structuredClone(data);
        queue.push(() => {
          for (const o of peers) o.onmessage?.({ data: structuredClone(frozen) });
        });
      },
      close(): void {
        members.get(name)?.delete(self);
      },
    };
    if (!members.has(name)) members.set(name, new Set());
    members.get(name)?.add(self);
    return self;
  }

  return {
    open,
    flush(): void {
      const q = queue;
      queue = [];
      for (const f of q) f();
    },
    pending: (): number => queue.length,
  };
}

const joinMsg = (tick = 0, seq = 0): NetMessage =>
  ({ kind: "join", from: 0, tick, seq, room: "r", version: 1, playerId: 0 }) as unknown as NetMessage;

test("[通道] 两端互通：主机发的消息，客户端在下一拍取得到；**自己发的自己收不到**", () => {
  const bus = createBus();
  const host = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
  const client = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  assert.equal(host.send(joinMsg(0, 0)), true, "通道开着时 send 该成功");
  bus.flush();

  const got = client.receive(0);
  assert.equal(got.length, 1);
  assert.equal(got[0]?.kind, "join");
  assert.equal(host.receive(0).length, 0, "BroadcastChannel 不投给自己");
});

test("[通道] ★ 到达时刻用「上一次 receive 的 tick」，不是消息自带的 tick", () => {
  const bus = createBus();
  const host = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
  const client = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  // 本端只跑到第 3 拍。对方发来的消息自称 tick = 999（它自己已经跑得很远）。
  client.receive(3);
  host.send(joinMsg(999, 0));
  bus.flush();

  // 用「消息自己的 tick」判定的话，999 > 3 ⇒ 取不到，这条会红。
  assert.equal(client.receive(3).length, 1, "到达时刻由**收方**的时钟决定，不由发送方的 tick 决定");
});

test("[通道] 取走的不会再出现；`queued` 反映「到了但还没取」", () => {
  const bus = createBus();
  const host = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
  const client = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  host.send(joinMsg(0, 0));
  bus.flush();
  assert.equal(client.stats().queued, 1, "到了还没取 = 在途 1 条");
  assert.equal(client.receive(0).length, 1);
  assert.equal(client.receive(0).length, 0, "取走的不再重复");
  assert.equal(client.stats().queued, 0);
});

test("[通道] `receive(tick, kinds)` 只取指定族，**其余留在队里**（另一个消费者还要取）", () => {
  const bus = createBus();
  const host = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
  const client = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  host.send(joinMsg(0, 0));
  host.send({ kind: "intent", from: 0, tick: 0, seq: 1, entity: 1, intent: { kind: "move.dir", dx: 1, dz: 0 } });
  bus.flush();

  const joins = client.receive(0, ["join"]);
  assert.equal(joins.length, 1);
  assert.equal(joins[0]?.kind, "join");
  const rest = client.receive(0);
  assert.equal(rest.length, 1, "不匹配的没被丢掉");
  assert.equal(rest[0]?.kind, "intent");
});

test("[通道] ★ 认不出的消息计入 unknownKinds 并丢掉（版本不一致的唯一线索）", () => {
  const bus = createBus();
  const host = bus.open("room");
  const clientT = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  host.postMessage({ kind: "teleport", from: 0, tick: 0, seq: 0 });
  host.postMessage({ kind: "join", from: 0, tick: 0, seq: 1 }); // 缺 room/version，但形状够
  bus.flush();

  assert.equal(clientT.unknownKinds, 1, "表外的 kind 要计数");
  assert.equal(clientT.malformed, 0, "「种类不认识」不该被算成「形状坏了」—— 两个数的成因不同");
  const got = clientT.receive(0);
  assert.equal(got.length, 1, "只有形状与种类都认的那条进队");
  assert.equal(got[0]?.kind, "join");
});

test("[通道] 完全不像消息的东西（{} / null / 字符串）也不进队、不抛，且记进 malformed", () => {
  const bus = createBus();
  const host = bus.open("room");
  const clientT = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  host.postMessage({});
  host.postMessage(null);
  host.postMessage("hello");
  bus.flush();

  assert.equal(clientT.receive(0).length, 0);
  assert.equal(
    clientT.malformed,
    3,
    "形状坏了的要单记 —— 与「对面版本不同」混在一个数里，版本线索就被无关广播淹掉了",
  );
  assert.equal(clientT.unknownKinds, 0, "形状都不对的东西不该被算成「未知种类」");
});

test("[通道] dispose 之后：send 返回 false 且计入 sendAfterClose；收到的也不再进队", () => {
  const bus = createBus();
  const host = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
  const client = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  client.dispose();
  client.dispose(); // 幂等
  assert.equal(client.send(joinMsg(0, 0)), false, "关闭之后 send 必须返回 false（上层靠它决定要不要预测）");
  assert.equal(client.sendAfterClose, 1, "第二次 dispose 不该再加");

  host.send(joinMsg(0, 0));
  bus.flush();
  assert.equal(client.receive(0).length, 0, "关闭之后不再收");
});

test("[通道] ★ 关闭之后**才派发**的事件也不进队（不依赖通道替我们摘监听器）", () => {
  // ★ 为什么需要这一条：`dispose()` 会把 `channel.onmessage` 摘成 `null`，所以在
  //   我们的内存总线（`flush` 时才读 `onmessage`）上，`closed` 分支**根本走不到** ——
  //   上一条判据因此对它没有分辨力（删掉那个 `if (closed) return` 照样全绿）。
  //   换一个通道实现就走得到：在 `post` 那一刻捕获监听者、之后照常派发的写法很常见。
  //   那时消息会进队，`receive` 再把它取出来 —— 症状是"关了还在收"，
  //   而 `stats().received` 会把这一段算成正常流量（丢包率因此偏低）。
  //   ★ 传输层自己的保证不能建立在"通道会替我摘"这个假设上。
  const bus = createBus();
  const clientCh = bus.open("room");
  const clientT = createBroadcastTransport({ channel: clientCh, self: 1 });
  const handler = clientCh.onmessage;
  assert.ok(handler !== null, "传输层必须先挂上监听器");

  clientT.dispose();
  handler({ data: joinMsg(0, 0) }); // 已经排队、关闭之后才派发的那一条

  assert.equal(clientT.receive(0).length, 0, "关闭之后派发的事件不该进队");
  assert.equal(clientT.stats().received, 0, "也不该计成「收到」—— 那会把这一段算成正常流量");
});

test("[通道] 消息过的是**克隆**，不是同一个对象（改它不影响对面的世界）", () => {
  const bus = createBus();
  const host = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
  const client = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  const msg = { kind: "join" as const, from: 0, tick: 0, seq: 0, room: "r", version: 1, playerId: 0 };
  host.send(msg as unknown as NetMessage);
  bus.flush();

  const got = client.receive(0)[0] as unknown as Record<string, unknown>;
  assert.ok(got !== undefined);
  assert.notEqual(got, msg, "拿到的必须是副本");
  got["room"] = "改过了";
  assert.equal(msg.room, "r", "改副本不该动到发出去的那份");
});

test("[通道] 计数的口径与环回一致：send/recv/dropped/queued 四个数都在", () => {
  const bus = createBus();
  const a = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
  const b = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

  a.send(joinMsg(0, 0));
  bus.flush();
  b.receive(0);

  const sa = a.stats();
  assert.equal(sa.sent, 1);
  assert.equal(sa.received, 0);
  assert.equal(sa.queued, 0);
  const sb = b.stats();
  assert.equal(sb.received, 1, "接收端计数" );
  assert.equal(b.stats().dropped, 0);
});
