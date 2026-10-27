/**
 * 脚本热重载（批104）—— `IScriptRuntime.loadModule` 的三条不变量
 *
 * 这一组守的是「边跑边改」这条路：热更最常见的用法是**改坏了中间态**，
 * 而运行中的游戏不能跟着一起坏。三条不变量：
 *
 *  ① **先编译后替换**：新源码编译失败 ⇒ 返回错误，旧模块还能照跑；
 *  ② **执行期出错同样不换**：编译通过但 chunk 抛错时，登记表一个字节不动；
 *  ③ **每次都造新的 env**：新版本看不到上一版的全局（`counter = 3` 不会残到新版）。
 *
 * ★ 为什么这三条必须是判据而不是注释：`runtime.ts` 的 Lua 前导里那两行
 *   `if not chunk then return {s=0}` / `if not ok then return {s=2}` 看起来像"多余的分支"
 *   —— 它们正是"改坏了不替换"的唯一实现。删掉之后**正常运行一条测试都不会红**
 *   （成功路径一模一样），只有热更中途失败的用例才会现形。M547–M549 就是照这三条打的。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { LuaScriptRuntime } from "../../src/backends/script-lua/runtime.ts";
import type { ScriptValue } from "../../src/platform/script/runtime.ts";
import { ScriptErrorCode } from "../../src/platform/script/runtime.ts";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import { Services } from "../../src/core/tokens.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Logger, LogLevel, MemorySink } from "../../src/foundation/log/logger.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { SystemClock } from "../../src/foundation/time/clock.ts";
import { BackendRegistry } from "../../src/platform/registry.ts";
import { createPlatform } from "../../src/platform/platform.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { ScriptComponent } from "../../src/extensions/script/script-component.ts";
import { createScriptModule } from "../../src/extensions/script/script-module.ts";

async function withLua(body: (rt: LuaScriptRuntime) => Promise<void>): Promise<void> {
  const rt = new LuaScriptRuntime();
  try {
    const ready = await rt.ready();
    assert.ok(ready.ok, "ready() 必须成功：" + (ready.ok ? "" : ready.error.message));
    await body(rt);
  } finally {
    rt.dispose();
  }
}

async function value(rt: LuaScriptRuntime, fn: string, args: readonly ScriptValue[] = []): Promise<ScriptValue> {
  const r = await rt.call(fn, args);
  assert.ok(r.ok, `call(${fn}) 应成功：${r.ok ? "" : r.error.message}`);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
}

const V1 = `
  counter = 0
  function bump() counter = counter + 1 return counter end
  function tag() return "v1" end
`;

// ---------------------------------------------------------------- ① 先编译后替换

test("★★ 热更成功：同名再加载 ⇒ 调用走新实现（旧函数被替换，不是并存）", async () => {
  await withLua(async (rt) => {
    assert.ok((await rt.loadModule("m", V1)).ok);
    assert.equal(await value(rt, "m.tag"), "v1");
    assert.equal(await value(rt, "m.bump"), 1);

    assert.ok((await rt.loadModule("m", `function tag() return "v2" end`)).ok);
    assert.equal(await value(rt, "m.tag"), "v2", "同名重载必须换实现");
    assert.equal(rt.listModules().length, 1, "是覆盖，不是登记第二个模块");
  });
});

test("★★ 编译失败：返回 LoadFailed，旧模块**还能照跑**（改坏的中间态不许打挂运行中的游戏）", async () => {
  await withLua(async (rt) => {
    assert.ok((await rt.loadModule("m", V1)).ok);
    assert.equal(await value(rt, "m.tag"), "v1");

    const bad = await rt.loadModule("m", `function oops( return "v2" end`); // 语法错
    assert.equal(bad.ok, false, "语法错的源码不该被当成成功");
    if (bad.ok) return;
    assert.equal(bad.error.code, ScriptErrorCode.LoadFailed);

    assert.equal(await value(rt, "m.tag"), "v1", "编译失败之后旧模块必须原样还在");
    assert.equal(await value(rt, "m.bump"), 1, "旧模块的**状态**也在（不是换成一个空模块）");
    assert.equal(rt.hasModule("m"), true);
    assert.deepEqual([...rt.listModules()], ["m"], "登记表不该被半新半旧改掉");
  });
});

test("★★ 执行期出错：同样不替换（编译通过 ≠ 能跑）", async () => {
  await withLua(async (rt) => {
    assert.ok((await rt.loadModule("m", V1)).ok);
    assert.equal(await value(rt, "m.bump"), 1);

    const boom = await rt.loadModule("m", `error("加载时就炸了")`);
    assert.equal(boom.ok, false, "chunk 执行期抛错必须报失败");
    if (boom.ok) return;
    assert.equal(boom.error.code, ScriptErrorCode.LoadFailed);

    assert.equal(await value(rt, "m.tag"), "v1", "旧模块还得能调");
    assert.equal(await value(rt, "m.bump"), 2, "而且状态是接着旧的走（1 → 2）");
  });
});

test("★ 热更之后旧全局不残留：新版本读到的是 nil（不是上一版的 3）", async () => {
  await withLua(async (rt) => {
    assert.ok((await rt.loadModule("m", V1)).ok);
    await value(rt, "m.bump");
    await value(rt, "m.bump");
    // 新版本里**没有** `counter = 0` ⇒ 读到的任何数字都只可能来自没被丢弃的旧 env
    assert.ok((await rt.loadModule("m", `function peek() return counter end`)).ok);
    assert.equal(await value(rt, "m.peek"), null);
  });
});

// ---------------------------------------------------------------- 端到端：下一 tick 就换

function makeHarness(rt: LuaScriptRuntime): ModuleContext {
  const reg = new BackendRegistry();
  registerNullBackends(reg);
  const p = createPlatform({ id: "test", interactive: false, registry: reg, clock: new SystemClock() });
  if (!p.ok) throw new Error("测试平台起不来：" + p.error.message);

  const components = new ComponentRegistry();
  components.register(new ScriptComponent().schema, () => new ScriptComponent());
  const scene = new Scene("test", components);
  const services = new ServiceRegistry();
  services.provide(Services.Scene, scene, "test");
  services.provide(Services.Script, rt, "test");

  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Info);
  log.addSink(new MemorySink());

  return {
    log,
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: p.value,
    random: new XorShift128(1),
    module: () => undefined,
  };
}

test("★★ 端到端：热更之后**下一个 tick** 就执行新代码（不是下次重启才生效）", async () => {
  const rt = new LuaScriptRuntime();
  const ready = await rt.ready();
  assert.ok(ready.ok);
  const ctx = makeHarness(rt);
  try {
    assert.ok(
      (await rt.loadModule(
        "hp",
        `function onUpdate() last = "v1" end
         function peek() return last end`,
      )).ok,
    );
    const scene = ctx.services.get(Services.Scene) as Scene;
    const node = scene.spawnImmediate("hp");
    scene.attach(node.id, () => {
      const c = new ScriptComponent();
      c.module = "hp";
      c.entry = "onUpdate";
      return c;
    });
    scene.flush();

    const mod = createScriptModule();
    assert.ok((await mod.init(ctx)).ok);
    mod.start?.();
    await mod.update(1, 0.25);
    assert.equal(await value(rt, "hp.peek"), "v1");

    // 热更：换成写 v2 的版本
    assert.ok((await rt.loadModule("hp", `function onUpdate() last = "v2" end\n function peek() return last end`)).ok);
    await mod.update(2, 0.25);
    assert.equal(await value(rt, "hp.peek"), "v2", "下一 tick 就该用新代码 —— 否则热更等于没用");

    mod.dispose();
  } finally {
    rt.dispose();
  }
});
