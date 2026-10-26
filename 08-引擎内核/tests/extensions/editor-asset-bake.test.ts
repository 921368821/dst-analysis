/**
 * L4 · 编辑器：把真实图片烘成图集（批87）
 *
 * 这一组里最值钱的是**第 4 条**（跨模块帧名一致）：
 *
 * 编辑器挂的一直是 `buildProceduralAtlas()` 那张 6 帧的假贴图，而
 * `world-visuals` 的 `SITE_FRAMES` 映射到 `tree/rock/berry`、地形用 `terrain`、
 * 生物模板用 `rabbit/hound`。**程序化图集里没有 rabbit/hound** ——
 * 于是编辑器世界里的兔子与猎狗一直在跑、却画不出来，渲染模块只 warn 一次
 * （还可能被日志级别吞掉）。这条判据把"要用的帧 ⊆ 烘出来的帧"变成机器守的东西，
 * 而不是靠人记得两边同步。
 *
 * 其余几条钉的是"一张坏图不该毁掉整锅"的三种边界：
 *   · 解不开的图必须进 `skipped`（**带原因**），其余照烘；
 *   · 一张都没解出来必须是错误（调用方要回落到程序化图集并留痕，
 *     而不是拿一张 0 帧的空图集去渲染 —— 那是"世界全黑且不报错"）；
 *   · 帧名重复时**先到的赢**，后来的进 `skipped`（否则 `berry.png` 与
 *     `sub/berry.png` 会静默覆盖，而"我的图为什么没上"没有答案）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { EDIT_BAKE_EMPTY, bakeAtlasFromImages, type BakeImage } from "../../src/extensions/editor/asset-bake.ts";
import { SITE_FRAMES, TERRAIN_FRAME } from "../../src/extensions/render/world-visuals.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ASSETS = join(HERE, "..", "..", "web", "assets");

/** web/assets 里的 10 张真位图（5 PNG + ……以实际目录为准，这里显式列出来当语料）。 */
const IMAGE_FILES = [
  "berry.png",
  "ground.png",
  "hound.png",
  "photo.jpg",
  "player.png",
  "rabbit.png",
  "rock.png",
  "ruler.png",
  "terrain.png",
  "tree.png",
] as const;

function img(file: string, name?: string): BakeImage {
  return { name: name ?? file.replace(/\.[a-z]+$/i, ""), bytes: readFileSync(join(ASSETS, file)) };
}

test("真资产：10 张图全烘进图集，帧名与文件名对得上", () => {
  const r = bakeAtlasFromImages(IMAGE_FILES.map((f) => img(f)));
  assert.equal(r.ok, true, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  if (!r.ok) return;

  assert.deepEqual(
    r.value.frames,
    ["berry", "ground", "hound", "photo", "player", "rabbit", "rock", "ruler", "terrain", "tree"],
    "帧名必须是去掉后缀的文件名，且升序",
  );
  assert.deepEqual(r.value.skipped, [], "这 10 张都该成功");
  assert.ok(r.value.atlas.width > 0 && r.value.atlas.height > 0, "图集尺寸不能是 0");
  assert.ok(r.value.atlas.width <= 2048 && r.value.atlas.height <= 2048, "默认 maxSize 是 2048");
  // 有损格式也要真的进来：decodeImage 按魔数分发，.jpg 不该被静默跳过
  assert.ok(r.value.frames.includes("photo"), "JPEG 必须能进图集");
});

test("★★ 跨模块一致：世界与生物要用的帧，全都在烘出来的图集里", () => {
  const r = bakeAtlasFromImages(IMAGE_FILES.map((f) => img(f)));
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;

  const have = new Set(r.value.frames);
  const missing: string[] = [];
  for (const [kind, frame] of Object.entries(SITE_FRAMES)) {
    if (!have.has(frame)) missing.push(`${kind}→${frame}`);
  }
  if (!have.has(TERRAIN_FRAME)) missing.push(`terrain→${TERRAIN_FRAME}`);
  // 生物模板的帧名（`rabbit` / `hound`）—— 程序化图集里没有它们，
  // 于是编辑器里的兔子与猎狗一直在跑但看不见。这条就是那个缺陷的守卫。
  for (const frame of ["rabbit", "hound"]) {
    if (!have.has(frame)) missing.push(`mob→${frame}`);
  }

  assert.deepEqual(missing, [], `这些帧在真实图集里没有，画面上会「有东西在动但看不见」：${missing.join(" ")}`);
});

test("★ 坏图只记账、不炸锅：其余照烘", () => {
  const bad: BakeImage = { name: "broken", bytes: new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 3]) };
  const r = bakeAtlasFromImages([img("tree.png"), bad, img("rock.png")]);
  assert.equal(r.ok, true, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  if (!r.ok) return;

  assert.deepEqual(r.value.frames, ["rock", "tree"]);
  assert.equal(r.value.skipped.length, 1);
  assert.equal(r.value.skipped[0]?.name, "broken");
  // 原因必须带错误码，否则"为什么这张没上"只能靠猜
  assert.ok(
    (r.value.skipped[0]?.reason ?? "").length > 0,
    `skipped 必须带原因，实际是 ${JSON.stringify(r.value.skipped)}`,
  );
});

test("★ 一张都没解出来 ⇒ EDIT_BAKE_EMPTY（调用方要回落，不能拿到 0 帧图集）", () => {
  const r = bakeAtlasFromImages([
    { name: "a", bytes: new Uint8Array([1, 2, 3]) },
    { name: "b", bytes: new Uint8Array([4, 5, 6]) },
  ]);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, EDIT_BAKE_EMPTY);
    assert.ok(!r.error.message.includes("undefined"), `消息里不该出现 undefined：${r.error.message}`);
  }

  // 空输入同理：0 张图不是"全部成功"
  const empty = bakeAtlasFromImages([]);
  assert.equal(empty.ok, false);
  if (!empty.ok) assert.equal(empty.error.code, EDIT_BAKE_EMPTY);
});

test("★ 帧名重复：先到的赢，后来的进 skipped（不许静默覆盖）", () => {
  const dup = img("rock.png", "tree");
  const r = bakeAtlasFromImages([img("tree.png"), dup]);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;

  assert.deepEqual(r.value.frames, ["tree"], "两个源同一个帧名，只该占一个位置");
  assert.deepEqual(r.value.skipped, [{ name: "tree", reason: "EDIT.DUPLICATE_NAME" }]);
});

test("空名字被记账（不是悄悄当成一个叫空的帧）", () => {
  const r = bakeAtlasFromImages([img("tree.png"), img("rock.png", "   ")]);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  assert.deepEqual(r.value.frames, ["tree"]);
  assert.deepEqual(r.value.skipped, [{ name: "   ", reason: "EDIT.EMPTY_NAME" }]);
});

test("图集里的帧确实带 UV（不是只把名字放进去）", () => {
  const r = bakeAtlasFromImages([img("tree.png")]);
  assert.equal(r.ok, true, r.ok ? "" : r.error.code);
  if (!r.ok) return;
  const f = r.value.atlas.frames.get("tree");
  assert.ok(f !== undefined, "帧表里没有 tree");
  assert.ok(f.u1 > f.u0 && f.v1 > f.v0, `UV 退化：u0=${String(f.u0)} u1=${String(f.u1)}`);
  assert.ok(f.w > 0 && f.h > 0, `帧尺寸退化：${String(f.w)}×${String(f.h)}`);
});
