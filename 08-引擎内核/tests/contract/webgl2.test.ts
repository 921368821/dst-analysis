/**
 * WebGL2 后端契约（用假 GL）
 *
 * 这里的断言分两层，**边界必须说清**：
 *   ① 通用契约（`runGfxContract`）：证明 webgl2 与 null 的**语义一致**；
 *   ② 专属断言：证明 webgl2 真的把调用**按 GL 的方式**发出去了
 *      （attribute stride/offset、状态缓存、program 级状态重放）。
 *
 * ⚠️ 假 GL 只能证明"我们发了什么调用、参数对不对"。
 *    它**不能**证明"WebGL2 会接受这些调用"（驱动差异、精度、扩展）。
 *    那部分由浏览器端到端（`web/index.html` + `readPixels`）负责。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { GL2Device } from "../../src/backends/gfx-webgl2/device.ts";
import { FakeGL2 } from "./fake-gl.ts";
import { runGfxContract } from "./gfx.contract.ts";
import {
  BlendMode,
  BufferUsage,
  SPRITE_VERTEX_LAYOUT,
  Topology,
  type BlendModeValue,
  type PipelineHandle,
  type ShaderHandle,
} from "../../src/platform/gfx/types.ts";
import { GL } from "../../src/backends/gfx-webgl2/gl2.ts";
import { Color, Rect } from "../../src/foundation/math/index.ts";

// ① 通用契约：与 null 后端跑**同一套**用例
runGfxContract("webgl2(fake)", () => new GL2Device(new FakeGL2()));

// ② 专属断言

test("[webgl2] 顶点属性布局：stride 32，position@0 / uv@8 / color@16", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const sh = dev.createShader({ vertex: "void main(){}", fragment: "void main(){}" });
  assert.ok(sh.ok);
  if (!sh.ok) return;
  const pipe = dev.createPipeline({ shader: sh.value, layout: SPRITE_VERTEX_LAYOUT });
  assert.ok(pipe.ok);
  if (!pipe.ok) return;
  const vb = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 32 * 4, dynamic: true });
  const ib = dev.createBuffer({ usage: BufferUsage.Index, byteLength: 6 * 2, dynamic: false });
  assert.ok(vb.ok && ib.ok);
  if (!vb.ok || !ib.ok) return;

  const cmd = dev.beginFrame(null);
  cmd.setPipeline(pipe.value);
  cmd.draw({ vertices: vb.value, indices: ib.value, vertexCount: 4, indexCount: 6 });
  cmd.finish();
  dev.endFrame();

  const attrs = gl.state.attribs;
  assert.equal(attrs.size, 3, "应设置 3 个顶点属性");
  const a0 = attrs.get(0)!;
  const a1 = attrs.get(1)!;
  const a2 = attrs.get(2)!;
  assert.deepEqual([a0.size, a0.stride, a0.offset], [2, 32, 0], "position: 2 float @0, stride 32");
  assert.deepEqual([a1.size, a1.stride, a1.offset], [2, 32, 8], "uv: 2 float @8");
  assert.deepEqual([a2.size, a2.stride, a2.offset], [4, 32, 16], "color: 4 float @16");
  assert.equal(gl.state.drawElementsCount, 1);
  assert.equal(gl.count("drawElements"), 1);
});

test("[webgl2] 状态缓存：同一 pipeline 连设两次只 useProgram 一次", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const sh = dev.createShader({ vertex: "void main(){}", fragment: "void main(){}" });
  assert.ok(sh.ok);
  if (!sh.ok) return;
  const pipe = dev.createPipeline({ shader: sh.value });
  assert.ok(pipe.ok);
  if (!pipe.ok) return;

  const cmd = dev.beginFrame(null);
  // beginFrame 会把缓存清空（新的一帧），所以先设一次记数
  cmd.setPipeline(pipe.value);
  const after1 = gl.count("useProgram");
  cmd.setPipeline(pipe.value);
  cmd.setPipeline(pipe.value);
  const after3 = gl.count("useProgram");
  cmd.finish();
  dev.endFrame();

  assert.equal(after1, 1, "第一次设置应真的 useProgram");
  assert.equal(after3, 1, `重复设置同一管线不应重复 useProgram（否则 pipelineSwitches 会虚高）；实际 ${after3}`);
  assert.equal(dev.stats.pipelineSwitches, 1);
});

test("[webgl2] 换 pipeline 后重放 **uniform**（program 状态），但不重放纹理（context 状态）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const sh1 = dev.createShader({ vertex: "void main(){}", fragment: "void main(){}" });
  const sh2 = dev.createShader({ vertex: "void main(){}", fragment: "void main(){}" });
  assert.ok(sh1.ok && sh2.ok);
  if (!sh1.ok || !sh2.ok) return;
  const p1 = dev.createPipeline({ shader: sh1.value });
  const p2 = dev.createPipeline({ shader: sh2.value });
  assert.ok(p1.ok && p2.ok);
  if (!p1.ok || !p2.ok) return;
  const tex = dev.createTexture({ width: 4, height: 4 });
  assert.ok(tex.ok);
  if (!tex.ok) return;

  const cmd = dev.beginFrame(null);
  cmd.setPipeline(p1.value);
  cmd.setUniform("u_useTexture", 1, "int");
  cmd.bindTexture(0, tex.value);
  const uniBefore = gl.count("uniform1i");
  const bindBefore = gl.count("bindTexture");
  cmd.setPipeline(p2.value);
  const uniAfter = gl.count("uniform1i");
  const bindAfter = gl.count("bindTexture");
  cmd.finish();
  dev.endFrame();

  assert.ok(
    uniAfter > uniBefore,
    `换 program 后必须重放 uniform（sampler 指向哪个 unit 是 program 状态）；${uniBefore} → ${uniAfter}`,
  );
  assert.equal(
    bindAfter,
    bindBefore,
    `纹理绑定是 context 状态，换 program 不该重绑；${bindBefore} → ${bindAfter}`,
  );
});

test("[webgl2] 编译失败返回 GFX.SHADER_COMPILE 且带 infoLog（不返回半成品）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const r = dev.createShader({ vertex: "FAIL", fragment: "void main(){}" });
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "GFX.SHADER_COMPILE");
    assert.match(r.error.message, /假编译错误|编译失败/);
  }
  // 失败后不该留下可用的 program
  assert.equal(gl.count("linkProgram"), 0, "编译失败不该走到 linkProgram");
});

test("[webgl2] draw 之前没 setPipeline ⇒ 抛（不许静默少画东西）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const vb = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 128, dynamic: true });
  assert.ok(vb.ok);
  if (!vb.ok) return;
  const cmd = dev.beginFrame(null);
  assert.throws(
    () => cmd.draw({ vertices: vb.value, indices: null, vertexCount: 4, indexCount: 6 }),
    /setPipeline/,
  );
  cmd.finish();
  dev.endFrame();
});

test("[webgl2] 清屏与视口在帧内生效，stats 每帧重置", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const cmd = dev.beginFrame(null);
  cmd.setViewport(new Rect(0, 0, 800, 600));
  cmd.clear(new Color(0.1, 0.2, 0.3, 1), 1);
  cmd.finish();
  dev.endFrame();
  assert.deepEqual(gl.state.viewport, [0, 0, 800, 600]);
  assert.equal(gl.count("clear"), 1);
  assert.equal(dev.stats.drawCalls, 0, "新的一帧 stats 应重置");
});

test("[webgl2] 纹理尺寸超限：失败在**创建设备资源时**，不是等到画的时候", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const r = dev.createTexture({ width: 9999, height: 8 });
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "GFX.TEXTURE_TOO_LARGE");
});

test("[webgl2] readPixels 走假 GL 的图案（区分'读到了'与'全零'）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const px = dev.readPixels(null, new Rect(0, 0, 2, 2));
  assert.ok(px.ok);
  if (!px.ok) return;
  assert.equal(px.value.length, 16);
  assert.equal(px.value[0], 11);
  assert.equal(px.value[3], 255);
});

test("[webgl2] 销毁后再用句柄 ⇒ 失败（句柄表已清）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const b = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 16, dynamic: true });
  assert.ok(b.ok);
  if (!b.ok) return;
  dev.destroyBuffer(b.value);
  const r = dev.updateBuffer(b.value, new Float32Array(4));
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, "GFX.INVALID_HANDLE");
});

/**
 * ★★ 这条判据补的是一个**跨层的洞**（批66 实地栽过一次）：
 *
 *   `render-tile.test.ts` 断言的是"渲染模块**传了** `firstIndex`"（读 null 后端的记录），
 *   而"真后端有没有**用它**"是另一件事 —— 两者之间没人验。webgl2 的 `draw` 曾把
 *   `drawElements` 的 offset 写死成 0，于是多页渲染的第二段永远从索引 0 开始：
 *   地形段（116 quad）+ 实体段（101 quad）两段都画开头的地形，画面被一整块纯色盖住，
 *   而 `drawCalls / 顶点数 / 纹理绑定 / firstIndex 传参` 全都"对"。
 *
 *   ★ 所以断言的粒度必须是**每次调用的 offset**，而不是"有没有调 drawElements"。
 *     顺带把"索引个数 → 字节数"的换算也钉住：`UNSIGNED_SHORT` 是 2 字节，
 *     传 `firstIndex` 原值会在 6 个 quad 之后才错，肉眼查起来极难。
 */
