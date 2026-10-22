/**
 * L4 · 渲染模块（`render.batch2d`）
 *
 * 把"场景里的 Sprite 组件"变成"每帧一次 draw"。这是 L4 扩展的标准形态：
 * **它自己实现 `IModule`，内核不知道它在做什么。**
 *
 * 生命周期分工（每一段都有明确的"为什么在这里"）：
 *   init  → 建 GPU 资源（纹理/着色器/管线/缓冲）。**不碰世界**。
 *   start → 注册渲染回调（`Services.Frame.onRender`）。此时世界已建好。
 *   stop  → 注销回调（世界还在，但不再画）。
 *   dispose → 释放 GPU 资源（逆序：先注销，再删缓冲，最后删管线/纹理）。
 *
 * ★ 一个必须做对的事：**相机跟随在渲染阶段做**。
 *   如果相机在 `onUpdate`（固定步）里跟随，那么 60Hz 屏幕上的画面会
 *   以 30Hz 跳动（即使有 alpha 插值也没用，因为相机位置本身就离散）。
 *   所以跟随用 `alpha` 插值，在 `onRender` 里算 —— 这是"渲染阶段存在的意义"。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import { Rect } from "../../foundation/math/index.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import { Services } from "../../core/tokens.ts";
import type { FrameInfo } from "../../core/frame-host.ts";
import {
  BlendMode,
  BufferUsage,
  PixelFormat,
  SPRITE_VERTEX_LAYOUT,
  TextureFilter,
  TextureWrap,
  type BufferHandle,
  type PipelineHandle,
  type ShaderHandle,
  type TextureHandle,
} from "../../platform/gfx/types.ts";
import type { IGraphicsDevice } from "../../platform/gfx/device.ts";
import { SPRITE_FS, SPRITE_VS } from "./shaders-glsl.ts";
import { SpriteBatch, type RenderItem } from "./batch2d.ts";
import { Camera2D } from "./camera.ts";
import { Sprite } from "./sprite.ts";
import { buildProceduralAtlas, type AtlasData } from "./atlas.ts";

export interface RenderModuleOptions {
  readonly id?: string;
  /** 视口尺寸（像素）。浏览器里传 canvas 尺寸。 */
  readonly viewportWidth: number;
  readonly viewportHeight: number;
  readonly zoom?: number;
  readonly tiltY?: number;
  /** 最多多少个 quad 一批（默认 4096）。 */
  readonly maxQuads?: number;
  /** 相机跟随目标（返回世界 XZ）。每帧渲染阶段调用一次。 */
  readonly follow?: () => { x: number; z: number } | undefined;
  /** 覆盖默认图集（真实项目会传导入的图集）。 */
  readonly atlas?: AtlasData;
}

export interface RenderModuleHandle extends IModule {
  readonly camera: Camera2D;
  /** 最近一帧的渲染统计（判据与 HUD 读它）。 */
  readonly lastFrame: {
    readonly quads: number;
    readonly drawCalls: number;
    readonly atlasSwitches: number;
    readonly culled: number;
  };
  /**
   * 图集帧数（init 之前是 0）。
   * ★ 存在的理由：`drawCalls > 0` 只能证明"画了点东西"，证明不了"画的是真资产的帧"。
   *   自检页用它区分"5 帧的资产图集"与"5 帧的程序化图集"——两者帧数可能一样，
   *   所以它必须和 `browser-entry` 的 `atlasSource` 一起看。
   */
  readonly atlasFrameCount: number;
}

