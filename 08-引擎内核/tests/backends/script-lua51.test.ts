/**
 * Lua 5.1 兼容垫片（`src/backends/script-lua/compat-lua51.ts`）
 *
 * 通用语义由 `runScriptContract`（tests/contract/script.contract.ts）守，这里只守
 * **5.1 → 5.4 的落差**。每条都对应一个"内容层会真的踩到"的缺陷：
 *
 *   · `unpack` / `loadstring` / `setfenv` / `getfenv` / `module` / `require` 在 5.4 里
 *     **被删了**，不补就是 `attempt to call a nil value (global 'module')`；
 *   · `setfenv` 的写法有陷阱：`debug.setupvalue` 会牵连同 chunk 的**兄弟闭包**
 *     （_ENV 是共享 upvalue），垫片必须做到"只换目标函数"；
 *   · 数字参数（栈层号）在 5.4 没有对应物 ⇒ 必须**明确报错**，不能静默失败；
 *   · `module()` 要同时做到"全局表可见 / package.loaded 有登记 / 调用者 env 被换掉"；
 *   · 补齐的 `math.*` / `table.getn` / `string.gfind` 不能把 5.4 自己的语义弄坏
 *     （`table.unpack`、`goto` 必须还在）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { LuaScriptRuntime } from "../../src/backends/script-lua/runtime.ts";
import { ScriptErrorCode, type ScriptValue } from "../../src/platform/script/runtime.ts";

async function withLua(body: (rt: LuaScriptRuntime) => Promise<void>): Promise<void> {
  const rt = new LuaScriptRuntime();
  try {
    const ready = await rt.ready();
    assert.ok(ready.ok, "ready() 必须成功（含 5.1 垫片自检）：" + (ready.ok ? "" : ready.error.message));
    await body(rt);
  } finally {
    rt.dispose();
  }
}

/** 加载一个模块并断言成功（失败时把 Lua 原文带出来，否则只剩 "false !== true"）。 */
async function load(rt: LuaScriptRuntime, name: string, source: string): Promise<void> {
  const r = await rt.loadModule(name, source);
  assert.ok(r.ok, `loadModule(${name}) 失败：${r.ok ? "" : r.error.message}`);
}

/** 调用并断言成功，返回 JS 值。 */
async function value(rt: LuaScriptRuntime, fn: string, args: readonly ScriptValue[] = []): Promise<ScriptValue> {
  const r = await rt.call(fn, args);
  assert.ok(r.ok, `call(${fn}) 应成功：${r.ok ? "" : r.error.message}`);
  if (!r.ok) throw new Error("unreachable");
  return r.value;
}

// ------------------------------------------------------------------ 基础别名

test("[lua51] unpack 必须存在且返回多值 —— 守 5.4 删掉全局 unpack 后内容层全炸", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "u",
      `function count() return table.pack(unpack({1, 2, 3})).n end
       function sum3() local a, b, c = unpack({1, 2, 3}) return a + b + c end`,
    );
    // 用 table.pack(...).n 断言"真的是 3 个返回值"，而不是"第一个值恰好是 1"
    assert.equal(await value(rt, "count"), 3);
    assert.equal(await value(rt, "sum3"), 6);
  });
});

test("[lua51] loadstring 可用，失败时返回 nil + 错误信息 —— 守 5.4 只留 load 的落差", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "ls",
      `function ok_chunk()
         local f = loadstring("return 1 + 1")
         return f()
       end
       function bad_chunk()
         local f, err = loadstring("function (")
         return tostring(f == nil) .. "/" .. type(err)
       end`,
    );
    assert.equal(await value(rt, "ok_chunk"), 2);
    // 5.1 的 loadstring 失败是 (nil, msg)，不是抛异常 —— 脚本靠这个分支做降级
    assert.equal(await value(rt, "bad_chunk"), "true/string");
  });
});

// ------------------------------------------------------------------ setfenv / getfenv

test("[lua51] setfenv 生效：函数内的全局读取走新 env", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "sf",
      `function probe()
         local f = function() return V end
         setfenv(f, { V = 42 })
         return f()
       end
       function probe_getfenv()
         local f = function() return V end
         setfenv(f, { V = 42, tag = "hi" })
         return tostring(getfenv(f).tag)
       end`,
    );
    assert.equal(await value(rt, "probe"), 42);
    // getfenv 必须能读回 setfenv 设的那张表（否则"换了但看不见"）
    assert.equal(await value(rt, "probe_getfenv"), "hi");
  });
});

