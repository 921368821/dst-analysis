/**
 * L6 · 端到端：**握手 → 座位 → 每人一个角色**（这一批要拆掉的那条捷径的正面判据）
 *
 * ★★ 批163 留下的形状：`planNetWiring` 把**任何端点**都映射到同一个座位，
 *   于是两个窗口同控主机世界里的同一个角色 —— 而它能跑通，所以"预测在真链路上是活的"
 *   这个结论当时是对的。它掩掉的是联机里最难的三件事：谁是谁、每人一个角色、
 *   掉线了角色归谁。这个文件一件事一件事地钉它们。
 *
 * ★ 为什么是端到端而不是"各层单测加起来"：
 *   `Room`（座位分配）· `SeatTable`（座位 → 实体）· `Session`（按座位校验意图）
 *   三层各自的判据都可以全绿，而它们之间那两根线（`onJoinRequest` 有没有接、
 *   `playerOf` 有没有真的用 `room.playerOf`）**一根都没接**也一样全绿。
 *   这与批128 那个「wx 入口装上了但没接进 main」是同一类缝。
 *
 * ★ 顺序细节（会改变结果，所以写死）：
 *   每一拍先让客户端 `step`、再让主机 `step`、最后 `bus.flush()`。
 *   广播传输的到达时刻定义是「上一次 `receive()` 的 tick」，而 `flush` 在两次 step
 *   之间投递 —— 于是"这一拍发的，下一拍可见"。这一条与浏览器里的真实时序同形。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { saveScene, sceneToJson } from "../../src/core/scene/scene-io.ts";
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
import { createSession, type NetSession } from "../../src/extensions/net/session.ts";
import { createBroadcastTransport, type ChannelLike } from "../../src/extensions/net/broadcast-transport.ts";
import { snapshotOfScene } from "../../src/extensions/net/delta.ts";
import { countPlayers, createSeatTable, type SeatTable } from "../../src/host/seat-table.ts";
import { pickLocalEntity } from "../../src/host/net-mode.ts";
import type { MoveIntent } from "../../src/extensions/motion/intent.ts";

const DT = 1 / 30;

/** 内存总线：同名通道互达，投递由 `flush()` 显式触发（与 `net-broadcast-session.test.ts` 同形）。 */
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

/** 主机侧：一张真世界 + 开局那位玩家（0 号座位，不经过座位表）。 */
function makeHostWorld(): { scene: Scene; plan: WorldPlan; heroId: number; heroCell: number } {
  const reg = makeRegistry();
  const scene = new Scene("host", reg);
  const g = generateWorld({ seed: 7, width: 32, height: 24, maxSitesPerCell: 1 });
  assert.ok(g.ok, g.ok ? "" : `生成失败：${g.error.code}`);
  assert.ok(assembleWorld(g.value, scene).ok);
  const hero = spawnPlayer(scene, g.value);
  assert.ok(hero.ok, hero.ok ? "" : `${hero.error.code} ${hero.error.message}`);
  // 主机自己的归属 = 0 号座位（联机模式下由装配挂上，见 `demo-game`）
  scene.attach(hero.value.nodeId, () => {
    const n = new NetIdentity();
    n.owner = 0;
    return n;
  });
  scene.flush();
  return { scene, plan: g.value, heroId: hero.value.nodeId, heroCell: hero.value.cell };
}

interface HostRig {
  readonly scene: Scene;
  readonly session: NetSession;
  readonly room: Room;
  readonly seats: SeatTable;
  readonly heroId: number;
  readonly transport: ReturnType<typeof createBroadcastTransport>;
}