test("[webgl2] 多段绘制：每段从自己的索引起点画（offset = firstIndex × 2 字节）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const sh = dev.createShader({ vertex: "void main(){}", fragment: "void main(){}" });
  assert.ok(sh.ok);
  if (!sh.ok) return;
  const pipe = dev.createPipeline({ shader: sh.value, layout: SPRITE_VERTEX_LAYOUT });
  assert.ok(pipe.ok);
  if (!pipe.ok) return;
  const vb = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 4096, dynamic: true });
  const ib = dev.createBuffer({ usage: BufferUsage.Index, byteLength: 2048, dynamic: false });
  assert.ok(vb.ok && ib.ok);
  if (!vb.ok || !ib.ok) return;

  const cmd = dev.beginFrame(null);
  cmd.setPipeline(pipe.value);
  // 第 1 段：116 个 quad（地形），从索引 0
  cmd.draw({ vertices: vb.value, indices: ib.value, vertexCount: 116 * 4, indexCount: 116 * 6, firstIndex: 0 });
  // 第 2 段：101 个 quad（实体），从第 116*6 个索引开始
  cmd.draw({ vertices: vb.value, indices: ib.value, vertexCount: 217 * 4, indexCount: 101 * 6, firstIndex: 116 * 6 });
  cmd.finish();
  dev.endFrame();

  const calls = gl.calls.filter((c) => c.name === "drawElements");
  assert.equal(calls.length, 2, "两段应各发一次 drawElements");
  assert.deepEqual(
    [calls[0]!.args[1], calls[0]!.args[3]],
    [116 * 6, 0],
    `第 1 段：count=${116 * 6} 索引、offset=0；实际 ${JSON.stringify(calls[0]!.args)}`,
  );
  assert.deepEqual(
    [calls[1]!.args[1], calls[1]!.args[3]],
    [101 * 6, 116 * 6 * 2],
    `第 2 段的 offset 必须是 116*6 个索引 × 2 字节 = ${116 * 6 * 2}；` +
      `写成 0 会把第 1 段的地形再画一遍（画面被纯色盖住，而所有计数都对）。实际 ${JSON.stringify(calls[1]!.args)}`,
  );
});

