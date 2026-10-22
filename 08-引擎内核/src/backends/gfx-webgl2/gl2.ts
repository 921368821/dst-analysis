/**
 * L5 · WebGL2 的最小可用子集（`GL2Like`）
 *
 * ★★ 这个文件存在的唯一理由：**让渲染后端能在没有浏览器的环境里被测试**。
 *
 *   如果 device 直接吃 `WebGL2RenderingContext`，那么：
 *     · Node 里跑不了（没有 canvas）⇒ 判据只能靠"起个浏览器"或者"假装有 context"；
 *     · 而"假装"出来的桩一旦和真实 GL 语义不一致，就会制造**假绿灯**
 *       （上一代引擎为此在测试桩里手写过一整套 DOM，后来那些桩自己成了假否定的来源）。
 *
 *   所以把依赖收窄成一个**显式接口**：
 *     · 生产路径：`new GL2Device(canvas.getContext('webgl2'))` —— 结构类型直接兼容；
 *     · 测试路径：注入一个记录型 fake，验证"我们到底调了什么、参数对不对"。
 *
 *   ⚠️ 边界说清楚（写在文档里，避免被当成"已经验过 GL"）：
 *      fake 只能证明"我们发出的调用序列与参数正确"，**不能**证明
 *      "WebGL2 会接受这些调用"（驱动差异、精度、扩展）。后者由
 *      浏览器端到端（真实画布 + readPixels）负责。
 *
 * 常量写在本地而不是引用全局 `WebGL2RenderingContext` 的静态成员：
 * WebGL 的常量值由规范固定，硬编码是安全的；而引用全局类型会让本文件
 * 依赖 DOM lib，破坏"L1/L5 可移植"的约束。
 */

/** WebGL2 常量（值与规范一致）。 */
export const GL = {
  // buffer
  ARRAY_BUFFER: 0x8892,
  ELEMENT_ARRAY_BUFFER: 0x8893,
  STATIC_DRAW: 0x88e4,
  DYNAMIC_DRAW: 0x88e8,
  // shader
  VERTEX_SHADER: 0x8b31,
  FRAGMENT_SHADER: 0x8b30,
  COMPILE_STATUS: 0x8b81,
  LINK_STATUS: 0x8b82,
  // texture
  TEXTURE_2D: 0x0de1,
  TEXTURE0: 0x84c0,
  RGBA: 0x1908,
  RGBA8: 0x8058,
  RGB: 0x1907,
  R8: 0x8229,
  UNSIGNED_BYTE: 0x1401,
  FLOAT: 0x1406,
  UNSIGNED_SHORT: 0x1403,
  UNSIGNED_INT: 0x1405,
  TEXTURE_MIN_FILTER: 0x2801,
  TEXTURE_MAG_FILTER: 0x2800,
  TEXTURE_WRAP_S: 0x2802,
  TEXTURE_WRAP_T: 0x2803,
  NEAREST: 0x2600,
  LINEAR: 0x2601,
  CLAMP_TO_EDGE: 0x812f,
  REPEAT: 0x2901,
  UNPACK_ALIGNMENT: 0x0cf5,
  // state
  BLEND: 0x0be2,
  DEPTH_TEST: 0x0b71,
  SCISSOR_TEST: 0x0c11,
  SRC_ALPHA: 0x0302,
  ONE_MINUS_SRC_ALPHA: 0x0303,
  ONE: 0x0001,
  COLOR_BUFFER_BIT: 0x4000,
  DEPTH_BUFFER_BIT: 0x0100,
  TRIANGLES: 0x0004,
  TRIANGLE_STRIP: 0x0005,
  // limits
  MAX_TEXTURE_SIZE: 0x0d33,
  MAX_TEXTURE_IMAGE_UNITS: 0x8872,
  MAX_VERTEX_ATTRIBS: 0x8869,
  MAX_ELEMENTS_VERTICES: 0x80e8,
  // framebuffer
  FRAMEBUFFER: 0x8d40,
  COLOR_ATTACHMENT0: 0x8ce0,
  FRAMEBUFFER_COMPLETE: 0x8cd5,
} as const;

