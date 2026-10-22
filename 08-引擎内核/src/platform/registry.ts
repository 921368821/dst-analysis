/**
 * L1 · 后端注册表
 *
 * 这是"可扩展性"在平台层的落点：**新增一个后端 = 一次 register，不改任何调用方**。
 *
 * 设计要点：
 *
 * ① **按 kind 分表**（gfx/audio/input/fs/net）。用 `kind → id → {priority, factory}`。
 *    调用方只写 `create('gfx')`，它拿到的可能是 WebGL2 / WebGPU / Null —— 但
 *    **接口完全一样**，所以调用方不需要知道，也不需要 `if` 分支。
 *
 * ② **priority + 显式指定**。默认取优先级最高的**可用**后端（`probe()` 返回 true）。
 *    宿主可以强制指定（`create('gfx', { prefer: 'null' })`）—— 判据和 headless 靠这个。
 *    为什么要 priority 而不只是"注册顺序"：注册顺序取决于 import 顺序，
 *    那是一个"看起来稳定其实很脆弱"的隐式约定。
 *
 * ③ **创建失败要有原因**。全部不可用时返回一条带**每个候选为什么失败**的错误，
 *    而不是笼统的"没有可用后端"。这类笼统错误在生产上几乎无法定位
 *    （"为什么我这儿黑屏？"）。
 *
 * ④ **注册表本身不是单例**。每个宿主（player/editor/headless）各持一个，
 *    这样判据可以在同一个进程里并行跑多个不同配置的平台，互不污染。
 *    （上一代引擎用模块级单例，导致"两个测试互相覆盖端口"这种问题。）
 */

import { engineError, ok, err, type Result } from "../foundation/result.ts";
import type { EngineError } from "../foundation/result.ts";
import type { GraphicsBackendFactory, IGraphicsDevice } from "./gfx/device.ts";
import type { AudioBackendFactory, IAudioDevice } from "./audio/device.ts";
import type { InputBackendFactory, IInputDevice } from "./input/device.ts";
import type { FsBackendFactory, IFileSystem, NetBackendFactory, ITransport } from "./fs/fs.ts";

export const BackendKind = {
  Gfx: "gfx",
  Audio: "audio",
  Input: "input",
  Fs: "fs",
  Net: "net",
} as const;
export type BackendKindValue = (typeof BackendKind)[keyof typeof BackendKind];

/** kind → 该 kind 的后端提供的对象类型。新增 kind 时在这里加一行。 */
export interface BackendTypeMap {
  gfx: IGraphicsDevice;
  audio: IAudioDevice;
  input: IInputDevice;
  fs: IFileSystem;
  net: ITransport;
}

export interface BackendEntry<T> {
  readonly id: string;
  readonly priority: number;
  readonly probe: (options?: unknown) => boolean;
  readonly create: (options?: unknown) => Result<T, EngineError>;
}

export interface CreateOptions<T extends BackendKindValue> {
  /** 强制指定后端 id；不存在或 probe 失败都算错误（不静默回退）。 */
  readonly prefer?: string;
  /** 传给后端工厂的参数（canvas 等）。 */
  readonly options?: unknown;
  /** 允许的 id 白名单（"这个宿主只接受这两条后端"）。 */
  readonly allow?: readonly string[];
  /** 判据/headless 用：允许在 prefer 不可用时回退到 null 后端。 */
  readonly allowFallbackToNull?: boolean;
  readonly _kind?: T;
}

export class BackendRegistry {
  private readonly tables = new Map<string, Map<string, BackendEntry<unknown>>>();

  register<T extends BackendKindValue>(
    kind: T,
    entry: BackendEntry<BackendTypeMap[T]>,
  ): void {
    let table = this.tables.get(kind);
    if (table === undefined) {
      table = new Map();
      this.tables.set(kind, table);
    }
    if (table.has(entry.id)) {
      // 重名注册会让"到底用了哪个"变成运气问题 —— 直接拒绝
      throw new Error(`后端 ${kind}/${entry.id} 已经注册过（同 id 不允许重复注册）`);
    }
    table.set(entry.id, entry as BackendEntry<unknown>);
  }

  /** 便捷注册：从工厂对象批量取 probe/create。 */
  registerGfx(f: GraphicsBackendFactory, priority = 100): void {
    this.register("gfx", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerAudio(f: AudioBackendFactory, priority = 100): void {
    this.register("audio", {
      id: f.id,
      priority,
      probe: f.probe,
      create: f.create,
    });
  }
  registerInput(f: InputBackendFactory, priority = 100): void {
    this.register("input", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerFs(f: FsBackendFactory, priority = 100): void {
    this.register("fs", { id: f.id, priority, probe: f.probe, create: f.create });
  }
  registerNet(f: NetBackendFactory, priority = 100): void {
    this.register("net", { id: f.id, priority, probe: f.probe, create: f.create });
  }

  list(kind: BackendKindValue): readonly string[] {
    return Array.from(this.tables.get(kind)?.keys() ?? []).sort();
  }

  has(kind: BackendKindValue, id: string): boolean {
    return this.tables.get(kind)?.has(id) ?? false;
  }

  /**
   * 创建后端。选择顺序：
   *   1) `prefer` 指定 → 必须成功（除非 `allowFallbackToNull` 且 `null` 可用）
   *   2) `allow` 白名单内、probe 通过、priority 最高的
   *   3) 全失败 → 返回聚合错误
   */
  create<T extends BackendKindValue>(
    kind: T,
    opts: CreateOptions<T> = {},
  ): Result<BackendTypeMap[T], EngineError> {
    const table = this.tables.get(kind);
    if (table === undefined || table.size === 0) {
      return err(
        engineError(
          "BACKEND.NONE_REGISTERED",
          `没有任何 ${kind} 后端被注册（宿主应该在 bootstrap 阶段调用 register* ）`,
        ),
      );
    }

    const notes: string[] = [];

    if (opts.prefer !== undefined) {
      const e = table.get(opts.prefer);
      if (e === undefined) {
        notes.push(`prefer=${opts.prefer} 未注册`);
      } else if (!e.probe(opts.options)) {
        notes.push(`prefer=${opts.prefer} 探测失败（该环境不支持）`);
      } else {
        const r = e.create(opts.options);
        if (r.ok) return ok(r.value as BackendTypeMap[T]);
        notes.push(`prefer=${opts.prefer} 创建失败：${r.error.message}`);
      }
    }

    const cands = Array.from(table.values())
      .filter((e) => opts.allow === undefined || opts.allow.includes(e.id))
      .sort((a, b) => b.priority - a.priority);

    for (const e of cands) {
      if (opts.allowFallbackToNull === false && e.id === "null") continue;
      let probed = false;
      try {
        probed = e.probe(opts.options);
      } catch (ex) {
        notes.push(`${e.id} 探测抛错：${ex instanceof Error ? ex.message : String(ex)}`);
        continue;
      }
      if (!probed) {
        notes.push(`${e.id} 不可用`);
        continue;
      }
      const r = e.create(opts.options);
      if (r.ok) return ok(r.value as BackendTypeMap[T]);
      notes.push(`${e.id} 创建失败：${r.error.message}`);
    }

    return err(
      engineError("BACKEND.UNAVAILABLE", `没有可用的 ${kind} 后端`, {
        kind,
        candidates: opts.allow ?? Array.from(table.keys()),
        reasons: notes,
      }),
    );
  }
}
