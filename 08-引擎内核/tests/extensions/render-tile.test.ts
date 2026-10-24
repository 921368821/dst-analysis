/**
 * L4 · 地形平铺测试（T288）
 *
 * 现象：一块矩形一个精灵 ⇒ 64×64 的噪点被拉伸到整块上，大块地形的颗粒明显变粗。
 * 修法：地形走**独立的 repeat 瓦片页**，按格平铺（`tileX/tileY` = 矩形格数）。
 *
 * ★★ 这个文件守四个**各自独立**的失效方式（少任何一个，另外三个都还是绿的）：
 *   ① 瓦片页没抽出来 / 抽错 ⇒ 平铺会把**邻居帧**采进来（"每隔几格一块树"）；
 *   ② 平铺次数没传进 batch ⇒ UV 仍是 0..1，画面与修之前一模一样；
 *   ③ 分段没做 ⇒ 第二段把第一段的几何再画一遍（画面重复而不是切换贴图）；
 *   ④ 平铺落在 clamp 页上 ⇒ 接缝被抻成脏边，而精灵的所有数字都对。
 *
 * ③ 与 ④ 是这条链上最隐蔽的两个：它们都不改任何"能看见的数字"，
 * 只有 draw 记录与日志里留得下证据 —— 所以判据必须读到那一层。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { Logger, MemorySink, LogLevel } from "../../src/foundation/log/logger.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import type { FrameInfo } from "../../src/core/frame-host.ts";
import { Camera2D } from "../../src/extensions/render/camera.ts";
import { SpriteBatch, type RenderItem } from "../../src/extensions/render/batch2d.ts";
import { buildProceduralAtlas, buildTilePages, tilePageName, type AtlasData } from "../../src/extensions/render/atlas.ts";
import { NullGraphicsDevice } from "../../src/backends/gfx-null/device.ts";
import { PixelFormat } from "../../src/platform/gfx/types.ts";
import { createRenderModule, spriteToRenderItem } from "../../src/extensions/render/render-module.ts";
import { Services } from "../../src/core/tokens.ts";
import { SPRITE_TYPE, Sprite } from "../../src/extensions/render/sprite.ts";
import { TERRAIN_TILE_PAGE, TERRAIN_FRAME, attachWorldVisuals } from "../../src/extensions/render/world-visuals.ts";
import { registerWorldComponents, assembleWorld } from "../../src/extensions/worldgen/assemble.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";

// ── ① 瓦片页：抽得对，才敢平铺 ────────────────────────────────

test("★ 瓦片页：尺寸 = 帧尺寸、wrap = repeat、单帧铺满 0..1、页名集中一处", () => {
  const main = buildProceduralAtlas();
  const pages = buildTilePages(main, [TERRAIN_FRAME]);
  assert.equal(pages.length, 1, "terrain 帧应抽出一页");
  const p = pages[0]!;
  const f = main.frames.get(TERRAIN_FRAME)!;
  assert.equal(p.width, f.w);
  assert.equal(p.height, f.h);
  assert.equal(p.wrap, "repeat", "瓦片页必须 repeat —— clamp 页平铺会把接缝抻成脏边");
  assert.equal(p.name, tilePageName(TERRAIN_FRAME));
  assert.equal(p.name, TERRAIN_TILE_PAGE, "页名必须与 world-visuals 用的是同一个常量");
  const only = p.frames.get(TERRAIN_FRAME);
  assert.ok(only !== undefined, "瓦片页里必须有那一帧");
  assert.deepEqual(
    { u0: only.u0, v0: only.v0, u1: only.u1, v1: only.v1 },
    { u0: 0, v0: 0, u1: 1, v1: 1 },
    "瓦片页里帧必须铺满整页 —— 邻居不存在，repeat 才只重复自己",
  );
});

test("★ 瓦片页的像素与主图集那一帧**逐字节相同**（抽错矩形 = 平铺错贴图）", () => {
  const main = buildProceduralAtlas();
  const p = buildTilePages(main, [TERRAIN_FRAME])[0]!;
  const f = main.frames.get(TERRAIN_FRAME)!;
  const x0 = Math.round(f.u0 * main.width);
  const y0 = Math.round(f.v0 * main.height);
  for (let y = 0; y < f.h; y++) {
    const from = ((y0 + y) * main.width + x0) * 4;
    const to = y * f.w * 4;
    assert.deepEqual(
      [...p.pixels.subarray(to, to + f.w * 4)],
      [...main.pixels.subarray(from, from + f.w * 4)],
      `第 ${y} 行不一致 —— 抽帧矩形错了（画面上是另一块内容在平铺）`,
    );
  }
});

test("★ 瓦片页：帧不存在就不建页（不能让调用方拿到一页空纹理）", () => {
  const main = buildProceduralAtlas();
  assert.equal(buildTilePages(main, ["nope"]).length, 0);
  assert.equal(buildTilePages(main, []).length, 0);
});

test("★ 瓦片页：16 位主图集抽出 16 位页，且 pixels === round(pixels16/257)", () => {
  const main = buildProceduralAtlas();
  const f = main.frames.get(TERRAIN_FRAME)!;
  // 造一个 16 位主图集（只留 terrain 一帧，够验抽取）
  const w = f.w;
  const h = f.h;
  const p16 = new Uint16Array(w * h * 4);
  for (let i = 0; i < p16.length; i++) p16[i] = (i * 37) % 65536;
  const px = new Uint8Array(w * h * 4);
  for (let i = 0; i < px.length; i++) px[i] = Math.round(p16[i]! / 257);
  const wide: AtlasData = {
    width: w,
    height: h,
    pixels: px,
    format: PixelFormat.RGBA16,
    pixels16: p16,
    frames: new Map([[TERRAIN_FRAME, { u0: 0, v0: 0, u1: 1, v1: 1, w, h }]]),
  };
  const page = buildTilePages(wide, [TERRAIN_FRAME])[0]!;
  assert.equal(page.format, PixelFormat.RGBA16, "16 位页不能悄悄降成 8 位");
  assert.ok(page.pixels16 !== undefined, "16 位页必须带 pixels16");
  assert.deepEqual([...page.pixels16], [...p16], "16 位像素必须原样抽出");
  for (let i = 0; i < page.pixels.length; i++) {
    assert.equal(page.pixels[i], Math.round(page.pixels16![i]! / 257), `8 位视图第 ${i} 个与 16 位不满足派生关系`);
  }
});

// ── ② 平铺真的进了顶点 ────────────────────────────────────────

function item(p: Partial<RenderItem> & { nodeId: number; z: number }): RenderItem {
  return {
    x: 0,
    w: 1,
    h: 1,
    u0: 0,
    v0: 0,
    u1: 0.25,
    v1: 0.5,
    r: 1,
    g: 1,
    b: 1,
    a: 1,
    order: 0,
    pivotY: 0.5,
    pivotX: 0.5,
    atlas: 0,
    ...p,
  };
}

/** 取第 q 个四边形的（u 最小值, u 最大值, v 最小值, v 最大值）。 */
function uvSpan(batch: SpriteBatch, q: number): { u0: number; u1: number; v0: number; v1: number } {
  const o = q * 32; // 4 顶点 × 8 float
  const us = [batch.vertices[o + 2]!, batch.vertices[o + 10]!, batch.vertices[o + 18]!, batch.vertices[o + 26]!];
  const vs = [batch.vertices[o + 3]!, batch.vertices[o + 11]!, batch.vertices[o + 19]!, batch.vertices[o + 27]!];
  return { u0: Math.min(...us), u1: Math.max(...us), v0: Math.min(...vs), v1: Math.max(...vs) };
}

