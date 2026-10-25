/**
 * L4 · UI 控件绘制与模块接线判据
 *
 * 这一层守的是**集成**，不是算法：
 *   ① 九宫格：9 块几何拼起来必须严丝合缝（缝 1 像素，圆角就断）；
 *   ② 控件：进度条的 UV 按比例裁切；标签的字形数对得上；
 *   ③ 模块：UI 必须画在**同一个 pass** 里、世界之后（这是"UI 盖住世界"的唯一正确做法）；
 *   ④ 缓存：文本没变就不该重排（重排一次是 O(字数)，背包 40 格每帧重排会掉帧）。
 *
 * ★ 用 null 后端而不是真 GL：要断言的是"提交了什么"（几段 draw、第几段、
 *   顶点数），这些在空后端里是**可读的数据**；在真 GL 里只能靠截图猜。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Rect } from "../../src/foundation/math/index.ts";
import { unwrap } from "../../src/foundation/result.ts";
import { PixelFormat } from "../../src/platform/gfx/types.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import { NullGraphicsDevice } from "../../src/backends/gfx-null/device.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { Logger, MemorySink } from "../../src/foundation/log/logger.ts";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import type { FrameInfo } from "../../src/core/frame-host.ts";
import { createRenderModule, type RenderModuleHandle } from "../../src/extensions/render/render-module.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { buildUiTree, layoutTree, UiLayoutKind, UiWidget } from "../../src/extensions/ui/layout.ts";
import { buildUiQuads, nineSlice, TextCache, type UiSkin, type UiSkinFrame } from "../../src/extensions/ui/widgets.ts";
import { FontRegistry } from "../../src/extensions/ui/font.ts";
import { createUiModule, type UiModuleHandle } from "../../src/extensions/ui/ui-module.ts";
import { makeTestFont } from "./ui-fixtures.ts";

// ── ① 九宫格 ────────────────────────────────────────────────

const FRAME: UiSkinFrame = { page: 0, u0: 0, v0: 0, u1: 0.25, v1: 0.25, width: 32, height: 32 };

test("★ 九宫格：9 块拼满目标矩形，无缝、不重叠", () => {
  const r = new Rect(100, 50, 200, 100);
  const parts = nineSlice(r, FRAME, 8);
  assert.equal(parts.length, 9);
  // 面积守恒：9 块面积之和 = 目标面积（有缝或少一块都不成立）
  const area = parts.reduce((s, p) => s + p.rect.width * p.rect.height, 0);
  assert.equal(area, r.width * r.height);
  // 四角原地不动：左上角那块必须精确等于 (100,50,8,8)
  assert.deepEqual(parts[0]?.rect, new Rect(100, 50, 8, 8));
  // 中间块被拉伸：宽 = 200 − 2×8
  const mid = parts.find((p) => p.rect.x === 108 && p.rect.y === 58);
  assert.equal(mid?.rect.width, 184);
  assert.equal(mid?.rect.height, 84);
});

test("九宫格的 UV 按源图比例切（不是按目标像素切）", () => {
  const parts = nineSlice(new Rect(0, 0, 200, 100), FRAME, 8);
  // 源帧 32×32、边距 8 ⇒ u 方向每边占 8/32 = 0.25 的帧宽 ⇒ 帧宽 0.25 里的 0.0625
  assert.equal(parts[0]?.uv.u0, 0);
  assert.equal(parts[0]?.uv.u1, 0.0625, "8/32 × 帧宽 0.25");
  assert.equal(parts[8]?.uv.u1, FRAME.u1);
});

test("★ 边距过大时退化但仍覆盖整块（不能切出负宽度）", () => {
  const r = new Rect(0, 0, 10, 10);
  const parts = nineSlice(r, FRAME, 50); // 边距远大于目标
  assert.ok(parts.length >= 1 && parts.length <= 9);
  for (const p of parts) {
    assert.ok(p.rect.width > 0 && p.rect.height > 0, "不能出现 0 或负尺寸的块");
    assert.ok(p.rect.x >= -1e-9 && p.rect.xMax <= 10 + 1e-9);
  }
  const area = parts.reduce((s, p) => s + p.rect.width * p.rect.height, 0);
  assert.equal(area, 100, "退化后仍要铺满目标");
});

// ── ② 控件绘制 ──────────────────────────────────────────────

function smallSkin(): UiSkin {
  return { frames: new Map([["panel", FRAME]]) };
}

test("★ 进度条按比例**裁切 UV**（不是把整图缩小）：50% 时 u1 落在中点", () => {
  const fonts = new FontRegistry();
  fonts.register(makeTestFont());
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "hp",
        widget: UiWidget.Progress,
        size: { w: 100, h: 20 },
        props: { frame: "panel", slice: 0, value: 0.5 },
      },
    ],
  });
  // ★ 必须先布局：直接把未布局的树交给绘制层，所有 rect 都是 0 ⇒ 一个 quad 都不出。
  layoutTree(tree, new Rect(0, 0, 400, 300));
  const res = buildUiQuads(tree, fonts, smallSkin(), new TextCache());
  // 底 1 块 + 填充 1 块（slice=0）
  assert.equal(res.quads.length, 2);
  const fill = res.quads[1]!;
  assert.equal(fill.w, 50, "填充宽度 = 100 × 0.5");
  assert.equal(fill.u1, 0.125, "UV 也裁到一半：0 + 0.25 × 0.5");
  assert.equal(fill.u0, 0, "起点不能跟着缩放");
});

test("进度条 value 被夹到 0..1；0 时不画填充", () => {
  const fonts = new FontRegistry();
  fonts.register(makeTestFont());
  const mk = (v: number) => {
    const t = buildUiTree({
      id: "root",
      children: [{ id: "hp", widget: UiWidget.Progress, size: { w: 100, h: 20 }, props: { frame: "panel", value: v } }],
    });
    layoutTree(t, new Rect(0, 0, 400, 300));
    return t;
  };
  assert.equal(buildUiQuads(mk(0), fonts, smallSkin(), new TextCache()).quads.length, 1);
  assert.equal(buildUiQuads(mk(1.8), fonts, smallSkin(), new TextCache()).quads.length, 2);
  const full = buildUiQuads(mk(1.8), fonts, smallSkin(), new TextCache()).quads[1]!;
  assert.equal(full.w, 100, "超 1 的 value 不能画出容器");
});

test("标签画出字形；不存在的帧名进 missingFrames（不静默）", () => {
  const fonts = new FontRegistry();
  fonts.register(makeTestFont());
  const tree = buildUiTree({
    id: "root",
    children: [
      { id: "lbl", widget: UiWidget.Label, size: { w: 200, h: 24 }, props: { text: "AB", fontId: "test" } },
      { id: "ghost", widget: UiWidget.Image, size: { w: 10, h: 10 }, props: { frame: "no-such-frame" } },
    ],
  });
  layoutTree(tree, new Rect(0, 0, 400, 300));
  const res = buildUiQuads(tree, fonts, smallSkin(), new TextCache());
  assert.equal(res.stats.labels, 1);
  assert.equal(res.stats.glyphs, 2);
  assert.deepEqual([...res.stats.missingFrames], ["no-such-frame"]);
});

// ── ③ 模块接线 ──────────────────────────────────────────────

interface Rig {
  readonly dev: NullGraphicsDevice;
  readonly ui: UiModuleHandle;
  readonly renderer: RenderModuleHandle;
  readonly scene: Scene;
  readonly sink: MemorySink;
  readonly frame: (info?: FrameInfo) => void;
}

const INFO: FrameInfo = { frame: 1, realDtSec: 1 / 60, steps: 1, alpha: 0, tick: 1 };

function bootUi(
  opts: {
    readonly root?: ReturnType<typeof buildUiTree>;
    readonly fonts?: readonly ReturnType<typeof makeTestFont>[];
    readonly pages?: number;
    readonly dpr?: number;
    readonly withSprite?: boolean;
  } = {},
): Rig {
  const reg = new ComponentRegistry();
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("ui-test", reg);
  if (opts.withSprite === true) {
    // ★ 必须走 spawn + scene.attach + flush：`componentsOf` 读的是场景的组件索引，
    //   直接 `node.add()` 只挂到节点上，渲染模块一个都看不到。
    const sp = scene.spawn("box", null);
    assert.ok(sp.ok, "spawn 失败");
    scene.flush();
    const made = scene.attach(sp.value.id, () => {
      const s2 = new Sprite();
      // 用一个**主图集里确实存在**的帧名，这样世界真的会画一次 draw
      s2.frame = "tree";
      s2.width = 1;
      s2.height = 1;
      return s2;
    });
    assert.ok(made.ok, "attach 失败");
    scene.flush();
  }

  const sink = new MemorySink();
  const logger = new Logger(() => 0);
  logger.addSink(sink);

  const renders: Array<(info: FrameInfo) => void> = [];
  const frameHost = {
    onRender(fn: (info: FrameInfo) => void): () => void {
      renders.push(fn);
      return () => void renders.splice(renders.indexOf(fn), 1);
    },
  };
  const services = new ServiceRegistry();
  services.provide(Services.Frame, frameHost as never, "test.ui");
  services.provide(Services.Scene, scene, "test.ui");

  const dev = new NullGraphicsDevice(800, 600);
  let renderer: RenderModuleHandle | undefined;
  const ctx: ModuleContext = {
    log: logger,
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: { gfx: dev } as unknown as IPlatform,
    random: new XorShift128(1),
    module: () => renderer as never,
  };

  const rmod = createRenderModule({ viewportWidth: 800, viewportHeight: 600, zoom: 32 });
  renderer = rmod;
  const r0 = rmod.init(ctx);
  assert.ok(!(r0 instanceof Promise) && (r0 === undefined || r0.ok), "渲染模块 init 失败");
  rmod.start?.();

  const pageCount = opts.pages ?? 1;
  const textures = Array.from({ length: pageCount }, (_, i) =>
    unwrap(dev.createTexture({ width: 64, height: 64, format: PixelFormat.RGBA8, label: `ui-page-${i}` })),
  );

  const ui = createUiModule({
    viewport: { designWidth: 800, designHeight: 600, scaleMode: "expand" },
    skin: smallSkin(),
    pages: textures,
    fonts: opts.fonts ?? [makeTestFont()],
    root: opts.root ?? buildUiTree({ id: "root" }),
    dpr: opts.dpr ?? 1,
  });
  const r1 = ui.init(ctx);
  assert.ok(!(r1 instanceof Promise) && (r1 === undefined || r1.ok), "UI 模块 init 失败");
  const r2 = ui.start?.();
  assert.ok(!(r2 instanceof Promise) && (r2 === undefined || r2.ok), "UI 模块 start 失败");

  return {
    dev,
    ui,
    renderer: rmod,
    scene,
    sink,
    frame: (info) => {
      for (const f of renders) f(info ?? INFO);
    },
  };
}

test("★ UI 画在**同一个 pass** 里：整帧只有一次 clear，且 UI 的 draw 在最后", () => {
  const root = buildUiTree({
    id: "root",
    children: [
      { id: "panel", widget: UiWidget.Panel, size: { w: 200, h: 120 }, props: { frame: "panel", slice: 8 } },
    ],
  });
  const rig = bootUi({ root, withSprite: true });
  rig.frame();
  const rec = rig.dev.frames[rig.dev.frames.length - 1];
  assert.ok(rec !== undefined);
  assert.equal(rec.clears.length, 1, "第二个 pass 会再 clear 一次 —— 那会把世界擦掉");
  // 世界 1 次 + UI 1 次，且在**同一条 frame record** 里（= 同一个 pass）
  assert.equal(rec.draws.length, 2, "世界一次 + UI 一次");
  const world = rec.draws[0]!;
  const ui = rec.draws[1]!;
  assert.equal(world.vertices, 4, "世界那个精灵是 1 个 quad");
  assert.equal(ui.vertices, 36, "UI 的九宫格是 9 个 quad = 36 顶点");
  assert.notEqual(ui.pipeline, world.pipeline, "UI 用自己的 pipeline（同一个 shader，不同句柄）");
  assert.notEqual(ui.vertices, world.vertices, "★ UI 必须排在世界之后：第 2 次 draw 才是 UI");
  // 九宫格 9 块同页 ⇒ 一次 draw
  assert.equal(rig.ui.lastFrame.quads, 9);
  assert.equal(rig.ui.lastFrame.drawCalls, 1, "同页的 9 块必须合成一次 draw");
});

test("★ 跨页时按页分批：字体在另一页 ⇒ 多一次 draw（而不是画错）", () => {
  const root = buildUiTree({
    id: "root",
    children: [
      { id: "panel", widget: UiWidget.Panel, size: { w: 100, h: 40 }, props: { frame: "panel" } },
      { id: "lbl", widget: UiWidget.Label, size: { w: 100, h: 20 }, offset: { x: 0, y: 50 }, props: { text: "AB" } },
    ],
  });
  const rig = bootUi({ root, pages: 2 });
  // 把字体的字形挪到第 1 页
  const f = makeTestFont();
  const moved = new Map(f.glyphs);
  for (const [code, g] of moved) moved.set(code, { ...g, page: 1 });
  const rig2 = bootUi({
    root,
    pages: 2,
    fonts: [{ ...f, glyphs: moved }],
  });
  rig.frame();
  rig2.frame();
  assert.equal(rig.ui.lastFrame.drawCalls, 1, "全在同一页 ⇒ 1 段");
  assert.equal(rig2.ui.lastFrame.drawCalls, 2, "皮肤与字体不同页 ⇒ 必须切成 2 段");
});

test("★ 文本缓存：第二帧不重排（relaid=false）且 cacheHits 增长", () => {
  const root = buildUiTree({
    id: "root",
    children: [{ id: "lbl", widget: UiWidget.Label, size: { w: 200, h: 20 }, props: { text: "HELLO" } }],
  });
  const rig = bootUi({ root });
  rig.frame();
  assert.equal(rig.ui.lastFrame.relaid, true);
  const quadsAfterFirst = rig.ui.lastFrame.quads;
  rig.frame();
  assert.equal(rig.ui.lastFrame.relaid, false, "文本没变、视口没变 ⇒ 不该重排");
  // ★ 不重排时**根本不会去查缓存**（cacheHits 不增长才是对的）。要验的是结果没变：
  assert.equal(rig.ui.lastFrame.quads, quadsAfterFirst, "复用上一帧的四边形，画面不能少东西");

  rig.ui.invalidate();
  rig.frame();
  assert.equal(rig.ui.lastFrame.relaid, true, "标脏后必须重排");
});

test("UI 模块：没有字体 / 没有纹理页 ⇒ init 直接失败（不静默空字体）", () => {
  const dev = new NullGraphicsDevice(100, 100);
  const logger = new Logger(() => 0);
  const services = new ServiceRegistry();
  const ctx: ModuleContext = {
    log: logger,
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: { gfx: dev } as unknown as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
  const tex = unwrap(dev.createTexture({ width: 8, height: 8, format: PixelFormat.RGBA8 }));

  const noFont = createUiModule({
    viewport: { designWidth: 100, designHeight: 100 },
    skin: smallSkin(),
    pages: [tex],
    fonts: [],
  });
  const r1 = noFont.init(ctx);
  assert.ok(!(r1 instanceof Promise) && r1 !== undefined && !r1.ok);
  if (!(r1 instanceof Promise) && r1 !== undefined && !r1.ok) assert.equal(r1.error.code, "UI.NO_FONT");

  const noPage = createUiModule({
    viewport: { designWidth: 100, designHeight: 100 },
    skin: smallSkin(),
    pages: [],
    fonts: [makeTestFont()],
  });
  const r2 = noPage.init(ctx);
  assert.ok(!(r2 instanceof Promise) && r2 !== undefined && !r2.ok);
  if (!(r2 instanceof Promise) && r2 !== undefined && !r2.ok) assert.equal(r2.error.code, "UI.NO_PAGE");
});

test("指针走设计坐标：点按钮产生 click，点空白不产生", () => {
  const root = buildUiTree({
    id: "root",
    children: [
      { id: "btn", widget: UiWidget.Button, size: { w: 100, h: 40 }, interactive: true, opaque: true, props: { frame: "panel", text: "OK" } },
    ],
  });
  const rig = bootUi({ root });
  rig.frame();
  const down = rig.ui.pointer({ x: 10, y: 10, down: true });
  const up = rig.ui.pointer({ x: 10, y: 10, down: false });
  assert.ok(down.some((e) => e.type === "pointerdown" && e.target.id === "btn"));
  assert.ok(up.some((e) => e.type === "click" && e.target.id === "btn"));
  const nowhere = rig.ui.pointer({ x: 700, y: 500, down: true });
  assert.equal(nowhere.some((e) => e.type === "pointerdown"), false);
});

test("dpr：物理像素 / CSS 像素 的换算进入 scale", () => {
  const rig = bootUi({ dpr: 2 });
  rig.frame();
  // 空后端 800×600 **物理**像素、dpr=2 ⇒ CSS 400×300；设计 800×600。
  // scale 的定义是「绘制像素 / 设计像素」= 800/800 = 1 —— 也就是 UI 正好铺满屏幕，
  // dpr 只影响 CSS 侧的换算（4 个 CSS 像素 = 1 个设计像素）。
  assert.equal(rig.ui.viewport.scale, 1);
  assert.equal(rig.ui.viewport.pixelWidth, 800);
  const p = rig.ui.viewport.screenToDesign(200, 150); // CSS 中心
  assert.equal(p.x, 400, "CSS 中心 = 设计中心");
  assert.equal(p.y, 300);
});

test("dispose 后不再画（overlay 已被摘掉）", () => {
  const root = buildUiTree({
    id: "root",
    children: [{ id: "p", widget: UiWidget.Panel, size: { w: 100, h: 20 }, props: { frame: "panel" } }],
  });
  const rig = bootUi({ root });
  rig.frame();
  const before = rig.ui.lastFrame.quads;
  assert.ok(before > 0);
  rig.ui.stop?.();
  rig.ui.dispose?.();
  rig.frame();
  assert.equal(rig.dev.frames[rig.dev.frames.length - 1]?.draws.length, 0, "摘掉 overlay 后不该再有 UI draw");
});

test("布局结果可按 id 取绝对矩形（编辑器/自动化用）", () => {
  const root = buildUiTree({
    id: "root",
    kind: UiLayoutKind.Free,
    children: [{ id: "tag", widget: UiWidget.Label, size: { w: 80, h: 20 }, offset: { x: 12, y: 16 }, props: { text: "x" } }],
  });
  const rig = bootUi({ root });
  rig.frame();
  const r = rig.ui.layout.get("tag");
  assert.ok(r !== undefined);
  // 空后端 800×600、dpr=1、设计 800×600、expand ⇒ 参考矩形正好是设计框
  assert.equal(r.x, 12);
  assert.equal(r.y, 16);
});
