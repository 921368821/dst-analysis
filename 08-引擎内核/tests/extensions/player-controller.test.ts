/**
 * L4 · 玩家移动控制（输入映射 → 位置）
 *
 * ★ 两条在画面上看不出来、数值也不会报错的语义：
 *   ① 对角线**没归一化** ⇒ 斜走快 41%；
 *   ② 一个 tick poll **两次** ⇒ 吞掉"按下"边缘（"按一下没反应"）。
 *   这组判据把两条都钉住。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import type { InputSnapshot } from "../../src/platform/input/device.ts";
import { Services } from "../../src/core/tokens.ts";
import {
  CONTROLLER_TYPE,
  PlayerController,
  createControllerModule,
  directionFromKeys,
  registerControllerComponent,
  stepOf,
} from "../../src/extensions/input/player-controller.ts";

function snap(keys: string[]): InputSnapshot {
  return {
    keysDown: new Set(keys),
    keysPressed: new Set(keys),
    keysReleased: new Set<string>(),
    pointer: { x: 0, y: 0, dx: 0, dy: 0, buttonsDown: new Set<number>(), buttonsPressed: new Set<number>(), buttonsReleased: new Set<number>() },
    wheel: { dx: 0, dy: 0 },
    text: "",
  } as unknown as InputSnapshot;
}

function ctx(scene: Scene | null): ModuleContext {
  const services = new ServiceRegistry();
  if (scene !== null) services.provide(Services.Scene, scene, "test");
  return {
    log: { channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }) } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  };
}

function makeScene(): { scene: Scene; reg: ComponentRegistry } {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  return { scene: new Scene("c", reg), reg };
}

function addPlayer(scene: Scene, name: string, speed = 4): number {
  const r = scene.spawn(name, null);
  assert.ok(r.ok);
  scene.flush();
  assert.ok(
    scene.attach(r.value.id, () => {
      const c = new PlayerController();
      c.speed = speed;
      return c;
    }).ok,
  );
  scene.flush();
  return r.value.id;
}

// ── ① 方向与归一化 ───────────────────────────────────────────

test("★ 直走：按 D 一个 tick 的位移 = speed × dt（另一个轴不动）", () => {
  const s = stepOf(snap(["KeyD"]), 4, 0.5);
  assert.equal(s.dx, 2);
  assert.equal(s.dz, 0);
});

test("★★ 斜走不加速：W+D 的位移**长度**仍然 = speed × dt（不是 1.41 倍）", () => {
  const s = stepOf(snap(["KeyW", "KeyD"]), 4, 0.5);
  const len = Math.hypot(s.dx, s.dz);
  assert.ok(Math.abs(len - 2) < 1e-9, `位移长度 ${len.toFixed(4)} ≠ 2 —— 对角线没归一化（斜着快 41%）`);
  assert.ok(Math.abs(s.dx - s.dz) < 1e-9, "两轴分量不相等 —— 斜走方向不是 45°");
});

test("方向键与 WASD 等价；相反方向互相抵消", () => {
  assert.deepEqual(directionFromKeys(new Set(["ArrowUp"])), { dx: 0, dz: 1 });
  assert.deepEqual(directionFromKeys(new Set(["KeyW", "ArrowUp"])), { dx: 0, dz: 1 }, "同一方向按两个键应该是 1，不是 2");
  assert.deepEqual(directionFromKeys(new Set(["KeyA", "KeyD"])), { dx: 0, dz: 0 });
});

test("没按任何键 ⇒ 位移为零（不是 NaN，也不是漂移）", () => {
  const s = stepOf(snap([]), 4, 0.5);
  assert.deepEqual(s, { dx: 0, dz: 0 });
});

// ── ② 一个 tick 只 poll 一次 ────────────────────────────────

test("★★ 同一个 tick 调两次 update：只 poll 一次（poll 会消费边缘事件）", () => {
  const { scene } = makeScene();
  const id = addPlayer(scene, "p1");
  let polls = 0;
  const mod = createControllerModule({
    poll: () => {
      polls++;
      return snap(["KeyD"]);
    },
  });
  assert.ok(!(mod.init(ctx(scene)) instanceof Promise));
  mod.update(5, 0.1);
  mod.update(5, 0.1); // 同一 tick 再来一次
  assert.equal(polls, 1, `poll 了 ${polls} 次 —— 多 poll 会吞掉「按下」，表现为「按一下没反应」`);
  // 而且位移也只发生一次
  const p = scene.find(id)!;
  assert.ok(Math.abs(p.localPosition.x - 0.4) < 1e-9, `位移 ${p.localPosition.x} ≠ 0.4（走了两步？）`);
});

test("换 tick 之后会再 poll（不是只跑一次）", () => {
  const { scene } = makeScene();
  addPlayer(scene, "p1");
  let polls = 0;
  const mod = createControllerModule({ poll: () => (polls++, snap([])) });
  mod.init(ctx(scene));
  mod.update(1, 0.1);
  mod.update(2, 0.1);
  assert.equal(polls, 2);
});

// ── ③ 驱动所有控制器 ────────────────────────────────────────

test("★ 模块驱动**所有**带控制器的节点（两个玩家都动）", () => {
  const { scene } = makeScene();
  const a = addPlayer(scene, "p1");
  const b = addPlayer(scene, "p2");
  const mod = createControllerModule({ poll: () => snap(["KeyD"]) });
  mod.init(ctx(scene));
  mod.update(1, 0.5);
  assert.ok(scene.find(a)!.localPosition.x > 0);
  assert.ok(scene.find(b)!.localPosition.x > 0);
  assert.equal(mod.driven, 2);
});

test("没有 Scene 服务 ⇒ 报 CONTROLLER.NO_SCENE（不是静默什么都不做）", () => {
  const mod = createControllerModule({ poll: () => snap([]) });
  const r = mod.init(ctx(null));
  assert.ok(!(r instanceof Promise));
  if (r !== undefined && !r.ok) assert.equal(r.error.code, "CONTROLLER.NO_SCENE");
  else assert.fail("没有 Scene 也 init 成功了");
});

test("没有控制器的场景：不 poll、不崩（driven = 0）", () => {
  const { scene } = makeScene();
  let polls = 0;
  const mod = createControllerModule({ poll: () => (polls++, snap([])) });
  mod.init(ctx(scene));
  mod.update(1, 0.1);
  assert.equal(mod.driven, 0);
  assert.equal(polls, 1, "没玩家时也该 poll 一次（否则「按了没反应」时无法区分是没输入还是没实体）");
});

// ── ④ `drive: false`：只 poll、不落位 ───────────────────────
//
// ★ 这一条为什么必须写：`planNetWiring` 给出 `driveController: false` 是一个**标志位**，
//   而"标志位对了、效果没发生"是最隐蔽的假绿 —— 只测 `planNetWiring` 的话，
//   把 `opts.drive !== false` 改成 `true`（或者把整个 `if (drive)` 拆掉）判据照样全绿，
//   症状是联机下每拍走两步（而单机下永远只有一个驱动者，看不见）。
// ★ 两个观测量必须同时读：该变的变了（poll 与 snapshot）∧ 不该变的没变（位置）。

test("★★ drive:false —— 位置一点不动，但 poll 照跑、snapshot 照更新、driven 照数", () => {
  const { scene } = makeScene();
  const id = addPlayer(scene, "p1", 4);
  let polls = 0;
  const mod = createControllerModule({ drive: false, poll: () => (polls++, snap(["KeyD"])) });
  mod.init(ctx(scene));
  mod.update(1, 0.5);

  const p = scene.find(id)!;
  assert.equal(
    p.localPosition.x,
    0,
    `drive:false 时位置被改了 ${String(p.localPosition.x)} —— 联机下会话再怎么预测都是每拍走两步`,
  );
  assert.equal(polls, 1, "drive:false 也要 poll —— 不 poll 的话会话的 local 回调读到的永远是空输入");
  assert.ok(mod.snapshot.keysDown.has("KeyD"), "snapshot 没更新 —— 会话读到的输入会是「什么都没按」");
  assert.equal(mod.driven, 1, "driven 要照常计数 —— 联机下恒 0 看起来像「控制器模块没跑」");
});

test("★ drive 写成显式 true 时与缺省一致（单机那条路一个字节都没改）", () => {
  const { scene } = makeScene();
  const id = addPlayer(scene, "p1", 4);
  const mod = createControllerModule({ drive: true, poll: () => snap(["KeyD"]) });
  mod.init(ctx(scene));
  mod.update(1, 0.5);
  const p = scene.find(id)!;
  assert.ok(Math.abs(p.localPosition.x - 2) < 1e-9, `位移 ${String(p.localPosition.x)} ≠ 2（speed 4 × dt 0.5）`);
});

void CONTROLLER_TYPE;
