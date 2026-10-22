/**
 * L4 · 资产导入管线测试
 *
 * 守的缺陷（每条都是上一代"资产没有身份"的后果）：
 *  ① 首次导入没有可复现身份 → 删一次 meta 全工程引用失效
 *  ② 每次构建都重导 → 构建时间随工程线性增长，产物反复重写
 *  ③ 改内容换了 id → 场景/图集里的引用静默断开
 *  ④ 导入器升级不重导 → 修了 bug 但老产物还在用
 *  ⑤ 移动文件丢 id → 重命名 = 删旧建新
 *  ⑥ 依赖顺序被排序 → 加载顺序不确定，跨机器行为不同
 *  ⑦ 一个坏文件中断整轮 → 一个坏 PNG 让整个工程导不进来
 *  ⑧ 未知格式被静默跳过 → 报告说"全部成功"，实际少了一半资产
 *  ⑨ 损坏 .meta 被"修复"成新 id → 用户的数据被静默改写
 *  ⑩ 非 ASCII 文件名 → 本机工程路径含中文，一崩就是全崩
 *  ⑪ 隐藏目录/产物目录被当成资产 → 导入 .git / library 自身
 *  ⑫ 相对路径含 `..` → 嵌套目录的图集永远解析不到依赖
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { AssetDatabase } from "../../src/core/asset/asset.ts";
import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import { Logger, LogLevel } from "../../src/foundation/log/logger.ts";
import type { EngineError, Result } from "../../src/foundation/result.ts";
import { ImporterRegistry } from "../../src/extensions/asset-import/importer.ts";
import { AssetImportPipeline } from "../../src/extensions/asset-import/pipeline.ts";
import type { ImportReport } from "../../src/extensions/asset-import/pipeline.ts";
import { textureImporter } from "../../src/extensions/asset-import/importers/texture.ts";
import { atlasImporter } from "../../src/extensions/asset-import/importers/atlas.ts";
import { textImporter } from "../../src/extensions/asset-import/importers/text.ts";

interface Rig {
  readonly fs: MemoryFileSystem;
  readonly db: AssetDatabase;
  readonly log: Logger;
  readonly pipeline: AssetImportPipeline;
}

function rig(textureVersion?: number): Rig {
  const fs = new MemoryFileSystem();
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Off);
  const db = new AssetDatabase(fs, log.channel("asset"));
  const registry = new ImporterRegistry();
  registry.register(
    textureVersion === undefined ? textureImporter : { ...textureImporter, version: textureVersion },
  );
  registry.register(atlasImporter);
  registry.register(textImporter);
  const pipeline = new AssetImportPipeline(fs, db, registry, log.channel("asset.import"));
  return { fs, db, log, pipeline };
}

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

/**
 * 造一份"只有头合法"的 PNG：签名 + IHDR（长 13 / 类型 / 宽高 / 位深 / 色彩类型 /
 * 压缩 / 过滤 / 隔行）+ 4 字节假 CRC。
 * 导入器只读头，所以不需要真实 IDAT —— 这正是它的边界（像素解码归 gfx 加载器）。
 */
function png(width = 16, height = 16, bitDepth = 8, colorType = 6): Uint8Array {
  const b = new Uint8Array(33);
  b.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  writeU32(b, 8, 13);
  b.set([0x49, 0x48, 0x44, 0x52], 12); // "IHDR"
  writeU32(b, 16, width);
  writeU32(b, 20, height);
  b[24] = bitDepth;
  b[25] = colorType;
  b[26] = 0; // compression
  b[27] = 0; // filter
  b[28] = 0; // interlace
  // b[29..32] 假 CRC：导入器不校验
  return b;
}

const ID_RE = /^[a-z0-9]{1,40}$/;

function assertReport(rep: ImportReport): void {
  assert.ok(rep.durationMs >= 0);
}

// ---------------------------------------------------------------- 1

test("首次导入：解析 PNG 宽高、生成 .meta、报告计数正确", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png(24, 16));

  const rep = must(await pipeline.run("/assets"));
  assertReport(rep);
  assert.equal(rep.scanned, 1);
  assert.equal(rep.created, 1);
  assert.equal(rep.imported, 1);
  assert.equal(rep.skipped, 0);
  assert.equal(rep.registered, 1);
  assert.deepEqual(rep.failed, []);

  assert.equal(await fs.exists("/assets/grass.png.meta"), true, "首次导入必须生成 sidecar");
  const metaText = must(await fs.readText("/assets/grass.png.meta"));
  assert.match(
    metaText,
    /^\{"id":"[a-z0-9]{1,40}","type":"texture","importerVersion":1,"settings":\{\}\}\n$/,
    "sidecar 必须是固定字段顺序的单行 JSON + 末尾换行",
  );

  const id = db.idAtPath("/assets/grass.png");
  assert.ok(id !== undefined, "路径必须能查到 id");
  const meta = db.meta(id);
  assert.ok(meta !== undefined);
  assert.equal(meta.type, "texture");

  const art = pipeline.artifactOf(id);
  assert.ok(art !== undefined);
  assert.equal(art.data["width"], 24, "宽必须来自 IHDR，而不是文件名/默认值");
  assert.equal(art.data["height"], 16);
  assert.equal(art.data["bitDepth"], 8);
  assert.equal(art.data["colorType"], 6);
  assert.equal(art.data["hasAlpha"], true);
});

