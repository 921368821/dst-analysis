/**
 * per-module `_ENV` 隔离（`src/backends/script-lua/runtime.ts`）
 *
 * 守的是**一个具体的旧缺陷**：模块只隔离了"函数名"，模块里的**全局变量仍共享 `_G`**。
 * 于是两个 mod 定义同名全局会互相污染，热重载会把上一版的变量残留到新版本。
 *
 * 每条判据都对应一种"串味"，且都要求"该看得见的仍然看得见"（`__index = _G`）：
 *   · A 写 `g = "A"`，B 读 `g` 必须是 nil（不是 "A"）；
 *   · 同名函数不互相覆盖（限定名 `<module>.<entry>` 可区分）；
 *   · 各自 `counter` 自增互不影响；
 *   · 同名重载丢弃旧 env（旧全局不残留）；
 *   · `engine_log` / `math` 两边都能用（证明只读共享 `_G` 生效）；
 *   · 5.1 兼容层与隔离**同时**生效（module() + setfenv 的脚本能跑）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { LuaScriptRuntime } from "../../src/backends/script-lua/runtime.ts";
import type { ScriptValue } from "../../src/platform/script/runtime.ts";

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

async function load(rt: LuaScriptRuntime, name: string, source: string): Promise<void> {
  const r = await rt.loadModule(name, source);
  assert.ok(r.ok, `loadModule(${name}) 失败：${r.ok ? "" : r.error.message}`);
}

async function value(rt: LuaScriptRuntime, fn: string, args: readonly ScriptValue[] = []): Promise<ScriptValue> {
  const r = await rt.call(fn, args);
  assert.ok(r.ok, `call(${fn}) 应成功：${r.ok ? "" : r.error.message}`);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
}

// ------------------------------------------------------------------ 变量隔离

test("[env] 模块 A 的全局 g 对模块 B 不可见 —— 守'全局变量共享 _G'", async () => {
  await withLua(async (rt) => {
    await load(rt, "a", `g = "A"\nfunction read_g() return g end`);
    await load(rt, "b", `function read_g() return g end`);

    assert.equal(await value(rt, "a.read_g"), "A", "A 自己写的全局必须读得到");
    assert.equal(await value(rt, "b.read_g"), null, "B 读同名全局必须是 nil（不是 'A'）");
  });
});

test("[env] 两个模块的同名函数互不覆盖（限定名可区分）", async () => {
  await withLua(async (rt) => {
    await load(rt, "a", `function onUpdate() return "A" end`);
    await load(rt, "b", `function onUpdate() return "B" end`);

    assert.equal(await value(rt, "a.onUpdate"), "A");
    assert.equal(await value(rt, "b.onUpdate"), "B");
    // 裸名仍是"最近加载的模块优先"（等价于旧实现里后写覆盖 _G 的行为）
    assert.equal(await value(rt, "onUpdate"), "B");
  });
});

test("[env] A/B 各自的 counter 自增互不影响 —— 守'热重载/多 mod 串味'", async () => {
  await withLua(async (rt) => {
    const src = `counter = 0
      function bump() counter = counter + 1 return counter end
      function peek() return counter end`;
    await load(rt, "a", src);
    await load(rt, "b", src);

    assert.equal(await value(rt, "a.bump"), 1);
    assert.equal(await value(rt, "a.bump"), 2);
    assert.equal(await value(rt, "b.bump"), 1, "B 的 counter 必须从 0 开始，不能继承 A 的状态");
    assert.equal(await value(rt, "a.bump"), 3, "A 的状态不能被 B 推高");
    assert.equal(await value(rt, "b.peek"), 1);
  });
});

// ------------------------------------------------------------------ 热重载

test("[env] 同名重载丢弃旧 env：counter 回到 nil —— 守'复用旧表导致旧全局残留'", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "a",
      `counter = 0
       function bump() counter = counter + 1 return counter end
       function peek() return counter end`,
    );
    assert.equal(await value(rt, "a.bump"), 1);
    assert.equal(await value(rt, "a.bump"), 2);
    assert.equal(await value(rt, "a.peek"), 2);

    // 重载成"不再初始化 counter"的版本。★ 这是判据的关键：源码里没有 counter = 0，
    // 所以读到的任何数字都只可能来自**没被丢弃的旧 env**。
    await load(
      rt,
      "a",
      `function peek() return counter end
       function bump() counter = (counter or 0) + 1 return counter end`,
    );
    assert.equal(
      await value(rt, "a.peek"),
      null,
      "重载后 counter 必须是 nil（旧 env 被丢弃，不是复用旧表）",
    );
    assert.equal(await value(rt, "a.bump"), 1, "新 env 从 0 重新开始");

    assert.equal(rt.stats().modules, 1, "同名重载是覆盖，不是登记第二个模块");
  });
});

test("[env] unload 之后模块的全局真的消失 —— 守'只删名字、变量留在 _G'", async () => {
  await withLua(async (rt) => {
    await load(rt, "temp", `keep = "yes"\nfunction read_keep() return keep end`);
    assert.equal(await value(rt, "temp.read_keep"), "yes");

    const un = await rt.unloadModule("temp");
    assert.ok(un.ok, "unloadModule 应成功：" + (un.ok ? "" : un.error.message));
    assert.equal(rt.hasModule("temp"), false);

    // 重新加载一份**没有** keep 赋值的源码：如果旧 env 还在（或变量漏进 _G），这里会读回 "yes"
    await load(rt, "temp", `function read_keep() return keep end`);
    assert.equal(await value(rt, "temp.read_keep"), null, "旧全局必须随旧 env 一起丢失");
  });
});

// ------------------------------------------------------------------ _G 只读共享

test("[env] 两边都能调 engine_log / math.floor —— 守'隔离把基础库也隔掉了'", async () => {
  await withLua(async (rt) => {
    const logs: unknown[][] = [];
    const e = rt.expose("engine_log", (tag, v) => {
      logs.push([tag, v]);
      return null;
    });
    assert.ok(e.ok, "expose 应成功：" + (e.ok ? "" : e.error.message));

    const src = (tag: string) => `
      function report(x)
        engine_log("${tag}", x)
        return math.floor(x)
      end`;
    await load(rt, "a", src("A"));
    await load(rt, "b", src("B"));

    assert.equal(await value(rt, "a.report", [1.5]), 1);
    assert.equal(await value(rt, "b.report", [2.5]), 2);
    assert.deepEqual(logs, [
      ["A", 1.5],
      ["B", 2.5],
    ]);
  });
});

// ------------------------------------------------------------------ 与 5.1 兼容层共同作用

test("[env] 5.1 风格 module() 脚本在隔离下仍能跑，且不把模块全局泄进别的模块", async () => {
  await withLua(async (rt) => {
    // 顶层 module()：chunk 的 env 被换到 legacy.foo，后续定义全在模块表里
    await load(
      rt,
      "legacy",
      `module("legacy.foo", package.seeall)
       _USED = "51"
       function hello() return "hello/" .. tostring(_USED) end
       function via_setfenv()
         local f = function() return Dep end
         setfenv(f, { Dep = "injected" })
         return f()
       end`,
    );
    // 另一个模块：普通全局（hello/_USED）看不见，但 module() 建的全局表看得见
    await load(
      rt,
      "other",
      `function peek_hello() return hello end
       function peek_legacy_type() return type(legacy) end
       function peek_foo_type() return type(legacy.foo) end`,
    );

    assert.equal(await value(rt, "legacy.foo.hello"), "hello/51");
    assert.equal(await value(rt, "via_setfenv"), "injected", "兼容层的 setfenv 必须仍生效");

    assert.equal(await value(rt, "other.peek_hello"), null, "模块的普通全局不能泄进别的模块");
    assert.equal(await value(rt, "other.peek_legacy_type"), "table", "module() 建的全局表本来就是全局的");
    assert.equal(await value(rt, "other.peek_foo_type"), "table");
  });
});
