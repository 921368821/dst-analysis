/**
 * 脚本模块（`script.lua`）
 *
 * 这里守的是**帧级行为**，不是接口语义（后者在 `tests/contract/script.contract.ts`）：
 *   · `onUpdate(nodeId, dt, tick)` 的参数真的按这个顺序到脚本；
 *   · 一个脚本 `error()` 不能让同帧其他脚本不执行（异常隔离）；
 *   · `script:error` 必须被发出、日志必须含错误（否则只是"某个东西不动了"）；
 *   · `engine_spawn` 走命令队列：调用当下节点**还不在树里**，flush 后才出现；
 *   · `init` 在"没有脚本能力"时失败（不静默降级）；
 *   · `dispose` 只清自己，不关平台持有的 runtime。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ModuleRegistry, type ModuleContext } from "../../src/core/module/module.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import { Services } from "../../src/core/tokens.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Logger, LogLevel, MemorySink } from "../../src/foundation/log/logger.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { SystemClock } from "../../src/foundation/time/clock.ts";
import { BackendRegistry } from "../../src/platform/registry.ts";
import { createPlatform, type IPlatform } from "../../src/platform/platform.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { NullScriptRuntime } from "../../src/backends/script-null/runtime.ts";
import { LuaScriptRuntime } from "../../src/backends/script-lua/runtime.ts";
import type { IScriptRuntime } from "../../src/platform/script/runtime.ts";
import { ScriptErrorCode } from "../../src/platform/script/runtime.ts";
import { SCRIPT_COMPONENT_TYPE, ScriptComponent } from "../../src/extensions/script/script-component.ts";
import { createScriptModule } from "../../src/extensions/script/script-module.ts";

interface Harness {
  readonly ctx: ModuleContext;
  readonly scene: Scene;
  readonly events: EventBus<Record<string, unknown>>;
  readonly log: Logger;
  readonly sink: MemorySink;
}

function makePlatform(): IPlatform {
  const reg = new BackendRegistry();
  registerNullBackends(reg);
  const p = createPlatform({ id: "test", interactive: false, registry: reg, clock: new SystemClock() });
  if (!p.ok) throw new Error("测试平台起不来：" + p.error.message);
  return p.value;
}

function makeHarness(script: IScriptRuntime | null, registerComponent = true): Harness {
  const services = new ServiceRegistry();
  const components = new ComponentRegistry();
  if (registerComponent) {
    components.register(new ScriptComponent().schema, () => new ScriptComponent());
  }
  const scene = new Scene("test", components);
  services.provide(Services.Scene, scene, "test");
  services.provide(Services.Script, script, "test");

  const sink = new MemorySink();
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Info);
  log.addSink(sink);

  const events = new EventBus<Record<string, unknown>>();
  const ctx: ModuleContext = {
    log,
    events,
    services,
    platform: makePlatform(),
    random: new XorShift128(1),
    module: () => undefined,
  };
  return { ctx, scene, events, log, sink };
}

/** 挂一个 `game.script` 组件，并 flush 到 Scene 的类型索引里。 */
function addScriptNode(scene: Scene, module: string, entry = "onUpdate"): number {
  const node = scene.spawnImmediate(module);
  scene.attach(node.id, () => {
    const c = new ScriptComponent();
    c.module = module;
    c.entry = entry;
    return c;
  });
  scene.flush();
  return node.id;
}

async function makeLua(): Promise<LuaScriptRuntime> {
  const rt = new LuaScriptRuntime();
  const ready = await rt.ready();
  assert.ok(ready.ok, "Lua 启动失败：" + (ready.ok ? "" : ready.error.message));
  return rt;
}

