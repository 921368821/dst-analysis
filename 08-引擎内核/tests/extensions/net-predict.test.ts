/**
 * L4 · 客户端移动预测的契约（批161）
 *
 * ★ 这份判据要回答的是「预测有没有让客户端算错」，不是「Predictor 这个类写对了没有」。
 *   所以核心是两条：
 *
 *   ① **客户端第 t 拍的位置 == 主机第 t + 延迟 拍的位置**（逐拍）。
 *      预测的全部承诺就是这一条：不是"算得差不多"，而是"提前看到主机将来会算出的
 *      那个数"。它一旦不成立，玩家看到的是自己的角色在滑，而主机那边一切正常。
 *
 *   ② **不预测时两拍之间动都不动**（对照组）。
 *      没有这条，"有位移"这个断言在预测根本没接上时也可能成立（快照推进也算位移）。
 *
 * ★★ 一个刻意的对照：延迟 2 拍、每拍广播。
 *   延迟 0 时环回会让主机在**同一拍**收到意图，于是"客户端领先主机"这件事根本
 *   观察不到 —— 判据全绿，而线上（RTT 几十毫秒）完全是另一回事。延迟 2 拍时
 *   领先量正好等于延迟，可以逐拍钉死。
 *
 * ★ 量化地板：快照被量化到 1e-9（`delta.ts` 文件头 ①），所以重放出来的坐标与
 *   "主机当时算的"差 ≤1e-9。判据用的是这个量级，不是 0 —— 写 0 的话这条判据会在
 *   任何一次量化实现变更时红，而那种红没有任何信息量。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { saveScene, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { PlayerController, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import { NetIdentity, ownedBy, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import { NetReject, createSession, type LocalCommand, type NetSession } from "../../src/extensions/net/session.ts";
import {
  createLoopbackPair,
  type NetMessage,
  type PeerId,
  type Transport,
  type TransportStats,
} from "../../src/extensions/net/transport.ts";

const DT = 1 / 30;

/** 量化地板：快照里的浮点只到 1e-9（见文件头）。判据用它当"算对了"的上界。 */
const FLOOR = 1e-8;

// ---------------------------------------------------------------- 语料

/**
 * 6 拍的输入脚本：含斜走、空拍、反向。
 *
 * ★ 空拍（`[0, 0]`）不是凑数：它让"零位移不记一步"这条规则有语料，
 *   也让"位移不等于 0"那种判据不能靠"拍数"蒙对。
 */
const DIRS: readonly (readonly [number, number])[] = [
  [1, 0],
  [1, 1],
  [0, 1],
  [-1, 0],
  [0, 0],
  [-1, -1],
];

function dirAt(tick: number): { kind: "move.dir"; dx: number; dz: number } {
  const d = DIRS[((tick % DIRS.length) + DIRS.length) % DIRS.length] ?? [0, 0];
  return { kind: "move.dir", dx: d[0], dz: d[1] };
}

// ---------------------------------------------------------------- 夹具

interface World {
  readonly scene: Scene;
  readonly reg: ComponentRegistry;
}

function world(): World {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  registerNetIdentity(reg);
  return { scene: new Scene("main", reg), reg };
}

function spawnPlayer(w: World, owner: number, id: number): number {
  const n = w.scene.spawnImmediate("player", w.scene.rootId, id);
  w.scene.attach(n.id, () => new PlayerController());
  w.scene.attach(n.id, () => {
    const i = new NetIdentity();
    i.owner = owner;
    return i;
  });
  w.scene.flush();
  return n.id;
}

function posOf(scene: Scene, id: number): { x: number; y: number } {
  const n = scene.find(id);
  assert.ok(n !== undefined, `节点 ${String(id)} 不见了`);
  return { x: n.localPosition.x, y: n.localPosition.y };
}

/**
 * 同 `posOf`，但**还没到**时返回 `null`。
 *
 * ★ 客户端在第一份快照到达之前根本没有这个节点（延迟 2 拍时是前两拍）。
 *   用 `posOf` 会红在"节点不存在"上，而那与预测毫无关系。
 */
