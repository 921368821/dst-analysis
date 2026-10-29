/**
 * 注入式输入后端：宿主已有的设备能不能真的接到平台上。
 *
 * ★ 这条判据要防的不是"函数写错了"，而是下面这种**看起来全对**的状态：
 *   wx 宿主把触摸翻译成了逻辑键（那边 37 条判据全绿），但平台里跑的是
 *   `input-null`（因为 `input-dom` 在小游戏里 probe 不过）——
 *   于是"触摸能用了"与"游戏收不到按键"同时成立，而两边各自的判据都是绿的。
 *   判别法：**读平台自己的 `input.caps.backend`**，不是读宿主那个对象。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { BackendRegistry } from "../../src/platform/registry.ts";
import { createPlatform } from "../../src/platform/platform.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { NullInputDevice } from "../../src/backends/input-null/device.ts";
import {
  INJECTED_INPUT_ID,
  injectedInputBackend,
} from "../../src/backends/input-injected/device.ts";

function registryWithInjected(): BackendRegistry {
  const reg = new BackendRegistry();
  registerNullBackends(reg);
  reg.registerInput(injectedInputBackend, injectedInputBackend.priority);
  return reg;
}

test("★ 注入的设备就是平台拿到的那个对象（不复制、不代理）", () => {
  const reg = registryWithInjected();
  const device = new NullInputDevice();
  const p = createPlatform({
    id: "test",
    interactive: true,
    registry: reg,
    prefer: { input: INJECTED_INPUT_ID },
    backendOptions: { input: { device } },
  });
  assert.equal(p.ok, true, "平台该建起来");
  if (!p.ok) return;
  assert.equal(p.value.input, device, "必须是同一个实例：代理会各 poll 一次，边缘被清两次");
  assert.equal(p.value.input.caps.backend, "null", "caps 也应当透传自被注入的设备");
  p.value.dispose();
});

test("★★ 没有 device 时 prefer 它必须报错，不许静默退回 null", () => {
  const reg = registryWithInjected();
  const p = createPlatform({
    id: "test",
    interactive: true,
    registry: reg,
    prefer: { input: INJECTED_INPUT_ID },
    // ★ 必须点名 strict：注册表的默认语义是"挑不到就继续往下挑"，
    //   而宿主明说了"输入不能降级"才是那条纪律（见 `PlatformRequest.strict`）。
    strict: ["input"],
  });
  // 静默退回的症状是"游戏起来了但按什么都没反应"—— 与"输入没接好"在画面上一样
  assert.equal(p.ok, false, "缺 device 还建成功就是静默降级");
  const msg = p.ok ? "" : JSON.stringify(p.error);
  // ★ 这里只能断到「哪个后端没成」，断不到 `INPUT.NO_DEVICE`：
  //   `prefer` 分支先看 `probe`，probe 为 false 时根本走不到 `create`（那句才带具体原因）。
  //   两条断言分开写，是为了让"文案变差了"与"行为变差了"不会混成同一个红。
  assert.ok(msg.includes("BACKEND.UNAVAILABLE"), `该是聚合错误，实际：${msg}`);
  assert.ok(msg.includes("prefer=injected"), `要点名是哪个后端没成，实际：${msg}`);
});

test("★★ 给了 device 就该用它（与是否 prefer 无关）", () => {
  // ★ 这条纠正了一个想当然的假设：以为"必须 prefer 才生效"。实际 probe 看的是
  //   **options 里有没有 device** —— 而"宿主交了一个输入设备"本身就是意图，
  //   再要求它写一遍 prefer 只会多一个"忘了写"的失效点。
  //   真正要防的是相反的情况：没给 device 时被选中（下一条判据）。
  const reg = registryWithInjected();
  const device = new NullInputDevice();
  const p = createPlatform({
    id: "test",
    interactive: true,
    registry: reg,
    backendOptions: { input: { device } },
  });
  assert.equal(p.ok, true);
  if (!p.ok) return;
  assert.equal(p.value.input, device, "给了设备却仍然用 null 后端，等于注入没生效");
  p.value.dispose();
});

test("★★ 没给 device 时它不会被自动选中（否则浏览器宿主会莫名换成注入后端）", () => {
  const reg = registryWithInjected();
  const p = createPlatform({ id: "test", interactive: true, registry: reg });
  assert.equal(p.ok, true);
  if (!p.ok) return;
  assert.equal(p.value.backends.input, "null", "没有注入意图时该老老实实用 null");
  p.value.dispose();
});

test("★ probe 只看 options.device：undefined 与 null 都算没给", () => {
  assert.equal(injectedInputBackend.probe(undefined), false);
  assert.equal(injectedInputBackend.probe({}), false);
  assert.equal(injectedInputBackend.probe({ device: null }), false);
  assert.equal(injectedInputBackend.probe({ device: new NullInputDevice() }), true);
});