function makeHostRig(bus: ReturnType<typeof createBus>, roomName: string): HostRig {
  const w = makeHostWorld();
  const transport = createBroadcastTransport({ channel: bus.open(roomName), self: 0 });
  const seats = createSeatTable({ scene: w.scene, plan: w.plan, origin: w.heroCell });
  const room = createRoom({
    id: roomName,
    name: "test",
    seed: 7,
    snapshot: () => sceneToJson(snapshotOfScene(w.scene)),
    onJoin: (pid: number) => {
      seats.join(pid);
    },
  });
  const session = createSession({
    role: "host",
    transport,
    scene: w.scene,
    registry: w.scene.components,
    snapshotEveryTicks: 1,
    playerOf: room.playerOf,
    onJoinRequest: (req, from, tick) => {
      const reply = room.accept(req, from, tick);
      transport.send(reply);
      if (reply.accepted) {
        // 与 `demo-game` 同一条路径：重连时 `Room` 不再调 `onJoin`，而归属可能已经
        // 被超时清扫交还权威 —— 补一次幂等的 `join`（复用实体 + 写回归属）。
        if (reply.reconnected) seats.join(reply.playerId);
        session.requestKeyframe();
      }
    },
  });
  return { scene: w.scene, session, room, seats, heroId: w.heroId, transport };
}

interface ClientRig {
  readonly joiner: Joiner;
  readonly session: NetSession;
  readonly transport: ReturnType<typeof createBroadcastTransport>;
  /** 客户端当前认为自己能推的实体（每拍现算，与 `demo-game` 一致）。 */
  localEntity(): number | null;
  /** `adopt` 成功过几次（= 拿到过几份"我进房那一刻的世界"）。 */
  adopted(): number;
}

function makeClientRig(
  bus: ReturnType<typeof createBus>,
  roomName: string,
  self: number,
  opts: { local?: (tick: number) => MoveIntent | null } = {},
): ClientRig {
  const reg = makeRegistry();
  const scene = new Scene(`client-${String(self)}`, reg);
  const transport = createBroadcastTransport({ channel: bus.open(roomName), self });
  const joiner = createJoiner({ self, name: `c${String(self)}` });
  let adoptedCount = 0;
  const session = createSession({
    role: "client",
    transport,
    scene,
    registry: reg,
    snapshotEveryTicks: 1,
    playerOf: () => joiner.playerId(),
    local: (tick) => {
      const entity = pickLocalEntity(scene, joiner.playerId());
      if (entity === null) return null;
      const intent = opts.local?.(tick) ?? null;
      return intent === null ? null : { entity, intent };
    },
    onJoinReply: (reply) => {
      if (!joiner.reply(reply)) return;
      if (!reply.accepted) return;
      const json = joiner.takeSnapshot();
      if (json !== null && session.adopt(json)) adoptedCount++;
    },
  });
  return {
    joiner,
    session,
    transport,
    localEntity: () => pickLocalEntity(scene, joiner.playerId()),
    adopted: () => adoptedCount,
  };
}

/** 客户端每 `every` 拍发一次 join 请求（`joiner` 保证重发是安全的）。 */
function pumpJoin(client: ClientRig, tick: number, every = 5): void {
  // ★ 判据是 `state()` 而不是 `playerId() !== null`：掉线之后座位号与票据是**留着**的
  //   （那正是重连的凭据，见 `join.ts` 文件头 ①），用座位号判断会让"重连"这一步
  //   永远不发请求 —— 而它在判据里表现为"重连后还是连不上"，看起来像主机的错。
  if (client.joiner.state() === "joined") return;
  if (tick % every !== 0) return;
  client.transport.send(client.joiner.request(tick));
}

function stepAll(tick: number, host: HostRig, clients: readonly ClientRig[], bus: ReturnType<typeof createBus>): void {
  for (const c of clients) {
    c.session.step(tick, DT);
  }
  host.session.step(tick, DT);
  bus.flush();
}

test("★★ 握手 → 座位 → 实体：客户端拿到 1 号座位，主机**为它造了一个角色**，不再是同控一个", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r1");
  const client = makeClientRig(bus, "r1", 1);

  for (let t = 0; t <= 30; t++) {
    pumpJoin(client, t);
    stepAll(t, host, [client], bus);
  }

  assert.equal(client.joiner.playerId(), 1, "客户端该拿到 1 号座位（0 号是主机自己）");
  assert.equal(client.joiner.stats().joins, 1);
  assert.equal(host.room.stats().accepted, 1, "主机侧房间没有接受任何人 —— `onJoinRequest` 那根线没接上");
  assert.equal(host.seats.stats().spawned, 1, "座位坐了，实体没造出来（所有计数都会是对的）");
  assert.equal(countPlayers(host.scene), 2, "主机世界里应该站着两个人");

  const mine = host.seats.entityOf(1);
  assert.ok(mine !== null, "座位表里没有 1 号座的实体");
  assert.equal(ownerOf(host.scene, mine), 1, "实体的归属不是 1 号座位 —— 他的输入会被 not-owner 拒掉");
  assert.notEqual(mine, host.heroId, "新座位落到了主机自己的角色上（那就是批163 的同控）");

  // 客户端：装上了"我进房那一刻的世界"，并且找得到**自己**那个实体
  assert.equal(client.adopted(), 1, "进房的那份世界没装上 —— 客户端会一直看主机的世界，却推不动任何人");
  const onClient = client.localEntity();
  assert.ok(onClient !== null, "客户端在装好的世界里找不到自己的实体");
  assert.equal(ownerOf(host.scene, onClient), 1, "客户端找到的实体不是 1 号座的（快照里的归属没带过来）");
});

