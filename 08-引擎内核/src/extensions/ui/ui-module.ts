/**
 * L4 · UI 模块（把字体、布局、控件、事件、渲染接成一块）
 *
 * ★★ 与 2.5D 场景的集成方式：**共用一次 pass、共用一个批处理器、只换一个相机**。
 *
 *   · 世界的绘制由 `render.batch2d` 在 `beginFrame … endFrame` 之间完成；
 *     UI 通过 `setOverlay` 挂在**同一个 pass 的尾部**，世界之后。
 *   · 两者用同一个 `SpriteBatch`（同一套顶点格式、同一套分批规则），
 *     但各自的 `Camera2D`：世界相机做 2.5D 投影（zoom = 每单位像素数，tiltY = 0.62），
 *     UI 相机是**纯 2D**（zoom = 设计→屏幕缩放，tiltY = 1，世界单位 = 设计像素）。
 *     `Camera2D` 本来只是一条投影函数，给它两组参数就能服务两种坐标 —— 不需要第二套管线。
 *   · 于是"UI 盖住世界"不是靠调 z 值，而是靠**同一个 pass 里后画**。
 *     靠 z 值的话，世界相机一移动，UI 就会跟着跑或被裁。
 *
 * ★ 为什么 UI 不能自己 `beginFrame`：pass 开头会 `clear`，第二个 pass 会把世界擦掉。
 *   详见 `render-module.ts` 里 `setOverlay` 的注释。
 *
 * ★ 纹理所有权：`pages` 由宿主创建并持有，本模块**只绑不销毁**。
 *   一个模块销毁它没创建的 GPU 资源，会在"换皮 / 重载 UI 图集"时把世界的纹理一起带走 ——
 *   而错误发生在很久以后（下一次用那张纹理时），根本追不回来。
 */

import type { Rect } from "../../foundation/math/index.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { IModule, ModuleContext } from "../../core/module/module.ts";
import {
  BlendMode,
  BufferUsage,
  SPRITE_VERTEX_LAYOUT,
  TextureFilter,
  TextureWrap,
  type BufferHandle,
  type PipelineHandle,
  type ShaderHandle,
  type TextureHandle,
} from "../../platform/gfx/types.ts";
import type { ICommandList, IGraphicsDevice } from "../../platform/gfx/device.ts";
import { SPRITE_FS, SPRITE_VS } from "../render/shaders-glsl.ts";
import { SpriteBatch, type RenderItem } from "../render/batch2d.ts";
import type { RenderModuleHandle } from "../render/render-module.ts";
import { FontRegistry, type BitmapFont } from "./font.ts";
import { UiViewport, type UiViewportConfig } from "./viewport.ts";
import { buildUiQuads, TextCache, type UiDrawStats, type UiSkin } from "./widgets.ts";
import { layoutTree, UiNode, type UiLayoutResult } from "./layout.ts";
import { UiInputRouter, type UiEvent, type UiEventSink, type UiPointer } from "./events.ts";

/** 默认依赖的渲染模块 id（`createRenderModule` 的默认 id）。 */
export const RENDER_MODULE_ID = "render.batch2d";

/**
 * 一页 UI 纹理的**数据**（不是句柄）。
 *
 * ★ 为什么需要这条路：`createUiModule` 发生在 `bootGameApp` **之前** ——
 *   那时 `platform.gfx` 还不存在，宿主拿不到 `TextureHandle`。
 *   渲染模块的图集就是同样的处境（它接受 `atlas` 数据、在自己的 `init` 里建纹理），
 *   UI 走同一条路，宿主就不必为了"先建两张贴图"把 boot 拆成两段。
 *   给了 `pageSources` 时纹理归**模块**所有，`dispose` 会销毁；
 *   给 `pages`（现成句柄）时归宿主所有，`dispose` 不碰它们。
 */
export interface UiPageSource {
  readonly name: string;
  readonly width: number;
  readonly height: number;
  /** RGBA8 行主序，原点左上（与 `DecodedPng.pixels` 同格式）。 */
  readonly pixels: Uint8Array;
}

export interface UiModuleOptions {
  readonly id?: string;
  readonly viewport: UiViewportConfig;
  readonly skin: UiSkin;
  /**
   * 现成的页 → 纹理，下标必须与 `skin.frames[].page` 和字形 `glyph.page` 一致。
   * 所有权归宿主：本模块 dispose 时**不销毁**它们。与 `pageSources` 二选一。
   */
  readonly pages?: readonly TextureHandle[];
  /** 由模块自己建纹理的页数据（boot 之前没有 device 时用这条）。与 `pages` 二选一。 */
  readonly pageSources?: readonly UiPageSource[];
  /** 至少一个字。 */
  readonly fonts: readonly BitmapFont[];
  readonly root?: UiNode;
  readonly maxQuads?: number;
  /** 物理像素 / CSS 像素。浏览器里传 `devicePixelRatio`，Node 里 1。 */
  readonly dpr?: number;
  readonly dragThreshold?: number;
  readonly onEvent?: UiEventSink;
}