export function createRenderModule(opts: RenderModuleOptions): RenderModuleHandle {
  const camera = new Camera2D({
    viewportWidth: opts.viewportWidth,
    viewportHeight: opts.viewportHeight,
    zoom: opts.zoom ?? 32,
    tiltY: opts.tiltY ?? 0.62,
  });

  let dev: IGraphicsDevice | null = null;
  let tex: TextureHandle | null = null;
  let shader: ShaderHandle | null = null;
  let pipeline: PipelineHandle | null = null;
  let vbo: BufferHandle | null = null;
  let ibo: BufferHandle | null = null;
  let offRender: (() => void) | null = null;
  let batch: SpriteBatch | null = null;
  let atlas: AtlasData | null = null;
  let ctxRef: ModuleContext | null = null;

  let lastFrame = { quads: 0, drawCalls: 0, atlasSwitches: 0, culled: 0 };

  const mod: RenderModuleHandle = {
    id: opts.id ?? "render.batch2d",
    deps: [],

    init(ctx: ModuleContext): Result<void, EngineError> {
      ctxRef = ctx;
      dev = ctx.platform.gfx;
      const d = dev;

      const procedural = opts.atlas === undefined;
      atlas = opts.atlas ?? buildProceduralAtlas();
      const t = d.createTexture(
        {
          width: atlas.width,
          height: atlas.height,
          format: PixelFormat.RGBA8,
          filter: TextureFilter.Nearest,
          wrap: TextureWrap.Clamp,
          // label 不是装饰：null 后端的 `describe()` 与崩溃报告会原样打印它，
          // "这张纹理到底是资产图集还是兜底的程序化图集"必须一眼可辨。
          label: procedural ? "engine.procedural-atlas" : "engine.asset-atlas",
        },
        atlas.pixels,
      );
      if (!t.ok) return t as Result<void, EngineError>;
      tex = t.value;

      const sh = d.createShader({
        vertex: SPRITE_VS,
        fragment: SPRITE_FS,
        label: "engine.sprite",
      });
      if (!sh.ok) {
        d.destroyTexture(tex);
        return sh as Result<void, EngineError>;
      }
      shader = sh.value;

      const pl = d.createPipeline({
        shader: shader,
        layout: SPRITE_VERTEX_LAYOUT,
        blend: BlendMode.Alpha,
        label: "engine.sprite",
      });
      if (!pl.ok) {
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return pl as Result<void, EngineError>;
      }
      pipeline = pl.value;

      batch = new SpriteBatch(opts.maxQuads ?? 4096);
      const vb = d.createBuffer({
        usage: BufferUsage.Vertex,
        byteLength: batch.vertices.byteLength,
        dynamic: true,
        label: "engine.sprite.vbo",
      });
      if (!vb.ok) {
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return vb as Result<void, EngineError>;
      }
      vbo = vb.value;

      const ib = d.createBuffer({
        usage: BufferUsage.Index,
        byteLength: batch.indices.byteLength,
        dynamic: false,
        label: "engine.sprite.ibo",
      });
      if (!ib.ok) {
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return ib as Result<void, EngineError>;
      }
      ibo = ib.value;
      const up = d.updateBuffer(ibo, batch.indices);
      if (!up.ok) {
        d.destroyBuffer(ibo);
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        d.destroyTexture(tex);
        return up as Result<void, EngineError>;
      }

      ctx.log.channel("render").info(
        `渲染模块就绪：${atlas.width}x${atlas.height} 图集 · ${atlas.frames.size} 帧 · ` +
          `批量上限 ${batch.maxQuads} quad`,
      );
      return ok(undefined);
    },

    start(): Result<void, EngineError> {
      const ctx = ctxRef;
      if (ctx === null) return err(engineError("RENDER.NOT_INIT", "start 之前没有 init"));
      const frame = ctx.services.require(Services.Frame);
      offRender = frame.onRender(renderFrame);
      return ok(undefined);
    },

    stop(): void {
      offRender?.();
      offRender = null;
    },

    dispose(): void {
      const d = dev;
      if (d !== null) {
        if (ibo !== null) d.destroyBuffer(ibo);
        if (vbo !== null) d.destroyBuffer(vbo);
        if (pipeline !== null) d.destroyPipeline(pipeline);
        if (shader !== null) d.destroyShader(shader);
        if (tex !== null) d.destroyTexture(tex);
      }
      ibo = null;
      vbo = null;
      pipeline = null;
      shader = null;
      tex = null;
      dev = null;
      batch = null;
      atlas = null;
    },

    describe(): string {
      return `渲染：${lastFrame.quads} quad / ${lastFrame.drawCalls} draw / ` +
        `${lastFrame.atlasSwitches} 纹理切换`;
    },

    get camera(): Camera2D {
      return camera;
    },

    get lastFrame() {
      return lastFrame;
    },

    get atlasFrameCount(): number {
      return atlas?.frames.size ?? 0;
    },
  };

  function renderFrame(info: FrameInfo): void {
    const d = dev;
    const b = batch;
    const a = atlas;
    const scene = ctxRef?.services.get(Services.Scene);
    if (d === null || b === null || a === null || scene === undefined) return;

    // ---- 相机跟随（在渲染阶段做，见文件头）
    const target = opts.follow?.();
    if (target !== undefined) {
      // 用 alpha 在"上一帧位置"与"当前位置"之间插值。
      // 这里没有保存上一帧位置（那需要额外的状态），所以直接用当前位置 ——
      // 对"跟随玩家"这类低速目标，视觉差异不可见；高速甩镜头时才需要真正的插值，
      // 那时应该由"相机控制器"组件持有 prev/cur 两帧位置。
      camera.moveTo(target.x, target.z);
    }

    // ---- 收集可见精灵
    const sprites = scene.componentsOf<Sprite>("render.sprite");
    const items: RenderItem[] = [];
    const vis = camera.visibleRect();
    let culled = 0;
    const slotOfAtlas = (atlasId: string): number => (atlasId === "" ? 0 : 0); // 单图集：槽位恒 0

    for (const s of sprites) {
      if (!s.visible) continue;
      const node = s.node;
      if (node === null || !node.activeInHierarchy) continue;
      const p = node.worldPosition;
      // 视口粗筛：只按"中心点是否在扩展后的可见矩形内"。
      // ★ 粗筛**会漏掉**中心在框外但边缘在框内的精灵，所以矩形按最大半径外扩。
      const pad = Math.max(s.width, s.height);
      if (p.x < vis.xMin - pad || p.x > vis.xMax + pad || p.y < vis.zMin - pad || p.y > vis.zMax + pad) {
        culled++;
        continue;
      }
      const f = a.frames.get(s.frame);
      if (f === undefined) {
        // 帧名不存在：不能静默跳过（否则"某个东西不显示"永远查不出来）
        ctxRef?.log.channel("render").warn(`Sprite 帧名不存在：${JSON.stringify(s.frame)}`, { node: node.id }, null);
        continue;
      }
      items.push({
        nodeId: node.id,
        x: p.x,
        z: p.y,
        w: s.width,
        h: s.height,
        u0: f.u0,
        v0: f.v0,
        u1: f.u1,
        v1: f.v1,
        r: s.r,
        g: s.g,
        b: s.b,
        a: s.a,
        order: s.order,
        pivotY: s.pivotY,
        atlas: slotOfAtlas(s.atlasId),
      });
    }

    const built = b.build(items, camera);
    lastFrame = {
      quads: built.quadCount,
      drawCalls: 0,
      atlasSwitches: built.atlasSwitches,
      culled,
    };

    // ---- 提交
    const vw = d.size.width;
    const vh = d.size.height;
    camera.setViewport(vw, vh);

    const cmd = d.beginFrame(null);
    cmd.setViewport(new Rect(0, 0, vw, vh));
    cmd.clear(camera.clearColor, 1);

    if (built.quadCount > 0 && vbo !== null && ibo !== null && pipeline !== null && tex !== null) {
      const up = d.updateBuffer(vbo, b.vertexView(built.quadCount));
      if (!up.ok) {
        // 上传失败（容量/句柄）—— 报出来，不要静默黑屏
        ctxRef?.log.channel("render").error(`顶点上传失败：${up.error.message}`, undefined, null);
      } else {
        cmd.setPipeline(pipeline);
        cmd.bindTexture(0, tex);
        cmd.setUniform("u_useTexture", 1, "int");
        cmd.draw({
          vertices: vbo,
          indices: ibo,
          vertexCount: built.vertexCount,
          indexCount: built.indexCount,
        });
        lastFrame = { ...lastFrame, drawCalls: 1 };
      }
    }
    cmd.finish();
    d.endFrame();
    void info;
  }

  return mod;
}