test("★★ 两个人的输入各动各的角色：主机那位**一步没动**（这条就是「不再同控」的正面判据）", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r2");
  const client = makeClientRig(bus, "r2", 1, { local: () => ({ kind: "move.dir", dx: 1, dz: 0 }) });

  for (let t = 0; t <= 30; t++) {
    pumpJoin(client, t);
    stepAll(t, host, [client], bus);
  }
  const mine = host.seats.entityOf(1);
  assert.ok(mine !== null);
  const heroBefore = host.scene.find(host.heroId)?.localPosition;
  assert.ok(heroBefore !== undefined);
  const heroStartX = heroBefore.x;
  const heroStartZ = heroBefore.y;

  const mineBefore = host.scene.find(mine)?.localPosition;
  assert.ok(mineBefore !== undefined);
  const startX = mineBefore.x;

  // 客户端按住"右"走 20 拍
  for (let t = 31; t <= 50; t++) {
    stepAll(t, host, [client], bus);
  }
  const hs = host.session.stats();
  const mineAfter = host.scene.find(mine)?.localPosition;
  const heroAfter = host.scene.find(host.heroId)?.localPosition;
  assert.ok(mineAfter !== undefined && heroAfter !== undefined);

  assert.ok(
    mineAfter.x > startX + 0.05,
    `客户端的角色没动（x ${startX.toFixed(3)} → ${mineAfter.x.toFixed(3)}）—— 他的意图没落到自己的实体上`,
  );
  // ★ 这一条是这一批的全部：主机自己的角色**一步都不该动**。
  assert.equal(heroAfter.x, heroStartX, "主机自己的角色被客户端的输入推动了 —— 两个人还在同控一个角色");
  assert.equal(heroAfter.y, heroStartZ);

  assert.equal(hs.rejected["not-owner"], 0, `有 ${String(hs.rejected["not-owner"])} 条意图因为归属不符被拒`);
  assert.equal(hs.rejected["no-seat"], 0, `有 ${String(hs.rejected["no-seat"])} 条意图因为端点没有座位被拒`);
  assert.ok(hs.remoteApplied > 5, `主机真正执行了 ${String(hs.remoteApplied)} 条远端意图（太少了）`);
});

