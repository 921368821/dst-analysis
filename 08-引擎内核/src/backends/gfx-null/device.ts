/**
 * L5 · Null 图形设备（记录型）
 *
 * 名字叫 Null，但它**不"什么都不做"** —— 它把每一次调用都记下来。
 * 这是刻意的：headless 判据要能断言"渲染层到底提交了什么"（几个 draw call、
 * 多少顶点、绑了几次纹理、有没有越界上传），而唯一能在没有 GPU 的环境里
 * 得到这个答案的办法，就是让设备把调用变成**可读的数据**。
 *
 * ★ 它同时是 `IGraphicsDevice` 的**契约参照实现**：
 *   所有后端（webgl2 / 将来的 webgpu / 原生）都必须通过 `tests/contract/gfx.contract.ts`，
 *   而那个契约里一半的断言在 Null 上先跑通 —— 于是"接口有没有歧义"在写第二个
 *   后端之前就被发现。上一代引擎只有一个后端，接口里的歧义直到接第二个才暴露。
 *
 * 它**故意严格**：越界上传、超限纹理、使用无效句柄都返回失败。
 * 宽松的哑设备会让判据在真实的严格后端上突然红（"本地全绿线上挂"）。
 */

import { ok, err, engineError, type EngineError, type Result } from "../../foundation/result.ts";
import { hashStateCreate, hashStateHex, hashStateUpdate, type HashState } from "../../foundation/hash.ts";
import { Color, Rect } from "../../foundation/math/index.ts";
import type { IGraphicsDevice, ICommandList } from "../../platform/gfx/device.ts";
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
} from "../../platform/gfx/types.ts";

interface BufRec {
  byteLength: number;
  usage: number;
  dynamic: boolean;
  label: string;
}

/**
 * 纹理摘要：FNV-1a 双通道 16 hex。**算法在 L0（`foundation/hash.ts`），这里不自己写。**
 *
 * ★ 为什么必须共用 L0 那一份（这是修过的真实缺陷）：
 *   本文件原先自带一份双 FNV，B 通道 basis 取 `0x84222325`；资产层
 *   （`extensions/asset-import/hash.ts`）也自带一份，B 通道取 `0x9e3779b9`。
 *   两边注释都写"FNV-1a 双拼"，各自单测都过，但摘要**永不相等** ——
 *   于是"资产解码出的像素"和"GPU 收到的像素"无法比对，
 *   `解码 → 上传` 的最后一环只能靠"我相信它接通了"。这类缺陷靠看代码发现不了。
 *
 * ★ 为什么对"上传的字节"算，而不是对描述符算：
 *   判据要回答的是"解码出的 pixels 与 GPU 实际收到的字节是不是同一份"。
 *   描述符（宽高/格式/label）相同不代表像素相同 —— 那正是"假贴图"能混过去的原因。
 *
 * ★ 为什么不存像素：2048×2048 RGBA8 是 16 MB，几十张就能让判据进程 OOM。
 *   摘要 + 字节数足以做**相等性**断言，且内存是常数。
 *
 * ★ 多次 update 的口径：对"按调用顺序拼接起来的字节流"算（FNV 可流式累加，
 *   不需要保存历史字节）。因此：
 *     · 一次 createTexture(整张图) → 摘要 == 对整张图直接算的摘要；
 *     · 分块 update 两次 → 摘要 == 对两块拼接后的流算的摘要。
 *   它**不是**"最终像素状态"的摘要（同一区域被覆盖两次时，旧字节也进了流）。
 *   这是刻意选择：判据关心的是"后端收到了什么"，不是"显存里最后是什么"。
 */
function asBytes(view: ArrayBufferView): Uint8Array {
  return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
}

interface TexRec {
  width: number;
  height: number;
  label: string;
  isTarget: boolean;
  /** 累积字节流的哈希状态（可流式累加，不保存字节）。`hash.bytes === 0` 表示从未上传。 */
  hash: HashState;
}

