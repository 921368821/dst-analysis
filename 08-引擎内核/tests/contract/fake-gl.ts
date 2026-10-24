/**
 * 契约测试用的假 WebGL2 上下文
 *
 * ★ 它**只**验证"我们发出了什么调用、参数对不对"，不验证"GL 会不会接受"。
 *   后者靠浏览器端到端（真实画布 + readPixels）。这条边界必须写在文档里，
 *   否则它会变成假绿灯的来源。
 *
 * 刻意实现的两个"坏人"行为，用来测试我们自己的错误处理：
 *  · 源码里含 `FAIL` ⇒ 编译失败（`getShaderParameter` 返回 false + infoLog）
 *  · 索引/顶点缓冲的 `bufferSubData` 越界 ⇒ 记一条 `badCalls`（模拟 GL 的静默无操作）
 */

import { GL, type GL2Like } from "../../src/backends/gfx-webgl2/gl2.ts";

export interface GL2Call {
  readonly name: string;
  readonly args: readonly unknown[];
}

/** 一次 `texImage2D` 的结构化记录（判据要断言"上传的是 RGBA16 而不是 RGBA8"）。 */
export interface TexImageRecord {
  readonly internal: number;
  readonly format: number;
  readonly type: number;
  readonly width: number;
  readonly height: number;
  readonly bytes: number;
}

/** `HALF_FLOAT`（WebGL2 规范值）。fake 需要它来算 RGBA16F 的每像素字节数。 */
const HALF_FLOAT = 0x140b;

/**
 * 由 (format, type) 推每像素字节数。
 * 不认识的组合返回 `null` ⇒ **不做字节数断言**（fake 不该假装懂它没实现的格式）。
 *
 * ★ 这个映射是刻意写在 fake 里的"第二份知识"：它模拟的是 GL 对
 *   `format/type` 的解释。如果设备层把 RGBA16 的 `type` 发成 `UNSIGNED_BYTE`，
 *   fake 会按 4 字节/像素算 → 立刻记 badCall。这正是它能抓住"格式表写错"的方式。
 */
function bppOf(format: number, type: number): number | null {
  if (type === GL.UNSIGNED_BYTE) {
    if (format === GL.RGBA) return 4;
    if (format === GL.RGB) return 3;
    if (format === GL.R8) return 1;
    return null;
  }
  if (type === GL.UNSIGNED_SHORT && format === GL.RGBA) return 8; // RGBA16
  if (type === HALF_FLOAT && format === GL.RGBA) return 8; // RGBA16F
  return null;
}

export class FakeGL2 implements GL2Like {
  readonly canvas = { width: 800, height: 600 };
  readonly calls: GL2Call[] = [];
  /** 我们"接受"的调用里，被 fake 判定为非法的（越界等）。 */
  readonly badCalls: string[] = [];
  /** 当前绑定状态（用于断言 attribute 设置）。 */
  readonly state = {
    program: null as unknown,
    arrayBuffer: null as unknown,
    elementBuffer: null as unknown,
    activeTexture: 0,
    boundTexture: new Map<number, unknown>(),
    attribs: new Map<number, { size: number; stride: number; offset: number; buffer: unknown }>(),
    viewport: [0, 0, 0, 0] as [number, number, number, number],
    scissorEnabled: false,
    blends: 0,
    drawElementsCount: 0,
    drawArraysCount: 0,
    /** 每次 `texImage2D` 的格式/长度记录（供判据断言"上传的是 16 位"）。 */
    texImages: [] as TexImageRecord[],
  };

  private nextObj = 1;
  private readonly objKind = new Map<unknown, string>();
  private readonly sizes = new Map<unknown, number>();

  private rec(name: string, ...args: unknown[]): void {
    this.calls.push({ name, args });
  }

  private mk(kind: string): unknown {
    const o = { __kind: kind, __id: this.nextObj++ };
    this.objKind.set(o, kind);
    return o;
  }

  count(name: string): number {
    return this.calls.filter((c) => c.name === name).length;
  }

  getParameter(pname: number): number {
    switch (pname) {
      case GL.MAX_TEXTURE_SIZE:
        return 4096;
      case GL.MAX_TEXTURE_IMAGE_UNITS:
        return 8;
      case GL.MAX_ELEMENTS_VERTICES:
        return 65536;
      default:
        return 0;
    }
  }

  getExtension(_name: string): unknown {
    return null;
  }

  getError(): number {
    return 0;
  }

  // ---- buffer
  createBuffer(): unknown {
    return this.mk("buffer");
  }