// ---------------------------------------------------------------- 2

test("幂等：第二次 run 全部 skipped，产物逐字节不变", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png());

  must(await pipeline.run("/assets"));
  const id = db.idAtPath("/assets/grass.png");
  assert.ok(id !== undefined);
  const artifactPath = `/assets/library/imported/${id}.json`;
  const before = must(await fs.readText(artifactPath));

  const rep2 = must(await pipeline.run("/assets"));
  assert.equal(rep2.scanned, 1);
  assert.equal(rep2.created, 0, "第二轮不该再新建 .meta");
  assert.equal(rep2.imported, 0);
  assert.equal(rep2.skipped, 1);
  assert.equal(rep2.registered, 1, "跳过的资产仍要注册（load 需要 meta）");

  const after = must(await fs.readText(artifactPath));
  assert.equal(after, before, "同输入必须产出同字节，否则增量导入会污染 diff");
});

// ---------------------------------------------------------------- 3

test("改源 1 字节：重导，但 id 不变", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png());
  must(await pipeline.run("/assets"));
  const idBefore = db.idAtPath("/assets/grass.png");
  assert.ok(idBefore !== undefined);
  const hashBefore = db.meta(idBefore)?.sourceHash;

  const src = must(await fs.readBinary("/assets/grass.png"));
  const changed = new Uint8Array(src.length + 1);
  changed.set(src, 0);
  changed[src.length] = 0x2a;
  await fs.writeBinary("/assets/grass.png", changed);

  const rep = must(await pipeline.run("/assets"));
  assert.equal(rep.imported, 1);
  assert.equal(rep.skipped, 0);
  assert.equal(rep.created, 0);

  const idAfter = db.idAtPath("/assets/grass.png");
  assert.equal(idAfter, idBefore, "内容变化不该换身份");
  assert.notEqual(db.meta(idBefore)?.sourceHash, hashBefore, "hash 必须真的变了");
});

// ---------------------------------------------------------------- 4

test("导入器版本升级：源没变也要重导", async () => {
  const first = rig();
  await first.fs.writeBinary("/assets/grass.png", png());
  must(await first.pipeline.run("/assets"));

  // 同一个 fs/db，换一个 version=2 的导入器（同时验证"版本变了读缓存也无效"）。
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Off);
  const registry = new ImporterRegistry();
  registry.register({ ...textureImporter, version: 2 });
  registry.register(atlasImporter);
  registry.register(textImporter);
  const pipeline2 = new AssetImportPipeline(first.fs, first.db, registry, log.channel("asset.import"));

  const rep = must(await pipeline2.run("/assets"));
  assert.equal(rep.imported, 1, "importerVersion 变了必须重导");
  assert.equal(rep.skipped, 0);

  const id = first.db.idAtPath("/assets/grass.png");
  assert.ok(id !== undefined);
  assert.equal(first.db.meta(id)?.importerVersion, 2);
});

// ---------------------------------------------------------------- 5

test("移动/改名保 id：旧路径查不到，新路径沿用同一身份", async () => {
  const { fs, db, pipeline } = rig();
  const bytes = png();
  await fs.writeBinary("/assets/grass.png", bytes);
  must(await pipeline.run("/assets"));
  const idBefore = db.idAtPath("/assets/grass.png");
  assert.ok(idBefore !== undefined);
  const metaText = must(await fs.readText("/assets/grass.png.meta"));

  await fs.writeBinary("/assets/terrain/grass.png", bytes);
  await fs.writeText("/assets/terrain/grass.png.meta", metaText);
  must(await fs.remove("/assets/grass.png"));
  must(await fs.remove("/assets/grass.png.meta"));

  const rep = must(await pipeline.run("/assets"));
  assert.equal(rep.imported, 0, "内容没变，产物缓存按 id 命中");
  assert.equal(rep.skipped, 1);
  assert.equal(rep.created, 0, "移动过来的 .meta 不该被重新创建");

  assert.equal(db.idAtPath("/assets/terrain/grass.png"), idBefore);
  assert.equal(db.idAtPath("/assets/grass.png"), undefined, "db 的路径索引必须清掉旧路径");
});

