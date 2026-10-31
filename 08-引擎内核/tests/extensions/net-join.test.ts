/**
 * L4 · 加入握手的契约（批159）
 *
 * ★ 这份判据要回答的是「两台机器能不能一起玩」，而不是「Room 这个类写对了没有」。
 *   所以骨架是一条**端到端**的判据（第 21 条）：环回 + 握手 + 会话 + 快照装载，
 *   客户端从「一根线」变成「一个能推自己角色的玩家」，然后逐字节比对两边的世界。
 *   其余各条打的是这条链上**每一个会静默出错的接口**。
 *
 * ★★ 三条最容易写出「绿着但没在验」的地方，各自配了一条判据：
 *
 *   ① **座位号 ≠ 端点号**：环回里两者都是 0/1，所以「主机盖章」这件事天然不可见。
 *      第 5 条用 peer 5 / 7 直接调 `accept`（Room 是纯记账，不校验端点来自哪根线），
 *      把「号是主机分配的、与端点无关」变成可观察的；第 6 条再钉住「自报的 from 不算」。
 *   ② **先给归属、再拍照**：顺序反了之后，客户端第一份快照里没有任何实体归它 ——
 *      而下一份广播（5 拍后）会把世界补齐，**终态判据全绿**。所以第 9 条在
 *      **入房那一刻**采一份中途样本（终态是常量的量必须采中途样本）。
 *   ③ **掉线超时要交还归属**：`sweep` 只返回名单，`Room` 不碰场景。忘了交接的症状是
 *      「角色谁都推不动」，而玩家的、座位的、带宽的计数**全都是对的**。第 14 条
 *      把「名单交出来」与「边界拍数」一起钉住。
 *
 * ★ 一个刻意的取舍：本文件的端到端判据**不使用** `attachSession`（挂在调度器上），
 *   而是每一拍显式调 `step`。理由与 `net-session.test.ts` 相同：「第几拍看到什么」
 *   是这批判据唯一的语言，而调度器的真实时间在这里只会让判据变慢、变不确定。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { loadScene, saveScene, sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { PlayerController, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import {
  AUTHORITY,
  NetIdentity,
  assignOwner,
  ownedBy,
  ownerOf,
  registerNetIdentity,
} from "../../src/extensions/net/identity.ts";
import {
  JoinReject,
  PROTOCOL_VERSION,
  createJoiner,
  createRoom,
  discoverRooms,
  type JoinRefused,
  type JoinReply,
  type JoinRequest,
  type Room,
  type RoomInfo,
  type RoomOptions,
} from "../../src/extensions/net/join.ts";
import { NetReject, createSession, type LocalCommand } from "../../src/extensions/net/session.ts";
import { createLoopbackPair, type IntentMessage } from "../../src/extensions/net/transport.ts";

const DT = 1 / 30;

// ---------------------------------------------------------------- 语料

interface World {
  readonly scene: Scene;
  readonly reg: ComponentRegistry;
}

function world(name = "main"): World {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  registerNetIdentity(reg);
  return { scene: new Scene(name, reg), reg };
}

/** 一个可被意图驱动的角色：`game.controller` + `net.identity`。 */
function spawnPlayer(scene: Scene, owner: number, id: number): number {
  const n = scene.spawnImmediate("player", scene.rootId, id);
  scene.attach(n.id, () => new PlayerController());
  scene.attach(n.id, () => {
    const i = new NetIdentity();
    i.owner = owner;
    return i;
  });
  scene.flush();
  return n.id;
}

function jsonOf(scene: Scene): string {
  return sceneToJson(saveScene(scene, { mode: "rollback" }));
}

/** 把一份快照装进一个世界（客户端入房时做的事）。 */
function applyJson(w: World, json: string): void {
  const parsed = sceneFromJson(json);
  assert.ok(parsed.ok, "快照必须能解析");
  const r = loadScene(w.scene, parsed.value, w.reg);
  assert.ok(r.ok, "快照必须能装载");
}

