/**
 * 联机网关的端到端判据（批169）
 *
 * ★ 这一份是**真的起服务、真的连 TCP** —— 与其它判据不同，它要花几十毫秒。
 *   理由是这一层没有任何一部分能在纯函数里验：
 *   · "盖章"这条规则写在网关的转发路径上，而它的效果只在**对面收到的那一份**里；
 *   · "扇出"要真的有两三个连接才看得出来（一个客户端的话，"复制给所有"与"只给那一个"
 *     是同一件事）；
 *   · "主机走了客户端也跟着关"只在连接生命周期里存在。
 *
 * ★ 端口用 **0**（系统分配）+ 只听 `127.0.0.1`：判据可能并行跑，固定端口会撞；
 *   听 `0.0.0.0` 会在 CI 机器上弹防火墙提示。
 *
 * ★ 每一条判据自己起一个网关、自己关掉 —— 共用一个是"上一个用例留下的连接"
 *   变成下一个用例的语料，而那正是批98 那条「夹具不许依赖上一个动作的副作用」。
 */

import { test, after } from "node:test";
import assert from "node:assert/strict";

import { startGateway, type Gateway } from "../../src/extensions/net/gateway.ts";

/**
 * 曾经建过的每一条 socket。
 *
 * ★★ 为什么需要它（批169 实测，代价是整轮变异 600 秒超时）：判据跑到一半**失败**时，
 *   `host.close()` 那几行在断言后面，于是不会被走到 —— 而那些 socket 会一直开着，
 *   事件循环不退出，`node --test` 永远不返回。变异工具把它记成"超时"而不是"红"，
 *   整轮作废（还留下 `.cache/mutation.lock`）。
 *
 *   这不是"夹具要照顾被测代码的 bug"，而是**失败路径上也要清理**：断言失败是常态
 *   （变异就是靠它），一个只在成功路径上收尾的夹具，在它最该工作的时候什么也不做。
 */
const OPEN = new Set<WebSocket>();
after(() => {
  for (const ws of OPEN) {
    try {
      ws.close();
    } catch {
      /* 已经关了 */
    }
  }
});

/** 每条判据自带超时：卡住要**变红**，不能把整轮拖成超时。 */
const T = { timeout: 20_000 } as const;

interface Peer {
  readonly ws: WebSocket;
  readonly inbox: Record<string, unknown>[];
  /** 收到的 hello（没有就是 `null`）。 */
  readonly hello: () => Record<string, unknown> | null;
  close(): void;
}

async function boot(extra: Record<string, unknown> = {}): Promise<Gateway> {
  return await startGateway({
    port: 0,
    host: "127.0.0.1",
    hostToken: "tok",
    pingMs: 0,
    log: () => {},
    ...extra,
  });
}

function connect(url: string): Promise<Peer> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    OPEN.add(ws);
    const inbox: Record<string, unknown>[] = [];
    let hello: Record<string, unknown> | null = null;
    ws.addEventListener("message", (ev: MessageEvent) => {
      const m = JSON.parse(String(ev.data)) as Record<string, unknown>;
      if (m["kind"] === "hello") hello = m;
      else inbox.push(m);
    });
    ws.addEventListener("open", () => {
      resolve({ ws, inbox, hello: () => hello, close: () => ws.close() });
    });
    ws.addEventListener("error", () => {
      reject(new Error(`连不上 ${url}`));
    });
  });
}

/** 等到 `pred` 命中（或超时抛，**带完整 inbox**：不然失败信息只有"超时"）。 */
function waitFor(peer: Peer, pred: (m: Record<string, unknown>) => boolean, ms = 3000): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const tick = (): void => {
      const hit = peer.inbox.find(pred);
      if (hit !== undefined) {
        resolve(hit);
        return;
      }
      if (Date.now() - t0 > ms) {
        reject(new Error(`超时（${String(ms)}ms）；收到的是 ${JSON.stringify(peer.inbox)}`));
        return;
      }
      setTimeout(tick, 5);
    };
    tick();
  });
}

/** 等到 `hello` 到手。 */
function waitHello(peer: Peer, ms = 3000): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const t0 = Date.now();
    const tick = (): void => {
      const h = peer.hello();
      if (h !== null) {
        resolve(h);
        return;
      }
      if (Date.now() - t0 > ms) {
        reject(new Error("没收到 hello"));
        return;
      }
      setTimeout(tick, 5);
    };
    tick();
  });
}