test("★ 两个客户端 = 两个座位两个角色：他们各推各的，互不干扰", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r3");
  const one = makeClientRig(bus, "r3", 1, { local: () => ({ kind: "move.dir", dx: 1, dz: 0 }) });
  const two = makeClientRig(bus, "r3", 2, { local: () => ({ kind: "move.dir", dx: 0, dz: 1 }) });

  for (let t = 0; t <= 30; t++) {
    pumpJoin(one, t);
    pumpJoin(two, t);
    stepAll(t, host, [one, two], bus);
  }

  assert.equal(one.joiner.playerId(), 1);
  assert.equal(two.joiner.playerId(), 2, "第二个客户端该拿到 2 号座位（号单调、不复用）");
  assert.equal(countPlayers(host.scene), 3, "主机世界里应该站着三个人");

  const e1 = host.seats.entityOf(1);
  const e2 = host.seats.entityOf(2);
  assert.ok(e1 !== null && e2 !== null);
  assert.notEqual(e1, e2, "两个座位落到了同一个实体上");
  assert.equal(ownerOf(host.scene, e1), 1);
  assert.equal(ownerOf(host.scene, e2), 2);

  const c1 = host.scene.find(e1)?.localPosition;
  const c2 = host.scene.find(e2)?.localPosition;
  assert.ok(c1 !== undefined && c2 !== undefined);
  const start1 = { x: c1.x, z: c1.y };
  const start2 = { x: c2.x, z: c2.y };

  for (let t = 31; t <= 50; t++) {
    stepAll(t, host, [one, two], bus);
  }
  const a1 = host.scene.find(e1)?.localPosition;
  const a2 = host.scene.find(e2)?.localPosition;
  assert.ok(a1 !== undefined && a2 !== undefined);

  // 一号往 +x 走、二号往 +z 走：两人的位移方向必须不同（否则就是"同一份输入推了两个角色"）
  assert.ok(a1.x > start1.x + 0.05, "1 号没往 +x 走");
  assert.equal(a1.y, start1.z, "1 号被推着往 +z 走了 —— 他收到了别人的输入");
  assert.ok(a2.y > start2.z + 0.05, "2 号没往 +z 走");
  assert.equal(a2.x, start2.x, "2 号被推着往 +x 走了 —— 他收到了别人的输入");
  assert.equal(host.session.stats().rejected["not-owner"], 0);
});

test("★ 掉线重连（窗口内）：同一个座位、同一个实体、归属照旧", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r4");
  const client = makeClientRig(bus, "r4", 1);

  for (let t = 0; t <= 20; t++) {
    pumpJoin(client, t);
    stepAll(t, host, [client], bus);
  }
  const entity = host.seats.entityOf(1);
  assert.ok(entity !== null);

  // 断线：两端各自记账（Room 保留座位等超时；Joiner 保留座位号与票据）
  host.room.drop(1, 21);
  client.joiner.drop();
  assert.equal(host.room.stats().lost, 1);
  assert.equal(ownerOf(host.scene, entity), 1, "掉线的瞬间不该动归属 —— 他的角色还站在原地等");

  for (let t = 22; t <= 60; t++) {
    pumpJoin(client, t);
    stepAll(t, host, [client], bus);
  }

  assert.equal(client.joiner.playerId(), 1, "窗口内重连换了座位号 —— 票据那条路没接上");
  assert.equal(client.joiner.stats().reconnects, 1);
  assert.equal(host.room.stats().reconnects, 1);
  assert.equal(host.seats.stats().spawned, 1, "重连又造了一个实体（他会多出一个分身）");
  assert.equal(countPlayers(host.scene), 2);
  assert.equal(host.seats.entityOf(1), entity, "重连后角色换了节点 —— 他会在世界里瞬移");
  assert.equal(ownerOf(host.scene, entity), 1, "重连没把归属写回来：他看得到自己，但按键不动");
  // ★ 这一次 `join` 是**主机补的**（`Room` 的重连路径刻意不调 `onJoin`），
  //   所以它落在"复用"那条上：同一个实体、归属写回去。
  assert.equal(host.seats.stats().reused, 1);
});

test("★ 掉线**超时之后**回来：票据作废 → 新座位、新角色，旧角色留在权威手里", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r5");
  const client = makeClientRig(bus, "r5", 1);

  for (let t = 0; t <= 20; t++) {
    pumpJoin(client, t);
    stepAll(t, host, [client], bus);
  }
  const oldEntity = host.seats.entityOf(1);
  assert.ok(oldEntity !== null);

  host.room.drop(1, 21);
  client.joiner.drop();
  // 超时窗口过去：座位被清掉、归属交还权威。之后"他"由 AI/脚本继续演，
  // 而不是被一个不存在的玩家占着（那会让谁都推不动它，且所有计数都对）。
  const gone = host.room.sweep(21 + 300);
  assert.deepEqual([...gone], [1]);
  for (const pid of gone) host.seats.release(pid);
  assert.equal(ownerOf(host.scene, oldEntity), AUTHORITY);

  for (let t = 22; t <= 60; t++) {
    pumpJoin(client, t);
    stepAll(t, host, [client], bus);
  }

  // ★ 这是**设计**不是 bug：号单调不复用（复用会让一张老票据意外匹配到新玩家）。
  assert.equal(client.joiner.playerId(), 2, "超时之后回来该是新玩家（新座位）");
  assert.equal(host.room.stats().ticketStale, 1, "票据作废没有留下痕迹 —— 界面上没法说清「你的角色没了」");
  assert.equal(host.seats.stats().spawned, 2);
  assert.equal(countPlayers(host.scene), 3, "旧角色还在（归权威）+ 新角色");
  assert.equal(ownerOf(host.scene, oldEntity), AUTHORITY, "旧角色被新座位抢走了");
  const fresh = host.seats.entityOf(2);
  assert.ok(fresh !== null);
  assert.equal(ownerOf(host.scene, fresh), 2);
});

