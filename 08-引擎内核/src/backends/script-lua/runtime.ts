/**
 * L5 · 脚本后端：Lua（wasmoon / Lua 5.4）
 *
 * 这个后端是"真的能执行"的那一档（`caps.executes === true`）。
 * 与 null 后端的差别不是"实现多寡"，而是**失败必须可判定**：
 *   · 函数不存在 → `NO_FUNCTION`（不是 Lua 的 "attempt to call a nil value"）
 *   · 脚本 error  → `CALL_FAILED`，但运行时随后仍可用
 *   · 死循环      → `TIMEOUT`，打断后运行时仍可用
 *   · 语法错误    → `LOAD_FAILED`，且**旧模块还能跑**（热重载不能把线上打挂）
 *
 * ★★ 为什么所有出站调用都走一个 Lua 侧 dispatcher（`__engine_dispatch`），
 *   而不是 `lua.global.get(fn)` 拿到函数直接调用：
 *   1. wasmoon 的 `global.get` 返回的 JS 包装器内部会 `newThread()`，
 *      也就是**在一条新建的 coroutine 上跑**。Lua 5.4 的 hook 是**每线程**的，
 *      在宿主状态上 `debug.sethook` 管不到那条 coroutine ⇒ 超时永远不触发。
 *      在 dispatcher 里用 `coroutine.running()` 拿到当前线程再挂 hook，才真的能打断。
 *   2. `global.get` 对"全局不存在"只会抛 `A value of type 'nil' ...`，
 *      调用方无法区分"脚本没定义这个函数"和"运行时坏了"。
 *      dispatcher 在 Lua 侧先 `type(fn) ~= "function"` 判定，给出稳定状态码。
 *   3. 多返回值：wasmoon 的 JS 包装器只保留**第一个**返回值（`lua_pcallk(..., 1, ...)`），
 *      所以 dispatcher 返回**一张表** `{s=状态, v=值, m=消息}`，语义可控。
 *
 * ★★ 传参绝不拼接源码字符串：参数按值经 wasmoon 推入 Lua 表，Lua 侧用
 *   `table.unpack(args, 1, n)` 展开。拼接源码等于把脚本注入的口子开在宿主侧。
 *
 * ★ wasmoon 1.16 的已知坑（都是实测的，处理方式写在代码旁）：
 *   ① Node 22 下 `createEngine()` 会因 emscripten 环境变量断言失败 —— 见 `withSanitizedEnv`。
 *   ② JS `null` 不能经 wasmoon 推入 Lua：`PromiseTypeExtension.pushValue` 对
 *      `null.then` 直接抛 TypeError。顶层 null 用 `undefined`（= nil）代替；
 *      嵌套 null 在 Lua 表里本来也只能是 nil（键消失），这是 Lua 的表示能力上限，
 *      不是可以在这一层"修好"的东西。`sanitizeForLua` 负责这层降级，并保持诚实。
 *   ③ `pairs` 顺序在同一 state 内稳定、跨实例不保证 —— 本文件不依赖它。
 */

import { LuaFactory } from "wasmoon";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import {
  ScriptErrorCode,
  assertScriptValue,
  type HostFunction,
  type IScriptRuntime,
  type ScriptBackendFactory,
  type ScriptCallOptions,
  type ScriptCaps,
  type ScriptRuntimeStats,
  type ScriptValue,
} from "../../platform/script/runtime.ts";

// ------------------------------------------------------------------ 环境变量

/**
 * ★★ 为什么创建 Lua 引擎前要处理环境变量：
 *   wasmoon 的 wasm 由 emscripten 生成，`environ_get` 里逐字符断言
 *   `charCode <= 255`（它按 byte 写环境）。任何非 Latin1 的环境字符串都会
 *   让 `createEngine()` 直接 `Aborted(Assertion failed)` —— 报错点在 wasm 里，
 *   与根因（环境变量编码）完全无关，不查一次源码根本猜不到。
 *
 *   本机实测（Node 22 + node:test）真正越界的是 **`_`**：
 *   emscripten 的默认环境里 `_` = 程序名（Node 下取 `process.argv[1]`），
 *   而 node:test 的 argv[1] 是测试文件路径 —— 工程目录名含中文。
 *   （任务简报里写的是 `PWD`；`PWD` 也可能命中，所以两种都处理，见下。）
 *
 *   处理分两层：
 *   ① 创建前把 `process.env` 里含 `charCode > 255` 的值临时换成下划线，
 *      创建完成（或失败）后**立即还原**；
 *   ② 显式传 `environmentVariables` 覆盖给 wasmoon：把有问题的键换成 ASCII，
 *      并强制 `_` = "lua"。第 ② 层是**必需**的 —— 只改 `process.env` 不一定
 *      有效：emscripten 的 ENV 可能在模块 import 时就已经定型，且 `_` 根本
 *      不在 `process.env` 里（它来自 argv）。
 *
 *   浏览器没有 `process.env` / argv，`_` 覆盖仍然无害。
 *
 *   ★ 用模块级 Promise 串行化：两个 Lua 实例并行创建时，A 还原环境变量的瞬间
 *     可能正好落在 B 的 wasm 初始化中间 ⇒ B 又失败。串行化只花一次引擎加载的时间。
 */
