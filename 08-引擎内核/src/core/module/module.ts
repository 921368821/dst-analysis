/**
 * L2 · 模块系统
 *
 * 这是"新增功能无需重构核心"的落点：**引擎的每一块能力都是一个 IModule**。
 * 渲染、物理、音频、AI、UI、世界生成……没有例外；内核本身只是"加载并排序这些模块"。
 *
 * ★ 为什么不用继承（`class RenderModule extends EngineModule`）：
 *   继承会把"引擎是什么"钉死成一棵类树，而模块之间的关系是**图**（渲染依赖 gfx，
 *   AI 依赖场景，UI 依赖输入+渲染）。用 id + deps 声明的图可以在运行时拓扑排序、
 *   可以做循环依赖检测、可以让第三方插件插到任意位置。类树做不到这三件事。
 *
 * ★ 生命周期四段，各自有明确语义（不许混）：
 *   init    —— 分配资源、注册自己提供的服务。**不许碰世界**（世界还没建）。
 *   start   —— 世界已建好，开始参与（订阅事件、启动泵）。
 *   stop    —— 停止参与（退订）。**世界还在**，可以安全读。
 *   dispose —— 释放全部资源。之后模块对象不可再用。
 *   逆序释放：谁后启动谁先停，谁先 init 谁后 dispose（与构造顺序相反）。
 *   这是 RAII 的图版本；顺序错了的症状是"释放时访问已释放的服务"（随机崩）。
 *
 * ★ 失败处理：`init` 失败 ⇒ 整个启动失败，并把**已经 init 成功的模块逆序回滚**。
 *   不许"部分启动"—— 一个缺了渲染模块的引擎看起来在跑，实际是黑屏，
 *   比直接报错更难查。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { err, ok } from "../../foundation/result.ts";
import type { Logger } from "../../foundation/log/logger.ts";
import type { EventBus } from "../../foundation/event/event-bus.ts";
import type { IPlatform } from "../../platform/platform.ts";
import type { ServiceRegistry } from "./services.ts";
import type { IRandom } from "../../foundation/random.ts";

export const ModuleState = {
  Created: "created",
  Initialized: "initialized",
  Started: "started",
  Stopped: "stopped",
  Disposed: "disposed",
  Failed: "failed",
} as const;
export type ModuleStateValue = (typeof ModuleState)[keyof typeof ModuleState];

/** 模块能拿到的一切（**显式注入**，没有全局单例）。 */
export interface ModuleContext {
  readonly log: Logger;
  readonly events: EventBus<Record<string, unknown>>;
  /**
   * 服务容器。模块从这里取 Scene / Scheduler / Assets。
   * ★ 为什么用 `require(token)` 而不是 `ctx.scene` 这样的便利字段：
   *   便利字段会让"引擎内核有哪些服务"变成 ModuleContext 的字段列表 ——
   *   每加一个服务就改一次内核接口（违反"新增功能不改核心结构"）。
   *   token 方式下，新服务由**提供它的模块**定义，内核完全不用改。
   */
  readonly services: ServiceRegistry;
  readonly platform: IPlatform;
  /** 世界级随机流（模块不该自己 new 一个，否则存档无法恢复它的状态）。 */
  readonly random: IRandom;
  /** 取自己声明的依赖模块（拿到的是实例，未声明的取不到 —— 这是刻意的）。 */
  readonly module: <T extends IModule>(id: string) => T | undefined;
}

/**
 * 模块钩子的返回值。
 * ★ 允许 `void`：绝大多数 init/start 不会失败，"必须写 `return ok(undefined)`"
 *   只会让每个模块多一行噪声，最后所有人都复制粘贴而不再想"这里会不会失败"。
 *   只有在**真的可能失败**时才返回 Result —— 那样失败才有意义。
 */
export type ModuleHookResult =
  | void
  | Result<void, EngineError>
  | Promise<void | Result<void, EngineError>>;

export interface IModule {
  /** 全局唯一。约定 `域.名`，例如 `render.batch2d`、`physics.2d`。 */
  readonly id: string;
  /** 硬依赖：缺一个就不启动。 */
  readonly deps?: readonly string[];
  /** 软依赖：有就用，没有就降级（例如"有音频就播，没有就静默"）。 */
  readonly optionalDeps?: readonly string[];

  init(ctx: ModuleContext): ModuleHookResult;
  start?(): ModuleHookResult;
  stop?(): void;
  dispose?(): void;

  /** 诊断用：返回一句人类可读的状态（编辑器/`/healthz` 展示）。 */
  describe?(): string;
}

interface Entry {
  readonly mod: IModule;
  state: ModuleStateValue;
  error: EngineError | null;
}