// ---------------------------------------------------------------- ① 分配

test("★★ 端点号由网关分配：主机 0、客户端从 1 起单调（永不复用）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    const c1 = await connect(gw.url);
    const c2 = await connect(gw.url);
    assert.equal((await waitHello(host))["peer"], 0);
    assert.equal((await waitHello(c1))["peer"], 1);
    assert.equal((await waitHello(c2))["peer"], 2);
    // ★ 客户端 c1 走了之后再来一个：**必须是 3**，不是回收的 1。
    //   复用号会让 seq 缺口诊断错位（同一个号上出现了两段互不相干的序列），
    //   而那种错位的症状是"偶尔丢一条"，频率取决于谁先关页面。
    c1.close();
    await waitFor(host, (m) => m["kind"] === "peer-left");
    const c3 = await connect(gw.url);
    assert.equal((await waitHello(c3))["peer"], 3, "端点号被复用了 ⇒ 后面所有按号做的诊断都会错位");
    host.close();
    c2.close();
    c3.close();
  } finally {
    await gw.close();
  }
});

// ---------------------------------------------------------------- ② 盖章

test("★★ 客户端自称 `from: 0` 会被盖成它自己的号（否则一个改 DevTools 的人就是主机）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    const c1 = await connect(gw.url);
    await waitHello(c1);
    // ★ 冒充主机：如果网关采信这个字段，主机侧的 `owner === from` 会全部放行。
    c1.ws.send(JSON.stringify({ kind: "intent", from: 0, tick: 1, seq: 0, entity: 9, intent: { kind: "move.dir", dx: 1, dz: 0 } }));
    const got = await waitFor(host, (m) => m["kind"] === "intent");
    assert.equal(got["from"], 1, "印章没盖：客户端可以自称任何号");
    host.close();
    c1.close();
  } finally {
    await gw.close();
  }
});

test("★ 主机的下行也被盖章（主机同样不采信自己写的 from）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    const c1 = await connect(gw.url);
    await waitHello(c1);
    host.ws.send(JSON.stringify({ kind: "snapshot", from: 77, tick: 3, seq: 0, json: "{}" }));
    const got = await waitFor(c1, (m) => m["kind"] === "snapshot");
    assert.equal(got["from"], 0, "主机不是例外：它的信封 `from` 也是网关说了算");
    host.close();
    c1.close();
  } finally {
    await gw.close();
  }
});

// ---------------------------------------------------------------- ③ 扇出

test("★★ 主机的一份广播要复制给**所有**客户端（多客户端的分流点在这里）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    const c1 = await connect(gw.url);
    const c2 = await connect(gw.url);
    await waitHello(c1);
    await waitHello(c2);
    host.ws.send(JSON.stringify({ kind: "snapshot", from: 0, tick: 9, seq: 7, json: '{"n":1}' }));
    const a = await waitFor(c1, (m) => m["kind"] === "snapshot");
    const b = await waitFor(c2, (m) => m["kind"] === "snapshot");
    assert.equal(a["seq"], 7);
    assert.equal(b["seq"], 7, "第二个客户端没收到 ⇒ 只有一个客户端时永远看不出这条");
    assert.equal(gw.stats()["forwardedHostToClients"], 2);
    // ★ 主机**不该**收到自己发的那份：它自己就是作者（会话里 `sentSnap` 已经更新过），
    //   收到一份自己的广播等于把同一份世界装两遍，而"装两遍"在终态一致的判据里看不出来。
    assert.deepEqual(host.inbox, [], "主机收到了自己发的广播 ⇒ 它会把自己重放一次");
    host.close();
    c1.close();
    c2.close();
  } finally {
    await gw.close();
  }
});

test("★★ 客户端的上行只给主机（客户端之间直连会造出第二条权威路径）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    const c1 = await connect(gw.url);
    const c2 = await connect(gw.url);
    await waitHello(c1);
    await waitHello(c2);
    c1.ws.send(JSON.stringify({ kind: "intent", from: 1, tick: 1, seq: 0, entity: 9, intent: { kind: "move.dir", dx: 1, dz: 0 } }));
    await waitFor(host, (m) => m["kind"] === "intent");
    // 给 c2 一点时间"什么也不该收到"
    await new Promise((r) => setTimeout(r, 60));
    assert.deepEqual(c2.inbox, [], "c2 收到了另一个客户端的意图 ⇒ 两条权威路径");
    host.close();
    c1.close();
    c2.close();
  } finally {
    await gw.close();
  }
});

