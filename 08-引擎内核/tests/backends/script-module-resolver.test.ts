/**
 * 脚本模块解析（批134 / 阻塞项 C26）：`require(name)` 的第三站
 *
 * ★ 起点是一次**真实测量**，不是设想：把 `dstsrc` 顶层 218 个脚本按字母序全加载，
 *   117 通过 / 101 失败，失败绝大多数是同一句：
 *
 *     actions.lua:240   module 'class' not found
 *     chathistory.lua:8 module 'class' not found
 *
 *   因为 `actions.lua` 排在 `class.lua` **前面**，而引擎的 `require` 只查
 *   `package.loaded` / `package.preload`，且**没有任何 API 往 `package.preload` 里写**
 *   —— 垫片文件头那句"唯一入口"是空头支票。DST 那边 `require` 是真的去
 *   `scripts/` 里找文件的。
 *
 * ★ 判据必须造的**不是**"解析器能返回源码"这种一句话事实，而是四种失败形状：
 *   找不到 / 读不出来 / 它自己又缺别的模块 / 循环依赖 —— 四种要能分辨，
 *   否则报错只是在说"加载失败了"，而加载失败是这条链上唯一**没有信息量**的说法。
 *
 * ★ 语料全部合成（`dstsrc` 未入库，挂在那儿等于 CI 永远跳过）：真实文件的形状
 *   用"同形状的 5 行"复现（`Class` 是全局、`require` 不接返回值）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { LuaScriptRuntime, type LuaBackendOptions } from "../../src/backends/script-lua/runtime.ts";
import {
  candidatePaths,
  collectModuleSources,
  resolverFromSources,
  type LuaModuleResolver,
} from "../../src/backends/script-lua/module-resolver.ts";
import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import type { IReadableFileSystem } from "../../src/platform/fs/fs.ts";

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

/** 把「相对路径 → 源码」的字面表包成同步解析器。 */
function fromFiles(files: Record<string, string>): LuaModuleResolver {
  return resolverFromSources(new Map(Object.entries(files)));
}

test("★★ 没配解析器：require 只查后两站，行为与批134 之前完全一致", async () => {
  await withLua({}, async (rt) => {
    const r = await rt.loadModule("m", 'require("cls")');
    assert.equal(r.ok, false, "没有解析器时不该凭空加载出 cls");
    const msg = r.ok ? "" : r.error.message;
    assert.ok(msg.includes("module 'cls' not found"), `报错要点名模块，实际：${msg}`);
  });
});

test("★★ 装上解析器：require 真的读 <name>.lua、执行它，并把返回值交回来", async () => {
  const resolve = fromFiles({ "cls.lua": "return { tag = 'cls' }" });
  await withLua({ resolveModule: resolve }, async (rt) => {
    const m = await rt.loadModule(
      "m",
      'local C = require("cls")\nfunction tagOf() return C.tag end',
    );
    assert.equal(m.ok, true, m.ok ? "" : m.error.message);
    const r = await rt.call("m.tagOf");
    assert.equal(r.ok, true, r.ok ? "" : r.error.message);
    assert.equal(r.ok ? r.value : "?", "cls", "返回值要原样交回（这是 `local X = require(...)` 的全部意义）");
  });
});

test("★★ 第二次 require 不重新执行 —— `package.loaded` 是第一站", async () => {
  const resolve = fromFiles({
    "cls.lua": "BOOTS = (BOOTS or 0) + 1\nreturn { boots = BOOTS }",
  });
  await withLua({ resolveModule: resolve }, async (rt) => {
    const m = await rt.loadModule(
      "m",
      [
        'local a = require("cls")',
        'local b = require("cls")',
        "function same() return a == b end",
        "function boots() return a.boots end",
      ].join("\n"),
    );
    assert.equal(m.ok, true, m.ok ? "" : m.error.message);
    const same = await rt.call("m.same");
    assert.equal(same.ok ? same.value : "?", true, "两次 require 必须是同一张表");
    const boots = await rt.call("m.boots");
    assert.equal(boots.ok ? boots.value : "?", 1, "模块体只该执行一次");
  });
});