/** 从一份快照里读归属（不装载，直接看内容——避免「装载顺手补了归属」这种假绿）。 */
function ownerInJson(w: World, json: string, nodeId: number): number | null {
  applyJson(w, json);
  return ownerOf(w.scene, nodeId);
}

function xOf(scene: Scene, id: number): number {
  const n = scene.find(id);
  assert.ok(n !== undefined, `节点 ${String(id)} 不见了`);
  return n.localPosition.x;
}

/** `dz` 落在 `y` 上（见 `dirStep`），所以「谁动了哪个方向」要靠两个坐标分开看。 */
function yOf(scene: Scene, id: number): number {
  const n = scene.find(id);
  assert.ok(n !== undefined, `节点 ${String(id)} 不见了`);
  return n.localPosition.y;
}

/** 一条默认合法的入房请求。 */
function reqOf(over: Partial<JoinRequest> = {}): JoinRequest {
  return {
    kind: "join",
    from: 1,
    tick: 0,
    seq: 0,
    protocolVersion: PROTOCOL_VERSION,
    name: "小P",
    ...over,
  };
}

function mkRoom(over: Partial<RoomOptions> = {}): Room {
  const w = world("snap");
  spawnPlayer(w.scene, AUTHORITY, 900);
  return createRoom({
    id: "r1",
    name: "测试房",
    maxPlayers: 4,
    snapshot: () => jsonOf(w.scene),
    ...over,
  });
}

function isRefused(r: JoinReply): r is JoinRefused {
  return !r.accepted;
}

function reasonOf(r: JoinReply): string {
  assert.ok(isRefused(r), "这条应当是拒绝");
  return r.reason;
}

// ---------------------------------------------------------------- 1 · 版本

test("[握手] 版本不符两个方向各有各的码，并带上两边的版本号（不消耗座位号）", () => {
  const room = mkRoom({ protocolVersion: 3 });

  const old = room.accept(reqOf({ protocolVersion: 2 }), 1, 0);
  assert.equal(reasonOf(old), JoinReject.VersionOld, "客户端比主机旧");
  assert.deepEqual(old.accepted === false ? old.detail : null, { host: 3, client: 2 }, "界面要能说清谁该更新");

  const newer = room.accept(reqOf({ protocolVersion: 5 }), 1, 0);
  assert.equal(reasonOf(newer), JoinReject.VersionNew, "客户端比主机新（主机该更新了）");

  assert.equal(room.stats().refused[JoinReject.VersionOld], 1);
  assert.equal(room.stats().refused[JoinReject.VersionNew], 1);
  assert.equal(room.stats().players, 1, "被拒的请求不许留下座位");

  // ★ 版本检查在**分配之前**，所以号没被拒掉的尝试消耗。
  const ok = room.accept(reqOf({ protocolVersion: 3 }), 1, 0);
  assert.ok(ok.accepted);
  assert.equal(ok.playerId, 1, "第一次成功的加入拿到 1 号（不是被拒了两次之后的 3 号）");
});

test("[握手] 被拒的回复里没有任何成功字段（运行时也不带，不只是类型上）", () => {
  const room = mkRoom();
  const r = room.accept(reqOf({ protocolVersion: PROTOCOL_VERSION + 1 }), 1, 0);
  assert.ok(!r.accepted);
  assert.equal("playerId" in r, false, "带半份回复就会被某条路径当成功处理");
  assert.equal("json" in r, false, "没有世界就没有快照——客户端不该拿空串去装载");
  assert.equal("ticket" in r, false);
});

