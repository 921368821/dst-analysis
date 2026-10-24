/**
 * L4 · 图集合成判据
 *
 * 守的缺陷：**"有解码器"不等于"画面用上了真贴图"**。
 *   图集排布是构建产物：只要排序/取整/填充有一处依赖输入顺序或 locale，
 *   同一批图在两次构建里就会得到不同字节 —— 增量构建失效、golden 判据随机红。
 *   所以这里的核心不是"能不能拼出来"，而是 **同输入逐字节同输出**。
 *
 * 另外守住三个会静默出错的细节：
 *   · 空白必须全透明（填黑会让精灵边缘出现黑边）；
 *   · UV 必须按**最终**图集尺寸归一化（按所需尺寸算会整体偏移）；
 *   · 超过 maxSize 必须报错并点名帧（否则 2048×2048 拼成 8192² 直接 OOM）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { AtlasData } from "../../src/extensions/render/atlas.ts";
import type { DecodedPng } from "../../src/extensions/asset-import/decode/png.ts";
import type { AtlasSource, ImportedFrameRect } from "../../src/extensions/render/atlas-from-assets.ts";
import {
  buildAtlasFromImported,
  buildAtlasFromSources,
} from "../../src/extensions/render/atlas-from-assets.ts";

function must<T>(r: Result<T, EngineError>): T {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function mustFail(r: Result<AtlasData, EngineError>): EngineError {
  if (r.ok) throw new Error("期望失败，实际成功了");
  return r.error;
}

/** 造一张纯色（可带 alpha）的小图。 */
function tex(name: string, w: number, h: number, rgba: readonly [number, number, number, number]): AtlasSource {
  const pixels = new Uint8Array(w * h * 4);
  for (let i = 0; i < w * h; i++) pixels.set(rgba, i * 4);
  const png: DecodedPng = {
    width: w,
    height: h,
    pixels,
    bitDepth: 8,
    colorType: 6,
    hasAlpha: true,
    usedTransparencyKey: false,
    interlaced: false,
    isApng: false,
  };
  return { name, png };
}

function isPow2(n: number): boolean {
  return n > 0 && (n & (n - 1)) === 0;
}

function frameOf(a: AtlasData, name: string): { u0: number; v0: number; u1: number; v1: number; w: number; h: number } {
  const f = a.frames.get(name);
  assert.ok(f !== undefined, `缺少帧 ${name}`);
  return f;
}

function pixelAt(a: AtlasData, x: number, y: number): number[] {
  const i = (y * a.width + x) * 4;
  return [a.pixels[i]!, a.pixels[i + 1]!, a.pixels[i + 2]!, a.pixels[i + 3]!];
}

function snapshot(a: AtlasData): string {
  return (
    `${a.width}x${a.height}:` +
    Array.from(a.frames.entries())
      .map(([n, f]) => `${n}=${f.u0},${f.v0},${f.u1},${f.v1},${f.w}x${f.h}`)
      .join(";")
  );
}

// ------------------------------------------------------------------ 判据

test("图集：两个不同尺寸帧 → 2 的幂尺寸 + 具体 UV", () => {
  const a = must(
    buildAtlasFromSources([
      tex("A", 4, 2, [255, 0, 0, 255]),
      tex("B", 2, 3, [0, 255, 0, 255]),
    ]),
  );
  // 排序：B(高 3) 在左，A(高 2) 在右；padding=1 → 需要 2+1+4=7 宽、3 高 → 8×4
  assert.equal(a.width, 8);
  assert.equal(a.height, 4);
  assert.ok(isPow2(a.width) && isPow2(a.height), "尺寸必须是 2 的幂");

  const b = frameOf(a, "B");
  assert.deepEqual([b.u0, b.v0, b.u1, b.v1, b.w, b.h], [0, 0, 2 / 8, 3 / 4, 2, 3]);
  const f = frameOf(a, "A");
  assert.deepEqual([f.u0, f.v0, f.u1, f.v1, f.w, f.h], [3 / 8, 0, 7 / 8, 2 / 4, 4, 2]);
});

test("图集：确定性 —— 同输入两次构建逐字节相同", () => {
  const sources = [
    tex("tree", 8, 12, [20, 120, 40, 255]),
    tex("rock", 6, 5, [100, 100, 110, 255]),
    tex("berry", 3, 3, [200, 40, 40, 255]),
  ];
  const a1 = must(buildAtlasFromSources(sources));
  const a2 = must(buildAtlasFromSources(sources));
  assert.deepEqual(Buffer.from(a1.pixels), Buffer.from(a2.pixels));
  assert.equal(snapshot(a1), snapshot(a2));
});

test("图集：打乱输入顺序 → 输出完全相同（排序真的生效）", () => {
  const sources = [
    tex("a", 5, 4, [1, 2, 3, 255]),
    tex("b", 7, 9, [4, 5, 6, 255]),
    tex("c", 2, 9, [7, 8, 9, 255]), // 与 b 同高：靠名字升序决定先后
  ];
  const forward = must(buildAtlasFromSources(sources));
  const backward = must(buildAtlasFromSources([...sources].reverse()));
  const shuffled = must(buildAtlasFromSources([sources[1]!, sources[2]!, sources[0]!]));
  assert.deepEqual(Buffer.from(forward.pixels), Buffer.from(backward.pixels));
  assert.equal(snapshot(forward), snapshot(backward));
  assert.deepEqual(Buffer.from(forward.pixels), Buffer.from(shuffled.pixels));
  assert.equal(snapshot(forward), snapshot(shuffled));
});