test("★ 两种命名：`<name>.lua` 与 `<name>/init.lua` 都能解析", async () => {
  assert.deepEqual(candidatePaths("pkg"), ["pkg.lua", "pkg/init.lua"]);
  assert.deepEqual(candidatePaths("ai.brain"), ["ai/brain.lua", "ai/brain/init.lua"], "点号就是目录分隔符");

  const resolve = fromFiles({ "pkg/init.lua": "return { from = 'init' }" });
  await withLua({ resolveModule: resolve }, async (rt) => {
    const m = await rt.loadModule("m", 'local P = require("pkg")\nfunction from() return P.from end');
    assert.equal(m.ok, true, m.ok ? "" : m.error.message);
    const r = await rt.call("m.from");
    assert.equal(r.ok ? r.value : "?", "init", "目录式模块（`pkg/init.lua`）必须能找到");
  });
});

test("★ 两种命名同时存在时 `<name>.lua` 赢（与标准 package.path 同序，不是随便定的）", async () => {
  const resolve = fromFiles({
    "ai/brain.lua": "return { from = 'file' }",
    "ai/brain/init.lua": "return { from = 'init' }",
  });
  await withLua({ resolveModule: resolve }, async (rt) => {
    const m = await rt.loadModule("m", 'local B = require("ai.brain")\nfunction from() return B.from end');
    assert.equal(m.ok, true, m.ok ? "" : m.error.message);
    const r = await rt.call("m.from");
    assert.equal(r.ok ? r.value : "?", "file");
  });
});

test("★★ 「找不到」与「它自己又缺模块」是两句话（合并 = 报错没有信息量）", async () => {
  const resolve = fromFiles({ "a.lua": 'require("b")' }); // 有 a，没有 b
  await withLua({ resolveModule: resolve }, async (rt) => {
    const m = await rt.loadModule("m", 'require("a")');
    assert.equal(m.ok, false);
    const msg = m.ok ? "" : m.error.message;
    assert.ok(msg.includes("module 'a' 加载失败"), `要说清是谁加载失败，实际：${msg}`);
    assert.ok(msg.includes("module 'b' not found"), `还要说清它缺的是谁，实际：${msg}`);
  });
});

test("★★ io ≠ not-found：「有但读不出来」不许说成「没有」", async () => {
  const resolve: LuaModuleResolver = () => ({
    ok: false,
    reason: "io",
    message: "磁盘读错误（EIO）",
  });
  await withLua({ resolveModule: resolve }, async (rt) => {
    const m = await rt.loadModule("m", 'require("cls")');
    assert.equal(m.ok, false);
    const msg = m.ok ? "" : m.error.message;
    assert.ok(msg.includes("读取失败"), `要说「读取失败」，实际：${msg}`);
    assert.ok(msg.includes("EIO"), `要带上宿主给的原由，实际：${msg}`);
    assert.ok(
      !msg.includes("not found"),
      `读失败不许说成找不到（两者该查的地方完全不同），实际：${msg}`,
    );
  });
});

test("★★ 循环依赖：a→b→a 必须说「循环依赖」，不是 C stack overflow", async () => {
  const resolve = fromFiles({ "a.lua": 'require("b")', "b.lua": 'require("a")' });
  await withLua({ resolveModule: resolve }, async (rt) => {
    const m = await rt.loadModule("m", 'require("a")');
    assert.equal(m.ok, false, "循环依赖不可能成功");
    const msg = m.ok ? "" : m.error.message;
    assert.ok(msg.includes("循环依赖"), `要说「循环依赖」，实际：${msg}`);
    assert.ok(msg.includes("->"), `要打出链条（谁依赖谁），实际：${msg}`);
    assert.ok(!msg.includes("stack overflow"), `不该退化成栈溢出，实际：${msg}`);
  });
});