export interface NullDrawRecord {
  readonly vertices: number;
  readonly indices: number;
  readonly pipeline: PipelineHandle;
  readonly textures: readonly TextureHandle[];
}

/** 一次帧的录制结果（判据读它）。 */
export interface NullFrameRecord {
  readonly frameIndex: number;
  readonly clears: Array<{ color: Color; flags: number }>;
  readonly draws: NullDrawRecord[];
  scissorSets: number;
  viewportSets: number;
}

export class NullGraphicsDevice implements IGraphicsDevice {
  readonly caps: DeviceCaps = {
    backend: "null",
    version: "1",
    maxTextureSize: 4096,
    maxTextureUnits: 8,
    maxVerticesPerDraw: 65536,
    instancing: false,
    floatTextures: false,
    readback: true,
    srgbTextures: false,
  };

  private nextHandle = 1;
  private readonly buffers = new Map<number, BufRec>();
  private readonly textures = new Map<number, TexRec>();
  private readonly shaders = new Map<number, { label: string }>();
  private readonly pipelines = new Map<number, { shader: ShaderHandle; label: string }>();
  private readonly targets = new Map<number, { color: TextureHandle }>();

  private frameIndex = 0;
  private current: NullFrameRecord | null = null;
  private _stats: GfxStats = {
    frameIndex: 0,
    drawCalls: 0,
    verticesSubmitted: 0,
    textureBindings: 0,
    pipelineSwitches: 0,
    bytesUploaded: 0,
  };
  private _size = { width: 0, height: 0 };

  /** 所有完成的帧（判据读最近若干帧）。 */
  readonly frames: NullFrameRecord[] = [];
  /** 错误调用记录：契约测试会断言"非法操作没有静默通过"。 */
  readonly rejectedCalls: string[] = [];

  constructor(width = 1280, height = 720) {
    this._size = { width, height };
  }

  get stats(): GfxStats {
    return this._stats;
  }

  get size(): { readonly width: number; readonly height: number } {
    return this._size;
  }

  resize(width: number, height: number): void {
    this._size = { width, height };
  }

  // ---------------------------------------------------------------- buffer
  createBuffer(desc: BufferDesc): Result<BufferHandle, EngineError> {
    if (!(desc.byteLength > 0)) {
      return err(engineError("GFX.BAD_BUFFER", `缓冲区大小必须 > 0，收到 ${desc.byteLength}`));
    }
    if (desc.byteLength > 64 * 1024 * 1024) {
      return err(engineError("GFX.BAD_BUFFER", `缓冲区过大：${desc.byteLength} 字节（上限 64 MB）`));
    }
    const h = this.nextHandle++;
    this.buffers.set(h, {
      byteLength: desc.byteLength,
      usage: desc.usage,
      dynamic: desc.dynamic,
      label: desc.label ?? "",
    });
    return ok(h as unknown as BufferHandle);
  }

  updateBuffer(handle: BufferHandle, data: ArrayBufferView, byteOffset = 0): Result<void, EngineError> {
    const rec = this.buffers.get(handle as unknown as number);
    if (rec === undefined) {
      this.rejectedCalls.push(`updateBuffer(无效句柄 ${handle})`);
      return err(engineError("GFX.INVALID_HANDLE", `缓冲区句柄 ${handle} 不存在（可能已销毁）`));
    }
    const end = byteOffset + data.byteLength;
    if (byteOffset < 0 || end > rec.byteLength) {
      this.rejectedCalls.push(`updateBuffer(越界 ${byteOffset}+${data.byteLength} > ${rec.byteLength})`);
      // 不静默截断：越界上传在真后端上会静默画错，这里必须失败
      return err(
        engineError("GFX.BUFFER_OVERFLOW", `写入越界：offset=${byteOffset} len=${data.byteLength} 容量=${rec.byteLength}`, {
          label: rec.label,
        }),
      );
    }
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(undefined);
  }