function maybePos(scene: Scene, id: number): { x: number; y: number } | null {
  const n = scene.find(id);
  return n === undefined ? null : { x: n.localPosition.x, y: n.localPosition.y };
}

interface PairOptions {
  readonly delay: number;
  readonly snapshotEvery: number;
  readonly predict?: boolean;
  readonly maxSteps?: number;
}

interface Pair {
  readonly host: World;
  readonly client: World;
  readonly hostS: NetSession;
  readonly clientS: NetSession;
  readonly peerHero: number;
}

/**
 * 两端各一个角色，客户端推自己那个（输入相位 +5，两条轨迹必然不同）。
 *
 * ★ 两条轨迹必须不同：轨迹相同时"预测打了别人的角色"会算出一样的坐标。
 */
function makePair(opts: PairOptions): Pair {
  const [hostT, clientT] = createLoopbackPair({ delayTicks: opts.delay });
  const host = world();
  const client = world();
  const hostHero = spawnPlayer(host, 0, 100);
  const peerHero = spawnPlayer(host, 1, 101);

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: opts.snapshotEvery,
    local: (t) => ({ entity: hostHero, intent: dirAt(t) }),
  });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    snapshotEveryTicks: opts.snapshotEvery,
    ...(opts.predict === undefined ? {} : { predict: opts.predict }),
    ...(opts.maxSteps === undefined ? {} : { maxPredictSteps: opts.maxSteps }),
    local: (t): LocalCommand | null => {
      const id = ownedBy(client.scene, 1)[0];
      return id === undefined ? null : { entity: id, intent: dirAt(t + 5) };
    },
  });
  return { host, client, hostS, clientS, peerHero };
}

/** 一步的长度（对角走也一样，`dirStep` 归一化过）。 */
function stepLen(): number {
  return 4.5 * DT;
}

/** 与主机 `broadcast` 同一条规矩：网络快照是「第 T 拍的世界」，用回滚语义导出。 */
function snapJsonOf(scene: Scene): string {
  return sceneToJson(saveScene(scene, { mode: "rollback" }));
}

/**
 * 一个只有收件箱的传输端：用来**按我指定的顺序**投递消息（收据乱序、坏 JSON、
 * 主机不发收据）。环回做不到这些 —— 它按 tick 排队，而且总会带收据。
 */
class FakeEnd implements Transport {
  readonly self: PeerId;
  readonly out: NetMessage[] = [];
  private inbox: NetMessage[] = [];

  /** 接下来 N 次 `send` 返回 `false`（模拟"我以为发出去了，其实没有"）。 */
  fails = 0;

  constructor(self: PeerId) {
    this.self = self;
  }

