/**
 * L4 · 会话的契约（批152）
 *
 * ★ 这份判据要回答的是「把传输接到世界上之后，玩法有没有变」，而不是「Session 这个类写对了没有」。
 *   所以核心是两条比对：
 *
 *   ① **主机算出来的世界 == 单机算出来的世界**（逐 tick 逐字节）——
 *      证明「远程输入不改变结果」。这一条一旦松，联机与单机的平衡性就是两份。
 *   ② **客户端的副本 == 主机**（逐字节）——
 *      证明副本忠实，且客户端没有偷偷自己算一份。
 *
 * ★★ 两条判据里两个角色的轨迹**必须不同**（一个 8 拍相位差）：
 *   若两条轨迹相同，"意图被应用到错误的实体上"与"用错发件人的归属"这两种错
 *   都会算出完全一样的坐标 —— 判据全绿，而线上是另一个人的角色在动。
 *
 * ★ 一个诚实的代价写在判据里：**第 0 拍客户端不发意图**，因为它要等第一份快照
 *   才知道自己拥有谁（`ownedBy`）。这不是缺陷，是「客户端从快照学归属」的必然结果；
 *   真正上线时该由加入握手先给一次归属，那属于会话建立，不在这一层。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { saveScene, sceneToJson } from "../../src/core/scene/scene-io.ts";
import type { InputSnapshot } from "../../src/platform/input/device.ts";
import { DEFAULT_INPUT_MAP } from "../../src/extensions/input/input-map.ts";
import { PlayerController, directionFromMap, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import { MOVER_TYPE, Mover, registerMoverComponent } from "../../src/extensions/ai/move.ts";
import { dirStep, type MoveIntent } from "../../src/extensions/motion/intent.ts";
import { AUTHORITY, NET_IDENTITY_TYPE, NetIdentity, ownedBy, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import { NetReject, createSession, type LocalCommand } from "../../src/extensions/net/session.ts";
import {
  createLoopbackPair,
  type IntentMessage,
  type NetMessage,
  type PeerId,
  type SnapshotMessage,
  type Transport,
  type TransportStats,
} from "../../src/extensions/net/transport.ts";

const DT = 1 / 30;
const SPEED = 4.5;

// ---------------------------------------------------------------- 语料

function snapOf(keys: readonly string[]): InputSnapshot {
  return {
    keysDown: new Set(keys),
    keysPressed: new Set<string>(),
    keysReleased: new Set<string>(),
    pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
    wheel: { dx: 0, dy: 0 },
    text: "",
  };
}

/**
 * 8 拍的输入脚本（含斜走与空拍）。
 *
 * ★ 斜走是归一化唯一能暴露差异的地方；空拍是"零位移不该被当成一条位移"的地方。
 */
function keysAt(tick: number): readonly string[] {
  const dirs: readonly (readonly string[])[] = [
    ["KeyD"],
    ["KeyD", "KeyW"],
    ["KeyW"],
    ["KeyA", "KeyW"],
    ["KeyA"],
    ["KeyA", "KeyS"],
    ["KeyS"],
    [],
  ];
  return dirs[((tick % dirs.length) + dirs.length) % dirs.length] ?? [];
}

function intentOf(tick: number): MoveIntent {
  const d = directionFromMap(DEFAULT_INPUT_MAP, snapOf(keysAt(tick)));
  return { kind: "move.dir", dx: d.dx, dz: d.dz };
}

// ---------------------------------------------------------------- 夹具

interface World {
  readonly scene: Scene;
  readonly reg: ComponentRegistry;
}

function world(name = "main"): World {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  registerNetIdentity(reg);
  registerMoverComponent(reg);
  return { scene: new Scene(name, reg), reg };
}