  destroyBuffer(handle: BufferHandle): void {
    if (!this.buffers.delete(handle as unknown as number)) {
      this.rejectedCalls.push(`destroyBuffer(已失效 ${handle})`);
    }
  }

  // ---------------------------------------------------------------- texture
  createTexture(desc: TextureDesc, data?: ArrayBufferView | null): Result<TextureHandle, EngineError> {
    if (!(desc.width > 0) || !(desc.height > 0)) {
      return err(engineError("GFX.BAD_TEXTURE", `纹理尺寸非法：${desc.width}x${desc.height}`));
    }
    if (desc.width > this.caps.maxTextureSize || desc.height > this.caps.maxTextureSize) {
      // ★ 真实后端在这里会失败（GPU 上限）。让 Null 也失败，是为了让"依赖超大纹理"
      //   的代码在 headless 判据里就红，而不是等真机上线才发现。
      return err(
        engineError(
          "GFX.TEXTURE_TOO_LARGE",
          `纹理 ${desc.width}x${desc.height} 超过上限 ${this.caps.maxTextureSize}`,
          { label: desc.label ?? "" },
        ),
      );
    }
    const h = this.nextHandle++;
    const hash = hashStateCreate();
    if (data !== undefined && data !== null) hashStateUpdate(hash, asBytes(data));
    this.textures.set(h, {
      width: desc.width,
      height: desc.height,
      label: desc.label ?? "",
      isTarget: desc.renderTarget === true,
      hash,
    });
    return ok(h as unknown as TextureHandle);
  }

  updateTexture(
    handle: TextureHandle,
    region: { x: number; y: number; width: number; height: number },
    data: ArrayBufferView,
  ): Result<void, EngineError> {
    const rec = this.textures.get(handle as unknown as number);
    if (rec === undefined) {
      return err(engineError("GFX.INVALID_HANDLE", `纹理句柄 ${handle} 不存在`));
    }
    if (
      region.x < 0 ||
      region.y < 0 ||
      region.x + region.width > rec.width ||
      region.y + region.height > rec.height
    ) {
      return err(
        engineError("GFX.REGION_OUT_OF_BOUNDS", `上传区域超出纹理：${JSON.stringify(region)} vs ${rec.width}x${rec.height}`),
      );
    }
    // 4 字节/像素（RGBA8）是唯一严格校验的格式；其他格式只记字节数
    const expect = region.width * region.height * 4;
    if (data.byteLength !== expect && rec.isTarget) {
      // 渲染目标的上传必须是完整 RGBA8 —— 少一个字节就会错位
      return err(
        engineError("GFX.SIZE_MISMATCH", `上传字节数 ${data.byteLength} 与区域期望 ${expect} 不符`),
      );
    }
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    hashStateUpdate(rec.hash, asBytes(data));
    return ok(undefined);
  }

  /**
   * 纹理的"上传字节流"摘要（16 hex），用于断言"解码出的 pixels == GPU 实际收到的字节"。
   * 句柄不存在 → `undefined`（不抛：这不是程序错误，是查询语气）。
   * 从未上传过任何字节 → 也返回 `undefined`：空流的摘要看起来像一个真摘要，
   * 让调用方误以为"上传过了"。
   */
  textureDigest(handle: TextureHandle): string | undefined {
    const rec = this.textures.get(handle as unknown as number);
    if (rec === undefined || rec.hash.bytes === 0) return undefined;
    return hashStateHex(rec.hash);
  }

  /**
   * 已创建且未销毁的纹理句柄（按创建顺序）。
   *
   * ★ 判据需要它才能回答"渲染模块到底传了哪张图"：
   *   `stats.bytesUploaded` 只能说明"传了 65536 字节"，分不清"传对了"
   *   和"传了同样大小的另一张图"—— 而后者正是"假贴图"在生产环境里的样子。
   */
  get textureHandles(): readonly TextureHandle[] {
    return Array.from(this.textures.keys()) as TextureHandle[];
  }