  send(msg: NetMessage): boolean {
    if (this.fails > 0) {
      this.fails--;
      return false;
    }
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

  /** 取出并清空发件箱（判据读它来确认"客户端确实发了一条意图"）。 */
  take(): NetMessage[] {
    return this.out.splice(0, this.out.length);
  }
}

/** 单独一个客户端会话（配 `FakeEnd`）。 */
function loneClient(
  w: World,
  end: FakeEnd,
  local: (tick: number) => LocalCommand | null,
  extra: { predict?: boolean; maxSteps?: number } = {},
): NetSession {
  return createSession({
    role: "client",
    transport: end,
    scene: w.scene,
    registry: w.reg,
    local,
    ...(extra.predict === undefined ? {} : { predict: extra.predict }),
    ...(extra.maxSteps === undefined ? {} : { maxPredictSteps: extra.maxSteps }),
  });
}

// ---------------------------------------------------------------- 1 · 当拍就动

test("[预测] ★ 开预测时本端角色每拍都在动；关掉时只在快照到达那拍动（对照）", () => {
  const on = makePair({ delay: 2, snapshotEvery: 5 });
  const off = makePair({ delay: 2, snapshotEvery: 5, predict: false });

  let movedOn = 0;
  let movedOff = 0;
  let prevOn = maybePos(on.client.scene, on.peerHero);
  let prevOff = maybePos(off.client.scene, off.peerHero);
  for (let t = 0; t <= 30; t++) {
    on.clientS.step(t, DT);
    on.hostS.step(t, DT);
    off.clientS.step(t, DT);
    off.hostS.step(t, DT);
    const nowOn = maybePos(on.client.scene, on.peerHero);
    const nowOff = maybePos(off.client.scene, off.peerHero);
    if (nowOn !== null && prevOn !== null && (Math.abs(nowOn.x - prevOn.x) > 1e-12 || Math.abs(nowOn.y - prevOn.y) > 1e-12)) {
      movedOn++;
    }
    if (nowOff !== null && prevOff !== null && (Math.abs(nowOff.x - prevOff.x) > 1e-12 || Math.abs(nowOff.y - prevOff.y) > 1e-12)) {
      movedOff++;
    }
    prevOn = nowOn;
    prevOff = nowOff;
  }

  // 30 拍里有 5 个空拍（`DIRS` 的 [0,0]），所以上界是 30-5=25 附近。
  assert.ok(movedOn >= 20, `开预测时该几乎每拍都动，实际 ${String(movedOn)} 拍`);
  // 每 5 拍一份快照、共 31 拍 ⇒ 最多 7 次"因为快照而跳"。
  assert.ok(movedOff <= 7, `关预测时只该在快照那几拍动，实际 ${String(movedOff)} 拍`);
  assert.ok(movedOn > movedOff * 2, "预测与不预测必须有量级差，否则这条判据在两种情况下都绿");
  assert.ok(on.clientS.stats().predicted >= 20, "预测计数要跟上（不是靠别的东西在动）");
  assert.equal(off.clientS.stats().predicted, 0);
});

// ---------------------------------------------------------------- 2 · 提前看到的正是主机的将来

test("[预测] ★ 客户端第 t 拍的位置 == 主机第 t+2 拍的位置（延迟 2、每拍广播）", () => {
  const p = makePair({ delay: 2, snapshotEvery: 1 });
  const hostXs: number[] = [];
  const clientXs: number[] = [];
  const T = 30;
  for (let t = 0; t <= T + 2; t++) {
    p.clientS.step(t, DT);
    p.hostS.step(t, DT);
    hostXs.push(posOf(p.host.scene, p.peerHero).x);
    clientXs.push(maybePos(p.client.scene, p.peerHero)?.x ?? Number.NaN);
  }

  // 前 2 拍客户端还没有归属（第一份快照在路上），从第 3 拍开始比。
  let compared = 0;
  let worst = 0;
  for (let t = 3; t <= T; t++) {
    const h = hostXs[t + 2];
    const c = clientXs[t];
    assert.ok(h !== undefined && c !== undefined);
    worst = Math.max(worst, Math.abs(h - c));
    compared++;
  }
  assert.equal(compared, 28);
  assert.ok(worst <= FLOOR, `预测必须提前看准，最大偏差 ${worst.toExponential(3)}`);
  // ★ 不能看"最后那一拍离原点多远"：这条脚本是 6 拍一轮的闭环，走完一圈就回到
  //   原点附近。要证明"真的走过很多路"，只能看累计路程。
  let walked = 0;
  for (let t = 4; t <= T; t++) walked += Math.abs((clientXs[t] ?? 0) - (clientXs[t - 1] ?? 0));
  assert.ok(walked > 1, `整条轨迹几乎没动（累计 ${walked.toFixed(3)}）时，「提前看准」是两份静止在相等`);
  // 反向证据：客户端**不是**在跟着主机的当前拍走（那说明它其实没提前）。
  const lagDiff = Math.abs((clientXs[T] ?? 0) - (hostXs[T] ?? 0));
  assert.ok(lagDiff > 1e-6, "客户端与主机在同一拍上应该差着一段（它领先 2 拍）");
});

// ---------------------------------------------------------------- 3 · 重放在发生且会收敛

test("[预测] ★ 重放确实在发生，且待重放表会收敛（无积压时 pending 不涨）", () => {
  const p = makePair({ delay: 2, snapshotEvery: 1 });
  for (let t = 0; t <= 30; t++) {
    p.clientS.step(t, DT);
    p.hostS.step(t, DT);
  }
  const s = p.clientS.stats();
  assert.ok(s.predicted >= 20, `预测没生效（${String(s.predicted)}）`);
  assert.ok(s.replayed >= 20, `重放没发生 —— 那么"预测"只是一次性位移，快照一来就被抹掉（${String(s.replayed)}）`);
  assert.ok(s.predictDropped === 0, "没有积压时不该丢预测步");
  assert.ok(s.predictError <= FLOOR, `重放抖动该停在量化地板，实际 ${s.predictError.toExponential(3)}`);
  assert.equal(p.hostS.stats().rejected[NetReject.NotOwner], 0, "这条线不该有被拒的意图");
});

// ---------------------------------------------------------------- 4 · 发不出去就不预测

test("[预测] 发不出去的意图**不**预测（否则那一步永远等不到收据，人一直往前滑）", () => {
  const w = world();
  const me = spawnPlayer(w, 1, 101);
  const end = new FakeEnd(1);
  const s = loneClient(w, end, () => ({ entity: me, intent: dirAt(0) }), { maxSteps: 8 });

  // 先正常发一条，确认这条线是通的。
  s.step(0, DT);
  assert.equal(s.stats().intentsSent, 1);
  assert.equal(s.stats().predicted, 1);
  assert.ok(Math.abs(posOf(w.scene, me).x - stepLen()) <= 1e-12, "发出去的那一步该当拍落地");

  end.fails = 3;
  const before = posOf(w.scene, me);
  for (let t = 1; t <= 3; t++) s.step(t, DT);

  assert.equal(s.stats().intentsSent, 1, "这三拍一条都没发出去");
  assert.equal(s.stats().predicted, 1, "预测计数也不许涨（涨了就是「发出去了」的假象）");
  const after = posOf(w.scene, me);
  assert.equal(after.x, before.x, "发不出去的输入不许在本地走");
  assert.equal(after.y, before.y);
});

// ---------------------------------------------------------------- 5 · 只预测自己的

test("[预测] 不是我的实体不预测；主机按 not-owner 拒，客户端也不漂", () => {
  const [hostT, clientT] = createLoopbackPair({ delayTicks: 1 });
  const host = world();
  const client = world();
  const hostHero = spawnPlayer(host, 0, 100);
  spawnPlayer(host, 1, 101);

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: 1,
    local: () => null,
  });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    snapshotEveryTicks: 1,
    // 故意去推**主机**的角色（id 100，owner 0）
    local: () => ({ entity: hostHero, intent: dirAt(0) }),
  });

  // ★ 40 拍不是凑数：默认上限是 32 步。被拒的意图如果**不进收据**，
  //   待重放表就会涨到 32 然后开始丢 —— `predictDropped` 是这件事唯一的观测量。
  for (let t = 0; t <= 39; t++) {
    clientS.step(t, DT);
    hostS.step(t, DT);
  }

  assert.equal(clientS.stats().intentsSent, 40, "意图照样发（本地凭什么替主机做判断）");
  assert.equal(clientS.stats().predicted, 0, "不是我的实体不许本地先走");
  // 39 = 40 条意图里最后一条还在路上（延迟 1 拍）。
  assert.equal(hostS.stats().rejected[NetReject.NotOwner], 39, "主机收到的每一条都该按 not-owner 拒");
  const n = posOf(host.scene, hostHero);
  assert.equal(n.x, 0, "主机那边这个角色一步都不该动");
  // ★ 被拒的意图必须进收据，否则客户端会把它们重放一辈子。
  assert.equal(
    clientS.stats().predictDropped,
    0,
    "被拒的意图没进收据 —— 待重放表会涨到 32 然后开始丢（玩家看到的是角色在自己往前挪）",
  );
});