test("[script-module] onUpdate(nodeId, dt, tick)：推进 3 tick，脚本侧计数与参数精确", async () => {
  const rt = await makeLua();
  const h = makeHarness(rt);
  assert.ok(
    (await rt.loadModule(
      "counter",
      `count = 0
       last_node = 0
       last_dt = 0
       last_tick = -1
       function onUpdate(nodeId, dt, t)
         count = count + 1
         last_node = nodeId
         last_dt = dt
         last_tick = t
       end
       function snapshot() return { count = count, node = last_node, dt = last_dt, tick = last_tick } end`,
    )).ok,
  );

  const nodeId = addScriptNode(h.scene, "counter");
  const mod = createScriptModule();
  const init = await mod.init(h.ctx);
  assert.ok(init.ok, "init 应成功：" + (init.ok ? "" : init.error.message));
  mod.start?.();

  await mod.update(1, 0.25);
  await mod.update(2, 0.25);
  await mod.update(3, 0.25);

  const snap = await rt.call("snapshot");
  assert.ok(snap.ok, "snapshot 应成功：" + (snap.ok ? "" : snap.error.message));
  if (snap.ok) {
    assert.deepEqual(snap.value, { count: 3, node: nodeId, dt: 0.25, tick: 3 });
  }
  // 3 次 onUpdate + 1 次 snapshot
  assert.equal(rt.stats().calls, 4);
  assert.equal(rt.stats().errors, 0);
  mod.dispose();
  rt.dispose();
});

test("[script-module] 一个脚本 error()：同帧另一个仍执行，日志 + script:error 事件都在", async () => {
  const rt = await makeLua();
  const h = makeHarness(rt);
  assert.ok(
    (await rt.loadModule("bad.script", `function onUpdate() error("boom-module") end`)).ok,
  );
  assert.ok(
    (await rt.loadModule(
      "good.script",
      `hits = 0
       function onUpdate() hits = hits + 1 end
       function hits_count() return hits end`,
    )).ok,
  );

  addScriptNode(h.scene, "bad.script"); // 故意把会失败的排在前面
  addScriptNode(h.scene, "good.script");

  const errors: Array<Record<string, unknown>> = [];
  h.events.on("script:error", (p) => errors.push(p as Record<string, unknown>));

  const mod = createScriptModule();
  assert.ok((await mod.init(h.ctx)).ok);
  mod.start?.();

  await mod.update(1, 0.1);

  assert.equal(errors.length, 1, "必须发一次 script:error");
  const ev = errors[0]!;
  assert.equal(ev["module"], "bad.script");
  assert.equal(ev["fn"], "onUpdate");
  assert.equal(ev["code"], ScriptErrorCode.CallFailed);
  assert.match(String(ev["message"]), /boom-module/);

  assert.ok(h.sink.has(LogLevel.Error, "boom-module"), "日志必须含 Lua 原始信息");
  const logged = h.sink.byChannel("script").filter((r) => r.level >= LogLevel.Error);
  assert.equal(logged.length, 1);
  assert.equal(logged[0]!.fields?.["code"], ScriptErrorCode.CallFailed);

  // 关键：同帧另一个脚本必须已经执行
  const hits = await rt.call("hits_count");
  assert.ok(hits.ok);
  if (hits.ok) assert.equal(hits.value, 1, "异常隔离失败：一个脚本挂了让同帧其他脚本没跑");

  mod.dispose();
  rt.dispose();
});

