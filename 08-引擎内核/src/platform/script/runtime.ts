/**
 * L1 · 脚本运行时接口
 *
 * ★★ 为什么脚本层必须是**接口**而不是"内核里直接嵌 Lua"：
 *   要复用的内容层是 153 万行 Lua，但"内核绑定 Lua"会让三件事同时变贵：
 *     ① 换语言（JS / DSL / 可视化图）＝ 重写内核；
 *     ② 判据必须拖一个 Lua 解释器才能测内核（内核不再是纯 TS）；
 *     ③ 浏览器与 headless 要各写一套绑定。
 *   把 Lua 放到 `IScriptRuntime` 后面，内核只认"C 风格调用 + 反射表"。
 *
 * ★★ 为什么方法**全是异步的**（哪怕 Lua 求值本身是同步的）：
 *   与 `IFileSystem` 同一条理由 —— 浏览器里 WASM 加载、Worker 隔离、远程调试桥
 *   都必然是异步的。接口若定成同步，接其中任何一个都要改签名，也就是改所有调用方。
 *   代价是调用点多一个 `await`；收益是"换实现不改核心"这条承诺真的成立。
 *   （`BackendRegistry.create()` 仍是同步的：它只**构造** runtime，
 *    真正的初始化被包在 runtime 内部的 ready Promise 里，见 `ready()`。）
 *
 * ★ 值语义：跨语言边界**只传值**，不传对象引用。
 *   宿主对象（Node / Scene / GPU 句柄）一律通过 `expose()` 变成脚本侧的函数表，
 *   脚本拿到的是"调用能力"，不是"引擎内存"。这条边界是异常隔离与未来
 *   "把脚本丢进 Worker"的前提；一旦允许传引用，这两件事都做不了。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

// ------------------------------------------------------------------ 值

/** 脚本能传的值。刻意**不含** `undefined` / `bigint` / 函数 / 类实例 —— 它们不可序列化。 */
export type ScriptPrimitive = null | boolean | number | string;
export type ScriptValue = ScriptPrimitive | readonly ScriptValue[] | { readonly [key: string]: ScriptValue };

/** 暴露给脚本的宿主函数。返回值会被转成 `ScriptValue`（`undefined` 视为 null）。 */
export type HostFunction = (...args: ScriptValue[]) => ScriptValue | undefined;

export interface ScriptCaps {
  /** 语言名（`lua` / `js` / `none`）。 */
  readonly language: string;
  /** 语言版本（`5.4`）。null 表示"没有执行能力"。 */
  readonly version: string | null;
  /** 能不能打断死循环（有时间预算）。false 时 `timeoutMs` 会被**明确报错**而不是静默忽略。 */
  readonly interruptible: boolean;
  /** 能不能把宿主函数暴露给脚本。 */
  readonly hostCalls: boolean;
  /** 执行能力档位。`none` = 只能登记模块、不能求值（诚实降级，不假装成功）。 */
  readonly executes: boolean;
}

export interface ScriptCallOptions {
  /**
   * 本次调用的时间预算（毫秒）。超时返回 `SCRIPT.TIMEOUT` 且**运行时仍可用**。
   * 未指定则不限 —— 只该在"信任的脚本 + 离线工具"里这么做。
   */
  readonly timeoutMs?: number;
}

export interface ScriptRuntimeStats {
  readonly modules: number;
  readonly calls: number;
  /** 失败调用数（含超时）。 */
  readonly errors: number;
  readonly timeouts: number;
}

// ------------------------------------------------------------------ 接口

export interface IScriptRuntime {
  /** 实现 id（`lua` / `null`）。与后端 id 一致，便于日志对账。 */
  readonly id: string;
  readonly caps: ScriptCaps;

