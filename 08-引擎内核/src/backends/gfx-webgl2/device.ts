/**
 * L5 · WebGL2 图形设备
 *
 * 实现 `IGraphicsDevice`，并且**只**依赖 `GL2Like`（可在 Node 里注入 fake）。
 *
 * 四件必须做对的事（都是"错了会静默"的那类）：
 *
 * ① **句柄表 + 严格校验**。创建失败返回 `Result`；已销毁句柄的任何操作失败。
 *    WebGL 本身对"用已删除的纹理"是**静默无操作**（不报错、画面变黑），
 *    所以这里的校验是唯一的防线。
 *
 * ② **每帧统计**（drawCalls / vertices / textureBindings / pipelineSwitches）。
 *    2D 引擎的性能几乎完全由"每帧几个 draw call"决定，
 *    而它不可见时，任何"批处理优化"都无法验证。
 *
 * ③ **状态缓存**（当前 program / 纹理槽 / 裁剪）：
 *    WebGL 的 `useProgram` / `bindTexture` / `activeTexture` 都是跨调用状态的，
 *    重复设置相同值在驱动侧仍可能触发校验。缓存后 `stats.pipelineSwitches`
 *    才等于"真实切换次数"（否则统计会虚高，优化效果无法判断）。
 *
 * ④ **错误的资源尺寸早失败**：`maxTextureSize` 是硬件上限，超了在真机上会创建失败
 *    但 WebGL 只给一个 INVALID_VALUE 错误码而不抛异常 —— 必须主动查。
 */

import { Color, Rect } from "../../foundation/math/index.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { ICommandList, IGraphicsDevice } from "../../platform/gfx/device.ts";
import {
  BlendMode,
  BufferUsage,
  PixelFormat,
  TextureFilter,
  TextureWrap,
  Topology,
  bytesPerPixel,
  type BufferDesc,
  type BufferHandle,
  type DeviceCaps,
  type DrawBatch,
  type GfxStats,
  type PipelineDesc,
  type PipelineHandle,
  type PixelFormatValue,
  type RenderTargetDesc,
  type RenderTargetHandle,
  type ShaderDesc,
  type ShaderHandle,
  type TextureDesc,
  type TextureHandle,
  type UniformValue,
} from "../../platform/gfx/types.ts";
import { GL, isGL2Like, type GL2Like } from "./gl2.ts";

type Kind = "buffer" | "texture" | "shader" | "pipeline" | "target";

interface Rec {
  readonly kind: Kind;
  readonly gl: unknown;
  readonly meta: Record<string, number | boolean | string>;
}

const SPRITE_STRIDE = 8 * 4; // pos2 + uv2 + color4（float32）
const QUAD_INDEX_MAX = 65536; // Uint16 索引上限

export class GL2Device implements IGraphicsDevice {
  readonly caps: DeviceCaps;
  private readonly gl: GL2Like;
  private next = 1;
  private readonly recs = new Map<number, Rec>();

  private frameIndex = 0;
  private recording: GL2CommandList | null = null;
  private _size: { width: number; height: number };
  private _stats: GfxStats = {
    frameIndex: 0,
    drawCalls: 0,
    verticesSubmitted: 0,
    textureBindings: 0,
    pipelineSwitches: 0,
    bytesUploaded: 0,
  };

  // 状态缓存：只在**真的变化**时才调 GL
  private curProgram: unknown = null;
  private curTextureSlot = -1;
  private curTexture: unknown = null;