// ---------------------------------------------------------------- ④ 断开

test("★★ 客户端断开 → 主机收到 `peer-left`（`Room.drop` 唯一的触发源）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    const c1 = await connect(gw.url);
    const hello = await waitHello(c1);
    c1.close();
    const left = await waitFor(host, (m) => m["kind"] === "peer-left");
    assert.equal(left["peer"], hello["peer"]);
    host.close();
  } finally {
    await gw.close();
  }
});

test("★★ 主机断开 → 所有客户端也被关（留在一个没有权威的世界里只会继续飘）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    const c1 = await connect(gw.url);
    await waitHello(c1);
    const closed = new Promise<void>((resolve) => {
      c1.ws.addEventListener("close", () => resolve());
    });
    host.close();
    await Promise.race([
      closed,
      new Promise((_, reject) => setTimeout(() => reject(new Error("主机走了但客户端还连着")), 3000)),
    ]);
  } finally {
    await gw.close();
  }
});

// ---------------------------------------------------------------- ⑤ 拒绝与丢弃

test("★ 第二个「主机」连上来要被拒（否则房间有两个权威）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    await assert.rejects(async () => {
      const dup = await connect(`${gw.url}?token=${gw.hostToken}`);
      dup.close();
    }, /连不上/);
    host.close();
  } finally {
    await gw.close();
  }
});

test("★★ 主机不在时客户端的消息被**丢弃并计数**，不是排队（排队会在主机长时间不在时吃满内存）", T, async () => {
  const gw = await boot();
  try {
    const c1 = await connect(gw.url);
    await waitHello(c1);
    assert.equal(c1.hello()?.["peer"], 1, "先来的客户端也是 1 号 —— 网关不预留座位");
    c1.ws.send(JSON.stringify({ kind: "join", from: 1, tick: 1, seq: 0, name: "x" }));
    // ★ 轮询而不是固定 `setTimeout(80)`：判据是并行跑的（全量 70 多个文件），
    //   机器忙时 80ms 可能不够 ⇒ 消息还在路上而计数是 0 ⇒ **假红**。
    //   「等到它发生」不该靠猜时间；这里轮询到出现为止，仍然断言 ≥ 1。
    for (let i = 0; i < 200 && (gw.stats()["droppedNoHost"] ?? 0) === 0; i++) {
      await new Promise((r) => setTimeout(r, 5));
    }
    assert.ok((gw.stats()["droppedNoHost"] ?? 0) >= 1, `没计数：${JSON.stringify(gw.stats())}`);
    // ★ 主机后上来时**不补发**：客户端每 15 拍会重发 `join`（`net/join.ts` 的重试），
    //   所以"主机后上线"能自愈。补发会让网关持有一份"谁的什么还没送到"的状态，
    //   而那份状态在主机重启后与真实世界无关。
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    await new Promise((r) => setTimeout(r, 80));
    assert.deepEqual(host.inbox, [], "网关把主机不在时收到的消息补发了 ⇒ 主机收到一条几拍前的意图");
    host.close();
    c1.close();
  } finally {
    await gw.close();
  }
});

test("★ 坏 JSON 只记账、不踢人（一条坏消息不该让玩家掉线）", T, async () => {
  const gw = await boot();
  try {
    const host = await connect(`${gw.url}?token=${gw.hostToken}`);
    await waitHello(host);
    const c1 = await connect(gw.url);
    await waitHello(c1);
    c1.ws.send("{这不是 JSON");
    c1.ws.send(JSON.stringify({ kind: "intent", from: 1, tick: 2, seq: 0, entity: 9, intent: { kind: "move.dir", dx: 1, dz: 0 } }));
    const got = await waitFor(host, (m) => m["kind"] === "intent");
    assert.equal(got["from"], 1, "坏 JSON 之后的连接必须还能用");
    assert.ok(
      (gw.stats()["malformed"] ?? 0) >= 1,
      `坏 JSON 没记账：${JSON.stringify(gw.stats())}`,
    );
    host.close();
    c1.close();
  } finally {
    await gw.close();
  }
});