test("图集：空白区域是全透明（不是黑）", () => {
  const a = must(
    buildAtlasFromSources([
      tex("A", 4, 2, [255, 0, 0, 255]),
      tex("B", 2, 3, [0, 255, 0, 255]),
    ]),
  );
  // 8×4 里 A 占 x=3..6,y=0..1；B 占 x=0..1,y=0..2
  assert.deepEqual(pixelAt(a, 0, 0), [0, 255, 0, 255], "帧内应是不透明绿");
  assert.deepEqual(pixelAt(a, 2, 0), [0, 0, 0, 0], "帧间空隙必须全透明");
  assert.deepEqual(pixelAt(a, 7, 3), [0, 0, 0, 0], "未使用区域必须全透明");
  assert.deepEqual(pixelAt(a, 4, 3), [0, 0, 0, 0]);
});

test("图集：padding 生效 —— 相邻帧之间至少 1 像素空隙", () => {
  const noPad = must(
    buildAtlasFromSources(
      [tex("left", 4, 4, [255, 0, 0, 255]), tex("right", 4, 4, [0, 0, 255, 255])],
      { padding: 0 },
    ),
  );
  // 同高 → 名字升序：left 在前。padding=0 时 right 从 x=4 开始
  assert.deepEqual(pixelAt(noPad, 3, 0), [255, 0, 0, 255]);
  assert.deepEqual(pixelAt(noPad, 4, 0), [0, 0, 255, 255]);

  const pad = must(
    buildAtlasFromSources([tex("left", 4, 4, [255, 0, 0, 255]), tex("right", 4, 4, [0, 0, 255, 255])], {
      padding: 1,
    }),
  );
  assert.deepEqual(pixelAt(pad, 3, 0), [255, 0, 0, 255]);
  assert.deepEqual(pixelAt(pad, 4, 0), [0, 0, 0, 0], "padding 列必须全透明");
  assert.deepEqual(pixelAt(pad, 5, 0), [0, 0, 255, 255]);
  assert.equal(pad.width, 16, "4+1+4=9 → 16");
});

test("图集：单帧 → frames 是整图 UV（0,0,1,1）", () => {
  const a = must(buildAtlasFromSources([tex("only", 4, 4, [9, 8, 7, 255])]));
  assert.equal(a.width, 4);
  assert.equal(a.height, 4);
  const f = frameOf(a, "only");
  assert.deepEqual([f.u0, f.v0, f.u1, f.v1], [0, 0, 1, 1]);
  assert.deepEqual([f.w, f.h], [4, 4]);
});

test("图集：超过 maxSize → ASSET.ATLAS_TOO_LARGE 且点名帧", () => {
  const e = mustFail(buildAtlasFromSources([tex("huge", 200, 200, [1, 1, 1, 255])], { maxSize: 128 }));
  assert.equal(e.code, "ASSET.ATLAS_TOO_LARGE");
  assert.match(e.message, /huge/, "必须点名是哪一帧");
  assert.match(e.message, /128/);

  const e2 = mustFail(
    buildAtlasFromSources([tex("a", 100, 100, [1, 1, 1, 255]), tex("b", 100, 100, [2, 2, 2, 255])], {
      maxSize: 128,
    }),
  );
  assert.equal(e2.code, "ASSET.ATLAS_TOO_LARGE");
});

test("图集：从图集帧矩形裁切重排（buildAtlasFromImported）", () => {
  // 8×8 的"旧图集"：左上 4×4 红、右上 4×4 绿
  const sheetPixels = new Uint8Array(8 * 8 * 4);
  for (let y = 0; y < 8; y++) {
    for (let x = 0; x < 8; x++) {
      const i = (y * 8 + x) * 4;
      const red = x < 4;
      sheetPixels[i] = red ? 255 : 0;
      sheetPixels[i + 1] = red ? 0 : 255;
      sheetPixels[i + 2] = 0;
      sheetPixels[i + 3] = 255;
    }
  }
  const sheet: AtlasSource = {
    name: "sheet",
    png: {
      width: 8,
      height: 8,
      pixels: sheetPixels,
      bitDepth: 8,
      colorType: 6,
      hasAlpha: true,
      usedTransparencyKey: false,
      interlaced: false,
      isApng: false,
    },
  };
  const frames = new Map<string, ImportedFrameRect>([
    ["red", { x: 0, y: 0, w: 4, h: 4 }],
    ["green", { x: 4, y: 0, w: 4, h: 4 }],
  ]);

  const a = must(buildAtlasFromImported(frames, [sheet]));
  // 两张 4×4 + padding 1 = 9 宽、4 高 → 向上取整 16×4
  assert.equal(a.width, 16);
  assert.equal(a.height, 4);
  assert.equal(a.frames.size, 2);
  const r = frameOf(a, "red");
  const g = frameOf(a, "green");
  assert.equal(r.w, 4);
  assert.equal(g.w, 4);
  // 同高 → 名字升序：green 在左（x=0），red 在右（x=5）
  assert.deepEqual(pixelAt(a, 0, 0), [0, 255, 0, 255]);
  assert.deepEqual(pixelAt(a, 5, 0), [255, 0, 0, 255], "red 从 x=5 开始（green 4 + padding 1）");
});