/**
 * 我们在 WebGL2 里实际用到的能力子集。
 *
 * ★ 故意**不**照抄完整 `WebGL2RenderingContext`：
 *   接口越小，fake 越容易写对；而"fake 写不对"正是假绿灯的来源。
 *   新增能力时（例如 uniform buffer），在这里加一行 —— 那是一次**有意识的**扩展。
 */
export interface GL2Like {
  readonly canvas: { width: number; height: number };

  // 查询
  getParameter(pname: number): number;
  getExtension(name: string): unknown;
  getError(): number;

  // buffer
  createBuffer(): unknown;
  bindBuffer(target: number, buffer: unknown | null): void;
  bufferData(target: number, data: ArrayBufferView | number, usage: number): void;
  bufferSubData(target: number, offset: number, data: ArrayBufferView): void;
  deleteBuffer(buffer: unknown): void;

  // texture
  createTexture(): unknown;
  bindTexture(target: number, texture: unknown | null): void;
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
  ): void;
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
  ): void;
  texParameteri(target: number, pname: number, param: number): void;
  activeTexture(texture: number): void;
  pixelStorei(pname: number, param: number): void;
  generateMipmap(target: number): void;
  deleteTexture(texture: unknown): void;

  // shader / program
  createShader(type: number): unknown;
  shaderSource(shader: unknown, source: string): void;
  compileShader(shader: unknown): void;
  getShaderParameter(shader: unknown, pname: number): boolean;
  getShaderInfoLog(shader: unknown): string | null;
  deleteShader(shader: unknown): void;
  createProgram(): unknown;
  attachShader(program: unknown, shader: unknown): void;
  linkProgram(program: unknown): void;
  getProgramParameter(program: unknown, pname: number): boolean;
  getProgramInfoLog(program: unknown): string | null;
  useProgram(program: unknown | null): void;
  getUniformLocation(program: unknown, name: string): unknown;
  deleteProgram(program: unknown): void;

  // uniform
  uniformMatrix3fv(location: unknown, transpose: boolean, value: Float32Array): void;
  uniform4f(location: unknown, x: number, y: number, z: number, w: number): void;
  uniform1i(location: unknown, v: number): void;
  uniform1f(location: unknown, v: number): void;

  // vertex layout
  enableVertexAttribArray(index: number): void;
  vertexAttribPointer(
    index: number,
    size: number,
    type: number,
    normalized: boolean,
    stride: number,
    offset: number,
  ): void;

  // state / draw
  viewport(x: number, y: number, w: number, h: number): void;
  scissor(x: number, y: number, w: number, h: number): void;
  enable(cap: number): void;
  disable(cap: number): void;
  blendFunc(sfactor: number, dfactor: number): void;
  clearColor(r: number, g: number, b: number, a: number): void;
  clear(mask: number): void;
  drawElements(mode: number, count: number, type: number, offset: number): void;
  drawArrays(mode: number, first: number, count: number): void;

  // framebuffer
  createFramebuffer(): unknown;
  bindFramebuffer(target: number, fb: unknown | null): void;
  framebufferTexture2D(
    target: number,
    attachment: number,
    textarget: number,
    texture: unknown,
    level: number,
  ): void;
  checkFramebufferStatus(target: number): number;
  deleteFramebuffer(fb: unknown): void;

  // 读回
  readPixels(
    x: number,
    y: number,
    width: number,
    height: number,
    format: number,
    type: number,
    pixels: ArrayBufferView,
  ): void;
}

/**
 * 判断一个对象是否像 WebGL2 context（结构类型收窄的唯一入口）。
 * ★ 不做 `instanceof`：jsdom / headless-gl / 各种 polyfill 都不是同一个构造器。
 */
export function isGL2Like(x: unknown): x is GL2Like {
  if (x === null || typeof x !== "object") return false;
  const o = x as Record<string, unknown>;
  return (
    typeof o["createBuffer"] === "function" &&
    typeof o["createShader"] === "function" &&
    typeof o["drawElements"] === "function" &&
    typeof o["getParameter"] === "function"
  );
}
