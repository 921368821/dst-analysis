/**
 * L1 · 图形设备接口
 *
 * 形状刻意保持"缩小版的现代图形 API"（Device / CommandList / 显式资源），
 * 这样将来接 WebGPU 或原生后端时是**换实现**，不是改接口。
 * 但也不做完整的 Vulkan（没有 barrier、没有 descriptor set）——
 * 2.5D 精灵渲染用不到，多一层抽象只增加出错面。
 *
 * 调用顺序（由 runtime 保证，设备不做隐式生命周期管理）：
 *   beginFrame(target) → 拿到 cmd
 *   cmd.setViewport / clear / setPipeline / bindTexture / draw ...
 *   endFrame()          → 提交并 ffi
 */

import type { Color, Rect } from "../../foundation/math/index.ts";
import type { EngineError, Result } from "../../foundation/result.ts";
import type {
  BufferDesc,
  BufferHandle,
  DeviceCaps,
  DrawBatch,
  GfxStats,
  PipelineDesc,
  PipelineHandle,
  RenderTargetDesc,
  RenderTargetHandle,
  ShaderDesc,
  ShaderHandle,
  TextureDesc,
  TextureHandle,
  UniformValue,
} from "./types.ts";

export type GfxErr = Result<void, EngineError>;
export type GfxOk<T> = Result<T, EngineError>;

/**
 * 指令列表。设备每帧给一个（双缓冲），调用方只在这一帧内使用。
 *
 * ★ 为什么不做"多线程录制"：Web 上没有真多线程渲染，原生后端将来要的话，
 *   这是"新增 ICommandList 的并行录制语义"，而不是改调用方 —— 因为调用方
 *   本来就只面对这个接口。
 */
export interface ICommandList {
  setViewport(rect: Rect): void;
  /**
   * 裁剪矩形。`null` = 取消裁剪。
   * ★ 用**屏幕空间**矩形（像素），不是世界坐标：世界→屏幕的换算属于相机，
   *   属于 core 层职责，不该让后端知道世界长什么样。
   */
  setScissor(rect: Rect | null): void;
  /** `flags` 是 `ClearFlags` 的位或。用 number 而非枚举：后端之间不共享枚举对象。 */
  clear(color: Color, flags: number): void;
  setPipeline(pipeline: PipelineHandle): void;
  /**
   * 设 uniform。
   * ★ `kind` 必须显式给：GL 里 `uniform1i` 与 `uniform1f` 是两个调用，
   *   而 JS 的 `1` 无法区分"整型 1"与"浮点 1.0"。设错类型在多数驱动上**静默不生效**
   *   （值恰好是 0/1 时"看起来能用"，换成 2.5 就出问题）。
   *   默认 `float`（绝大多数 uniform 是浮点）。
   */
  setUniform(name: string, value: UniformValue, kind?: "int" | "float"): void;
  bindTexture(slot: number, texture: TextureHandle): void;
  draw(batch: DrawBatch): void;
  /** 结束录制。之后对同一列表的调用是 bug，设备应当拒绝（返回 false 并计数）。 */
  finish(): void;
}

export interface IGraphicsDevice {
  readonly caps: DeviceCaps;

  // ---- 资源创建/销毁（全部返回 Result，失败可降级）
  createBuffer(desc: BufferDesc): GfxOk<BufferHandle>;
  /** `data` 必须已按 desc.byteLength 准备好；超出部分被拒绝（不静默截断）。 */
  updateBuffer(handle: BufferHandle, data: ArrayBufferView, byteOffset?: number): GfxErr;
  destroyBuffer(handle: BufferHandle): void;

  createTexture(desc: TextureDesc, data?: ArrayBufferView | null): GfxOk<TextureHandle>;
  updateTexture(
    handle: TextureHandle,
    region: { x: number; y: number; width: number; height: number },
    data: ArrayBufferView,
  ): GfxErr;
  destroyTexture(handle: TextureHandle): void;

  createShader(desc: ShaderDesc): GfxOk<ShaderHandle>;
  destroyShader(handle: ShaderHandle): void;

  createPipeline(desc: PipelineDesc): GfxOk<PipelineHandle>;
  destroyPipeline(handle: PipelineHandle): void;

  createRenderTarget(desc: RenderTargetDesc): GfxOk<RenderTargetHandle>;
  destroyRenderTarget(handle: RenderTargetHandle): void;

  // ---- 帧
  /** `target === null` 表示默认帧缓冲（画布）。 */
  beginFrame(target: RenderTargetHandle | null): ICommandList;
  endFrame(): void;

  /** 读回像素（左下原点，RGBA8）。不支持时返回带 `GFX.NO_READBACK` 的失败。 */
  readPixels(
    target: RenderTargetHandle | null,
    rect: Rect,
  ): GfxOk<Uint8Array>;

  resize(width: number, height: number): void;
  get size(): { readonly width: number; readonly height: number };

  readonly stats: GfxStats;

  /** 释放全部 GPU 资源。之后设备不可再用（句柄全部失效）。 */
  destroy(): void;
}

/**
 * 后端工厂：注册进 `BackendRegistry` 的东西。
 *
 * ★ `options` 用 `unknown` 而不是具体类型：注册表不该知道每个后端需要什么参数
 *   （webgl2 要 canvas，node 不需要）。由宿主强转 —— 这是**唯一**允许在
 *   L1 出现 `unknown` 的地方，且类型收窄在宿主侧完成。
 */
export interface GraphicsBackendFactory {
  readonly id: string;
  /** 探测当前环境能否创建（例如 canvas 存在、WebGL2 可用）。 */
  probe(options?: unknown): boolean;
  create(options?: unknown): GfxOk<IGraphicsDevice>;
}

export interface RenderPassDesc {
  readonly target: RenderTargetHandle | null;
  readonly clearColor?: Color;
  readonly clearFlags?: number;
}