let envGate: Promise<unknown> = Promise.resolve();

function withSanitizedEnv<T>(fn: (envOverrides: Record<string, string>) => Promise<T>): Promise<T> {
  const run = envGate.then(
    () => runWithSanitizedEnv(fn),
    () => runWithSanitizedEnv(fn),
  );
  envGate = run.then(
    () => undefined,
    () => undefined,
  );
  return run;
}

async function runWithSanitizedEnv<T>(
  fn: (envOverrides: Record<string, string>) => Promise<T>,
): Promise<T> {
  const proc = (globalThis as { process?: { env?: Record<string, string | undefined> } }).process;
  const env: Record<string, string> = { _: "lua" };
  const saved: Array<[string, string]> = [];

  if (proc !== undefined && proc.env !== undefined) {
    for (const [key, value] of Object.entries(proc.env)) {
      if (value === undefined) continue;
      if (!/[^\u0000-\u00ff]/.test(value)) continue;
      saved.push([key, value]);
      const ascii = value.replace(/[^\u0000-\u00ff]/g, "_");
      proc.env[key] = ascii;
      env[key] = ascii;
    }
    // `_` 必须最后写：即使 process.env._ 本身是 ASCII，它也可能是错的值（program 路径）
    env["_"] = "lua";
  }

  try {
    return await fn(env);
  } finally {
    // 还原是 finally：创建失败时也必须还原，否则宿主进程被永久改坏
    for (const [key, value] of saved) proc!.env![key] = value;
  }
}

// ------------------------------------------------------------------ Lua 侧引导

/**
 * 引导脚本只定义"边界原语"，不含任何业务。
 * 所有名字以 `__engine_` 开头：`expose()` 拒绝这个前缀，避免脚本/宿主互相覆盖。
 *
 * `__engine_dispatch` 的状态码（与 TS 侧 `LuaStatus` 一一对应）：
 *   0 成功（v 是返回值，可能为 nil）
 *   1 脚本运行时错误（m 是 Lua 原始错误信息，保留给诊断）
 *   2 全局函数不存在
 *   3 宿主函数拒绝了参数（参数不可跨边界）
 *   4 超时
 */