export interface ModuleRegistryOptions {
  /** 未知依赖时的行为：'fail' 严格（默认），'warn' 宽容（第三方插件开发期用）。 */
  readonly onMissingDep?: "fail" | "warn";
  /** 单个模块 init 超时（毫秒）。0 表示不限制。 */
  readonly initTimeoutMs?: number;
}

export class ModuleRegistry {
  private readonly entries = new Map<string, Entry>();
  /** 拓扑序（启动顺序）。stop/dispose 时逆序用。 */
  private order: string[] = [];
  private started = false;

  constructor(
    private readonly ctx: ModuleContext,
    private readonly opts: ModuleRegistryOptions = {},
  ) {}

  /**
   * 注册。**可以在 start 之前注册任意多个**，顺序无关（排序在启动时做）。
   * 启动后注册直接拒绝：热插拔模块需要先 stop，否则会出现"半个世界在用它"。
   */
  register(mod: IModule): Result<void, EngineError> {
    if (this.started) {
      return err({
        code: "MODULE.REGISTER_AFTER_START",
        message: `模块 ${mod.id} 在启动后注册 —— 先 stop 再 register（热插拔需要显式停止，不允许隐式）`,
      });
    }
    if (this.entries.has(mod.id)) {
      return err({
        code: "MODULE.DUPLICATE_ID",
        message: `模块 id 重复：${mod.id}`,
      });
    }
    this.entries.set(mod.id, { mod, state: ModuleState.Created, error: null });
    return ok(undefined);
  }

  get<T extends IModule>(id: string): T | undefined {
    return this.entries.get(id)?.mod as T | undefined;
  }

  state(id: string): ModuleStateValue | undefined {
    return this.entries.get(id)?.state;
  }

  ids(): readonly string[] {
    return Array.from(this.entries.keys());
  }

  /** 拓扑序（稳定：同层按 id 字典序，保证两次运行顺序一致 ⇒ 可回放）。 */
  private topoSort(): Result<string[], EngineError> {
    const indeg = new Map<string, number>();
    const out = new Map<string, string[]>();
    for (const id of this.entries.keys()) {
      indeg.set(id, 0);
      out.set(id, []);
    }
    for (const [id, e] of this.entries) {
      for (const d of e.mod.deps ?? []) {
        if (!this.entries.has(d)) {
          if ((this.opts.onMissingDep ?? "fail") === "fail") {
            return err({
              code: "MODULE.MISSING_DEP",
              message: `模块 ${id} 依赖 ${d}，但它没有注册`,
            });
          }
          this.ctx.log.channel("module").warn(`模块 ${id} 依赖 ${d} 缺失（宽容模式，继续）`);
          continue;
        }
        out.get(d)!.push(id);
        indeg.set(id, (indeg.get(id) ?? 0) + 1);
      }
      // 软依赖不算入度：缺失时不阻塞，存在时只需保证"它先启动"由硬依赖保证
      for (const d of e.mod.optionalDeps ?? []) {
        if (this.entries.has(d)) {
          out.get(d)!.push(id);
          indeg.set(id, (indeg.get(id) ?? 0) + 1);
        }
      }
    }

    const ready = Array.from(indeg.entries())
      .filter(([, n]) => n === 0)
      .map(([id]) => id)
      .sort();
    const result: string[] = [];
    while (ready.length > 0) {
      const id = ready.shift()!;
      result.push(id);
      const next: string[] = [];
      for (const succ of out.get(id)!) {
        const n = (indeg.get(succ) ?? 1) - 1;
        indeg.set(succ, n);
        if (n === 0) next.push(succ);
      }
      // 每轮重新排序，保证结果与插入顺序无关
      next.sort();
      ready.push(...next);
      ready.sort();
    }

    if (result.length !== this.entries.size) {
      const stuck = Array.from(this.entries.keys()).filter((id) => !result.includes(id)).sort();
      return err({
        code: "MODULE.CYCLE",
        message: `模块依赖存在环，涉及：${stuck.join(", ")}。环意味着"谁先启动"没有答案，必须拆开`,
        detail: { stuck },
      });
    }
    return ok(result);
  }