test("[webgl2] 无索引绘制：firstIndex 解释成顶点起点，不许静默忽略", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const sh = dev.createShader({ vertex: "void main(){}", fragment: "void main(){}" });
  assert.ok(sh.ok);
  if (!sh.ok) return;
  const pipe = dev.createPipeline({ shader: sh.value, layout: SPRITE_VERTEX_LAYOUT });
  assert.ok(pipe.ok);
  if (!pipe.ok) return;
  const vb = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 4096, dynamic: true });
  assert.ok(vb.ok);
  if (!vb.ok) return;

  const cmd = dev.beginFrame(null);
  cmd.setPipeline(pipe.value);
  cmd.draw({ vertices: vb.value, indices: null, vertexCount: 4, indexCount: 6, firstIndex: 8 });
  cmd.finish();
  dev.endFrame();

  const calls = gl.calls.filter((c) => c.name === "drawArrays");
  assert.equal(calls.length, 1);
  assert.equal(calls[0]!.args[1], 8, `drawArrays 的 first 应是 8；实际 ${calls[0]!.args[1]}`);
});

/**
 * ★ 与 `firstIndex` 同一类缺陷的另一半（批66 系统性排查的产物）：
 *   `PipelineDesc.blend` 被存进管线记录，却从没被落到 GL 上 ——
 *   设备初始化时写死的一次 `blendFunc(SRC_ALPHA, ONE_MINUS_SRC_ALPHA)` 覆盖了所有管线。
 *   于是 `None / Additive / Premultiplied` 全部静默退化成 Alpha：不报错、数量全对、
 *   只是叠加不发光、该不透明的变半透。断言落在**具体 blendFunc 参数**上才算数。
 */
