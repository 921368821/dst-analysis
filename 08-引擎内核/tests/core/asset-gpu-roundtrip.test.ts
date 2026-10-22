/**
 * 资产 → GPU 闭环（内容板块的出口判据）
 *
 * 守的缺陷：**"导入管线全绿"与"画面用上了真资产"是两件独立的事**，
 *   而这轮之前它们之间的连线根本不存在 ——
 *   管线把 `.meta`/增量/依赖全做对了，浏览器却还在用程序化生成的假图集。
 *   中间层的判据越漂亮，这个盲区越难发现（所有判据都绿，画面还是假贴图）。
 *
 * 这条判据把四段接成一根链条，每段都必须真的发生：
 *   ① `web/assets/*.png` 是**磁盘上的真文件**（不是自造字节）
 *   ② 它们被导入管线扫到、生成 `.meta`、按路径派生 id
 *   ③ `db.load` 交回的 `ImportedTexture.bytes` 被 `decodePng` 解成 RGBA8
 *   ④ 合成出的 `AtlasData.pixels` **逐字节**到达 GPU（用 null 后端的摘要比对）
 *
 * ★ 为什么第 ④ 步用摘要而不是像素：2048² 一张就 16 MB。
 * ★ 为什么必须有反例（改一个字节摘要得变）：否则"两边都是空流摘要"
 *   或"摘要函数恒返回常量"时，这条判据会**假绿**。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

import { hashBytes } from "../../src/foundation/hash.ts";
import { Logger, LogLevel } from "../../src/foundation/log/logger.ts";
import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import { NullGraphicsDevice } from "../../src/backends/gfx-null/device.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { BackendRegistry } from "../../src/platform/registry.ts";
import { AssetDatabase } from "../../src/core/asset/asset.ts";
import { bootGameApp } from "../../src/runtime/GameApp.ts";
import { ImporterRegistry } from "../../src/extensions/asset-import/importer.ts";
import { AssetImportPipeline, type ImportReport } from "../../src/extensions/asset-import/pipeline.ts";
import { textureImporter } from "../../src/extensions/asset-import/importers/texture.ts";
import { atlasImporter } from "../../src/extensions/asset-import/importers/atlas.ts";
import { textImporter } from "../../src/extensions/asset-import/importers/text.ts";
import { ImportedTexture, createImportLoaders } from "../../src/extensions/asset-import/loaders.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";
import { buildAtlasFromSources, type AtlasSource } from "../../src/extensions/render/atlas-from-assets.ts";
import { createRenderModule } from "../../src/extensions/render/render-module.ts";
import type { AtlasData } from "../../src/extensions/render/atlas.ts";

/** 与 `browser-entry.ts` 的 `DEMO_FRAMES` 保持一致（那边是宿主，这边是判据）。 */
const ASSET_NAMES = ["ground", "tree", "rock", "berry", "player"] as const;

function assetUrl(name: string): URL {
  return new URL(`../../web/assets/${name}.png`, import.meta.url);
}

async function readAsset(name: string): Promise<Uint8Array> {
  const buf = await readFile(fileURLToPath(assetUrl(name)));
  return new Uint8Array(buf);
}

interface AssetRig {
  readonly fs: MemoryFileSystem;
  readonly db: AssetDatabase;
  readonly pipeline: AssetImportPipeline;
  readonly report: ImportReport;
}

/** 把 web/assets 的真实字节灌进内存 fs，跑完整导入管线。 */
async function importRealAssets(): Promise<AssetRig> {
  const fs = new MemoryFileSystem();
  const logger = new Logger(() => 0);
  logger.setLevel(LogLevel.Off);
  const db = new AssetDatabase(fs, logger.channel("asset"));
  const importers = new ImporterRegistry();
  importers.register(textureImporter);
  importers.register(atlasImporter);
  importers.register(textImporter);
  const pipeline = new AssetImportPipeline(fs, db, importers, logger.channel("import"));
  // ★ 加载器必须显式注册，且 root 必须与 pipeline.run(root) 的 root **一模一样**：
  //   产物路径规则是 `<root>/library/imported/<id>.json`，两处 root 不一致时
  //   `db.load` 会报"产物不在"——症状是"导入全绿、运行时全空"，很难从报错看出根因。
  for (const l of createImportLoaders({ root: "/assets" })) db.registerLoader(l);

  for (const name of ASSET_NAMES) {
    const w = await fs.writeBinary(`/assets/${name}.png`, await readAsset(name));
    assert.ok(w.ok, `写入 ${name}.png 失败`);
  }
  const rep = await pipeline.run("/assets");
  assert.ok(rep.ok, `导入管线失败：${rep.ok ? "" : rep.error.code + " " + rep.error.message}`);
  return { fs, db, pipeline, report: rep.value };
}