test("[握手] 满员 / 关闭 / 主机自己入房：三个码各自计数", () => {
  const room = mkRoom({ maxPlayers: 2 });
  assert.ok(room.accept(reqOf(), 1, 0).accepted, "maxPlayers=2 时主机 + 一个客户端是满的");
  assert.equal(reasonOf(room.accept(reqOf(), 3, 0)), JoinReject.Full);
  assert.equal(room.stats().refused[JoinReject.Full], 1);

  assert.equal(reasonOf(room.accept(reqOf(), 0, 0)), JoinReject.Host, "主机没有「加入」这个动作");
  assert.equal(room.stats().refused[JoinReject.Host], 1);

  room.close();
  assert.equal(reasonOf(room.accept(reqOf(), 3, 0)), JoinReject.Closed);
  assert.equal(room.stats().closed, true);
});

test("[握手] 畸形版本号按「比谁都旧」拒（NaN 不许当成「更新」蒙混过去）", () => {
  const room = mkRoom({ protocolVersion: 2 });
  for (const bad of [Number.NaN, 1.5, Number.POSITIVE_INFINITY]) {
    const r = room.accept(reqOf({ protocolVersion: bad }), 1, 0);
    assert.equal(reasonOf(r), JoinReject.VersionOld, `版本 ${String(bad)} 该被拒`);
  }
  assert.equal(room.stats().players, 1, "三次被拒之后座位表还是只有主机");
});

// ---------------------------------------------------------------- 2 · 身份

test("[身份] 座位号由主机分配、单调、与端点号无关（peer 5 / 7 ⇒ 座位 1 / 2）", () => {
  const room = mkRoom({ maxPlayers: 4 });
  const a = room.accept(reqOf(), 5, 0);
  const b = room.accept(reqOf({ name: "小Q" }), 7, 0);
  assert.ok(a.accepted && b.accepted);
  assert.equal(a.playerId, 1);
  assert.equal(b.playerId, 2);
  assert.equal(room.playerOf(5), 1);
  assert.equal(room.playerOf(7), 2);
  assert.equal(room.playerOf(1), null, "端点 1 从来没入过房");
  assert.deepEqual(room.seats(), [0, 1, 2], "主机永远在 0 号座，客户端的号从 1 起");
});

test("[身份] 请求里自报 from: 0 被无视（自报不等于来源）", () => {
  const room = mkRoom();
  const r = room.accept(reqOf({ from: 0, name: "冒充主机" }), 1, 0);
  assert.ok(r.accepted);
  assert.equal(r.playerId, 1, "号按**传进来的端点**分配，不按请求里写的那个");
  assert.equal(room.playerOf(0), 0, "0 号座还是主机自己");
});

test("[身份] 票据不是令牌：拿在线座位的票据来入房，只得到一个新座位", () => {
  const room = mkRoom();
  const first = room.accept(reqOf(), 1, 0);
  assert.ok(first.accepted);
  const stolen = room.accept(reqOf({ ticket: first.ticket, name: "小偷" }), 3, 0);
  assert.ok(stolen.accepted);
  assert.notEqual(stolen.playerId, first.playerId, "不许把在线的玩家顶掉");
  assert.equal(room.playerOf(1), 1, "原主人还在");
  assert.equal(room.stats().reconnects, 0, "这不是重连");
});

// ---------------------------------------------------------------- 3 · 全量快照

test("[快照] 入房回复带的是**此刻**的世界，不是建房那一刻", () => {
  const w = world("live");
  const hero = spawnPlayer(w.scene, AUTHORITY, 500);
  const room = createRoom({ id: "r", name: "live", snapshot: () => jsonOf(w.scene) });
  // 建房之后世界变了（有人走了一步）
  const n = w.scene.find(hero);
  assert.ok(n !== undefined);
  n.setLocalPosition(7.5, 0);

  const r = room.accept(reqOf(), 1, 3);
  assert.ok(r.accepted);
  const probe = world("probe");
  assert.equal(xOf(applyJsonAnd(probe, r.json), hero), 7.5, "快照必须反映建好之后发生的改动");
});