test("★ 递归加载：a→b→c 三层，值一路传回来", async () => {
  const resolve = fromFiles({
    "c.lua": "return 3",
    "b.lua": 'local n = require("c")\nreturn n + 1',
    "a.lua": 'local n = require("b")\nreturn n + 1',
  });
  await withLua({ resolveModule: resolve }, async (rt) => {
    const m = await rt.loadModule("m", 'local n = require("a")\nfunction got() return n end');
    assert.equal(m.ok, true, m.ok ? "" : m.error.message);
    const r = await rt.call("m.got");
    assert.equal(r.ok ? r.value : "?", 5);
  });
});

test("★★ 真实 DST 的形状：共享模式 + 解析器 ⇒ `require(\"class\")` 才真的落地（101 个失败的形状）", async () => {
  const CLASS_LIKE = [
    "Class = function(ctor)",
    "  local c = {}",
    "  c.__index = c",
    "  return { new = function(...) local s = {}; ctor(s, ...); return s end }",
    "end",
  ].join("\n");
  const BT_LIKE = [
    'require("class")', // ★ 裸 require，不接返回值 —— DST 到处都是这种
    "BT = Class(function(self) self.ready = true end)",
    "function makeBT() return BT.new() end",
  ].join("\n");

  const resolve = fromFiles({ "class.lua": CLASS_LIKE, "behaviourtree.lua": BT_LIKE });
  await withLua({ sharedModuleEnv: true, resolveModule: resolve }, async (rt) => {
    // ★ 只 load behaviourtree：class 从来没被宿主 loadModule 过，
    //   全靠 require 把它从解析器里拉进来 —— 这就是失败 101 个的那条路。
    const bt = await rt.loadModule("behaviourtree", BT_LIKE);
    assert.equal(bt.ok, true, bt.ok ? "" : bt.error.message);
    const made = await rt.call("makeBT");
    assert.equal(made.ok, true, made.ok ? "" : made.error.message);
    assert.deepEqual(made.ok ? made.value : null, { ready: true });
  });
});

test("★ collectModuleSources：只收 .lua、键是相对路径、可直接喂给解析器", async () => {
  const fs = new MemoryFileSystem();
  await fs.ensureDir("/mods");
  await fs.ensureDir("/mods/ai");
  await fs.writeText("/mods/cls.lua", "return 1");
  await fs.writeText("/mods/ai/brain.lua", "return 2");
  await fs.writeText("/mods/readme.txt", "不是 Lua");
  await fs.writeText("/mods/anim.zip", "也不是 Lua");

  const got = await collectModuleSources(fs, "/mods");
  assert.equal(got.ok, true, got.ok ? "" : got.error.message);
  const keys = got.ok ? [...got.value.keys()].sort() : [];
  assert.deepEqual(keys, ["ai/brain.lua", "cls.lua"], "键是相对路径，且只收 .lua");

  const resolve = got.ok ? resolverFromSources(got.value) : fromFiles({});
  assert.equal(resolve("cls").ok, true);
  assert.equal(resolve("ai.brain").ok, true, "点号要在解析器这一层转成目录");
});

test("★ collectModuleSources：不能列目录时明确报错，不返回空表（空表的含义是「这个目录是空的」）", async () => {
  const real = new MemoryFileSystem();
  const blind: IReadableFileSystem = {
    scheme: "http",
    canList: false,
    readText: (p) => real.readText(p),
    readBinary: (p) => real.readBinary(p),
    exists: (p) => real.exists(p),
    list: async () => ({ ok: false, error: { code: "FS.NOT_SUPPORTED", message: "静态资源服务器没有列目录" } }),
    stat: (p) => real.stat(p),
  };
  const got = await collectModuleSources(blind, "/mods");
  assert.equal(got.ok, false);
  const code = got.ok ? "" : got.error.code;
  assert.equal(code, "SCRIPT.MODULE_LIST_UNSUPPORTED", "错误码要能分辨「宿主没这个能力」");
});