// ---------------------------------------------------------------- 6 · 零位移与非移动意图

test("[预测] 零位移 / 非移动意图都不预测（记账分开，不许混成一个数）", () => {
  const w = world();
  const me = spawnPlayer(w, 1, 101);
  const end = new FakeEnd(1);
  const s = loneClient(w, end, (t) =>
    t % 2 === 0
      ? { entity: me, intent: { kind: "move.dir", dx: 0, dz: 0 } }
      : { entity: me, intent: { kind: "move.cell", cell: 7 } },
  );

  for (let t = 0; t <= 7; t++) s.step(t, DT);
  const st = s.stats();
  assert.equal(st.intentsSent, 8, "两种输入都是合法意图，都该发出去");
  assert.equal(st.predicted, 0, "零位移与目标型都不该预测");
  const n = posOf(w.scene, me);
  assert.equal(n.x, 0);
  assert.equal(n.y, 0);
});

// ---------------------------------------------------------------- 7 · 只剪收据覆盖的那一段

test("[预测] 收据只剪掉它覆盖的步：报 2 就剪 3 步、留 2 步重放（多剪少剪都不行）", () => {
  const w = world();
  const me = spawnPlayer(w, 1, 101);
  const end = new FakeEnd(1);
  // ★ 输入在 4 拍之后停：`step()` 是「先收快照（重放）再走本地输入」，
  //   一直给输入的话，验完重放的那一拍又自己走了一步，判据会以为重放多了。
  const s = loneClient(w, end, (t) => (t <= 4 ? { entity: me, intent: dirAt(0) } : null));

  // 起点那份世界（角色在原点）—— 主机第 T 拍发来的就是它。
  const origin = snapJsonOf(w.scene);

  // 攒 5 步（seq 0..4），本地已经走了 5 步。
  for (let t = 0; t <= 4; t++) s.step(t, DT);
  const step = stepLen();
  assert.equal(s.stats().predicted, 5);
  assert.ok(Math.abs(posOf(w.scene, me).x - step * 5) <= 1e-9, "五步都落地了");

  // 主机说：处理到第 2 条（seq 2）。于是 seq 0/1/2 这三步已经在主机那份世界里了，
  // seq 3/4 还没到 —— 正确的结果是「主机的坐标 + 2 步」。
  end.push({ kind: "snapshot", from: 0, tick: 5, seq: 0, json: origin, acks: [{ entity: me, seq: 2 }] });
  s.step(5, DT);
  const after = posOf(w.scene, me);
  assert.ok(
    Math.abs(after.x - step * 2) <= 1e-8,
    `重放的段落与该是 2 步：多剪则停在主机的坐标（0），少剪则是 4 步。实际 ${(after.x / step).toFixed(3)} 步`,
  );
  assert.ok(s.stats().replayed >= 2, "这两步必须是真的重放上去的，不是残留在场景里的");
});