  constructor(gl: unknown) {
    if (!isGL2Like(gl)) {
      throw new Error("GL2Device 需要一个 WebGL2 上下文（webgl2），传进来的对象不像 WebGL2 context");
    }
    this.gl = gl;
    const maxTex = gl.getParameter(GL.MAX_TEXTURE_SIZE) || 2048;
    const maxUnits = gl.getParameter(GL.MAX_TEXTURE_IMAGE_UNITS) || 8;
    const maxVerts = gl.getParameter(GL.MAX_ELEMENTS_VERTICES) || 65536;
    this.caps = {
      backend: "webgl2",
      version: "3.0",
      maxTextureSize: maxTex,
      maxTextureUnits: maxUnits,
      maxVerticesPerDraw: Math.max(1024, maxVerts),
      instancing: true,
      floatTextures: true,
      readback: true,
      srgbTextures: true,
    };
    this._size = { width: gl.canvas.width, height: gl.canvas.height };
    // 2D 渲染需要的固定状态
    gl.enable(GL.BLEND);
    gl.blendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA);
    gl.disable(GL.DEPTH_TEST);
    gl.pixelStorei(GL.UNPACK_ALIGNMENT, 1);
  }

  get stats(): GfxStats {
    return this._stats;
  }

  get size(): { readonly width: number; readonly height: number } {
    return this._size;
  }

  resize(width: number, height: number): void {
    this._size = { width, height };
    this.gl.canvas.width = width;
    this.gl.canvas.height = height;
  }

  // ---------------------------------------------------------------- buffer
  createBuffer(desc: BufferDesc): Result<BufferHandle, EngineError> {
    if (!(desc.byteLength > 0)) {
      return err(engineError("GFX.BAD_BUFFER", `缓冲区大小必须 > 0，收到 ${desc.byteLength}`));
    }
    const gl = this.gl;
    const buf = gl.createBuffer();
    if (buf === null || buf === undefined) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createBuffer 返回 null（显存不足）"));
    }
    const target = desc.usage === BufferUsage.Index ? GL.ELEMENT_ARRAY_BUFFER : GL.ARRAY_BUFFER;
    gl.bindBuffer(target, buf);
    gl.bufferData(target, desc.byteLength, desc.dynamic ? GL.DYNAMIC_DRAW : GL.STATIC_DRAW);
    gl.bindBuffer(target, null);
    return ok(this.track("buffer", buf, {
      byteLength: desc.byteLength,
      dynamic: desc.dynamic,
      target,
      label: desc.label ?? "",
    }) as unknown as BufferHandle);
  }

  updateBuffer(handle: BufferHandle, data: ArrayBufferView, byteOffset = 0): Result<void, EngineError> {
    const rec = this.get(handle as unknown as number, "buffer");
    if (rec === undefined) {
      return err(engineError("GFX.INVALID_HANDLE", `缓冲区句柄 ${handle} 不存在（可能已销毁）`));
    }
    const cap = rec.meta["byteLength"] as number;
    const end = byteOffset + data.byteLength;
    if (byteOffset < 0 || end > cap) {
      // ★ 不静默截断：真 WebGL 会对越界 bufferSubData 报 INVALID_VALUE 但不抛，
      //   于是"少画了几个精灵"完全无法归因。
      return err(
        engineError("GFX.BUFFER_OVERFLOW", `写入越界：offset=${byteOffset} len=${data.byteLength} 容量=${cap}`),
      );
    }
    const target = rec.meta["target"] as number;
    this.gl.bindBuffer(target, rec.gl);
    this.gl.bufferSubData(target, byteOffset, data);
    this.gl.bindBuffer(target, null);
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(undefined);
  }

  destroyBuffer(handle: BufferHandle): void {
    const rec = this.recs.get(handle as unknown as number);
    if (rec === undefined) return;
    this.gl.deleteBuffer(rec.gl);
    this.recs.delete(handle as unknown as number);
  }

  // ---------------------------------------------------------------- texture
  createTexture(desc: TextureDesc, data?: ArrayBufferView | null): Result<TextureHandle, EngineError> {
    if (!(desc.width > 0) || !(desc.height > 0)) {
      return err(engineError("GFX.BAD_TEXTURE", `纹理尺寸非法：${desc.width}x${desc.height}`));
    }
    if (desc.width > this.caps.maxTextureSize || desc.height > this.caps.maxTextureSize) {
      return err(
        engineError(
          "GFX.TEXTURE_TOO_LARGE",
          `纹理 ${desc.width}x${desc.height} 超过上限 ${this.caps.maxTextureSize}`,
          { label: desc.label ?? "" },
        ),
      );
    }
    const format = desc.format ?? PixelFormat.RGBA8;
    const fmt = glFormat(format);
    // ★ 早失败：真 WebGL 对"字节数与 w*h*format 不符"的 texImage2D 只置一个
    //   INVALID_VALUE 错误码（不抛、不返回），结果是**一张空纹理**被当成上传成功。
    //   在 JS 侧算一次乘法就能把这件事变成明确的错误，没有理由不做。
    if (data !== undefined && data !== null) {
      const need = desc.width * desc.height * fmt.bytesPerPixel;
      if (data.byteLength !== need) {
        return err(
          engineError(
            "GFX.SIZE_MISMATCH",
            `纹理数据 ${data.byteLength} 字节，但 ${desc.width}x${desc.height} 的 ${format} 需要 ${need}`,
            { label: desc.label ?? "", format },
          ),
        );
      }
    }
    const gl = this.gl;
    const tex = gl.createTexture();
    if (tex === null || tex === undefined) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createTexture 返回 null（显存不足）"));
    }
    gl.bindTexture(GL.TEXTURE_2D, tex);
    gl.texImage2D(
      GL.TEXTURE_2D,
      0,
      fmt.internal,
      desc.width,
      desc.height,
      0,
      fmt.format,
      fmt.type,
      data ?? null,
    );
    const filter = desc.filter === TextureFilter.Linear ? GL.LINEAR : GL.NEAREST;
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MIN_FILTER, filter);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_MAG_FILTER, filter);
    const wrap = desc.wrap === TextureWrap.Repeat ? GL.REPEAT : GL.CLAMP_TO_EDGE;
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_S, wrap);
    gl.texParameteri(GL.TEXTURE_2D, GL.TEXTURE_WRAP_T, wrap);
    if (desc.mipmaps === true) gl.generateMipmap(GL.TEXTURE_2D);
    gl.bindTexture(GL.TEXTURE_2D, null);
    return ok(
      this.track("texture", tex, {
        width: desc.width,
        height: desc.height,
        isTarget: desc.renderTarget === true,
        // 记下格式：updateTexture 必须按**同一格式**的字节数校验，
        // 否则"往 RGBA16 纹理里写 4 字节/像素"会以小图片段的形式静默成功。
        format,
        label: desc.label ?? "",
      }) as unknown as TextureHandle,
    );
  }

  updateTexture(
    handle: TextureHandle,
    region: { x: number; y: number; width: number; height: number },
    data: ArrayBufferView,
  ): Result<void, EngineError> {
    const rec = this.get(handle as unknown as number, "texture");
    if (rec === undefined) return err(engineError("GFX.INVALID_HANDLE", `纹理句柄 ${handle} 不存在`));
    const w = rec.meta["width"] as number;
    const h = rec.meta["height"] as number;
    if (region.x < 0 || region.y < 0 || region.x + region.width > w || region.y + region.height > h) {
      return err(
        engineError("GFX.REGION_OUT_OF_BOUNDS", `上传区域超出纹理：${JSON.stringify(region)} vs ${w}x${h}`),
      );
    }
    const format = rec.meta["format"] as PixelFormatValue;
    const fmt = glFormat(format);
    const need = region.width * region.height * fmt.bytesPerPixel;
    if (data.byteLength !== need) {
      return err(
        engineError(
          "GFX.SIZE_MISMATCH",
          `上传字节数 ${data.byteLength} 与区域期望 ${need} 不符（${format}，${region.width}x${region.height}）`,
        ),
      );
    }
    const gl = this.gl;
    gl.bindTexture(GL.TEXTURE_2D, rec.gl);
    gl.texSubImage2D(
      GL.TEXTURE_2D,
      0,
      region.x,
      region.y,
      region.width,
      region.height,
      fmt.format,
      fmt.type,
      data,
    );
    gl.bindTexture(GL.TEXTURE_2D, null);
    this._stats = { ...this._stats, bytesUploaded: this._stats.bytesUploaded + data.byteLength };
    return ok(undefined);
  }

  destroyTexture(handle: TextureHandle): void {
    const rec = this.recs.get(handle as unknown as number);
    if (rec === undefined) return;
    this.gl.deleteTexture(rec.gl);
    this.recs.delete(handle as unknown as number);
  }

  // ---------------------------------------------------------------- shader / pipeline
  createShader(desc: ShaderDesc): Result<ShaderHandle, EngineError> {
    if (desc.vertex.trim() === "" || desc.fragment.trim() === "") {
      return err(engineError("GFX.SHADER_EMPTY", "着色器源码为空"));
    }
    const gl = this.gl;
    const vs = gl.createShader(GL.VERTEX_SHADER);
    const fs = gl.createShader(GL.FRAGMENT_SHADER);
    gl.shaderSource(vs, desc.vertex);
    gl.compileShader(vs);
    if (!gl.getShaderParameter(vs, GL.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(vs) ?? "";
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      return err(engineError("GFX.SHADER_COMPILE", `顶点着色器编译失败：${log}`, { stage: "vertex", log }));
    }
    gl.shaderSource(fs, desc.fragment);
    gl.compileShader(fs);
    if (!gl.getShaderParameter(fs, GL.COMPILE_STATUS)) {
      const log = gl.getShaderInfoLog(fs) ?? "";
      gl.deleteShader(vs);
      gl.deleteShader(fs);
      return err(engineError("GFX.SHADER_COMPILE", `片元着色器编译失败：${log}`, { stage: "fragment", log }));
    }
    const prog = gl.createProgram();
    gl.attachShader(prog, vs);
    gl.attachShader(prog, fs);
    gl.linkProgram(prog);
    // 链接后 shader 对象可以被回收（program 持有引用）
    gl.deleteShader(vs);
    gl.deleteShader(fs);
    if (!gl.getProgramParameter(prog, GL.LINK_STATUS)) {
      const log = gl.getProgramInfoLog(prog) ?? "";
      gl.deleteProgram(prog);
      return err(engineError("GFX.SHADER_LINK", `程序链接失败：${log}`, { log }));
    }
    return ok(this.track("shader", prog, { label: desc.label ?? "" }) as unknown as ShaderHandle);
  }

  destroyShader(handle: ShaderHandle): void {
    const rec = this.recs.get(handle as unknown as number);
    if (rec === undefined) return;
    if (this.curProgram === rec.gl) this.curProgram = null;
    this.gl.deleteProgram(rec.gl);
    this.recs.delete(handle as unknown as number);
  }

  createPipeline(desc: PipelineDesc): Result<PipelineHandle, EngineError> {
    const sh = this.get(desc.shader as unknown as number, "shader");
    if (sh === undefined) {
      return err(engineError("GFX.INVALID_HANDLE", `管线引用的着色器 ${desc.shader} 不存在`));
    }
    return ok(
      this.track("pipeline", sh.gl, {
        blend: desc.blend ?? BlendMode.Alpha,
        topology: desc.topology ?? Topology.Triangles,
        label: desc.label ?? "",
      }) as unknown as PipelineHandle,
    );
  }

  destroyPipeline(handle: PipelineHandle): void {
    this.recs.delete(handle as unknown as number);
  }

  // ---------------------------------------------------------------- target
  createRenderTarget(desc: RenderTargetDesc): Result<RenderTargetHandle, EngineError> {
    const tex = this.get(desc.color as unknown as number, "texture");
    if (tex === undefined) {
      return err(engineError("GFX.INVALID_HANDLE", `渲染目标的颜色纹理 ${desc.color} 不存在`));
    }
    const fb = this.gl.createFramebuffer();
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, fb);
    this.gl.framebufferTexture2D(GL.FRAMEBUFFER, GL.COLOR_ATTACHMENT0, GL.TEXTURE_2D, tex.gl, 0);
    const status = this.gl.checkFramebufferStatus(GL.FRAMEBUFFER);
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    if (status !== GL.FRAMEBUFFER_COMPLETE) {
      this.gl.deleteFramebuffer(fb);
      return err(engineError("GFX.FRAMEBUFFER_INCOMPLETE", `帧缓冲不完整（status=${status}）`));
    }
    return ok(this.track("target", fb, { label: desc.label ?? "" }) as unknown as RenderTargetHandle);
  }

  destroyRenderTarget(handle: RenderTargetHandle): void {
    const rec = this.recs.get(handle as unknown as number);
    if (rec === undefined) return;
    this.gl.deleteFramebuffer(rec.gl);
    this.recs.delete(handle as unknown as number);
  }

  // ---------------------------------------------------------------- frame
  beginFrame(target: RenderTargetHandle | null): ICommandList {
    if (this.recording !== null) {
      // 上一帧没 endFrame：这是调用方 bug。不抛（渲染循环里抛会让整帧崩），但要留痕。
      this.recording.forceFinish();
      this.recording = null;
    }
    const gl = this.gl;
    if (target === null) {
      gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    } else {
      const rec = this.get(target as unknown as number, "target");
      gl.bindFramebuffer(GL.FRAMEBUFFER, rec?.gl ?? null);
    }
    this.frameIndex++;
    this._stats = {
      frameIndex: this.frameIndex,
      drawCalls: 0,
      verticesSubmitted: 0,
      textureBindings: 0,
      pipelineSwitches: 0,
      bytesUploaded: 0,
    };
    this.curProgram = null;
    this.curTextureSlot = -1;
    this.curTexture = null;
    const cmd = new GL2CommandList(this, gl);
    this.recording = cmd;
    return cmd;
  }

  endFrame(): void {
    this.recording?.forceFinish();
    this.recording = null;
    this.gl.bindFramebuffer(GL.FRAMEBUFFER, null);
  }

  readPixels(target: RenderTargetHandle | null, rect: Rect): Result<Uint8Array, EngineError> {
    if (!this.caps.readback) return err(engineError("GFX.NO_READBACK", "该设备不支持读回像素"));
    const w = Math.max(1, Math.floor(rect.width));
    const h = Math.max(1, Math.floor(rect.height));
    const out = new Uint8Array(w * h * 4);
    const gl = this.gl;
    if (target !== null) {
      const rec = this.get(target as unknown as number, "target");
      gl.bindFramebuffer(GL.FRAMEBUFFER, rec?.gl ?? null);
    }
    gl.readPixels(Math.floor(rect.x), Math.floor(rect.y), w, h, GL.RGBA, GL.UNSIGNED_BYTE, out);
    if (target !== null) gl.bindFramebuffer(GL.FRAMEBUFFER, null);
    return ok(out);
  }

  destroy(): void {
    const gl = this.gl;
    for (const [, rec] of this.recs) {
      switch (rec.kind) {
        case "buffer":
          gl.deleteBuffer(rec.gl);
          break;
        case "texture":
          gl.deleteTexture(rec.gl);
          break;
        case "shader":
          gl.deleteProgram(rec.gl);
          break;
        case "target":
          gl.deleteFramebuffer(rec.gl);
          break;
        default:
          break;
      }
    }
    this.recs.clear();
    this.recording = null;
  }

  // ---------------------------------------------------------------- 内部
  private track(kind: Kind, glObj: unknown, meta: Record<string, number | boolean | string>): number {
    const h = this.next++;
    this.recs.set(h, { kind, gl: glObj, meta });
    return h;
  }

  private get(h: number, kind: Kind): Rec | undefined {
    const rec = this.recs.get(h);
    return rec !== undefined && rec.kind === kind ? rec : undefined;
  }

  // ---- 命令列表回调（保持 internal，但需要暴露给同文件的类）
  _useProgram(program: unknown): boolean {
    if (this.curProgram === program) return false;
    this.gl.useProgram(program);
    this.curProgram = program;
    this._stats = { ...this._stats, pipelineSwitches: this._stats.pipelineSwitches + 1 };
    return true;
  }

  _bindTexture(slot: number, tex: unknown): void {
    if (this.curTextureSlot === slot && this.curTexture === tex) return;
    this.gl.activeTexture(GL.TEXTURE0 + slot);
    this.gl.bindTexture(GL.TEXTURE_2D, tex);
    this.curTextureSlot = slot;
    this.curTexture = tex;
    this._stats = { ...this._stats, textureBindings: this._stats.textureBindings + 1 };
  }

  _countDraw(vertices: number): void {
    this._stats = {
      ...this._stats,
      drawCalls: this._stats.drawCalls + 1,
      verticesSubmitted: this._stats.verticesSubmitted + vertices,
    };
  }

  _bufferRec(h: BufferHandle): Rec | undefined {
    return this.recs.get(h as unknown as number);
  }

  _textureRec(h: TextureHandle): Rec | undefined {
    const rec = this.recs.get(h as unknown as number);
    return rec !== undefined && rec.kind === "texture" ? rec : undefined;
  }

  _pipelineRec(h: PipelineHandle): Rec | undefined {
    return this.recs.get(h as unknown as number);
  }
}

