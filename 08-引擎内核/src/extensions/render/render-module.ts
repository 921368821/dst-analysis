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
  type PixelFormatValue,
  type ShaderHandle,
  type TextureHandle,
} from "../../platform/gfx/types.ts";
import type { ICommandList, IGraphicsDevice } from "../../platform/gfx/device.ts";
import { SPRITE_FS, SPRITE_VS } from "./shaders-glsl.ts";
import { SpriteBatch, type RenderItem } from "./batch2d.ts";
import { Camera2D } from "./camera.ts";
import { Sprite } from "./sprite.ts";
import { buildProceduralAtlas, buildTilePages, type AtlasData, type AtlasFrame } from "./atlas.ts";

/**
 * `render.sprite` → `RenderItem`（纯数据搬运）。
 *
 * ★★ 为什么这 10 行要被抽出来：它原来是 `renderFrame` 里的一段对象字面量。
 *   搬运**漏一个字段**时，三处判据全是绿的 —— 组件上有值、batch 也支持、
 *   唯独画面错位。这种"中间那一行"的缺陷只有把搬运本身抽成可测的函数才抓得住
 *   （M139 就是这么发现的：变异加在字面量上，没有任何判据变红）。
 *
 * ★ 帧名不存在时**不在这里报错**：这一层只做映射，`renderFrame` 负责 warn + 跳过
 *   （那是运行时该有的态度）；"资产配置错"由可视化桥在加载时升级成错误。
 */
export function spriteToRenderItem(s: Sprite, f: AtlasFrame, nodeId: number, x: number, z: number, atlas: number): RenderItem {
  return {
    nodeId,
    x,
    z,
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
    layer: s.layer,
    pivotY: s.pivotY,
    pivotX: s.pivotX,
    atlas,
    tileX: s.tileX,
    tileY: s.tileY,
  };
}

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
  /**
   * 覆盖默认图集（真实项目会传导入的图集）。**第 0 页是主图集**。
   */
  readonly atlas?: AtlasData;
  /**
   * 除主图集之外再挂几页（T288：瓦片页走 `repeat`，主图集仍是 `clamp`）。
   * ★ 为什么不是给主图集开 repeat：邻居帧会被平铺采进来（见 `buildTilePages`）。
   */
  readonly extraPages?: readonly AtlasData[];
  /**
   * 从主图集**自动抽出**瓦片页的帧名（默认 `["terrain"]`）。
   * ★ 默认值的存在理由：程序化兜底路径也要能平铺地形，否则"降级"会静默丢掉 T288。
   *   传 `[]` 可关掉（例如主图集里没有 terrain 帧，抽了也是空）。
   */
  readonly tileFrames?: readonly string[];
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
  /**
   * 图集页数（主图集 + 瓦片页 + 附加页；init 之前是 0）。
   * ★ 存在的理由：T288 之后"一帧几次 draw"由页数决定。自检页要能区分
   *   "draw=1 因为只有一页"与"draw=1 因为批处理生效"—— 这两个数必须一起看。
   */
  readonly atlasPageCount: number;
  /**
   * 实际上传到 GPU 的图集格式（init 之前 / dispose 之后是 `rgba8`）。
   * ★ 存在的理由与 `atlasFrameCount` 同：`drawCalls > 0` 证明不了"画的是 16 位图集"。
   *   16 位链路上任何一段悄悄退回 8 位（合成器没给 pixels16 / 上传按 RGBA8 / 后端把
   *   RGBA16 落到 RGBA8），画面在肉眼下几乎一样，只有这个值会变。
   */
  readonly atlasFormat: PixelFormatValue;
  /**
   * 查一帧的 UV 矩形与图集尺寸（诊断）。
   *
   * ★ 存在的理由：画面"少了一类东西"时，第一个要回答的问题是
   *   **帧在不在、UV 指哪儿、图集多大**。这三件事从 `atlasFrameCount` 看不出来：
   *   帧存在但 UV 落在贴图的透明区，画面就是空的，而所有计数都是对的
   *   （批46 就是这么栽的：地形帧在资产图集里指向了一片空白）。
   */
  atlasFrame(name: string): AtlasFrameRect | undefined;
  /**
   * 上一帧**实际提交**的顶点（前 `quads` 个四边形，每顶点 8 个 float：x y u v r g b a）。
   *
   * ★ 为什么诊断要到顶点这一层：画面不对时，"组件字段对、图集对、quad 数对" 全都可能成立，
   *   而错误只在**顶点坐标**里。没有这个视图就只能靠改代码猜（批46 卡了两小时）。
   */
  lastVertices(quads: number): Float32Array;

  /**
   * 注册「世界画完、`endFrame` 之前」的绘制回调（UI 用）。
   *
   * ★ 为什么需要这个钩子，而不是让 UI 自己 `beginFrame`：
   *   `beginFrame/endFrame` 是一次完整的 pass，而 pass 开头会 `clear`。
   *   第二个渲染器自己开 pass 会把世界擦掉；不 clear 又要依赖后端的隐式状态
   *   （"上一帧的 clear 还在不在"），那是靠后端实现细节碰运气。
   *   把 UI 放进**同一个 pass 的尾部**，是唯一既正确又不依赖后端的选择。
   *
   * ★ 回调抛错不静默：记 `render` 通道的 error，并继续 `endFrame`
   *   （否则一帧异常会让整帧不提交，画面冻结在上一帧，症状像"卡死"）。
   *
   * ★ 只允许一个（后注册的覆盖先注册的）：多个 overlay 之间的顺序没有语义，
   *   而"谁先谁后"在 UI 上就是"谁盖住谁"。真需要多层就自己在回调里排。
   */
  setOverlay(fn: ((cmd: ICommandList) => void) | null): void;
}

