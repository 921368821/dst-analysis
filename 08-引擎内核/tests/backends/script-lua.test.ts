/**
 * Lua 脚本后端（wasmoon / Lua 5.4）
 *
 * 通用语义由 `runScriptContract` 守（与 null 后端同一套条目）；这里补的是
 * **Lua 侧独有**、且曾经踩过的坑：
 *   · caps 必须与实现一致（5.4 / 可打断 / 可宿主调用）；
 *   · 模块名在 Lua 侧可见（chunkname + package.loaded）——否则报错里全是 `[string "..."]`；
 *   · `a.b.c` 形式的函数名可解析（模块可以把 API 挂在自己的表里）；
 *   · JS `null` 能正确变成 Lua `nil`（wasmoon 推 null 会直接崩，见 runtime.ts 文件头）；
 *   · 返回值不可序列化（Lua 函数）→ BAD_VALUE，而不是把 JS 函数漏给引擎。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { LuaScriptRuntime, luaScriptBackend } from "../../src/backends/script-lua/runtime.ts";
import { ScriptErrorCode, type IScriptRuntime, type ScriptValue } from "../../src/platform/script/runtime.ts";
import { runScriptContract } from "../contract/script.contract.ts";

const target = {
  async make(): Promise<IScriptRuntime> {
    const r = luaScriptBackend.create();
    if (!r.ok) throw new Error("lua 后端创建失败：" + r.error.message);
    return r.value;
  },
};

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

// 全量契约（executes=true 那条分支）
await runScriptContract("lua", target);

test("[lua] caps 精确：Lua 5.4 / 可打断 / 可宿主调用 / 可执行", () => {
  const rt = new LuaScriptRuntime();
  assert.deepEqual(rt.caps, {
    language: "lua",
    version: "5.4",
    interruptible: true,
    hostCalls: true,
    executes: true,
  });
  rt.dispose();
});

test("[lua] 模块名在 Lua 侧可见：chunkname 带模块名，package.loaded 有登记", async () => {
  await withLua(async (rt) => {
    const okLoad = await rt.loadModule(
      "modx",
      `function module_visible() return package.loaded["modx"] ~= nil end`,
    );
    assert.ok(okLoad.ok);
    const visible = await rt.call("module_visible");
    assert.ok(visible.ok);
    if (visible.ok) assert.equal(visible.value, true, "package.loaded['modx'] 必须已登记");

    // 语法错误的诊断信息必须能指到模块名（而不是 [string "..."]）
    const bad = await rt.loadModule("modx", `function broken( end`);
    assert.equal(bad.ok, false);
    if (!bad.ok) {
      assert.equal(bad.error.code, ScriptErrorCode.LoadFailed);
      assert.match(bad.error.message, /modx/, `错误信息应带模块名，实际：${bad.error.message}`);
    }
  });
});

test("[lua] 支持 a.b.c 形式的函数名（查表，不是拼源码）", async () => {
  await withLua(async (rt) => {
    const r = await rt.loadModule(
      "nested",
      `brain = { think = function() return 9 end }
       deep = { inner = { value = function() return "ok" end } }`,
    );
    assert.ok(r.ok);

    const a = await rt.call("brain.think");
    assert.ok(a.ok);
    if (a.ok) assert.equal(a.value, 9);

    const b = await rt.call("deep.inner.value");
    assert.ok(b.ok);
    if (b.ok) assert.equal(b.value, "ok");

    const missing = await rt.call("brain.absent");
    assert.equal(missing.ok, false);
    if (!missing.ok) assert.equal(missing.error.code, ScriptErrorCode.NoFunction);
  });
});

test("[lua] JS null → Lua nil（wasmoon 直接推 null 会崩）", async () => {
  await withLua(async (rt) => {
    assert.ok((await rt.loadModule("nilcheck", `function is_nil(x) return x == nil end`)).ok);
    const r = await rt.call("is_nil", [null]);
    assert.ok(r.ok);
    if (r.ok) assert.equal(r.value, true);
  });
});

test("[lua] 脚本无返回值 → 值是 null（不是 undefined 漏出边界）", async () => {
  await withLua(async (rt) => {
    assert.ok((await rt.loadModule("void", `function nothing() end`)).ok);
    const r = await rt.call("nothing");
    assert.ok(r.ok);
    if (r.ok) assert.equal(r.value, null);
  });
});

test("[lua] 返回值不可序列化（Lua 函数）→ BAD_VALUE", async () => {
  await withLua(async (rt) => {
    assert.ok((await rt.loadModule("badret", `function ret_fn() return function() end end`)).ok);
    const r = await rt.call("ret_fn");
    assert.equal(r.ok, false);
    if (!r.ok) assert.equal(r.error.code, ScriptErrorCode.BadValue);
    // 出错后运行时仍可用
    assert.ok((await rt.loadModule("ok2", `function ok() return 1 end`)).ok);
    const again = await rt.call("ok");
    assert.ok(again.ok);
    if (again.ok) assert.equal(again.value, 1);
  });
});

test("[lua] 宿主函数收到不可跨界参数 → 不进宿主函数，call 报 BAD_VALUE", async () => {
  await withLua(async (rt) => {
    let called = 0;
    const e = rt.expose("host_strict", () => {
      called++;
      return 1;
    });
    assert.ok(e.ok);
    assert.ok((await rt.loadModule("h", `function pass_fn() return host_strict(function() end) end`)).ok);

    const r = await rt.call("pass_fn");
    assert.equal(r.ok, false);
    if (!r.ok) assert.equal(r.error.code, ScriptErrorCode.BadValue);
    assert.equal(called, 0, "参数校验必须发生在进入宿主函数之前");
  });
});

test("[lua] 模块返回表：成员也进模块命名空间（`return { onUpdate = ... }` 可用）", async () => {
  await withLua(async (rt) => {
    const r = await rt.loadModule("tbl", `return { hit = function(n) return n + 1 end }`);
    assert.ok(r.ok, r.ok ? "" : r.error.message);
    const hit = await rt.call("tbl.hit", [1]);
    assert.ok(hit.ok, hit.ok ? "" : hit.error.message);
    if (hit.ok) assert.equal(hit.value, 2);
  });
});

test("[lua] 参数与返回值按值往返：数组/对象不共享引用", async () => {
  await withLua(async (rt) => {
    assert.ok((await rt.loadModule("copy", `function mutate(t) t[1] = 99 return t end`)).ok);
    const input: ScriptValue = [1, 2];
    const r = await rt.call("mutate", [input]);
    assert.ok(r.ok);
    if (r.ok) assert.deepEqual(r.value, [99, 2]);
    assert.deepEqual(input, [1, 2], "跨语言边界只传值：脚本改表不能改到宿主对象");
  });
});
