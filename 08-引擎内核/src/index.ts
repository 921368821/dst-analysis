/**
 * 引擎公共入口
 *
 * ★ 这个文件的导出列表就是**对外 API 面**（"引擎的产品边界"）。
 *   规则：只导出接口、类型、值对象、工厂；**不导出内部实现细节**。
 *   判断标准：如果一个东西改起来会让外部代码编译失败，它就不该出现在这里 ——
 *   除非那条改动本身就该是破坏性变更（例如接口新增方法）。
 *
 * 分两层导出，便于调用方表达意图：
 *   `@engine/core`    —— 只写游戏/工具，不碰平台（可跑在任何宿主）
 *   `@engine/runtime` —— 组合根与帧源（宿主用）
 */

// ---- L0 基础设施
export * from "./foundation/result.ts";
export * from "./foundation/math/index.ts";
export * from "./foundation/log/logger.ts";
export * from "./foundation/event/event-bus.ts";
export * from "./foundation/memory/disposable.ts";
export * from "./foundation/time/clock.ts";
export * from "./foundation/random.ts";

// ---- L1 平台接口（只有接口与描述符，没有实现）
export * from "./platform/gfx/types.ts";
export type {
  IGraphicsDevice,
  ICommandList,
  GraphicsBackendFactory,
} from "./platform/gfx/device.ts";
export type {
  IAudioDevice,
  AudioBackendFactory,
  AudioBus,
  PlayOptions,
  VoiceState,
} from "./platform/audio/device.ts";
export type { IInputDevice, InputBackendFactory, InputSnapshot, RawInputEvent } from "./platform/input/device.ts";
export type {
  IFileSystem,
  FsBackendFactory,
  NetBackendFactory,
  ITransport,
  FileEntry,
  FileStat,
  TransportMessage,
} from "./platform/fs/fs.ts";
export { BackendKind, BackendRegistry } from "./platform/registry.ts";
export type { CreateOptions } from "./platform/registry.ts";
export { createPlatform } from "./platform/platform.ts";
export type { IPlatform, PlatformCaps, PlatformRequest } from "./platform/platform.ts";

// ---- L2 引擎内核
export { ModuleRegistry, ModuleState } from "./core/module/module.ts";
export type { IModule, ModuleContext, ModuleStateValue } from "./core/module/module.ts";
export { defineService, ServiceRegistry } from "./core/module/services.ts";
export type { ServiceToken } from "./core/module/services.ts";
export { Services } from "./core/tokens.ts";
export type { EngineEvents } from "./core/tokens.ts";
export { Component, ComponentRegistry, FieldType, zeroValue } from "./core/scene/component.ts";
export type { ComponentSchema, FieldTypeValue } from "./core/scene/component.ts";
export { Node, __resetNodeIdsForTest } from "./core/scene/node.ts";
export type { NodeId } from "./core/scene/node.ts";
export { Scene } from "./core/scene/scene.ts";
export type { SceneCommand, SceneStats } from "./core/scene/scene.ts";
export { FixedStepScheduler } from "./core/scheduler/scheduler.ts";
export type { SchedulerConfig, SchedulerStats, StepFn } from "./core/scheduler/scheduler.ts";
export {
  AssetDatabase,
  AssetHandle,
  AssetType,
  newAssetId,
  stableIdFromPath,
} from "./core/asset/asset.ts";
export type { AssetId, AssetMeta, IAsset, IAssetLoader, AssetLoadContext, AssetDatabaseStats } from "./core/asset/asset.ts";
export { Schema, stableHash } from "./core/serialization/schema.ts";
export type { Migration, SchemaOptions } from "./core/serialization/schema.ts";

// ---- L3 运行时
export { GameApp, bootGameApp } from "./runtime/GameApp.ts";
export type { GameAppOptions, AppSnapshot } from "./runtime/GameApp.ts";
export { ManualTickSource, RafTickSource, IntervalTickSource } from "./runtime/tick-source.ts";
export type { ITickSource } from "./runtime/tick-source.ts";

// ---- L5 null 后端（判据/headless 的标准配置）
export {
  registerNullBackends,
  NullGraphicsDevice,
  NullAudioDevice,
  NullInputDevice,
  MemoryFileSystem,
} from "./backends/index.ts";