// ---------------------------------------------------------------- 6

test("图集依赖：顺序 = 声明顺序；缺一张时报 MISSING_DEPENDENCY 并点名", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/terrain/grass.png", png(8, 8));
  await fs.writeBinary("/assets/terrain/rock.png", png(8, 8));
  await fs.writeText(
    "/assets/pack.atlas.json",
    JSON.stringify({
      textures: ["terrain/grass.png", "terrain/rock.png"],
      frames: { grass: { x: 0, y: 0, w: 8, h: 8 }, rock: { x: 8, y: 0, w: 8, h: 8 } },
    }),
  );

  must(await pipeline.run("/assets"));
  const atlasId = db.idAtPath("/assets/pack.atlas.json");
  const grassId = db.idAtPath("/assets/terrain/grass.png");
  const rockId = db.idAtPath("/assets/terrain/rock.png");
  assert.ok(atlasId !== undefined && grassId !== undefined && rockId !== undefined);

  // `.atlas.json` 必须赢过 `.json`（最长后缀优先），否则依赖全丢。
  assert.equal(db.meta(atlasId)?.type, "atlas");
  assert.deepEqual([...db.dependencies(atlasId)], [grassId, rockId], "依赖必须保持声明顺序");

  const art = pipeline.artifactOf(atlasId);
  assert.ok(art !== undefined);
  assert.equal(art.data["frames"], 2);

  must(await fs.remove("/assets/terrain/rock.png"));
  must(await fs.remove("/assets/terrain/rock.png.meta"));
  const rep = must(await pipeline.run("/assets"));
  const bad = rep.failed.find((f) => f.path === "/assets/pack.atlas.json");
  assert.ok(bad !== undefined, "图集缺依赖必须出现在 failed 里");
  assert.equal(bad.code, "IMPORT.MISSING_DEPENDENCY");
  assert.match(bad.message, /terrain\/rock\.png/, "必须点名缺的是哪个文件");
});

// ---------------------------------------------------------------- 7

test("坏 PNG：只记该文件的 BAD_SOURCE，其他文件照常导入", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/bad.png", new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d]));
  await fs.writeText("/assets/good.txt", "hello\nworld\n");

  const rep = must(await pipeline.run("/assets"));
  assert.equal(rep.scanned, 2);
  assert.equal(rep.failed.length, 1);
  assert.equal(rep.failed[0]?.path, "/assets/bad.png");
  assert.equal(rep.failed[0]?.code, "IMPORT.BAD_SOURCE");
  assert.match(rep.failed[0]?.message ?? "", /签名|截断/, "报错要能诊断，不能只说 bad source");

  assert.equal(rep.imported, 1);
  const txtId = db.idAtPath("/assets/good.txt");
  assert.ok(txtId !== undefined, "一个坏文件不能拖垮整轮");
  const txt = pipeline.artifactOf(txtId);
  assert.equal(txt?.data["lines"], 2);
  assert.equal(txt?.data["chars"], 12);
  assert.equal(txt?.data["encoding"], "utf-8");
  assert.equal(db.idAtPath("/assets/bad.png"), undefined, "失败的资产不该注册");
});

// ---------------------------------------------------------------- 8

test("未知扩展名（.fbx）：IMPORT.NO_IMPORTER，不静默跳过", async () => {
  const { fs, pipeline } = rig();
  await fs.writeBinary("/assets/model.fbx", new Uint8Array([1, 2, 3]));

  const rep = must(await pipeline.run("/assets"));
  assert.equal(rep.scanned, 1);
  assert.equal(rep.failed.length, 1);
  assert.equal(rep.failed[0]?.code, "IMPORT.NO_IMPORTER");
  assert.equal(rep.created, 0, "没有导入器就不该建 .meta");
  assert.equal(await fs.exists("/assets/model.fbx.meta"), false);
});

// ---------------------------------------------------------------- 9