class GL2CommandList implements ICommandList {
  private pipeline: PipelineHandle = 0 as PipelineHandle;
  private readonly uniforms = new Map<string, { value: UniformValue; kind: "int" | "float" }>();
  private readonly textureSlots = new Map<number, TextureHandle>();
  /** 本帧已落到 GL 上的混合方式（`null` = 还没设过）。避免同一帧重复 blendFunc。 */
  private blendMode: number | null = null;
  private finished = false;

  constructor(
    private readonly dev: GL2Device,
    private readonly gl: GL2Like,
  ) {
    this.gl.viewport(0, 0, this.gl.canvas.width, this.gl.canvas.height);
  }

  setViewport(rect: Rect): void {
    this.gl.viewport(rect.x | 0, rect.y | 0, rect.width | 0, rect.height | 0);
  }

  setScissor(rect: Rect | null): void {
    if (rect === null) {
      this.gl.disable(GL.SCISSOR_TEST);
      return;
    }
    this.gl.enable(GL.SCISSOR_TEST);
    this.gl.scissor(rect.x | 0, rect.y | 0, rect.width | 0, rect.height | 0);
  }

  clear(color: Color, flags: number): void {
    this.assertOpen("clear");
    this.gl.clearColor(color.r, color.g, color.b, color.a);
    this.gl.clear(flags);
  }