test("[lua51] setfenv 只换目标函数，不牵连兄弟闭包 —— 守 setupvalue 的共享 upvalue 陷阱", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "sib",
      `function siblings()
         local a = function() return Q end
         local b = function() return Q end
         setfenv(a, { Q = "A" })
         -- b 与 a 在 5.4 里共享同一个 _ENV upvalue；天真实现会把 b 一起改掉
         return tostring(a()) .. "/" .. tostring(b())
       end
       function caller_survives()
         local f = function() return W end
         setfenv(f, {})
         -- 调用者自己的全局（tostring/math）必须还在：setupvalue 会把调用者也换掉
         return tostring(tostring ~= nil) .. "/" .. tostring(math ~= nil)
       end`,
    );
    assert.equal(await value(rt, "siblings"), "A/nil", "兄弟闭包必须保留原 env（= 5.1 的函数级环境）");
    assert.equal(await value(rt, "caller_survives"), "true/true", "setfenv 不能把调用者的 env 一起换掉");
  });
});

test("[lua51] setfenv(数字) → 明确报错，而不是静默失败", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "sfnum",
      `function bad() setfenv(1, {}) end
       function after() return "still-alive" end`,
    );
    const r = await rt.call("bad");
    assert.equal(r.ok, false, "按栈层号设环境在 5.4 无法实现，必须失败");
    if (!r.ok) {
      assert.equal(r.error.code, ScriptErrorCode.CallFailed);
      // 报错必须说明"为什么"，不能只是 "bad argument"
      assert.match(r.error.message, /栈层|level/, `错误信息应点明 level：${r.error.message}`);
      assert.match(r.error.message, /5\.4/, `错误信息应点明 5.4 的局限：${r.error.message}`);
    }
    // 明确报错的另一面：运行时不能被毒死
    assert.equal(await value(rt, "after"), "still-alive");
  });
});

// ------------------------------------------------------------------ module()

test("[lua51] module('foo.bar', package.seeall)：全局可见 + package.loaded 登记 + 调用者 env 被换", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "mod",
      `function install()
         local before = getfenv(1)
         module("foo.bar", package.seeall)
         local self = getfenv(1)
         self.mark = (self.mark or 0) + 1
         return table.concat({
           tostring(foo ~= nil),                          -- ① 点号嵌套的全局表建出来了
           tostring(foo.bar ~= nil),
           tostring(package.loaded["foo.bar"] == foo.bar), -- ② package.loaded 有登记
           tostring(self == foo.bar),                      -- ③ 调用者的 env 被换成模块表
           tostring(before ~= self),
           tostring(math ~= nil),                          -- ④ seeall 让 _G 可见
         }, "/") .. "/" .. self.mark
       end`,
    );
    assert.equal(
      await value(rt, "install"),
      "true/true/true/true/true/true/1",
      "module() 必须建表、登记 package.loaded、换调用者 env，且 seeall 让 _G 可见",
    );
    // 第二次进：install 自己已经在模块 env 里了（所以 before == self），
    // 但 mark 变成 2 证明 module() **复用**了同一张表 —— 不是每次新建（那会丢模块状态）
    assert.equal(await value(rt, "install"), "true/true/true/true/false/true/2");
  });
});

test("[lua51] module() 之后定义的函数落在模块表上 —— 守'换了 env 但新函数还写在旧表'", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "legacy",
      `module("legacy.widget", package.seeall)
       _USED = "5.1"
       function id() return _USED end`,
    );
    // module() 在 chunk 顶层调用 ⇒ 整个 chunk 的 _ENV 被换，后续定义进模块表
    assert.equal(await value(rt, "legacy.widget.id"), "5.1");
    assert.equal(await value(rt, "id"), "5.1", "模块命名空间里也应有 id（裸名可解析）");
  });
});

// ------------------------------------------------------------------ math / table / string 补齐

test("[lua51] math.pow / math.mod / math.ldexp / math.frexp / math.log10 / table.getn", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "m",
      `function pow() return math.pow(2, 10) end
       function mod_() return math.mod(7, 3) end
       function ldexp() return math.ldexp(1, 10) end
       function log10_() return math.log10(1000) end
       function getn() return table.getn({1, 2}) end
       function frexp() local m, e = math.frexp(8) return { m, e } end
       function setn() table.setn({}, 3) end`,
    );
    assert.equal(await value(rt, "pow"), 1024);
    assert.equal(await value(rt, "mod_"), 1);
    assert.equal(await value(rt, "ldexp"), 1024);
    assert.equal(await value(rt, "log10_"), 3);
    assert.equal(await value(rt, "getn"), 2);
    // frexp 的定义是 x = m * 2^e 且 0.5 <= |m| < 1
    assert.deepEqual(await value(rt, "frexp"), [0.5, 4]);

    // table.setn 在 5.1 里就已废弃：必须明确报错，而不是假装成功
    const r = await rt.call("setn");
    assert.equal(r.ok, false);
    if (!r.ok) assert.equal(r.error.code, ScriptErrorCode.CallFailed);
  });
});

