/**
 * L4 · 图集 16 位链路判据
 *
 * 守的缺陷：**"解码器能给出 16 位"不等于"图集/GPU 拿到的是 16 位"**。
 *   这条链上有四个可以各自"看起来成功"的降级点：
 *     ① 合成器只读 `png.pixels`（8 位视图）→ 16 位数据在第一步就丢了；
 *     ② 合成器拼了 16 位缓冲，但 8 位源按错的方式上转（如 `v*256` 或 `v/255*65535` 后取整）；
 *     ③ 图集里 16 位与 8 位视图各拼一份 → 两份数据迟早漂移（本仓库的双 FNV 教训）；
 *     ④ 空白的 padding 在 16 位图集里填了 `0xffff`（白边）或 8 位语义的 `255`。
 *   所以这里不是"能跑通"，而是逐值对比：源 16 位样本 → 图集 16 位样本。
 *
 * ★ 源数据用 `tests/fixtures/png` 里的真 16 位 PNG（其像素已被 pngjs 7 / Pillow 13
 *   两个独立实现交叉验证过，见 png-fixtures.test.ts）。不用手搓的 DecodedPng：
 *   手搓的源会让"解码 → 合成"这段根本没被走到。
 *
 * ★ 必有一条反例（改一个 16 位样本）：否则"逐值相等"在实现恒返回 0、
 *   或者判据比较的是自己刚写进去的数组时，都会恒真。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { AtlasData } from "../../src/extensions/render/atlas.ts";
import type { DecodedPng } from "../../src/extensions/asset-import/decode/png.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";
import type { AtlasSource } from "../../src/extensions/render/atlas-from-assets.ts";
import { buildAtlasFromImported, buildAtlasFromSources } from "../../src/extensions/render/atlas-from-assets.ts";

const DIR = fileURLToPath(new URL("../fixtures/png/", import.meta.url));

function must<T>(r: Result<T, EngineError>): T {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function mustFail(r: Result<AtlasData, EngineError>): EngineError {
  if (r.ok) throw new Error("期望失败，实际成功了");
  return r.error;
}

function fixture(name: string, keep16: boolean): DecodedPng {
  const bytes = new Uint8Array(readFileSync(DIR + name));
  return must(decodePng(bytes, { keep16 }));
}

const PNG16 = fixture("rgba16-7x5.plain.png", true);
const PNG8 = fixture("rgba8-2x2.plain.png", false);

function src16(name: string): AtlasSource {
  return { name, png: PNG16 };
}

function src8(name: string): AtlasSource {
  return { name, png: PNG8 };
}

/** 帧在图集里的像素矩形（由归一化 UV 反算，顺带验证 UV 与放置一致）。 */
function frameRect(a: AtlasData, name: string): { x: number; y: number; w: number; h: number } {
  const f = a.frames.get(name);
  assert.ok(f !== undefined, `图集里没有帧 ${name}`);
  return { x: Math.round(f.u0 * a.width), y: Math.round(f.v0 * a.height), w: f.w, h: f.h };
}

function px16(a: AtlasData, x: number, y: number, c: number): number {
  assert.ok(a.pixels16 !== undefined, "这是 16 位图集，必须有 pixels16");
  return a.pixels16[(y * a.width + x) * 4 + c]!;
}

function isPow2(n: number): boolean {
  return n > 0 && (n & (n - 1)) === 0;
}

// ------------------------------------------------------------------ 16 位源

test("图集16：16 位源 → 图集 pixels16 与源**逐值**相等（不是「接近」）", () => {
  const a = must(buildAtlasFromSources([src16("t")]));
  assert.equal(a.format, "rgba16", "源带 pixels16 且 precision 默认 auto ⇒ 图集必须是 rgba16");
  const p16 = a.pixels16!;
  assert.equal(p16.length, a.width * a.height * 4, "pixels16 长度必须等于 width*height*4");
  assert.equal(a.width, 8);
  assert.equal(a.height, 8);

  const f = frameRect(a, "t");
  assert.deepEqual([f.w, f.h], [7, 5]);

  let notMultipleOf257 = 0;
  for (let y = 0; y < f.h; y++) {
    for (let x = 0; x < f.w; x++) {
      for (let c = 0; c < 4; c++) {
        const want = PNG16.pixels16![(y * 7 + x) * 4 + c]!;
        assert.equal(px16(a, f.x + x, f.y + y, c), want, `像素 (${x},${y}) 通道 ${c} 与源不一致`);
        if (want % 257 !== 0) notMultipleOf257++;
      }
    }
  }
  // 8 位能重建出来的值只有 257 的倍数（`v*257`）。这份金标里存在 7、4863 这种
  // 非 257 倍数的样本 —— 它们**不可能**由任何 8 位视图重建，所以这条能证明全精度真的走到了图集里。
  assert.ok(notMultipleOf257 > 0, "所有样本都是 257 的倍数 —— 数据看起来是 8 位上转来的，不是 16 位原值");
});