/** 造一个可被意图驱动的角色：`game.controller` + `net.identity`。 */
function spawnPlayer(scene: Scene, owner: PeerId, id: number): number {
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

function xOf(scene: Scene, id: number): number {
  const n = scene.find(id);
  assert.ok(n !== undefined, `节点 ${String(id)} 不见了`);
  return n.localPosition.x;
}

function jsonOf(scene: Scene): string {
  return sceneToJson(saveScene(scene, { mode: "rollback" }));
}

/**
 * 一个只有「收件箱 + 发件箱」的传输端。
 *
 * ★ 存在的理由：有几条判据要「按我指定的顺序、投我指定的消息」（乱序快照、
 *   协议违规、坏 JSON）。用环回做不到完美控制（它按 tick 排队），而这里要验的
 *   是会话对**任意**投递顺序的反应，不是环回。传输是接口，本来就是接缝。
 */
class FakeEnd implements Transport {
  readonly self: PeerId;
  readonly out: NetMessage[] = [];
  private inbox: NetMessage[] = [];

  constructor(self: PeerId) {
    this.self = self;
  }

  send(msg: NetMessage): boolean {
    this.out.push(msg);
    return true;
  }

  receive(): readonly NetMessage[] {
    const got = this.inbox;
    this.inbox = [];
    return got;
  }

  stats(): TransportStats {
    return { sent: this.out.length, received: 0, dropped: 0, queued: this.inbox.length };
  }

  dispose(): void {
    this.inbox = [];
  }

  push(...msgs: NetMessage[]): void {
    this.inbox.push(...msgs);
  }
}

/** 从一份世界造一条快照消息（主机就是这样发的）。 */
function snapshotMsgOf(scene: Scene, seq: number, tick: number): SnapshotMessage {
  return {
    kind: "snapshot",
    from: 0,
    tick,
    seq,
    // 与 `session.broadcast` 同一条规矩：网络快照是「第 T 拍的世界」，用回滚语义。
    json: jsonOf(scene),
  };
}

// ---------------------------------------------------------------- 1 · 快照节奏

test("[会话] 主机每 4 拍广播一次快照，客户端应用到最后一份（0/4/8/12/16/20/24 共 7 份）", () => {
  const [hostT, clientT] = createLoopbackPair();
  const host = world();
  const client = world();
  spawnPlayer(host.scene, 0, 100);
  spawnPlayer(host.scene, 1, 101);

  const hostS = createSession({ role: "host", transport: hostT, scene: host.scene, registry: host.reg, snapshotEveryTicks: 4 });
  const clientS = createSession({ role: "client", transport: clientT, scene: client.scene, registry: client.reg });

  for (let t = 0; t <= 24; t++) {
    clientS.step(t, DT);
    hostS.step(t, DT);
  }
  // 主机在第 24 拍发出的那份，客户端还没机会取（它同拍的 receive 已经过了）
  assert.equal(hostS.stats().snapshotsSent, 7, "0..24 之间 4 的倍数有 7 个");
  assert.equal(clientS.stats().snapshotsApplied, 6, "最后一拍的那份还没到——客户端本来就晚一拍");

  clientS.step(25, DT);
  assert.equal(clientS.stats().snapshotsApplied, 7);
  assert.equal(clientS.stats().lastSnapshotTick, 24, "客户端世界应停在主机第 24 拍的样子");
});

// ---------------------------------------------------------------- 2 · 副本忠实

test("[会话] ★ 客户端的副本与主机逐字节一致（两条不同轨迹，含斜走）", () => {
  const [hostT, clientT] = createLoopbackPair();
  const host = world();
  const client = world();
  const hostHero = spawnPlayer(host.scene, 0, 100);
  const peerHero = spawnPlayer(host.scene, 1, 101);

  // ★ 再放一只**带寻路状态**的怪（它跟网络无关，只是世界的一部分）。
  //   作用是把「网络快照该用**回滚**语义导出」钉死：用存档语义导出时它进快照只剩 speed，
  //   客户端的副本会少一整个 path —— 而两个角色的位置仍然一模一样，位置判据全绿。
  const mob = host.scene.spawnImmediate("mob", host.scene.rootId, 102);
  host.scene.attach(mob.id, () => {
    const m = new Mover();
    m.path = [3, 4, 5];
    m.cursor = 1;
    m.goalCell = 5;
    m.stuckTicks = 2;
    return m;
  });
  host.scene.flush();

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: 1,
    local: (t) => ({ entity: hostHero, intent: intentOf(t) }),
  });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    // ★ 归属从快照里读出来（客户端不硬编码自己拥有谁）
    local: (t): LocalCommand | null => {
      const mine = ownedBy(client.scene, 1);
      const id = mine[0];
      return id === undefined ? null : { entity: id, intent: intentOf(t + 5) };
    },
  });

  for (let t = 0; t <= 24; t++) {
    clientS.step(t, DT);
    hostS.step(t, DT);
  }
  clientS.step(25, DT);

  assert.equal(hostS.stats().protocolViolations, 0, "正常一条线不该有协议违规");
  assert.equal(clientS.stats().badSnapshots, 0, "快照全都该能读回来");
  assert.ok(hostS.stats().remoteApplied >= 20, "远程输入确实被执行了（否则「一致」是两份都没动）");
  const peer = host.scene.find(peerHero);
  assert.ok(peer !== undefined);
  assert.ok(
    Math.hypot(peer.localPosition.x, peer.localPosition.y) > 1e-9,
    "对面那个角色一步都没动 —— 那样副本与主机当然一致",
  );
  assert.ok(
    Math.abs(xOf(host.scene, hostHero) - xOf(host.scene, peerHero)) > 1e-9,
    "两条轨迹必须不同，否则「意图打到错的人身上」这种错看不出来",
  );
  const replica = client.scene.find(102)?.get<Mover>(MOVER_TYPE);
  assert.deepEqual(replica?.path, [3, 4, 5], "副本里的寻路状态要一起过来（快照用的是回滚语义）");
  assert.equal(jsonOf(client.scene), jsonOf(host.scene), "客户端副本必须与主机逐字节一致");
});