test("★ 平铺次数进顶点：tileX=3 / tileY=2 ⇒ UV 跨度各乘 3 / 2，位置列不动", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.5 });
  const b = new SpriteBatch(16);
  const built = b.build([item({ nodeId: 1, z: 0, tileX: 3, tileY: 2 })], cam);
  assert.equal(built.quadCount, 1);
  const span = uvSpan(b, 0);
  assert.ok(Math.abs(span.u1 - span.u0 - 0.25 * 3) < 1e-6, `u 跨度应是 3×帧宽（0.75），实际 ${span.u1 - span.u0}`);
  assert.ok(Math.abs(span.v1 - span.v0 - 0.5 * 2) < 1e-6, `v 跨度应是 2×帧高（1.0），实际 ${span.v1 - span.v0}`);
  // 位置列（前两个 float）必须与不平铺时完全一致：平铺只改 UV
  const plain = new SpriteBatch(16);
  plain.build([item({ nodeId: 1, z: 0 })], cam);
  for (let i = 0; i < 8; i++) {
    if (i === 2 || i === 3 || i === 10 || i === 11 || i === 18 || i === 19 || i === 26 || i === 27) continue;
    assert.equal(b.vertices[i], plain.vertices[i], `第 ${i} 个 float（位置/颜色）被平铺改动了`);
  }
});