test("[快照] ★ 先给归属再拍照：入房那一眼，快照里那个角色已经归我（不是等下一份广播）", () => {
  const w = world("grant");
  const mine = spawnPlayer(w.scene, AUTHORITY, 600);
  const room = createRoom({
    id: "r",
    name: "grant",
    snapshot: () => jsonOf(w.scene),
    onJoin: (pid) => {
      assignOwner(w.scene, mine, pid);
    },
  });

  const r = room.accept(reqOf(), 1, 0);
  assert.ok(r.accepted);
  // ★ 中途样本：顺序反了的话这里读到 -1（AUTHORITY），而 5 拍后的广播会把世界补齐，
  //   于是任何「终态一致」的判据都是绿的。
  const probe = world("probe");
  assert.equal(ownerInJson(probe, r.json, mine), r.playerId, "第一份快照里就该是我的角色");
  assert.equal(ownerOf(w.scene, mine), r.playerId, "主机世界里的归属也真的改了");
});

test("[快照] 世界还没准备好 ⇒ behind，不留座位；号不回退（宁可留空号也不复用）", () => {
  let ready: string | null = null;
  const room = mkRoom({ snapshot: () => ready });

  const r = room.accept(reqOf(), 1, 0);
  assert.equal(reasonOf(r), JoinReject.Behind);
  assert.equal(room.stats().players, 1, "被拒时座位要退回（否则满员也进不来人）");
  assert.equal(room.playerOf(1), null);

  const w = world("late");
  ready = jsonOf(w.scene);
  const ok = room.accept(reqOf(), 1, 1);
  assert.ok(ok.accepted);
  assert.equal(ok.playerId, 2, "号单调不复用：复用会让一张老票据意外匹配到新玩家");
});

test("[快照] 客户端取走一次就没了（同一份快照不许应用两遍）", () => {
  const j = createJoiner({ self: 1, name: "小P" });
  j.request(0);
  const room = mkRoom();
  const r = room.accept(reqOf(), 1, 0);
  assert.ok(r.accepted);
  assert.equal(j.reply(r), true);
  assert.notEqual(j.takeSnapshot(), null);
  assert.equal(j.takeSnapshot(), null, "第二遍取不到——应用两遍等于凭空回滚一次");
});

// ---------------------------------------------------------------- 4 · 断线重连

test("[重连] 窗口内带票 ⇒ 同一个座位号、reconnected，且快照反映离线期间的改动", () => {
  const w = world("rc");
  const hero = spawnPlayer(w.scene, AUTHORITY, 700);
  const room = createRoom({
    id: "r",
    name: "rc",
    snapshot: () => jsonOf(w.scene),
    onJoin: (pid) => {
      assignOwner(w.scene, hero, pid);
    },
  });

  const first = room.accept(reqOf(), 1, 0);
  assert.ok(first.accepted);
  assert.equal(room.drop(1, 5), first.playerId, "掉落返回被标掉的玩家号");

  // 离线期间世界继续走（AI / 脚本 / 别的玩家）
  const n = w.scene.find(hero);
  assert.ok(n !== undefined);
  n.setLocalPosition(3, 0);

  const back = room.accept(reqOf({ ticket: first.ticket }), 1, 9);
  assert.ok(back.accepted);
  assert.equal(back.reconnected, true);
  assert.equal(back.playerId, first.playerId, "★ 重连后你还是你（不是拿到了同一个端口）");
  assert.equal(room.stats().reconnects, 1);
  assert.equal(room.stats().ticketStale, 0, "票据是对的，不该记成降级");
  assert.equal(ownerOf(w.scene, hero), 1, "归属没被重连动过");
  const probe = world("probe");
  assert.equal(xOf(applyJsonAnd(probe, back.json), hero), 3, "重连的回复必须是**当下**的世界，不是掉线那一刻的");
});