const BOOTSTRAP = `
__engine_deadline = 0

-- 计时钩子：只在调用方给了 timeoutMs 时挂上（否则每 N 条指令一次回调是白付的开销）。
-- 用 CPU 时间而不是 Date.now：脚本里拿不到 JS 时钟，os.clock 在 wasm 里可用且单调。
__engine_timeout_hook = function()
  if os.clock() >= __engine_deadline then
    error("__ENGINE_TIMEOUT__", 0)
  end
end

-- 支持 "a.b.c" 形式的函数名：模块可以把 API 挂在自己的表里。
local function __engine_walk(root, path)
  local cur = root
  for part in string.gmatch(path, "[^.]+") do
    if type(cur) ~= "table" then return nil end
    cur = cur[part]
  end
  return cur
end

-- 已加载模块的"函数表"（每次加载时对 _G 做差异快照，见 __engine_load）
__engine_modules = {}

local function __engine_resolve(name)
  -- ① 先按全局路径找（契约 call("greet") 就是这条）
  local g = __engine_walk(_G, name)
  if type(g) == "function" then return g end

  -- ② 再按"模块限定名"找：取最长匹配的模块名，避免 a 与 a.b 互相抢占。
  --    ScriptModule 用 "<module>.<entry>" 调用，所以两个模块都定义 onUpdate 时
  --    不会互相覆盖（模块名可以带点，所以必须用最长匹配）。
  local best = nil
  for m in pairs(__engine_modules) do
    if string.sub(name, 1, #m + 1) == m .. "." then
      if best == nil or #m > #best then best = m end
    end
  end
  if best ~= nil then
    local fn = __engine_walk(__engine_modules[best], string.sub(name, #best + 2))
    if fn ~= nil then return fn end
  end

  return g
end

function __engine_dispatch(name, args, n, timeout_ms)
  local out = {}
  local fn = __engine_resolve(name)
  if type(fn) ~= "function" then
    out.s = 2
    out.m = tostring(name)
    return out
  end

  local co = coroutine.running()
  local hooked = false
  if timeout_ms ~= nil and timeout_ms > 0 then
    __engine_deadline = os.clock() + timeout_ms / 1000
    debug.sethook(co, __engine_timeout_hook, "", 1000)
    hooked = true
  end

  local ok, v = pcall(fn, table.unpack(args or {}, 1, n or 0))

  -- 一定要清 hook（超时路径也要）：残留的钩子会让下一次调用莫名其妙地也超时
  if hooked then debug.sethook(co) end

  if ok then
    out.s = 0
    out.v = v
  else
    local msg = tostring(v)
    if string.find(msg, "__ENGINE_TIMEOUT__", 1, true) then
      out.s = 4
      out.m = msg
    elseif string.find(msg, "__ENGINE_BAD_VALUE__", 1, true) then
      out.s = 3
      out.m = msg
    else
      out.s = 1
      out.m = msg
    end
  end
  return out
end

-- 先编译后替换：load 只编译；语法错误时旧函数一个都没动。
-- 编译成功后才执行 chunk，其返回值写入 package.loaded[name]
--（模块名在 Lua 侧可见，调试时 print(package.loaded["ai.brain"]) 有东西看）。
--
-- ★ 模块函数表：执行前对 _G 做一次浅快照，执行后把"新增/被重定义且类型是
--   function"的全局收进 __engine_modules[name]。这样 "<module>.<entry>" 能精确
--   指到本模块的函数，两个模块都叫 onUpdate 也不会互相覆盖。
--   已知限制（诚实标注）：模块**共享 _G**，函数体里对全局变量的读写仍是共享的；
--   完整隔离需要每个模块一个 _ENV，那会与契约里的 call("greet")（全局函数）冲突，
--   本阶段不做。
function __engine_load(name, source)
  local chunk, compile_err = load(source, "@" .. name)
  if not chunk then
    return { s = 0, m = tostring(compile_err) }
  end

  local before = {}
  for k, v in pairs(_G) do before[k] = v end

  local ok, result = pcall(chunk)
  if not ok then
    -- 编译通过但执行期出错：不登记新模块表，旧函数保留（与语法错误同一策略）
    return { s = 2, m = tostring(result) }
  end

  local mt = __engine_modules[name]
  if mt == nil then
    mt = {}
    __engine_modules[name] = mt
  end
  -- 惯用写法 "return { onUpdate = ... }"：把返回表的成员也纳入模块命名空间
  if type(result) == "table" then
    for k, v in pairs(result) do mt[k] = v end
  end
  -- 再叠加本 chunk 在 _G 里新增/重定义的函数（显式定义优先于返回表）
  for k, v in pairs(_G) do
    if type(v) == "function" and before[k] ~= v then mt[k] = v end
  end

  package.loaded[name] = result == nil and true or result
  return { s = 1, m = "" }
end

function __engine_unload(name)
  package.loaded[name] = nil
  __engine_modules[name] = nil
  return { s = 1 }
end
`;

// ------------------------------------------------------------------ 值转换

/** dispatcher 的返回状态（与 BOOTSTRAP 中的数字一致）。 */
const LuaStatus = {
  Ok: 0,
  CallFailed: 1,
  NoFunction: 2,
  BadValue: 3,
  Timeout: 4,
} as const;

/**
 * 判断"这个 JS 对象是不是 Lua 的连续数组表"。
 * wasmoon 自己会把纯序列表转成数组，但它的判定依赖 `lua_next` 的遍历顺序；
 * 这里独立判定一次，保证**语义由我们的规格决定**，而不是库的实现细节：
 * 键恰好是 1..n（n > 0）⇒ 数组，否则对象。
 */
