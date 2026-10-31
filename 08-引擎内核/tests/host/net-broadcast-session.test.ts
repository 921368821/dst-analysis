/**
 * L6 · 端到端：两个 `GameApp` 经**广播通道**互联，客户端**开着预测**
 *
 * ★ 这一条与 `net-assembly.test.ts` 的区别（两个都留着）：
 *   · 那条用环回、**关**预测，问的是「副本忠不忠实」（逐字节一致）；
 *   · 这条用广播通道、**开**预测，问的是「预测在网络真的接上时还收敛吗」。
 *
 *   两件事不能合成一条：预测开着时客户端**本来就**比主机领先一步（那条意图还在路上），
 *   所以"逐字节一致"只能在**输入停下来之后**成立。把两种断言写进同一条判据，
 *   最后只能二选一 —— 要么关掉预测（验不到预测），要么放宽成"差不多"（验了个寂寞）。
 *
 * ★ 为什么用内存总线而不是真 `BroadcastChannel`：真通道的投递时机取决于事件循环，
 *   而"哪一拍看得到"正是这里唯一要钉住的东西。`flush()` 让投递点变成显式的。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { BackendRegistry } from "../../src/platform/registry.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { bootGameApp, type GameApp } from "../../src/runtime/GameApp.ts";
import { saveScene, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { PlayerController, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import { NetIdentity, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import { attachSession } from "../../src/extensions/net/session.ts";
import { createBroadcastTransport, type ChannelLike } from "../../src/extensions/net/broadcast-transport.ts";
import type { MoveIntent } from "../../src/extensions/motion/intent.ts";
import { pickLocalEntity } from "../../src/host/net-mode.ts";

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

async function bootApp(): Promise<GameApp> {
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  const r = await bootGameApp({
    platformId: "test",
    interactive: false,
    registry,
    modules: [],
    seed: 20261031,
    fixedDt: DT,
  });
  assert.ok(r.ok, r.ok ? "" : `装配失败：${r.error.code} ${r.error.message}`);
  if (!r.ok) throw new Error("unreachable");
  registerControllerComponent(r.value.components);
  registerNetIdentity(r.value.components);
  return r.value;
}

function spawnPlayer(app: GameApp, owner: number, id: number): number {
  const n = app.scene.spawnImmediate("player", app.scene.rootId, id);
  app.scene.attach(n.id, () => new PlayerController());
  app.scene.attach(n.id, () => {
    const i = new NetIdentity();
    i.owner = owner;
    return i;
  });
  app.scene.flush();
  return n.id;
}

function jsonOf(app: GameApp): string {
  return sceneToJson(saveScene(app.scene, { mode: "rollback" }));
}

/** 4 拍脚本：右、右上、上、空。★ 只往 +x/+z 走，别绕回来（末拍位移要有判别力）。 */
function dirAt(tick: number): MoveIntent {
  const seq: readonly (readonly [number, number])[] = [
    [1, 0],
    [1, 1],
    [0, 1],
    [0, 0],
  ];
  const d = seq[tick % seq.length] ?? [0, 0];
  return { kind: "move.dir", dx: d[0] ?? 0, dz: d[1] ?? 0 };
}