test("[重连] 掉线期间 playerOf 返回 null（掉线的连接不能再驱动角色）", () => {
  const room = mkRoom();
  const first = room.accept(reqOf(), 1, 0);
  assert.ok(first.accepted);
  assert.equal(room.playerOf(1), 1);
  room.drop(1, 4);
  assert.equal(room.playerOf(1), null, "掉线 = 没有座位：意图该报 no-seat，而不是 not-owner");
  assert.deepEqual(room.seats(), [0], "占位还在，但在线名单里没有他");
  assert.equal(room.stats().lost, 1);
  // 回来之后仍然是他
  const back = room.accept(reqOf({ ticket: first.ticket }), 1, 5);
  assert.ok(back.accepted);
  assert.equal(room.playerOf(1), 1);
  assert.deepEqual(room.seats(), [0, 1]);
});

test("[重连] 超时 sweep 交出名单；边界拍数（window=10、掉线在第 5 拍 ⇒ 14 拍不清、15 拍清）", () => {
  const room = mkRoom({ reconnectWindowTicks: 10 });
  const first = room.accept(reqOf(), 1, 0);
  assert.ok(first.accepted);
  room.drop(1, 5);

  assert.deepEqual(room.sweep(14), [], "还没到点");
  assert.equal(room.playerOf(1), null, "没到点也还是掉线状态");

  assert.deepEqual(room.sweep(15), [first.playerId], "★ 到点那一拍就清，并且把号交出来（调用方要去还归属）");
  assert.equal(room.stats().expired, 1);
  assert.deepEqual(room.seats(), [0]);
});

test("[重连] 超时之后旧票据降级成新玩家：号不同、客户端看得见这件事", () => {
  const room = mkRoom({ reconnectWindowTicks: 5 });
  const first = room.accept(reqOf(), 1, 0);
  assert.ok(first.accepted);
  room.drop(1, 1);
  room.sweep(6);

  const j = createJoiner({ self: 1, name: "小P" });
  j.request(0);
  assert.equal(j.reply(first), true, "第一次进房：座位 1");
  j.drop();
  const req = j.request(8);
  assert.equal(req.ticket, first.ticket, "drop 之后请求必须带票，否则连「想回到原来的座位」都表达不了");

  const back = room.accept(req, 1, 8);
  assert.ok(back.accepted);
  assert.equal(back.reconnected, false);
  assert.equal(back.playerId, 2, "座位 1 已经超时没了");
  assert.equal(room.stats().ticketStale, 1, "降级必须可见——它意味着「你的角色没了」");

  assert.equal(j.reply(back), true);
  assert.equal(j.playerId(), 2, "★ 以主机为准：客户端不许继续用旧号发意图");
  assert.equal(j.stats().seatChanges, 1, "换了号这件事要能被面板说出来");
});

test("[重连] 同一端点重复入房是幂等的（不把人踢成一个新号）", () => {
  const room = mkRoom();
  const first = room.accept(reqOf(), 1, 0);
  assert.ok(first.accepted);
  const again = room.accept(reqOf(), 1, 2);
  assert.ok(again.accepted);
  assert.equal(again.playerId, first.playerId);
  assert.equal(again.reconnected, true);
  assert.equal(room.stats().duplicates, 1);
  assert.equal(room.stats().players, 2, "座位表还是「主机 + 他」");
});

// ---------------------------------------------------------------- 5 · 房间发现