// ---------------------------------------------------------------- 8 · 坏快照不重放

test("[预测] 快照读不回来：计数、要全量、但**不重放**（世界保持预测值）", () => {
  const w = world();
  const me = spawnPlayer(w, 1, 101);
  const end = new FakeEnd(1);
  const s = loneClient(w, end, (t) => (t <= 2 ? { entity: me, intent: dirAt(0) } : null));

  for (let t = 0; t <= 2; t++) s.step(t, DT);
  const step = stepLen();
  const before = posOf(w.scene, me);
  assert.ok(Math.abs(before.x - step * 3) <= 1e-9);

  end.push({ kind: "snapshot", from: 0, tick: 3, seq: 0, json: "{ 这不是 JSON" });
  s.step(3, DT);

  assert.equal(s.stats().badSnapshots, 1);
  assert.equal(s.stats().resyncsSent, 1, "读不回来就要一份全量（不是干等关键帧）");
  const after = posOf(w.scene, me);
  assert.equal(after.x, before.x, "装载失败时世界没被动过，重放会把预测值再加一遍");
  assert.ok(s.stats().replayed === 0, "一次都不该重放");
});

// ---------------------------------------------------------------- 9 · 实体没了

test("[预测] 预测中的实体在快照里不见了：整条丢掉（不留永远等不到的步）", () => {
  const w = world();
  const me = spawnPlayer(w, 1, 101);
  const end = new FakeEnd(1);
  const s = loneClient(w, end, () => ({ entity: me, intent: dirAt(0) }));

  for (let t = 0; t <= 2; t++) s.step(t, DT);
  assert.equal(s.stats().predicted, 3);

  // 主机给的世界里没有这个节点（它被销毁了）。
  end.push({ kind: "snapshot", from: 0, tick: 3, seq: 0, json: '{"format":1,"name":"main","nodes":[]}' });
  s.step(3, DT);

  assert.equal(w.scene.find(me), undefined, "装载之后节点确实没了");
  assert.equal(s.stats().predictResets, 1, "整条丢弃要计数（否则这就是一条静默的分支）");
  assert.equal(s.stats().predictDropped, 0, "这不是「攒太多丢老的」，别混成一个数");
});