function looksLikeSequence(obj: Record<string, unknown>): boolean {
  const keys = Object.keys(obj);
  if (keys.length === 0) return false;
  for (let i = 1; i <= keys.length; i++) {
    if (!Object.prototype.hasOwnProperty.call(obj, String(i))) return false;
  }
  return true;
}

/**
 * Lua/JS 混合值 → `ScriptValue`。
 * 只在这里做"合法化"，上层拿到的每个值都满足契约（有限 number、纯对象、无函数）。
 */
function toScriptValue(v: unknown, where: string, depth = 0): Result<ScriptValue, EngineError> {
  if (depth > 32) {
    return err(engineError(ScriptErrorCode.BadValue, `${where}: 嵌套超过 32 层（八成是成环的表）`));
  }
  if (v === null || v === undefined) return ok(null);
  if (typeof v === "boolean" || typeof v === "string") return ok(v);
  if (typeof v === "number") {
    if (!Number.isFinite(v)) {
      return err(engineError(ScriptErrorCode.BadValue, `${where}: 数值 ${String(v)} 不是有限数`));
    }
    return ok(v);
  }
  if (Array.isArray(v)) {
    const out: ScriptValue[] = [];
    for (let i = 0; i < v.length; i++) {
      const r = toScriptValue(v[i], `${where}[${i}]`, depth + 1);
      if (!r.ok) return r;
      out.push(r.value);
    }
    return ok(out);
  }
  if (typeof v === "object") {
    const src = v as Record<string, unknown>;
    if (looksLikeSequence(src)) {
      const out: ScriptValue[] = [];
      for (let i = 1; i <= Object.keys(src).length; i++) {
        const r = toScriptValue(src[String(i)], `${where}[${i}]`, depth + 1);
        if (!r.ok) return r;
        out.push(r.value);
      }
      return ok(out);
    }
    const out: Record<string, ScriptValue> = {};
    // 排序：转换顺序确定 ⇒ 调试输出与判据可复现（不依赖 lua_next 顺序）
    for (const k of Object.keys(src).sort()) {
      const r = toScriptValue(src[k], `${where}.${k}`, depth + 1);
      if (!r.ok) return r;
      out[k] = r.value;
    }
    return ok(out);
  }
  return err(
    engineError(
      ScriptErrorCode.BadValue,
      `${where}: 类型 ${typeof v} 不能跨脚本边界（只允许 null/bool/number/string/数组/纯对象）`,
    ),
  );
}

/**
 * JS → Lua 的推入前处理。
 * ★ 只做一件事：`null` → `undefined`。原因见文件头的 wasmoon 坑 ②：
 *   `null` 会让 `PromiseTypeExtension.pushValue` 解引用 `null.then` 直接崩。
 *   `undefined` 在 Lua 侧就是 nil，语义等价；数组里的 null 会变成空洞，
 *   因此数组长度由 `n` 参数显式携带（`table.unpack(args, 1, n)`），不靠 `#`。
 */
function sanitizeForLua(v: ScriptValue): unknown {
  if (v === null) return undefined;
  if (Array.isArray(v)) {
    const out: unknown[] = [];
    for (let i = 0; i < v.length; i++) out.push(sanitizeForLua(v[i]!));
    return out;
  }
  if (typeof v === "object") {
    const src = v as { readonly [key: string]: ScriptValue };
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(src)) out[k] = sanitizeForLua(src[k]!);
    return out;
  }
  return v;
}

type LuaStatusTable = { readonly s?: unknown; readonly v?: unknown; readonly m?: unknown };

function statusOf(raw: unknown): LuaStatusTable {
  return (raw !== null && typeof raw === "object" ? raw : {}) as LuaStatusTable;
}

// ------------------------------------------------------------------ 运行时

export interface LuaBackendOptions {
  /**
   * `glue.wasm` 的 URI。
   * ★ Node 下可省（wasmoon 能自己解析到包内的 `dist/glue.wasm`）；
   *   **浏览器必须给** —— 省略时 wasmoon 会去 `unpkg.com` 下载，
   *   于是"离线能不能跑"变成了对 CDN 的依赖（本项目要求零外部资产）。
   *   典型值：`new URL("glue.wasm", location.href).href`。
   */
  readonly wasmPath?: string;
}