/** 从已导入的资产解出图集。 */
async function buildRealAtlas(rig: AssetRig): Promise<AtlasData> {
  const sources: AtlasSource[] = [];
  for (const name of ASSET_NAMES) {
    const id = rig.db.idAtPath(`/assets/${name}.png`);
    assert.ok(id !== undefined, `${name}.png 导入后应能按路径查到 id`);
    const h = await rig.db.load(id);
    assert.ok(h.ok, `${name} 加载失败：${h.ok ? "" : h.error.code + " " + h.error.message}`);
    try {
      const asset = h.value.asset;
      assert.ok(
        asset instanceof ImportedTexture,
        `${name} 应加载成 ImportedTexture，实际 ${asset.constructor.name}（缺加载器时会退化成别的类型）`,
      );
      const dec = decodePng(asset.bytes);
      assert.ok(dec.ok, `${name} 解码失败：${dec.ok ? "" : dec.error.code + " " + dec.error.message}`);
      sources.push({ name, png: dec.value });
    } finally {
      h.value.release();
    }
  }
  const built = buildAtlasFromSources(sources, { padding: 2 });
  assert.ok(built.ok, `图集合成失败：${built.ok ? "" : built.error.code + " " + built.error.message}`);
  return built.value;
}

/** 用 null 后端 boot 一个只挂渲染模块的 app，返回设备与渲染模块。 */
async function bootWithAtlas(atlas: AtlasData): Promise<{ dev: NullGraphicsDevice }> {
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  const mod = createRenderModule({ viewportWidth: 800, viewportHeight: 600, zoom: 32, atlas });
  const appR = await bootGameApp({
    platformId: "test.roundtrip",
    interactive: false,
    registry,
    modules: [mod],
    seed: 20261022,
  });
  assert.ok(appR.ok, `bootGameApp 失败：${appR.ok ? "" : appR.error.code + " " + appR.error.message}`);
  return { dev: appR.value.platform.gfx as unknown as NullGraphicsDevice };
}

// ---------------------------------------------------------------- ① 导入

test("资产链：web/assets 的 5 张真 PNG 被扫到、生成 .meta、按路径拿到 id", async () => {
  const rig = await importRealAssets();

  assert.equal(rig.report.scanned, ASSET_NAMES.length, `应扫到 ${ASSET_NAMES.length} 个源文件`);
  assert.equal(rig.report.created, ASSET_NAMES.length, "首次导入应为每个源文件生成 .meta");
  assert.equal(rig.report.imported, ASSET_NAMES.length);
  assert.deepEqual(rig.report.failed, [], "不应有导入失败");

  for (const name of ASSET_NAMES) {
    assert.ok(
      (await rig.fs.exists(`/assets/${name}.png.meta`)),
      `${name}.png.meta 必须落盘 —— 没有它 id 就只能靠路径派生，改名即断引用`,
    );
    assert.ok(rig.db.idAtPath(`/assets/${name}.png`) !== undefined);
  }
});

test("资产链：第二次导入是增量的（skipped=5 / imported=0），id 不变", async () => {
  const rig = await importRealAssets();
  const before = ASSET_NAMES.map((n) => rig.db.idAtPath(`/assets/${n}.png`));

  const again = await rig.pipeline.run("/assets");
  assert.ok(again.ok);
  assert.equal(again.value.imported, 0, "源没变、importerVersion 没变 ⇒ 一个都不该重导");
  assert.equal(again.value.skipped, ASSET_NAMES.length);

  const after = ASSET_NAMES.map((n) => rig.db.idAtPath(`/assets/${n}.png`));
  assert.deepEqual(after, before, "增量导入不许改 id");
});

// ---------------------------------------------------------------- ② 解码