test("[lua51] string.gfind 与 gmatch 同行为", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "s",
      `local function collect(iter, s)
         local out = {}
         for w in iter(s, "%a+") do out[#out + 1] = w end
         return table.concat(out, ",")
       end
       function via_gfind() return collect(string.gfind, "ab cd ef") end
       function via_gmatch() return collect(string.gmatch, "ab cd ef") end
       function same() return tostring(string.gfind == string.gmatch) end`,
    );
    const a = await value(rt, "via_gfind");
    const b = await value(rt, "via_gmatch");
    assert.equal(a, "ab,cd,ef");
    assert.equal(a, b, "gfind 必须是 gmatch 的别名（同行为）");
    assert.equal(await value(rt, "same"), "true");
  });
});

// ------------------------------------------------------------------ require

test("[lua51] require：不存在 → 明确错误；package.preload 登记后可用", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "r",
      `function missing()
         local ok, err = pcall(require, "no.such.module")
         return tostring(ok) .. "/" .. tostring(err)
       end
       function preloaded()
         package.preload["fake.mod"] = function(name)
           return { name = name, tag = "loaded" }
         end
         local m = require("fake.mod")
         -- 第二次 require 必须命中缓存（返回同一张表），不能重复执行 loader
         local again = require("fake.mod")
         return tostring(m.tag) .. "/" .. tostring(m.name) .. "/" .. tostring(m == again)
       end`,
    );
    const miss = await value(rt, "missing");
    assert.equal(typeof miss, "string");
    assert.match(String(miss), /^false\//, "require 不存在必须 error（pcall 应捕获到 false）");
    assert.match(String(miss), /not found/, `错误信息应说明 not found：${String(miss)}`);

    assert.equal(await value(rt, "preloaded"), "loaded/fake.mod/true");
  });
});

// ------------------------------------------------------------------ 真实 5.1 脚本

test("[lua51] 真实 5.1 风格脚本（module + setfenv + unpack + math.pow）能加载并调用", async () => {
  await withLua(async (rt) => {
    // 这段写法是 5.1 内容层（DST）的典型骨架：
    //   ① 文件顶层 module(..., package.seeall)，后续定义全落在模块表；
    //   ② 用 unpack 展开可变参数；
    //   ③ 局部沙箱函数靠 setfenv 注入依赖；
    //   ④ 用 math.pow 这类 5.4 已删的 API。
    const source = `
      module("legacy.widget", package.seeall)

      _VERSION_USED = "5.1"
      _count = 0

      local function square(v) return math.pow(v, 2) end

      function power_sum(a, b, c)
        -- unpack 在 5.1 里就长这样用：把一个表展开成多值
        local args = { unpack({ a, b, c }) }
        local s = 0
        for _, v in ipairs(args) do
          s = s + square(v)
        end
        return s
      end

      function sandboxed()
        local f = function() return dep_value end
        setfenv(f, { dep_value = "from-sandbox" })
        return f()
      end

      function bump()
        _count = _count + 1
        return _count
      end
    `;
    await load(rt, "legacy", source);

    // ① 模块表上的函数：限定名与裸名都能调到
    assert.equal(await value(rt, "legacy.widget.power_sum", [1, 2, 3]), 14);
    assert.equal(await value(rt, "power_sum", [3, 4]), 25);
    // ② 沙箱函数
    assert.equal(await value(rt, "sandboxed"), "from-sandbox");
    // ③ 模块表上的状态是持久的（_count 存在 module() 建的全局表里）
    assert.equal(await value(rt, "bump"), 1);
    assert.equal(await value(rt, "bump"), 2);
  });
});

// ------------------------------------------------------------------ 不破坏 5.4

test("[lua51] 垫片不破坏 5.4 语义：table.unpack 仍在、goto 仍可用", async () => {
  await withLua(async (rt) => {
    await load(
      rt,
      "keep54",
      `function unpack54() return table.pack(table.unpack({7, 8})).n end
       function goto54()
         local out = {}
         for i = 1, 3 do
           if i == 2 then goto continue end
           out[#out + 1] = i
           ::continue::
         end
         return table.concat(out, ",")
       end
       function intdiv() return 7 // 2 end`,
    );
    assert.equal(await value(rt, "unpack54"), 2, "table.unpack 被别名成 unpack 后必须仍然可用");
    assert.equal(await value(rt, "goto54"), "1,3", "5.4 的 goto 不能被垫片影响");
    assert.equal(await value(rt, "intdiv"), 3, "5.4 的整除运算符不能被垫片影响");
  });
});
