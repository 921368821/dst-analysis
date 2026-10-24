/**
 * L4 · APNG → sprite sheet 判据
 *
 * 守的缺陷：**"解码器支持了、素材却用不上"**。
 *   `decodeApng` 能把帧合成出来，但引擎的纹理上传只有 `createTexture(desc, rgba8)`，
 *   渲染模块只认图集里的 UV 矩形。少了这一步，APNG 支持就停在"测试里能用"，
 *   进了引擎还是没人消费 —— 典型的"中间层做完、两头没接上"。
 *
 * ★ 判据重点在**顺序**，不是像素（像素已由 apng.test.ts 与外部金标钉住）：
 *   播放端按下标取帧，所以"图集里第 i 块"必须就是"第 i 帧"。
 *   帧名零填充让字典序 == 播放序；不填充时 `10` 会排在 `2` 前面。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { ApngFrame } from "../../src/extensions/asset-import/decode/apng.ts";
import { decodeApng } from "../../src/extensions/asset-import/decode/apng.ts";
import type { ApngAtlasResult } from "../../src/extensions/render/atlas-from-apng.ts";
import { buildAtlasFromApng } from "../../src/extensions/render/atlas-from-apng.ts";

const DIR = fileURLToPath(new URL("../fixtures/png/", import.meta.url));

function read(name: string): Uint8Array {
  return new Uint8Array(readFileSync(DIR + name));
}

function must<T>(r: Result<T, EngineError>): T {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function decodeFixture(name: string): {
  frames: readonly ApngFrame[];
  width: number;
  height: number;
  loopCount: number;
} {
  const r = must(decodeApng(read(name + ".png")));
  return { frames: r.frames, width: r.width, height: r.height, loopCount: r.loopCount };
}

/** 从图集里按 UV 取出某帧的像素（最近邻，验证"帧矩形真的指对了地方"）。 */
function sampleAtlas(
  atlas: { width: number; height: number; pixels: Uint8Array },
  frame: { u0: number; v0: number; w: number; h: number },
  x: number,
  y: number,
): number[] {
  const px = Math.floor(frame.u0 * atlas.width) + x;
  const py = Math.floor(frame.v0 * atlas.height) + y;
  const o = (py * atlas.width + px) * 4;
  return Array.from(atlas.pixels.subarray(o, o + 4));
}

test("APNG→图集：3 帧动图拼成一张图集，帧名按播放序", () => {
  const { frames, width, height, loopCount } = decodeFixture("apng-none-source");
  const r = must(buildAtlasFromApng(frames, width, height, loopCount));
  assert.equal(r.frameNames.length, 3);
  assert.deepEqual(r.frameNames, ["0", "1", "2"]);
  assert.equal(r.atlas.frames.size, 3);
  for (const n of r.frameNames) assert.ok(r.atlas.frames.has(n), `图集缺帧 ${n}`);
  assert.equal(r.loopCount, 0, "0 = 无限循环，不能被换成别的值");
});

test("APNG→图集：图集里的像素与解码出的帧逐点一致", () => {
  const { frames, width, height, loopCount } = decodeFixture("apng-background-over");
  const r = must(buildAtlasFromApng(frames, width, height, loopCount));
  frames.forEach((f, i) => {
    const name = r.frameNames[i]!;
    const rect = r.atlas.frames.get(name)!;
    assert.equal(rect.w, width);
    assert.equal(rect.h, height);
    for (const [x, y] of [
      [0, 0],
      [width - 1, 0],
      [0, height - 1],
      [width - 1, height - 1],
      [Math.floor(width / 2), Math.floor(height / 2)],
    ] as const) {
      assert.deepEqual(
        sampleAtlas(r.atlas, rect, x, y),
        Array.from(f.pixels.subarray((y * width + x) * 4, (y * width + x) * 4 + 4)),
        `帧 ${i} 在 (${x},${y}) 的像素与图集不一致`,
      );
    }
  });
});

test("APNG→图集：帧时长与总时长原样透传（播放器自己计时，图集不持状态）", () => {
  const { frames, width, height, loopCount } = decodeFixture("apng-none-source");
  const r = must(buildAtlasFromApng(frames, width, height, loopCount));
  assert.deepEqual(Array.from(r.frameDurationsMs), [100, 200, 500]);
  assert.equal(r.totalDurationMs, 800);
});

test("APNG→图集：默认图用例只有 2 帧（默认图不该混进播放序列）", () => {
  const { frames, width, height, loopCount } = decodeFixture("apng-default-image");
  assert.equal(frames.length, 2, "IDAT 默认图不属于动画，帧数只数 fcTL");
  const r = must(buildAtlasFromApng(frames, width, height, loopCount));
  assert.equal(r.frameNames.length, 2);
  assert.equal(r.loopCount, 1);
});

test("APNG→图集：帧名零填充，字典序 == 播放序（12 帧时不允许 10 排在 2 前面）", () => {
  const w = 2;
  const h = 2;
  const frames: ApngFrame[] = Array.from({ length: 12 }, (_, i) => ({
    index: i,
    pixels: new Uint8Array(w * h * 4).fill(i),
    rect: { x: 0, y: 0, width: w, height: h },
    delayMs: 10,
    dispose: 0,
    blend: 0,
  }));
  const r = must(buildAtlasFromApng(frames, w, h, 0));
  const sorted = [...r.frameNames].sort();
  assert.deepEqual(sorted, Array.from(r.frameNames), "帧名排序后必须与播放序相同");
  assert.equal(r.frameNames[0], "00");
  assert.equal(r.frameNames[11], "11");
  assert.equal(r.totalDurationMs, 120);
});

test("APNG→图集：空帧数组 → ATLAS.EMPTY_APNG（不是拼出一张空图集）", () => {
  const r = buildAtlasFromApng([], 4, 4, 0);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, "ATLAS.EMPTY_APNG");
});

test("APNG→图集：超出 maxSize 时报错并说清尺寸（不静默缩小）", () => {
  const { frames, width, height, loopCount } = decodeFixture("apng-none-source");
  const r = buildAtlasFromApng(frames as readonly ApngFrame[], width, height, loopCount, { maxSize: 8 });
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.match(String(r.error.message), /8|maxSize|图集/);
});

export type { ApngAtlasResult };
