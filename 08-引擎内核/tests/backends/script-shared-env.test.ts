/**
 * 脚本模块的**两种环境模式**（批133）。
 *
 * ★ 这一批的起点是一次真实测量，不是设想：把 `dstsrc/scripts/behaviourtree.lua`
 *   （3755 行）与 `brain.lua`（1173 行）喂给运行时，两个都死在同一个地方：
 *
 *     behaviourtree:204: attempt to call a nil value (global 'Class')
 *     brain:132:        attempt to call a nil value (global 'Class')
 *
 *   而第 159 行只有一句**裸的** `require("class")`，第 204 行直接 `BT = Class(...)`。
 *   `class.lua` 本身能加载（批130 验过），`require("class")` 也能返回成功 ——
 *   因为引擎把每个模块放进**自己的 env**（`__index = _G`），`class.lua` 里
 *   `Class = function ... end` 写进的是**它自己那张表**，别的模块看不见。
 *
 *   所以这不是"垫片缺一个函数"，是**两种模块观**：DST 的脚本按 5.1 的
 *   "全局即模块"写（`require` 只为副作用，函数留在 `_G`），而隔离模式假设
 *   "模块是一张命名空间表"。两者都自洽，但**不能同时成立** ——
 *   于是做成显式选项 `sharedModuleEnv`，而不是偷偷把默认改掉：
 *   默认仍是隔离（热更不变式 ③ 靠它），跑真实内容层时显式打开共享。
 *
 * ★ 判据必须**两个方向都验**：只验"共享模式下能读到"的话，
 *   一个"永远共享"的实现（默认也共享）会全绿，而热更不变式已经没了。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { LuaScriptRuntime, type LuaBackendOptions } from "../../src/backends/script-lua/runtime.ts";

async function withLua(
  opts: LuaBackendOptions,
  body: (rt: LuaScriptRuntime) => Promise<void>,
): Promise<void> {
  const rt = new LuaScriptRuntime(opts);
  try {
    const ready = await rt.ready();
    assert.ok(ready.ok, `ready() 必须成功：${ready.ok ? "" : ready.error.message}`);
    await body(rt);
  } finally {
    rt.dispose();
  }
}

/** 造一对语料：`def` 定义一个全局，`use` 读它。 */
const DEF = "X = 1\nfunction readX() return X end";
const USE = "function probe() return X end";

test("★★ 默认（隔离）：模块之间看不到对方的全局 —— 这正是热更不变式 ③ 的前提", async () => {
  await withLua({}, async (rt) => {
    assert.ok((await rt.loadModule("def", DEF)).ok);
    assert.ok((await rt.loadModule("use", USE)).ok);
    const r = await rt.call("use.probe");
    assert.equal(r.ok, true, r.ok ? "" : r.error.message);
    assert.equal(r.ok ? r.value : "?", null, "隔离模式下 use 模块读不到 def 的全局");
  });
});

test("★★ 共享模式（sharedModuleEnv）：同样的语料，模块之间看得到全局", async () => {
  await withLua({ sharedModuleEnv: true }, async (rt) => {
    assert.ok((await rt.loadModule("def", DEF)).ok);
    assert.ok((await rt.loadModule("use", USE)).ok);
    // ★ 注意这里是**裸名** `probe`：共享模式下函数落在 `_G`，没有 `<module>.<fn>` 命名空间。
    //   这不是偷懒，是这套模式的必然结果（见下一条判据）。
    const r = await rt.call("probe");
    assert.equal(r.ok, true, r.ok ? "" : r.error.message);
    assert.equal(r.ok ? r.value : "?", 1, "共享模式下 use 应当读到 def 写进 _G 的 X");
  });
});