test("[webgl2] 管线的 blend 必须真的落到 GL（不透明/叠加/预乘不能退化成 Alpha）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const sh = dev.createShader({ vertex: "void main(){}", fragment: "void main(){}" });
  assert.ok(sh.ok);
  if (!sh.ok) return;

  const mk = (blend: BlendModeValue) => {
    const p = dev.createPipeline({ shader: sh.value, layout: SPRITE_VERTEX_LAYOUT, blend });
    assert.ok(p.ok);
    return p.ok ? p.value : null;
  };
  const opaque = mk(BlendMode.None);
  const additive = mk(BlendMode.Additive);
  const premul = mk(BlendMode.Premultiplied);
  assert.ok(opaque !== null && additive !== null && premul !== null);
  if (opaque === null || additive === null || premul === null) return;

  const cmd = dev.beginFrame(null);
  cmd.setPipeline(opaque);
  // 只数 `disable(GL.BLEND)`：`disable` 还会被 SCISSOR_TEST 用到（那是别的事）
  const blendDisabled = () => gl.calls.filter((c) => c.name === "disable" && c.args[0] === GL.BLEND).length;
  const disabledAfterOpaque = blendDisabled();
  cmd.setPipeline(additive);
  const additiveFunc = gl.calls.filter((c) => c.name === "blendFunc").at(-1);
  cmd.setPipeline(premul);
  const premulFunc = gl.calls.filter((c) => c.name === "blendFunc").at(-1);
  cmd.finish();
  dev.endFrame();

  assert.equal(disabledAfterOpaque, 1, "BlendMode.None 必须真的 disable(BLEND)，而不是只改 blendFunc");
  assert.deepEqual(
    [additiveFunc?.args[0], additiveFunc?.args[1]],
    [GL.SRC_ALPHA, GL.ONE],
    `Additive 应是 (SRC_ALPHA, ONE)；实际 ${JSON.stringify(additiveFunc?.args)}`,
  );
  assert.deepEqual(
    [premulFunc?.args[0], premulFunc?.args[1]],
    [GL.ONE, GL.ONE_MINUS_SRC_ALPHA],
    `Premultiplied 应是 (ONE, ONE_MINUS_SRC_ALPHA)；实际 ${JSON.stringify(premulFunc?.args)}`,
  );
});

test("[webgl2] 管线的 topology 必须真的落到 draw 的 mode（三角带不能当独立三角画）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);
  const sh = dev.createShader({ vertex: "void main(){}", fragment: "void main(){}" });
  assert.ok(sh.ok);
  if (!sh.ok) return;
  const strip = dev.createPipeline({
    shader: sh.value,
    layout: SPRITE_VERTEX_LAYOUT,
    topology: Topology.TriangleStrip,
  });
  assert.ok(strip.ok);
  if (!strip.ok) return;
  const vb = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 4096, dynamic: true });
  assert.ok(vb.ok);
  if (!vb.ok) return;

  const cmd = dev.beginFrame(null);
  cmd.setPipeline(strip.value);
  cmd.draw({ vertices: vb.value, indices: null, vertexCount: 4, indexCount: 6 });
  cmd.finish();
  dev.endFrame();

  const calls = gl.calls.filter((c) => c.name === "drawArrays");
  assert.equal(calls.length, 1);
  assert.equal(
    calls[0]!.args[0],
    GL.TRIANGLE_STRIP,
    `TriangleStrip 管线的 drawArrays mode 应是 TRIANGLE_STRIP(0x0005)；实际 ${calls[0]!.args[0]}`,
  );
});

// 让未使用的 import 有归属（tape 类型收窄用）
void (0 as unknown as PipelineHandle);
void (0 as unknown as ShaderHandle);