test("★ 平铺次数是垃圾值时按 1 处理（0 / 负数 / 1.7 都不许产生怪 UV）", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.5 });
  for (const bad of [0, -3, 1.7]) {
    const b = new SpriteBatch(4);
    b.build([item({ nodeId: 1, z: 0, tileX: bad, tileY: bad })], cam);
    const span = uvSpan(b, 0);
    assert.ok(Math.abs(span.u1 - span.u0 - 0.25) < 1e-6, `tileX=${bad} 的 u 跨度应退回 1×，实际 ${span.u1 - span.u0}`);
    assert.ok(Math.abs(span.v1 - span.v0 - 0.5) < 1e-6, `tileY=${bad} 的 v 跨度应退回 1×，实际 ${span.v1 - span.v0}`);
  }
});

// ── ③ 分段：几次 draw、每段绑哪张纹理 ─────────────────────────

test("★★ 多页时分段：drawCalls = 段数，每段一个槽位，z 序不被分段破坏", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.5 });
  const b = new SpriteBatch(16);
  const built = b.build(
    [
      item({ nodeId: 1, z: 10, atlas: 1 }), // 瓦片页（远）
      item({ nodeId: 2, z: 5, atlas: 0 }), // 主图集
      item({ nodeId: 3, z: 1, atlas: 1 }), // 瓦片页（近）
    ],
    cam,
  );
  // ★ z 序（远先画）不可牺牲，所以 1→0→1 是**三段**，不是两段。
  //   "先画完所有 1 页再画 0 页"只要两段，但会让近处的瓦片页被远处的主图集盖住 —— 那是错。
  assert.equal(built.drawCalls, 3, `z 序打散的两页应是 3 段，实际 ${built.drawCalls}`);
  assert.deepEqual(built.runs.map((r) => r.atlas), [1, 0, 1], "段顺序必须跟随排好的序");
  assert.equal(built.runs.reduce((n, r) => n + r.count, 0), 3, "所有 quad 都必须归进某一段");
  assert.equal(built.atlasSwitches, 3);
  // 段内 quad 连续：start 必须首尾相接
  let expectStart = 0;
  for (const r of built.runs) {
    assert.equal(r.start, expectStart, "段起点不连续 —— 有 quad 被漏掉或重复归段");
    expectStart += r.count;
  }
  assert.equal(expectStart, 3);

  // 同页相邻时仍合并成一段（批处理没有白做）
  const adj = new SpriteBatch(16).build(
    [item({ nodeId: 1, z: 3, atlas: 1 }), item({ nodeId: 2, z: 2, atlas: 1 }), item({ nodeId: 3, z: 1, atlas: 0 })],
    cam,
  );
  assert.equal(adj.drawCalls, 2, "同页相邻必须合并");
  assert.deepEqual(adj.runs.map((r) => [r.atlas, r.count]), [[1, 2], [0, 1]]);
});

test("★ 单页仍是 1 段；空场景 0 段 0 draw（不许为「没有东西」付一次 draw）", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.5 });
  const one = new SpriteBatch(8).build([item({ nodeId: 1, z: 0 }), item({ nodeId: 2, z: -1 })], cam);
  assert.equal(one.drawCalls, 1);
  assert.equal(one.runs.length, 1);
  const none = new SpriteBatch(8).build([], cam);
  assert.equal(none.drawCalls, 0);
  assert.equal(none.runs.length, 0);
});

// ── ②b 分层：layer 在 z 之前（T288 收尾：draw 29 → 2） ───────

test("★★ layer 优先于 z：背景（地面）整体先画，哪怕单个地形更远", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.5 });
  const b = new SpriteBatch(16);
  const built = b.build(
    [
      item({ nodeId: 1, z: 10, atlas: 1, layer: 0 }), // 地形：远
      item({ nodeId: 2, z: 1, atlas: 1, layer: 0 }), // 地形：近
      item({ nodeId: 3, z: 100, atlas: 0 }), // 实体：最远（缺 layer ⇒ 当 1）
      item({ nodeId: 4, z: 50, atlas: 0, layer: 1 }), // 实体
    ],
    cam,
  );
  // ★ 两个 layer 0 必须整体排在两个实体之前，即使实体的 z 大得多。
  //   不分层时 z=100 的实体先画、z=1 的地形最后画 ⇒ 近处地面盖住最远的树。
  assert.deepEqual(b.items.map((i) => i.nodeId), [1, 2, 3, 4], "背景层必须整体先画");
  // 地形同在瓦片页（1）、实体同在住图集（0）⇒ 两段，不是四段
  assert.equal(built.drawCalls, 2, `同层同页应各并一段，实际 ${built.drawCalls}`);
  assert.deepEqual(built.runs.map((r) => [r.atlas, r.count]), [[1, 2], [0, 2]]);
});

