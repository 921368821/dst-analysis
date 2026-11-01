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
  assignOwner,
  ownerOf,
  registerNetIdentity,
} from "../../src/extensions/net/identity.ts";
import { createJoiner, JoinReject, type Joiner, type Room } from "../../src/extensions/net/join.ts";
import { DEFAULT_INPUT_MAP } from "../../src/extensions/input/input-map.ts";
import { createSession, type NetSession } from "../../src/extensions/net/session.ts";
import { createBroadcastTransport, type ChannelLike } from "../../src/extensions/net/broadcast-transport.ts";
import { countPlayers, type SeatTable } from "../../src/host/seat-table.ts";
import { assembleClientNet, assembleHostNet, type NetInputProbe } from "../../src/host/net-assembly.ts";
import { pickLocalEntity } from "../../src/host/net-mode.ts";

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
  // ★ 这里**不再手挂** 0 号归属：那是装配的事（`assembleHostNet` 的第一段）。
  //   手挂的话「装配有没有挂」就永远测不到 —— 而它掉了的症状是主机自己的输入
  //   全被 `not-owner` 拒掉（世界在动，但自己不动的那个最容易被当成"卡了"）。
  return { scene, plan: g.value, heroId: hero.value.nodeId, heroCell: hero.value.cell };
}

/** 只收集 `onStep` 回调的假调度器：判据自己决定什么时候推进（与 `attachSession` 同形）。 */
interface FakeScheduler {
  onStep(fn: (tick: number, dt: number) => void): () => void;
  run(tick: number, dt: number): void;
  readonly size: number;
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
    get size() {
      return fns.length;
    },
  };
}

/** 「一直按住 D」的输入探针（真走 `directionFromMap`，不是直接给 `dx: 1`）。 */
const HOLD_RIGHT_KEYS: ReadonlySet<string> = new Set(["KeyD"]);
const HOLD_FORWARD_KEYS: ReadonlySet<string> = new Set(["KeyW"]);
const NO_KEYS: ReadonlySet<string> = new Set<string>();

function probe(keys: ReadonlySet<string>): NetInputProbe {
  return {
    map: DEFAULT_INPUT_MAP,
    snapshot: {
      keysDown: keys,
      keysPressed: NO_KEYS,
      keysReleased: NO_KEYS,
      pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
      wheel: { dx: 0, dy: 0 },
      text: "",
    },
  };
}

interface HostRig {
  readonly scene: Scene;
  readonly session: NetSession;
  readonly room: Room;
  readonly seats: SeatTable;
  readonly heroId: number;
  readonly transport: ReturnType<typeof createBroadcastTransport>;
  readonly scheduler: FakeScheduler;
  /** 装配留下的告警（「座位没落到实体上」之类）。 */
  readonly warnings: readonly string[];
}

/** 主机侧整套装配 —— **走产品代码**（`assembleHostNet`），不是判据里另搭一份。 */
function makeHostRig(bus: ReturnType<typeof createBus>, roomName: string): HostRig {
  const w = makeHostWorld();
  const transport = createBroadcastTransport({ channel: bus.open(roomName), self: 0 });
  const scheduler = makeScheduler();
  const warnings: string[] = [];
  const side = assembleHostNet({
    app: { scene: w.scene, components: w.scene.components, scheduler },
    scene: w.scene,
    transport,
    heroId: w.heroId,
    plan: w.plan,
    nav: null,
    origin: w.heroCell,
    room: roomName,
    snapshotEveryTicks: 1,
    assembled: () => true,
    input: () => null,
    warn: (m) => {
      warnings.push(m);
    },
  });
  const seats = side.seats;
  assert.ok(seats !== null, "有生成计划时座位表不该是 null");
  return {
    scene: w.scene,
    session: side.session,
    room: side.room,
    seats,
    heroId: w.heroId,
    transport,
    scheduler,
    warnings,
  };
}

interface ClientRig {
  readonly joiner: Joiner;
  readonly session: NetSession;
  readonly transport: ReturnType<typeof createBroadcastTransport>;
  readonly scheduler: FakeScheduler;
  /** 客户端当前认为自己能推的实体（每拍现算，与装配一致）。 */
  localEntity(): number | null;
  /** 装载之后装配把主角重指到了哪个实体（`null` = 还没装载过）。 */
  heroAfterLoad(): number | null;
}

