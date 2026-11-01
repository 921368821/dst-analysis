/**
 * L4 · 插值坐标**真的进了顶点缓冲**（批168）
 *
 * ★★ 这条链有两个「全绿但没效果」的长相：
 *
 *   ① 会话算了、渲染层没问（`opts.visual` 没接上 / `at()` 的返回值被丢掉）；
 *   ② 渲染层问了、但用的是节点坐标（`const px = p.x`）。
 *
 *   两者的表现完全一样：画面一格一格地闪，而所有位置判据都是绿的（节点坐标分毫
 *   不差）。所以判据必须读到**给了 GPU 的那一层** —— 顶点缓冲，与 T288 的瓦片判据
 *   同一个入口。
 *
 * ★ 自校准：不写死"2 格 = 64 像素"（那要假设 zoom 的语义）。用三个 rig 比较
 *   位移的**线性**（0 → 2 → 4 格），既不看 zoom，也不会因为视口/dpr 变化而红。
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
import { NullGraphicsDevice } from "../../src/backends/gfx-null/device.ts";
import { createRenderModule, type VisualSmoothing } from "../../src/extensions/render/render-module.ts";
import { Services } from "../../src/core/tokens.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";

const FRAME_DT = 1 / 60;

/** 每帧记录 `beginFrame` 收到的毫秒数（顺便证明它**被调用过**）。 */
interface Probe extends VisualSmoothing {
  readonly dts: number[];
  readonly asked: number[];
}

function probe(x: number | null): Probe {
  const dts: number[] = [];
  const asked: number[] = [];
  return {
    dts,
    asked,
    beginFrame(dtMs: number): void {
      dts.push(dtMs);
    },
    at(nodeId: number): { readonly x: number; readonly y: number } | null {
      asked.push(nodeId);
      return x === null ? null : { x, y: 0 };
    },
  };
}

interface Rig {
  readonly dev: NullGraphicsDevice;
  readonly nodeId: number;
  readonly mod: ReturnType<typeof createRenderModule>;
  frame(): void;
  /** 这一帧唯一那个 quad 的左下角屏幕 x。 */
  x0(): number;
}

function boot(visual: VisualSmoothing | null): Rig {
  const reg = new ComponentRegistry();
  reg.register(new Sprite().schema, () => new Sprite());
  const scene = new Scene("t", reg);
  const n = scene.spawnImmediate("hero", scene.rootId, 1);
  scene.attach(n.id, () => {
    const s = new Sprite();
    s.frame = "player"; // 程序化图集里存在的帧（名字错了会被跳过 ⇒ 顶点为空）
    s.width = 1;
    s.height = 1;
    return s;
  });
  scene.flush();
  n.setLocalPosition(0, 0);

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
  services.provide(Services.Frame, frameHost as never, "test.render-visual");
  services.provide(Services.Scene, scene, "test.render-visual");
  const dev = new NullGraphicsDevice(800, 600);
  const ctx: ModuleContext = {
    log: logger,
    events: new EventBus<Record<string, unknown>>(),
    services,
    platform: { gfx: dev } as unknown as IPlatform,
    random: new XorShift128(1),
    module: () => undefined,
  };
  const mod = createRenderModule({
    viewportWidth: 800,
    viewportHeight: 600,
    zoom: 32,
    ...(visual === null ? {} : { visual }),
  });
  const r = mod.init(ctx);
  assert.ok(r === undefined || (!(r instanceof Promise) && r.ok), "渲染模块 init 失败");
  mod.start?.();
  return {
    dev,
    nodeId: n.id,
    mod,
    frame: () => {
      for (const f of renders) f({ frame: 1, realDtSec: FRAME_DT, steps: 1, alpha: 0, tick: 1 });
    },
    x0: () => {
      const v = mod.lastVertices(1);
      assert.equal(v.length, 4 * 8, "这一帧没有画出那个 quad（帧名/裁剪/初始化都不对）");
      return v[0] ?? Number.NaN;
    },
  };
}

test("★★ visual 的坐标进了顶点缓冲：0 → 2 → 4 格必须是**线性**的屏幕位移", () => {
  const base = boot(null);
  base.frame();
  const xBase = base.x0();

  const two = boot(probe(2));
  two.frame();
  const xTwo = two.x0();

  const four = boot(probe(4));
  four.frame();
  const xFour = four.x0();

  const d1 = xTwo - xBase;
  const d2 = xFour - xTwo;
  assert.ok(
    Math.abs(d1) > 1e-6,
    "visual 的坐标没进顶点缓冲 ⇒ 会话算了、画面没动（这就是「算出来了但没画」）",
  );
  assert.ok(
    Math.abs(d1 - d2) < 1e-6,
    `位移不是线性的（${String(d1)} vs ${String(d2)}）⇒ 插值只作用在部分路径上`,
  );
});

test("★★ `at()` 返回 null 时不干预：顶点与「没有 visual」逐位相同", () => {
  const base = boot(null);
  base.frame();
  const none = boot(probe(null));
  none.frame();
  assert.equal(
    none.x0(),
    base.x0(),
    "null 也要被当成一个坐标用了（或者把节点坐标改了一点）⇒ 本地玩家会被顺手插值",
  );
});

test("★★ 视口粗筛按**画出来的**坐标：被插值到屏幕外的精灵必须剔掉", () => {
  // 节点在原点（屏幕正中），插值把它画到 1000 格外（远超视口半宽 ≈ 12.5 格）。
  // 用节点坐标做粗筛的话，这条精灵会被判成"可见"并真的提交上去 ——
  // 表现是一帧里多出几个 quad，而"多画的那些"在屏幕上根本看不到。
  const inside = boot(probe(0));
  inside.frame();
  assert.equal(inside.mod.lastFrame.quads, 1, "基线都不画 ⇒ 这条判据什么也没验");

  const outside = boot(probe(1000));
  outside.frame();
  assert.equal(
    outside.mod.lastFrame.quads,
    0,
    "被插值到屏幕外的精灵还在提交 ⇒ 粗筛用的是节点坐标（`p.x`）而不是画出来的坐标（`px`）",
  );
});

test("★ `beginFrame` 每帧调一次，且单位是**毫秒**（传秒会让插值慢 1000 倍）", () => {
  const p = probe(null);
  const rig = boot(p);
  rig.frame();
  rig.frame();
  assert.deepEqual(p.dts.length, 2, "一帧一次：调 0 次 = 时钟不走，调 2 次 = 时间走两倍");
  for (const dt of p.dts) {
    assert.ok(
      Math.abs(dt - FRAME_DT * 1000) < 1e-6,
      `beginFrame 收到 ${String(dt)}，期望 ${String(FRAME_DT * 1000)}（毫秒）`,
    );
  }
  assert.deepEqual(p.asked, [rig.nodeId, rig.nodeId], "只该问有精灵的那些节点，且一条精灵问一次");
});