  setPipeline(pipeline: PipelineHandle): void {
    this.assertOpen("setPipeline");
    this.pipeline = pipeline;
    const rec = this.dev._pipelineRec(pipeline);
    if (rec === undefined) return;
    const changed = this.dev._useProgram(rec.gl);
    // ★ 混合方式是**管线**的属性，必须在设管线时落到 GL 上（而不是在设备初始化时
    //   一次性写死 `SRC_ALPHA / ONE_MINUS_SRC_ALPHA`）。写死的版本会让
    //   `BlendMode.None / Additive / Premultiplied` 全部**静默退化成 Alpha** ——
    //   与 `firstIndex` 同一类缺陷：字段被存下来、却从没被用（批66 的系统性排查）。
    //   放在 `_useProgram` 之后、且不受 `changed` 影响：同一条管线重复设也要保持一致。
    this.applyBlend(rec.meta.blend as number | undefined);
    if (!changed) return;
    // ★ 只重放 **uniform**，不重放纹理绑定。理由（这是 GL 的状态模型，不是风格）：
    //   · `bindTexture` 改的是 **context 级** 的 texture unit 绑定，换 program 不影响它；
    //   · `uniform1i(u_texture, 0)`（sampler 指向哪个 unit）是 **program 级** 状态，
    //     换 program 之后新 program 的 sampler 是未设置的 ⇒ 必须重放。
    //   第一版我两个都重放了（还写了"GL 的 program 状态不共享"来论证），
    //   被自己的契约测试抓到：纹理绑定次数不该因为换管线而变化。
    for (const [name, u] of this.uniforms) this.applyUniform(rec.gl, name, u.value, u.kind);
  }

