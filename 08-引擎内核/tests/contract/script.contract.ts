/**
 * 脚本运行时契约（`IScriptRuntime`）
 *
 * ★ 这个文件回答的是"接口有没有歧义"，不是"某个后端能不能跑"。
 *   同一套用例跑在 null / lua（将来还有 js/host）上；任何一条只在某个后端
 *   成立，就说明接口语义没定义清楚，而不是"那个后端有 bug"。
 *
 * 分两档：
 *   · `executes === true`  → 全部条目（执行、热重载、错误隔离、超时、值往返、统计）
 *   · `executes === false` → 降级契约（诚实地说"不能执行"，而不是假装成功）
 *
 * ★ 每条都断言**具体的 code / 具体值 / 具体计数**。
 *   `assert.ok(r.ok)` 这种断言守不住"错误码写错"、"超时没计数"、"错误后运行时坏了" ——
 *   而那三类恰恰是脚本层最容易静默出事的地方。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import {
  ScriptErrorCode,
  type IScriptRuntime,
  type ScriptValue,
} from "../../src/platform/script/runtime.ts";

export interface ScriptContractTarget {
  /** 每次新建一个**未 ready** 的运行时（ready 由契约调用，便于先断言初始化语义）。 */
  make(): Promise<IScriptRuntime>;
}

const fnArg = (): ScriptValue => (() => "nope") as unknown as ScriptValue;

function assertCode(r: Result<unknown, EngineError>, code: string, what: string): void {
  assert.equal(r.ok, false, `${what} 必须失败`);
  if (!r.ok) assert.equal(r.error.code, code, `${what} 的 code 应为 ${code}，实际 ${r.error.code}（${r.error.message}）`);
}

async function withRuntime(
  target: ScriptContractTarget,
  body: (rt: IScriptRuntime) => Promise<void>,
): Promise<void> {
  const rt = await target.make();
  try {
    const ready = await rt.ready();
    assert.ok(ready.ok, "ready() 必须成功：" + (ready.ok ? "" : ready.error.message));
    await body(rt);
  } finally {
    rt.dispose();
  }
}

/** 加载后立刻断言成功（失败时把 Lua 原始信息带出来，否则只剩 "false !== true"）。 */
async function load(rt: IScriptRuntime, name: string, source: string): Promise<void> {
  const r = await rt.loadModule(name, source);
  assert.ok(r.ok, `loadModule(${name}) 失败：${r.ok ? "" : r.error.message}`);
}

function valueOf(r: Result<ScriptValue, EngineError>, what: string): ScriptValue {
  assert.ok(r.ok, `${what} 应成功：${r.ok ? "" : r.error.message}`);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
}

// ------------------------------------------------------------------ 全量契约