// ---------------------------------------------------------------- 3 · 权威不改变结果

test("[会话] ★ 主机算出的世界与单机逐 tick 逐字节一致（远程输入不改变结果）", () => {
  const [hostT, clientT] = createLoopbackPair();
  const host = world();
  const client = world();
  const hostHero = spawnPlayer(host.scene, 0, 100);
  const peerHero = spawnPlayer(host.scene, 1, 101);

  // 单机基线：同样的两个角色、同样的两条轨迹，只是没有网络。
  const base = world();
  spawnPlayer(base.scene, 0, 100);
  spawnPlayer(base.scene, 1, 101);

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: 1,
    local: (t) => ({ entity: hostHero, intent: intentOf(t) }),
  });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    local: (t): LocalCommand | null => {
      const id = ownedBy(client.scene, 1)[0];
      return id === undefined ? null : { entity: id, intent: intentOf(t + 5) };
    },
  });

  for (let t = 0; t <= 24; t++) {
    clientS.step(t, DT);
    hostS.step(t, DT);

    // 基线按「本地角色跟 intentOf(t)，远程角色跟 intentOf(t+5)」推进。
    // ★ 第 0 拍远程角色不动：客户端此刻还不知道自己拥有谁（见文件头）。
    const moves: readonly (readonly [number, MoveIntent | null])[] = [
      [hostHero, intentOf(t)],
      [peerHero, t === 0 ? null : intentOf(t + 5)],
    ];
    for (const [id, it] of moves) {
      if (it === null) continue;
      const r = dirStep(it, SPEED, DT);
      const n = base.scene.find(id);
      assert.ok(n !== undefined);
      n.setLocalPosition(n.localPosition.x + r.dx, n.localPosition.y + r.dz);
    }

    assert.equal(jsonOf(host.scene), jsonOf(base.scene), `第 ${String(t)} 拍主机与单机就分叉了`);
  }
  assert.ok(hostS.stats().remoteApplied > 20, "远程输入确实被执行了（否则「一致」是因为谁都没动）");
});