test("[发现] 版本不符与满员的房间照列（不过滤），按 id 升序，码的方向是「你相对于它」", () => {
  const rooms: RoomInfo[] = [
    { id: "c", name: "满的", protocolVersion: PROTOCOL_VERSION, players: 4, maxPlayers: 4 },
    { id: "a", name: "老的", protocolVersion: PROTOCOL_VERSION - 1, players: 1, maxPlayers: 4 },
    { id: "d", name: "新的", protocolVersion: PROTOCOL_VERSION + 1, players: 1, maxPlayers: 4 },
    { id: "b", name: "能进", protocolVersion: PROTOCOL_VERSION, players: 1, maxPlayers: 4 },
  ];
  const got = discoverRooms(rooms);
  assert.deepEqual(got.map((r) => r.id), ["a", "b", "c", "d"], "按 id 升序，不按上报顺序");
  assert.equal(got.length, 4, "★ 不许静默过滤：过滤之后玩家看到的是「没有房间」");

  const byId = new Map(got.map((r) => [r.id, r]));
  assert.equal(byId.get("b")?.joinable, true);
  assert.equal(byId.get("a")?.joinable, false);
  assert.equal(byId.get("a")?.reason, JoinReject.VersionNew, "房间比我旧 ⇒ 我比它新");
  assert.equal(byId.get("d")?.reason, JoinReject.VersionOld, "房间比我新 ⇒ 我比它旧");
  assert.equal(byId.get("c")?.reason, JoinReject.Full);
});

// ---------------------------------------------------------------- 6 · 客户端状态机

test("[客户端] 不是给我的、以及没在等的回复都不应用（迟到的那份不许把世界回滚一次）", () => {
  const j = createJoiner({ self: 1, name: "小P" });
  const room = mkRoom();

  const req = j.request(0);
  const good = room.accept(req, 1, 0);
  assert.ok(good.accepted);

  assert.equal(j.reply({ ...good, to: 3 }), false, "不是给我的");
  assert.equal(j.state(), "joining", "状态不许动");
  assert.equal(j.reply(good), true);
  assert.equal(j.state(), "joined");
  assert.equal(j.reply(good), false, "同一份回复第二次到达");
  assert.equal(j.stats().strayReplies, 2);
  assert.equal(j.takeSnapshot() !== null, true, "第一份快照没被那次重放吃掉");
});

test("[客户端] 半份回复不半连着：不动状态、继续等，之后正常回复仍能进房", () => {
  const j = createJoiner({ self: 1, name: "小P" });
  const room = mkRoom();
  const req = j.request(0);
  const good = room.accept(req, 1, 0);
  assert.ok(good.accepted);

  // ★ 两种坏形状都要验：只验一种时，另一个条件删掉了也看不出来
  //   （「不是字符串」与「空串」是两行判断，缺一条就有一条路放行空世界）。
  const halves: readonly JoinReply[] = [
    { ...good, json: 123 as unknown as string },
    { ...good, json: "" },
  ];
  for (const half of halves) {
    assert.equal(j.reply(half), false, "半份回复不许应用");
    assert.equal(j.state(), "joining", "★ 半连着比没连上难查得多");
  }
  assert.equal(j.stats().badReplies, 2);
  assert.equal(j.playerId(), null);

  assert.equal(j.reply(good), true);
  assert.equal(j.state(), "joined");
  assert.equal(j.playerId(), 1);
});

test("[客户端] 状态机走一圈：idle → joining → joined → lost → joining → joined（掉线不清身份）", () => {
  const j = createJoiner({ self: 1, name: "小P" });
  const room = mkRoom();
  assert.equal(j.state(), "idle");

  const first = room.accept(j.request(0), 1, 0);
  assert.ok(first.accepted);
  assert.equal(j.state(), "joining");
  j.reply(first);
  assert.equal(j.state(), "joined");

  j.drop();
  assert.equal(j.state(), "lost");
  assert.equal(j.playerId(), 1, "掉线不清身份");
  assert.equal(j.ticket(), first.ticket, "也不清票据");

  const again = room.accept(j.request(4), 1, 4);
  assert.ok(again.accepted);
  j.reply(again);
  assert.equal(j.state(), "joined");
  assert.equal(j.playerId(), 1);
  assert.equal(j.stats().joins, 1, "第一次是新玩家");
  assert.equal(j.stats().reconnects, 1, "第二次是重连");
});

// ---------------------------------------------------------------- 7 · 端到端

