/**
 * L4 · 会话把视觉插值**真的接上了**（批168）
 *
 * ★★ 纯函数判据（`net-interpolate.test.ts`）全绿，也可能一行接线都没连。
 *   这一份钉的是三件只有会话知道的事：
 *
 *   ① 谁被插值：`playerOf(transport.self)` 是**唯一**的"我是谁"来源。写错成
 *      "归 AUTHORITY 的算别人"或"0 号不是我"时，纯函数那边一切正常。
 *   ② 什么时候采样：必须在 `loadScene` 的**另一侧**。顺序写反的效果是"一段都不
 *      开始"，而所有位置判据照样绿（节点坐标是对的，只是没人插值）。
 *   ③ 摊多久：一个**广播周期**。写死成缺省值时画面照样平滑，只是永远落后一截
 *      且随 `snapshotEveryTicks` 变化 —— 而"落后多少"没有任何计数会反映。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { PlayerController, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import { NetIdentity, ownedBy, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import { createSession, type LocalCommand, type NetSession } from "../../src/extensions/net/session.ts";
import { createLoopbackPair } from "../../src/extensions/net/transport.ts";

const DT = 1 / 30;
/** 主机那位玩家的实体 id。 */
const HERO = 100;
/** 客户端那位玩家的实体 id。 */
const PEER = 101;

interface Side {
  readonly scene: Scene;
  readonly reg: ComponentRegistry;
}

function world(): Side {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  registerNetIdentity(reg);
  return { scene: new Scene("main", reg), reg };
}

