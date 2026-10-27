/**
 * 引擎公共入口
 *
 * ★ 这个文件的导出列表就是**对外 API 面**（"引擎的产品边界"）。
 *   规则：只导出接口、类型、值对象、工厂；**不导出内部实现细节**。
 *   判断标准：如果一个东西改起来会让外部代码编译失败，它就不该出现在这里 ——
 *   除非那条改动本身就该是破坏性变更（例如接口新增方法）。
 *
 * ★★ 边界的**现状**（2026-10-23 批48 把这句话改成实话）：
 *   这里覆盖的是 **L0–L3（内核）+ 脚本 + 资产导入**。
 *   **L4 的 render / physics / worldgen / ai / build 不在里面** —— 这不是遗漏，
 *   而是"还没有逐个审过哪些是接口、哪些是实现"。它们现在只能按相对路径深导入
 *   （本项目没有 `exports` 映射，所以深导入是可用的）。
 *   在把 L4 收进来之前，任何"本文件 = 全部 API"的说法都不成立；
 *   收进来的前提是对每个模块逐条标注"这行是给人调的"还是"这行是内部零件"。
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
export type {
  IScriptRuntime,
  ScriptBackendFactory,
  ScriptCaps,
  ScriptValue,
  ScriptPrimitive,
  ScriptCallOptions,
  ScriptRuntimeStats,
  HostFunction,
} from "./platform/script/runtime.ts";
export { ScriptErrorCode, assertScriptValue } from "./platform/script/runtime.ts";

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
  NullScriptRuntime,
} from "./backends/index.ts";

// ---- L4 扩展：脚本（不含 Lua 实现 —— 见下）
export { ScriptComponent, SCRIPT_COMPONENT_TYPE } from "./extensions/script/script-component.ts";
export { createScriptModule } from "./extensions/script/script-module.ts";
export type { ScriptModuleHandle, ScriptModuleOptions } from "./extensions/script/script-module.ts";

// ---- L4 扩展：资产导入
export { ImporterRegistry } from "./extensions/asset-import/importer.ts";
export type { SourceImporter, ImportedArtifact, ImportContext } from "./extensions/asset-import/importer.ts";
export { AssetImportPipeline, normalizePath, resolveSiblingPath } from "./extensions/asset-import/pipeline.ts";
export type { ImportReport, ImportFailure } from "./extensions/asset-import/pipeline.ts";
export {
  createImportLoaders,
  ImportedTexture,
  ImportedAtlas,
  ImportedText,
} from "./extensions/asset-import/loaders.ts";
export { textureImporter } from "./extensions/asset-import/importers/texture.ts";
export { atlasImporter } from "./extensions/asset-import/importers/atlas.ts";
export { textImporter } from "./extensions/asset-import/importers/text.ts";

// ★ **不导出** `backends/script-lua`：它会把 wasmoon（~240KB + wasm）拖进任何
//   import 了公共入口的构建，包括完全不需要脚本的纯渲染宿主。
//   需要 Lua 的宿主请显式 `import { createLuaScriptBackend } from "@engine/backends/script-lua"`。
//   这是"公共 API 面不为少数使用者的便利付费"的具体一条。

// ---- L4 扩展：UI（位图字体 + 布局 + 控件 + 事件）
export { parseBmFont, glyphOf, kerningOf, kerningKey, FontRegistry, FONT_ERR } from "./extensions/ui/font.ts";
export type { BitmapFont, FontGlyph, FontPage } from "./extensions/ui/font.ts";
export { layoutText } from "./extensions/ui/text-layout.ts";
export type { TextLayout, TextQuad, TextStyle, TextAlign } from "./extensions/ui/text-layout.ts";
export { UiViewport, UiScaleMode, ZERO_INSETS } from "./extensions/ui/viewport.ts";
export type { UiViewportConfig, Insets, UiScaleModeValue } from "./extensions/ui/viewport.ts";
export {
  UiNode,
  UiLayoutKind,
  UiWidget,
  buildUiTree,
  layoutTree,
  hitTest,
  hitChain,
  ANCHOR_TOP_LEFT,
  ANCHOR_TOP_CENTER,
  ANCHOR_CENTER,
  ANCHOR_BOTTOM_LEFT,
  ANCHOR_BOTTOM_CENTER,
} from "./extensions/ui/layout.ts";
export type { UiNodeConfig, UiPoint, UiProps, UiPadding, UiLayoutResult, UiWidgetValue, UiLayoutKindValue, LayoutOptions } from "./extensions/ui/layout.ts";
export { buildUiQuads, nineSlice, UI_LAYER } from "./extensions/ui/widgets.ts";
export { UiStateStore } from "./extensions/ui/state.ts";
export type { UiStateStats } from "./extensions/ui/state.ts";
export { createIntrinsicMeasure, defaultFontId, textBoxOf, textStyleFor, textInsetOf, BUTTON_TEXT_INSET } from "./extensions/ui/intrinsic.ts";
export type { IntrinsicMeasure } from "./extensions/ui/intrinsic.ts";
export type { UiSkin, UiSkinFrame, UiDrawStats, UiDrawResult, Rgba } from "./extensions/ui/widgets.ts";
export { UiInputRouter, UiEvent, bubble } from "./extensions/ui/events.ts";
export type { UiPointer, UiEventType, UiEventSink, UiInputRouterOptions } from "./extensions/ui/events.ts";
export { createUiModule, rectOf, RENDER_MODULE_ID } from "./extensions/ui/ui-module.ts";
export type { UiModuleHandle, UiModuleOptions, UiFrameStats } from "./extensions/ui/ui-module.ts";
// 批76：UI 过渡的应用侧（补间采样 → UiNode 字段 + 值域收口）
export { UI_TWEEN_PROP, applyUiTween, applyUiSamples, isUiTweenProp } from "./extensions/ui/ui-transition.ts";
export type { UiTweenProp, UiTransitionResult } from "./extensions/ui/ui-transition.ts";

// ---- L4 扩展：补间（缓动 + 标量采样 + 组件化推进）
//   批72 只交付了纯函数层（没有消费者，所以没进公共 API）；
//   批73 顿帧是**时间**的消费者，批76 `TweenPlayer` 才是**值**的消费者。
export { EASINGS, getEasing } from "./extensions/tween/easing.ts";
export type { EasingFn } from "./extensions/tween/easing.ts";
export { makeTween, sampleTween, tweenDurationMs, tweenIsDone, TWEEN_ERR } from "./extensions/tween/tween.ts";
export type { TweenSpec, TweenSpecInput, TweenSample } from "./extensions/tween/tween.ts";
export { TweenPlayer, TweenTrack, advancePlayer, ticksToMs, TWEEN_PLAYER_TYPE, TWEEN_PLAYER_ERR } from "./extensions/tween/tween-player.ts";
export type { TweenTrackInput, TrackSample } from "./extensions/tween/tween-player.ts";
