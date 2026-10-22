/**
 * L4 · 批处理与相机测试
 *
 * 这里守的是**遮挡正确性**与**像素对齐**，都是"看起来没问题但实际错了"的那类：
 *  · 排序键错一个优先级 ⇒ 远的挡住近的（截图里两个精灵都在，看不出错）
 *  · UV 的 v 没翻转 ⇒ 所有精灵上下颠倒（很像"美术画反了"）
 *  · pivot 算错 ⇒ 精灵悬空/陷地（很像"锚点没设"）
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Camera2D } from "../../src/extensions/render/camera.ts";
import { SpriteBatch, type RenderItem } from "../../src/extensions/render/batch2d.ts";
import { buildProceduralAtlas } from "../../src/extensions/render/atlas.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { stableHash } from "../../src/core/serialization/schema.ts";

function item(p: Partial<RenderItem> & { nodeId: number; z: number }): RenderItem {
  return {
    x: 0,
    w: 1,
    h: 1,
    u0: 0,
    v0: 0,
    u1: 1,
    v1: 1,
    r: 1,
    g: 1,
    b: 1,
    a: 1,
    order: 0,
    pivotY: 0.5,
    atlas: 0,
    ...p,
  };
}

test("相机：世界 → 裁剪的符号与比例（z 增大 = 屏幕上移）", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.5 });
  cam.moveTo(0, 0);
  // 世界 x=12.5 => 像素 400 => NDC 1.0
  assert.ok(Math.abs(cam.project(12.5, 0).x - 1) < 1e-9, "12.5 单位 × 32 px = 400 px ⇒ 半屏 ⇒ NDC 1");
  // z=18.75 => 18.75*32*0.5 = 300 px = 半屏 ⇒ NDC 1
  assert.ok(Math.abs(cam.project(0, 18.75).y - 1) < 1e-9, "tiltY=0.5 时 z 方向被压缩一半");
  // 相机移动后同一点应左移
  cam.moveTo(6.25, 0);
  assert.ok(Math.abs(cam.project(12.5, 0).x - 0.5) < 1e-9);
});

test("相机：unproject 是 project 的逆（拾取用）", () => {
  const cam = new Camera2D({ viewportWidth: 800, viewportHeight: 600, zoom: 32, tiltY: 0.62 });
  cam.moveTo(3, -2);
  const p = cam.project(7.5, 1.25);
  const px = { x: ((p.x + 1) / 2) * 800, y: ((1 - p.y) / 2) * 600 };
  const w = cam.unproject(px.x, px.y);
  assert.ok(Math.abs(w.x - 7.5) < 1e-6, `x 往返：${w.x}`);
  assert.ok(Math.abs(w.z - 1.25) < 1e-6, `z 往返：${w.z}`);
});

test("排序：z 降序（远的先画），同 z 再按 order / atlas / nodeId", () => {
  const items = [
    item({ nodeId: 1, z: 0 }),
    item({ nodeId: 2, z: 5 }),
    item({ nodeId: 3, z: 0, order: 2 }),
    item({ nodeId: 4, z: 0, order: 1 }),
    item({ nodeId: 5, z: 5, atlas: 1 }),
  ];
  SpriteBatch.sort(items);
  assert.deepEqual(
    items.map((i) => i.nodeId),
    [2, 5, 1, 4, 3],
    "z=5 的两个先画（同 z 按 atlas 升序 ⇒ 2 在 5 前），再 z=0 按 order 升序（1→4→3）",
  );
});

test("排序把 z 放在 atlas 之前（遮挡正确性优先于减少纹理切换）", () => {
  const items = [
    item({ nodeId: 1, z: 0, atlas: 0 }),
    item({ nodeId: 2, z: 9, atlas: 1 }),
  ];
  SpriteBatch.sort(items);
  assert.deepEqual(
    items.map((i) => i.nodeId),
    [2, 1],
    "更远的（z=9、图集 1）必须先画，即使这样会多一次纹理切换",
  );
});

test("排序是确定的：同一批输入两次排序结果相同（否则画面会闪）", () => {
  const make = (): RenderItem[] => [
    item({ nodeId: 9, z: 1 }),
    item({ nodeId: 3, z: 1 }),
    item({ nodeId: 7, z: 1 }),
  ];
  const a = make();
  const b = make();
  SpriteBatch.sort(a);
  SpriteBatch.sort(b);
  assert.deepEqual(a.map((i) => i.nodeId), b.map((i) => i.nodeId));
  assert.deepEqual(a.map((i) => i.nodeId), [3, 7, 9]);
});

test("UV 的 v 轴翻转：像素数组原点在左上，GL 的 v=0 在底部", () => {
  const cam = new Camera2D({ viewportWidth: 100, viewportHeight: 100, zoom: 10, tiltY: 1 });
  const batch = new SpriteBatch(4);
  batch.build([item({ nodeId: 1, z: 0, v0: 0.25, v1: 0.75, pivotY: 0.5 })], cam);
  // 顶点 0 = 左下；它的 uv.v 应当是 1 - v1
  const v0 = batch.vertices[3];
  // 顶点 2 = 右上；它的 uv.v 应当是 1 - v0
  const v2 = batch.vertices[2 * 8 + 3];
  assert.ok(Math.abs(v0! - 0.25) < 1e-6, `左下 uv.v 应为 1-0.75=0.25，实际 ${v0}`);
  assert.ok(Math.abs(v2! - 0.75) < 1e-6, `右上 uv.v 应为 1-0.25=0.75，实际 ${v2}`);
});

test("pivotY：0 = 底边贴地（中心抬高半个高度），0.5 = 中心对齐", () => {
  const cam = new Camera2D({ viewportWidth: 100, viewportHeight: 100, zoom: 10, tiltY: 1 });
  const center = new SpriteBatch(2);
  center.build([item({ nodeId: 1, z: 0, w: 2, h: 2, pivotY: 0.5 })], cam);
  const bottom = new SpriteBatch(2);
  bottom.build([item({ nodeId: 1, z: 0, w: 2, h: 2, pivotY: 0 })], cam);

  const cyCenter = (center.vertices[1]! + center.vertices[3 * 8 + 1]!) / 2;
  const cyBottom = (bottom.vertices[1]! + bottom.vertices[3 * 8 + 1]!) / 2;
  assert.ok(Math.abs(cyCenter - 0) < 1e-6, `中心对齐时中心在 y=0，实际 ${cyCenter}`);
  assert.ok(cyBottom > cyCenter, "pivotY=0 时整体上移（底边贴地）");
});

test("批处理容量：超过 maxQuads 时**明确截断并报告**（不静默丢东西）", () => {
  const cam = new Camera2D({ viewportWidth: 100, viewportHeight: 100 });
  const batch = new SpriteBatch(3);
  const items = Array.from({ length: 10 }, (_, i) => item({ nodeId: i + 1, z: i }));
  const r = batch.build(items, cam);
  assert.equal(r.quadCount, 3, "只写 maxQuads 个");
  assert.equal(r.vertexCount, 12);
  assert.equal(r.indexCount, 18);
  assert.equal(batch.items.length, 10, "items 仍保留全部（供调用方决定是否再开一批）");
});

test("批处理：maxQuads 超过 Uint16 索引上限时构造就抛（不许悄悄溢出）", () => {
  assert.throws(() => new SpriteBatch(20000), /Uint16/);
});

test("图集：程序化生成是**确定性的**（两次生成逐字节相同）", () => {
  const a = buildProceduralAtlas();
  const b = buildProceduralAtlas();
  assert.equal(a.width, b.width);
  assert.equal(a.frames.size, b.frames.size);
  const ha = stableHash(a.pixels);
  const hb = stableHash(b.pixels);
  assert.equal(ha, hb, `两次生成的像素必须相同（否则判据无法用 golden 比对）：${ha} vs ${hb}`);
});

test("图集：帧矩形都在图内且不越界", () => {
  const a = buildProceduralAtlas();
  for (const [name, f] of a.frames) {
    assert.ok(f.u0 >= 0 && f.u1 <= 1, `${name} 的 u 越界：${f.u0}~${f.u1}`);
    assert.ok(f.v0 >= 0 && f.v1 <= 1, `${name} 的 v 越界：${f.v0}~${f.v1}`);
  }
});

test("Sprite 组件：schema 覆盖全部字段（否则存档会漏字段）", () => {
  const s = new Sprite();
  const keys = Object.keys(s.schema.fields);
  for (const k of ["frame", "width", "height", "order", "visible", "pivotY"]) {
    assert.ok(keys.includes(k), `schema 缺少字段 ${k}`);
  }
  const saved = s.save();
  assert.equal(saved["frame"], "", "save 应包含 frame");
});
