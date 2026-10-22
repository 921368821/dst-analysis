/**
 * L5 · 内置着色器（GLSL ES 3.00）
 *
 * ★ 为什么着色器源码属于 **L4 渲染模块**，而不属于后端：
 *   后端只负责**编译**调用方给的源码（`ShaderDesc.vertex/fragment`），
 *   它不该决定"精灵怎么画"。反过来，把源码放进 backends/ 会让
 *   extensions → backends —— 违反"扩展只依赖接口"。
 *
 *   所以源码在这里，由渲染模块按 `dev.caps.backend` 选择（当前只有 GLSL；
 *   将来 WebGPU 时加 `shaders-wgsl.ts`，选择逻辑在 `render-module.ts` 一处）。
 *   这也解释了为什么 `IGraphicsDevice.createShader` 收的是**源码字符串**
 *   而不是"着色器名字"：源码是策略，编译是机制。
 *
 * 2.5D 的投影在**着色器外**完成：顶点位置由 CPU 侧用相机的 Affine2 变换好
 * （`batch2d.ts` 做），着色器只做"把 NDC 坐标送出去"。
 * 这样做的理由：
 *   · 2D 只需要 2×3 仿射，CPU 侧一次性算完比每顶点一次 mat3 乘更快；
 *   · 深度排序（z 降序）本来就必须在 CPU 侧做，投影跟着一起做没有额外成本；
 *   · 着色器因此极简 ⇒ 换后端时最难移植的部分（矩阵约定）不存在。
 */

/** 精灵：位置已是裁剪空间（-1..1），直接输出。 */
export const SPRITE_VS = `#version 300 es
layout(location = 0) in vec2 a_position;
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_color;
out vec2 v_uv;
out vec4 v_color;
void main() {
  v_uv = a_uv;
  v_color = a_color;
  gl_Position = vec4(a_position, 0.0, 1.0);
}`;

/**
 * 片元：纹理 × 顶点色。
 * ★ `u_useTexture` 而不是"绑定一张 1×1 白图"：
 *   前者省一次纹理切换（切纹理是 2D 批处理的最大开销），
 *   后者会让"纯色矩形"（血条、调试框）也占一个纹理槽位。
 */
export const SPRITE_FS = `#version 300 es
precision mediump float;
in vec2 v_uv;
in vec4 v_color;
uniform sampler2D u_texture;
uniform int u_useTexture;
out vec4 o_color;
void main() {
  vec4 c = u_useTexture == 1 ? texture(u_texture, v_uv) : vec4(1.0);
  o_color = c * v_color;
}`;

/** 全屏纯色（清屏兜底 / 调试）—— 与精灵共用顶点格式，只忽略 uv/color。 */
export const SOLID_FS = `#version 300 es
precision mediump float;
in vec4 v_color;
out vec4 o_color;
void main() { o_color = v_color; }`;