  destroyTexture(handle: TextureHandle): void {
    if (!this.textures.delete(handle as unknown as number)) {
      this.rejectedCalls.push(`destroyTexture(已失效 ${handle})`);
    }
  }

  // ---------------------------------------------------------------- shader / pipeline
  createShader(desc: ShaderDesc): Result<ShaderHandle, EngineError> {
    if (desc.vertex.trim() === "" || desc.fragment.trim() === "") {
      return err(engineError("GFX.SHADER_EMPTY", "着色器源码为空"));
    }
    // 极简静态检查：真实的编译在 webgl2 后端。这里只拦"明显不可能编译"的输入，
    // 让契约测试能覆盖"非法源码必须失败"这条而不依赖 GPU。
    if (!/(void\s+main|fn\s+main)/.test(desc.vertex + desc.fragment)) {
      return err(engineError("GFX.SHADER_COMPILE", "着色器没有 main 入口", { label: desc.label ?? "" }));
    }
    const h = this.nextHandle++;
    this.shaders.set(h, { label: desc.label ?? "" });
    return ok(h as unknown as ShaderHandle);
  }

  destroyShader(handle: ShaderHandle): void {
    this.shaders.delete(handle as unknown as number);
  }

  createPipeline(desc: PipelineDesc): Result<PipelineHandle, EngineError> {
    if (!this.shaders.has(desc.shader as unknown as number)) {
      return err(engineError("GFX.INVALID_HANDLE", `管线引用的着色器 ${desc.shader} 不存在`));
    }
    const h = this.nextHandle++;
    this.pipelines.set(h, { shader: desc.shader, label: desc.label ?? "" });
    return ok(h as unknown as PipelineHandle);
  }

  destroyPipeline(handle: PipelineHandle): void {
    this.pipelines.delete(handle as unknown as number);
  }

  createRenderTarget(desc: RenderTargetDesc): Result<RenderTargetHandle, EngineError> {
    if (!this.textures.has(desc.color as unknown as number)) {
      return err(engineError("GFX.INVALID_HANDLE", `渲染目标的颜色纹理 ${desc.color} 不存在`));
    }
    const h = this.nextHandle++;
    this.targets.set(h, { color: desc.color });
    return ok(h as unknown as RenderTargetHandle);
  }

  destroyRenderTarget(handle: RenderTargetHandle): void {
    this.targets.delete(handle as unknown as number);
  }

  // ---------------------------------------------------------------- frame
  beginFrame(target: RenderTargetHandle | null): ICommandList {
    if (this.current !== null) {
      this.rejectedCalls.push("beginFrame(上一帧没有 endFrame)");
    }
    const record: NullFrameRecord = {
      frameIndex: this.frameIndex++,
      clears: [],
      draws: [],
      scissorSets: 0,
      viewportSets: 0,
    };
    this.current = record;
    this._stats = {
      frameIndex: record.frameIndex,
      drawCalls: 0,
      verticesSubmitted: 0,
      textureBindings: 0,
      pipelineSwitches: 0,
      bytesUploaded: 0,
    };
    return new NullCommandList(this, target);
  }

  endFrame(): void {
    if (this.current === null) {
      this.rejectedCalls.push("endFrame(没有 beginFrame)");
      return;
    }
    this.frames.push(this.current);
    if (this.frames.length > 120) this.frames.shift();
    this.current = null;
  }

