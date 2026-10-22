/**
 * L4 · 导入产物加载器测试
 *
 * 守的缺陷：**导入管线全绿，资产却进不了世界**。
 *   `AssetImportPipeline` 只写产物与元数据；没有加载器时 `AssetDatabase.load()`
 *   永远返回 `ASSET.NO_LOADER` —— 报告完美，运行时是空的。
 *   这类"中间层做完、两头没接"的假完成，比报错难发现得多。
 *
 * 另外守三条"两处口径必须一致"的边界：
 *  ② 产物缺失与产物损坏是**两种**故障（一个该重导，一个该查是谁改的）；
 *  ③ 文本行数只认产物里的口径（导入器与加载器各算一次必然出现两种答案）；
 *  ④ 源文件删除后的清理不能把依赖链拆坏（删贴图前得先没人引用它）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { AssetDatabase } from "../../src/core/asset/asset.ts";
import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import { Logger, LogLevel } from "../../src/foundation/log/logger.ts";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import { ImporterRegistry } from "../../src/extensions/asset-import/importer.ts";
import { AssetImportPipeline } from "../../src/extensions/asset-import/pipeline.ts";
import { textureImporter } from "../../src/extensions/asset-import/importers/texture.ts";
import { atlasImporter } from "../../src/extensions/asset-import/importers/atlas.ts";
import { textImporter } from "../../src/extensions/asset-import/importers/text.ts";
import {
  ImportedAtlas,
  ImportedText,
  ImportedTexture,
  createImportLoaders,
} from "../../src/extensions/asset-import/loaders.ts";

function must<T>(r: Result<T, EngineError>): T {
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function writeU32(b: Uint8Array, at: number, v: number): void {
  b[at] = (v >>> 24) & 0xff;
  b[at + 1] = (v >>> 16) & 0xff;
  b[at + 2] = (v >>> 8) & 0xff;
  b[at + 3] = v & 0xff;
}

/** 只有头合法的 PNG（导入器只读 IHDR，不校验 CRC/IDAT）。 */
function png(width = 16, height = 16, bitDepth = 8, colorType = 6): Uint8Array {
  const b = new Uint8Array(33);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  writeU32(b, 8, 13);
  b.set([0x49, 0x48, 0x44, 0x52], 12);
  writeU32(b, 16, width);
  writeU32(b, 20, height);
  b[24] = bitDepth;
  b[25] = colorType;
  return b;
}

interface Rig {
  readonly fs: MemoryFileSystem;
  readonly db: AssetDatabase;
  readonly pipeline: AssetImportPipeline;
}

function rig(root = "/assets"): Rig {
  const fs = new MemoryFileSystem();
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Off);
  const db = new AssetDatabase(fs, log.channel("asset"));
  const registry = new ImporterRegistry();
  registry.register(textureImporter);
  registry.register(atlasImporter);
  registry.register(textImporter);
  const pipeline = new AssetImportPipeline(fs, db, registry, log.channel("asset.import"));
  for (const l of createImportLoaders({ root })) db.registerLoader(l);
  return { fs, db, pipeline };
}

test("贴图：导入后能 load 出元数据与原始字节（不是 NO_LOADER）", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png(24, 16, 8, 2));
  must(await pipeline.run("/assets"));

  const id = db.idAtPath("/assets/grass.png");
  assert.ok(id !== undefined, "导入后应能按路径查到 id");
  const h = await db.load<ImportedTexture>(id);
  assert.ok(h.ok, `加载失败：${h.ok ? "" : h.error.code + " " + h.error.message}`);
  assert.ok(h.value.asset instanceof ImportedTexture);
  assert.equal(h.value.asset.width, 24);
  assert.equal(h.value.asset.height, 16);
  assert.equal(h.value.asset.bitDepth, 8);
  assert.equal(h.value.asset.colorType, 2);
  assert.equal(h.value.asset.bytes.byteLength, 33, "交付的应是源字节（像素解码归 gfx）");
  assert.equal(h.value.asset.type, "texture");

  // 同时持有两个句柄时只加载一次（加载器不该被重复调用）
  const h2 = await db.load<ImportedTexture>(id);
  assert.ok(h2.ok);
  assert.equal(db.stats().cacheMiss, 1);
  assert.equal(db.stats().loaded, 1);
  assert.equal(db.stats().refs, 2);

  h.value.release();
  h2.value.release();
});

test("产物缺失：报 NO_ARTIFACT 并指出先跑导入（不是笼统的加载失败）", async () => {
  const { fs, db } = rig();
  // 只注册元数据，不跑管线 —— 模拟 library 被清空后直接起运行时
  await fs.writeBinary("/assets/grass.png", png());
  db.register({
    id: "ptest001",
    type: "texture",
    path: "/assets/grass.png",
    importerVersion: 1,
    sourceHash: "x",
    dependencies: [],
    byteLength: 33,
  });

  const h = await db.load("ptest001");
  assert.equal(h.ok, false);
  if (!h.ok) {
    assert.equal(h.error.code, "ASSET.NO_ARTIFACT");
    assert.match(h.error.message, /AssetImportPipeline/, "错误里要给出修复动作");
  }
});

