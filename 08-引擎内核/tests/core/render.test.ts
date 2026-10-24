/**
 * L4 · 批处理与相机测试
 *
 * 这里守的是**遮挡正确性**与**像素对齐**，都是"看起来没问题但实际错了"的那类：
 *  · 排序键错一个优先级 ⇒ 远的挡住近的（截图里两个精灵都在，看不出错）
 *  · UV 的 v 被翻转 ⇒ 采样落到图集的另一半：帧高 < 图集高一半的帧**整帧消失**
 *    （T330，藏了一整天；旧判据曾把这次翻转写成契约，见下面那条测试的注释）
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
    pivotX: 0.5,
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

/**
 * ★★ T330：这条判据**曾经把 bug 钉成契约**，是全仓库最贵的假绿灯。
 *
 * 旧版本断言"左下顶点 uv.v = 1 − v1"，依据是文件头那句"GL 的 v=0 在底部"。
 * 但那是"纹理空间的底"，而 `texImage2D` 收 `ArrayBufferView` 时，**数据第一行
 * 就落在 v=0**（像素数组第一行 = 图片顶）。所以 v 天然与像素数组同向，
 * `1 − v` 是**多翻了一次**。症状按帧高分布（帧高 < 图集高一半 ⇒ 整帧落到空白
 * padding ⇒ 消失），而这条断言当时只盯两个数，完全不看"采样落到贴图的哪一行"。
 *
 * 新版本换成**行区间**判据：顶点 uv.v 覆盖的贴图行，必须**恰好等于**帧在图集里
 * 占的行。它不依赖任何约定措辞 —— 谁把坐标扭了，行区间立刻错位。
 */
test("★ UV 的 v 不翻转：顶点覆盖的贴图行 == 帧在图集里的行（T330）", () => {
  const cam = new Camera2D({ viewportWidth: 100, viewportHeight: 100, zoom: 10, tiltY: 1 });
  const atlas = buildProceduralAtlas();

  // 用一张**不在图集顶部**的帧：ground 在 y=96..159（256 高）。
  // 若 v 被翻过，采样会落到 96..159 的镜像区（256−160..256−96），行区间必然不等。
  const f = atlas.frames.get("ground")!;
  const H = atlas.height;
  const batch = new SpriteBatch(4);
  batch.build(
    [{ ...item({ nodeId: 1, z: 0, pivotY: 0.5 }), u0: f.u0, v0: f.v0, u1: f.u1, v1: f.v1, w: f.w, h: f.h }],
    cam,
  );

  // 顶点序：0=左下 / 1=右下 / 2=右上 / 3=左上；uv 在第 3、4 个 float
  const vBottom = batch.vertices[3]!;
  const vTop = batch.vertices[2 * 8 + 3]!;
  const rowTop = Math.floor(vTop * H);
  const rowBottom = Math.ceil(vBottom * H) - 1;

  assert.equal(rowTop, 96, `上边顶点应采样帧的第 96 行（ground 顶行），实际 ${rowTop}（v=${vTop}）`);
  assert.equal(rowBottom, 159, `下边顶点应采样帧的第 159 行（ground 底行），实际 ${rowBottom}（v=${vBottom}）`);
  // 方向也要对：上边的行号必须小于下边（v 与行号同向，不是反向）
  assert.ok(rowTop < rowBottom, `上边行号 ${rowTop} 必须小于下边行号 ${rowBottom}（v 与行号同向）`);
});

/**
 * 补充判据（与上一条同源，但抓的是另一种错法）：**帧高 < 图集高一半**时，
 * 翻转会把采样区间整个推出内容区。这条用"覆盖行里有多少行不透明"来判 ——
 * 它正是当初那 8 帧里 5 帧消失的量化形状（0 行不透明 ⇒ 画面上什么都没有）。
 */
