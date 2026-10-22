/**
 * L5 · 脚本后端：null（诚实降级）
 *
 * ★ 这个后端**不假装能执行脚本**。
 *   它与 `gfx-null` 的区别值得说清：null 图形设备可以"假装渲染并记录调用"，
 *   因为渲染的产物是像素，没人校验像素；而脚本的产物是**世界状态**，
 *   假装执行会让"脚本没跑"看起来像"脚本跑了但没效果" —— 这是最难查的一类 bug。
 *
 *   所以这里：`loadModule` 记录源码（可诊断"到底加载了哪些"），
 *   `call` 一律返回 `SCRIPT.NOT_SUPPORTED`，`caps.executes === false`。
 *   上层（`ScriptModule`）看到这个 caps 就该在 init 阶段直接报错，
 *   而不是跑起来一帧帧刷日志。
 *
 * 用途：headless 判据、纯表现宿主、以及"平台探测"（只想知道有没有脚本能力）。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import {
  ScriptErrorCode,
  type HostFunction,
  type IScriptRuntime,
  type ScriptBackendFactory,
  type ScriptCallOptions,
  type ScriptCaps,
  type ScriptRuntimeStats,
  type ScriptValue,
} from "../../platform/script/runtime.ts";

export interface NullScriptRecord {
  readonly name: string;
  readonly bytes: number;
}

export class NullScriptRuntime implements IScriptRuntime {
  readonly id = "null";
  readonly caps: ScriptCaps = {
    language: "none",
    version: null,
    interruptible: false,
    hostCalls: false,
    executes: false,
  };

  private readonly modules = new Map<string, string>();
  private readonly hostFns = new Map<string, HostFunction>();
  private readonly loaded: NullScriptRecord[] = [];
  private calls = 0;
  private errors = 0;
  private disposed = false;

  async loadModule(name: string, source: string): Promise<Result<void, EngineError>> {
    if (this.disposed) return this.disposedErr();
    this.modules.set(name, source);
    this.loaded.push({ name, bytes: source.length });
    return ok(undefined);
  }

  async unloadModule(name: string): Promise<Result<void, EngineError>> {
    if (this.disposed) return this.disposedErr();
    this.modules.delete(name);
    return ok(undefined);
  }

  hasModule(name: string): boolean {
    return this.modules.has(name);
  }

  listModules(): readonly string[] {
    return Array.from(this.modules.keys()).sort();
  }

  async call(
    fn: string,
    args: readonly ScriptValue[] = [],
    _opts: ScriptCallOptions = {},
  ): Promise<Result<ScriptValue, EngineError>> {
    void args;
    if (this.disposed) return this.disposedErr();
    this.calls++;
    this.errors++;
    return err(
      engineError(
        ScriptErrorCode.NotSupported,
        `null 脚本后端不能执行 ${fn}（这个平台没有脚本能力：caps.executes=false）`,
        { fn },
      ),
    );
  }

  expose(name: string, fn: HostFunction): Result<void, EngineError> {
    if (this.disposed) return this.disposedErr();
    this.hostFns.set(name, fn);
    return ok(undefined);
  }

  exposed(): readonly string[] {
    return Array.from(this.hostFns.keys()).sort();
  }

  async ready(): Promise<Result<void, EngineError>> {
    return this.disposed ? this.disposedErr() : ok(undefined);
  }

  stats(): ScriptRuntimeStats {
    return {
      modules: this.modules.size,
      calls: this.calls,
      errors: this.errors,
      timeouts: 0,
    };
  }

  /** 诊断：加载历史（含热重载的重复项）。 */
  history(): readonly NullScriptRecord[] {
    return this.loaded.slice();
  }

  dispose(): void {
    this.disposed = true;
    this.modules.clear();
    this.hostFns.clear();
  }

  private disposedErr(): Result<never, EngineError> {
    return err(engineError(ScriptErrorCode.Disposed, "脚本运行时已释放"));
  }
}

export const nullScriptBackend: ScriptBackendFactory = {
  id: "null",
  probe: () => true,
  create: () => ok(new NullScriptRuntime()),
};
