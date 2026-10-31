/**
 * L6 · 握手**接线**的契约（批165）
 *
 * ★★ 与 `net-assembly.test.ts` 的分工
 *
 *   · `net-assembly.test.ts`（批152）：两个真 `GameApp` 经环回互连，世界逐字节一致
 *     —— 它问的是「副本忠实不忠实」；
 *   · 这个文件：**握手那几根线**接对没有 —— 它问的是「谁该拿到座位、重连补不补归属、
 *     装载后重不重指主角」。两者都用真的会话与真的场景，只是关注点不同。
 *
 * ★★ 为什么这一批必须把接线搬出 `demo-game.ts`
 *
 *   批163/164 把联机接进去之后，有三行**只有浏览器里才跑得到**：
 *
 *   · `if (reply.reconnected) seats?.join(reply.playerId)` —— 重连补归属；
 *   · `session.requestKeyframe()` —— 客户端刚装完世界，下一份改全量；
 *   · `onWorldLoaded: () => { heroId = pickLocalEntity(...) }` —— 装载后重指主角。
 *
 *   三行**一条判据都没有**。它们的共同症状是「世界在动，但按键不动 / 相机钉住」，
 *   而所有计数都是对的（座位 1、在线 1、reconnects 1）—— 排障时只能猜。
 *   搬进 `host/net-assembly.ts` 之后，一个 Node 判据就能直接打。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { generateWorld, type WorldPlan } from "../../src/extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { registerPlayerComponents, spawnPlayer } from "../../src/extensions/worldgen/spawn.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import {
  AUTHORITY,
  NetIdentity,
  assignOwner,
  ownerOf,
  registerNetIdentity,
} from "../../src/extensions/net/identity.ts";
import { createJoiner, createRoom, JoinReject, type Joiner, type Room } from "../../src/extensions/net/join.ts";
import { createBroadcastTransport, type ChannelLike } from "../../src/extensions/net/broadcast-transport.ts";
import { DEFAULT_INPUT_MAP } from "../../src/extensions/input/input-map.ts";
import type { InputSnapshot } from "../../src/platform/input/device.ts";
import { countPlayers, createSeatTable, type SeatTable } from "../../src/host/seat-table.ts";
import {
  assembleClientNet,
  assembleHostNet,
  handleJoinRequest,
  localCommand,
  type HostJoinDeps,
  type NetInputProbe,
} from "../../src/host/net-assembly.ts";

const DT = 1 / 30;

/** 内存总线：同名通道互达，投递由 `flush()` 显式触发。 */
function createBus(): { open(name: string): ChannelLike; flush(): void } {
  type Member = { onmessage: ((ev: { readonly data: unknown }) => void) | null };
  const members = new Map<string, Set<Member>>();
  let queue: (() => void)[] = [];
  function open(name: string): ChannelLike {
    const self: Member & ChannelLike = {
      name,
      onmessage: null,
      postMessage(data: unknown): void {
        const peers = [...(members.get(name) ?? [])].filter((o) => o !== self);
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
  };
}

function makeRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerPlayerComponents(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  registerNetIdentity(reg);
  return reg;
}

function makeWorld(): { scene: Scene; plan: WorldPlan; heroId: number; heroCell: number } {
  const reg = makeRegistry();
  const scene = new Scene("host", reg);
  const g = generateWorld({ seed: 7, width: 32, height: 24, maxSitesPerCell: 1 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  assert.ok(assembleWorld(g.value, scene).ok);
  const hero = spawnPlayer(scene, g.value);
  assert.ok(hero.ok, hero.ok ? "" : `${hero.error.code}`);
  return { scene, plan: g.value, heroId: hero.value.nodeId, heroCell: hero.value.cell };
}

interface FakeScheduler {
  onStep(fn: (tick: number, dt: number) => void): () => void;
  run(tick: number, dt: number): void;
  /** 现在挂着几个回调（判据用它看 `off()` 有没有真的摘掉）。 */
  readonly count: number;
}
function makeScheduler(): FakeScheduler {
  const fns: ((tick: number, dt: number) => void)[] = [];
  return {
    onStep(fn) {
      fns.push(fn);
      return () => {
        const k = fns.indexOf(fn);
        if (k >= 0) fns.splice(k, 1);
      };
    },
    run(tick, dt) {
      for (const fn of [...fns]) fn(tick, dt);
    },
    get count() {
      return fns.length;
    },
  };
}

// ---------------------------------------------------------------- handleJoinRequest

interface HandshakeRig {
  readonly scene: Scene;
  readonly room: Room;
  readonly seats: SeatTable;
  readonly sent: unknown[];
  keyframes: number;
  readonly warnings: string[];
  readonly deps: HostJoinDeps;
}

function makeHandshakeRig(opts: { maxPlayers?: number; withSeats?: boolean } = {}): HandshakeRig {
  const w = makeWorld();
  const seats = createSeatTable({ scene: w.scene, plan: w.plan, origin: w.heroCell });
  const room = createRoom({
    id: "asm",
    name: "asm",
    ...(opts.maxPlayers === undefined ? {} : { maxPlayers: opts.maxPlayers }),
    snapshot: () => "{}",
    onJoin: (pid: number) => {
      seats.join(pid);
    },
  });
  const rig: HandshakeRig = {
    scene: w.scene,
    room,
    seats,
    sent: [],
    keyframes: 0,
    warnings: [],
    deps: {
      room,
      seats: opts.withSeats === false ? null : seats,
      send: (r: unknown) => {
        rig.sent.push(r);
      },
      requestKeyframe: () => {
        rig.keyframes++;
      },
      warn: (m) => {
        rig.warnings.push(m);
      },
    },
  };
  return rig;
}

test("★★ 新座位：分配座位 → 造实体 → 回包 → 要一份全量（四件事一件都不许漏）", () => {
  const rig = makeHandshakeRig();
  const j = createJoiner({ self: 1, name: "p1" });
  const reply = handleJoinRequest(rig.deps, j.request(0), 1, 0);
  j.reply(reply);

  assert.equal(reply.accepted, true);
  assert.equal(reply.accepted ? reply.playerId : -1, 1, "第一个端点该拿到 1 号座位（0 号是主机自己）");
  assert.equal(rig.sent.length, 1, "回复没有交出去 —— 客户端会一直重发到超时");
  assert.equal(rig.seats.stats().spawned, 1, "座位坐了但实体没造出来（所有计数都会是对的）");
  assert.equal(countPlayers(rig.scene), 2, "主机世界里应该站着两个人");
  assert.equal(rig.keyframes, 1, "新客户端装完世界后没有要求改全量 —— 它下一份增量必然对不上基线");
});

test("★★ 重连：**补一次** `join` 把归属写回来，且不造第二个实体", () => {
  const rig = makeHandshakeRig();
  const j = createJoiner({ self: 1, name: "p1" });
  const first = handleJoinRequest(rig.deps, j.request(0), 1, 0);
  j.reply(first);
  assert.ok(first.accepted);
  const entity = rig.seats.entityOf(1);
  assert.ok(entity !== null);
  assert.equal(rig.keyframes, 1);

  // 掉线：`Room` 保留座位等超时，而**超时清扫**（或宿主自己的释放）把归属交还权威。
  // 这里是重连窗口内 —— 但归属被交还这一步要模拟出来，否则「补 join」这一行
  // 在回放里根本碰不到（它补的是「扫过一遍」之后的状态）。
  rig.room.drop(1, 10);
  assignOwner(rig.scene, entity, AUTHORITY);
  assert.equal(ownerOf(rig.scene, entity), AUTHORITY);

  const again = handleJoinRequest(rig.deps, j.request(20), 1, 20);
  j.reply(again);

  assert.equal(again.accepted && again.reconnected, true, "窗口内回来必须是「重连」而不是「新玩家」");
  assert.equal(again.accepted ? again.playerId : -1, 1, "重连换了座位号 —— 票据那条路没接上");
  assert.equal(rig.seats.stats().spawned, 1, "重连又造了一个实体（他会多出一个分身）");
  assert.equal(rig.seats.stats().reused, 1, "重连没有走到「复用」那条路上 —— 归属没被写回来");
  assert.equal(rig.seats.entityOf(1), entity, "重连后角色换了节点 —— 他会在世界里瞬移");
  assert.equal(ownerOf(rig.scene, entity), 1, "重连没把归属写回来：他看得到自己，但按键不动");
  assert.equal(rig.keyframes, 2, "重连也要一份全量（他手里那份不在会话的序号链上）");
});

test("★ 被拒的请求：**不**要全量，但回复照样发出去", () => {
  const rig = makeHandshakeRig({ maxPlayers: 2 }); // 主机 + 1 个座位
  const a = createJoiner({ self: 1, name: "p1" });
  const first = handleJoinRequest(rig.deps, a.request(0), 1, 0);
  a.reply(first);
  assert.ok(first.accepted);

  const b = createJoiner({ self: 2, name: "p2" });
  const refused = handleJoinRequest(rig.deps, b.request(0), 2, 0);

  assert.equal(refused.accepted, false);
  assert.equal(refused.accepted ? "" : refused.reason, JoinReject.Full);
  assert.equal(rig.keyframes, 1, "拒绝也去要全量 —— 白广播一份没人在等的世界");
  assert.equal(rig.sent.length, 2, "拒绝的回复没发出去 —— 客户端会一直重试到超时");
});

test("★ 座位表是 `null`（世界还没生成）时重连：**留证据**，不是静默", () => {
  const rig = makeHandshakeRig({ withSeats: false });
  const j = createJoiner({ self: 1, name: "p1" });
  const first = handleJoinRequest(rig.deps, j.request(0), 1, 0);
  j.reply(first);
  assert.ok(first.accepted);

  rig.room.drop(1, 5);
  const again = handleJoinRequest(rig.deps, j.request(8), 1, 8);
  assert.equal(again.accepted && again.reconnected, true);
  assert.equal(rig.warnings.length, 1, "重连补不上实体却一声不吭 —— 排障时只能猜");
  assert.ok(
    (rig.warnings[0] ?? "").includes("1"),
    `告警里要点名是几号座位：${rig.warnings[0] ?? ""}`,
  );
  assert.equal(rig.keyframes, 2, "补不上实体也仍然该给一份全量（客户端那边还是得有个世界）");
});

// ---------------------------------------------------------------- assembleHostNet

test("★★ 装配给主机自己挂上 0 号归属（不挂 ⇒ 自己的输入全被 `not-owner` 拒掉）", () => {
  const w = makeWorld();
  const bus = createBus();
  const transport = createBroadcastTransport({ channel: bus.open("h0"), self: 0 });
  assert.equal(ownerOf(w.scene, w.heroId), null, "前置：开局那位还没有 `net.identity`");

  assembleHostNet({
    app: { scene: w.scene, components: w.scene.components, scheduler: makeScheduler() },
    scene: w.scene,
    transport,
    heroId: w.heroId,
    plan: w.plan,
    nav: null,
    origin: w.heroCell,
    room: "h0",
    assembled: () => true,
    input: () => null,
    warn: () => {},
  });

  assert.equal(ownerOf(w.scene, w.heroId), 0, "主机自己的角色没有归属 —— 他按 WASD 会被 `not-owner` 拒掉");
});

test("★ 重复装配不许把 0 号归属叠成两份", () => {
  const w = makeWorld();
  const bus = createBus();
  const transport = createBroadcastTransport({ channel: bus.open("h1"), self: 0 });
  const opts = {
    app: { scene: w.scene, components: w.scene.components, scheduler: makeScheduler() },
    scene: w.scene,
    transport,
    heroId: w.heroId,
    plan: w.plan,
    nav: null,
    origin: w.heroCell,
    room: "h1",
    assembled: () => true,
    input: () => null,
    warn: () => {},
  };
  /** 节点上 `net.identity` 的**实例数**（不是 `get()` 返回的那个）。 */
  const identCount = (): number =>
    w.scene.componentsOf("net.identity").filter((c) => c.node?.id === w.heroId).length;

  assembleHostNet(opts);
  assert.equal(identCount(), 1, "前置：装配之后正好一份归属");
  assembleHostNet(opts);
  // ★★ 这里比的必须是**实例数**，不是 `get()` 的返回值。
  //   `Node.attach` 会 push 第二个同类型组件，而 `get()` 返回数组里的**第一个**
  //   —— 于是「叠了两份」在 `ownerOf` 上完全看不出来（它读的就是第一个）。
  //   这正是「标志位对了、效果没发生」的反面：效果发生了，但观测点选错了。
  assert.equal(identCount(), 1, "第二次装配又挂了一份 `net.identity` —— 归属从此有两个答案");
});

test("★ 没有生成计划：座位表为 `null`，且加入被拒成 `behind`（可重试），不是 `full`", () => {
  const w = makeWorld();
  const bus = createBus();
  const transport = createBroadcastTransport({ channel: bus.open("h2"), self: 0 });
  const side = assembleHostNet({
    app: { scene: w.scene, components: w.scene.components, scheduler: makeScheduler() },
    scene: w.scene,
    transport,
    heroId: w.heroId,
    plan: null,
    nav: null,
    origin: 0,
    room: "h2",
    assembled: () => false,
    input: () => null,
    warn: () => {},
  });
  assert.equal(side.seats, null, "没有生成计划却造出了座位表 —— 它会去 `pickJoinCell` 里解引用 null");

  const j = createJoiner({ self: 1, name: "p1" });
  const r = side.room.accept(j.request(0), 1, 0);
  assert.equal(r.accepted, false);
  assert.equal(r.accepted ? "" : r.reason, JoinReject.Behind, "世界没好时该拒 `behind`（可重试），不是 `full`");
});

// ---------------------------------------------------------------- localCommand

function probe(keys: readonly string[]): NetInputProbe {
  const set = new Set(keys);
  const empty: ReadonlySet<string> = new Set();
  const snap: InputSnapshot = {
    keysDown: set,
    keysPressed: empty,
    keysReleased: empty,
    pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
    wheel: { dx: 0, dy: 0 },
    text: "",
  };
  return { map: DEFAULT_INPUT_MAP, snapshot: snap };
}

test("★★ 本地意图只有一份实现：同一实体 + 同一输入 ⇒ 同一结果（两端不会各算一套）", () => {
  const w = makeWorld();
  // 前置：给他挂上 0 号归属（装配会做，这里只关心「读法」是否唯一）
  // ★ `assignOwner` 要求节点上**已经有** `net.identity`（它只改数字，不建组件）。
  w.scene.attach(w.heroId, () => {
    const n = new NetIdentity();
    n.owner = 0;
    return n;
  });
  w.scene.flush();
  const a = localCommand(w.scene, 0, probe(["KeyD"]));
  const b = localCommand(w.scene, 0, probe(["KeyD"]));
  assert.ok(a !== null && b !== null);
  assert.deepEqual(a, b);
  assert.equal(a.entity, w.heroId);
  assert.deepEqual(
    a.intent,
    { kind: "move.dir", dx: 1, dz: 0 },
    "KeyD 应该是 +x —— 方向由映射表解释，不是写死的键名",
  );
});

test("★ 本地意图的四种 `null`：没探针 / 没座位 / 座位没实体 / 没按键", () => {
  const w = makeWorld();
  // ★★ 必须先给 0 号挂上归属：不然 `pickLocalEntity` 一律返回 null，
  //   四条断言全靠「没实体」这一条路径通过 —— 于是「没按键」那条
  //   （真正要测的零方向早退）**根本没被执行到**。第一版就是这样绿的。
  w.scene.attach(w.heroId, () => {
    const n = new NetIdentity();
    n.owner = 0;
    return n;
  });
  w.scene.flush();
  assert.equal(localCommand(w.scene, 0, null), null, "没有输入探针时不该凭空产出意图");
  assert.equal(localCommand(w.scene, null, probe(["KeyD"])), null, "还没有座位时不该产出意图");
  assert.equal(localCommand(w.scene, 99, probe(["KeyD"])), null, "座位 99 没有实体时不该产出意图");
  assert.equal(localCommand(w.scene, 0, probe([])), null, "没按键时不该产出意图（否则每拍都发一条零位移）");
});

// ---------------------------------------------------------------- assembleClientNet

test("★ 客户端被拒：同一理由只提示一次（每 15 拍重发，每条都弹会闪成一团）", () => {
  const bus = createBus();
  const reg = makeRegistry();
  const scene = new Scene("c", reg);
  const scheduler = makeScheduler();
  const transport = createBroadcastTransport({ channel: bus.open("c1"), self: 1 });
  // 对面（主机）要有一个真的 transport：`postMessage` 不投给自己，自己发自己是收不到的。
  const hostTr = createBroadcastTransport({ channel: bus.open("c1"), self: 0 });
  const joiner: Joiner = createJoiner({ self: 1, name: "c" });
  // 先发一次请求，让 joiner 处于 `joining`（否则 `reply()` 一律返回 `false`）
  transport.send(joiner.request(0));

  const notes: string[] = [];
  assembleClientNet({
    app: { scene, components: reg, scheduler },
    scene,
    transport,
    joiner,
    input: () => null,
    onHero: () => {},
    notify: (m) => {
      notes.push(m);
    },
  });

  const refuse = (reason: string, tick: number): void => {
    // ★ 真实世界里客户端每 15 拍重发一次；不发的话 `awaiting` 是 `false`，
    //   回复会被当成「迟到/重放」丢掉（`strayReplies++`）—— 于是这条判据测的
    //   就不再是「去重」而是「重发」了。
    joiner.request(tick);
    // 手造一条拒绝回复：主机侧 `room.accept` 在满员 / 版本不符时产出的就是这形状。
    hostTr.send({
      kind: "join-reply",
      from: 0,
      to: 1,
      tick,
      seq: tick + 1,
      accepted: false,
      reason,
    } as never);
    // ★ 顺序不能反：先 `flush` 把消息投进各端的收件箱，再 `step` 让它被读走。
    bus.flush();
    scheduler.run(tick, DT);
  };

  refuse("full", 1);
  refuse("full", 2);
  assert.equal(notes.length, 1, `同一理由提示了 ${String(notes.length)} 次（每条重发都弹一次）`);
  refuse("version-old", 3);
  assert.equal(notes.length, 2, "换了理由却不提示 —— 玩家不知道「要更新」还是「等会儿」");
});

test("★ `off()` 真的能摘掉会话的每拍驱动（装配返回的那个句柄不是摆设）", () => {
  const bus = createBus();
  const reg = makeRegistry();
  const scene = new Scene("c2", reg);
  const scheduler = makeScheduler();
  const transport = createBroadcastTransport({ channel: bus.open("c2"), self: 1 });
  const joiner: Joiner = createJoiner({ self: 1, name: "c" });
  transport.send(joiner.request(0));

  const side = assembleClientNet({
    app: { scene, components: reg, scheduler },
    scene,
    transport,
    joiner,
    input: () => null,
    onHero: () => {},
    notify: () => {},
  });

  assert.equal(scheduler.count, 1, "装配没有把会话挂上每拍驱动 —— 它一个字节都不会收发");
  side.off();
  assert.equal(scheduler.count, 0, "`off()` 没有摘掉驱动 —— 关掉联机之后会话还在跑（对着已废弃的 transport 发消息）");
});