  bindBuffer(target: number, buffer: unknown | null): void {
    this.rec("bindBuffer", target, buffer);
    if (target === GL.ARRAY_BUFFER) this.state.arrayBuffer = buffer;
    else this.state.elementBuffer = buffer;
  }

  bufferData(target: number, data: ArrayBufferView | number, usage: number): void {
    this.rec("bufferData", target, typeof data === "number" ? data : data.byteLength, usage);
    if (typeof data === "number" && this.state.arrayBuffer !== null && target === GL.ARRAY_BUFFER) {
      this.sizes.set(this.state.arrayBuffer, data);
    }
  }

  bufferSubData(target: number, offset: number, data: ArrayBufferView): void {
    this.rec("bufferSubData", target, offset, data.byteLength);
    const buf = target === GL.ARRAY_BUFFER ? this.state.arrayBuffer : this.state.elementBuffer;
    const cap = buf === null ? 0 : (this.sizes.get(buf) ?? 0);
    if (cap > 0 && offset + data.byteLength > cap) {
      // GL 会静默无操作（只置 INVALID_VALUE），这里记录下来供断言
      this.badCalls.push(`bufferSubData 越界：${offset}+${data.byteLength} > ${cap}`);
    }
    if (buf !== null && offset === 0 && target === GL.ELEMENT_ARRAY_BUFFER) {
      this.sizes.set(buf, data.byteLength);
    }
  }

  deleteBuffer(_b: unknown): void {
    this.rec("deleteBuffer");
  }

  // ---- texture
  createTexture(): unknown {
    return this.mk("texture");
  }

  bindTexture(target: number, texture: unknown | null): void {
    this.rec("bindTexture", target, texture);
    this.state.boundTexture.set(this.state.activeTexture, texture);
  }

  texImage2D(
    target: number,
    level: number,
    internalformat: number,
    width: number,
    height: number,
    border: number,
    format: number,
    type: number,
    pixels: ArrayBufferView | null,
  ): void {
    this.rec("texImage2D", target, level, internalformat, width, height, border, format, type, pixels === null ? 0 : pixels.byteLength);
    const bytes = pixels === null ? 0 : pixels.byteLength;
    this.state.texImages.push({ internal: internalformat, format, type, width, height, bytes });
    if (pixels !== null) {
      const bpp = bppOf(format, type);
      const expect = width * height * (bpp ?? 0);
      // bpp 为 null（fake 不识别的组合）时不断言：假装懂它没实现的格式就是假绿灯。
      if (bpp !== null && pixels.byteLength !== expect) {
        this.badCalls.push(`texImage2D 字节数不符：${pixels.byteLength} != ${width}x${height}x${bpp}=${expect}`);
      }
    }
  }

  texSubImage2D(
    target: number,
    level: number,
    xoffset: number,
    yoffset: number,
    width: number,
    height: number,
    format: number,
    type: number,
    pixels: ArrayBufferView,
  ): void {
    this.rec("texSubImage2D", target, level, xoffset, yoffset, width, height, format, type, pixels.byteLength);
  }

  texParameteri(target: number, pname: number, param: number): void {
    this.rec("texParameteri", target, pname, param);
  }

  activeTexture(texture: number): void {
    this.rec("activeTexture", texture);
    this.state.activeTexture = texture - GL.TEXTURE0;
  }

  pixelStorei(pname: number, param: number): void {
    this.rec("pixelStorei", pname, param);
  }

  generateMipmap(target: number): void {
    this.rec("generateMipmap", target);
  }

  deleteTexture(_t: unknown): void {
    this.rec("deleteTexture");
  }

  // ---- shader
  createShader(type: number): unknown {
    return this.mk(type === GL.VERTEX_SHADER ? "vs" : "fs");
  }

  shaderSource(shader: unknown, source: string): void {
    this.rec("shaderSource", shader, source.length);
    this.sizes.set(shader, source.length);
    (shader as { __src?: string }).__src = source;
  }

  compileShader(shader: unknown): void {
    this.rec("compileShader", shader);
  }

  getShaderParameter(shader: unknown, pname: number): boolean {
    if (pname !== GL.COMPILE_STATUS) return false;
    const src = (shader as { __src?: string }).__src ?? "";
    // ★ 两件事：
    //   · 没有 `main` 的源码在真 GL 里**编译不过**（fake 必须同样拒绝，否则契约形同虚设）
    //   · 刻意留一个 "FAIL" 开关，用来测"编译失败必须返回错误码"
    return src.includes("main") && !src.includes("FAIL");
  }

