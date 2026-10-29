/**
 * L3 · GameApp —— 组合根
 *
 * ★★ 全工程**唯一**允许知道"具体后端是谁"的地方。
 *    其他所有代码只面对接口（`IGraphicsDevice` / `IFileSystem` / …）。
 *    这条规则的可检验形式：`grep -r "webgl2\|webaudio\|node-fs" src/` 只应命中
 *    `src/backends/**` 与 `src/runtime/GameApp.ts`。
 *    （机器守护：`tests/arch/composition-root.test.ts`）
 *
 * 职责清单（就这四件，多一件都算越界）：
 *   ① 建平台（按请求挑后端）
 *   ② 建基础设施（logger / events / services / random）
 *   ③ 提供内核对象（scene / scheduler / assets），并登记成服务
 *   ④ 装配模块（交给 ModuleRegistry），提供 frame/start/stop
 * 它**不**实现：世界步进、渲染、输入路由、玩法。那些都是模块。
 *
 * ★ 为什么不用"引擎单例 + 静态初始化"：
 *   单例让"第二个实例"不可能 —— 而编辑器需要 PIE（编辑器世界 + 预览世界），
 *   判据需要并行跑多个世界。单例会在这两处同时爆炸。所以这里就是普通对象，
 *   谁 new 谁负责 dispose。
 */

import { ConsoleSink, Logger, LogLevel, MemorySink } from "../foundation/log/logger.ts";
import { SystemClock, type IClock } from "../foundation/time/clock.ts";
import { EventBus } from "../foundation/event/event-bus.ts";
import { DisposableBag } from "../foundation/memory/disposable.ts";
import { XorShift128, type IRandom } from "../foundation/random.ts";
import { engineError, err, ok, type EngineError, type Result } from "../foundation/result.ts";
import { BackendRegistry } from "../platform/registry.ts";
import { createPlatform, type IPlatform, type PlatformRequest } from "../platform/platform.ts";
import type { IFileSystem } from "../platform/fs/fs.ts";
import { ModuleRegistry, type IModule, type ModuleContext } from "../core/module/module.ts";
import { ServiceRegistry } from "../core/module/services.ts";
import { ComponentRegistry } from "../core/scene/component.ts";
import { Scene } from "../core/scene/scene.ts";
import { FixedStepScheduler } from "../core/scheduler/scheduler.ts";
import { AssetDatabase } from "../core/asset/asset.ts";
import { Services, type EngineEvents } from "../core/tokens.ts";
import type { FrameInfo, IFrameHost, RenderFn } from "../core/frame-host.ts";
import { ManualTickSource, type ITickSource } from "./tick-source.ts";

export interface GameAppOptions {
  /** 平台标识（`web` / `headless` / `editor`）。 */
  readonly platformId: string;
  readonly interactive: boolean;
  /** 已注册好后端的注册表（由宿主/引导脚本填）。 */
  readonly registry: BackendRegistry;
  readonly modules: readonly IModule[];
  readonly fixedDt?: number;
  readonly maxStepsPerFrame?: number;
  /** 世界种子。**所有随机流都从它派生**。 */
  readonly seed: number;
  readonly logLevel?: (typeof LogLevel)[keyof typeof LogLevel];
  /** 额外的日志 sink（判据用 MemorySink 读日志）。 */
  readonly extraSinks?: readonly import("../foundation/log/logger.ts").LogSink[];
  /** 手动帧源（判据）。不传则用调用方提供的 tickSource 或外部驱动。 */
  readonly tickSource?: ITickSource;
  readonly prefer?: PlatformRequest["prefer"];
  readonly allow?: PlatformRequest["allow"];
  readonly backendOptions?: PlatformRequest["backendOptions"];
  /**
   * 点名"这几样不许回落到 null"（见 `PlatformRequest.strict`）。
   *
   * ★★ 这个字段是**补上了漏传**，不是新功能：`host/wx-entry.ts` 从批128 起就给了
   *   `strict: ["gfx", "input", "fs"]`，而 `GameAppOptions` 里没有它 —— 装配那边是
   *   靠 `...(env.platform ?? {})` 展开进来的，而**对象展开不做多余属性检查**，
   *   于是它被静默丢掉，平台一次都没收到过。症状正是"说了不留半个宿主，
   *   实则照样悄悄退回 null 后端"，而所有判据都绿（判据验的是各子系统，
   *   验不到"这个参数到没到"）。
   *   ⇒ 由 `tests/host/wx-entry.test.ts` 的 no-GL 那条钉住：没有 GL 时必须**启动失败**。
   */
  readonly strict?: PlatformRequest["strict"];
  /** 强制文件系统（编辑器/判据注入内存盘）。 */
  readonly fs?: IFileSystem;
  /** 注入时钟（判据用 ManualClock 拨表）。缺省用系统高精度时钟。 */
  readonly clock?: IClock;
}

