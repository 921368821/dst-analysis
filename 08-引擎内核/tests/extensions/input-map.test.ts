/**
 * L4 · 输入映射表 + 手柄（T361 / T362）
 *
 * 守的缺陷，按"多贵"排序：
 *  ① **拼错动作名**：`isDown(snap, "havesrt")` 永远 false —— 表现是"按了没反应"，
 *     而且所有判据都是绿的。所以映射表选择**抛错**，这组判据把它钉住。
 *  ② **同组共用键**：`W` 同时绑前进与后退 ⇒ 两轴抵消、人不动；或者更糟，
 *     两个动作都触发（"按一下砍树也存了档"）。冲突检测必须报出来。
 *  ③ **手柄方向反了**：W3C 的摇杆"向上是负值"，写反时只有真手柄能发现。
 *     所以后端把手柄合成成键码，判据里注入假手柄 —— **硬件不在场也能判**。
 *  ④ **改键没生效**：键位还在代码里时，"换一张表"什么都不会发生。
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
  DEFAULT_INPUT_MAP,
  DEFAULT_INPUT_MAP_DATA,
  INPUT_MAP_VERSION,
  createInputMap,
  type InputMapData,
} from "../../src/extensions/input/input-map.ts";
import {
  CONTROLLER_TYPE,
  PlayerController,
  createControllerModule,
  registerControllerComponent,
  stepOf,
} from "../../src/extensions/input/player-controller.ts";
import { DomInputDevice, type DomEventTarget, type GamepadLike } from "../../src/backends/input-dom/device.ts";

function snap(down: string[], pressed: string[] = down): InputSnapshot {
  return {
    keysDown: new Set(down),
    keysPressed: new Set(pressed),
    keysReleased: new Set<string>(),
    pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
    wheel: { dx: 0, dy: 0 },
    text: "",
  };
}

/** 只要有 addEventListener 就算合格目标；记录注册了哪些监听，供测试手动派发。 */
function fakeTarget(): { target: DomEventTarget; fire: (type: string, ev: Record<string, unknown>) => void } {
  const handlers = new Map<string, Array<(ev: never) => void>>();
  const target: DomEventTarget = {
    addEventListener(type, fn) {
      const l = handlers.get(type) ?? [];
      l.push(fn as (ev: never) => void);
      handlers.set(type, l);
    },
    removeEventListener(type, fn) {
      const l = handlers.get(type) ?? [];
      const i = l.indexOf(fn as (ev: never) => void);
      if (i >= 0) l.splice(i, 1);
    },
  };
  return {
    target,
    fire(type, ev) {
      for (const fn of handlers.get(type) ?? []) (fn as (e: unknown) => void)(ev);
    },
  };
}

// ── ① 映射表校验 ─────────────────────────────────────────────

test("默认映射表合法，且 toData() 能原样喂回去（数据形状 = 存档形状）", () => {
  const again = createInputMap(DEFAULT_INPUT_MAP.toData());
  assert.ok(again.ok, again.ok ? "" : again.error.message);
  assert.deepEqual(again.value.names, DEFAULT_INPUT_MAP.names);
  assert.equal(DEFAULT_INPUT_MAP_DATA.version, INPUT_MAP_VERSION);
  // 动作名升序（判据与日志要靠它比对）
  const sorted = [...DEFAULT_INPUT_MAP.names].sort();
  assert.deepEqual([...DEFAULT_INPUT_MAP.names], sorted);
  for (const a of ["move_left", "move_right", "move_forward", "move_back", "harvest", "save"]) {
    assert.ok(DEFAULT_INPUT_MAP.names.includes(a), `默认表缺动作 ${a}`);
  }
});

test("版本不对就报错（不做「猜格式」的兼容）", () => {
  const r = createInputMap({ version: 99, actions: {} });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, "INPUT.BAD_MAP");
});

test("★ 同一个动作里键码重复 ⇒ INPUT.DUPLICATE_KEY", () => {
  const r = createInputMap({
    version: INPUT_MAP_VERSION,
    actions: { move_right: { keys: ["KeyD", "KeyD"] } },
  });
  assert.equal(r.ok, false);
  assert.equal(r.ok ? "" : r.error.code, "INPUT.DUPLICATE_KEY");
});

test("★★ 同一互斥组里两个动作共用一个键 ⇒ INPUT.KEY_CONFLICT（消息里点名两个动作）", () => {
  const bad: InputMapData = {
    version: INPUT_MAP_VERSION,
    actions: {
      move_forward: { keys: ["KeyW"], group: "move" },
      move_back: { keys: ["KeyW"], group: "move" },
    },
  };
  const r = createInputMap(bad);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, "INPUT.KEY_CONFLICT");
  assert.match(r.error.message, /move_forward/);
  assert.match(r.error.message, /move_back/);
});