/** 客户端侧整套装配 —— 同样走 `assembleClientNet`。 */
function makeClientRig(
  bus: ReturnType<typeof createBus>,
  roomName: string,
  self: number,
  opts: { keys?: ReadonlySet<string> } = {},
): ClientRig {
  const reg = makeRegistry();
  const scene = new Scene(`client-${String(self)}`, reg);
  const transport = createBroadcastTransport({ channel: bus.open(roomName), self });
  const joiner = createJoiner({ self, name: `c${String(self)}` });
  const scheduler = makeScheduler();
  const keys = opts.keys ?? NO_KEYS;
  let hero: number | null = null;
  const side = assembleClientNet({
    app: { scene, components: reg, scheduler },
    scene,
    transport,
    joiner,
    input: () => probe(keys),
    onHero: (id) => {
      hero = id;
    },
    notify: () => {},
  });
  return {
    joiner,
    session: side.session,
    transport,
    scheduler,
    localEntity: () => pickLocalEntity(scene, joiner.playerId()),
    heroAfterLoad: () => hero,
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
    c.scheduler.run(tick, DT);
  }
  host.scheduler.run(tick, DT);
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
  // ★ 读的是「装载之后装配把主角重指到了谁」而不是内部计数：`onWorldLoaded`
  //   只在装载**成功**之后调，而客户端在握手之前没有世界 ⇒ 第一次装载必定是 adopt。
  //   它非 `null` 就同时证明了三件事：世界装上了、重指跑了、重指找到了我的实体。
  assert.notEqual(client.heroAfterLoad(), null, "装载之后没有重指主角 —— 相机会钉在原地，按键看起来没反应");
  const onClient = client.localEntity();
  assert.ok(onClient !== null, "客户端在装好的世界里找不到自己的实体");
  assert.equal(ownerOf(host.scene, onClient), 1, "客户端找到的实体不是 1 号座的（快照里的归属没带过来）");
});

test("★★ 两个人的输入各动各的角色：主机那位**一步没动**（这条就是「不再同控」的正面判据）", () => {
  const bus = createBus();
  const host = makeHostRig(bus, "r2");
  const client = makeClientRig(bus, "r2", 1, { keys: HOLD_RIGHT_KEYS });

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
  const one = makeClientRig(bus, "r3", 1, { keys: HOLD_RIGHT_KEYS });
  const two = makeClientRig(bus, "r3", 2, { keys: HOLD_FORWARD_KEYS });

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

// ---------------------------------------------------------------- 批169：端点号是运行期才知道的

test("★★ `self` 可以是函数：网关分配号之前，握手不许把自己打死", () => {
  // ★★ 这条守的是跨机器那条链路**唯一**的握手前提。
  //   `Joiner.reply()` 里有一句 `msg.to !== selfPeer` —— 端点号写死成快照的话，
  //   客户端在 `hello` 之前那次构造拿到的号（比如 -1）会**永远**留着，
  //   于是每一份合法的加入回复都被当成"不是给我的"丢掉。
  //   症状：客户端连上了、网关日志说转发了、主机日志说分配了座位，
  //   而客户端上什么也没有 —— 三层日志全都正常。
  let self = -1; // `UNASSIGNED`：还没收到 hello
  const joiner = createJoiner({ self: () => self, name: "c" });

  const req = joiner.request(0);
  // ★ 第一条请求的 `from` 是垃圾 —— 这没问题：网关会盖成连接的真实号。
  //   反过来（先等 hello 再发请求）会让"页面一起来就握手"变成"等一个异步事件"。
  assert.equal(req.from, -1, "还没握手就说自己几号才是错的");

  // 网关的 hello 到了，本端知道自己 3 号。
  self = 3;
  const mine = { kind: "join-reply" as const, from: 0, to: 3, tick: 2, seq: 0, accepted: false as const, reason: JoinReject.Full };
  assert.equal(
    joiner.reply(mine),
    true,
    "self 是快照的话这份回复会被判成「不是给我的」（strayReplies 涨），而所有计数都正常",
  );
  assert.equal(joiner.stats().lastRefusal, JoinReject.Full, "回复没被应用：状态机还停在 joining");

  // ★ 反向也要成立：号不对的回复仍然必须被拒 —— 否则上面那条就退化成"什么都接受"。
  const other = { kind: "join-reply" as const, from: 0, to: 1, tick: 3, seq: 1, accepted: false as const, reason: JoinReject.Full };
  assert.equal(joiner.reply(other), false, "to 不对的回复也接受了 ⇒ 两个客户端会应用同一份座位分配");
});

test("★ 端点号没变时（环回 / 跨标签页），函数形态与数字形态行为一致", () => {
  // ★ 这条防的是"为了支持函数把老路径改了"：`self: 1` 与 `self: () => 1` 必须等价。
  const fixed = createJoiner({ self: 1, name: "a" });
  const fn = createJoiner({ self: () => 1, name: "b" });
  const reply = { kind: "join-reply" as const, from: 0, to: 1, tick: 0, seq: 0, accepted: false as const, reason: JoinReject.Full };
  assert.equal(fixed.request(0).from, fn.request(0).from);
  // ★ 别写 `a.strays ?? a.strayReplies`：字段名不存在时两边都是 `undefined`，
  //   `undefined === undefined` 照样绿 —— 那不是"两种形态一致"，是"这条什么也没验"。
  assert.equal(fixed.reply(reply), true, "数字形态没接受 to=1 的回复");
  assert.equal(fn.reply(reply), true, "函数形态没接受 to=1 的回复");
  assert.equal(fixed.state(), fn.state());
  assert.equal(fixed.stats().strayReplies, 0);
  assert.equal(fn.stats().strayReplies, 0);
});