export interface AppSnapshot {
  readonly platformId: string;
  readonly backends: IPlatform["backends"];
  readonly tick: number;
  readonly time: number;
  readonly paused: boolean;
  readonly timeScale: number;
  /** hitstop 冻结中（批73）。与 `paused` 独立：玩家暂停时也可以处于冻结。 */
  readonly frozen: boolean;
  /** 剩余冻结步数（诊断/自检读它，避免直接摸调度器）。 */
  readonly freezeTicks: number;
  /** 累计消耗的冻结步数（诊断："这一场打了多久的顿帧"）。 */
  readonly totalFreezeTicks: number;
  readonly droppedSteps: number;
  readonly scene: ReturnType<Scene["stats"]>;
  readonly assets: ReturnType<AssetDatabase["stats"]>;
  readonly modules: ReturnType<ModuleRegistry["snapshot"]>;
  readonly eventStats: ReturnType<EventBus<EngineEvents>["stats"]>;
}

export class GameApp {
  readonly platform: IPlatform;
  readonly log: Logger;
  readonly memorySink: MemorySink;
  readonly events = new EventBus<EngineEvents>();
  readonly services = new ServiceRegistry();
  readonly components = new ComponentRegistry();
  readonly scene: Scene;
  readonly scheduler: FixedStepScheduler;
  readonly assets: AssetDatabase;
  readonly modules: ModuleRegistry;
  readonly random: IRandom;
  readonly tickSource: ITickSource | null;
  /** 渲染阶段回调（`onRender` 注册）。按注册顺序执行。 */
  private readonly renderers: RenderFn[] = [];

  private readonly bag = new DisposableBag();
  private frameCount = 0;
  private running = false;
  private disposed = false;

  private constructor(opts: GameAppOptions, platform: IPlatform, log: Logger, memorySink: MemorySink, fs: IFileSystem) {
    this.platform = platform;
    this.log = log;
    this.memorySink = memorySink;
    this.tickSource = opts.tickSource ?? null;

    this.random = new XorShift128(opts.seed);
    this.scheduler = new FixedStepScheduler({
      fixedDt: opts.fixedDt ?? 1 / 30,
      maxStepsPerFrame: opts.maxStepsPerFrame ?? 5,
    });
    this.scene = new Scene("main", this.components);
    this.assets = new AssetDatabase(fs, log.channel("asset"));

    // ★ getter 里闭包**局部变量**而不是 `this`：对象字面量里的 `this` 不是 GameApp，
    //   写 `this.renderers` 会拿到 undefined。类型检查会先发现（rendererCount 缺失），
    //   但即便绕过类型也可能静默错 —— 所以直接闭包局部数组。
    const renderers = this.renderers;
    const frameHost: IFrameHost = {
      onRender: (fn: RenderFn) => {
        renderers.push(fn);
        return () => {
          const i = renderers.indexOf(fn);
          if (i >= 0) renderers.splice(i, 1);
        };
      },
      get rendererCount(): number {
        return renderers.length;
      },
    };
    this.services.provide(Services.Frame, frameHost, "core");
    this.services.provide(Services.Scene, this.scene, "core");
    this.services.provide(Services.Scheduler, this.scheduler, "core");
    this.services.provide(Services.Assets, this.assets, "core");
    // 脚本运行时可能不存在（headless / 纯表现宿主）。**显式提供 null**，
    // 而不是"不提供"：两者对上层可区分（has() 为真但值是 null = 平台没有脚本能力；
    // 完全没提供 = 宿主忘了接线）。前者可以给出"这个平台不支持脚本"的准确诊断。
    this.services.provide(Services.Script, platform.script, "core");

    // 丢步必须被记录：这是"卡顿"唯一可见的症状
    this.events.on("scheduler:steps-dropped", (p) => {
      log.channel("core.scheduler").warn(
        `帧预算不足，丢弃了 ${p.dropped} 个逻辑步（tick=${p.tick}）—— 世界时间落后于真实时间`,
        { dropped: p.dropped, tick: p.tick },
      );
    });

    const ctx: ModuleContext = {
      log,
      events: this.events as unknown as EventBus<Record<string, unknown>>,
      services: this.services,
      platform,
      random: this.random,
      module: <T extends IModule>(id: string) => this.modules.get<T>(id),
    };
    this.modules = new ModuleRegistry(ctx);
    for (const m of opts.modules) {
      const r = this.modules.register(m);
      if (!r.ok) {
        // 注册期失败说明宿主配置错了（重复 id），直接抛：这不是运行时状况
        throw new Error(`模块注册失败：${r.error.message}`);
      }
    }

    this.bag.add("platform", { dispose: () => platform.dispose() });
    this.bag.add("services", this.services);
    this.bag.add("logsink", { dispose: () => this.log.flush() });
  }