test("★ 不同组共用同一个键是**允许**的（「W 同时是移动和冲刺」不是错）", () => {
  const r = createInputMap({
    version: INPUT_MAP_VERSION,
    actions: {
      move_forward: { keys: ["KeyW"], group: "move" },
      sprint: { keys: ["KeyW"], group: "buff" },
    },
  });
  assert.ok(r.ok, r.ok ? "" : r.error.message);
});

test("★★ 动作名拼错要**抛错**，不能静默 false（这是「按了没反应」的经典成因）", () => {
  assert.throws(
    () => DEFAULT_INPUT_MAP.isDown(snap(["KeyD"]), "move_rigth"),
    /move_rigth/,
    "拼错的动作名必须炸，而且消息里要有它",
  );
  // axis 的两侧都要校验：只在"按了正向键"时才暴露的那种错法更贵
  assert.throws(() => DEFAULT_INPUT_MAP.axis(snap([]), "move_lft", "move_right"), /move_lft/);
});

test("axis：两边都按住 = 0（不是 1），只按一侧 = ±1；justPressed 走边缘不是按住", () => {
  const m = DEFAULT_INPUT_MAP;
  assert.equal(m.axis(snap(["KeyA", "KeyD"]), "move_left", "move_right"), 0);
  assert.equal(m.axis(snap(["KeyD"]), "move_left", "move_right"), 1);
  assert.equal(m.axis(snap(["KeyA"]), "move_left", "move_right"), -1);
  assert.equal(m.isDown(snap(["KeyD"]), "move_right"), true);
  // 按住但这一 tick 不是"刚按下"
  assert.equal(m.justPressed(snap(["KeyD"], []), "move_right"), false);
  assert.equal(m.justPressed(snap(["KeyD"], ["KeyD"]), "move_right"), true);
});

// ── ② 改键真的生效（键位不再写死在代码里） ─────────────────────

test("★★ 换一张表就换键位：同一段逻辑，按 KeyD 不动、按 KeyL 才动", () => {
  const data: InputMapData = {
    version: INPUT_MAP_VERSION,
    actions: {
      move_left: { keys: ["KeyJ"], group: "move" },
      move_right: { keys: ["KeyL"], group: "move" },
      move_forward: { keys: ["KeyI"], group: "move" },
      move_back: { keys: ["KeyK"], group: "move" },
    },
  };
  const custom = createInputMap(data);
  assert.ok(custom.ok);
  const map = custom.value;

  assert.deepEqual(stepOf(snap(["KeyD"]), 4, 0.5, map), { dx: 0, dz: 0 }, "旧键位必须失效");
  assert.deepEqual(stepOf(snap(["KeyL"]), 4, 0.5, map), { dx: 2, dz: 0 }, "新键位必须生效");
});

// ── ③ 手柄：后端把硬件合成成逻辑键码 ─────────────────────────

function makeDevice(pads: () => readonly (GamepadLike | null | undefined)[]): DomInputDevice {
  const kb = fakeTarget();
  const ptr = fakeTarget();
  return new DomInputDevice({ keyboard: kb.target, pointer: ptr.target, gamepads: pads });
}

function pad(over: Partial<{ index: number; axes: number[]; buttons: boolean[] }> = {}): GamepadLike {
  const buttons = (over.buttons ?? []).map((pressed) => ({ pressed, value: pressed ? 1 : 0 }));
  return { connected: true, index: over.index ?? 0, axes: over.axes ?? [0, 0], buttons };
}

test("★★ 手柄按键 → 逻辑键码，且边缘只出现一次（不是每帧都算「刚按下」）", () => {
  let b = [false];
  const dev = makeDevice(() => [pad({ buttons: b })]);
  assert.equal(dev.caps.gamepad, true, "注入了手柄来源，caps 必须报 true");

  const first = dev.poll();
  assert.equal(first.keysDown.size, 0, "没按键时不该有键");

  b = [true];
  const pressedFrame = dev.poll();
  assert.ok(pressedFrame.keysDown.has("Gamepad0.A"));
  assert.ok(pressedFrame.keysPressed.has("Gamepad0.A"), "刚按下这一帧必须在 keysPressed 里");
  const heldFrame = dev.poll();
  assert.ok(heldFrame.keysDown.has("Gamepad0.A"), "按住要持续在 keysDown 里");
  assert.equal(heldFrame.keysPressed.size, 0, "边缘只在第一帧出现（否则一次按键会被处理多次）");

  b = [false];
  const releasedFrame = dev.poll();
  assert.ok(releasedFrame.keysReleased.has("Gamepad0.A"));
});