test("图集16：pixels 是 pixels16 的降采样视图（逐通道 round(v/257)）", () => {
  const a = must(buildAtlasFromSources([src16("t")]));
  assert.equal(a.pixels.length, a.pixels16!.length);
  for (let i = 0; i < a.pixels.length; i++) {
    assert.equal(
      a.pixels[i],
      Math.round(a.pixels16![i]! / 257),
      `第 ${i} 个通道：8 位视图与 16 位值不满足 round(v/257)（两条路径漂移了）`,
    );
  }
});

test("图集16：padding 在 16 位图集里是 0（全透明，不是白边/8 位语义的 255）", () => {
  const a = must(buildAtlasFromSources([src16("t")]));
  const f = frameRect(a, "t");
  // 7×5 的帧放在 8×8 的图集里：第 7 列与第 5 行全是空白
  for (let y = 0; y < a.height; y++) {
    assert.equal(px16(a, a.width - 1, y, 3), 0, `空白列 (${a.width - 1},${y}) 的 alpha 必须是 0`);
    for (let c = 0; c < 4; c++) assert.equal(px16(a, a.width - 1, y, c), 0);
  }
  for (let x = 0; x < a.width; x++) {
    for (let c = 0; c < 4; c++) assert.equal(px16(a, x, a.height - 1, c), 0);
  }
  assert.ok(f.w < a.width && f.h < a.height, "前置：这份布局里确实存在空白区");
});

// ------------------------------------------------------------------ 8 位源上转

test("图集16：8 位源 precision:16 → v*257（0..255 → 0..65535 均匀，且回读无损）", () => {
  const a = must(buildAtlasFromSources([src8("a")], { precision: 16 }));
  assert.equal(a.format, "rgba16");
  const f = frameRect(a, "a");
  assert.deepEqual([f.w, f.h], [2, 2]);
  for (let y = 0; y < f.h; y++) {
    for (let x = 0; x < f.w; x++) {
      for (let c = 0; c < 4; c++) {
        const v = PNG8.pixels[(y * 2 + x) * 4 + c]!;
        assert.equal(px16(a, f.x + x, f.y + y, c), v * 257, "8 位上转必须是 v*257");
      }
    }
  }
  // 上转 → 降采样必须回到原值（这正是"无损"的定义）。
  // 单帧 2×2 ⇒ 图集正好 2×2，8 位视图必须与源逐字节相同。
  assert.equal(a.width, 2);
  assert.equal(a.height, 2);
  for (let i = 0; i < PNG8.pixels.length; i++) {
    assert.equal(a.pixels[i], PNG8.pixels[i], `8 位上转再降采样后有损：第 ${i} 个通道`);
  }
});

test("图集16：混合源 auto 整体升 16 位，且 8 位部分上转后回读无损", () => {
  const a = must(buildAtlasFromSources([src8("a"), src16("b")]));
  assert.equal(a.format, "rgba16", "只要有一个源带 pixels16，整张图集就升 16 位");

  const f8 = frameRect(a, "a");
  for (let y = 0; y < f8.h; y++) {
    for (let x = 0; x < f8.w; x++) {
      for (let c = 0; c < 4; c++) {
        const want = PNG8.pixels[(y * 2 + x) * 4 + c]!;
        assert.equal(px16(a, f8.x + x, f8.y + y, c), want * 257, "8 位源在 16 位图集里必须是 v*257");
        // 8 位视图必须还是原值：上转再降采样不许改变 8 位素材的任何一个字节
        assert.equal(
          a.pixels[(f8.y + y) * a.width * 4 + (f8.x + x) * 4 + c],
          want,
          "8 位源经过「上转 → 16 位图集」后回读必须逐字节相同",
        );
      }
    }
  }

  const f16 = frameRect(a, "b");
  for (let y = 0; y < f16.h; y++) {
    for (let x = 0; x < f16.w; x++) {
      for (let c = 0; c < 4; c++) {
        assert.equal(px16(a, f16.x + x, f16.y + y, c), PNG16.pixels16![(y * 7 + x) * 4 + c]!);
      }
    }
  }
});

// ------------------------------------------------------------------ 显式降采样