// ---------------------------------------------------------------- 4 · 本地输入

test("[会话] 主机本地输入不经网络（没有 RTT），但过同一道授权：驱动别人的角色会被拒", () => {
  const [hostT] = createLoopbackPair();
  const host = world();
  const mine = spawnPlayer(host.scene, 0, 100);
  const theirs = spawnPlayer(host.scene, 1, 101);

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    local: (): LocalCommand => ({ entity: theirs, intent: { kind: "move.dir", dx: 1, dz: 0 } }),
  });
  hostS.step(0, DT);

  assert.equal(xOf(host.scene, theirs), 0, "主机不能推别人的角色");
  assert.equal(hostS.stats().rejected[NetReject.NotOwner], 1);
  assert.equal(hostS.stats().localApplied, 0);
  assert.equal(xOf(host.scene, mine), 0, "别人的角色不动，也不该顺手推动自己的");
});

// ---------------------------------------------------------------- 5 · 伪造

test("[会话] 客户端伪造 entity 指定别人的角色：一寸不动、计数 +1、自己的角色照常", () => {
  const [hostT, clientT] = createLoopbackPair();
  const host = world();
  const hostHero = spawnPlayer(host.scene, 0, 100);
  const peerHero = spawnPlayer(host.scene, 1, 101);

  const hostS = createSession({ role: "host", transport: hostT, scene: host.scene, registry: host.reg });
  // 绕过客户端会话，直接往线上投一条自称能驱动 hostHero 的意图（最坏情况）
  const forged: IntentMessage = {
    kind: "intent",
    from: 1,
    tick: 0,
    seq: 0,
    entity: hostHero,
    intent: { kind: "move.dir", dx: 1, dz: 0 },
  };
  clientT.send(forged);
  const legit: IntentMessage = { ...forged, seq: 1, entity: peerHero };
  clientT.send(legit);

  hostS.step(0, DT);
  assert.equal(xOf(host.scene, hostHero), 0, "冒充者驱动不了主机自己的角色");
  assert.equal(xOf(host.scene, peerHero), SPEED * DT, "它自己的角色照常能走（不是一刀切拒掉）");
  assert.equal(hostS.stats().rejected[NetReject.NotOwner], 1);
  assert.equal(hostS.stats().remoteApplied, 1);
});

// ---------------------------------------------------------------- 6 · 卡顿不瞬移

test("[会话] 一拍到 5 条只执行 1 条（不瞬移）；队列超限丢最老的，剩下的照常补", () => {
  const [hostT, clientT] = createLoopbackPair();
  const host = world();
  const peerHero = spawnPlayer(host.scene, 1, 101);

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    maxQueuedIntents: 3,
    snapshotEveryTicks: 100, // 这条判据不关心快照
  });

  // ★ 五条意图**方向不同**（前四条向右、最后一条向左）：只有这样才能分辨
  //   「丢最老的」与「丢最新的」—— 五条一模一样时，两种丢法算出的位移完全相同。
  for (let i = 0; i < 5; i++) {
    clientT.send({
      kind: "intent",
      from: 1,
      tick: 10,
      seq: i,
      entity: peerHero,
      intent: { kind: "move.dir", dx: i === 4 ? -1 : 1, dz: 0 },
    } satisfies IntentMessage);
  }

  hostS.step(10, DT);
  assert.ok(
    Math.abs(xOf(host.scene, peerHero) - SPEED * DT) < 1e-9,
    `一次卡顿后的 5 条不能一起执行（那是瞬移 5 拍），实际位移 ${String(xOf(host.scene, peerHero))}`,
  );
  assert.equal(hostS.stats().backlogDropped, 2, "队列上限 3，进来 5 条 ⇒ 丢 2 条最老的");
  // 5 条进来 → 丢掉第 0、1 条 → 队列剩 [第2、3、4 条] → 本拍消化第 2 条 ⇒ 还剩 2 条
  assert.equal(hostS.stats().queued, 2);
  assert.equal(hostS.stats().remoteApplied, 1);

  hostS.step(11, DT);
  hostS.step(12, DT);
  hostS.step(13, DT);
  assert.equal(hostS.stats().queued, 0);
  assert.equal(hostS.stats().remoteApplied, 3, "1 条当场 + 队列里 2 条，共 3 条被执行");
  // 被执行的三条是「右、右、左」，合位移 **一** 拍。
  // 若改成丢最新的（留下右、右、右），这里会是三拍 —— 这正是这条断言的分辨力所在。
  assert.ok(
    Math.abs(xOf(host.scene, peerHero) - SPEED * DT) < 1e-9,
    `留下的该是最后三条（右、右、左 = 一拍），实际 ${String(xOf(host.scene, peerHero) / (SPEED * DT))} 拍`,
  );
});