export interface UiFrameStats {
  readonly quads: number;
  readonly drawCalls: number;
  readonly glyphs: number;
  readonly labels: number;
  readonly cacheHits: number;
  readonly missingGlyphs: readonly number[];
  readonly missingFrames: readonly string[];
  /** 本帧是否真的重排过（false = 复用了上一帧的结果）。 */
  readonly relaid: boolean;
}

export interface UiModuleHandle extends IModule {
  readonly viewport: UiViewport;
  readonly fonts: FontRegistry;
  readonly root: UiNode;
  /** 换一棵 UI 树（换界面）。会重建命中路由并标脏。 */
  setRoot(node: UiNode): void;
  /** 宿主每帧推一次指针（**设计坐标**，用 `viewport.screenToDesign()` 换）。 */
  pointer(p: UiPointer): UiEvent[];
  /** 属性改过之后调用（下一帧重排）。文本缓存一并失效。 */
  invalidate(): void;
  /** 立即重排一次（不等下一帧）。判据与编辑器用。 */
  relayout(): void;
  readonly lastFrame: UiFrameStats;
  /** 最近一次布局结果：节点 id → 绝对矩形。 */
  readonly layout: UiLayoutResult;
}

export function createUiModule(opts: UiModuleOptions): UiModuleHandle {
  const dpr = opts.dpr ?? 1;
  const viewport = new UiViewport(opts.viewport);
  const fonts = new FontRegistry();
  for (const f of opts.fonts) fonts.register(f);
  const cache = new TextCache();
  const skin = opts.skin;
  const hostPages = opts.pages;
  const pageSources = opts.pageSources;
  /** init 里由本模块创建的纹理（dispose 时销毁）；宿主传句柄时这里恒为空。 */
  let ownPages: TextureHandle[] = [];
  let pages: readonly TextureHandle[] = hostPages ?? [];

  let root: UiNode = opts.root ?? new UiNode({ id: "ui.root" });
  let router = new UiInputRouter(root, { dragThreshold: opts.dragThreshold });
  let dev: IGraphicsDevice | null = null;
  let ctxRef: ModuleContext | null = null;
  let shader: ShaderHandle | null = null;
  let pipeline: PipelineHandle | null = null;
  let batch: SpriteBatch | null = null;
  let vbo: BufferHandle | null = null;
  let ibo: BufferHandle | null = null;
  let offRender: (() => void) | null = null;

  let dirty = true;
  let lastPw = -1;
  let lastPh = -1;
  let quads: readonly RenderItem[] = [];
  let drawStats: UiDrawStats = {
    quads: 0,
    glyphs: 0,
    labels: 0,
    cacheHits: 0,
    missingGlyphs: [],
    missingFrames: [],
  };
  let layoutResult: UiLayoutResult = new Map();
  let lastFrame: UiFrameStats = {
    quads: 0,
    drawCalls: 0,
    glyphs: 0,
    labels: 0,
    cacheHits: 0,
    missingGlyphs: [],
    missingFrames: [],
    relaid: false,
  };

  /** 重排 + 重画（只在脏或视口变化时真的做）。 */
  function sync(): void {
    const d = dev;
    if (d === null) return;
    const pw = d.size.width;
    const ph = d.size.height;
    if (pw > 0 && ph > 0) viewport.setScreen(pw / dpr, ph / dpr, dpr);
    if (!dirty && pw === lastPw && ph === lastPh) {
      lastFrame = { ...lastFrame, relaid: false };
      return;
    }

    layoutResult = layoutTree(root, viewport.safeRect);
    const res = buildUiQuads(root, fonts, skin, cache);
    quads = res.quads;
    drawStats = res.stats;
    dirty = false;
    lastPw = pw;
    lastPh = ph;
    lastFrame = {
      ...lastFrame,
      quads: quads.length,
      glyphs: drawStats.glyphs,
      labels: drawStats.labels,
      cacheHits: drawStats.cacheHits,
      missingGlyphs: drawStats.missingGlyphs,
      missingFrames: drawStats.missingFrames,
      relaid: true,
    };
  }

  /** 帧内绘制：上传 + 按段绑定纹理。 */
  function drawOverlay(cmd: ICommandList): void {
    sync();
    const d = dev;
    const b = batch;
    if (d === null || b === null || pipeline === null || vbo === null || ibo === null) return;
    if (quads.length === 0) {
      lastFrame = { ...lastFrame, quads: 0, drawCalls: 0 };
      return;
    }
    const built = b.build(quads, viewport.camera);
    const up = d.updateBuffer(vbo, b.vertexView(built.quadCount));
    if (!up.ok) {
      ctxRef?.log.channel("ui").error(`UI 顶点上传失败：${up.error.message}`, undefined, null);
      return;
    }
    cmd.setPipeline(pipeline);
    for (const run of built.runs) {
      const page = pages[run.atlas];
      if (page === undefined) {
        ctxRef?.log.channel("ui").warn(`UI 纹理页 ${run.atlas} 不存在（该段被跳过）`, undefined, null);
        continue;
      }
      cmd.bindTexture(0, page);
      cmd.setUniform("u_useTexture", 1, "int");
      cmd.draw({
        vertices: vbo,
        indices: ibo,
        vertexCount: (run.start + run.count) * 4,
        indexCount: run.count * 6,
        firstIndex: run.start * 6,
      });
    }
    lastFrame = { ...lastFrame, quads: built.quadCount, drawCalls: built.drawCalls };
  }

  const mod: UiModuleHandle = {
    id: opts.id ?? "ui",
    deps: [RENDER_MODULE_ID],

    init(ctx: ModuleContext): Result<void, EngineError> {
      ctxRef = ctx;
      dev = ctx.platform.gfx;
      const d = dev;
      // 没有字体 = 所有文本静默消失。启动期就拒绝，比运行时查"字为什么不显示"便宜得多。
      if (opts.fonts.length === 0) {
        return err(engineError("UI.NO_FONT", "UI 模块至少需要一个位图字体"));
      }
      if (hostPages !== undefined && pageSources !== undefined) {
        // 两条都给时**没法知道该由谁销毁** —— 猜错的后果是"换 UI 图集把世界的纹理带走了"。
        return err(engineError("UI.PAGE_AMBIGUOUS", "pages 与 pageSources 只能给一个（纹理所有权必须唯一）"));
      }
      if (hostPages === undefined && pageSources === undefined) {
        return err(engineError("UI.NO_PAGE", "UI 模块至少需要一个纹理页（pages 或 pageSources）"));
      }
      if (pageSources !== undefined) {
        if (pageSources.length === 0) return err(engineError("UI.NO_PAGE", "UI 模块至少需要一个纹理页"));
        const made: TextureHandle[] = [];
        for (const [i, src] of pageSources.entries()) {
          // Nearest：像素字体与非整数倍缩放时，线性过滤会把 1px 的笔画抹成灰边。
          // Clamp：UI 图集的帧可以贴边，repeat 会把邻居帧采进来。
          const t = d.createTexture(
            {
              width: src.width,
              height: src.height,
              filter: TextureFilter.Nearest,
              wrap: TextureWrap.Clamp,
              label: `engine.ui.page[${String(i)}]:${src.name}`,
            },
            src.pixels,
          );
          if (!t.ok) {
            for (const h of made) d.destroyTexture(h);
            return t as Result<void, EngineError>;
          }
          made.push(t.value);
        }
        ownPages = made;
        pages = made;
      }

      // `pages: []` 与"没给"是同一个意思：**没有可采样的纹理**。
      // 只判 undefined 会让空数组一路走到渲染，然后在 drawOverlay 里被
      // "纹理页不存在（该段被跳过）"吞掉 —— 那时已经看不出是配置错了。
      if (pages.length === 0) {
        return err(engineError("UI.NO_PAGE", "UI 模块至少需要一个纹理页"));
      }

      // init 中途失败时，模块系统的约定是**不保证**再调 dispose（它连"初始化成功"都没看到）。
      // 所以自己建的纹理要在这里就地清掉；靠 dispose 兜底会漏掉"init 失败"这一整类泄漏。
      const bail = (e: Result<never, EngineError>): Result<void, EngineError> => {
        for (const h of ownPages) d.destroyTexture(h);
        ownPages = [];
        return e as Result<void, EngineError>;
      };

      const sh = d.createShader({ vertex: SPRITE_VS, fragment: SPRITE_FS, label: "engine.ui" });
      if (!sh.ok) return bail(sh);
      const pl = d.createPipeline({
        shader: sh.value,
        layout: SPRITE_VERTEX_LAYOUT,
        blend: BlendMode.Alpha,
        label: "engine.ui",
      });
      if (!pl.ok) {
        d.destroyShader(sh.value);
        return bail(pl);
      }
      const b = new SpriteBatch(opts.maxQuads ?? 2048);
      const vb = d.createBuffer({
        usage: BufferUsage.Vertex,
        byteLength: b.vertices.byteLength,
        dynamic: true,
        label: "engine.ui.vbo",
      });
      if (!vb.ok) {
        d.destroyPipeline(pl.value);
        d.destroyShader(sh.value);
        return bail(vb);
      }
      const ib = d.createBuffer({
        usage: BufferUsage.Index,
        byteLength: b.indices.byteLength,
        dynamic: false,
        label: "engine.ui.ibo",
      });
      if (!ib.ok) {
        d.destroyBuffer(vb.value);
        d.destroyPipeline(pl.value);
        d.destroyShader(sh.value);
        return bail(ib);
      }
      const up = d.updateBuffer(ib.value, b.indices);
      if (!up.ok) {
        d.destroyBuffer(ib.value);
        d.destroyBuffer(vb.value);
        d.destroyPipeline(pl.value);
        d.destroyShader(sh.value);
        return bail(up);
      }

      shader = sh.value;
      pipeline = pl.value;
      batch = b;
      vbo = vb.value;
      ibo = ib.value;
      ctx.log.channel("ui").info(
        `UI 模块就绪：${opts.fonts.length} 个字体 · ${skin.frames.size} 个皮肤帧 · ${pages.length} 页 · ` +
          `设计分辨率 ${viewport.designWidth}x${viewport.designHeight}（${viewport.scaleMode}）`,
      );
      return ok(undefined);
    },

    start(): Result<void, EngineError> {
      const ctx = ctxRef;
      if (ctx === null) return err(engineError("UI.NOT_INIT", "start 之前没有 init"));
      const render = ctx.module<RenderModuleHandle>(RENDER_MODULE_ID);
      if (render === undefined) {
        return err(
          engineError("UI.NO_RENDER", `找不到渲染模块 ${RENDER_MODULE_ID}（UI 必须挂在它的 pass 尾部）`),
        );
      }
      render.setOverlay(drawOverlay);
      offRender = () => render.setOverlay(null);
      return ok(undefined);
    },

    stop(): void {
      offRender?.();
      offRender = null;
    },

    dispose(): void {
      const d = dev;
      if (d !== null) {
        // 只销毁自己创建的：纹理是宿主的（hostPages），销毁它会在"换皮 / 重载 UI 图集"时
        // 把世界的纹理一起带走 —— 而错误发生在很久以后（下一次用那张纹理时），追不回来。
        for (const h of ownPages) d.destroyTexture(h);
        if (ibo !== null) d.destroyBuffer(ibo);
        if (vbo !== null) d.destroyBuffer(vbo);
        if (pipeline !== null) d.destroyPipeline(pipeline);
        if (shader !== null) d.destroyShader(shader);
      }
      ownPages = [];
      pages = hostPages ?? [];
      ibo = null;
      vbo = null;
      pipeline = null;
      shader = null;
      batch = null;
      dev = null;
      quads = [];
      cache.invalidate();
      dirty = true;
    },

    describe(): string {
      return (
        `UI：${lastFrame.quads} quad / ${lastFrame.drawCalls} draw / ` +
        `${lastFrame.glyphs} 字形 / ${lastFrame.labels} 标签`
      );
    },

    get viewport(): UiViewport {
      return viewport;
    },
    get fonts(): FontRegistry {
      return fonts;
    },
    get root(): UiNode {
      return root;
    },

    setRoot(node: UiNode): void {
      root = node;
      router = new UiInputRouter(root, { dragThreshold: opts.dragThreshold });
      cache.invalidate();
      dirty = true;
    },

    pointer(p: UiPointer): UiEvent[] {
      // 先保证布局是最新的：否则点击会打在上一次布局的矩形上（换分辨率后的第一帧必错）。
      sync();
      return router.update(p, opts.onEvent);
    },

    invalidate(): void {
      dirty = true;
    },

    relayout(): void {
      dirty = true;
      sync();
    },

    get lastFrame(): UiFrameStats {
      return lastFrame;
    },

    get layout(): UiLayoutResult {
      return layoutResult;
    },
  };

  return mod;
}

/** 取某个节点的绝对矩形（诊断/编辑器用）。 */
export function rectOf(ui: UiModuleHandle, id: string): Rect | undefined {
  return ui.layout.get(id);
}