test("[端到端] ★ 环回 + 握手：从「一根线」到「能推自己的角色」，两边世界逐字节一致", () => {
  const [hostT, clientT] = createLoopbackPair();
  // ★ 两边的场景**同名**：`sceneToJson` 把 `name` 也写进快照，而副本是整场替换 ——
  //   名字不同时逐字节比对会红在那一个字段上，看起来像「世界不一致」。
  const host = world("main");
  const client = world("main");
  const hostHero = spawnPlayer(host.scene, 0, 100);
  const peerHero = spawnPlayer(host.scene, AUTHORITY, 101);

  const room = createRoom({
    id: "r1",
    name: "测试房",
    maxPlayers: 4,
    snapshot: () => jsonOf(host.scene),
    onJoin: (pid) => {
      assignOwner(host.scene, peerHero, pid);
    },
  });
  const joiner = createJoiner({ self: 1, name: "小P" });

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: 1,
    playerOf: room.playerOf,
    // 主机推的是另一个方向（dz=0）：两条轨迹必须不同，否则「意图打到错的人身上」
    // 这种错会算出完全一样的坐标。
    local: (t) => ({ entity: hostHero, intent: { kind: "move.dir", dx: t % 2 === 0 ? 1 : 0.5, dz: 0 } }),
  });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    playerOf: () => joiner.playerId(),
    // ★ 关掉预测：这条判据问的是「握手之后副本对不对」，而预测开着时客户端本端角色
    //   永远比主机多走一步（合法的）。预测的正面判据在 `net-predict.test.ts`。
    predict: false,
    local: (): LocalCommand | null => {
      const pid = joiner.playerId();
      if (pid === null) return null;
      const id = ownedBy(client.scene, pid)[0];
      return id === undefined ? null : { entity: id, intent: { kind: "move.dir", dx: 0, dz: 1 } };
    },
  });

  let ownedAtJoin = -1;
  for (let t = 0; t <= 24; t++) {
    if (t === 0) clientT.send(joiner.request(0));

    // ★ 顺序是契约的一部分：握手先取，会话后取（传输按种类取，谁也不吃谁的消息）
    for (const m of hostT.receive(t, ["join"])) {
      if (m.kind !== "join") continue;
      hostT.send(room.accept(m, m.from, t));
    }
    for (const m of clientT.receive(t, ["join-reply"])) {
      if (m.kind !== "join-reply") continue;
      joiner.reply(m);
    }
    const snap = joiner.takeSnapshot();
    if (snap !== null) {
      applyJson(client, snap);
      ownedAtJoin = ownedBy(client.scene, 1).length;
    }

    clientS.step(t, DT);
    hostS.step(t, DT);
  }
  clientS.step(25, DT);

  assert.equal(joiner.state(), "joined");
  assert.equal(joiner.playerId(), 1);
  assert.equal(ownedAtJoin, 1, "★ 入房那一刻客户端就知道自己拥有一个角色（不必等下一份广播）");
  assert.equal(hostS.stats().rejected[NetReject.NoSeat], 0, "进了房的人不该报「没有座位」");
  assert.equal(hostS.stats().rejected[NetReject.NotOwner], 0, "自己的角色不该被当成别人的");
  assert.ok(hostS.stats().remoteApplied >= 20, "远程输入真的被执行了（否则「一致」是两边都没动）");
  // ★ 两条轨迹的方向不同（主机推 x、客户端推 z），于是「意图打到错的人身上」
  //   与「两个人的输入推同一个角色」都会让这里的某个坐标变成 0。
  assert.ok(yOf(host.scene, peerHero) > 0.5, "客户端推的是自己那个角色，而且真的朝它自己的方向动了");
  assert.equal(yOf(host.scene, hostHero), 0, "主机那个角色不该被客户端的意图推动");
  assert.ok(xOf(host.scene, hostHero) > 0.5, "主机自己的角色也在动");
  assert.equal(xOf(host.scene, peerHero), 0, "客户端的角色不该被主机的意图推动");
  assert.equal(jsonOf(client.scene), jsonOf(host.scene), "★ 副本与主机逐字节一致");
});