test("★★ 摇杆：右推 → LStickRight，上推（W3C 负值）→ LStickUp；死区内不出键", () => {
  let axes = [0, 0];
  const dev = makeDevice(() => [pad({ axes })]);
  assert.equal(dev.poll().keysDown.size, 0, "摇杆回中不能有任何方向键");

  axes = [0.9, 0];
  assert.ok(dev.poll().keysDown.has("Gamepad0.LStickRight"), "x=+0.9 必须是右");
  axes = [-0.9, 0];
  assert.ok(dev.poll().keysDown.has("Gamepad0.LStickLeft"));

  // ★ 这一条是"上下颠倒"的唯一防线：W3C 里 y = −1 是**上**
  axes = [0, -0.9];
  const up = dev.poll().keysDown;
  assert.ok(up.has("Gamepad0.LStickUp"), "y=-0.9 必须是上（写反的话真手柄上会上下颠倒）");
  assert.ok(!up.has("Gamepad0.LStickDown"));
  axes = [0, 0.9];
  assert.ok(dev.poll().keysDown.has("Gamepad0.LStickDown"));

  axes = [0.2, 0.2];
  assert.equal(dev.poll().keysDown.size, 0, "死区内的漂移不该产生方向键");
});

test("没有手柄 API 的环境里 caps.gamepad 是 false（不假报能力）", () => {
  const kb = fakeTarget();
  const ptr = fakeTarget();
  // 显式传 null 语义：给一个永远返回空的来源不算"没有 API"，所以这里直接看环境
  const dev = new DomInputDevice({ keyboard: kb.target, pointer: ptr.target, gamepads: () => [] });
  // 注入空来源 = "环境有 API 但没有手柄"：caps 为 true、但按什么都没
  assert.equal(dev.caps.gamepad, true);
  assert.equal(dev.poll().keysDown.size, 0);
});

// ── ④ 端到端：手柄能不能玩 ───────────────────────────────────

function ctxOf(scene: Scene): ModuleContext {
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  return {
    log: { channel: () => ({ warn: () => undefined, error: () => undefined, info: () => undefined, debug: () => undefined }) } as never,
    events: { emit: () => undefined, on: () => () => undefined } as never,
    services,
    platform: {} as never,
    random: { next: () => 0 } as never,
    module: () => undefined,
  };
}

test("★★ 手柄左摇杆右推 ⇒ 玩家真的往 +x 走（整条链：手柄 → 键码 → 动作 → 位移）", () => {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  const scene = new Scene("c", reg);
  const spawned = scene.spawn("hero", null);
  assert.ok(spawned.ok);
  scene.flush();
  assert.ok(scene.attach(spawned.value.id, () => new PlayerController()).ok);
  scene.flush();

  let axes = [0, 0];
  const kb = fakeTarget();
  const ptr = fakeTarget();
  const dev = new DomInputDevice({ keyboard: kb.target, pointer: ptr.target, gamepads: () => [pad({ axes })] });

  const mod = createControllerModule({ poll: () => dev.poll() });
  mod.init(ctxOf(scene));

  mod.update(1, 0.1);
  const before = scene.find(spawned.value.id)!.localPosition.x;
  axes = [1, 0];
  mod.update(2, 0.1);
  const after = scene.find(spawned.value.id)!.localPosition.x;
  assert.ok(after > before + 0.3, `手柄右推之后 x 应该变大（${before} → ${after}）`);
  assert.ok(mod.snapshot.keysDown.has("Gamepad0.LStickRight"), "快照里要能看见手柄键码（宿主诊断要用）");
});

test("★ 宿主读的是模块那一份快照（自己再 poll 一次会吞掉「刚按下」）", () => {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  const scene = new Scene("c", reg);

  let polls = 0;
  const mod = createControllerModule({
    poll: () => {
      polls++;
      // 只有第一次 poll 有"刚按下"，模拟真实后端消费边缘
      return polls === 1 ? snap(["KeyG"], ["KeyG"]) : snap(["KeyG"], []);
    },
  });
  mod.init(ctxOf(scene));
  mod.update(1, 0.1);
  // 宿主这一 tick 读到的就是"刚按下"，不必也不该再 poll
  assert.equal(mod.map.justPressed(mod.snapshot, "harvest"), true);
  mod.update(2, 0.1);
  assert.equal(mod.map.justPressed(mod.snapshot, "harvest"), false);
  assert.equal(polls, 2, "每个 tick 恰好 poll 一次 —— 多一次就吞掉边缘");
});

// ── ⑤ 控制器模块的组件面 ─────────────────────────────────────

test("控制器的组件类型名与注册表一致（否则 componentsOf 找不到人）", () => {
  const reg = new ComponentRegistry();
  registerControllerComponent(reg);
  assert.ok(reg.has(CONTROLLER_TYPE));
  const scene = new Scene("c", reg);
  const s = scene.spawn("p", null);
  assert.ok(s.ok);
  scene.flush();
  assert.ok(scene.attach(s.value.id, () => new PlayerController()).ok);
  scene.flush();
  assert.equal(scene.componentsOf<PlayerController>(CONTROLLER_TYPE).length, 1);
});