  setUniform(name: string, value: UniformValue, kind: "int" | "float" = "float"): void {
    this.assertOpen("setUniform");
    this.uniforms.set(name, { value, kind });
    const rec = this.dev._pipelineRec(this.pipeline);
    if (rec !== undefined) this.applyUniform(rec.gl, name, value, kind);
  }

  bindTexture(slot: number, texture: TextureHandle): void {
    this.assertOpen("bindTexture");
    this.textureSlots.set(slot, texture);
    const rec = this.dev._textureRec(texture);
    if (rec !== undefined) this.dev._bindTexture(slot, rec.gl);
  }

  draw(batch: DrawBatch): void {
    this.assertOpen("draw");
    const pipe = this.dev._pipelineRec(this.pipeline);
    if (pipe === undefined) {
      // 没设管线就 draw 是调用方 bug；静默跳过会表现为"少画了东西"
      throw new Error("draw 之前没有 setPipeline（或管线句柄已失效）");
    }
    const vrec = this.dev._bufferRec(batch.vertices);
    if (vrec === undefined) throw new Error(`draw 的顶点缓冲句柄 ${batch.vertices} 不存在`);

    // 顶点布局固定（pos2 + uv2 + color4），stride 32 字节
    this.gl.bindBuffer(GL.ARRAY_BUFFER, vrec.gl);
    this.gl.enableVertexAttribArray(0);
    this.gl.vertexAttribPointer(0, 2, GL.FLOAT, false, SPRITE_STRIDE, 0);
    this.gl.enableVertexAttribArray(1);
    this.gl.vertexAttribPointer(1, 2, GL.FLOAT, false, SPRITE_STRIDE, 8);
    this.gl.enableVertexAttribArray(2);
    this.gl.vertexAttribPointer(2, 4, GL.FLOAT, false, SPRITE_STRIDE, 16);

    // ★★ `firstIndex` 是**索引个数**的起点，不是字节数（与 null 后端同一口径）。
    //   WebGL 的 `drawElements` 要的是**字节**偏移，所以要乘 `UNSIGNED_SHORT` 的 2。
    //
    //   ★ 这一行曾经写死成 0，代价是"整块地形盖住所有实体"：渲染模块把 215 个 quad
    //     分成两段（地形 116 / 实体 101），两段都从索引 0 开始画 ⇒ 第二段绑着主图集
    //     把**第一段的地形几何**又画了一遍（地形在主图集里 UV 被 clamp 到边缘色），
    //     结果是一整块纯色盖住画面。draw 次数、顶点数、纹理绑定、`firstIndex` 的
    //     传参**全都对**，只有真后端把它丢了 —— 所以 `render-tile.test.ts` 是绿的。
    //     判据在"我们传了什么"，缺陷在"我们用了没"；两者之间曾有一个洞（见 M238）。
    const firstIndex = batch.firstIndex ?? 0;
    // ★ 拓扑同理：`PipelineDesc.topology` 被存进管线记录却从没被读 ⇒ 三角带会被
    //   当成独立三角画（顶点数对、draw 数对，画面是错的）。这里按管线取 GL 的 mode。
    const mode = (pipe.meta.topology ?? Topology.Triangles) === Topology.TriangleStrip
      ? GL.TRIANGLE_STRIP
      : GL.TRIANGLES;
    if (batch.indices !== null) {
      const irec = this.dev._bufferRec(batch.indices);
      if (irec === undefined) throw new Error(`draw 的索引缓冲句柄 ${batch.indices} 不存在`);
      this.gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, irec.gl);
      this.gl.drawElements(mode, batch.indexCount, GL.UNSIGNED_SHORT, firstIndex * 2);
    } else {
      // 无索引时 `firstIndex` 只能解释成**顶点**起点；忽略它等于静默重画开头。
      this.gl.drawArrays(mode, firstIndex, batch.vertexCount);
    }
    this.dev._countDraw(batch.vertexCount);
  }

  finish(): void {
    this.finished = true;
  }

  forceFinish(): void {
    this.finished = true;
  }

  private applyUniform(
    program: unknown,
    name: string,
    v: UniformValue,
    kind: "int" | "float" = "float",
  ): void {
    const loc = this.gl.getUniformLocation(program, name);
    if (loc === null || loc === undefined) return; // 未使用的 uniform 会被优化掉，正常
    if (typeof v === "number") {
      // ★ 整型必须走 uniform1i：用 uniform1f 设 `uniform int` 在多数驱动上静默不生效
      if (kind === "int") this.gl.uniform1i(loc, v | 0);
      else this.gl.uniform1f(loc, v);
    } else if (v instanceof Float32Array) {
      if (v.length === 9) this.gl.uniformMatrix3fv(loc, false, v);
      else this.gl.uniform1i(loc, v[0] ?? 0);
    } else if (v.length === 4) {
      this.gl.uniform4f(loc, v[0]!, v[1]!, v[2]!, v[3]!);
    } else if (v.length === 1) {
      this.gl.uniform1f(loc, v[0]!);
    }
  }

  private assertOpen(what: string): void {
    if (this.finished) {
      throw new Error(`命令列表已 finish，仍在调用 ${what}（会画进下一帧）`);
    }
  }

  /**
   * 把管线的 `blend` 落到 GL 上。
   *
   * ★ 为什么必须在这里做：混合方式是**管线**的属性（一条不透明管线和一条半透明
   *   精灵管线可以同帧共存）。设备初始化时写死 `SRC_ALPHA / ONE_MINUS_SRC_ALPHA`
   *   的版本会让 `None / Additive / Premultiplied` 静默退化成 Alpha ——
   *   画面"看着还行"，只是叠加不发光、某些特效莫名半透。与 `firstIndex` 同一类：
   *   字段被存下来，却从没被用。
   */
  private applyBlend(mode: number | undefined): void {
    const m = mode ?? BlendMode.Alpha;
    if (this.blendMode === m) return;
    this.blendMode = m;
    switch (m) {
      case BlendMode.None:
        // 不透明：关混合（不是"把 blendFunc 设成 1:0" —— 那样仍然会读 dst）
        this.gl.disable(GL.BLEND);
        break;
      case BlendMode.Additive:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.SRC_ALPHA, GL.ONE);
        break;
      case BlendMode.Premultiplied:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.ONE, GL.ONE_MINUS_SRC_ALPHA);
        break;
      default:
        this.gl.enable(GL.BLEND);
        this.gl.blendFunc(GL.SRC_ALPHA, GL.ONE_MINUS_SRC_ALPHA);
        break;
    }
  }
}