  static create(opts: GameAppOptions): Result<GameApp, EngineError> {
    const memorySink = new MemorySink(4000);
    // ★ 时钟是**注入**的：内核层不许出现 Date.now()（arch 规则 3 会红）。
    //   这也是判据能"拨表"跑长流程的前提。
    const clock = opts.clock ?? new SystemClock();
    const log = new Logger(() => clock.now());
    log.addSink(new ConsoleSink(opts.logLevel ?? LogLevel.Info));
    log.addSink(memorySink);
    for (const s of opts.extraSinks ?? []) log.addSink(s);

    const platformR = createPlatform({
      id: opts.platformId,
      interactive: opts.interactive,
      registry: opts.registry,
      clock,
      ...(opts.prefer === undefined ? {} : { prefer: opts.prefer }),
      ...(opts.allow === undefined ? {} : { allow: opts.allow }),
      ...(opts.backendOptions === undefined ? {} : { backendOptions: opts.backendOptions }),
      ...(opts.strict === undefined ? {} : { strict: opts.strict }),
    });
    if (!platformR.ok) {
      log.channel("app").error(`平台创建失败：${platformR.error.message}`, {
        code: platformR.error.code,
        detail: platformR.error.detail,
      });
      return platformR as Result<GameApp, EngineError>;
    }
    const platform = platformR.value;
    const fs = opts.fs ?? platform.fs;

    log.channel("app").info(
      `平台就绪：${platform.id} gfx=${platform.backends.gfx} audio=${platform.backends.audio} ` +
        `input=${platform.backends.input} fs=${platform.backends.fs} script=${platform.backends.script ?? "(无)"}`,
      { caps: platform.caps },
    );

    try {
      return ok(new GameApp(opts, platform, log, memorySink, fs));
    } catch (e) {
      platform.dispose();
      return err(
        engineError("APP.CREATE_FAILED", `GameApp 构造失败：${e instanceof Error ? e.message : String(e)}`),
      );
    }
  }

  /** 启动全部模块（拓扑序）。失败时模块已自行回滚。 */
  async start(): Promise<Result<void, EngineError>> {
    if (this.running) return err(engineError("APP.ALREADY_RUNNING", "已经在运行"));
    const r = await this.modules.start();
    if (!r.ok) {
      this.events.emit("module:failed", { id: String(r.error.detail?.["moduleId"] ?? "?"), code: r.error.code, message: r.error.message });
      return r;
    }
    this.running = true;
    return ok(undefined);
  }

