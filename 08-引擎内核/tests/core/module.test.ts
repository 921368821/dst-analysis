/**
 * L2 · 模块系统测试
 *
 * 模块系统是"新增功能不改内核"的前提，所以它的失败模式必须全部覆盖：
 *  · 启动顺序错（依赖没先起）
 *  · 循环依赖（没有"谁先起"的答案）
 *  · 部分启动（一个失败但其他还在跑 ⇒ 半死的引擎）
 *  · 释放顺序错（先释放被依赖的）
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ModuleRegistry, ModuleState, type IModule, type ModuleContext } from "../../src/core/module/module.ts";
import { Logger, LogLevel } from "../../src/foundation/log/logger.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import { BackendRegistry } from "../../src/platform/registry.ts";
import { createPlatform, type IPlatform } from "../../src/platform/platform.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { SystemClock } from "../../src/foundation/time/clock.ts";

function ctxOf(): ModuleContext {
  const reg = new BackendRegistry();
  registerNullBackends(reg);
  const p = createPlatform({
    id: "test",
    interactive: false,
    registry: reg,
    clock: new SystemClock(),
  });
  if (!p.ok) throw new Error("测试平台起不来：" + p.error.message);
  const platform: IPlatform = p.value;
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Off);
  return {
    log,
    events: new EventBus<Record<string, unknown>>(),
    services: new ServiceRegistry(),
    platform,
    random: new XorShift128(1),
    module: () => undefined,
  };
}

function mod(id: string, trace: string[], deps: string[] = [], failInit = false): IModule {
  return {
    id,
    deps,
    init(): { ok: true; value: undefined } | { ok: false; error: { code: string; message: string } } {
      if (failInit) return { ok: false, error: { code: "TEST.FAIL", message: id + " 故意失败" } };
      trace.push("init:" + id);
      return { ok: true, value: undefined };
    },
    start(): void {
      trace.push("start:" + id);
      // 不返回 Result：ModuleHookResult 允许 void（"start 通常不会失败"）
    },
    stop(): void {
      trace.push("stop:" + id);
    },
    dispose(): void {
      trace.push("dispose:" + id);
    },
  };
}

test("启动按拓扑序（依赖在前），与注册顺序无关", async () => {
  const trace: string[] = [];
  const reg = new ModuleRegistry(ctxOf());
  // 故意倒着注册
  reg.register(mod("c", trace, ["b"]));
  reg.register(mod("b", trace, ["a"]));
  reg.register(mod("a", trace));
  const r = await reg.start();
  assert.ok(r.ok);
  const initOrder = trace.filter((t) => t.startsWith("init:"));
  assert.deepEqual(initOrder, ["init:a", "init:b", "init:c"]);
});

test("释放是启动的逆序（先停后起的，先释放后 init 的）", async () => {
  const trace: string[] = [];
  const reg = new ModuleRegistry(ctxOf());
  reg.register(mod("a", trace));
  reg.register(mod("b", trace, ["a"]));
  await reg.start();
  trace.length = 0;
  await reg.dispose();
  assert.deepEqual(trace, [
    "stop:b",
    "dispose:b",
    "stop:a",
    "dispose:a",
  ]);
});

test("循环依赖：明确报错并点名环上的模块（不是栈溢出、不是静默）", async () => {
  const trace: string[] = [];
  const reg = new ModuleRegistry(ctxOf());
  reg.register(mod("a", trace, ["c"]));
  reg.register(mod("b", trace, ["a"]));
  reg.register(mod("c", trace, ["b"]));
  const r = await reg.start();
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "MODULE.CYCLE");
    assert.match(r.error.message, /a, b, c|a, c, b/, "错误必须点名环上的模块");
  }
  assert.deepEqual(trace, [], "有环时一个模块都不该被 init");
});

test("缺失硬依赖：拒绝启动（不许'少一个也能跑'）", async () => {
  const trace: string[] = [];
  const reg = new ModuleRegistry(ctxOf());
  reg.register(mod("a", trace, ["ghost"]));
  const r = await reg.start();
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "MODULE.MISSING_DEP");
});

test("init 失败：已 init 的模块被逆序回滚（不留半启动状态）", async () => {
  const trace: string[] = [];
  const reg = new ModuleRegistry(ctxOf());
  reg.register(mod("a", trace));
  reg.register(mod("b", trace, ["a"]));
  reg.register(mod("c", trace, ["b"], /* failInit */ true));
  const r = await reg.start();
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "MODULE.INIT_FAILED");
    assert.match(r.error.message, /c/);
  }
  // a、b 应被 dispose（c 失败后回滚）
  assert.ok(trace.includes("dispose:b"), "b 应被回滚释放：" + trace.join(","));
  assert.ok(trace.includes("dispose:a"), "a 应被回滚释放：" + trace.join(","));
  assert.equal(reg.state("a"), ModuleState.Disposed);
});

test("重复 id 与启动后注册都被拒绝（不允许隐式热插拔）", async () => {
  const trace: string[] = [];
  const reg = new ModuleRegistry(ctxOf());
  assert.ok(reg.register(mod("a", trace)).ok);
  const dup = reg.register(mod("a", trace));
  assert.equal(dup.ok, false);
  if (!dup.ok) assert.equal(dup.error.code, "MODULE.DUPLICATE_ID");

  await reg.start();
  const late = reg.register(mod("late", trace));
  assert.equal(late.ok, false);
  if (!late.ok) assert.equal(late.error.code, "MODULE.REGISTER_AFTER_START");
});

test("两个同层无依赖模块的启动顺序稳定（按 id 字典序，保证可回放）", async () => {
  const runOnce = async (): Promise<string[]> => {
    const trace: string[] = [];
    const reg = new ModuleRegistry(ctxOf());
    reg.register(mod("zeta", trace));
    reg.register(mod("alpha", trace));
    reg.register(mod("mike", trace));
    await reg.start();
    return trace.filter((t) => t.startsWith("init:")).map((t) => t.slice(5));
  };
  const a = await runOnce();
  const b = await runOnce();
  assert.deepEqual(a, ["alpha", "mike", "zeta"]);
  assert.deepEqual(a, b, "两次运行顺序必须一致 —— 否则回放不可复现");
});