/** `atlasFrame()` 的返回形状（单独命名：它要进公共签名，不该是一坨匿名对象类型）。 */
export interface AtlasFrameRect {
  readonly u0: number;
  readonly v0: number;
  readonly u1: number;
  readonly v1: number;
  readonly w: number;
  readonly h: number;
  readonly atlasW: number;
  readonly atlasH: number;
  /**
   * 帧**中心**那一个像素的值（RGBA8）。
   *
   * ★ 为什么这个字段必须存在：帧表里有名字、UV 也在范围内，画面却什么都没有 ——
   *   只剩一种可能：那块区域是透明的。这一条把"帧在不在"和"这块有没有像素"分开，
   *   否则只能靠肉眼猜（批46 的地形帧就是这么查出来的）。
   */
  readonly sample: { readonly r: number; readonly g: number; readonly b: number; readonly a: number };
  /**
   * 这一帧里**有多少行的中列是不透明的**（行数 × 列数里的行）。
   *
   * ★ 与 `sample` 配合才能回答"这帧是不是只有一条线"：
   *   一个 64 高的帧若只有 1 行不透明，画面就是 1 像素高的一条线，
   *   而帧尺寸、UV、像素采样全都可以是"对的"。
   */
  readonly opaqueRows: number;
}

/**
 * 帧的 UV / 像素诊断（`atlasFrame()` 的实现）。
 *
 * ★ 为什么值得单独一个函数：它回答的两个问题（"UV 指哪儿"、"那块有没有像素"）
 *   是画面空白时唯一能不问人就看出来的事实。抽出来是为了让"跨页查"与
 *   "主图集优先"这些规则有**一处**实现 —— 判据与诊断走同一条路。
 */
function frameRect(a: AtlasData, f: AtlasFrame, name: string): AtlasFrameRect {
  // 帧中心像素：UV 是归一化的，直接乘回像素坐标（四舍五入到格）
  const px = Math.min(a.width - 1, Math.max(0, Math.floor(((f.u0 + f.u1) / 2) * a.width)));
  const py = Math.min(a.height - 1, Math.max(0, Math.floor(((f.v0 + f.v1) / 2) * a.height)));
  const i = (py * a.width + px) * 4;
  // 数一下这一帧里有多少行的中列是不透明的（0 ⇒ 这帧在画面上是空的）
  const x0 = Math.floor(f.u0 * a.width);
  const x1 = Math.max(x0, Math.floor(f.u1 * a.width) - 1);
  const y0 = Math.floor(f.v0 * a.height);
  const y1 = Math.max(y0, Math.floor(f.v1 * a.height) - 1);
  const midX = (x0 + x1) >> 1;
  let opaqueRows = 0;
  for (let y = y0; y <= y1; y++) {
    if ((a.pixels[(y * a.width + midX) * 4 + 3] ?? 0) > 0) opaqueRows++;
  }
  void name;
  return {
    u0: f.u0, v0: f.v0, u1: f.u1, v1: f.v1, w: f.w, h: f.h, atlasW: a.width, atlasH: a.height,
    opaqueRows,
    sample: {
      r: a.pixels[i] ?? 0,
      g: a.pixels[i + 1] ?? 0,
      b: a.pixels[i + 2] ?? 0,
      a: a.pixels[i + 3] ?? 0,
    },
  };
}