test("★ 共享模式的代价：`<module>.<fn>` 解析不到（没有命名空间表，函数都在 _G）", async () => {
  await withLua({ sharedModuleEnv: true }, async (rt) => {
    assert.ok((await rt.loadModule("use", USE)).ok);
    const r = await rt.call("use.probe");
    assert.equal(r.ok, false, "共享模式下模块没有自己的表 ⇒ 点号路径必然解析不到");
    // ★ 把这条钉住而不是"顺手让它也能用"：真要去建命名空间表，就得把 _G 里的
    //   每个键按"是哪个模块写的"分类，而 _G 里根本没有这个信息（DST 自己也没有）。
    const bare = await rt.call("probe");
    assert.equal(bare.ok, true, "裸名必须能调到（这才是共享模式许诺的东西）");
  });
});

test("★★ 真实 DST 的写法（require 只为副作用 + 裸用全局函数）：隔离模式炸，共享模式通", async () => {
  const CLASS_LIKE = [
    // 与 dstsrc/scripts/class.lua 同形状：Class 是**全局**，不是返回值
    "Class = function(ctor)",
    "  local c = {}",
    "  c.__index = c",
    // 与真实 class.lua 一样：ctor(self, ...) —— 实例先建出来再交给构造函数
    "  return { new = function(...) local s = {}; ctor(s, ...); return s end }",
    "end",
  ].join("\n");
  const BT_LIKE = [
    'require("cls")', // ★ 裸 require：不接返回值，只为副作用（DST 到处都是这种）
    "BT = Class(function(self) self.ready = true end)",
    "function makeBT() return BT.new() end",
  ].join("\n");

  // ① 隔离：`Class` 在 cls 自己的 env 里 ⇒ bt 看不到 ⇒ 加载期就炸
  await withLua({}, async (rt) => {
    assert.ok((await rt.loadModule("cls", CLASS_LIKE)).ok, "class 这种单文件应当能加载");
    const bt = await rt.loadModule("bt", BT_LIKE);
    assert.equal(bt.ok, false, "隔离模式下这段真实写法必须炸（behaviourtree.lua:204 就是这里）");
    const msg = bt.ok ? "" : bt.error.message;
    assert.ok(msg.includes("Class"), `报错要点名是 Class，实际：${msg}`);
  });

  // ② 共享：同一段语料能加载，且 `BT` 真的可用
  await withLua({ sharedModuleEnv: true }, async (rt) => {
    assert.ok((await rt.loadModule("cls", CLASS_LIKE)).ok);
    const bt = await rt.loadModule("bt", BT_LIKE);
    assert.equal(bt.ok, true, bt.ok ? "" : bt.error.message);
    const made = await rt.call("makeBT");
    assert.equal(made.ok, true, made.ok ? "" : made.error.message);
    assert.deepEqual(made.ok ? made.value : null, { ready: true });
  });
});

test("★ 共享模式下 `call` 仍能从 _G 解析到模块定义的函数（解析顺序 ③ 兜住）", async () => {
  await withLua({ sharedModuleEnv: true }, async (rt) => {
    assert.ok((await rt.loadModule("m", "function hello() return 'hi' end")).ok);
    const r = await rt.call("hello");
    assert.equal(r.ok, true, r.ok ? "" : r.error.message);
    assert.equal(r.ok ? r.value : "", "hi");
  });
});

test("★ 共享模式不会让卸载变成「什么都没清」的假象：模块名从登记表里真的没了", async () => {
  await withLua({ sharedModuleEnv: true }, async (rt) => {
    assert.ok((await rt.loadModule("m", "function hello() return 1 end")).ok);
    assert.equal(rt.hasModule("m"), true);
    const un = await rt.unloadModule("m");
    assert.equal(un.ok, true);
    assert.equal(rt.hasModule("m"), false, "卸载后登记表必须没有它");
    // ★ 但函数还在 _G 里（共享模式的代价，如实钉住而不是假装干净）
    const r = await rt.call("hello");
    assert.equal(r.ok, true, "共享模式下卸载不回收 _G 里的函数 —— 这是 DST 自己的行为，不许假装清掉了");
  });
});