  /**
   * 推进一帧。`realDtSec` 是真实经过时间。
   * ★ 这是**唯一**的帧入口：外部（rAF / interval / 判据）都只能通过它驱动，
   *   否则"有两条帧路径"就必然有一条被忘记维护。
   */
  frame(realDtSec: number): void {
    if (this.disposed) return;
    const before = this.scheduler.stats().droppedSteps;
    const steps = this.scheduler.advance(realDtSec);
    const after = this.scheduler.stats();
    if (after.droppedSteps > before) {
      this.events.emit("scheduler:steps-dropped", {
        dropped: after.droppedSteps - before,
        tick: after.tick,
      });
    }
    this.frameCount++;

    // ---- 渲染阶段（每帧一次，与 step 次数无关；用 alpha 做插值）
    const info: FrameInfo = {
      frame: this.frameCount,
      realDtSec,
      steps,
      alpha: this.scheduler.alpha,
      tick: this.scheduler.tick,
    };
    for (const fn of this.renderers) {
      try {
        fn(info);
      } catch (e) {
        // 渲染异常不能让整帧崩（否则一次采样失败会连锁成黑屏），但必须可见
        this.log.channel("app.render").error(
          `渲染回调抛错：${e instanceof Error ? e.message : String(e)}`,
          { frame: this.frameCount },
          null,
        );
      }
    }

    this.events.emit("frame:end", {
      frame: this.frameCount,
      realDtMs: realDtSec * 1000,
      steps,
    });
  }

  /** 用 tickSource 自动驱动。没有 tickSource 时返回错误（不静默不动）。 */
  run(): Result<void, EngineError> {
    if (this.tickSource === null) {
      return err(
        engineError("APP.NO_TICK_SOURCE", "没有 tickSource —— 用 frame(dt) 手动驱动，或在 create 时传 tickSource"),
      );
    }
    if (this.tickSource.running) return ok(undefined);
    this.tickSource.start((dt) => this.frame(dt));
    return ok(undefined);
  }

  stopRun(): void {
    this.tickSource?.stop();
  }

  set paused(v: boolean) {
    this.scheduler.paused = v;
  }
  get paused(): boolean {
    return this.scheduler.paused;
  }

  set timeScale(v: number) {
    this.scheduler.timeScale = v;
  }

  get frameIndex(): number {
    return this.frameCount;
  }

  /** 诊断快照：`/healthz`、编辑器状态栏、判据都读这一份（避免三套描述）。 */
  snapshot(): AppSnapshot {
    return {
      platformId: this.platform.id,
      backends: this.platform.backends,
      tick: this.scheduler.tick,
      time: this.scheduler.time,
      paused: this.scheduler.paused,
      timeScale: this.scheduler.timeScale,
      frozen: this.scheduler.frozen,
      freezeTicks: this.scheduler.freezeTicks,
      totalFreezeTicks: this.scheduler.stats().totalFreezeTicks,
      droppedSteps: this.scheduler.stats().droppedSteps,
      scene: this.scene.stats(),
      assets: this.assets.stats(),
      modules: this.modules.snapshot(),
      eventStats: this.events.stats(),
    };
  }

  /** 停止模块并释放。幂等。 */
  async dispose(): Promise<void> {
    if (this.disposed) return;
    this.disposed = true;
    this.stopRun();
    const r = await this.modules.dispose();
    if (!r.ok) this.log.channel("app").error(`模块释放失败：${r.error.message}`);
    try {
      this.bag.dispose();
    } catch (e) {
      this.log.channel("app").error(`资源释放失败：${e instanceof Error ? e.message : String(e)}`);
    }
    this.events.clear();
  }
}

/** 便捷：建 + 启动。失败时已自动释放。 */
export async function bootGameApp(
  opts: GameAppOptions,
): Promise<Result<GameApp, EngineError>> {
  const appR = GameApp.create(opts);
  if (!appR.ok) return appR;
  const app = appR.value;
  const startR = await app.start();
  if (!startR.ok) {
    await app.dispose();
    return startR as Result<GameApp, EngineError>;
  }
  return ok(app);
}

export { ManualTickSource };