  /**
   * 加载（或**覆盖**）一个模块。同名重复加载 = 重新定义，不是错误 ——
   * 热重载与编辑器 PIE 都靠这条语义。
   * `name` 是逻辑模块名（`ai.brain`），不是文件路径；路径 → 模块名由上层映射。
   *
   * ★★ **热重载的三条不变量**（批104 补的判据钉住，实现见 `backends/script-lua`）：
   *   ① **先编译后替换**：新源码编译失败 ⇒ 返回错误，**旧模块还能照跑**。
   *      热更最常见的用法是"边跑边改"，改坏的中间态绝不能把运行中的游戏打挂；
   *   ② **执行期出错同样不换**：编译通过但 chunk 抛错时，登记表一个字节不动；
   *   ③ **每次都造新的 env**：新版本看不到上一版的全局（`counter = 3` 不会残到新版），
   *      这是热更最典型的串味缺陷。
   *   三条都由 `tests/backends/script-hot-reload.test.ts` 守着 —— 只写在文档里的话，
   *   它会在某次"顺手优化"里静默消失。
   */
  loadModule(name: string, source: string): Promise<Result<void, EngineError>>;
  unloadModule(name: string): Promise<Result<void, EngineError>>;
  hasModule(name: string): boolean;
  listModules(): readonly string[];

  /**
   * 调用脚本侧全局函数。
   * 失败一律走 Result（脚本 `error()`、函数不存在、超时都是**可预期失败**）；
   * 抛异常只代表运行时自身坏了。
   */
  call(fn: string, args?: readonly ScriptValue[], opts?: ScriptCallOptions): Promise<Result<ScriptValue, EngineError>>;

  /** 暴露宿主函数到脚本全局表。重复同名 = 覆盖（热重载友好）。 */
  expose(name: string, fn: HostFunction): Result<void, EngineError>;
  exposed(): readonly string[];

  /** 初始化完成的信号。`create()` 同步返回，真正加载 WASM 在这里。 */
  ready(): Promise<Result<void, EngineError>>;

  stats(): ScriptRuntimeStats;
  /** 释放。幂等；之后的调用返回 `SCRIPT.DISPOSED`（不是崩）。 */
  dispose(): void;
}

export interface ScriptBackendFactory {
  readonly id: string;
  probe(options?: unknown): boolean;
  /** 只构造，不做 IO（WASM 加载在 `ready()` 里）。 */
  create(options?: unknown): Result<IScriptRuntime, EngineError>;
}

// ------------------------------------------------------------------ 工具

/** 稳定的错误码。调用方按 code 分支，不解析 message。 */
export const ScriptErrorCode = {
  NotSupported: "SCRIPT.NOT_SUPPORTED",
  Disposed: "SCRIPT.DISPOSED",
  NoFunction: "SCRIPT.NO_FUNCTION",
  CallFailed: "SCRIPT.CALL_FAILED",
  Timeout: "SCRIPT.TIMEOUT",
  LoadFailed: "SCRIPT.LOAD_FAILED",
  BadValue: "SCRIPT.BAD_VALUE",
} as const;

/**
 * 值校验：把"不可跨边界的东西"在进运行时之前就挡掉。
 * 不做这一步的症状是"某个字段在 Lua 侧变成 userdata/nil"，很难回溯到调用方。
 */
export function assertScriptValue(v: unknown, where: string): Result<ScriptValue, EngineError> {
  const walk = (x: unknown, depth: number): Result<ScriptValue, EngineError> => {
    if (depth > 32) {
      return err(engineError(ScriptErrorCode.BadValue, `${where}: 嵌套超过 32 层（八成是成环的引用）`));
    }
    if (x === null || typeof x === "boolean" || typeof x === "string") return ok(x);
    if (typeof x === "number") {
      if (!Number.isFinite(x)) {
        // NaN/Infinity 在 Lua 里能表示，但在存档与判据里是确定的灾难
        return err(engineError(ScriptErrorCode.BadValue, `${where}: 数值 ${String(x)} 不是有限数`));
      }
      return ok(x);
    }
    if (Array.isArray(x)) {
      const out: ScriptValue[] = [];
      for (let i = 0; i < x.length; i++) {
        const r = walk(x[i], depth + 1);
        if (!r.ok) return r;
        out.push(r.value);
      }
      return ok(out);
    }
    if (typeof x === "object") {
      const src = x as Record<string, unknown>;
      const out: Record<string, ScriptValue> = {};
      for (const k of Object.keys(src).sort()) {
        // 排序：保证跨语言转换顺序确定（与存档的确定性同一诉求）
        const r = walk(src[k], depth + 1);
        if (!r.ok) return r;
        out[k] = r.value;
      }
      return ok(out);
    }
    return err(
      engineError(ScriptErrorCode.BadValue, `${where}: 类型 ${typeof x} 不能跨脚本边界（只允许 null/bool/number/string/数组/纯对象）`),
    );
  };
  return walk(v, 0);
}
