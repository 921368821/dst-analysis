/**
 * L4 · 脚本模块（`script.lua`）
 *
 * 职责只有三件，且**都不碰内核**：
 *   ① 把平台提供的 `IScriptRuntime` 接上（null / 不能执行 ⇒ init 直接失败）；
 *   ② 暴露最小引擎 API（`engine_*`）给脚本；
 *   ③ 每 tick 遍历 `game.script` 组件，调用其 `entry` 函数。
 *
 * ★★ 为什么"没有脚本能力"必须让 init 失败，而不是跑起来每帧查一次：
 *   静默降级的表现是"脚本写对了、世界没变化" —— 这类 bug 在饥荒类游戏里
 *   表现为"这个生物不动了"，会被误判成 AI 问题。诚实的做法是在启动阶段
 *   就告诉宿主"这台机器没有脚本能力"，由宿主决定是换后端还是关掉该功能。
 *
 * ★★ 为什么结构性修改（spawn/destroy）走 `scene.spawn` / `scene.destroy`：
 *   它们**只入队**（ADR 0004：命令队列），真正的树修改在 `Scene.flush()`。
 *   脚本调用期间绝不直接改树，否则 `Scene.step` 正在遍历的组件数组会被改。
 *   没有直接用 `scene.enqueue(...)` 的原因很实际：`enqueue` 里的回调执行完才知道
 *   节点 id，而脚本需要**立刻**拿到 id 做后续调用；`scene.spawn` 同样是入队，
 *   但节点对象（带 id）在入队时就已创建，语义完全一致。
 *
 * ★ 性能：每帧不 `Array.from`。组件快照写进复用的 `work` 数组，
 *   只在长度变化时扩容；单帧 N 个脚本不产生 N 个临时数组。
 *   （拷贝而不是直接遍历 `componentsOf`，是为了防止将来某个引擎 API 在
 *    遍历中摘组件 —— 现在不会，但这条边界不该靠"现在不会"来守。）
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import { Services } from "../../core/tokens.ts";
import type { Scene } from "../../core/scene/scene.ts";
import {
  ScriptErrorCode,
  type HostFunction,
  type IScriptRuntime,
  type ScriptValue,
} from "../../platform/script/runtime.ts";
import { SCRIPT_COMPONENT_TYPE, ScriptComponent } from "./script-component.ts";

export interface ScriptModuleOptions {
  /** 模块 id。默认 `script.lua`（与 `render.batch2d` 同风格：域.实现）。 */
  readonly id?: string;
  /**
   * 单次脚本调用的时间预算（毫秒）。0 = 不限（默认）。
   * ★ 默认不限是刻意的：`debug.sethook` 每 N 条指令一次回调，
   *   对"每个实体每帧一次"的调用量是实打实的开销。生产宿主应显式给一个值。
   */
  readonly callTimeoutMs?: number;
}

export interface ScriptModuleHandle extends IModule {
  /** 当前运行的脚本运行时（init 成功后才非 null；即使 dispose 也不释放它 —— 归平台）。 */
  readonly runtime: IScriptRuntime | null;
  /** 收窄 `IModule` 的可选/宽松签名：本模块的 init 一定返回 Result，start/dispose 一定存在。 */
  init(ctx: ModuleContext): Promise<Result<void, EngineError>>;
  start(): void;
  dispose(): void;
  /** 供宿主/判据驱动一帧。返回值便于调用方 `await`，保证同一帧内脚本串行。 */
  update(tick: number, dt: number): Promise<void>;
  /**
   * 等到队列里所有已排队的脚本跑完（不含之后新入队的）。
   * ★ 同步 pump 的宿主（判据、回放、`for` 循环跑 N 帧）**必须**每帧调它：
   *   一次 `for` 里 pump 300 帧，队列会瞬间打满并开始丢 tick ——
   *   那是宿主没有让出事件循环，不是脚本慢。
   */
  drain(): Promise<void>;
  /** 因为脚本跟不上而丢弃的 tick 数（>0 说明脚本预算不够，必须可观测）。 */
  readonly droppedUpdates: number;
}

function numArg(v: ScriptValue | undefined, where: string): number {
  if (typeof v !== "number" || !Number.isFinite(v)) {
    throw new Error(`${where} 需要有限数（收到 ${typeof v}）`);
  }
  return v;
}