function registerFullContract(label: string, target: ScriptContractTarget): void {
  test(`[${label}] 能力描述：executes=true 就必须四件事齐全`, async () => {
    const rt = await target.make();
    try {
      assert.equal(rt.caps.executes, true);
      assert.ok(rt.caps.language.length > 0);
      assert.notEqual(rt.caps.version, null, "能执行就必须报告语言版本");
      assert.equal(rt.caps.interruptible, true, "声明 executes 却打不断死循环 = 声明一半");
      assert.equal(rt.caps.hostCalls, true);
      assert.deepEqual(rt.stats(), { modules: 0, calls: 0, errors: 0, timeouts: 0 });
    } finally {
      rt.dispose();
    }
  });

  test(`[${label}] loadModule 后能执行 —— 守"加载了但没真跑"`, async () => {
    await withRuntime(target, async (rt) => {
      await load(rt, "greet", `function greet(n) return "hi "..n end`);
      const r = await rt.call("greet", ["x"]);
      assert.equal(valueOf(r, "greet('x')"), "hi x");
      assert.equal(rt.hasModule("greet"), true);
      assert.deepEqual(rt.listModules(), ["greet"]);
      assert.equal(rt.stats().modules, 1);
    });
  });

  test(`[${label}] 同名重载覆盖 —— 守"第二次加载被拒/旧定义残留"`, async () => {
    await withRuntime(target, async (rt) => {
      await load(rt, "hot", `function ver() return 1 end`);
      assert.equal(valueOf(await rt.call("ver"), "第一次 ver()"), 1);

      await load(rt, "hot", `function ver() return 2 end`);
      assert.equal(valueOf(await rt.call("ver"), "重载后 ver()"), 2, "热重载必须真的换掉旧定义");
      assert.equal(rt.stats().modules, 1, "同名重载是覆盖，不是登记第二个模块");
      assert.deepEqual(rt.listModules(), ["hot"]);
    });
  });

  test(`[${label}] 语法错误 → LOAD_FAILED 且旧模块仍可调用 —— 守"坏热重载把线上打挂"`, async () => {
    await withRuntime(target, async (rt) => {
      await load(rt, "stable", `function ver() return 1 end`);
      const bad = await rt.loadModule("stable", `function ver( end`);
      assertCode(bad, ScriptErrorCode.LoadFailed, "语法错误");
      if (!bad.ok) assert.ok(bad.error.message.length > 0, "LOAD_FAILED 必须带诊断信息（不能只说'失败'）");

      // 这一条是重点：编译失败**不许**影响已经加载的模块
      assert.equal(valueOf(await rt.call("ver"), "语法错误后旧 ver()"), 1);
      assert.equal(rt.hasModule("stable"), true);
      assert.equal(rt.stats().modules, 1, "失败的加载不该登记模块");
    });
  });

  test(`[${label}] 未知函数 → NO_FUNCTION（不是 Lua 原文的错误）`, async () => {
    await withRuntime(target, async (rt) => {
      const r = await rt.call("definitely_absent");
      assertCode(r, ScriptErrorCode.NoFunction, "调用不存在的函数");
      if (!r.ok) {
        assert.doesNotMatch(
          r.error.message,
          /attempt to call a nil value/,
          "必须给出可判定的 code，而不是把解释器原文透传",
        );
      }
    });
  });

  test(`[${label}] 脚本 error() → CALL_FAILED，且随后调用仍成功 —— 守"一次异常毒死整个 VM"`, async () => {
    await withRuntime(target, async (rt) => {
      await load(
        rt,
        "err",
        `function boom() error("boom-42") end
         function greet(n) return "hi "..n end`,
      );

      const bad = await rt.call("boom");
      assertCode(bad, ScriptErrorCode.CallFailed, "脚本 error()");
      if (!bad.ok) assert.match(bad.error.message, /boom-42/, "必须保留 Lua 原始信息（否则无法定位）");

      const good = await rt.call("greet", ["y"]);
      assert.equal(valueOf(good, "错误后的 greet('y')"), "hi y", "运行时必须仍然可用");
      assert.equal(rt.stats().errors, 1, "只该记一次失败");
    });
  });

  test(`[${label}] expose：number/string/bool/表 往返正确`, async () => {
    await withRuntime(target, async (rt) => {
      // 原样返回：只测"跨界后值和类型都还在"，不掺杂业务
      const e = rt.expose("host_echo", (v) => v);
      assert.ok(e.ok, "expose 应成功：" + (e.ok ? "" : e.error.message));
      assert.deepEqual(rt.exposed(), ["host_echo"]);

      await load(
        rt,
        "host",
        `function roundtrip(n, s, b, t)
           local rt = host_echo(t)
           return { rt.arr[1], rt.arr[2], rt.k, host_echo(n), host_echo(s), host_echo(b) }
         end`,
      );

      const r = await rt.call("roundtrip", [7, "s", false, { arr: [1, 2], k: "v" }]);
      assert.deepEqual(valueOf(r, "roundtrip"), [1, 2, "v", 7, "s", false]);
    });
  });

  test(`[${label}] 宿主函数抛异常 → 脚本 pcall 捕获，运行时仍可用`, async () => {
    await withRuntime(target, async (rt) => {
      const e = rt.expose("host_boom", () => {
        throw new Error("host exploded");
      });
      assert.ok(e.ok);

      await load(
        rt,
        "pcall",
        `function try_boom()
           local ok = pcall(host_boom)
           return ok
         end
         function ping() return "pong" end`,
      );

      assert.equal(valueOf(await rt.call("try_boom"), "try_boom"), false, "pcall 应返回 false");
      assert.equal(valueOf(await rt.call("ping"), "异常后的 ping"), "pong");
      assert.equal(
        rt.stats().errors,
        0,
        "异常被脚本 pcall 捕获 ⇒ 对 runtime 而言这次调用是成功的（不能虚报错误）",
      );
    });
  });

  test(`[${label}] 死循环 + timeoutMs → TIMEOUT，且随后调用仍成功`, async () => {
    await withRuntime(target, async (rt) => {
      await load(
        rt,
        "spin",
        `function spin() while true do end end
         function ping() return "pong" end`,
      );
      const t0 = Date.now();
      const r = await rt.call("spin", [], { timeoutMs: 200 });
      const elapsed = Date.now() - t0;
      assertCode(r, ScriptErrorCode.Timeout, "死循环");
      assert.ok(elapsed < 5000, `超时必须真的打断（耗时 ${elapsed} ms）`);

      assert.equal(valueOf(await rt.call("ping"), "超时后的 ping"), "pong", "打断后运行时必须可用");
      assert.equal(rt.stats().timeouts, 1);
      assert.equal(rt.stats().errors, 1, "超时计入 errors");
    });
  });

  test(`[${label}] 非法参数（函数 / NaN）→ BAD_VALUE`, async () => {
    await withRuntime(target, async (rt) => {
      await load(rt, "v", `function id(x) return x end`);
      assertCode(await rt.call("id", [fnArg()]), ScriptErrorCode.BadValue, "函数作参数");
      assertCode(await rt.call("id", [Number.NaN]), ScriptErrorCode.BadValue, "NaN 作参数");
      // 有限数仍然正常
      assert.equal(valueOf(await rt.call("id", [1.5]), "id(1.5)"), 1.5);
    });
  });

  test(`[${label}] Lua 表 → JS：连续整数键是数组，其余是对象（键有序）`, async () => {
    await withRuntime(target, async (rt) => {
      await load(
        rt,
        "shape",
        `function arr() return {10, 20, 30} end
         function obj() return {z = 1, a = "x", m = true} end
         function holes() return {[1] = 1, [3] = 3} end`,
      );

      const arr = valueOf(await rt.call("arr"), "arr()");
      assert.deepEqual(arr, [10, 20, 30]);
      assert.ok(Array.isArray(arr));

      const obj = valueOf(await rt.call("obj"), "obj()");
      assert.deepEqual(obj, { a: "x", m: true, z: 1 });
      assert.equal(Array.isArray(obj), false);
      assert.deepEqual(Object.keys(obj as Record<string, unknown>), ["a", "m", "z"], "键必须排序（转换顺序确定）");

      // 不连续的数字键不是数组：Lua 的数组语义要求 1..n 连续
      const holes = valueOf(await rt.call("holes"), "holes()");
      assert.equal(Array.isArray(holes), false);
      assert.deepEqual(holes, { "1": 1, "3": 3 });
    });
  });

  test(`[${label}] stats 与操作次数精确一致（calls / errors / timeouts）`, async () => {
    await withRuntime(target, async (rt) => {
      assert.deepEqual(rt.stats(), { modules: 0, calls: 0, errors: 0, timeouts: 0 });

      await load(
        rt,
        "counters",
        `function ok() return 1 end
         function bad() error("x") end
         function spin() while true do end end`,
      );
      assert.deepEqual(rt.stats(), { modules: 1, calls: 0, errors: 0, timeouts: 0 }, "加载模块不是调用");

      valueOf(await rt.call("ok"), "ok#1");
      valueOf(await rt.call("ok"), "ok#2");
      await rt.call("ghost"); // 失败 1
      await rt.call("bad"); // 失败 2
      await rt.call("ok", [Number.NaN]); // 失败 3（参数校验）
      await rt.call("spin", [], { timeoutMs: 100 }); // 失败 4 + 超时 1

      assert.deepEqual(rt.stats(), { modules: 1, calls: 6, errors: 4, timeouts: 1 });
    });
  });

  test(`[${label}] dispose：幂等，之后全部 DISPOSED / 空 / 零`, async () => {
    const rt = await target.make();
    const ready = await rt.ready();
    assert.ok(ready.ok);
    await load(rt, "gone", `function f() return 1 end`);
    rt.expose("host_gone", () => 1);

    rt.dispose();
    assert.doesNotThrow(() => rt.dispose(), "重复 dispose 不许抛");

    assertCode(await rt.call("f"), ScriptErrorCode.Disposed, "dispose 后 call");
    assertCode(await rt.loadModule("x", "return 1"), ScriptErrorCode.Disposed, "dispose 后 loadModule");
    assertCode(await rt.unloadModule("gone"), ScriptErrorCode.Disposed, "dispose 后 unloadModule");
    assertCode(await rt.ready(), ScriptErrorCode.Disposed, "dispose 后 ready");
    assertCode(rt.expose("x2", () => 1), ScriptErrorCode.Disposed, "dispose 后 expose");

    assert.equal(rt.hasModule("gone"), false, "同步查询返回空，不抛");
    assert.deepEqual(rt.listModules(), []);
    assert.deepEqual(rt.exposed(), []);
    assert.deepEqual(rt.stats(), { modules: 0, calls: 0, errors: 0, timeouts: 0 });
  });

  test(`[${label}] 两个实例互不影响 —— 守"全局状态共享"`, async () => {
    const a = await target.make();
    const b = await target.make();
    try {
      assert.ok((await a.ready()).ok);
      assert.ok((await b.ready()).ok);

      await load(a, "iso", `counter = 41
        function bump() counter = counter + 1 return counter end
        function who() return "A" end`);
      assert.equal(valueOf(await a.call("bump"), "A.bump"), 42);

      // B 没加载任何东西：A 的全局函数与全局变量都不可见
      assertCode(await b.call("bump"), ScriptErrorCode.NoFunction, "B 调用 A 的函数");
      assertCode(await b.call("who"), ScriptErrorCode.NoFunction, "B 调用 A 的函数（2）");

      assert.equal(valueOf(await a.call("bump"), "A.bump#2"), 43, "A 的全局变量不受 B 影响");
    } finally {
      a.dispose();
      b.dispose();
    }
  });
}

