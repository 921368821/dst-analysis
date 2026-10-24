/**
 * L4/L5 · 16 位图集 → GPU 上传判据
 *
 * 守的缺陷：**"图集里有 16 位数据"不等于"上传的是 16 位纹理"**。
 *   `render-module` 曾经硬编码 `format: RGBA8` + `atlas.pixels` ——
 *   于是哪怕合成器产出了 `pixels16`，GPU 收到的仍是 8 位视图，而画面看起来
 *   "也没什么问题"（这正是这类缺陷最难被发现的地方：它不报错、不变黑、只是精度没了）。
 *
 * 三段各自有判据：
 *   ① 格式声明：`mod.atlasFormat` 跟着图集走（16 位图集 ⇒ "rgba16"）；
 *   ② 设备侧记录：`dev.textureFormat(handle)` 是 "rgba16"（不是"传了 8 字节/像素就当 16 位"）；
 *   ③ 字节内容：`dev.textureDigest(handle)` == 对 `pixels16` 的字节流直接算的摘要。
 * ②+③ 缺一不可：摘要相等只证明"字节一样"，格式声明错了（比如把 16 位字节按 rgba8 上传）
 * 在 length 校验下会被后端拒绝，但"格式写成 rgba16f"这种同样 8 字节/像素的错误只有 ② 能抓。
 *
 * ★ 反例（8 位对照）：同一套断言跑一张纯 8 位图集，格式必须变回 rgba8。
 *   否则 `atlasFormat` 恒返回 "rgba16" 也能让第一条通过。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { hashBytes } from "../../src/foundation/hash.ts";
import { Logger, LogLevel } from "../../src/foundation/log/logger.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import { SystemClock } from "../../src/foundation/time/clock.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { BackendRegistry } from "../../src/platform/registry.ts";
import { createPlatform } from "../../src/platform/platform.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { NullGraphicsDevice } from "../../src/backends/gfx-null/device.ts";
import { GL2Device } from "../../src/backends/gfx-webgl2/device.ts";
import { FakeGL2 } from "../contract/fake-gl.ts";
import { PixelFormat, type TextureHandle } from "../../src/platform/gfx/types.ts";
import type { AtlasData } from "../../src/extensions/render/atlas.ts";
import { createRenderModule } from "../../src/extensions/render/render-module.ts";
import { buildAtlasFromSources, type AtlasSource } from "../../src/extensions/render/atlas-from-assets.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";

const DIR = fileURLToPath(new URL("../fixtures/png/", import.meta.url));

function sourceOf(name: string, keep16: boolean): AtlasSource {
  const bytes = new Uint8Array(readFileSync(DIR + name));
  const dec = decodePng(bytes, { keep16 });
  assert.ok(dec.ok, `解码 ${name} 失败：${dec.ok ? "" : dec.error.code + " " + dec.error.message}`);
  return { name: name.replace(/\..*$/, ""), png: dec.value };
}

/** 手工起一个最小平台（null 后端），拿到设备并组装 ModuleContext —— 不启动帧循环。 */
function makeCtx(): { ctx: ModuleContext; dev: NullGraphicsDevice } {
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  const p = createPlatform({ id: "test.render16", interactive: false, registry, clock: new SystemClock() });
  assert.ok(p.ok, `测试平台起不来：${p.ok ? "" : p.error.code + " " + p.error.message}`);
  if (!p.ok) throw new Error("unreachable");
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Off);
  return {
    ctx: {
      log,
      events: new EventBus<Record<string, unknown>>(),
      services: new ServiceRegistry(),
      platform: p.value,
      random: new XorShift128(1),
      module: () => undefined,
    },
    dev: p.value.gfx as unknown as NullGraphicsDevice,
  };
}

function bytesOf(u16: Uint16Array): Uint8Array {
  return new Uint8Array(u16.buffer, u16.byteOffset, u16.byteLength);
}

async function upload(atlas: AtlasData): Promise<{ dev: NullGraphicsDevice; atlasFormat: string }> {
  const { ctx, dev } = makeCtx();
  const mod = createRenderModule({ viewportWidth: 800, viewportHeight: 600, atlas });
  const r = await mod.init(ctx);
  assert.ok(r === undefined || r.ok, `init 失败：${r !== undefined && !r.ok ? r.error.code + " " + r.error.message : ""}`);
  return { dev, atlasFormat: mod.atlasFormat };
}

function onlyTexture(dev: NullGraphicsDevice): TextureHandle {
  const handles = dev.textureHandles;
  assert.equal(handles.length, 1, `渲染模块应只创建一张图集纹理，实际 ${handles.length} 张`);
  return handles[0]!;
}

// ------------------------------------------------------------------ 16 位

test("上传16：16 位图集 ⇒ atlasFormat/textureFormat 都是 rgba16，且像素 16 位原样到达设备", async () => {
  const atlas = buildAtlasFromSources([sourceOf("rgba16-7x5.plain.png", true)]);
  assert.ok(atlas.ok);
  if (!atlas.ok) return;
  assert.equal(atlas.value.format, PixelFormat.RGBA16, "前置：合成出来的图集应是 16 位");

  const { dev, atlasFormat } = await upload(atlas.value);
  assert.equal(atlasFormat, PixelFormat.RGBA16, "render 模块必须承认自己上传的是 16 位图集");

  const h = onlyTexture(dev);
  assert.equal(dev.textureFormat(h), PixelFormat.RGBA16, "设备记录的纹理格式不是 rgba16 —— 上传路径退回了 RGBA8");

  const digest = dev.textureDigest(h);
  assert.ok(digest !== undefined, "图集纹理没收到任何字节");
  assert.equal(
    digest,
    hashBytes(bytesOf(atlas.value.pixels16!)),
    "设备收到的字节必须与图集的 pixels16 **逐字节**相同（含字节序：Uint16Array 的宿主字节序）",
  );
  assert.notEqual(
    digest,
    hashBytes(atlas.value.pixels),
    "摘要与 8 位视图相同 —— 说明上传的是降采样后的 pixels，不是 pixels16",
  );
});