test("[script-module] engine_spawn 走命令队列：flush 前不在树里，flush 后存在且 id 非 0", async () => {
  const rt = await makeLua();
  const h = makeHarness(rt);
  assert.ok(
    (await rt.loadModule(
      "spawner",
      `spawned = 0
       function onUpdate()
         spawned = engine_spawn("crab", 3, 4)
       end
       function spawned_id() return spawned end
       function pos_of(id) return engine_get_pos(id) end
       function scripts() return engine_count("game.script") end`,
    )).ok,
  );

  addScriptNode(h.scene, "spawner");
  const mod = createScriptModule();
  assert.ok((await mod.init(h.ctx)).ok);
  mod.start?.();

  await mod.update(1, 0.1);

  const idResult = await rt.call("spawned_id");
  assert.ok(idResult.ok);
  if (!idResult.ok) throw new Error("unreachable");
  const id = idResult.value;
  assert.equal(typeof id, "number");
  assert.notEqual(id, 0, "engine_spawn 必须立刻返回可用 id（脚本要用它做后续调用）");
  if (typeof id !== "number") throw new Error("unreachable");

  // ★ 还没 flush：结构性修改只在队列里，树没变
  assert.equal(h.scene.find(id), undefined, "脚本调用期间不许直接改树（ADR 0004）");
  assert.ok(h.scene.pendingCount >= 1, "spawn 必须进命令队列");

  h.scene.flush();
  const node = h.scene.find(id);
  assert.ok(node !== undefined, "flush 后节点必须存在");
  if (node !== undefined) {
    assert.equal(node.name, "crab");
    assert.deepEqual(
      { x: node.worldPosition.x, z: node.worldPosition.y },
      { x: 3, z: 4 },
    );
  }

  // 脚本也能读回位置与组件计数
  const pos = await rt.call("pos_of", [id]);
  assert.ok(pos.ok);
  if (pos.ok) assert.deepEqual(pos.value, { x: 3, z: 4 });
  const scripts = await rt.call("scripts");
  assert.ok(scripts.ok);
  if (scripts.ok) assert.equal(scripts.value, 1);

  mod.dispose();
  rt.dispose();
});

test("[script-module] init：没有脚本能力 → NOT_SUPPORTED（不静默降级）", async () => {
  const nullRuntime = new NullScriptRuntime();
  const h1 = makeHarness(nullRuntime);
  const r1 = await createScriptModule().init(h1.ctx);
  assert.equal(r1.ok, false);
  if (!r1.ok) {
    assert.equal(r1.error.code, ScriptErrorCode.NotSupported);
    assert.match(r1.error.message, /不能执行/);
    assert.match(r1.error.message, /不静默降级/);
  }
  nullRuntime.dispose();

  const h2 = makeHarness(null);
  const r2 = await createScriptModule().init(h2.ctx);
  assert.equal(r2.ok, false);
  if (!r2.ok) {
    assert.equal(r2.error.code, ScriptErrorCode.NotSupported);
    assert.match(r2.error.message, /null/);
  }
});

test("[script-module] init：宿主根本没提供 core.script ⇒ 报接线缺失（与'平台不支持'区分）", async () => {
  const h = makeHarness(null);
  h.ctx.services.revoke(Services.Script);
  const r = await createScriptModule().init(h.ctx);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, ScriptErrorCode.NotSupported);
    assert.match(r.error.message, /接线缺失/);
  }
});

test("[script-module] dispose 不释放平台持有的 runtime（释放权在平台）", async () => {
  const rt = await makeLua();
  const h = makeHarness(rt);
  assert.ok((await rt.loadModule("keep", `function ping() return "pong" end`)).ok);

  const mod = createScriptModule();
  assert.ok((await mod.init(h.ctx)).ok);
  mod.start?.();
  mod.dispose();

  // 模块已释放，但 runtime 仍应可用 —— 它可能还被 AI/UI 模块持有
  const r = await rt.call("ping");
  assert.ok(r.ok, "模块 dispose 不能把平台的 runtime 关掉");
  if (r.ok) assert.equal(r.value, "pong");
  assert.equal(mod.runtime, null);
  rt.dispose();
});

test("[script-module] 生命周期：可以被 ModuleRegistry 正常启动/释放（与 render/physics 同形）", async () => {
  const rt = await makeLua();
  // 故意不预注册：这里要验证的是 ScriptModule.start 自己登记 game.script
  const h = makeHarness(rt, false);
  assert.equal(h.scene.components.has(SCRIPT_COMPONENT_TYPE), false);
  const mod = createScriptModule();
  const reg = new ModuleRegistry(h.ctx);
  assert.ok(reg.register(mod).ok);

  const started = await reg.start();
  assert.ok(started.ok, "启动失败：" + (started.ok ? "" : started.error.message));
  assert.equal(h.scene.components.has(SCRIPT_COMPONENT_TYPE), true, "start 应登记 game.script 组件");

  const disposed = await reg.dispose();
  assert.ok(disposed.ok);
  rt.dispose();
});
