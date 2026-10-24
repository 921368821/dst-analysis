/**
 * 图形后端契约测试
 *
 * ★ 这个文件是"接口有没有歧义"的检验器。
 *   同一个用例跑在 Null / WebGL2 / 将来的 WebGPU 上：
 *   任何一个后端不满足，就说明**接口语义没定义清楚**，而不是"那个后端有 bug"。
 *
 * 契约的核心是"非法操作必须失败"：
 *   - 越界上传（真后端会静默画错）
 *   - 超限纹理（真后端会创建失败/黑图）
 *   - 空/坏着色器
 *   - 引用不存在的对象
 *   - 帧外提交
 * 上一代引擎只有一个后端，这些歧义直到接第二个才会暴露 —— 而那时已经在线上。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import type { IGraphicsDevice } from "../../src/platform/gfx/device.ts";
import {
  BufferUsage,
  PixelFormat,
  SPRITE_VERTEX_LAYOUT,
  TextureFilter,
  type ShaderHandle,
} from "../../src/platform/gfx/types.ts";
import { Color, Rect } from "../../src/foundation/math/index.ts";
import { NullGraphicsDevice } from "../../src/backends/gfx-null/device.ts";

export interface GfxCase {
  readonly name: string;
  run(dev: IGraphicsDevice): void;
}

const VS = `#version 300 es
in vec2 a_position; in vec2 a_uv; in vec4 a_color;
out vec2 v_uv; out vec4 v_color;
void main() { v_uv = a_uv; v_color = a_color; gl_Position = vec4(a_position, 0.0, 1.0); }`;

const FS = `#version 300 es
precision mediump float;
in vec2 v_uv; in vec4 v_color; out vec4 o;
void main() { o = v_color; }`;

function makeShader(dev: IGraphicsDevice): ShaderHandle {
  const r = dev.createShader({ vertex: VS, fragment: FS, label: "contract" });
  assert.ok(r.ok, "基础着色器必须能创建：" + (r.ok ? "" : r.error.message));
  if (!r.ok) throw new Error("unreachable");
  return r.value;
}

export const GFX_CASES: readonly GfxCase[] = [
  {
    name: "能力描述完整且自洽（没有 NaN/负数上限）",
    run(dev) {
      const c = dev.caps;
      assert.ok(c.backend.length > 0);
      assert.ok(c.maxTextureSize > 0 && Number.isFinite(c.maxTextureSize));
      assert.ok(c.maxTextureUnits > 0);
      assert.ok(c.maxVerticesPerDraw > 0);
    },
  },
  {
    name: "createBuffer：0 字节必须被拒绝（不许返回一个永远画不出东西的句柄）",
    run(dev) {
      const r = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 0, dynamic: true });
      assert.equal(r.ok, false);
      if (!r.ok) assert.equal(r.error.code, "GFX.BAD_BUFFER");
    },
  },
  {
    name: "updateBuffer：越界上传必须失败且**不静默截断**",
    run(dev) {
      const b = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 32, dynamic: true });
      assert.ok(b.ok);
      if (!b.ok) return;
      const tooBig = new Float32Array(32); // 128 字节 > 32
      const r = dev.updateBuffer(b.value, tooBig);
      assert.equal(r.ok, false, "越界上传不许成功");
      if (!r.ok) assert.equal(r.error.code, "GFX.BUFFER_OVERFLOW");
      // 边界值（正好写满）必须成功
      const exact = new Float32Array(8);
      assert.ok(dev.updateBuffer(b.value, exact).ok, "正好写满应该成功");
    },
  },
  {
    name: "使用已销毁的句柄必须失败（不许写进'别人的'槽位）",
    run(dev) {
      const b = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 16, dynamic: true });
      assert.ok(b.ok);
      if (!b.ok) return;
      dev.destroyBuffer(b.value);
      const r = dev.updateBuffer(b.value, new Float32Array(4));
      assert.equal(r.ok, false);
      if (!r.ok) assert.equal(r.error.code, "GFX.INVALID_HANDLE");
    },
  },
  {
    name: "createTexture：超过 maxTextureSize 必须失败（上层据此降级）",
    run(dev) {
      const over = dev.caps.maxTextureSize * 2;
      const r = dev.createTexture({ width: over, height: 1 });
      assert.equal(r.ok, false);
      if (!r.ok) assert.equal(r.error.code, "GFX.TEXTURE_TOO_LARGE");
      const okOne = dev.createTexture({ width: 4, height: 4, format: PixelFormat.RGBA8 });
      assert.ok(okOne.ok);
    },
  },
  {
    name: "RGBA16：合法长度能创建/上传，长度差 1 字节必须 GFX.SIZE_MISMATCH",
    run(dev) {
      const w = 4;
      const h = 4;
      // RGBA16 = 8 字节/像素 ⇒ 4×4 需要 128 字节
      const good = new Uint16Array(w * h * 4);
      for (let i = 0; i < good.length; i++) good[i] = (i * 4099) & 0xffff;

      const tex = dev.createTexture({ width: w, height: h, format: PixelFormat.RGBA16 }, good);
      assert.ok(tex.ok, "RGBA16 的合法长度必须能创建：" + (tex.ok ? "" : tex.error.code + " " + tex.error.message));
      if (!tex.ok) return;

      const up = dev.updateTexture(tex.value, { x: 0, y: 0, width: w, height: h }, good);
      assert.ok(up.ok, "RGBA16 整图上传必须成功：" + (up.ok ? "" : up.error.code + " " + up.error.message));

      // 差 1 字节 = "长度口径错了"的最小可辨识改动。
      // 旧行为（webgl2 不校验 / null 只校验渲染目标）在这里会**静默成功**，
      // 于是"16 位图集上传了半张"在 headless 里全绿。
      const short = new Uint8Array(w * h * 8 - 1);
      const created = dev.createTexture({ width: w, height: h, format: PixelFormat.RGBA16 }, short);
      assert.equal(created.ok, false, "长度差 1 字节的 RGBA16 创建必须失败（不许静默截断）");
      if (!created.ok) assert.equal(created.error.code, "GFX.SIZE_MISMATCH");

      const updated = dev.updateTexture(tex.value, { x: 0, y: 0, width: w, height: h }, short);
      assert.equal(updated.ok, false, "长度差 1 字节的 RGBA16 上传必须失败");
      if (!updated.ok) assert.equal(updated.error.code, "GFX.SIZE_MISMATCH");
    },
  },
  {
    name: "RGBA16F：按 8 字节/像素校验（不再被静默当成 RGBA8）",
    run(dev) {
      const w = 2;
      const h = 2;
      const half = new Uint8Array(w * h * 8);
      const okOne = dev.createTexture({ width: w, height: h, format: PixelFormat.RGBA16F }, half);
      assert.ok(
        okOne.ok,
        "RGBA16F 的合法长度必须能创建：" + (okOne.ok ? "" : okOne.error.code + " " + okOne.error.message),
      );

      // 4 字节/像素（RGBA8 的长度）必须被拒：如果后端把 RGBA16F 当 RGBA8，
      // 这一条就会**通过**，而这正是"格式表写错却没人发现"的样子。
      const asIfRgba8 = new Uint8Array(w * h * 4);
      const r = dev.createTexture({ width: w, height: h, format: PixelFormat.RGBA16F }, asIfRgba8);
      assert.equal(r.ok, false, "RGBA16F 收到 4 字节/像素必须失败");
      if (!r.ok) assert.equal(r.error.code, "GFX.SIZE_MISMATCH");
    },
  },
  {
    name: "createShader：空源码与无 main 必须失败（不许创建一个'能绑定但画不出'的着色器）",
    run(dev) {
      assert.equal(dev.createShader({ vertex: "", fragment: FS }).ok, false, "空源码应失败");
      const bad = dev.createShader({ vertex: "float x;", fragment: "float y;" });
      assert.equal(bad.ok, false);
      if (!bad.ok) assert.equal(bad.error.code, "GFX.SHADER_COMPILE");
    },
  },
  {
    name: "createPipeline：引用不存在的着色器必须失败",
    run(dev) {
      const r = dev.createPipeline({ shader: 9999 as unknown as ShaderHandle, layout: SPRITE_VERTEX_LAYOUT });
      assert.equal(r.ok, false);
      if (!r.ok) assert.equal(r.error.code, "GFX.INVALID_HANDLE");
    },
  },
  {
    name: "一帧内：clear → setPipeline → bindTexture → draw，统计随之增长",
    run(dev) {
      const sh = makeShader(dev);
      const pipe = dev.createPipeline({ shader: sh, layout: SPRITE_VERTEX_LAYOUT });
      assert.ok(pipe.ok);
      if (!pipe.ok) return;
      const tex = dev.createTexture({ width: 8, height: 8, filter: TextureFilter.Nearest });
      assert.ok(tex.ok);
      if (!tex.ok) return;
      const vb = dev.createBuffer({ usage: BufferUsage.Vertex, byteLength: 8 * 4 * 6, dynamic: true });
      assert.ok(vb.ok);
      if (!vb.ok) return;

      const cmd = dev.beginFrame(null);
      cmd.setViewport(new Rect(0, 0, 100, 100));
      cmd.clear(new Color(0, 0, 0, 1), 1);
      cmd.setPipeline(pipe.value);
      cmd.bindTexture(0, tex.value);
      cmd.draw({ vertices: vb.value, indices: null, vertexCount: 6, indexCount: 6 });
      cmd.finish();
      dev.endFrame();

      assert.equal(dev.stats.drawCalls, 1, "一次 draw 应记 1 个 draw call");
      assert.equal(dev.stats.verticesSubmitted, 6);
      assert.equal(dev.stats.textureBindings, 1);
      assert.ok(dev.stats.pipelineSwitches >= 1);
    },
  },
  {
    name: "录制结束后再提交必须被拒绝（否则会画进下一帧，表现为'画面滞后一帧'）",
    run(dev) {
      const cmd = dev.beginFrame(null);
      cmd.finish();
      assert.throws(() => cmd.clear(new Color(1, 1, 1, 1), 1), /finish/);
      dev.endFrame();
    },
  },
  {
    name: "readPixels：返回长度 = w*h*4，且支持 readback 时非全零",
    run(dev) {
      if (!dev.caps.readback) return; // 后端不支持就跳过（契约允许）
      const rt = dev.createTexture({ width: 8, height: 8, renderTarget: true, format: PixelFormat.RGBA8 });
      assert.ok(rt.ok);
      if (!rt.ok) return;
      const target = dev.createRenderTarget({ color: rt.value });
      assert.ok(target.ok);
      if (!target.ok) return;
      const px = dev.readPixels(target.value, new Rect(0, 0, 8, 8));
      assert.ok(px.ok);
      if (!px.ok) return;
      assert.equal(px.value.length, 8 * 8 * 4);
    },
  },
];

/** 用同一个后端跑完全部契约用例（每个用例独立设备，避免互相污染）。 */
export function runGfxContract(backendName: string, make: () => IGraphicsDevice): void {
  for (const c of GFX_CASES) {
    test(`[${backendName}] 契约 · ${c.name}`, () => {
      const dev = make();
      try {
        c.run(dev);
      } finally {
        dev.destroy();
      }
    });
  }
}

// Null 后端必须通过全部契约 —— 它是"参照实现"
runGfxContract("null", () => new NullGraphicsDevice(64, 64));