function spawnPlayer(w: Side, owner: number, id: number): number {
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

interface Rig {
  readonly hostS: NetSession;
  readonly clientS: NetSession;
  readonly stepTo: (lastTick: number) => void;
}

function rig(opts: { snapshotEvery: number; interpolate?: boolean }): Rig {
  const [hostT, clientT] = createLoopbackPair({ delayTicks: 2 });
  const host = world();
  const client = world();
  const hero = spawnPlayer(host, 0, HERO);
  spawnPlayer(host, 1, PEER);

  const hostS = createSession({
    role: "host",
    transport: hostT,
    scene: host.scene,
    registry: host.reg,
    snapshotEveryTicks: opts.snapshotEvery,
    // 主机那位玩家一直往 +x 走：每拍一步，于是每份快照之间有**恒定**的一段位移。
    local: () => ({ entity: hero, intent: { kind: "move.dir", dx: 1, dz: 0 } }),
  });
  const clientS = createSession({
    role: "client",
    transport: clientT,
    scene: client.scene,
    registry: client.reg,
    snapshotEveryTicks: opts.snapshotEvery,
    ...(opts.interpolate === undefined ? {} : { interpolate: opts.interpolate }),
    // 客户端推的是**自己**那个（归 1 号 = 它自己）。
    local: (): LocalCommand | null => {
      const id = ownedBy(client.scene, 1)[0];
      return id === undefined ? null : { entity: id, intent: { kind: "move.dir", dx: 0, dz: 1 } };
    },
  });

  return {
    hostS,
    clientS,
    stepTo: (lastTick: number) => {
      for (let t = 0; t <= lastTick; t++) {
        hostS.step(t, DT);
        clientS.step(t, DT);
      }
    },
  };
}

test("★★ 别人在插值、我自己不在（逐拍读两个量）", () => {
  const p = rig({ snapshotEvery: 5 });
  assert.notEqual(p.clientS.visual, null, "客户端没有插值器 ⇒ 别人的位移仍然一格一格地闪");
  assert.equal(p.hostS.visual, null, "主机不该有：它不装载快照，`rebase` 一辈子不会被调用");

  let sawOther = 0;
  let sawMine = 0;
  for (let t = 0; t <= 60; t++) {
    p.hostS.step(t, DT);
    p.clientS.step(t, DT);
    const v = p.clientS.visual;
    if (v === null) continue;
    if (v.at(HERO) !== null) sawOther++;
    if (v.at(PEER) !== null) sawMine++;
    // ★ 每拍一帧：插值时钟由**渲染**推进，而这组判据没有渲染层。
    //   不推进的话画面会冻在起点，于是位移被越攒越大、最后被判成传送 ——
    //   那是夹具的错，不是插值的错（这条注释就是那次红字的解释）。
    v.beginFrame(DT * 1000);
  }

  assert.ok(
    sawOther > 0,
    `别人的角色一次都没被插值（快照应用了 ${String(p.clientS.stats().snapshotsApplied)} 份）—— ` +
      "要么采样点不在装载的那一侧，要么「我是谁」判错了",
  );
  assert.equal(
    sawMine,
    0,
    "我自己的角色被插值了 ⇒ 输入与画面之间多一帧延迟，而画面上只会「更顺」",
  );
  const s = p.clientS.stats();
  assert.ok(s.interpStarted > 0, "计数没涨 ⇒ 面板上永远显示「没插值」");
  assert.equal(s.interpSnapped, 0, "每份快照 0.75 格的正常位移被判成了传送");
  p.clientS.visual?.beginFrame(10_000);
  assert.equal(p.clientS.stats().interpActive, 0, "世界停下来之后还有轨道挂着 ⇒ 泄漏");
});

test("★★ 过渡时长 = 一个广播周期（写成缺省值也看不出坏，只会一直落后一截）", () => {
  // 30Hz、每 10 拍播一份 ⇒ 一个周期 ≈ 333ms。缺省是 120ms —— 160ms 时前者还没到、后者早到了。
  const EVERY = 10;
  const PERIOD_MS = EVERY * DT * 1000;
  const p = rig({ snapshotEvery: EVERY });
  let last = 0;
  let checked = false;
  for (let t = 0; t <= 80 && !checked; t++) {
    p.hostS.step(t, DT);
    p.clientS.step(t, DT);
    const s = p.clientS.stats();
    if (s.snapshotsApplied === last) continue;
    last = s.snapshotsApplied;
    if (s.interpActive === 0) continue;
    const v = p.clientS.visual;
    assert.ok(v !== null);
    v.beginFrame(160);
    assert.notEqual(
      v.at(HERO),
      null,
      `160ms 就到位了 ⇒ 时长没按广播周期算（${String(PERIOD_MS)}ms），画面会一直落后一截`,
    );
    v.beginFrame(300); // 160 + 300 = 460 > 333
    assert.equal(v.at(HERO), null, "一个周期过完还挂着 ⇒ 永远追不上");
    checked = true;
  }
  assert.ok(checked, "整段都没抓到「刚装载完、有一段在走」的时刻 —— 这条判据什么也没验");
});

test("★★ 卡顿（帧长 > 插值时长）时也照样插值 —— 采样点必须在**装载之前**", () => {
  // 每帧 200ms、广播周期 166.7ms ⇒ 每一段都在这**一帧之内**走完。
  // 于是「装载后采样」的写法会拿不到上一段（那一帧刚开始就已经被清），
  // 起点退化成"这一份的权威坐标"，位移恒 0 ⇒ 一段都不开始。
  // ★ 这是唯一能把「capture 在 loadScene 之前还是之后」分开的语料：
  //   60fps 时上一段永远还在走，两种顺序看起来一模一样。
  const p = rig({ snapshotEvery: 5 });
  const every = 5 * DT * 1000; // 166.67
  let sawOther = 0;
  let sawMine = 0;
  for (let t = 0; t <= 60; t++) {
    p.hostS.step(t, DT);
    p.clientS.step(t, DT);
    const v = p.clientS.visual;
    if (v === null) continue;
    if (v.at(HERO) !== null) sawOther++;
    if (v.at(PEER) !== null) sawMine++;
    v.beginFrame(every + 40);
  }
  assert.ok(sawOther > 0, "卡顿时一段都不开始 ⇒ 画面退化成「一格一格地跳」，而这正是要治的病");
  assert.equal(sawMine, 0, "卡顿时也不许插值我自己");
});

test("★ 关掉插值：`visual` 为 null，而世界照常装载（同一个开关，不留半开半关）", () => {
  const p = rig({ snapshotEvery: 5, interpolate: false });
  p.stepTo(40);
  assert.equal(p.clientS.visual, null, "关不掉 ⇒ 对照实验（开/关各跑一遍）做不了");
  assert.ok(p.clientS.stats().snapshotsApplied > 0, "世界都没装载 ⇒ 这条判据证明不了任何事情");
  assert.equal(p.clientS.stats().interpStarted, 0);
});