// ---------------------------------------------------------------- 10 · 收据断了有界

test("[预测] 收据彻底断了（主机不发 acks）：待重放表被上限卡住，偏差有界", () => {
  const w = world();
  const me = spawnPlayer(w, 1, 101);
  const end = new FakeEnd(1);
  const s = loneClient(w, end, () => ({ entity: me, intent: dirAt(0) }), { maxSteps: 3 });

  const step = stepLen();
  // 主机每拍都发一份"世界没动"的快照，但**不带收据**。
  const origin = snapJsonOf(w.scene);
  for (let t = 0; t <= 20; t++) {
    s.step(t, DT);
    end.push({ kind: "snapshot", from: 0, tick: t, seq: t, json: origin });
  }

  const st = s.stats();
  assert.ok(st.predictDropped > 0, `上限该被顶到，实际 dropped=${String(st.predictDropped)}`);
  // 每拍：重放 3 步（上限）之后本地再走 1 步 ⇒ 领先量 = 上限 + 1，且**与拍数无关**。
  //   ★ 这个 +1 不是误差：本拍的那一步还没被任何一份快照重放过（它刚产生）。
  const last = posOf(w.scene, me);
  const lead = last.x / step;
  assert.ok(
    Math.abs(lead - 4) <= 1e-6,
    `没有收据时领先量必须被上限卡住（3+1 步），实际 ${lead.toFixed(2)} 步 —— 若随拍数增长就是对账断了`,
  );
});

// ---------------------------------------------------------------- 11 · 收据跟着两种广播走

test("[预测] ★ 收据挂在**两种**广播上（全量与增量都要带，否则增量那几拍会重放双份）", () => {
  const w = world();
  const me = spawnPlayer(w, 1, 101);
  const end = new FakeEnd(0);
  const s = createSession({
    role: "host",
    transport: end,
    scene: w.scene,
    registry: w.reg,
    snapshotEveryTicks: 1,
    keyframeEvery: 2,
  });

  // 第 0 拍：一条意图进来（主机当拍消化），随后广播一份全量。
  end.push({ kind: "intent", from: 1, tick: 0, seq: 0, entity: me, intent: dirAt(0) });
  s.step(0, DT);
  const first = end.take();
  assert.equal(first.length, 1);
  const m0 = first[0];
  assert.ok(m0 !== undefined && m0.kind === "snapshot", "第一份该是全量");
  assert.deepEqual(m0.acks, [{ entity: me, seq: 0 }], "全量必须带收据（且是处理过的那条）");

  // 第 1 拍：没有新意图，走增量分支 —— 收据仍然必须带（这是最容易漏的一支）。
  s.step(1, DT);
  const second = end.take();
  assert.equal(second.length, 1);
  const m1 = second[0];
  assert.ok(m1 !== undefined && m1.kind === "snapshot-delta", "第二份该是增量（关键帧间隔 2）");
  assert.deepEqual(m1.acks, [{ entity: me, seq: 0 }], "增量分支漏了收据时，客户端会少剪一步");
});

// ---------------------------------------------------------------- 12 · 主机自己不预测

test("[预测] 默认开预测，但**主机**不建预测器（它先落地、后广播，没有「预测」这回事）", () => {
  const [hostT, clientT] = createLoopbackPair({ delayTicks: 1 });
  const host = world();
  const client = world();
  const hostHero = spawnPlayer(host, 0, 100);
  spawnPlayer(host, 1, 101);

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: 1,
    local: () => ({ entity: hostHero, intent: dirAt(0) }),
  });
  // ★ 不传 `predict`：走默认值。
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    snapshotEveryTicks: 1,
    local: () => {
      const id = ownedBy(client.scene, 1)[0];
      return id === undefined ? null : { entity: id, intent: dirAt(1) };
    },
  });

  for (let t = 0; t <= 12; t++) {
    clientS.step(t, DT);
    hostS.step(t, DT);
  }

  assert.equal(hostS.stats().predicted, 0, "主机的本地输入本来就当拍落地，再预测一次就是走两步");
  assert.equal(hostS.stats().replayed, 0);
  assert.ok(clientS.stats().predicted > 0, "客户端不传 predict 时必须是开着的（默认值不许被悄悄翻成 false）");
  // 主机本地角色走了 13 步，不多不少。
  const n = posOf(host.scene, hostHero);
  assert.ok(Math.abs(n.x - stepLen() * 13) <= 1e-9, `主机走了 ${(n.x / stepLen()).toFixed(3)} 步，应为 13`);
});