export function createRenderModule(opts: RenderModuleOptions): RenderModuleHandle {
  const camera = new Camera2D({
    viewportWidth: opts.viewportWidth,
    viewportHeight: opts.viewportHeight,
    zoom: opts.zoom ?? 32,
    tiltY: opts.tiltY ?? 0.62,
  });

  let dev: IGraphicsDevice | null = null;
  /** 每页一张纹理（下标 = 槽位）。第 0 页恒为主图集。 */
  let tex: TextureHandle[] = [];
  /** 页名 → 槽位（`Sprite.atlasId` 的解析表）。空串 / 未知名都落到主图集。 */
  let slotOfName: ReadonlyMap<string, number> = new Map();
  let shader: ShaderHandle | null = null;
  let pipeline: PipelineHandle | null = null;
  let vbo: BufferHandle | null = null;
  let ibo: BufferHandle | null = null;
  let offRender: (() => void) | null = null;
  let overlay: ((cmd: ICommandList) => void) | null = null;
  let batch: SpriteBatch | null = null;
  /** 所有页（下标 = 槽位）。诊断与 `atlasFrame()` 跨页查。 */
  let pages: AtlasData[] = [];
  /** 已上传图集的格式。初始化前对外报 rgba8（见 `atlasFormat` getter 的说明）。 */
  let atlasFmt: PixelFormatValue = PixelFormat.RGBA8;
  let ctxRef: ModuleContext | null = null;
  /** 本帧已经告警过的"未知 atlasId"（避免同一件事每帧刷屏）。 */
  let warnedAtlasIds = new Set<string>();

  let lastFrame = { quads: 0, drawCalls: 0, atlasSwitches: 0, culled: 0 };

  const mod: RenderModuleHandle = {
    id: opts.id ?? "render.batch2d",
    deps: [],

    init(ctx: ModuleContext): Result<void, EngineError> {
      ctxRef = ctx;
      dev = ctx.platform.gfx;
      const d = dev;

      const procedural = opts.atlas === undefined;
      const main = opts.atlas ?? buildProceduralAtlas();
      // ★ 瓦片页：主图集 + 自动抽出 + 显式附加。三段都可能有，顺序固定（主图集恒为 0 槽）。
      pages = [main, ...buildTilePages(main, opts.tileFrames ?? ["terrain"]), ...(opts.extraPages ?? [])];
      const slots = new Map<string, number>();
      for (const [i, p] of pages.entries()) {
        const name = p.name;
        if (name !== undefined && name !== "") {
          if (slots.has(name)) {
            return err(engineError("RENDER.DUP_PAGE", `两个图集页重名：${name}（atlasId 会指向不确定的那一页）`));
          }
          slots.set(name, i);
        }
      }
      slotOfName = slots;

      const uploaded: TextureHandle[] = [];
      for (const [i, page] of pages.entries()) {
        // ★ 上传路径必须跟着 `page.format` 走，不能硬编码 RGBA8：
        //   16 位图集按 8 位上传 = 长度只有一半 —— null 后端会以 GFX.SIZE_MISMATCH 拒绝，
        //   真后端（GL）只会置 INVALID_VALUE 并留下空纹理。两种表现都不该出现在"图集通了"的路径上。
        const fmt = page.format ?? PixelFormat.RGBA8;
        const p16 = page.pixels16;
        if (fmt === PixelFormat.RGBA16 && p16 === undefined) {
          for (const h of uploaded) d.destroyTexture(h);
          // 声明 16 位却没有全精度像素：宁可启动失败，也不要"降采样之后看起来成功了"
          return err(
            engineError("RENDER.BAD_ATLAS", `图集页 ${i}（${page.name ?? "main"}）format 是 rgba16，但没给 pixels16（解码器偷偷降采样了？）`),
          );
        }
        const upload: ArrayBufferView = fmt === PixelFormat.RGBA16 && p16 !== undefined ? p16 : page.pixels;
        const t = d.createTexture(
          {
            width: page.width,
            height: page.height,
            format: fmt,
            filter: TextureFilter.Nearest,
            // ★ wrap 是**页级**的：瓦片页 repeat（平铺），主图集 clamp（不抻边）。
            //   两页混用同一张 wrap 的两种错法都试过：主图集开 repeat ⇒ 邻居帧被采进来；
            //   瓦片页开 clamp ⇒ 平铺的接缝处一条脏边。两种都不报错，只难看。
            wrap: page.wrap ?? TextureWrap.Clamp,
            // label 不是装饰：null 后端的 `describe()` 与崩溃报告会原样打印它，
            // "这张纹理到底是资产图集还是兜底的程序化图集"必须一眼可辨；
            // 精度同理 —— 一个 "atlas:rgba16" 比翻像素快得多。
            label:
              (procedural && i === 0 ? "engine.procedural-atlas" : `engine.atlas[${i}]`) +
              (page.name !== undefined ? `:${page.name}` : "") +
              (fmt === PixelFormat.RGBA16 ? ":rgba16" : "") +
              (page.wrap === TextureWrap.Repeat ? ":repeat" : ""),
          },
          upload,
        );
        if (!t.ok) {
          for (const h of uploaded) d.destroyTexture(h);
          return t as Result<void, EngineError>;
        }
        uploaded.push(t.value);
      }
      tex = uploaded;
      atlasFmt = main.format ?? PixelFormat.RGBA8;

      const sh = d.createShader({
        vertex: SPRITE_VS,
        fragment: SPRITE_FS,
        label: "engine.sprite",
      });
      if (!sh.ok) {
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
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
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
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
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
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
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return ib as Result<void, EngineError>;
      }
      ibo = ib.value;
      const up = d.updateBuffer(ibo, batch.indices);
      if (!up.ok) {
        d.destroyBuffer(ibo);
        d.destroyBuffer(vbo);
        d.destroyPipeline(pipeline);
        d.destroyShader(shader);
        for (const h of uploaded) d.destroyTexture(h);
        tex = [];
        return up as Result<void, EngineError>;
      }

      ctx.log.channel("render").info(
        `渲染模块就绪：${pages.map((p) => `${p.name ?? "main"} ${p.width}x${p.height}`).join(" + ")} · ` +
          `主图集 ${main.frames.size} 帧 · ${atlasFmt} · 批量上限 ${batch.maxQuads} quad`,
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
        for (const h of tex) d.destroyTexture(h);
      }
      ibo = null;
      vbo = null;
      pipeline = null;
      shader = null;
      tex = [];
      dev = null;
      batch = null;
      pages = [];
      slotOfName = new Map();
      atlasFmt = PixelFormat.RGBA8;
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
      // 主图集的帧数（第 0 页）。★ 刻意不含瓦片页：自检页用它区分
      // "5 帧的资产图集"与"5 帧的程序化图集"，把瓦片页算进来会让这个数随
      // `tileFrames` 漂移，而它要回答的问题是"主图集里有几帧可画"。
      return pages[0]?.frames.size ?? 0;
    },

    get atlasFormat(): PixelFormatValue {
      return atlasFmt;
    },

    /** 图集页数（主图集 + 瓦片页 + 附加页）。init 之前是 0。 */
    get atlasPageCount(): number {
      return pages.length;
    },

    atlasFrame(name: string) {
      // ★ 主图集优先，再查其它页：瓦片页里的帧与主图集同名时，诊断要回答的
      //   是"主图集里的 UV 与像素"（瓦片页的 UV 恒为 0..1，拿它回答会让人
      //   以为"这一帧铺满了整张纹理"）。
      const main = pages[0];
      const mf = main?.frames.get(name);
      if (main !== undefined && mf !== undefined) return frameRect(main, mf, name);
      for (const a of pages) {
        const f = a.frames.get(name);
        if (f !== undefined) return frameRect(a, f, name);
      }
      return undefined;
    },

    lastVertices(quads: number): Float32Array {
      const b = batch;
      if (b === null) return new Float32Array(0);
      return b.vertexView(Math.max(0, quads)).slice();
    },

    setOverlay(fn: ((cmd: ICommandList) => void) | null): void {
      overlay = fn;
    },
  };

  function renderFrame(info: FrameInfo): void {
    const d = dev;
    const b = batch;
    const scene = ctxRef?.services.get(Services.Scene);
    if (d === null || b === null || pages.length === 0 || scene === undefined) return;

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
    warnedAtlasIds.clear();

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
      // 页名 → 槽位。空串 = 主图集；未知名**也落主图集**但必须告警 ——
      // 静默落到主图集的表现是"用了另一张贴图"，而组件上的名字看起来是对的。
      let slot = 0;
      if (s.atlasId !== "") {
        const found = slotOfName.get(s.atlasId);
        if (found === undefined) {
          if (!warnedAtlasIds.has(s.atlasId)) {
            warnedAtlasIds.add(s.atlasId);
            ctxRef?.log.channel("render").warn(
              `Sprite 的 atlasId 没有对应图集页：${JSON.stringify(s.atlasId)}（已回落到主图集）`,
              { node: node.id },
              null,
            );
          }
        } else {
          slot = found;
        }
      }
      const f = frameOf(slot, s.frame);
      if (f === undefined) {
        // 帧名不存在：不能静默跳过（否则"某个东西不显示"永远查不出来）
        ctxRef?.log.channel("render").warn(`Sprite 帧名不存在：${JSON.stringify(s.frame)}`, { node: node.id }, null);
        continue;
      }
      items.push(spriteToRenderItem(s, f, node.id, p.x, p.y, slot));
      // ★ T288 的组合检查：平铺（tileX/tileY > 1）只能用在 `repeat` 页上。
      //   clamp 页上平铺 ⇒ GPU 把边缘像素抻出去，画面是一条脏边，而精灵的
      //   所有数字（UV/尺寸/位置）都对 —— 这类"全对但难看"必须在这里喊出来。
      if ((s.tileX > 1 || s.tileY > 1) && (pages[slot]?.wrap ?? "clamp") !== "repeat") {
        ctxRef?.log.channel("render").warn(
          `Sprite 在 clamp 页上平铺（tileX=${s.tileX}, tileY=${s.tileY}, atlasId=${JSON.stringify(s.atlasId)}）—— ` +
            `接缝会被抻成脏边；请改用 buildTilePages 抽出的 repeat 页`,
          { node: node.id },
          null,
        );
      }
    }

    const built = b.build(items, camera);
    lastFrame = {
      quads: built.quadCount,
      drawCalls: built.drawCalls,
      atlasSwitches: built.atlasSwitches,
      culled,
    };

    // ---- 提交（一段一次 draw：每段绑定自己那张纹理）
    const vw = d.size.width;
    const vh = d.size.height;
    camera.setViewport(vw, vh);

    const cmd = d.beginFrame(null);
    cmd.setViewport(new Rect(0, 0, vw, vh));
    cmd.clear(camera.clearColor, 1);

    if (built.quadCount > 0 && vbo !== null && ibo !== null && pipeline !== null) {
      const up = d.updateBuffer(vbo, b.vertexView(built.quadCount));
      if (!up.ok) {
        // 上传失败（容量/句柄）—— 报出来，不要静默黑屏
        ctxRef?.log.channel("render").error(`顶点上传失败：${up.error.message}`, undefined, null);
      } else {
        cmd.setPipeline(pipeline);
        for (const run of built.runs) {
          const page = tex[run.atlas];
          if (page === undefined) {
            ctxRef?.log.channel("render").error(`图集槽位 ${run.atlas} 没有纹理（段被跳过）`, undefined, null);
            continue;
          }
          cmd.bindTexture(0, page);
          cmd.setUniform("u_useTexture", 1, "int");
          cmd.draw({
            vertices: vbo,
            indices: ibo,
            vertexCount: (run.start + run.count) * 4,
            indexCount: run.count * 6,
            // ★ 段在索引缓冲里的偏移：顶点是连续排的，索引也是按 quad 顺序生成的，
            //   所以第 q 个 quad 的索引起点就是 q*6。少了这个偏移，第二段会把
            //   **第一段的几何**再画一遍（画面重复而不是切换贴图）。
            firstIndex: run.start * 6,
          });
        }
      }
    }
    // ---- 覆盖层（UI）：同一个 pass 的尾部，世界之后（见 `setOverlay` 的理由）。
    //   ★ 放在 `if (quadCount > 0)` 之外：世界空（比如加载中）时 UI 仍要画。
    if (overlay !== null) {
      try {
        overlay(cmd);
      } catch (e) {
        // 抛错不静默，也不让整帧不提交 —— 前者会让"UI 不见了"变成谜，
        // 后者会让画面冻结在上一帧，症状像卡死。
        ctxRef?.log.channel("render").error(
          `覆盖层绘制抛错（本帧仍提交，画面可能缺 UI）：${e instanceof Error ? e.message : String(e)}`,
          undefined,
          null,
        );
      }
    }
    cmd.finish();
    d.endFrame();
    void info;
  }

  /** 指定页里查一帧（主图集 / 瓦片页 / 附加页同一套查法）。 */
  function frameOf(slot: number, frame: string) {
    return pages[slot]?.frames.get(frame);
  }

  return mod;
}