test("★ 矮帧也必须采到不透明像素（帧高 < 图集高一半是当初全灭的那一档）", () => {
  const atlas = buildProceduralAtlas();
  const W = atlas.width;
  const H = atlas.height;
  for (const name of ["rock", "berry", "player"]) {
    const f = atlas.frames.get(name)!;
    assert.ok(f.h < H / 2, `${name} 的帧高 ${f.h} 应当 < 图集高的一半（${H / 2}），否则这条判据失去靶子`);
    const cam = new Camera2D({ viewportWidth: 100, viewportHeight: 100, zoom: 10, tiltY: 1 });
    const b = new SpriteBatch(2);
    b.build([{ ...item({ nodeId: 1, z: 0 }), u0: f.u0, v0: f.v0, u1: f.u1, v1: f.v1, w: f.w, h: f.h }], cam);
    const vTop = b.vertices[2 * 8 + 3]!;
    const vBottom = b.vertices[3]!;
    const x0 = Math.floor(f.u0 * W);
    const x1 = Math.max(x0, Math.ceil(f.u1 * W) - 1);
    const y0 = Math.floor(Math.min(vTop, vBottom) * H);
    const y1 = Math.min(H - 1, Math.ceil(Math.max(vTop, vBottom) * H) - 1);
    let opaque = 0;
    for (let y = y0; y <= y1; y++) {
      for (let x = x0; x <= x1; x++) {
        if ((atlas.pixels[(y * W + x) * 4 + 3] ?? 0) > 0) {
          opaque++;
          break;
        }
      }
    }
    assert.ok(opaque > 0, `${name}：采样区间落在行 ${y0}..${y1}，其中没有任何不透明像素 ⇒ 这一帧画不出来`);
    assert.equal(y1 - y0 + 1, f.h, `${name}：采样应覆盖 ${f.h} 行，实际 ${y1 - y0 + 1} 行`);
  }
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

test("★ pivotX：0 = 左边界贴住节点 x，0.5 = 水平居中（矩形地形靠它才能对上格子）", () => {
  const cam = new Camera2D({ viewportWidth: 100, viewportHeight: 100, zoom: 10, tiltY: 1 });
  const center = new SpriteBatch(2);
  center.build([item({ nodeId: 1, z: 0, x: 0, w: 2, h: 1, pivotX: 0.5 })], cam);
  const left = new SpriteBatch(2);
  left.build([item({ nodeId: 1, z: 0, x: 0, w: 2, h: 1, pivotX: 0 })], cam);

  // 顶点 0 = 左下，顶点 2 = 右上（x 在 [0]、[2*8]）
  const cxCenter = (center.vertices[0]! + center.vertices[2 * 8]!) / 2;
  const cxLeft = (left.vertices[0]! + left.vertices[2 * 8]!) / 2;
  assert.ok(Math.abs(cxCenter - 0) < 1e-6, `居中时中心在 x=0，实际 ${cxCenter}`);
  assert.ok(cxLeft > cxCenter, "pivotX=0 时整体右移（左边界贴住节点 x）");
  // 位移量必须是**半个宽度**：w=2 ⇒ 半宽 1 世界单位；zoom=10 / 视口 100 ⇒ 1 单位 = 10px = 0.2 NDC
  // （NDC 的半屏是 50px）。写成 0.1 是第一次算错的地方 —— 半屏不是 100px。
  assert.ok(Math.abs(cxLeft - cxCenter - 0.2) < 1e-6, `pivotX 的位移不是半个宽度：${cxLeft - cxCenter}`);
});

test("★ pivotX 与 pivotY 的符号必须同向（0 = 左/底，0.5 = 中心）", () => {
  // 这条钉的是"照抄 pivotY 那一行时把符号写反"：以 0.5 为对称中心时两轴的错法都看不出来，
  // 所以只能直接比 0 与 0.5 两种情况的方向。
  const cam = new Camera2D({ viewportWidth: 100, viewportHeight: 100, zoom: 10, tiltY: 1 });
  const p0 = new SpriteBatch(2);
  p0.build([item({ nodeId: 1, z: 0, x: 5, w: 1, h: 1, pivotX: 0, pivotY: 0 })], cam);
  const p5 = new SpriteBatch(2);
  p5.build([item({ nodeId: 1, z: 0, x: 5, w: 1, h: 1, pivotX: 0.5, pivotY: 0.5 })], cam);
  const dx0 = p0.vertices[0]! - p5.vertices[0]!;
  const dy0 = p0.vertices[1]! - p5.vertices[1]!;
  assert.ok(dx0 > 0 && dy0 > 0, `pivot=0 应当同时右移与上移，实际 dx=${dx0} dy=${dy0}`);
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