test("★★ 层内 z 降序完整保留（layer 不许把遮挡关系一起简化掉）", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.5 });
  for (const layer of [0, 1]) {
    const b = new SpriteBatch(16);
    b.build(
      [
        item({ nodeId: 1, z: 5, layer }),
        item({ nodeId: 2, z: 50, layer }),
        item({ nodeId: 3, z: 20, layer }),
      ],
      cam,
    );
    assert.deepEqual(b.items.map((i) => i.nodeId), [2, 3, 1], `layer=${layer} 层内必须是 z 降序`);
  }
});

test("★ 缺 layer 的 RenderItem 当实体（1）—— 默认 0 会让旧内容整体掉到地形背后", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.5 });
  const b = new SpriteBatch(8);
  b.build(
    [
      item({ nodeId: 1, z: 100 }), // 缺 layer：很远，但它是实体
      item({ nodeId: 2, z: 0, layer: 0 }), // 地形：近
    ],
    cam,
  );
  assert.deepEqual(b.items.map((i) => i.nodeId), [2, 1], "缺 layer 的精灵必须画在地形之后");
});

test("★★ spriteToRenderItem 搬运 layer（漏一个字段 = 分层静默失效，M139 同款形状）", () => {
  const s = new Sprite();
  s.layer = 0;
  const f = { u0: 0, v0: 0, u1: 0.5, v1: 0.5, w: 32, h: 32 };
  const it = spriteToRenderItem(s, f, 7, 1, 2, 1);
  assert.equal(it.layer, 0, "layer 没有从 Sprite 搬进 RenderItem —— 组件上有、batch 看不到");
  const dflt = spriteToRenderItem(new Sprite(), f, 7, 1, 2, 0);
  assert.equal(dflt.layer, 1, "默认 Sprite 的 layer 必须是 1");
});

// ── ④ 渲染模块：页、绑定、告警 ────────────────────────────────

interface Rig {
  dev: NullGraphicsDevice;
  scene: Scene;
  sink: MemorySink;
  render: (info?: FrameInfo) => void;
}