// ---------------------------------------------------------------- 7 · 丢包可发现

test("[会话] 丢包可发现：上行缺口记 intentGaps、下行缺口记 snapshotGaps（而不是把后一条当前一条）", () => {
  const [hostT, clientT] = createLoopbackPair({ lossRate: 0.35, seed: 5 });
  const host = world();
  const client = world();
  const hostHero = spawnPlayer(host.scene, 0, 100);
  spawnPlayer(host.scene, 1, 101);

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: 1,
    local: (t) => ({ entity: hostHero, intent: intentOf(t) }),
  });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    local: (t): LocalCommand | null => {
      const id = ownedBy(client.scene, 1)[0];
      return id === undefined ? null : { entity: id, intent: intentOf(t + 5) };
    },
  });

  for (let t = 0; t <= 24; t++) {
    clientS.step(t, DT);
    hostS.step(t, DT);
  }
  clientS.step(25, DT);

  assert.ok(hostS.stats().intentGaps > 0, "上行丢了却报 0 —— 丢包就永远查不出来");
  assert.ok(clientS.stats().snapshotGaps > 0, "下行丢了却报 0");
  assert.equal(hostS.stats().rejected[NetReject.NotOwner], 0, "丢包不等于伪造：不该算成被拒");
});

// ---------------------------------------------------------------- 8 · 乱序

test("[会话] 乱序 / 重放的旧快照不许覆盖新世界", () => {
  const host = world();
  const a = spawnPlayer(host.scene, 1, 101);
  const oldSnap = snapshotMsgOf(host.scene, 0, 5);

  host.scene.find(a)?.setLocalPosition(9, 9);
  const newSnap = snapshotMsgOf(host.scene, 1, 6);

  const end = new FakeEnd(1);
  const client = world();
  const clientS = createSession({ role: "client", transport: end, scene: client.scene, registry: client.reg });

  end.push(oldSnap);
  clientS.step(0, DT);
  end.push(newSnap);
  clientS.step(1, DT);
  end.push(oldSnap); // 重放：一条迟到的旧世界
  clientS.step(2, DT);

  assert.equal(clientS.stats().staleSnapshots, 1);
  assert.equal(xOf(client.scene, a), 9, "旧快照把新世界盖回去了 —— 卡一下就会回退一次");
  assert.equal(clientS.stats().lastSnapshotTick, 6);
});

// ---------------------------------------------------------------- 9 · 归属