test("[广播+预测] ★ 客户端开着预测跑在真通道上：中途领先主机、输入停下后逐字节收敛", async () => {
  const bus = createBus();
  const hostApp = await bootApp();
  const clientApp = await bootApp();
  try {
    // 主机世界里两个角色：0 号是自己，1 号是「客户端那个人」。
    const hostHero = spawnPlayer(hostApp, 0, 100);
    const remoteHero = spawnPlayer(hostApp, 1, 101);
    assert.equal(pickLocalEntity(hostApp.scene, 0), hostHero);
    assert.equal(pickLocalEntity(hostApp.scene, 1), remoteHero);

    const hostT = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
    const clientT = createBroadcastTransport({ channel: bus.open("room"), self: 1 });

    const hostSide = attachSession(hostApp, {
      role: "host",
      transport: hostT,
      snapshotEveryTicks: 1,
      // ★ 主机端**用缺省的恒等映射**（端点 1 → 座位 1）：写成 `playerOf: () => 0`
      //   的话，客户端发的意图会因为「实体 owner 是 1、而冒充的座位是 0」被判 not-owner ——
      //   那正是"两个窗口同控"的模式，不是这条判据要验的情况。
      local: (t) => (t <= 20 ? { entity: hostHero, intent: dirAt(t) } : null),
    });
    const clientSide = attachSession(clientApp, {
      role: "client",
      transport: clientT,
      snapshotEveryTicks: 1,
      playerOf: () => 1,
      // ★ 用**同一个**决策函数挑本机实体（`pickLocalEntity`），不写 `ownedBy(...)[0]`：
      //   这条判据要证明的正是"宿主选出的那个 == 会话驱动的那个"。
      local: (t) => {
        const id = pickLocalEntity(clientApp.scene, 1);
        return t <= 20 && id !== null ? { entity: id, intent: dirAt(t + 1) } : null;
      },
    });

    // 第 0..20 拍有输入，21..30 拍两边都空（收敛窗口）。
    let leadSeen = 0;
    let clientX = 0;
    let hostX = 0;
    for (let t = 0; t <= 30; t++) {
      clientApp.frame(DT);
      hostApp.frame(DT);
      bus.flush();

      // 中途采样：客户端那个角色是不是**跑在主机前面**
      const c = clientApp.scene.find(remoteHero);
      const h = hostApp.scene.find(remoteHero);
      if (c !== undefined && h !== undefined) {
        const dx = c.localPosition.x - h.localPosition.x;
        clientX = c.localPosition.x;
        hostX = h.localPosition.x;
        if (dx > 1e-9) leadSeen++;
      }
    }
    // 再跑两拍，把最后一条在途的消息消化掉
    for (let t = 0; t < 3; t++) {
      clientApp.frame(DT);
      hostApp.frame(DT);
      bus.flush();
    }

    const cs = clientSide.session.stats();
    const hs = hostSide.session.stats();

    assert.ok(cs.intentsSent > 10, `客户端要真的在发意图，实际 ${String(cs.intentsSent)}`);
    assert.ok(hs.remoteApplied > 10, `主机要真的在执行远端意图，实际 ${String(hs.remoteApplied)}`);
    assert.equal(hs.rejected["not-owner"], 0, "这条判据里双方座位不同，不该有任何 not-owner");
    assert.ok(cs.predicted > 10, `客户端要真的在预测，实际 ${String(cs.predicted)}`);
    assert.ok(cs.replayed > 0, "有收据剪枝、有重放，才说明对账链路在跑");
    assert.ok(
      leadSeen >= 10,
      `客户端应该在一半以上的拍里领先主机（实际 ${String(leadSeen)} 拍）—— 领先不了说明预测没接上` +
        `（末次 客户端 x=${clientX.toFixed(4)} / 主机 x=${hostX.toFixed(4)}）`,
    );
    // 输入停下之后必须收敛：不是"差不多"，是逐字节
    assert.equal(
      jsonOf(clientApp),
      jsonOf(hostApp),
      "输入停下 10 拍之后，客户端副本必须与主机逐字节一致（预测的每一步都被收据校正过了）",
    );
  } finally {
    await clientApp.dispose();
    await hostApp.dispose();
  }
});

test("[广播+预测] 客户端没有自己的实体时不预测、也不发意图（空手等快照）", async () => {
  const bus = createBus();
  const hostApp = await bootApp();
  const clientApp = await bootApp();
  try {
    spawnPlayer(hostApp, 0, 100);
    spawnPlayer(hostApp, 1, 101);

    const hostT = createBroadcastTransport({ channel: bus.open("room"), self: 0 });
    const clientT = createBroadcastTransport({ channel: bus.open("room"), self: 1 });
    attachSession(hostApp, { role: "host", transport: hostT, snapshotEveryTicks: 1, local: () => null });
    const clientSide = attachSession(clientApp, {
      role: "client",
      transport: clientT,
      snapshotEveryTicks: 1,
      playerOf: () => 1,
      local: () => {
        const id = pickLocalEntity(clientApp.scene, 1);
        return id === null ? null : { entity: id, intent: dirAt(1) };
      },
    });

    // ★ 座位 1 在主机的世界里**确实**有实体（101）。这条判据要证明的是：
    //   客户端不会"因为快照里有 owner=1 就自作主张发意图" —— 它得先收到那份快照。
    //   而"收到之前"那几拍里它必须安静。
    const before = clientSide.session.stats().intentsSent;
    clientApp.frame(DT);
    assert.equal(
      clientSide.session.stats().intentsSent,
      before,
      "第一份快照到达之前，客户端不该发意图（它还不知道自己拥有谁）",
    );

    for (let t = 0; t <= 6; t++) {
      clientApp.frame(DT);
      hostApp.frame(DT);
      bus.flush();
    }
    // 收到快照之后就该开始发了 —— 否则「安静」是"永远安静"，与上面那条测不到东西
    assert.ok(clientSide.session.stats().intentsSent > 0, "快照到了之后就要开始发意图");
  } finally {
    await clientApp.dispose();
    await hostApp.dispose();
  }
});