test("资产链：解码出的尺寸与导入产物记录的头信息一致（不是'解出来就行'）", async () => {
  const rig = await importRealAssets();

  for (const name of ASSET_NAMES) {
    const id = rig.db.idAtPath(`/assets/${name}.png`);
    assert.ok(id !== undefined);
    const h = await rig.db.load(id);
    assert.ok(h.ok);
    try {
      const tex = h.value.asset as ImportedTexture;
      const dec = decodePng(tex.bytes);
      assert.ok(dec.ok);
      assert.equal(dec.value.width, tex.width, `${name} 解码宽度应等于 IHDR 声明值`);
      assert.equal(dec.value.height, tex.height, `${name} 解码高度应等于 IHDR 声明值`);
      assert.equal(
        dec.value.pixels.byteLength,
        tex.width * tex.height * 4,
        `${name} 必须交出紧凑的 RGBA8（少了就会错行，多了就会上传越界）`,
      );
    } finally {
      h.value.release();
    }
  }
});

// ---------------------------------------------------------------- ③④ 图集 → GPU

test("闭环：合成的图集上传到 GPU 的字节，与解码结果逐字节一致", async () => {
  const rig = await importRealAssets();
  const atlas = await buildRealAtlas(rig);

  assert.equal(atlas.frames.size, ASSET_NAMES.length, "每一帧都必须进图集");
  assert.equal(atlas.pixels.byteLength, atlas.width * atlas.height * 4);
  // 2 的幂：GPU 友好（也是合成器承诺的确定性的一部分）
  assert.equal(atlas.width & (atlas.width - 1), 0, `图集宽应为 2 的幂，实际 ${atlas.width}`);
  assert.equal(atlas.height & (atlas.height - 1), 0, `图集高应为 2 的幂，实际 ${atlas.height}`);

  const { dev } = await bootWithAtlas(atlas);
  const handles = dev.textureHandles;
  assert.equal(handles.length, 1, `渲染模块应只创建一张图集纹理，实际 ${handles.length} 张`);

  const digest = dev.textureDigest(handles[0]!);
  assert.ok(
    digest !== undefined,
    "图集纹理没有收到任何字节 —— createTexture 的 data 参数被丢了（这正是'假贴图'的样子）",
  );
  assert.equal(
    digest,
    hashBytes(atlas.pixels),
    "GPU 收到的字节必须与'解码 + 合成'产出的 RGBA8 完全相同",
  );
});

test("闭环反例：改一个像素，摘要必须变（否则上一条是恒绿的）", async () => {
  const rig = await importRealAssets();
  const atlas = await buildRealAtlas(rig);

  const { dev: devA } = await bootWithAtlas(atlas);
  const baseDigest = devA.textureDigest(devA.textureHandles[0]!);
  assert.ok(baseDigest !== undefined);

  const mutated: AtlasData = {
    width: atlas.width,
    height: atlas.height,
    pixels: new Uint8Array(atlas.pixels),
    frames: atlas.frames,
  };
  // 只翻一个字节的最低有效位：最"看不见"的改动，摘要也必须变
  mutated.pixels[0] = (mutated.pixels[0]! ^ 0x01) & 0xff;

  const { dev: devB } = await bootWithAtlas(mutated);
  const mutDigest = devB.textureDigest(devB.textureHandles[0]!);
  assert.ok(mutDigest !== undefined);
  assert.notEqual(
    mutDigest,
    baseDigest,
    "一个字节变了摘要却相同 —— 说明这条链上的摘要根本没覆盖像素内容",
  );
  assert.equal(mutDigest, hashBytes(mutated.pixels), "反例的摘要也必须等于它自己的正确摘要");
});

test("闭环反例：不传 atlas 时用的是程序化图集，摘要与资产图集不同（降级可辨识）", async () => {
  const rig = await importRealAssets();
  const atlas = await buildRealAtlas(rig);
  const { dev: devAsset } = await bootWithAtlas(atlas);
  const assetDigest = devAsset.textureDigest(devAsset.textureHandles[0]!);

  // 不传 atlas ⇒ 渲染模块自己 buildProceduralAtlas()
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  const mod = createRenderModule({ viewportWidth: 800, viewportHeight: 600, zoom: 32 });
  const appR = await bootGameApp({
    platformId: "test.roundtrip.proc",
    interactive: false,
    registry,
    modules: [mod],
    seed: 20261022,
  });
  assert.ok(appR.ok);
  const devProc = appR.value.platform.gfx as unknown as NullGraphicsDevice;
  const procDigest = devProc.textureDigest(devProc.textureHandles[0]!);

  assert.ok(procDigest !== undefined);
  assert.notEqual(
    procDigest,
    assetDigest,
    "程序化图集与资产图集摘要相同 —— 意味着'降级'在数据上不可辨识，HUD 上的 atlas 标签也就成了装饰",
  );
});
