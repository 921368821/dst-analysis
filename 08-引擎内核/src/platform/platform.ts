/**
 * L1 · 平台聚合
 *
 * `IPlatform` 是"当前跑在什么环境上"的**唯一答案**。它只做三件事：
 *   ① 暴露本平台实际使用的后端 id（可观测：日志/诊断/判据要能打印出来）；
 *   ② 暴露能力（caps），上层据此降级；
 *   ③ 统一释放（逆序：先 gfx，最后 fs —— 因为释放过程可能要写日志/存档）。
 *
 * ★ 它**不**提供"服务定位器"式的 `platform.get('anything')`。
 *   那种写法看起来灵活，实际上把"这个模块依赖什么"变成了运行时才知道的事，
 *   静态分析和依赖图全部失效。依赖必须显式出现在构造参数里（见 core/module）。
 */

import type { IClock } from "../foundation/time/clock.ts";
import { SystemClock } from "../foundation/time/clock.ts";
import type { EngineError, Result } from "../foundation/result.ts";
import type { IGraphicsDevice } from "./gfx/device.ts";
import type { IAudioDevice } from "./audio/device.ts";
import type { IInputDevice } from "./input/device.ts";
import type { IFileSystem, ITransport } from "./fs/fs.ts";
import type { IScriptRuntime } from "./script/runtime.ts";
import type { BackendRegistry } from "./registry.ts";

export interface PlatformCaps {
  readonly id: string;
  /** 是否是"能渲染给真人看"的环境（headless 为 false）。 */
  readonly interactive: boolean;
  readonly hasGpu: boolean;
  readonly hasAudio: boolean;
  readonly hasDom: boolean;
  readonly maxTextureSize: number;
}

export interface IPlatform {
  readonly id: string;
  readonly caps: PlatformCaps;
  readonly gfx: IGraphicsDevice;
  readonly audio: IAudioDevice;
  readonly input: IInputDevice;
  readonly fs: IFileSystem;
  readonly net: ITransport | null;
  /**
   * 脚本运行时。**可空**：没有脚本层的宿主（纯表现/纯判据）完全正常。
   * ★ 空不等于"脚本默默不执行"——`ScriptModule` 在拿不到 runtime 时必须报错，
   *   否则"脚本没跑"会变成最难查的一类 bug（世界不动但不报错）。
   */
  readonly script: IScriptRuntime | null;
  readonly clock: IClock;
  /** 实际选中的后端 id —— 打印出来就能回答"到底跑在什么上"。 */
  readonly backends: {
    readonly gfx: string;
    readonly audio: string;
    readonly input: string;
    readonly fs: string;
    readonly net: string | null;
    readonly script: string | null;
  };
  dispose(): void;
}

export interface PlatformRequest {
  readonly id: string;
  readonly interactive: boolean;
  readonly registry: BackendRegistry;
  readonly clock?: IClock;
  readonly backendOptions?: {
    readonly gfx?: unknown;
    readonly audio?: unknown;
    readonly input?: unknown;
    readonly fs?: unknown;
    readonly net?: unknown;
    readonly script?: unknown;
  };
  /** 强制使用某些后端（判据/headless）。 */
  readonly prefer?: {
    readonly gfx?: string;
    readonly audio?: string;
    readonly input?: string;
    readonly fs?: string;
    readonly net?: string;
    readonly script?: string;
  };
  /** 允许的后端白名单（例如"这个构建只带 null 后端"）。 */
  readonly allow?: {
    readonly gfx?: readonly string[];
    readonly audio?: readonly string[];
    readonly input?: readonly string[];
    readonly fs?: readonly string[];
    readonly net?: readonly string[];
    readonly script?: readonly string[];
  };
  /**
   * 这些子系统**不许**回落到 null（起不来就整体失败）。
   *
   * ★ 为什么需要它：`prefer` 只是"优先试这个"，试不成会继续往下挑 ——
   *   对浏览器宿主这是对的（WebGL2 不可用就退回 null 画个空画面，至少页面还在）。
   *   但小游戏宿主上，输入/存档退回 null 等于**半个宿主**：游戏起得来、
   *   帧也在跑，而"按不动"与"存不了"要在五个方向里各查一遍才知道是哪个掉的。
   *   这类宿主应当把 `input` / `fs` 列进来，让失败停在启动那一刻并带上原因。
   *
   * ★ 默认（不传）= 与之前逐字节一致：允许回落。判据 `input-injected` 同时钉了两侧。
   */
  readonly strict?: readonly StrictBackendKind[];
}

export type StrictBackendKind = "gfx" | "audio" | "input" | "fs" | "net" | "script";

/**
 * 按注册表创建平台。**失败是聚合的**：四个子系统里任何一个起不来，
 * 错误里会带上每一个的失败原因（便于一次看清，而不是改一个跑一次）。
 */