test("图集16：precision:8 对 16 位源**重新**降采样（不复制解码器给的 8 位视图）", () => {
  // 故意把 8 位视图清空：如果实现只是 `pixels.set(src.pixels)`，
  // 图集会是全 0，而"round(pixels16/257)"这句话就没被执行过。
  const stale: AtlasSource = {
    name: "t",
    png: { ...PNG16, pixels: new Uint8Array(PNG16.pixels.length) },
  };
  const a = must(buildAtlasFromSources([stale], { precision: 8 }));
  assert.equal(a.format, undefined, "precision:8 时不允许再声称自己是 rgba16");
  assert.equal(a.pixels16, undefined, "precision:8 时不该分配 16 位缓冲");

  const f = frameRect(a, "t");
  let nonZero = 0;
  for (let y = 0; y < f.h; y++) {
    for (let x = 0; x < f.w; x++) {
      for (let c = 0; c < 4; c++) {
        const i = (f.y + y) * a.width * 4 + (f.x + x) * 4 + c;
        const want = Math.round(PNG16.pixels16![(y * 7 + x) * 4 + c]! / 257);
        assert.equal(a.pixels[i], want, `降采样口径必须是 round(v/257)（像素 ${x},${y} 通道 ${c}）`);
        if (want !== 0) nonZero++;
      }
    }
  }
  assert.ok(nonZero > 0, "整张图都是 0 —— 说明像素不是从 pixels16 降采样来的");
});

// ------------------------------------------------------------------ UV / 报错

test("图集16：16 位与 8 位路径的尺寸、帧 UV 完全相同（精度不该改变布局）", () => {
  const sources = [src8("a"), src16("b")];
  const a8 = must(buildAtlasFromSources(sources, { precision: 8 }));
  const a16 = must(buildAtlasFromSources(sources, { precision: 16 }));
  assert.equal(a16.width, a8.width);
  assert.equal(a16.height, a8.height);
  assert.ok(isPow2(a16.width) && isPow2(a16.height));
  assert.deepEqual([...a16.frames.keys()], [...a8.frames.keys()]);
  for (const [name, f] of a8.frames) {
    const g = a16.frames.get(name)!;
    assert.deepEqual([g.u0, g.v0, g.u1, g.v1, g.w, g.h], [f.u0, f.v0, f.u1, f.v1, f.w, f.h], `帧 ${name} 的 UV 变了`);
  }
});

test("图集16：非法 precision → ASSET.BAD_ATLAS_OPTIONS（不许静默当 auto）", () => {
  const bad = 12 as unknown as "auto";
  const e = mustFail(buildAtlasFromSources([src8("a")], { precision: bad }));
  assert.equal(e.code, "ASSET.BAD_ATLAS_OPTIONS");
  assert.match(e.message, /precision/);
});

// ------------------------------------------------------------------ 反例

test("图集16 反例：改一个 16 位样本，图集对应位置必须跟着变（否则逐值比较是恒真的）", () => {
  const base = must(buildAtlasFromSources([src16("t")]));
  const f = frameRect(base, "t");
  const at = (x: number, y: number, c: number) => px16(base, f.x + x, f.y + y, c);

  const original = at(3, 2, 1);
  const wrong = (original ^ 0x4000) & 0xffff; // 只翻一个 bit，且必定 != original
  assert.notEqual(wrong, original);

  const mutatedPixels16 = new Uint16Array(PNG16.pixels16!);
  mutatedPixels16[(2 * 7 + 3) * 4 + 1] = wrong;
  const mutated: AtlasSource = { name: "t", png: { ...PNG16, pixels16: mutatedPixels16, pixels: PNG16.pixels } };
  const a2 = must(buildAtlasFromSources([mutated]));
  const f2 = frameRect(a2, "t");
  const mutatedAt = px16(a2, f2.x + 3, f2.y + 2, 1);

  assert.equal(mutatedAt, wrong, "改了源样本，图集里必须出现改后的值");
  assert.notEqual(at(3, 2, 1), wrong, "用**未改**的源构建的图集里不该出现那个错误值 —— 出现了说明比较的对象错了");
});

// ------------------------------------------------------------------ 从图集帧裁剪的路径

test("图集16：buildAtlasFromImported 裁剪时保留 pixels16（不许在这一步退回 8 位）", () => {
  const sheet: AtlasSource = { name: "sheet", png: PNG16 };
  const frames = new Map([
    ["left", { x: 0, y: 0, w: 3, h: 5 }],
    ["right", { x: 4, y: 0, w: 3, h: 5 }],
  ]);
  const a = must(buildAtlasFromImported(frames, [sheet]));
  assert.equal(a.format, "rgba16", "裁剪只带 RGBA8 时这里会静默退回 8 位");

  for (const [name, rect] of frames) {
    const f = frameRect(a, name);
    for (let y = 0; y < rect.h; y++) {
      for (let x = 0; x < rect.w; x++) {
        for (let c = 0; c < 4; c++) {
          const want = PNG16.pixels16![(y * 7 + (rect.x + x)) * 4 + c]!;
          assert.equal(px16(a, f.x + x, f.y + y, c), want, `帧 ${name} 的 (${x},${y}) 通道 ${c} 在裁剪后变了`);
        }
      }
    }
  }
});
