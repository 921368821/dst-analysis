/**
 * L6 · 装配：两个 `GameApp` 经环回互连（批152）
 *
 * ★ 为什么这条判据必须真的起两个 app，而不是两个裸 `Scene`：
 *   `net-session.test.ts` 验的是会话本身；这里验的是**接线** —— 会话挂在
 *   `scheduler.onStep` 上、用 `app.components` 当组件注册表、用 `app.scene` 当世界。
 *   这三件事任何一件接错（挂到 frame 上、忘了注册组件、另建一个 scene），
 *   裸 `Scene` 的判据全都看不见，而真机上是"客户端一直空着"。
 *
 * ★ 一个诚实的边界：这里**不注册任何模块**。世界步进、AI、渲染都不参与，
 *   因为这条判据要证的是"会话在组合根的驱动链上"，不是"demo 能跑"。
 *   模块一进来，任何一条模块的顺序变化都可能让这条判据红在与它无关的地方。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { BackendRegistry } from "../../src/platform/registry.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { bootGameApp, type GameApp } from "../../src/runtime/GameApp.ts";
import { saveScene, sceneToJson } from "../../src/core/scene/scene-io.ts";
import { PlayerController, registerControllerComponent } from "../../src/extensions/input/player-controller.ts";
import { NetIdentity, ownedBy, registerNetIdentity } from "../../src/extensions/net/identity.ts";
import { attachSession } from "../../src/extensions/net/session.ts";
import { createLoopbackPair } from "../../src/extensions/net/transport.ts";
import type { MoveIntent } from "../../src/extensions/motion/intent.ts";

const DT = 1 / 30;

async function bootApp(): Promise<GameApp> {
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  const r = await bootGameApp({
    platformId: "test",
    interactive: false,
    registry,
    modules: [],
    seed: 20261030,
    fixedDt: DT,
  });
  assert.ok(r.ok, r.ok ? "" : `装配失败：${r.error.code} ${r.error.message}`);
  if (!r.ok) throw new Error("unreachable");
  const app = r.value;
  registerControllerComponent(app.components);
  registerNetIdentity(app.components);
  return app;
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

/**
 * 8 拍脚本：右 / 右上 / 上 / 左上 / 左 / 左下 / 下 / 空。
 * ★ 含斜走（归一化）与空拍（零位移），与 `net-session` 的语料同形但独立写一份 ——
 *   共享语料会让"两边同时被改错"看不出来。
 */
function dirAt(tick: number): MoveIntent {
  const seq: readonly (readonly [number, number])[] = [
    [1, 0],
    [1, 1],
    [0, 1],
    [-1, 1],
    [-1, 0],
    [-1, -1],
    [0, -1],
    [0, 0],
  ];
  const d = seq[tick % seq.length] ?? [0, 0];
  return { kind: "move.dir", dx: d[0], dz: d[1] };
}

test("[装配] 两个 GameApp 经环回互连，跑 24 拍后客户端世界与主机逐字节一致", async () => {
  const [hostT, clientT] = createLoopbackPair();
  const hostApp = await bootApp();
  const clientApp = await bootApp();

  try {
    const hostHero = spawnPlayer(hostApp, 0, 100);
    spawnPlayer(hostApp, 1, 101);

    const hostSide = attachSession(hostApp, {
      role: "host",
      transport: hostT,
      snapshotEveryTicks: 1,
      local: (t) => ({ entity: hostHero, intent: dirAt(t) }),
    });
    const clientSide = attachSession(clientApp, {
      role: "client",
      transport: clientT,
      snapshotEveryTicks: 1,
      local: (t) => {
        // ★ 客户端从副本里读出「我拥有谁」再发意图 —— 第一份快照到之前它是空的，
        //   所以第 0 拍不发（与 `net-session` 的判据同一条约定）。
        const id = ownedBy(clientApp.scene, 1)[0];
        return id === undefined ? null : { entity: id, intent: dirAt(t + 3) };
      },
    });

    for (let t = 0; t <= 24; t++) {
      clientApp.frame(DT);
      hostApp.frame(DT);
    }
    // 主机第 24 拍发出的那份快照，客户端要到下一拍才取
    clientApp.frame(DT);

    assert.equal(hostSide.session.stats().snapshotsSent, 25, "每拍一份，0..24 共 25 份");
    assert.equal(clientSide.session.stats().snapshotsApplied, 25, "最后一份也该追上");
    assert.equal(clientSide.session.stats().protocolViolations, 0);

    const hostHeroNode = hostApp.scene.find(hostHero);
    assert.ok(hostHeroNode !== undefined);
    assert.ok(Math.hypot(hostHeroNode.localPosition.x, hostHeroNode.localPosition.y) > 1e-9);

    assert.equal(jsonOf(clientApp), jsonOf(hostApp), "客户端副本必须与主机逐字节一致");
    assert.ok(clientApp.scene.countOf("game.controller") === 2, "副本里两个角色都在");
  } finally {
    await clientApp.dispose();
    await hostApp.dispose();
  }
});