export function createPlatform(req: PlatformRequest): Result<IPlatform, EngineError> {
  const { registry } = req;
  const clock = req.clock ?? new SystemClock();
  /** `strict` 里点名的子系统不许回落到 null（注册表早已支持，这里只是把它透传下去）。 */
  const noNull = (kind: StrictBackendKind): { allowFallbackToNull?: false } =>
    req.strict?.includes(kind) === true ? { allowFallbackToNull: false } : {};

  const gfxR = registry.create("gfx", {
    ...(req.prefer?.gfx === undefined ? {} : { prefer: req.prefer.gfx }),
    ...(req.allow?.gfx === undefined ? {} : { allow: req.allow.gfx }),
    ...noNull("gfx"),
    options: req.backendOptions?.gfx,
  });
  if (!gfxR.ok) return gfxR as Result<IPlatform, EngineError>;

  const audioR = registry.create("audio", {
    ...(req.prefer?.audio === undefined ? {} : { prefer: req.prefer.audio }),
    ...(req.allow?.audio === undefined ? {} : { allow: req.allow.audio }),
    ...noNull("audio"),
    options: req.backendOptions?.audio,
  });
  if (!audioR.ok) {
    gfxR.value.destroy();
    return audioR as Result<IPlatform, EngineError>;
  }

  const inputR = registry.create("input", {
    ...(req.prefer?.input === undefined ? {} : { prefer: req.prefer.input }),
    ...(req.allow?.input === undefined ? {} : { allow: req.allow.input }),
    ...noNull("input"),
    options: req.backendOptions?.input,
  });
  if (!inputR.ok) {
    audioR.value.destroy();
    gfxR.value.destroy();
    return inputR as Result<IPlatform, EngineError>;
  }

  const fsR = registry.create("fs", {
    ...(req.prefer?.fs === undefined ? {} : { prefer: req.prefer.fs }),
    ...(req.allow?.fs === undefined ? {} : { allow: req.allow.fs }),
    ...noNull("fs"),
    options: req.backendOptions?.fs,
  });
  if (!fsR.ok) {
    inputR.value.destroy();
    audioR.value.destroy();
    gfxR.value.destroy();
    return fsR as Result<IPlatform, EngineError>;
  }

  // 网络是**可选**的：单机游戏没有传输层也完全正常，不该因此起不来。
  let net: ITransport | null = null;
  let netId: string | null = null;
  if (registry.list("net").length > 0) {
    const netR = registry.create("net", {
      ...(req.prefer?.net === undefined ? {} : { prefer: req.prefer.net }),
      ...(req.allow?.net === undefined ? {} : { allow: req.allow.net }),
      ...noNull("net"),
      options: req.backendOptions?.net,
    });
    if (netR.ok) {
      net = netR.value;
      netId = req.prefer?.net ?? "auto";
    }
  }

  // 脚本也是**可选**的：判据/纯表现宿主没有脚本层也该能起。
  // ★ 但"用户显式 prefer 了 script 却起不来"必须报错 —— 静默降级成 null
  //   会让"脚本没跑"看起来像"脚本跑了但没效果"。（判据 D-S2 守这条）
  let script: IScriptRuntime | null = null;
  let scriptId: string | null = null;
  if (registry.list("script").length > 0) {
    const scriptR = registry.create("script", {
      ...(req.prefer?.script === undefined ? {} : { prefer: req.prefer.script }),
      ...(req.allow?.script === undefined ? {} : { allow: req.allow.script }),
      ...noNull("script"),
      options: req.backendOptions?.script,
    });
    if (scriptR.ok) {
      script = scriptR.value;
      scriptId = scriptR.value.id;
    } else if (req.prefer?.script !== undefined) {
      inputR.value.destroy();
      audioR.value.destroy();
      gfxR.value.destroy();
      return scriptR as Result<IPlatform, EngineError>;
    }
  }

  const size = gfxR.value.size;
  const caps: PlatformCaps = {
    id: req.id,
    interactive: req.interactive,
    hasGpu: gfxR.value.caps.backend !== "null",
    hasAudio: audioR.value.caps.backend !== "null",
    hasDom: typeof (globalThis as { document?: unknown }).document !== "undefined",
    maxTextureSize: gfxR.value.caps.maxTextureSize,
  };

  return {
    ok: true,
    value: {
      id: req.id,
      caps,
      gfx: gfxR.value,
      audio: audioR.value,
      input: inputR.value,
      fs: fsR.value,
      net,
      script,
      clock,
      backends: {
        gfx: gfxR.value.caps.backend,
        audio: audioR.value.caps.backend,
        input: inputR.value.caps.backend,
        fs: fsR.value.scheme,
        net: netId,
        script: scriptId,
      },
      dispose(): void {
        // 逆序：脚本先停（它可能在 update 里写存档），再停表现层，最后停存储
        // （释放过程可能要记日志）。fs 没有 close —— 接口上它无可释放资源。
        script?.dispose();
        net?.close(1000, "platform dispose");
        inputR.value.destroy();
        audioR.value.destroy();
        gfxR.value.destroy();
        void size; // 保留引用，避免被当成无用代码（size 用于诊断快照）
      },
    },
  };
}