export class LuaScriptRuntime implements IScriptRuntime {
  readonly id = "lua";
  readonly caps: ScriptCaps = {
    language: "lua",
    version: "5.4",
    interruptible: true,
    hostCalls: true,
    executes: true,
  };

  private readonly opts: LuaBackendOptions;

  constructor(opts: LuaBackendOptions = {}) {
    this.opts = opts;
  }

  private engine: import("wasmoon").LuaEngine | null = null;
  private dispatchFn: ((...args: unknown[]) => unknown) | null = null;
  private loadFn: ((...args: unknown[]) => unknown) | null = null;
  private unloadFn: ((...args: unknown[]) => unknown) | null = null;

  private readyPromise: Promise<Result<void, EngineError>> | null = null;
  private readonly modules = new Map<string, string>();
  private readonly hostFns = new Map<string, HostFunction>();

  private calls = 0;
  private errors = 0;
  private timeouts = 0;
  private disposed = false;

  // ---------------------------------------------------------------- 生命周期

  ready(): Promise<Result<void, EngineError>> {
    if (this.disposed) return Promise.resolve(this.disposedErr());
    if (this.readyPromise === null) this.readyPromise = this.initEngine();
    return this.readyPromise;
  }

  private async initEngine(): Promise<Result<void, EngineError>> {
    let lua: import("wasmoon").LuaEngine | null = null;
    try {
      lua = await withSanitizedEnv((env) => new LuaFactory(this.opts.wasmPath, env).createEngine());
      if (this.disposed) {
        // dispose 发生在 WASM 加载途中：把这个引擎收掉，不要泄漏一个没人管的 state
        lua.global.close();
        return this.disposedErr();
      }
      await lua.doString(BOOTSTRAP);
      if (this.disposed) {
        // dispose 可能发生在 doString 的 await 期间（此时 engine 还没赋值，dispose 拿不到它）
        lua.global.close();
        return this.disposedErr();
      }

      const dispatch = lua.global.get("__engine_dispatch");
      const load = lua.global.get("__engine_load");
      const unload = lua.global.get("__engine_unload");
      if (typeof dispatch !== "function" || typeof load !== "function" || typeof unload !== "function") {
        lua.global.close();
        return err(
          engineError(ScriptErrorCode.LoadFailed, "Lua 引导脚本没有产出边界原语（__engine_dispatch/load/unload）"),
        );
      }
      this.engine = lua;
      this.dispatchFn = dispatch as (...args: unknown[]) => unknown;
      this.loadFn = load as (...args: unknown[]) => unknown;
      this.unloadFn = unload as (...args: unknown[]) => unknown;

      // ready 之前 expose 的宿主函数在这里补装（ScriptModule 会先 await ready，但接口不禁止早调）
      for (const [name, fn] of this.hostFns) this.installHost(lua, name, fn);
      return ok(undefined);
    } catch (e) {
      if (lua !== null) {
        try {
          lua.global.close();
        } catch {
          // 关不掉就算了：原始错误（加载失败）才是根因
        }
      }
      return err(
        engineError(
          ScriptErrorCode.LoadFailed,
          `Lua 运行时初始化失败：${e instanceof Error ? e.message : String(e)}`,
          { backend: this.id },
        ),
      );
    }
  }

  dispose(): void {
    if (this.disposed) return; // 幂等
    this.disposed = true;
    const lua = this.engine;
    this.engine = null;
    this.dispatchFn = null;
    this.loadFn = null;
    this.unloadFn = null;
    this.modules.clear();
    this.hostFns.clear();
    this.calls = 0;
    this.errors = 0;
    this.timeouts = 0;
    if (lua !== null) {
      try {
        lua.global.close();
      } catch {
        // 释放失败不该把 dispose 变成抛异常的接口（契约要求幂等、不抛）
      }
    }
  }

  // ---------------------------------------------------------------- 模块

