/**
 * L2 · 服务 token 与引擎事件契约
 *
 * 集中放两个"跨模块契约"：
 *  ① 服务 token（谁能被注入）
 *  ② 事件表（谁在什么时候通知谁）
 *
 * ★ 为什么集中：
 *   事件与服务的名字一旦散落在各模块里，"有哪些事件"就没有答案了，
 *   新模块不知道能订阅什么，只能去翻代码 —— 这是"可扩展性"的真实成本。
 *   一张表 = 一份文档 + 一处静态检查。
 */

import { defineService } from "./module/services.ts";
import type { IFrameHost } from "./frame-host.ts";
import type { Scene } from "./scene/scene.ts";
import type { AssetDatabase } from "./asset/asset.ts";
import type { FixedStepScheduler } from "./scheduler/scheduler.ts";
import type { IScriptRuntime } from "../platform/script/runtime.ts";

// ------------------------------------------------------------------ 服务
export const Services = {
  /**
   * 帧宿主：提供 `onRender(fn)`。
   * ★ 为什么渲染不能靠"事件"：事件是"发生了什么，谁关心谁订阅"，
   *   而渲染是**每个宿主都必须执行的一个阶段**（哪怕没人订阅）。
   *   用事件的话，"没有任何渲染器订阅"与"渲染器都注销了"无法区分，
   *   画面会静默变黑。
   */
  Frame: defineService<IFrameHost>("core.frame"),
  Scene: defineService<Scene>("core.scene"),
  Assets: defineService<AssetDatabase>("core.assets"),
  Scheduler: defineService<FixedStepScheduler>("core.scheduler"),
  /**
   * 脚本运行时（可空）。
   * ★ 为什么作为服务而不是"模块私有字段"：UI/AI/关卡这些上层模块都要调脚本，
   *   如果各自 new 一个运行时，就会出现"两个 VM 两份全局状态"——
   *   脚本里的全局变量会莫名其妙地不共享。
   */
  Script: defineService<IScriptRuntime | null>("core.script"),
} as const;

// ------------------------------------------------------------------ 事件
/**
 * 引擎事件表。约定：
 *  - 载荷**只放不可变值或 id**，不放可变对象（见 EventBus 的注释）
 *  - 事件名用 `域:动作`（`scene:node-spawned`）
 *  - 结构性事件（增删/切换）在**命令 flush 之后**发，保证"订阅者看到的世界是稳定的"
 */
export interface EngineEvents extends Record<string, unknown> {
  /** 节点已创建并挂到父节点（flush 后）。 */
  "scene:node-spawned": { readonly nodeId: number; readonly parentId: number | null; readonly name: string };
  /** 节点已销毁（含子树；每个节点都发一次）。 */
  "scene:node-destroyed": { readonly nodeId: number; readonly name: string };
  /** 组件已挂载。 */
  "scene:component-attached": { readonly nodeId: number; readonly type: string };
  "scene:component-detached": { readonly nodeId: number; readonly type: string };
  /** 场景整体清空（切场景/读档前）。 */
  "scene:cleared": { readonly reason: string };

  /** 调度器丢步（卡顿被截断）。**必须有人订阅并记录**，否则静默丢时间。 */
  "scheduler:steps-dropped": { readonly dropped: number; readonly tick: number };
  /** 帧结束（渲染前）。诊断/埋点用。 */
  "frame:end": { readonly frame: number; readonly realDtMs: number; readonly steps: number };

  /** 资产加载完成 / 失败。 */
  "asset:loaded": { readonly id: string; readonly type: string };
  "asset:load-failed": { readonly id: string; readonly code: string; readonly message: string };

  /** 模块状态变化（编辑器与 healthz 用同一份）。 */
  "module:failed": { readonly id: string; readonly code: string; readonly message: string };

  /** 脚本模块加载成功（含热重载：同一 name 会再发一次）。 */
  "script:module-loaded": { readonly name: string; readonly bytes: number };
  /**
   * 脚本调用失败。**必须可观测**：脚本 `error()` 不该静默 ——
   * 饥荒类游戏里"某个行为脚本挂了"的表现是"这个生物不动了"，
   * 没有这条事件就只能靠肉眼发现。
   */
  "script:error": {
    readonly module: string;
    readonly fn: string;
    readonly code: string;
    readonly message: string;
  };
}