test("[会话] 归属：主机 assign 生效并随快照传到客户端；客户端 assign 被拒并计违规", () => {
  const [hostT, clientT] = createLoopbackPair();
  const host = world();
  const client = world();
  const hero = spawnPlayer(host.scene, AUTHORITY, 100);

  const hostS = createSession({ role: "host", transport: hostT, scene: host.scene, registry: host.reg, snapshotEveryTicks: 1 });
  const clientS = createSession({ role: "client", transport: clientT, scene: client.scene, registry: client.reg });

  // 主机把 NPC 交给 1 号对端（加入 / 交接用的就是这一个动作）
  assert.equal(hostS.assign(hero, 1), true);
  assert.equal(hostS.stats().owned, 0, "主机此刻不拥有它");
  clientS.step(0, DT);
  hostS.step(0, DT);
  clientS.step(1, DT);

  assert.deepEqual(ownedBy(client.scene, 1), [hero], "客户端要从快照里读到自己拥有了谁");
  assert.equal(ownedBy(client.scene, AUTHORITY).length, 0, "改归属之后旧主人不该还拥有它");
  assert.equal(clientS.stats().owned, 1);

  assert.equal(clientS.assign(hero, 1), false, "客户端不许改归属");
  assert.equal(clientS.stats().protocolViolations, 1, "被拒也要可见，不能只是返回 false");
});

// ---------------------------------------------------------------- 10 · 协议违规

test("[会话] 协议违规可见：主机收到快照、客户端收到意图，都要计数（不是静默忽略）", () => {
  const host = world();
  spawnPlayer(host.scene, 0, 100);
  const hostEnd = new FakeEnd(0);
  const hostS = createSession({ role: "host", transport: hostEnd, scene: host.scene, registry: host.reg });
  hostEnd.push(snapshotMsgOf(host.scene, 0, 0));
  hostS.step(0, DT);
  assert.equal(hostS.stats().protocolViolations, 1, "主机收到快照 ⇒ 场上有第二个主机");

  const client = world();
  const clientEnd = new FakeEnd(1);
  const clientS = createSession({ role: "client", transport: clientEnd, scene: client.scene, registry: client.reg });
  const wandering: IntentMessage = {
    kind: "intent",
    from: 0,
    tick: 0,
    seq: 0,
    entity: 100,
    intent: { kind: "move.dir", dx: 1, dz: 0 },
  };
  clientEnd.push(wandering);
  clientS.step(0, DT);
  assert.equal(clientS.stats().protocolViolations, 1, "客户端收到意图 ⇒ 有人在往上广播输入");
});

// ---------------------------------------------------------------- 11 · 坏快照

test("[会话] 读不回来的快照计数并丢弃（不抛、也不把半份世界留下）", () => {
  const host = world();
  const a = spawnPlayer(host.scene, 1, 101);
  const end = new FakeEnd(1);
  const client = world();
  const clientS = createSession({ role: "client", transport: end, scene: client.scene, registry: client.reg });

  const good = snapshotMsgOf(host.scene, 0, 0);
  end.push(good);
  clientS.step(0, DT);
  assert.equal(xOf(client.scene, a), 0);

  host.scene.find(a)?.setLocalPosition(3, 4);
  end.push({ ...snapshotMsgOf(host.scene, 1, 1), json: "{\"format\":1,\"name\":\"x\",\"nodes\":[{" });
  clientS.step(1, DT);

  assert.equal(clientS.stats().badSnapshots, 1);
  assert.equal(xOf(client.scene, a), 0, "坏快照不该把上一份好世界清空");
  assert.equal(clientS.stats().lastSnapshotTick, 0, "没应用成功就不该推进 lastSnapshotTick");
});

// ---------------------------------------------------------------- 12 · 常量

test("[会话] 授权常量不自相矛盾：AUTHORITY 不等于任何真实对端", () => {
  // ★ 这条守的是"改常量时顺手改成 0"：0 是环回里主机那个**对端**，
  //   混用之后 NPC 会被当成"0 号玩家的角色"，而所有归属判据都绿。
  assert.equal(AUTHORITY, -1);
  assert.notEqual(AUTHORITY, 0);
  assert.equal(new NetIdentity().owner, AUTHORITY, "新挂的实体默认归权威，不是归 0 号");
  assert.equal(new NetIdentity().schema.type, NET_IDENTITY_TYPE);
});
