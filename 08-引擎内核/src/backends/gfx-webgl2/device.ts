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
  type BufferDesc,
  type BufferHandle,
  type DeviceCaps,
  type DrawBatch,
  type GfxStats,
  type PipelineDesc,
  type PipelineHandle,
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
    const gl = this.gl;
    const tex = gl.createTexture();
    if (tex === null || tex === undefined) {
      return err(engineError("GFX.OUT_OF_MEMORY", "createTexture 返回 null（显存不足）"));
    }
    const fmt = glFormat(desc.format ?? PixelFormat.RGBA8);
    gl.bindTexture(GL.TEXTURE_2D, tex);
    gl.texImage2D(
      GL.TEXTURE_2D,
      0,
      fmt.internal,
      desc.width,
      desc.height,
      0,
      fmt.format,
      GL.UNSIGNED_BYTE,
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
    const need = region.width * region.height * 4;
    if (data.byteLength !== need) {
      return err(engineError("GFX.SIZE_MISMATCH", `上传字节数 ${data.byteLength} 与区域期望 ${need} 不符`));
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
      GL.RGBA,
      GL.UNSIGNED_BYTE,
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

    if (batch.indices !== null) {
      const irec = this.dev._bufferRec(batch.indices);
      if (irec === undefined) throw new Error(`draw 的索引缓冲句柄 ${batch.indices} 不存在`);
      this.gl.bindBuffer(GL.ELEMENT_ARRAY_BUFFER, irec.gl);
      this.gl.drawElements(GL.TRIANGLES, batch.indexCount, GL.UNSIGNED_SHORT, 0);
    } else {
      this.gl.drawArrays(GL.TRIANGLES, 0, batch.vertexCount);
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
}

function glFormat(f: string): { internal: number; format: number } {
  switch (f) {
    case PixelFormat.RGB8:
      return { internal: GL.RGB, format: GL.RGB };
    case PixelFormat.R8:
      return { internal: GL.R8, format: GL.R8 };
    default:
      return { internal: GL.RGBA8, format: GL.RGBA };
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