test("[端到端] 没握手就发意图 ⇒ 全部 no-seat、世界一动不动（但不是 not-owner）", () => {
  const [hostT, clientT] = createLoopbackPair();
  const host = world("host");
  const peerHero = spawnPlayer(host.scene, 1, 101);
  const room = mkRoom();
  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    playerOf: room.playerOf,
  });

  const forged: IntentMessage = {
    kind: "intent",
    from: 1,
    tick: 0,
    seq: 0,
    entity: peerHero,
    intent: { kind: "move.dir", dx: 1, dz: 0 },
  };
  clientT.send(forged);

  // 场上还有一只归权威的怪：没有座位的客户端不许把「归 AUTHORITY 的实体」算成自己的
  spawnPlayer(host.scene, AUTHORITY, 102);

  // ★ 一个没有座位的客户端不许把「归 AUTHORITY 的实体」算成自己的
  const empty = createJoiner({ self: 1, name: "没进门" });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: host.scene,
    registry: host.reg,
    playerOf: () => empty.playerId(),
  });
  assert.equal(clientS.stats().owned, 0);

  hostS.step(0, DT);
  assert.equal(xOf(host.scene, peerHero), 0, "没座位的人一寸也推不动");
  assert.equal(hostS.stats().rejected[NetReject.NoSeat], 1, "★ 报的是「没有座位」，不是「抢别人的角色」");
  assert.equal(hostS.stats().rejected[NetReject.NotOwner], 0);
});

test("[会话] 归属按**座位号**判定，不按端点号（端点 1 / 座位 7）", () => {
  const [hostT, clientT] = createLoopbackPair();
  const host = world("main");
  const his = spawnPlayer(host.scene, 7, 300);
  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    playerOf: () => 7,
  });

  clientT.send({
    kind: "intent",
    from: 1,
    tick: 0,
    seq: 0,
    entity: his,
    intent: { kind: "move.dir", dx: 1, dz: 0 },
  });
  hostS.step(0, DT);

  // 直接比 `from` 时这里是 7 !== 1 ⇒ 全被拒；而「重连后你还是你」恰恰依赖这个映射。
  assert.ok(xOf(host.scene, his) > 0, "座位 7 的意图该被接受");
  assert.equal(hostS.stats().remoteApplied, 1);
  assert.equal(hostS.stats().rejected[NetReject.NotOwner], 0);
});

test("[传输] 按种类取：不匹配的留在队里、取走的不重复（两个消费者不吃对方的消息）", () => {
  const [a, b] = createLoopbackPair();
  const room = mkRoom();
  a.send(reqOf({ tick: 7 }));
  a.send({
    kind: "intent",
    from: 0,
    tick: 7,
    seq: 1,
    entity: 1,
    intent: { kind: "move.dir", dx: 1, dz: 0 },
  });

  const joins = b.receive(7, ["join"]);
  assert.equal(joins.length, 1);
  assert.equal(joins[0]?.kind, "join");

  const rest = b.receive(7);
  assert.equal(rest.length, 1, "先跑的那个不该把另一类吃掉");
  assert.equal(rest[0]?.kind, "intent");

  assert.equal(b.receive(7).length, 0, "取走的不再重复");
  // 这条判据顺带钉住「房间表能直接喂给发现列表」
  const list = discoverRooms([room.info()]);
  assert.equal(list[0]?.joinable, true);
});

// ---------------------------------------------------------------- 小工具

/** `applyJson` 的表达式版：返回装好的场景（省一个临时变量）。 */
function applyJsonAnd(w: World, json: string): Scene {
  applyJson(w, json);
  return w.scene;
}