test("产物损坏：报 BAD_ARTIFACT（与「还没导」是两种处置）", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png());
  must(await pipeline.run("/assets"));
  const id = must(okId(db, "/assets/grass.png"));

  // 手改产物：宽度字段变成字符串
  const path = `/assets/library/imported/${id}.json`;
  const raw = must(await fs.readText(path));
  const obj = JSON.parse(raw) as { data: Record<string, unknown> };
  obj.data["width"] = "twenty-four";
  must(await fs.writeText(path, JSON.stringify(obj, null, 2) + "\n"));

  const h = await db.load(id);
  assert.equal(h.ok, false);
  if (!h.ok) {
    assert.equal(h.error.code, "ASSET.BAD_ARTIFACT");
    assert.match(h.error.message, /width/, "要指出是哪个字段坏了");
  }
});

test("图集：帧数与依赖 id 顺序来自产物（贴图本体由依赖计数管理）", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png());
  await fs.writeBinary("/assets/rock.png", png());
  must(
    await fs.writeText(
      "/assets/pack.atlas.json",
      JSON.stringify({
        textures: ["rock.png", "grass.png"],
        frames: {
          a: { x: 0, y: 0, w: 16, h: 16 },
          b: { x: 16, y: 0, w: 16, h: 16 },
          c: { x: 32, y: 0, w: 16, h: 16 },
        },
      }),
    ),
  );
  must(await pipeline.run("/assets"));

  const atlasId = must(okId(db, "/assets/pack.atlas.json"));
  const h = await db.load<ImportedAtlas>(atlasId);
  assert.ok(h.ok);
  assert.ok(h.value.asset instanceof ImportedAtlas);
  assert.equal(h.value.asset.frameCount, 3);
  assert.deepEqual(
    h.value.asset.textureIds,
    [must(okId(db, "/assets/rock.png")), must(okId(db, "/assets/grass.png"))],
    "顺序必须是声明顺序（不是排序后的）",
  );
  // 贴图因为依赖而被递归加载：它们的引用计数此刻 > 0
  const desc = db.describe();
  assert.equal(desc.filter((d) => d.type === "texture" && d.refs > 0).length, 2);
  h.value.release();
});

test("文本：行数只认产物口径（末尾换行不多算一行）", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeText("/assets/note.txt", "a\nb\n");
  must(await pipeline.run("/assets"));
  const id = must(okId(db, "/assets/note.txt"));
  const h = await db.load<ImportedText>(id);
  assert.ok(h.ok);
  assert.equal(h.value.asset.lines, 2, "\"a\\nb\\n\" 是 2 行（末尾换行不额外算一行）");
  assert.equal(h.value.asset.text, "a\nb\n");
  h.value.release();
});

test("删源文件：本轮从注册表清掉（removed=1），之后 load 报 NOT_REGISTERED", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png());
  await fs.writeBinary("/assets/rock.png", png());
  must(await pipeline.run("/assets"));
  const goneId = must(okId(db, "/assets/grass.png"));

  must(await fs.remove("/assets/grass.png"));
  must(await fs.remove("/assets/grass.png.meta"));

  const rep = must(await pipeline.run("/assets"));
  assert.equal(rep.removed, 1);
  assert.equal(rep.registered, 1);
  assert.equal(db.meta(goneId), undefined, "幽灵注册必须被清掉");

  const h = await db.load(goneId);
  assert.equal(h.ok, false);
  if (!h.ok) assert.equal(h.error.code, "ASSET.NOT_REGISTERED");
});

test("删源文件但图集还在引用它：清理被拒绝，报告点名缺失依赖（不拆依赖链）", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png());
  must(
    await fs.writeText(
      "/assets/pack.atlas.json",
      JSON.stringify({ textures: ["grass.png"], frames: { a: { x: 0, y: 0, w: 16, h: 16 } } }),
    ),
  );
  must(await pipeline.run("/assets"));
  const texId = must(okId(db, "/assets/grass.png"));

  must(await fs.remove("/assets/grass.png"));
  must(await fs.remove("/assets/grass.png.meta"));
  const rep = must(await pipeline.run("/assets"));

  // ★ 真实顺序：图集这一轮先因为缺依赖导不进来（MISSING_DEPENDENCY），
  //   于是"注册成功数 = 0" ⇒ 本轮不做幽灵清理。所以贴图的注册**留在原地**，
  //   依赖链没有被拆坏。想真删掉它，得先删图集或改图集的 textures 列表。
  assert.equal(rep.removed, 0, "依赖方还在（虽然它本轮导入失败），就不能清");
  const hit = rep.failed.find((f) => f.code === "IMPORT.MISSING_DEPENDENCY");
  assert.ok(hit !== undefined, `报告必须点名缺失依赖，实际：${JSON.stringify(rep.failed)}`);
  assert.match(hit.message, /grass\.png/, "要点名缺的是哪张图");
  assert.ok(db.meta(texId) !== undefined, "元数据仍在（依赖方还需要它）");
});

// ------------------------------------------------------------------ 工具

function okId(db: AssetDatabase, path: string): Result<string, EngineError> {
  const id = db.idAtPath(path);
  return id === undefined
    ? { ok: false, error: { code: "TEST.NO_ID", message: `路径 ${path} 没有对应 id` } as EngineError }
    : { ok: true, value: id };
}