test("损坏 .meta：BAD_META，且绝不覆盖原文件", async () => {
  const { fs, pipeline } = rig();
  await fs.writeBinary("/assets/grass.png", png());
  const broken = "这不是 JSON {";
  await fs.writeText("/assets/grass.png.meta", broken);

  const rep = must(await pipeline.run("/assets"));
  assert.equal(rep.failed.length, 1);
  assert.equal(rep.failed[0]?.code, "IMPORT.BAD_META");
  assert.match(rep.failed[0]?.message ?? "", /grass\.png\.meta/, "message 要带路径");

  assert.equal(must(await fs.readText("/assets/grass.png.meta")), broken, "坏文件必须原样保留，供人修复");

  // 字段级诊断：缺 settings 也要点名，而不是一句"meta 坏了"。
  const missing = '{"id":"pabc1234","type":"texture","importerVersion":1}';
  await fs.writeText("/assets/grass.png.meta", missing);
  const rep2 = must(await pipeline.run("/assets"));
  assert.equal(rep2.failed[0]?.code, "IMPORT.BAD_META");
  assert.match(rep2.failed[0]?.message ?? "", /settings/, "必须指出坏的是哪个字段");
  assert.equal(must(await fs.readText("/assets/grass.png.meta")), missing);
});

// ---------------------------------------------------------------- 10

test("非 ASCII 文件名/目录：正常导入、id 合法、路径可查", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/草地.png", png(12, 10));
  await fs.writeBinary("/assets/雪原/松树.png", png(7, 9));

  const rep = must(await pipeline.run("/assets"));
  assert.equal(rep.scanned, 2);
  assert.equal(rep.imported, 2);
  assert.deepEqual(rep.failed, []);

  const a = db.idAtPath("/assets/草地.png");
  const b = db.idAtPath("/assets/雪原/松树.png");
  assert.ok(a !== undefined && b !== undefined);
  assert.match(a, ID_RE);
  assert.match(b, ID_RE);
  assert.notEqual(a, b, "不同路径必须得到不同 id");

  assert.equal(pipeline.artifactOf(a)?.data["width"], 12);
  assert.equal(pipeline.artifactOf(b)?.data["height"], 9);
});

// ---------------------------------------------------------------- 11

test("隐藏文件/目录与 library 产物目录被跳过（scanned 不含它们）", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeText("/assets/ok.txt", "ok");
  await fs.writeText("/assets/.gitignore", "*.tmp");
  await fs.writeBinary("/assets/.cache/x.png", png());

  const rep = must(await pipeline.run("/assets"));
  assert.equal(rep.scanned, 1, "隐藏项不该计入扫描数");
  assert.equal(rep.created, 1);
  assert.ok(db.idAtPath("/assets/ok.txt") !== undefined);
  assert.equal(db.idAtPath("/assets/.cache/x.png"), undefined);
  assert.equal(await fs.exists("/assets/.cache/x.png.meta"), false);

  // 第二轮：library/ 是我们自己的产物目录，不能再被当成源文件扫进来。
  const rep2 = must(await pipeline.run("/assets"));
  assert.equal(rep2.scanned, 1, "library/ 必须被跳过，否则产物会自我循环导入");
  assert.equal(rep2.skipped, 1);
});

// ---------------------------------------------------------------- 12

test("嵌套目录图集用 ../ 引用兄弟目录的贴图能解析", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/terrain/grass.png", png(8, 8));
  await fs.writeText(
    "/assets/atlas/pack.atlas.json",
    JSON.stringify({
      textures: ["../terrain/grass.png"],
      frames: { grass: { x: 0, y: 0, w: 8, h: 8 } },
    }),
  );

  const rep = must(await pipeline.run("/assets"));
  assert.deepEqual(rep.failed, []);

  const atlasId = db.idAtPath("/assets/atlas/pack.atlas.json");
  const grassId = db.idAtPath("/assets/terrain/grass.png");
  assert.ok(atlasId !== undefined && grassId !== undefined);
  assert.deepEqual([...db.dependencies(atlasId)], [grassId]);
});

// ---------------------------------------------------------------- 13

test("id 冲突：两个源共用同一 id → IMPORT.ID_COLLISION，不静默加后缀", async () => {
  const { fs, db, pipeline } = rig();
  await fs.writeBinary("/assets/a.png", png());
  await fs.writeBinary("/assets/b.png", png());
  const shared = '{"id":"pabc1234","type":"texture","importerVersion":1,"settings":{}}\n';
  await fs.writeText("/assets/a.png.meta", shared);
  await fs.writeText("/assets/b.png.meta", shared);

  const rep = must(await pipeline.run("/assets"));
  const bad = rep.failed.find((f) => f.code === "IMPORT.ID_COLLISION");
  assert.ok(bad !== undefined, "同 id 两个源必须报冲突");
  assert.match(bad.message, /a\.png/);
  assert.match(bad.message, /b\.png/);

  // 排序后 a.png 先占用 id；b.png 失败，不能再造一个 "pabc1234-1"。
  assert.equal(db.idAtPath("/assets/a.png"), "pabc1234");
  assert.equal(db.idAtPath("/assets/b.png"), undefined);
});