  async loadModule(name: string, source: string): Promise<Result<void, EngineError>> {
    if (this.disposed) return this.disposedErr();
    const load = this.loadFn;
    if (load === null) {
      return err(engineError(ScriptErrorCode.LoadFailed, `加载模块 ${name} 前要先 await ready()`));
    }

    let raw: unknown;
    try {
      raw = load(name, source);
    } catch (e) {
      return err(
        engineError(
          ScriptErrorCode.LoadFailed,
          `模块 ${name} 编译/执行时边界异常：${e instanceof Error ? e.message : String(e)}`,
        ),
      );
    }

    const st = statusOf(raw);
    // s=1 成功；s=0 编译失败；s=2 执行期错误。后两者都算 LOAD_FAILED。
    if (st.s !== 1) {
      return err(
        engineError(ScriptErrorCode.LoadFailed, `模块 ${name} 加载失败：${String(st.m ?? "未知原因")}`, {
          module: name,
        }),
      );
    }

    // ★ 只有成功才替换登记：失败时旧模块名/旧函数保持原样（"先编译后替换"）
    this.modules.set(name, source);
    return ok(undefined);
  }

  async unloadModule(name: string): Promise<Result<void, EngineError>> {
    if (this.disposed) return this.disposedErr();
    this.modules.delete(name);
    // ★ 只摘模块表与 package.loaded。模块执行时写进 _G 的全局函数**不会**被删掉 ——
    //   运行时无法知道哪些全局属于它（我们不 hook _G 写入）。要彻底清掉，调用方应在
    //   加载前用独立 state（每个模块一个 runtime），那是下一步的事。
    try {
      this.unloadFn?.(name);
    } catch (e) {
      return err(
        engineError(
          ScriptErrorCode.CallFailed,
          `卸载模块 ${name} 时出错：${e instanceof Error ? e.message : String(e)}`,
        ),
      );
    }
    return ok(undefined);
  }

  hasModule(name: string): boolean {
    return this.disposed ? false : this.modules.has(name);
  }

  listModules(): readonly string[] {
    if (this.disposed) return [];
    return Array.from(this.modules.keys()).sort();
  }

  // ---------------------------------------------------------------- 调用

  async call(
    fn: string,
    args: readonly ScriptValue[] = [],
    opts: ScriptCallOptions = {},
  ): Promise<Result<ScriptValue, EngineError>> {
    if (this.disposed) return this.disposedErr();
    this.calls++;

    const dispatch = this.dispatchFn;
    if (dispatch === null) {
      this.errors++;
      return err(engineError(ScriptErrorCode.LoadFailed, `调用 ${fn} 前要先 await ready()`));
    }

    const checked: ScriptValue[] = [];
    for (let i = 0; i < args.length; i++) {
      const r = assertScriptValue(args[i], `call(${fn}) 参数 #${i}`);
      if (!r.ok) {
        this.errors++;
        return err(r.error);
      }
      checked.push(r.value);
    }

    const timeoutMs = opts.timeoutMs;
    if (timeoutMs !== undefined && !(Number.isFinite(timeoutMs) && timeoutMs > 0)) {
      this.errors++;
      return err(
        engineError(ScriptErrorCode.BadValue, `call(${fn}) 的 timeoutMs 必须是正的有限数（收到 ${String(timeoutMs)}）`),
      );
    }
    if (timeoutMs !== undefined && !this.caps.interruptible) {
      // 接口承诺：不可打断的后端必须显式报错，而不是静默忽略时间预算
      this.errors++;
      return err(engineError(ScriptErrorCode.NotSupported, `后端 ${this.id} 不能打断脚本，timeoutMs 无处生效`));
    }

    let raw: unknown;
    try {
      raw = dispatch(fn, sanitizeForLua(checked), checked.length, timeoutMs ?? 0);
    } catch (e) {
      // 走到这里说明 dispatcher 自身崩了（不是脚本 error，那条在 pcall 里）
      this.errors++;
      return err(
        engineError(
          ScriptErrorCode.CallFailed,
          `调用 ${fn} 时运行时异常：${e instanceof Error ? e.message : String(e)}`,
          { fn },
        ),
      );
    }

    const st = statusOf(raw);
    switch (st.s) {
      case LuaStatus.Ok: {
        const r = toScriptValue(st.v, `call(${fn}) 返回值`);
        if (!r.ok) {
          this.errors++;
          return err(r.error);
        }
        return r;
      }
      case LuaStatus.NoFunction:
        this.errors++;
        return err(
          engineError(ScriptErrorCode.NoFunction, `脚本里没有函数 ${fn}（不是可调用的 function）`, { fn }),
        );
      case LuaStatus.Timeout:
        this.errors++;
        this.timeouts++;
        return err(
          engineError(ScriptErrorCode.Timeout, `调用 ${fn} 超过 ${String(timeoutMs)} ms，已打断`, {
            fn,
            timeoutMs,
          }),
        );
      case LuaStatus.BadValue:
        this.errors++;
        return err(
          engineError(ScriptErrorCode.BadValue, String(st.m ?? "宿主函数拒绝了参数"), { fn }),
        );
      default:
        this.errors++;
        return err(
          engineError(ScriptErrorCode.CallFailed, String(st.m ?? "脚本执行失败（无错误信息）"), { fn }),
        );
    }
  }