// ------------------------------------------------------------------ 8 位对照（反例）

test("上传反例：8 位图集 ⇒ atlasFormat/textureFormat 变回 rgba8，摘要对应 pixels", async () => {
  const atlas = buildAtlasFromSources([sourceOf("rgba8-2x2.plain.png", false)]);
  assert.ok(atlas.ok);
  if (!atlas.ok) return;
  assert.equal(atlas.value.format, undefined, "前置：纯 8 位源不该声明 rgba16");

  const { dev, atlasFormat } = await upload(atlas.value);
  assert.equal(atlasFormat, PixelFormat.RGBA8, "8 位图集必须报 rgba8 —— 否则上面那条的 rgba16 也可能是写死的");

  const h = onlyTexture(dev);
  assert.equal(dev.textureFormat(h), PixelFormat.RGBA8);
  assert.equal(dev.textureDigest(h), hashBytes(atlas.value.pixels));
});

// ------------------------------------------------------------------ 谎报格式

test("上传：图集声称 rgba16 却没有 pixels16 ⇒ init 失败（不许按 8 位偷偷上传）", async () => {
  const { ctx } = makeCtx();
  const lying: AtlasData = {
    width: 2,
    height: 2,
    pixels: new Uint8Array(2 * 2 * 4),
    format: PixelFormat.RGBA16,
    frames: new Map(),
  };
  const mod = createRenderModule({ viewportWidth: 800, viewportHeight: 600, atlas: lying });
  const r = await mod.init(ctx);
  assert.ok(r !== undefined && !r.ok, "声明 16 位却拿不出 16 位像素时，初始化必须失败");
  if (r !== undefined && !r.ok) assert.equal(r.error.code, "RENDER.BAD_ATLAS");
});

// ------------------------------------------------------------------ webgl2 的 GL 三元组

/**
 * ★ 为什么这条断言必须存在（且只能在这里）：
 *   通用契约只能证明"两个后端的**语义**一致"（长度校验），证明不了
 *   "webgl2 把 RGBA16 发成了 `internal=RGBA16 / type=UNSIGNED_SHORT`"。
 *   而本任务要修的正是这个缺陷：旧 `glFormat()` 对未知格式一律回落 RGBA8 ——
 *   尺寸校验照样通过，真 GL 却收到一张 8 位纹理。判据看 `texImage2D` 的参数才能抓到它。
 *
 * ⚠️ 边界：假的 GL 只能证明"我们发出了什么"，不能证明"驱动接受了它"。
 */
test("[webgl2] RGBA16 真的按 internal=0x805B / RGBA / UNSIGNED_SHORT 发出（RGBA16F 同理）", () => {
  const gl = new FakeGL2();
  const dev = new GL2Device(gl);

  const w = 4;
  const h = 4;
  const data16 = new Uint16Array(w * h * 4);
  for (let i = 0; i < data16.length; i++) data16[i] = (i * 1237) & 0xffff;
  const t = dev.createTexture({ width: w, height: h, format: PixelFormat.RGBA16 }, data16);
  assert.ok(t.ok, `RGBA16 纹理创建失败：${t.ok ? "" : t.error.code + " " + t.error.message}`);

  const up = gl.state.texImages.at(-1);
  assert.ok(up !== undefined, "fake 没记录到 texImage2D");
  assert.equal(up!.internal, 0x805b, "internalformat 必须是 RGBA16（0x805B）—— 落到 RGBA8 就是静默降采样");
  assert.equal(up!.format, 0x1908, "format 必须是 RGBA（0x1908）");
  assert.equal(up!.type, 0x1403, "type 必须是 UNSIGNED_SHORT（0x1403）—— 否则 GL 会按 1 字节/通道读");
  assert.equal(up!.bytes, w * h * 8, "上传字节数必须是 8 字节/像素");
  assert.deepEqual(gl.badCalls, [], "fake 认为这次 texImage2D 本身就不合法（长度/格式对不上）");

  // RGBA16F：8 字节/像素，但 internal 是 0x881A、type 是 HALF_FLOAT（0x140B）。
  // 旧实现把它当 RGBA8（internal 0x8058 + UNSIGNED_BYTE），这条能直接把那个回落抓出来。
  const half = new Uint8Array(w * h * 8);
  const tf = dev.createTexture({ width: w, height: h, format: PixelFormat.RGBA16F }, half);
  assert.ok(tf.ok, `RGBA16F 纹理创建失败：${tf.ok ? "" : tf.error.code + " " + tf.error.message}`);
  const up2 = gl.state.texImages.at(-1);
  assert.ok(up2 !== undefined);
  assert.equal(up2!.internal, 0x881a, "internalformat 必须是 RGBA16F（0x881A）");
  assert.equal(up2!.type, 0x140b, "type 必须是 HALF_FLOAT（0x140B）");
});