test("★ 没接钩子的主机把 `join` 记成协议违规（不是静默丢弃）", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r5");
  const lone = createBroadcastTransport({ channel: bus.open("r5"), self: 9 });
  const client = makeClientRig(bus, "r5", 1);

  // 换成"没有 onJoinRequest"的会话：这是旧宿主的形状
  const blind = createSession({
    role: "host",
    transport: lone,
    scene: host.scene,
    registry: host.scene.components,
    snapshotEveryTicks: 1,
    // 注意：**没有** playerOf / onJoinRequest
  });
  for (let t = 0; t <= 10; t++) {
    pumpJoin(client, t);
    client.session.step(t, DT);
    blind.step(t, DT);
    bus.flush();
  }
  assert.ok(blind.stats().protocolViolations >= 1, "收到的 join 被静默吞掉了 —— 接错线时就没有任何信号");
  assert.equal(client.joiner.playerId(), null, "没有房间却坐进了座位");
});

test("★ 主机调用 `adopt` 是协议违规（世界只能由权威给出，不能从对面收）", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r6");
  const json = sceneToJson(saveScene(host.scene));
  assert.equal(host.session.adopt(json), false);
  assert.equal(host.session.stats().protocolViolations, 1);
});

test("★ 归属交还：`release` 之后同一实体归权威（引擎里没有「删掉角色」这个动作）", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r7");
  const client = makeClientRig(bus, "r7", 1);
  for (let t = 0; t <= 20; t++) {
    pumpJoin(client, t);
    stepAll(t, host, [client], bus);
  }
  const entity = host.seats.entityOf(1);
  assert.ok(entity !== null);
  host.room.drop(1, 21);
  // 超时窗口（缺省 300 拍）之后照样还在这里 —— 这里只验"交还之后世界还认得他"
  const gone = host.room.sweep(21 + 300);
  assert.deepEqual([...gone], [1]);
  for (const pid of gone) host.seats.release(pid);
  assert.equal(ownerOf(host.scene, entity), AUTHORITY);
  assert.ok(host.scene.find(entity) !== undefined, "释放把实体删掉了");
  assert.equal(assignOwner(host.scene, entity, 5), true, "交还之后仍然可以被重新分配（这是同一个写入点）");
  assert.equal(ownerOf(host.scene, entity), 5);
});

test("房间满了之后加入被拒，且拒绝码是 `full`（不是笼统的 false）", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r8");
  const clients = [
    makeClientRig(bus, "r8", 1),
    makeClientRig(bus, "r8", 2),
    makeClientRig(bus, "r8", 3),
    makeClientRig(bus, "r8", 4),
  ];
  for (let t = 0; t <= 30; t++) {
    for (const c of clients) pumpJoin(c, t);
    stepAll(t, host, clients, bus);
  }
  // 缺省 4 人：主机自己占一个 ⇒ 只能进 3 个
  assert.deepEqual(
    clients.map((c) => c.joiner.playerId()),
    [1, 2, 3, null],
    "第四个客户端不该坐进来（含主机 4 个座位）",
  );
  const refused = clients[3]?.joiner.stats();
  assert.ok(refused !== undefined);
  // ★ 客户端会**一直重试**（重发是安全的，见 `Joiner.request`）：所以这里数的是
  //   "被拒过"而不是"被拒了几次"。次数取决于重发节奏，钉死它等于钉死一个无关常数。
  assert.ok(refused.refusals >= 1, "满员的加入请求没有被拒？");
  assert.equal(refused.lastRefusal, JoinReject.Full, "拒绝码不是 full —— 界面只能说「加入失败」");
});