  readPixels(target: RenderTargetHandle | null, rect: Rect): Result<Uint8Array, EngineError> {
    if (!this.caps.readback) {
      return err(engineError("GFX.NO_READBACK", "该设备不支持读回像素"));
    }
    const w = Math.max(1, Math.floor(rect.width));
    const h = Math.max(1, Math.floor(rect.height));
    const out = new Uint8Array(w * h * 4);
    if (target !== null) {
      const t = this.targets.get(target as unknown as number);
      if (t === undefined) return err(engineError("GFX.INVALID_HANDLE", `渲染目标 ${target} 不存在`));
      // 用一个确定的花纹填充，便于判据区分"读到了"与"全零"
      for (let i = 0; i < out.length; i += 4) {
        out[i] = 32;
        out[i + 1] = 64;
        out[i + 2] = 96;
        out[i + 3] = 255;
      }
    }
    return ok(out);
  }

  destroy(): void {
    this.buffers.clear();
    this.textures.clear();
    this.shaders.clear();
    this.pipelines.clear();
    this.targets.clear();
    this.current = null;
  }

  /** 内部：命令列表回调。 */
  _pushDraw(rec: NullDrawRecord): void {
    this.current?.draws.push(rec);
    this._stats = {
      ...this._stats,
      drawCalls: this._stats.drawCalls + 1,
      verticesSubmitted: this._stats.verticesSubmitted + rec.vertices,
      textureBindings: this._stats.textureBindings + rec.textures.length,
    };
  }

  _pushClear(color: Color, flags: number): void {
    this.current?.clears.push({ color, flags });
  }

  _pushPipeline(): void {
    this._stats = { ...this._stats, pipelineSwitches: this._stats.pipelineSwitches + 1 };
  }

  _bumpScissor(): void {
    if (this.current) (this.current as { scissorSets: number }).scissorSets++;
  }

  _bumpViewport(): void {
    if (this.current) (this.current as { viewportSets: number }).viewportSets++;
  }
}

class NullCommandList implements ICommandList {
  private pipeline: PipelineHandle = 0 as PipelineHandle;
  private readonly textures = new Map<number, TextureHandle>();
  private readonly uniforms = new Map<string, UniformValue>();
  private finished = false;

  constructor(
    private readonly dev: NullGraphicsDevice,
    private readonly target: RenderTargetHandle | null,
  ) {
    void this.target;
  }

  setViewport(rect: Rect): void {
    void rect;
    this.dev._bumpViewport();
  }

  setScissor(rect: Rect | null): void {
    void rect;
    this.dev._bumpScissor();
  }

  clear(color: Color, flags: number): void {
    this.assertOpen("clear");
    this.dev._pushClear(color, flags);
  }

  setPipeline(pipeline: PipelineHandle): void {
    this.assertOpen("setPipeline");
    this.pipeline = pipeline;
    this.dev._pushPipeline();
  }

  setUniform(name: string, value: UniformValue, _kind: "int" | "float" = "float"): void {
    this.assertOpen("setUniform");
    this.uniforms.set(name, value);
  }

  bindTexture(slot: number, texture: TextureHandle): void {
    this.assertOpen("bindTexture");
    this.textures.set(slot, texture);
  }

  draw(batch: DrawBatch): void {
    this.assertOpen("draw");
    this.dev._pushDraw({
      vertices: batch.vertexCount,
      indices: batch.indexCount,
      pipeline: this.pipeline,
      textures: Array.from(this.textures.values()),
    });
  }

  finish(): void {
    this.finished = true;
  }

  private assertOpen(what: string): void {
    if (this.finished) {
      // 录制结束后再调用是 bug：真后端上会画到下一帧里去，症状是"画面滞后一帧"
      throw new Error(`命令列表已 finish，仍在调用 ${what}`);
    }
  }
}

export const nullGfxBackend = {
  id: "null",
  priority: 0,
  probe(_options?: unknown): boolean {
    return true; // 任何环境都能建
  },
  create(options?: unknown): Result<IGraphicsDevice, EngineError> {
    const o = (options ?? {}) as { width?: number; height?: number };
    return ok(new NullGraphicsDevice(o.width ?? 1280, o.height ?? 720));
  },
};