  getShaderInfoLog(shader: unknown): string {
    return (shader as { __src?: string }).__src?.includes("FAIL") ? "0:1(1): error: 假编译错误" : "";
  }

  deleteShader(_s: unknown): void {
    this.rec("deleteShader");
  }

  createProgram(): unknown {
    return this.mk("program");
  }

  attachShader(program: unknown, shader: unknown): void {
    this.rec("attachShader", program, shader);
  }

  linkProgram(program: unknown): void {
    this.rec("linkProgram", program);
  }

  getProgramParameter(program: unknown, pname: number): boolean {
    if (pname !== GL.LINK_STATUS) return false;
    return (program as { __linkFail?: boolean }).__linkFail !== true;
  }

  getProgramInfoLog(_p: unknown): string {
    return "";
  }

  useProgram(program: unknown | null): void {
    this.rec("useProgram", program);
    this.state.program = program;
  }

  getUniformLocation(program: unknown, name: string): unknown {
    this.rec("getUniformLocation", program, name);
    return { __kind: "uniform", name };
  }

  deleteProgram(_p: unknown): void {
    this.rec("deleteProgram");
  }

  uniformMatrix3fv(location: unknown, transpose: boolean, value: Float32Array): void {
    this.rec("uniformMatrix3fv", location, transpose, value.length);
  }

  uniform4f(location: unknown, x: number, y: number, z: number, w: number): void {
    this.rec("uniform4f", location, x, y, z, w);
  }

  uniform1i(location: unknown, v: number): void {
    this.rec("uniform1i", location, v);
  }

  uniform1f(location: unknown, v: number): void {
    this.rec("uniform1f", location, v);
  }

  enableVertexAttribArray(index: number): void {
    this.rec("enableVertexAttribArray", index);
  }

  vertexAttribPointer(
    index: number,
    size: number,
    type: number,
    normalized: boolean,
    stride: number,
    offset: number,
  ): void {
    this.rec("vertexAttribPointer", index, size, type, normalized, stride, offset);
    this.state.attribs.set(index, { size, stride, offset, buffer: this.state.arrayBuffer });
  }

  viewport(x: number, y: number, w: number, h: number): void {
    this.rec("viewport", x, y, w, h);
    this.state.viewport = [x, y, w, h];
  }

  scissor(x: number, y: number, w: number, h: number): void {
    this.rec("scissor", x, y, w, h);
  }

  enable(cap: number): void {
    this.rec("enable", cap);
    if (cap === GL.BLEND) this.state.blends++;
    if (cap === GL.SCISSOR_TEST) this.state.scissorEnabled = true;
  }

  disable(cap: number): void {
    this.rec("disable", cap);
    if (cap === GL.SCISSOR_TEST) this.state.scissorEnabled = false;
  }

  blendFunc(sfactor: number, dfactor: number): void {
    this.rec("blendFunc", sfactor, dfactor);
  }

  clearColor(r: number, g: number, b: number, a: number): void {
    this.rec("clearColor", r, g, b, a);
  }

  clear(mask: number): void {
    this.rec("clear", mask);
  }

  drawElements(mode: number, count: number, type: number, offset: number): void {
    this.rec("drawElements", mode, count, type, offset);
    this.state.drawElementsCount++;
  }

  drawArrays(mode: number, first: number, count: number): void {
    this.rec("drawArrays", mode, first, count);
    this.state.drawArraysCount++;
  }

  createFramebuffer(): unknown {
    return this.mk("fb");
  }

  bindFramebuffer(target: number, fb: unknown | null): void {
    this.rec("bindFramebuffer", target, fb);
  }

  framebufferTexture2D(
    target: number,
    attachment: number,
    textarget: number,
    texture: unknown,
    level: number,
  ): void {
    this.rec("framebufferTexture2D", target, attachment, textarget, texture, level);
  }

  checkFramebufferStatus(_target: number): number {
    return GL.FRAMEBUFFER_COMPLETE;
  }

  deleteFramebuffer(_f: unknown): void {
    this.rec("deleteFramebuffer");
  }

  readPixels(
    x: number,
    y: number,
    width: number,
    height: number,
    format: number,
    type: number,
    pixels: ArrayBufferView,
  ): void {
    this.rec("readPixels", x, y, width, height, format, type, pixels.byteLength);
    const out = pixels as Uint8Array;
    // 填一个确定的花纹，供判据区分"读到了"与"全零"
    for (let i = 0; i < out.length; i += 4) {
      out[i] = 11;
      out[i + 1] = 22;
      out[i + 2] = 33;
      out[i + 3] = 255;
    }
  }
}
