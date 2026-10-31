/**
 * L4 · `onWorldLoaded`：装载**成功之后**通知宿主重指
 *
 * 为什么值得单独一条判据：这个回调唯一的作用是让宿主把「主角 / 相机跟随目标 /
 * 选中对象」这些**节点 id** 重新指一遍。客户端每收到一份快照，`loadScene` 就把
 * 整个场景换掉，那些 id 全部悬空 —— 而症状是**世界在动、相机不动、按键没反应**。
 * 它长得像渲染坏了，也像输入坏了，唯独不像"某个回调没调"。
 *
 * 所以这里钉两件事：
 * ① 装载成功（全量与增量都算）之后**必须**调；
 * ② 装载失败时**不许**调 —— 失败时世界没被动过，重指反而会把好的 id 改坏
 *    （比如指着"新世界里的最小 id"，而那在新世界里是另一棵树）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { sceneToJson } from "../../src/core/scene/scene-io.ts";
import { PlayerController, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import { NetIdentity, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import { createSession } from "../../src/extensions/net/session.ts";
import { deltaToJson, diffSnapshot, snapshotOfScene } from "../../src/extensions/net/delta.ts";
import type { NetMessage, PeerId, Transport, TransportStats } from "../../src/extensions/net/transport.ts";

const DT = 1 / 30;

function world(): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  registerNetIdentity(reg);
  return { scene: new Scene("main", reg), reg };
}

function spawnPlayer(w: { scene: Scene }, owner: number, id: number): number {
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

class End implements Transport {
  readonly out: NetMessage[] = [];
  private inbox: NetMessage[] = [];
  constructor(readonly self: PeerId) {}
  send(msg: NetMessage): boolean {
    this.out.push(msg);
    return true;
  }
  receive(): readonly NetMessage[] {
    const got = this.inbox;
    this.inbox = [];
    return got;
  }
  push(...msgs: NetMessage[]): void {
    this.inbox.push(...msgs);
  }
  stats(): TransportStats {
    return { sent: this.out.length, received: 0, dropped: 0, queued: this.inbox.length };
  }
  dispose(): void {}
}

test("[装载回调] 全量快照装载成功 → 回调被调，且调的时候新世界**已经在场景里**", () => {
  const w = world();
  const end = new End(1);
  let calls = 0;
  let heroVisibleInCallback = false;
  const s = createSession({
    role: "client",
    transport: end,
    scene: w.scene,
    registry: w.reg,
    onWorldLoaded: () => {
      calls++;
      // ★ 这一句才是这条判据的价值：回调**在装载之后**跑，所以宿主读到的
      //   已经是新世界的节点。放在装载之前的话，宿主重指到的仍是旧 id。
      heroVisibleInCallback = w.scene.find(500) !== undefined;
    },
  });

  // 主机送来一份世界：一个玩家（id 500）
  const host = world();
  const heroId = spawnPlayer(host, 1, 500);
  const json = sceneToJson(snapshotOfScene(host.scene));
  end.push({ kind: "snapshot", from: 0, tick: 0, seq: 0, json });
  s.step(0, DT);

  assert.equal(calls, 1, "装载成功必须调一次");
  assert.equal(heroId, 500);
  assert.ok(heroVisibleInCallback, "回调里该看得见新世界的节点（说明它跑在装载**之后**）");
  assert.ok(w.scene.find(heroId) !== undefined, "回调之后世界确实换过来了");
});

test("[装载回调] 坏快照（读不回来）→ **不调**（世界没被动过，重指会把好的 id 改坏）", () => {
  const w = world();
  const end = new End(1);
  let calls = 0;
  const s = createSession({
    role: "client",
    transport: end,
    scene: w.scene,
    registry: w.reg,
    onWorldLoaded: () => {
      calls++;
    },
  });

  // 不是合法 JSON
  end.push({ kind: "snapshot", from: 0, tick: 0, seq: 0, json: "{ 这不是 json" });
  s.step(0, DT);
  assert.equal(calls, 0, "装载失败时不该调");
  // 同时读另一个观测量：它确实被当成坏快照处理了（而不是"整条被忽略"）
  assert.equal(s.stats().badSnapshots, 1);
  assert.ok(s.stats().resyncsSent > 0, "坏快照该主动要一份全量");

  // JSON 合法但结构不对（缺 nodes）
  end.push({ kind: "snapshot", from: 0, tick: 1, seq: 1, json: JSON.stringify({ format: 1, name: "main" }) });
  s.step(1, DT);
  assert.equal(calls, 0, "结构不对也不该调");
});

test("[装载回调] 增量合成之后也要调（增量走的是同一个装载点）", () => {
  const w = world();
  const end = new End(1);
  let calls = 0;
  const s = createSession({
    role: "client",
    transport: end,
    scene: w.scene,
    registry: w.reg,
    keyframeEvery: 100, // 别让它插全量
    onWorldLoaded: () => {
      calls++;
    },
  });

  const host = world();
  const heroId = spawnPlayer(host, 1, 600);
  const base = snapshotOfScene(host.scene);
  end.push({ kind: "snapshot", from: 0, tick: 0, seq: 0, json: sceneToJson(base) });
  s.step(0, DT);
  assert.equal(calls, 1);

  // 主机那边把角色挪了一格，发增量
  const node = host.scene.find(heroId);
  assert.ok(node !== undefined);
  node.setLocalPosition(3, 4);
  host.scene.flush();
  const next = snapshotOfScene(host.scene);
  end.push({ kind: "snapshot-delta", from: 0, tick: 1, seq: 1, base: 0, json: deltaToJson(diffSnapshot(base, next)) });
  s.step(1, DT);

  assert.equal(calls, 2, "增量装载之后同样要重指 —— 不调的话客户端每份增量都在换世界而宿主不知道");
  const applied = w.scene.find(heroId);
  assert.ok(applied !== undefined);
  assert.equal(applied.localPosition.x, 3, "坐标确实被增量改到了");
});