  // ---------------------------------------------------------------- 宿主函数

  expose(name: string, fn: HostFunction): Result<void, EngineError> {
    if (this.disposed) return this.disposedErr();
    if (name.length === 0) {
      return err(engineError(ScriptErrorCode.BadValue, "expose 的名字不能为空"));
    }
    if (name.startsWith("__engine_")) {
      // 引导原语是我的边界，不能让宿主函数（或热重载）把它替换掉
      return err(
        engineError(ScriptErrorCode.BadValue, `expose 不能占用保留前缀 __engine_（收到 ${name}）`),
      );
    }
    this.hostFns.set(name, fn);
    const lua = this.engine;
    if (lua !== null) this.installHost(lua, name, fn);
    return ok(undefined);
  }

  exposed(): readonly string[] {
    if (this.disposed) return [];
    return Array.from(this.hostFns.keys()).sort();
  }

  private installHost(lua: import("wasmoon").LuaEngine, name: string, fn: HostFunction): void {
    /**
     * 包一层的原因：
     *  ① 参数在**进入宿主函数之前**校验 —— 否则 `function`/userdata 会以
     *     "奇怪对象"的形态钻进引擎，出问题的地方离根因很远；
     *  ② JS 异常必须变成 **Lua error**（wasmoon 会把这个 Error 交给 lua_error），
     *     这样脚本可以 `pcall` 捕获，不会穿透 wasm 边界把宿主进程打崩；
     *  ③ 返回值同样校验并做 null 降级（见 sanitizeForLua）。
     */
    lua.global.set(name, (...rawArgs: unknown[]) => {
      const args: ScriptValue[] = [];
      for (let i = 0; i < rawArgs.length; i++) {
        const r = toScriptValue(rawArgs[i], `${name} 参数 #${i}`);
        if (!r.ok) throw new Error(`__ENGINE_BAD_VALUE__: ${r.error.message}`);
        args.push(r.value);
      }

      let out: ScriptValue | undefined;
      try {
        out = fn(...args);
      } catch (e) {
        // 保留宿主异常原文（可诊断），但以 Lua error 的形式交给脚本
        throw e instanceof Error ? e : new Error(String(e));
      }

      const checked = assertScriptValue(out ?? null, `${name} 返回值`);
      if (!checked.ok) throw new Error(`__ENGINE_BAD_VALUE__: ${checked.error.message}`);
      return sanitizeForLua(checked.value);
    });
  }

  // ---------------------------------------------------------------- 统计

  stats(): ScriptRuntimeStats {
    return {
      modules: this.disposed ? 0 : this.modules.size,
      calls: this.disposed ? 0 : this.calls,
      errors: this.disposed ? 0 : this.errors,
      timeouts: this.disposed ? 0 : this.timeouts,
    };
  }

  private disposedErr(): Result<never, EngineError> {
    return err(engineError(ScriptErrorCode.Disposed, "脚本运行时已释放"));
  }
}

export const luaScriptBackend: ScriptBackendFactory = {
  id: "lua",
  // probe 只能是同步的：wasmoon 是硬依赖（import 失败在模块加载阶段就暴露了），
  // 真正"能不能加载 WASM"由 ready() 报 LOAD_FAILED。
  probe: () => true,
  create: () => ok(new LuaScriptRuntime()),
};

/**
 * 带配置的工厂（浏览器宿主用这个传 `wasmPath`）。
 * ★ 为什么工厂要分两个：`ScriptBackendFactory` 的 `create(options?)` 拿的是
 *   `unknown`（注册表不知道各后端的私有配置），而宿主想拿到类型检查。
 *   这个函数把类型收窄在**构造点**，注册表仍然只认统一接口。
 */
export function createLuaScriptBackend(opts: LuaBackendOptions = {}): ScriptBackendFactory {
  return {
    id: "lua",
    probe: () => true,
    create: () => ok(new LuaScriptRuntime(opts)),
  };
}