  /** 初始化并启动全部模块。失败时**已启动的逆序回滚**。 */
  async start(): Promise<Result<void, EngineError>> {
    if (this.started) {
      return err({ code: "MODULE.ALREADY_STARTED", message: "已经启动过" });
    }
    const sorted = this.topoSort();
    if (!sorted.ok) return sorted;

    this.order = sorted.value;
    const log = this.ctx.log.channel("module");

    // ---- init（按拓扑序）
    for (const id of this.order) {
      const e = this.entries.get(id)!;
      const r = await this.withTimeout(e.mod.init(this.ctx), id, "init");
      if (!r.ok) {
        e.state = ModuleState.Failed;
        e.error = r.error;
        log.error(`模块 ${id} init 失败：${r.error.message}`, { code: r.error.code });
        // 回滚：已经 init 过的（不含自己）逆序 dispose
        await this.rollback(id);
        return err({
          code: "MODULE.INIT_FAILED",
          message: `模块 ${id} init 失败：${r.error.message}`,
          detail: { moduleId: id, cause: r.error },
        });
      }
      e.state = ModuleState.Initialized;
    }

    // ---- start
    for (const id of this.order) {
      const e = this.entries.get(id)!;
      if (e.mod.start === undefined) {
        e.state = ModuleState.Started;
        continue;
      }
      const r = await this.withTimeout(e.mod.start(), id, "start");
      if (!r.ok) {
        e.state = ModuleState.Failed;
        e.error = r.error;
        log.error(`模块 ${id} start 失败：${r.error.message}`, { code: r.error.code });
        await this.rollback(id);
        return err({
          code: "MODULE.START_FAILED",
          message: `模块 ${id} start 失败：${r.error.message}`,
          detail: { moduleId: id, cause: r.error },
        });
      }
      e.state = ModuleState.Started;
    }

    this.started = true;
    log.info(`模块启动完成：${this.order.length} 个（${this.order.join(" → ")}）`);
    return ok(undefined);
  }

  /** 逆序 stop + dispose。单个模块抛错不阻断其余（但那一条会被记录并上抛）。 */
  async dispose(): Promise<Result<void, EngineError>> {
    const log = this.ctx.log.channel("module");
    const failures: string[] = [];
    for (const id of [...this.order].reverse()) {
      const e = this.entries.get(id);
      if (e === undefined) continue;
      if (e.state === ModuleState.Started) {
        try {
          e.mod.stop?.();
        } catch (ex) {
          failures.push(`${id}.stop: ${ex instanceof Error ? ex.message : String(ex)}`);
        }
        e.state = ModuleState.Stopped;
      }
      if (e.state === ModuleState.Stopped || e.state === ModuleState.Initialized) {
        try {
          e.mod.dispose?.();
        } catch (ex) {
          failures.push(`${id}.dispose: ${ex instanceof Error ? ex.message : String(ex)}`);
        }
        e.state = ModuleState.Disposed;
      }
    }
    this.started = false;
    if (failures.length > 0) {
      log.error(`释放时 ${failures.length} 项失败`, { failures });
      return err({
        code: "MODULE.DISPOSE_FAILED",
        message: `释放时有 ${failures.length} 项失败`,
        detail: { failures },
      });
    }
    return ok(undefined);
  }

  /** 诊断快照：编辑器与 healthz 用同一份（避免两套状态描述）。 */
  snapshot(): ReadonlyArray<{ id: string; state: ModuleStateValue; desc: string }> {
    return this.order.map((id) => {
      const e = this.entries.get(id)!;
      return {
        id,
        state: e.state,
        desc: e.mod.describe?.() ?? "",
      };
    });
  }

  private async rollback(failingId: string): Promise<void> {
    const idx = this.order.indexOf(failingId);
    const done = idx >= 0 ? this.order.slice(0, idx) : this.order.slice();
    for (const id of [...done].reverse()) {
      const e = this.entries.get(id)!;
      try {
        if (e.state === ModuleState.Started) e.mod.stop?.();
        if (e.state !== ModuleState.Created) e.mod.dispose?.();
      } catch {
        // 回滚失败不改写原始错误（原始错误才是根因）
      }
      e.state = ModuleState.Disposed;
    }
  }

  /** 把 `void | Result | Promise<...>` 归一成 `Promise<Result>`。 */
  private async withTimeout(
    p: ModuleHookResult,
    id: string,
    phase: string,
  ): Promise<Result<void, EngineError>> {
    const ms = this.opts.initTimeoutMs ?? 0;
    if (ms <= 0) {
      const v = await p;
      return v === undefined ? ok(undefined) : v;
    }
    let timer: ReturnType<typeof setTimeout> | undefined;
    const timeout = new Promise<Result<void, EngineError>>((resolve) => {
      timer = setTimeout(
        () =>
          resolve(
            err({
              code: "MODULE.TIMEOUT",
              message: `${id}.${phase} 超过 ${ms} ms`,
            }),
          ),
        ms,
      );
    });
    const normalized: Promise<Result<void, EngineError>> = Promise.resolve(p).then((v) =>
      v === undefined ? ok(undefined) : v,
    );
    try {
      return await Promise.race([normalized, timeout]);
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }
}
