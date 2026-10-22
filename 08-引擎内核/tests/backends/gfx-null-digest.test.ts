/**
 * L5 · Null 后端的纹理摘要判据
 *
 * 守的缺陷：**"上传成功"只是返回了 `ok`，没人知道传上去的是哪份字节**。
 *   上一代引擎里"纹理显示成另一张图"的排查要靠截图比对；这里让设备只记一个
 *   16 hex 的摘要 + 字节数（不存像素，2048² 一张就 16 MB），
 *   于是判据可以断言：`解码器产出的 pixels` 与 `GPU 实际收到的字节` 是同一份。
 *
 * 另外守住"摘要口径"：句柄不存在返回 undefined 而不是抛；
 * 未上传过字节也返回 undefined（空流摘要会被误当成真摘要）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { NullGraphicsDevice } from "../../src/backends/gfx-null/device.ts";
import { PixelFormat, TextureFilter, type TextureHandle } from "../../src/platform/gfx/types.ts";

/**
 * 独立实现（不复用后端内部函数）：证明后端算的确实是"收到的字节"。
 *
 * ★ 这里的 basis 必须与 `foundation/hash.ts` 的 `FNV_BASIS_B` 一致。
 *   它曾经是 `0x84222325` —— 那是本文件与后端**共谋**的常量，两边一起错也测不出来；
 *   真正的缺陷是资产层（`0x9e3779b9`）与本层（`0x84222325`）各写一份、摘要互不相等。
 *   现在算法统一在 L0，这个函数保留为**独立冗余实现**：它验证"L0 的实现是对的"，
 *   而"两层用的是同一个 L0"由 `tests/core/asset-gpu-roundtrip.test.ts` 验证。
 */
function fnv1a32x2(data: Uint8Array): string {
  let h1 = 0x811c9dc5;
  let h2 = 0x9e3779b9;
  for (let i = 0; i < data.length; i++) {
    const b = data[i]!;
    h1 = Math.imul(h1 ^ b, 0x01000193) >>> 0;
    h2 = Math.imul(h2 ^ b, 0x01000193) >>> 0;
  }
  return h1.toString(16).padStart(8, "0") + h2.toString(16).padStart(8, "0");
}

function makeTexture(dev: NullGraphicsDevice, w: number, h: number, data: Uint8Array): TextureHandle {
  const r = dev.createTexture(
    { width: w, height: h, format: PixelFormat.RGBA8, filter: TextureFilter.Nearest, label: "test" },
    data,
  );
  assert.ok(r.ok, `createTexture 失败：${r.ok ? "" : r.error.code + " " + r.error.message}`);
  return r.value;
}

test("纹理摘要：同一份数据两次上传 → 摘要相同且是 16 hex", () => {
  const dev = new NullGraphicsDevice();
  const px = new Uint8Array(4 * 4 * 4);
  for (let i = 0; i < px.length; i++) px[i] = (i * 13) & 0xff;

  const a = makeTexture(dev, 4, 4, px);
  const b = makeTexture(dev, 4, 4, px);
  const da = dev.textureDigest(a);
  const db = dev.textureDigest(b);
  assert.ok(da !== undefined);
  assert.match(da, /^[0-9a-f]{16}$/);
  assert.equal(da, db);
});

test("纹理摘要：不同数据 → 摘要不同", () => {
  const dev = new NullGraphicsDevice();
  const p1 = new Uint8Array([1, 2, 3, 4]);
  const p2 = new Uint8Array([1, 2, 3, 5]);
  const t1 = makeTexture(dev, 1, 1, p1);
  const t2 = makeTexture(dev, 1, 1, p2);
  assert.notEqual(dev.textureDigest(t1), dev.textureDigest(t2));
});

test("纹理摘要：句柄不存在 → undefined（不抛）", () => {
  const dev = new NullGraphicsDevice();
  assert.equal(dev.textureDigest(999 as unknown as TextureHandle), undefined);

  const t = makeTexture(dev, 1, 1, new Uint8Array([9, 9, 9, 255]));
  dev.destroyTexture(t);
  assert.equal(dev.textureDigest(t), undefined, "销毁后也必须返回 undefined");
});

test("纹理摘要：与直接对源数据算的 FNV-1a 双拼一致（update 按调用顺序拼接）", () => {
  const dev = new NullGraphicsDevice();
  const a = new Uint8Array([10, 20, 30, 255, 40, 50, 60, 255]);
  const b = new Uint8Array([1, 2, 3, 4]);

  // create 时带整份数据
  const t1 = makeTexture(dev, 2, 1, a);
  assert.equal(dev.textureDigest(t1), fnv1a32x2(a), "摘要必须对上传字节算，而不是对描述符");

  // create 空 + 两次 update：等价于对 a|b 拼接后的流算
  const t2 = dev.createTexture({ width: 2, height: 1, format: PixelFormat.RGBA8 }, null);
  assert.ok(t2.ok);
  assert.equal(dev.textureDigest(t2.value), undefined, "没上传过字节时不应给出摘要");
  const u1 = dev.updateTexture(t2.value, { x: 0, y: 0, width: 2, height: 1 }, a);
  assert.ok(u1.ok);
  const u2 = dev.updateTexture(t2.value, { x: 0, y: 0, width: 1, height: 1 }, b);
  assert.ok(u2.ok);
  const concat = new Uint8Array(a.length + b.length);
  concat.set(a, 0);
  concat.set(b, a.length);
  assert.equal(dev.textureDigest(t2.value), fnv1a32x2(concat));
});