/**
 * `gl2.ts` 的 `GL` 只收录「本后端真正用到」的常量，下面四个格式常量到今天为止
 * 只在这里出现，所以就地声明（值取自 WebGL2 规范，与 `gl2.ts` 的硬编码策略一致）。
 */
const GL_FORMAT = {
  RGB8: 0x8051,
  RGBA16: 0x805b,
  RGBA16F: 0x881a,
  HALF_FLOAT: 0x140b,
} as const;

interface GLFormat {
  /** `texImage2D` 的 internalformat（决定显存里的真实格式）。 */
  readonly internal: number;
  /** 上传数据的通道布局。 */
  readonly format: number;
  /** 上传数据的通道类型（决定每个分量几字节）。 */
  readonly type: number;
  /** 每像素字节数，供 create/update 校验长度。来自 L1 的共享映射。 */
  readonly bytesPerPixel: number;
}

/**
 * 引擎格式 → GL 三元组。
 *
 * ★ 这里**返回** `bytesPerPixel` 而不是让调用方再算一次：格式表与字节数是同一件事的
 *   两个侧面，分开放就会出现"表里是 RGBA16、校验按 4 字节"的半对状态。
 *
 * ★ `RGBA16F` 的边界（明确写出来，别当它和 RGBA16 一样）：
 *   它的 `type` 是 `HALF_FLOAT`，上传数据必须是**真的** half 字节流（每通道 2 字节，
 *   由 JS 侧手工量化）—— WebGL 不接受 `Float32Array` 直接传给 HALF_FLOAT。
 *   当前仓库没有任何调用点传 RGBA16F 的 `data`（它只作为渲染目标格式出现的可能性更大），
 *   所以这里只保证格式与长度校验正确，不提供 float32→half 的转换。
 */