/** 起一个只挂渲染模块的最小 rig（null 后端 + 内存日志 + 假 FrameHost）。 */
function boot(opts: { atlas?: AtlasData; tileFrames?: readonly string[] } = {}): Rig {
  const reg = new ComponentRegistry();
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("t", reg);
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
  services.provide(Services.Frame, frameHost as never, "test.render-tile");
  services.provide(Services.Scene, scene, "test.render-tile");
  const ctx: ModuleContext = {
    log: logger,
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: { gfx: new NullGraphicsDevice(800, 600) } as unknown as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
  const mod = createRenderModule({
    viewportWidth: 800,
    viewportHeight: 600,
    zoom: 32,
    atlas: opts.atlas,
    tileFrames: opts.tileFrames,
  });
  const r = mod.init(ctx);
  // ★ assert 的消息参数是**立即求值**的：写成 `r.error.code` 会在 r 为 Ok 时先炸，
  //   于是"init 失败"这条判据自己变成运行时错误（判据错比没有判据更坏）。
  const why = r instanceof Promise ? "异步" : r === undefined || r.ok ? "" : `${r.error.code} ${r.error.message}`;
  assert.ok(!(r instanceof Promise) && (r === undefined || r.ok), `init 失败：${why}`);
  mod.start?.();
  return {
    dev: ctx.platform.gfx as unknown as NullGraphicsDevice,
    scene,
    sink,
    render: (info) => renders.forEach((f) => f(info ?? { frame: 1, realDtSec: 1 / 60, steps: 1, alpha: 0, tick: 1 })),
  };
}

function addSprite(scene: Scene, p: { frame: string; atlasId?: string; tileX?: number; tileY?: number; layer?: number; x: number; z: number }): void {
  const s = scene.spawn(`n${Math.random()}`, null);
  assert.ok(s.ok, `spawn 失败：${s.ok ? "" : s.error.message}`);
  scene.flush();
  const node = scene.find(s.value.id)!;
  node.setLocalPosition(p.x, p.z);
  // ★ 必须走 `scene.attach`（入队 + flush）而不是 `node.attach`：
  //   `componentsOf` 读的是场景的组件索引，`node.attach` 只挂到节点上 ——
  //   于是"精灵明明在节点上，渲染模块一个都看不到"（节点上有、索引里没有）。
  const made = scene.attach(s.value.id, () => {
    const sp = new Sprite();
    sp.frame = p.frame;
    sp.atlasId = p.atlasId ?? "";
    sp.tileX = p.tileX ?? 1;
    sp.tileY = p.tileY ?? 1;
    sp.layer = p.layer ?? 1;
    return sp;
  });
  assert.ok(made.ok, `attach 失败：${made.ok ? "" : made.error.message}`);
  scene.flush();
}


test("★★ 默认配置就抽出瓦片页：2 张纹理、瓦片页 repeat、label 可辨", () => {
  const rig = boot();
  assert.equal(rig.dev.textureHandles.length, 2, `应有 2 张纹理（主图集 + 瓦片页），实际 ${rig.dev.textureHandles.length}`);
  const wraps = rig.dev.textureHandles.map((h) => rig.dev.textureWrap(h));
  assert.equal(wraps.filter((w) => w === "repeat").length, 1, `应恰有一页 repeat，实际 ${wraps.join(",")}`);
  assert.equal(wraps.filter((w) => w === "clamp").length, 1, "主图集必须仍是 clamp（不许整张开 repeat）");
});

test("★★ 每段绑定自己的纹理、从自己的索引起点画（少了 firstIndex 会重画第一段）", () => {
  const rig = boot();
  addSprite(rig.scene, { frame: TERRAIN_FRAME, atlasId: TERRAIN_TILE_PAGE, tileX: 4, tileY: 3, x: 0, z: 5 });
  addSprite(rig.scene, { frame: "tree", x: 0, z: 0 });
  addSprite(rig.scene, { frame: "rock", x: 0, z: -5 });
  rig.render();
  const last = rig.dev.frames[rig.dev.frames.length - 1]!;
  assert.equal(last.draws.length, 2, `两页应各一次 draw，实际 ${last.draws.length}`);
  // ① 两次 draw 绑的不是同一张纹理（分段没生效时会是同一张）
  assert.notEqual(last.draws[0]!.textures[0], last.draws[1]!.textures[0], "两次 draw 绑了同一张纹理 —— 分段没生效");
  // ② 第二段必须从**自己的**索引起点开始：z 序（远先画）⇒ 瓦片页（z=5）在前，
  //    所以主图集段的 firstIndex 必须是 6（1 个 quad 的索引数），不是 0。
  assert.equal(last.draws[1]!.firstIndex, 6, `第二段的 firstIndex 应是 6，实际 ${last.draws[1]!.firstIndex} —— 传 0 会把第一段的几何再画一遍`);
  // ③ 每段的索引数 = 该段 quad 数 × 6（两页各 1 与 2 个 quad）
  assert.equal(last.draws[0]!.indices, 6, "第一段应只有 1 个 quad 的索引");
  assert.equal(last.draws[1]!.indices, 12, "第二段应有 2 个 quad 的索引");
});

test("★★★ 地形与实体 z 序交错：draw 仍是页数（分层回归：T288 后曾退化成 29 段）", () => {
  // ★ 这条判据的形状就是那次退化的形状：地形 z = 矩形左上角格子坐标、
  //   实体 z = 格子中心，两者必然交错。没有 layer 时按 z 全局混排，
  //   瓦片页被主图集打散成 N 段（实测 116 块地形 + 110 个精灵 ⇒ 29 次 draw）。
  const rig = boot();
  for (let i = 0; i < 3; i++) {
    addSprite(rig.scene, { frame: TERRAIN_FRAME, atlasId: TERRAIN_TILE_PAGE, tileX: 2, tileY: 2, layer: 0, x: 0, z: i });
    addSprite(rig.scene, { frame: i % 2 === 0 ? "tree" : "rock", layer: 1, x: 0, z: i + 0.5 });
  }
  rig.render();
  const last = rig.dev.frames[rig.dev.frames.length - 1]!;
  assert.equal(last.draws.length, 2, `交错场景应只有 2 段（瓦片页 + 主图集），实际 ${last.draws.length}`);
  // 背景段在前（先画地面），实体段在后
  assert.equal(last.draws[0]!.indices, 18, "背景段应含 3 个地形 quad");
  assert.equal(last.draws[1]!.indices, 18, "实体段应含 3 个精灵 quad");
  assert.equal(last.draws[1]!.firstIndex, 18, "实体段必须从自己的索引起点画");
});

test("★★ 未知 atlasId：回落到主图集，但必须**告警**（不静默换贴图）", () => {
  const rig = boot();
  addSprite(rig.scene, { frame: "tree", atlasId: "不存在的页", x: 0, z: 0 });
  rig.render();
  const warns = rig.sink.records().filter((r) => r.level === LogLevel.Warn);
  assert.ok(
    warns.some((w) => w.message.includes("不存在的页")),
    `未知 atlasId 没有告警 —— 静默回落的表现是"用了另一张贴图"，而组件上的名字看起来是对的`,
  );
  // 仍然画出来了（回落到主图集，不是整帧消失）
  assert.equal(rig.dev.frames[rig.dev.frames.length - 1]!.draws.length, 1);
});

test("★★ clamp 页上平铺：告警点名 atlasId 与 tile 次数（接缝脏边不许静默）", () => {
  const rig = boot();
  addSprite(rig.scene, { frame: "tree", tileX: 4, x: 0, z: 0 }); // tree 在主图集（clamp）
  rig.render();
  const warns = rig.sink.records().filter((r) => r.level === LogLevel.Warn);
  assert.ok(
    warns.some((w) => w.message.includes("clamp") && w.message.includes("tileX=4")),
    "clamp 页平铺没有告警 —— 这类错所有数字都对，只有日志留得下证据",
  );
});

// ── ⑤ 世界可见化：地形按格平铺 ────────────────────────────────

test("★ 地形精灵：页 = 瓦片页、tile = 矩形格数（颗粒不再随块变大）", () => {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("w", reg);
  const g = generateWorld({ seed: 7, width: 32, height: 24, maxSitesPerCell: 2 });
  assert.ok(g.ok);
  assert.ok(assembleWorld(g.value, scene).ok);
  const r = attachWorldVisuals(scene, [...buildProceduralAtlas().frames.keys()]);
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);

  const sprites = [...scene.componentsOf<Sprite>(SPRITE_TYPE)];
  const terrains = sprites.filter((s) => s.atlasId === TERRAIN_TILE_PAGE);
  assert.ok(terrains.length > 0, "没有任何地形用上瓦片页 —— T288 没接线");
  for (const s of terrains) {
    assert.equal(s.frame, TERRAIN_FRAME);
    assert.equal(s.layer, 0, "地形必须是背景层（layer 0）—— 否则会被 z 序打散、且能盖住实体");
    assert.ok(Number.isInteger(s.tileX) && s.tileX >= 1, `tileX 必须是正整数，实际 ${s.tileX}`);
    assert.ok(Number.isInteger(s.tileY) && s.tileY >= 1, `tileY 必须是正整数，实际 ${s.tileY}`);
    // 一块 w×h 的地形铺 w×h 张：tile 必须等于精灵的世界尺寸（格）
    assert.equal(s.tileX, s.width, "tileX 必须等于地形格宽");
    assert.equal(s.tileY, s.height, "tileY 必须等于地形格高");
  }
  // 其它精灵不许被平铺（树/石头/浆果平铺 = 把邻居帧采进来）
  const others = sprites.filter((s) => s.atlasId !== TERRAIN_TILE_PAGE);
  assert.ok(others.length > 0, "场景里只有地形，判据分辨力不足");
  for (const s of others) {
    assert.equal(s.layer, 1, `${s.frame} 不是实体层（layer ${s.layer}）—— 非地形都该默认 1`);
    assert.equal(s.tileX, 1, `${s.frame} 被平铺了 —— 只有地形该平铺`);
    assert.equal(s.tileY, 1, `${s.frame} 被平铺了 —— 只有地形该平铺`);
    assert.equal(s.atlasId, "", "非地形精灵不该换页");
  }
});

test("★ Sprite.layer 默认 1：旧内容 / 旧存档不能因为缺字段掉到地形背后", () => {
  assert.equal(new Sprite().layer, 1, "默认值必须是 1（实体）；0 会让所有旧精灵一帧不显示");
});