// ---------------------------------------------------------------- 13 · 收据只前移

test("[预测] 晚到的**旧**意图不许把收据往回拨（收据一回退，客户端就把已确认的步再走一遍）", () => {
  const w = world();
  const me = spawnPlayer(w, 1, 101);
  const end = new FakeEnd(0);
  const s = createSession({ role: "host", transport: end, scene: w.scene, registry: w.reg, snapshotEveryTicks: 1 });

  // 先到 seq 5。真实的传输里顺序并不保证（重传、多路复用都会让旧的晚到）。
  end.push({ kind: "intent", from: 1, tick: 0, seq: 5, entity: me, intent: dirAt(0) });
  s.step(0, DT);
  const first = end.take();
  assert.equal(first.length, 1, "每拍一份广播");
  const m0 = first[0];
  assert.ok(m0 !== undefined && (m0.kind === "snapshot" || m0.kind === "snapshot-delta"));
  assert.deepEqual(m0.acks, [{ entity: me, seq: 5 }], "已经处理到 5 了");

  // 晚到的 seq 3：照样要走、要落地，但收据必须**留在 5**。
  end.push({ kind: "intent", from: 1, tick: 1, seq: 3, entity: me, intent: dirAt(1) });
  for (let t = 1; t <= 2; t++) s.step(t, DT);

  const msgs = end.take();
  assert.equal(msgs.length, 2);
  const last = msgs[1];
  assert.ok(last !== undefined && (last.kind === "snapshot" || last.kind === "snapshot-delta"));
  assert.deepEqual(last.acks, [{ entity: me, seq: 5 }], "收据被一条旧意图拨回去了");
  // ★ 同时读另一个观测量：这条旧意图确实被执行了（不是被整条丢掉所以"看起来没回退"）。
  assert.equal(s.stats().remoteApplied, 2, "两条意图都该落地 —— 否则「收据没回退」可能是根本没处理");
});

// ---------------------------------------------------------------- 14 · 被拒的意图也要进收据

test("[预测] 座位号在主机那边变了（重连换号）时，被拒的意图照样进收据 —— 否则一直重放", () => {
  const [hostT, clientT] = createLoopbackPair({ delayTicks: 1 });
  const host = world();
  const client = world();
  const hero = spawnPlayer(host, 1, 101);

  // ★ 主机认为这根线是 2 号玩家（重连换了号），客户端还认为自己是 1 号。
  //   归属字段本身没变（owner 1），所以客户端的预测检查一直通过 —— 它每拍都预测，
  //   主机每拍都按 not-owner 拒。这是"客户端预测了、主机拒了"唯一能持续的情形。
  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: 1,
    playerOf: () => 2,
    local: () => null,
  });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    snapshotEveryTicks: 1,
    playerOf: () => 1,
    local: () => ({ entity: hero, intent: dirAt(0) }),
  });

  // 40 拍 > 默认上限 32 步：被拒的意图不进收据时，待重放表会涨到 32 再开始丢。
  for (let t = 0; t <= 39; t++) {
    clientS.step(t, DT);
    hostS.step(t, DT);
  }

  assert.ok(clientS.stats().predicted >= 38, "客户端确实在预测（它按自己那份归属判断）");
  assert.equal(hostS.stats().rejected[NetReject.NotOwner], 39, "主机把收到的每一条都按 not-owner 拒了");
  assert.equal(
    clientS.stats().predictDropped,
    0,
    "被拒的意图没进收据 —— 待重放表涨到上限后开始丢，角色会自己在原地往前挪",
  );
});