// ------------------------------------------------------------------ 降级契约

function registerDegradedContract(label: string, target: ScriptContractTarget): void {
  test(`[${label}] 能力描述诚实：executes=false 且 version=null`, async () => {
    const rt = await target.make();
    try {
      assert.equal(rt.caps.executes, false, "不能执行就必须说 false（不许假装成功）");
      assert.equal(rt.caps.version, null);
      assert.equal(rt.caps.hostCalls, false);
      assert.equal(rt.caps.interruptible, false);
      assert.ok(rt.caps.language.length > 0);
    } finally {
      rt.dispose();
    }
  });

  test(`[${label}] loadModule 仍登记源码（可诊断"加载了哪些"）`, async () => {
    await withRuntime(target, async (rt) => {
      const r = await rt.loadModule("m", "return 1");
      assert.ok(r.ok);
      assert.equal(rt.hasModule("m"), true);
      assert.deepEqual(rt.listModules(), ["m"]);
      assert.equal(rt.stats().modules, 1);

      // 同名重载也是覆盖
      assert.ok((await rt.loadModule("m", "return 22222")).ok);
      assert.equal(rt.stats().modules, 1);
    });
  });

  test(`[${label}] call 明确 NOT_SUPPORTED（不是 NO_FUNCTION / 不是一个假值）`, async () => {
    await withRuntime(target, async (rt) => {
      await load(rt, "m", `function f() return 1 end`);
      const r = await rt.call("f");
      assertCode(r, ScriptErrorCode.NotSupported, "不能执行的平台 call");
    });
  });

  test(`[${label}] dispose：幂等，之后 DISPOSED / 空 / 零`, async () => {
    const rt = await target.make();
    assert.ok((await rt.ready()).ok);
    await load(rt, "m", "return 1");
    rt.dispose();
    assert.doesNotThrow(() => rt.dispose());

    assertCode(await rt.call("f"), ScriptErrorCode.Disposed, "dispose 后 call");
    assertCode(await rt.loadModule("x", "return 1"), ScriptErrorCode.Disposed, "dispose 后 loadModule");
    assert.equal(rt.hasModule("m"), false);
    assert.deepEqual(rt.listModules(), []);
    assert.deepEqual(rt.stats(), { modules: 0, calls: 0, errors: 0, timeouts: 0 });
  });
}

/**
 * 跑契约。调用方在测试文件顶层 `await runScriptContract(...)` 即可；
 * 用 `caps.executes` 自动选档位，调用方不需要知道自己测的是哪个档。
 */
export async function runScriptContract(label: string, target: ScriptContractTarget): Promise<void> {
  const probe = await target.make();
  const executes = probe.caps.executes;
  probe.dispose();
  if (executes) registerFullContract(label, target);
  else registerDegradedContract(label, target);
}
