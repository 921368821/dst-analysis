/**
 * L4 · 全屏幕布（渲染侧，批98）
 *
 * 状态机只管"第几拍该多黑"，而**"那片黑真的画到屏幕上了没有"**是这一层的事。
 * 两者必须分开验：`setCurtain(1)` 调了、`alpha` 也算对了，顶点缓冲没建出来时
 * 画面照样是亮的，而所有状态都正常（假绿）。
 *
 * ★ 这条链上有三个各自独立的失效方式：
 *   ① 顶点坐标不在裁剪空间 `-1..1` ⇒ 幕布半屏或压根在屏幕外；
 *   ② 顶点数不是 6（4 个顶点 + 三角形列表）⇒ 只画出半个屏幕，看起来像"渐变的斜角"；
 *   ③ `setCurtain` 与绘制没接上 ⇒ 状态对、画面不对。
 *   所以下面既验纯函数（①②），也验模块真的多了一次 draw（③）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { Logger, MemorySink } from "../../src/foundation/log/logger.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import type { FrameInfo } from "../../src/core/frame-host.ts";
import { FLOATS_PER_SPRITE_VERTEX } from "../../src/platform/gfx/types.ts";
import { NullGraphicsDevice } from "../../src/backends/gfx-null/device.ts";
import { createRenderModule, curtainQuad } from "../../src/extensions/render/render-module.ts";
import { Services } from "../../src/core/tokens.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";

// ── ① 纯函数：几何与颜色 ──────────────────────────────────────

test("★★ 幕布是 6 个顶点（4 个顶点的三角形列表只画半个屏幕）", () => {
  const v = curtainQuad(1);
  assert.equal(v.length, 6 * FLOATS_PER_SPRITE_VERTEX, "顶点数必须是 6：两个三角形，不是 4 个");
});

test("★★ 四个角都盖到：x 与 y 都取遍 -1 和 1", () => {
  const v = curtainQuad(1);
  const xs = new Set<number>();
  const ys = new Set<number>();
  for (let i = 0; i < 6; i++) {
    xs.add(v[i * FLOATS_PER_SPRITE_VERTEX] ?? NaN);
    ys.add(v[i * FLOATS_PER_SPRITE_VERTEX + 1] ?? NaN);
  }
  assert.deepEqual([...xs].sort((a, b) => a - b), [-1, 1], "x 必须铺满裁剪空间");
  assert.deepEqual([...ys].sort((a, b) => a - b), [-1, 1], "y 必须铺满裁剪空间");
});

test("★★ 每个顶点的 alpha 都等于幕布不透明度，颜色是黑", () => {
  for (const a of [0, 0.25, 0.5, 1]) {
    const v = curtainQuad(a);
    for (let i = 0; i < 6; i++) {
      const at = i * FLOATS_PER_SPRITE_VERTEX;
      assert.equal(v[at + 4], 0, "红必须是 0");
      assert.equal(v[at + 5], 0, "绿必须是 0");
      assert.equal(v[at + 6], 0, "蓝必须是 0");
      assert.equal(v[at + 7], a, `第 ${String(i)} 个顶点的 alpha 不是 ${String(a)} —— 顶点色不一致会出现渐变`);
    }
  }
});

test("★★ uv 一律 0：幕布走 `u_useTexture = 0` 的纯色路径，采样了就会去读别人的帧", () => {
  const v = curtainQuad(0.5);
  for (let i = 0; i < 6; i++) {
    assert.equal(v[i * FLOATS_PER_SPRITE_VERTEX + 2], 0);
    assert.equal(v[i * FLOATS_PER_SPRITE_VERTEX + 3], 0);
  }
});

test("★★ 越界与 NaN 一律夹回 0..1（NaN 传到 GPU 是整屏变黑，而那时没有任何计数会变）", () => {
  assert.equal(curtainQuad(2)[7], 1, "大于 1 夹成 1");
  assert.equal(curtainQuad(-1)[7], 0, "小于 0 夹成 0");
  assert.equal(curtainQuad(Number.NaN)[7], 0, "NaN 当 0");
  assert.equal(curtainQuad(Number.POSITIVE_INFINITY)[7], 0, "Infinity 当 0（它不是个「很黑」的值，是算错了）");
});

// ── ② 接线：状态说要画，就真的多一次 draw ────────────────────

interface Rig {
  dev: NullGraphicsDevice;
  mod: ReturnType<typeof createRenderModule>;
  frame: () => void;
}

function boot(): Rig {
  const reg = new ComponentRegistry();
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("t", reg);
  const logger = new Logger(() => 0);
  logger.addSink(new MemorySink());
  const renders: Array<(info: FrameInfo) => void> = [];
  const frameHost = {
    onRender(fn: (info: FrameInfo) => void): () => void {
      renders.push(fn);
      return () => void renders.splice(renders.indexOf(fn), 1);
    },
  };
  const services = new ServiceRegistry();
  services.provide(Services.Frame, frameHost as never, "test.render-curtain");
  services.provide(Services.Scene, scene, "test.render-curtain");
  const dev = new NullGraphicsDevice(800, 600);
  const ctx: ModuleContext = {
    log: logger,
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: { gfx: dev } as unknown as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
  const mod = createRenderModule({ viewportWidth: 800, viewportHeight: 600, zoom: 32 });
  const r = mod.init(ctx);
  // ★ 断言的消息是**立即求值**的：写成 `r.error.code` 会在 r 为 Ok 时先炸。
  const why = r instanceof Promise ? "异步" : r === undefined || r.ok ? "" : `${r.error.code} ${r.error.message}`;
  assert.ok(!(r instanceof Promise) && (r === undefined || r.ok), `init 失败：${why}`);
  mod.start?.();
  return {
    dev,
    mod,
    frame: () => {
      for (const f of renders) f({ frame: 1, realDtSec: 1 / 60, steps: 1, alpha: 0, tick: 1 });
    },
  };
}

test("★★ 幕布 alpha = 0 时不画（多画一次就是「世界被一层全透明的东西盖着」，白费 bandwidth）", () => {
  const rig = boot();
  rig.mod.setCurtain(0);
  rig.frame();
  const base = rig.dev.frames[rig.dev.frames.length - 1]?.draws.length ?? 0;
  assert.equal(rig.mod.lastCurtain.drawn, false);
  assert.equal(base, 0, "空场景 + 没幕布 ⇒ 一次 draw 都不该有");
});

test("★★ 幕布 alpha > 0 时**多出恰好一次** draw，且报告 drawn = true", () => {
  const rig = boot();
  rig.mod.setCurtain(0);
  rig.frame();
  const base = rig.dev.frames[rig.dev.frames.length - 1]?.draws.length ?? 0;

  rig.mod.setCurtain(0.5);
  rig.frame();
  const withCurtain = rig.dev.frames[rig.dev.frames.length - 1]?.draws.length ?? 0;
  assert.equal(withCurtain, base + 1, "幕布必须是**一次** draw（6 个顶点两个三角形，不是两次）");
  assert.equal(rig.mod.lastCurtain.drawn, true, "真的画了才能说画了");
  assert.equal(rig.mod.lastCurtain.alpha, 0.5, "报告里的 alpha 要与推进去的一致");
});

test("★ 撒掉幕布之后又回到不画（停播之后不许留一块黑）", () => {
  const rig = boot();
  rig.mod.setCurtain(1);
  rig.frame();
  assert.equal(rig.mod.lastCurtain.drawn, true);

  rig.mod.setCurtain(0);
  rig.frame();
  assert.equal(rig.mod.lastCurtain.drawn, false, "alpha 归 0 之后还在画的话，画面会一直是黑的");
});

test("★ `setCurtain` 越界也夹：2 当 1、NaN 当 0", () => {
  const rig = boot();
  rig.mod.setCurtain(2);
  rig.frame();
  assert.equal(rig.mod.lastCurtain.alpha, 1);
  rig.mod.setCurtain(Number.NaN);
  rig.frame();
  assert.equal(rig.mod.lastCurtain.alpha, 0);
  assert.equal(rig.mod.lastCurtain.drawn, false, "NaN 不许画 —— 那是「不知道多黑」，不是「很黑」");
});