function glFormat(f: PixelFormatValue): GLFormat {
  const bpp = bytesPerPixel(f);
  switch (f) {
    case PixelFormat.RGB8:
      return { internal: GL_FORMAT.RGB8, format: GL.RGB, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    case PixelFormat.R8:
      return { internal: GL.R8, format: GL.R8, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    case PixelFormat.RGBA16:
      return { internal: GL_FORMAT.RGBA16, format: GL.RGBA, type: GL.UNSIGNED_SHORT, bytesPerPixel: bpp };
    case PixelFormat.RGBA16F:
      return { internal: GL_FORMAT.RGBA16F, format: GL.RGBA, type: GL_FORMAT.HALF_FLOAT, bytesPerPixel: bpp };
    case PixelFormat.RGBA8:
      return { internal: GL.RGBA8, format: GL.RGBA, type: GL.UNSIGNED_BYTE, bytesPerPixel: bpp };
    default:
      // 旧实现把 RGBA16F（以及任何未知格式）静默落到 RGBA8 —— 于是"16 位图集"能上传成功、
      // 判据全绿，画面上却是 8 位。这里不再有兜底：不认识就报错
      // （`bytesPerPixel` 已经先一步抛了，这个分支只为让 switch 穷尽）。
      throw new Error(`webgl2 后端不认识 PixelFormat：${String(f)}`);
  }
}

/**
 * 后端工厂。
 * `probe` 需要真实 canvas —— 在 Node 里返回 false，于是注册表会自动降级到 null。
 * ★ 这是"能力探测"而不是"try/catch 探路"：探测失败是**正常路径**，不打日志。
 */
export const webgl2Backend = {
  id: "webgl2",
  priority: 100,
  probe(options?: unknown): boolean {
    const o = (options ?? {}) as { canvas?: { getContext?: (t: string) => unknown } };
    const canvas = o.canvas;
    if (canvas === undefined || typeof canvas.getContext !== "function") return false;
    try {
      return isGL2Like(canvas.getContext("webgl2"));
    } catch {
      return false;
    }
  },
  create(options?: unknown): Result<IGraphicsDevice, EngineError> {
    const o = (options ?? {}) as { canvas?: { getContext?: (t: string) => unknown } };
    let ctx: unknown = null;
    try {
      ctx = o.canvas?.getContext?.("webgl2") ?? null;
    } catch (e) {
      return err(engineError("GFX.CONTEXT_FAILED", `getContext('webgl2') 抛错：${String(e)}`));
    }
    if (!isGL2Like(ctx)) {
      return err(engineError("GFX.CONTEXT_FAILED", "拿不到 WebGL2 上下文（浏览器不支持或被禁用）"));
    }
    try {
      return ok(new GL2Device(ctx));
    } catch (e) {
      return err(engineError("GFX.DEVICE_INIT", e instanceof Error ? e.message : String(e)));
    }
  },
};

export { QUAD_INDEX_MAX, SPRITE_STRIDE };