function strArg(v: ScriptValue | undefined, where: string): string {
  if (typeof v !== "string") throw new Error(`${where} 需要字符串（收到 ${typeof v}）`);
  return v;
}

function fmt(v: ScriptValue | undefined): string {
  if (typeof v === "string") return v;
  if (v === undefined) return "nil";
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

export function createScriptModule(opts: ScriptModuleOptions = {}): ScriptModuleHandle {
  let ctxRef: ModuleContext | null = null;
  let runtime: IScriptRuntime | null = null;
  let tick = 0;
  /** 复用的组件快照（见文件头"性能"）。 */
  const work: ScriptComponent[] = [];
  const timeoutMs = opts.callTimeoutMs ?? 0;

  /**
   * 串行队列。
   * ★★ 为什么必须有：宿主在 `scheduler.onStep`（**同步**回调）里驱动本模块，
   *   而 `rt.call` 是异步的 —— 不排队就会出现 tick N+1 在 tick N 的 Lua 调用
   *   返回之前进入同一个 state，两个 tick 交替改同一个全局变量。
   *   症状是"偶尔抖动 + 存档不可复现"（本阶段出口判据正是逐字节存档），
   *   而且极难归因（看起来像 Lua 的锅）。
   * ★ 上限与丢弃：脚本跟不上世界时**丢这个 tick 并记录**，与 `scheduler:steps-dropped`
   *   是同一处置。不设上限的后果是延迟无界累积 —— 玩家看到的是"操作越来越滞后"，
   *   比明确丢帧更难接受。
   */
  let queue: Promise<void> = Promise.resolve();
  let pending = 0;
  let droppedUpdates = 0;
  const MAX_PENDING_UPDATES = 4;

  function requireScene(): Scene {
    const scene = ctxRef?.services.get(Services.Scene);
    if (scene === undefined) {
      throw new Error("脚本模块需要 core.scene 服务（宿主没有接线）");
    }
    return scene;
  }

  function report(comp: ScriptComponent, fn: string, e: EngineError): void {
    ctxRef?.log.channel("script").error(`脚本 ${comp.module}.${fn} 失败：${e.message}`, {
      code: e.code,
      nodeId: comp.node?.id ?? 0,
    });
    // ★ 必须发事件：日志会被限流/丢弃，事件可以被编辑器、HUD、判据订阅。
    ctxRef?.events.emit("script:error", {
      module: comp.module,
      fn,
      code: e.code,
      message: e.message,
    });
  }

  /**
   * 暴露最小引擎 API。
   * ★ 参数/返回值只能是 `ScriptValue`：运行时会在跨界处校验；
   *   这里额外做**类型**检查（number vs string），因为"能序列化"不等于"是合法参数"。
   */
  function exposeEngineApi(rt: IScriptRuntime): Result<void, EngineError> {
    const fns: Array<[string, HostFunction]> = [
      [
        "engine_log",
        (msg) => {
          ctxRef?.log.channel("script").info(fmt(msg));
          return undefined;
        },
      ],
      [
        "engine_spawn",
        (name, x, z) => {
          const scene = requireScene();
          // 只入队（spawn 是命令），节点对象与 id 立刻可用，但树在 flush 时才变
          const r = scene.spawnAt(strArg(name, "engine_spawn(name)"), numArg(x, "engine_spawn(x)"), numArg(z, "engine_spawn(z)"));
          if (!r.ok) throw new Error(r.error.message);
          return r.value.id;
        },
      ],
      [
        "engine_destroy",
        (nodeId) => {
          requireScene().destroy(numArg(nodeId, "engine_destroy(nodeId)"));
          return undefined;
        },
      ],
      [
        "engine_count",
        (type) => requireScene().countOf(strArg(type, "engine_count(type)")),
      ],
      [
        "engine_get_pos",
        (nodeId) => {
          const node = requireScene().find(numArg(nodeId, "engine_get_pos(nodeId)"));
          // 不存在的节点返回 nil 而不是 {0,0}：后者会让脚本把"已销毁"当成"在原点"
          if (node === undefined) return null;
          const p = node.worldPosition;
          return { x: p.x, z: p.y };
        },
      ],
      [
        "engine_set_pos",
        (nodeId, x, z) => {
          const node = requireScene().find(numArg(nodeId, "engine_set_pos(nodeId)"));
          // 已销毁的节点：静默无操作会让脚本以为移动成功 —— 但抛错会让
          // "攻击一个刚被销毁的目标"这种正常竞态变成脚本崩溃。取后者：无操作。
          // 写的是**局部**位置（与物理层的 PositionAccessor 一致；当前可移动实体都是根节点直属子节点）
          if (node !== undefined) node.setLocalPosition(numArg(x, "engine_set_pos(x)"), numArg(z, "engine_set_pos(z)"));
          return undefined;
        },
      ],
      ["engine_tick", () => tick],
      [
        "engine_nodes_named",
        (name) => {
          const scene = requireScene();
          const want = strArg(name, "engine_nodes_named(name)");
          const ids: ScriptValue[] = [];
          const root = scene.find(scene.rootId);
          // 按 walk（深度优先、子节点顺序）收集：顺序**确定**，脚本可以依赖它
          root?.walk((n) => {
            if (n.name === want) ids.push(n.id);
          });
          return ids;
        },
      ],
      [
        "engine_set_scale",
        (nodeId, sx, sy) => {
          const node = requireScene().find(numArg(nodeId, "engine_set_scale(nodeId)"));
          if (node !== undefined) node.setLocalScale(numArg(sx, "engine_set_scale(sx)"), numArg(sy, "engine_set_scale(sy)"));
          return undefined;
        },
      ],
    ];

    for (const [name, fn] of fns) {
      const r = rt.expose(name, fn);
      if (!r.ok) return r;
    }
    return ok(undefined);
  }

  /**
   * 一帧的脚本调用（串行队列的执行体）。
   * ★ 抽成闭包函数而不是对象方法：`update()` 只负责排队，
   *   执行体需要访问 `queue/pending` 这些闭包状态，放在对象字面量里反而绕。
   */
  async function runUpdate(tickNow: number, dt: number): Promise<void> {
    const rt = runtime;
    if (rt === null) return;
    const scene = ctxRef?.services.get(Services.Scene);
    if (scene === undefined) return;
    tick = tickNow;

    const list = scene.componentsOf<ScriptComponent>(SCRIPT_COMPONENT_TYPE);
    work.length = 0;
    for (let i = 0; i < list.length; i++) work.push(list[i]!);

    const callOpts = timeoutMs > 0 ? { timeoutMs } : undefined;

    for (const c of work) {
      const node = c.node;
      if (!c.enabled || node === null || !node.activeInHierarchy) continue;
      const entry = c.entry === "" ? "onUpdate" : c.entry;
      // ★ 用 "<module>.<entry>" 而不是裸 entry：两个模块都定义 onUpdate 时，
      //   裸名字会解析到"最后加载的那个" —— 结果是两个组件跑同一段脚本。
      //   Lua 后端的解析器会先查 _G，再按最长模块名前缀查模块函数表。
      const target = c.module === "" ? entry : `${c.module}.${entry}`;

      try {
        const r = await rt.call(target, [node.id, dt, tickNow], callOpts);
        if (!r.ok) {
          // ★ 异常隔离：一个脚本挂不能让同帧其他脚本不执行，更不能让整帧崩
          report(c, entry, r.error);
        }
      } catch (e) {
        // runtime 契约说失败走 Result；走到这里是运行时自身坏了 —— 仍然隔离并上报
        report(
          c,
          entry,
          engineError(
            ScriptErrorCode.CallFailed,
            e instanceof Error ? e.message : String(e),
          ),
        );
      }
    }
  }

  const mod: ScriptModuleHandle = {
    id: opts.id ?? "script.lua",
    deps: [],

    async init(ctx: ModuleContext): Promise<Result<void, EngineError>> {
      ctxRef = ctx;

      if (!ctx.services.has(Services.Script)) {
        return err(
          engineError(
            ScriptErrorCode.NotSupported,
            "宿主没有提供 core.script 服务 —— 这是接线缺失，不是'平台没有脚本能力'（不静默运行）",
          ),
        );
      }
      const rt = ctx.services.get(Services.Script) ?? null;
      if (rt === null) {
        return err(
          engineError(
            ScriptErrorCode.NotSupported,
            "该平台没有脚本能力（Services.Script = null），不静默降级：脚本不会执行，宿主应关掉该功能",
          ),
        );
      }
      if (!rt.caps.executes) {
        return err(
          engineError(
            ScriptErrorCode.NotSupported,
            `脚本后端 ${rt.id} 不能执行（caps.executes=false），不静默降级`,
            { backend: rt.id },
          ),
        );
      }

      const ready = await rt.ready();
      if (!ready.ok) return err(ready.error);

      if (ctx.services.get(Services.Scene) === undefined) {
        return err(
          engineError("SCRIPT.NO_SCENE", "脚本模块需要 core.scene 服务：engine_* API 没有世界可操作"),
        );
      }

      const exposed = exposeEngineApi(rt);
      if (!exposed.ok) return exposed;

      runtime = rt;
      ctx.log.channel("script").info(
        `脚本模块就绪：后端 ${rt.id} ${rt.caps.version ?? ""} · 暴露 ${rt.exposed().length} 个宿主函数`,
      );
      return ok(undefined);
    },

    /**
     * 世界已建好：登记 `game.script` 组件类型。
     * ★ 只动组件注册表，不动节点树（init/start 的边界见 module.ts）。
     *   已有同名注册时跳过 —— 应用可能自己注册了子类/扩展 schema。
     */
    start(): void {
      const scene = ctxRef?.services.get(Services.Scene);
      if (scene !== undefined && !scene.components.has(SCRIPT_COMPONENT_TYPE)) {
        scene.components.register(new ScriptComponent().schema, () => new ScriptComponent());
      }
    },

    /**
     * 驱动一帧脚本。宿主在 `scheduler.onStep` 里 `void mod.update(tick, dt)` 即可。
     * 返回的 Promise 属于**整条队列**（不只是本次），所以 `await` 它等于
     * "等到此前排队的脚本全部跑完" —— 判据与需要严格同步的宿主用这个语义。
     */
    update(tickNow: number, dt: number): Promise<void> {
      if (runtime === null) return Promise.resolve();
      if (pending >= MAX_PENDING_UPDATES) {
        droppedUpdates++;
        ctxRef?.log.channel("script").warn(
          `脚本落后于世界：丢弃 tick ${tickNow} 的脚本更新（队列 ${pending}）—— ` +
            `与 scheduler 丢步同一处置，累计丢弃 ${droppedUpdates} 次`,
          { tick: tickNow, pending, dropped: droppedUpdates },
        );
        return queue;
      }
      pending++;
      const run = queue.then(() => runUpdate(tickNow, dt));
      // 两条回调都减计数：runUpdate 内部已隔离每个脚本，但它自身仍可能抛
      //（例如 scene 服务在 tick 中途被撤）。链不能因此断掉，否则后续 tick 全不执行。
      queue = run.then(
        () => {
          pending--;
        },
        () => {
          pending--;
        },
      );
      return queue;
    },

    stop(): void {
      // 没有订阅需要退订：本模块只被宿主显式驱动（update），不挂事件
    },

    /**
     * ★ 只清自己的状态。**不 dispose 运行时** ——
     *   它由平台持有（`Services.Script`），可能还有 AI/UI 模块在用。
     *   模块释放时把别人的服务关掉，是多模块架构里最典型的一类越权。
     */
    dispose(): void {
      runtime = null;
      ctxRef = null;
      work.length = 0;
      tick = 0;
    },

    drain(): Promise<void> {
      return queue;
    },

    describe(): string {
      const rt = runtime;
      if (rt === null) return "脚本：未启动";
      const s = rt.stats();
      const drop = droppedUpdates > 0 ? ` / 丢 ${droppedUpdates} tick` : "";
      return `脚本(${rt.id})：${s.modules} 模块 / ${s.calls} 调用 / ${s.errors} 错误（${s.timeouts} 超时）${drop}`;
    },

    get droppedUpdates(): number {
      return droppedUpdates;
    },
    get runtime(): IScriptRuntime | null {
      return runtime;
    },
  };

  return mod;
}
