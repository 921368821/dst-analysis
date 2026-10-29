/**
 * 构建发布 CLI：**导入管线 → 内容寻址资产包 → 产物目录**
 *
 * 这条命令是阶段 5 的第一件真东西。它的验收不是"能跑"，而是两条出口判据：
 *   ① 删掉一个**未被引用**的资产后，产物**逐字节不变**；
 *   ② 改动一个资产只重打**一个**包（包名 = 内容 hash，其余包名不变）。
 * 两条都在 `tests/extensions/build-cli.test.ts` 里用子进程真跑。
 *
 * ★ 五个刻意的决定：
 *
 * ① **入口在配置里显式写**，不从目录倒推。
 *    "所有文件都是入口"看起来省事，但那等于没有闭包 —— 判据 ① 会永远成立不了，
 *    而且往资产目录丢一张草稿就会改变线上包。
 *
 * ② **在内存盘里跑导入管线**，不往资产目录写 `.meta`。
 *    真实构建工具（Unity）确实会写 `.meta`，但那要求"构建产物"与"工作区"分离，
 *    否则一次构建就让 `git status` 变脏、CI 的"工作区干净"检查随之失效。
 *    这里把源字节**拷进内存盘**再跑，磁盘一个字节都不动。
 *
 * ③ **写盘前先比字节**：内容寻址的产物天然幂等 —— 一样的包不该重写一遍
 *    （重写会更新时间戳，破坏"同样输入 → 同样产物"的可核对性，也浪费增量上传）。
 *
 * ④ **失败点名到文件**：导入报告里 `failed` 非空就整体失败，并把每个失败的文件与错误码打出来。
 *    "构建成功但少了两张图"是上线后才发现的经典事故。
 *
 * ⑤ **退出码三分**：0 成功 / 1 构建失败 / 2 配置或环境问题（配置读不到、资产根不存在）。
 *    把 2 混进 1 会让人去查一个不存在的构建 bug。
 *
 * 用法：
 *   node --experimental-transform-types tools/build.ts [--config build.config.json] [--out DIR] [--verbose]
 */

import { readFileSync } from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";

import { NodeFileSystem } from "../src/backends/fs-node/fs.ts";
import { MemoryFileSystem } from "../src/backends/fs-memory/fs.ts";
import { Logger, LogLevel } from "../src/foundation/log/logger.ts";
import { AssetDatabase } from "../src/core/asset/asset.ts";
import { ImporterRegistry } from "../src/extensions/asset-import/importer.ts";
import { AssetImportPipeline } from "../src/extensions/asset-import/pipeline.ts";
import { textureImporter } from "../src/extensions/asset-import/importers/texture.ts";
import { atlasImporter } from "../src/extensions/asset-import/importers/atlas.ts";
import { textImporter } from "../src/extensions/asset-import/importers/text.ts";
import { buildPublish, renderManifest } from "../src/extensions/build/publish.ts";
import { collectPublishInput } from "../src/extensions/build/from-pipeline.ts";

const EXIT_OK = 0;
const EXIT_BUILD_FAILED = 1;
const EXIT_CONFIG = 2;

interface Config {
  readonly assetRoot: string;
  /**
   * manifest 里登记的**运行时路径前缀**（批127）。缺省 = 与 `assetRoot` 相同（老行为）。
   * 演示站点的运行时挂载根是 `/assets`，而源文件在 `/web/assets` —— 两者不等时
   * 必须显式写出来，否则 `?pack=` 读到的每个键都是 NOT_FOUND（见 `CollectOptions.mount`）。
   */
  readonly mount?: string;
  readonly entries: readonly string[];
  readonly outDir: string;
  readonly maxBundleBytes?: number;
}

function die(code: number, msg: string): never {
  console.error(`✗ ${msg}`);
  process.exit(code);
}

function arg(name: string): string | undefined {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : undefined;
}

/** 配置里的路径一律**相对配置文件所在目录**（绝对路径也接受，但要落在同一个根里）。 */
function loadConfig(configPath: string): Config {
  let raw: string;
  try {
    raw = readFileSync(configPath, "utf8");
  } catch (e) {
    die(EXIT_CONFIG, `读不到配置 ${configPath}：${e instanceof Error ? e.message : String(e)}`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch (e) {
    die(EXIT_CONFIG, `配置不是合法 JSON（${configPath}）：${e instanceof Error ? e.message : String(e)}`);
  }
  const obj = parsed as Partial<Config> & Record<string, unknown>;
  if (typeof obj.assetRoot !== "string" || !Array.isArray(obj.entries) || typeof obj.outDir !== "string") {
    die(EXIT_CONFIG, "配置需要 assetRoot（字符串）/ entries（数组）/ outDir（字符串）");
  }
  const entries = obj.entries.filter((x): x is string => typeof x === "string");
  if (entries.length !== obj.entries.length) die(EXIT_CONFIG, "entries 里只能有字符串");
  if (entries.length === 0) {
    // ★ 空入口 = 空产物。让它"成功"是最坏的结果：线上会变成一个什么都没有的包。
    die(EXIT_CONFIG, "entries 不能为空 —— 空入口会构建出一个没有内容的包");
  }
  return {
    assetRoot: obj.assetRoot,
    entries,
    outDir: obj.outDir,
    ...(typeof obj.mount === "string" ? { mount: obj.mount } : {}),
    ...(typeof obj.maxBundleBytes === "number" ? { maxBundleBytes: obj.maxBundleBytes } : {}),
  };
}

/** 把配置里的相对路径变成以 `/` 开头的 scheme 内路径。 */
function toFsPath(p: string): string {
  const norm = p.replace(/\\/g, "/");
  if (!norm.startsWith("/")) die(EXIT_CONFIG, `路径必须是 scheme 内绝对路径（以 / 开头）：${p}`);
  if (norm.includes("..")) die(EXIT_CONFIG, `路径不能包含 ..：${p}`);
  return norm;
}

async function main(): Promise<void> {
  const configPath = resolve(arg("--config") ?? "build.config.json");
  const verbose = process.argv.includes("--verbose");
  const cfg = loadConfig(configPath);
  const projectRoot = dirname(configPath);
  const outOverride = arg("--out");
  const outDir = toFsPath(outOverride === undefined ? cfg.outDir : isAbsolute(outOverride) ? outOverride : `/${outOverride}`);
  const assetRoot = toFsPath(cfg.assetRoot);

  const disk = new NodeFileSystem(projectRoot, { createRoot: false });
  if (!(await disk.exists(assetRoot))) {
    die(EXIT_CONFIG, `资产根不存在：${join(projectRoot, assetRoot)}`);
  }

  // ---- ① 源字节拷进内存盘（不往工作区写任何东西）
  const mem = new MemoryFileSystem();
  const copyOne = async (path: string): Promise<void> => {
    const r = await disk.readBinary(path);
    if (!r.ok) die(EXIT_BUILD_FAILED, `读 ${path} 失败：${r.error.code} ${r.error.message}`);
    const w = await mem.writeBinary(path, r.value);
    if (!w.ok) die(EXIT_BUILD_FAILED, `写内存盘 ${path} 失败：${w.error.code}`);
  };
  const listed = await disk.list(assetRoot);
  if (!listed.ok) die(EXIT_CONFIG, `列不出资产根 ${assetRoot}：${listed.error.code}`);
  const pending = [...listed.value];
  while (pending.length > 0) {
    const e = pending.pop()!;
    if (e.isDirectory) {
      const sub = await disk.list(e.path);
      if (!sub.ok) die(EXIT_BUILD_FAILED, `列 ${e.path} 失败：${sub.error.code}`);
      pending.push(...sub.value);
    } else {
      await copyOne(e.path);
    }
  }

  // ---- ② 跑导入管线（真跑：id 与依赖边都由它给）
  const log = new Logger(() => 0);
  log.setLevel(verbose ? LogLevel.Debug : LogLevel.Warn);
  const db = new AssetDatabase(mem, log.channel("asset"));
  const registry = new ImporterRegistry();
  registry.register(textureImporter);
  registry.register(atlasImporter);
  registry.register(textImporter);
  const pipeline = new AssetImportPipeline(mem, db, registry, log.channel("import"));
  const report = await pipeline.run(assetRoot);
  if (!report.ok) die(EXIT_BUILD_FAILED, `导入失败：${report.error.code} ${report.error.message}`);
  if (report.value.failed.length > 0) {
    console.error(`✗ 有 ${String(report.value.failed.length)} 个文件导入失败 —— 构建不会产出缺件的包：`);
    for (const f of report.value.failed) console.error(`  · ${f.path}  ${f.code}  ${f.message}`);
    process.exit(EXIT_BUILD_FAILED);
  }

  // ---- ③ 入口是**路径**（人写的），引擎要的是 id
  const entries: string[] = [];
  for (const p of cfg.entries) {
    const path = toFsPath(p);
    const id = db.idAtPath(path);
    if (id === undefined) die(EXIT_BUILD_FAILED, `入口 ${path} 不在导入注册表里 —— 文件不存在，或扩展名没有导入器`);
    entries.push(id);
  }

  // ---- ④ 收集 + 打包
  const input = await collectPublishInput(mem, db, {
    root: assetRoot,
    entries,
    ...(cfg.mount === undefined ? {} : { mount: cfg.mount }),
  });
  if (!input.ok) die(EXIT_BUILD_FAILED, `收集资产失败：${input.error.code} ${input.error.message}`);
  const built = buildPublish(input.value, cfg.maxBundleBytes === undefined ? {} : { maxBundleBytes: cfg.maxBundleBytes });
  if (!built.ok) die(EXIT_BUILD_FAILED, `打包失败：${built.error.code} ${built.error.message}`);

  // ---- ⑤ 落盘（内容寻址 ⇒ 先比字节，再决定写不写）
  const ensured = await disk.ensureDir(`${outDir}/bundles`);
  if (!ensured.ok) die(EXIT_BUILD_FAILED, `建产物目录失败：${ensured.error.code}`);
  let written = 0;
  let skipped = 0;
  const writeIfChanged = async (path: string, bytes: Uint8Array): Promise<void> => {
    const old = await disk.readBinary(path);
    if (old.ok && old.value.length === bytes.length && old.value.every((b, i) => b === bytes[i])) {
      skipped++;
      return;
    }
    const w = await disk.writeBinary(path, bytes);
    if (!w.ok) die(EXIT_BUILD_FAILED, `写 ${path} 失败：${w.error.code} ${w.error.message}`);
    written++;
  };

  for (const [hash, bytes] of built.value.bundles) {
    await writeIfChanged(`${outDir}/bundles/${hash}.bin`, bytes);
    if (verbose) console.log(`  bundle ${hash.slice(0, 12)}  ${String(bytes.length)}B`);
  }
  const manifestText = renderManifest(built.value.manifest);
  await writeIfChanged(`${outDir}/manifest.txt`, new TextEncoder().encode(manifestText));
  // ★ 同时写一份**机器可读**的 manifest：`manifest.txt` 是给人 diff 与排查用的，
  //   运行时读取必须走 JSON（解析文本格式等于再实现一遍渲染器，两份必然分叉）。
  //   两者内容同源（同一个 manifest 对象），所以"人看到的"和"运行时用的"不会不一致。
  const manifestJson = `${JSON.stringify(built.value.manifest, null, 2)}\n`;
  await writeIfChanged(`${outDir}/manifest.json`, new TextEncoder().encode(manifestJson));

  // ---- ⑥ 清掉不再被 manifest 引用的旧包
  // ★ 不清的后果不是"占空间"那么轻：产物目录会同时存在新旧两个版本的包，
  //   "改了资产只换一个包名"这条判据在**目录层面**就看不出来（旧名还在），
  //   而部署脚本按目录同步时会把一堆死包一起传上去。
  const live = new Set([...built.value.bundles.keys()].map((h) => `${h}.bin`));
  let pruned = 0;
  const existing = await disk.list(`${outDir}/bundles`);
  if (existing.ok) {
    for (const e of existing.value) {
      if (e.isDirectory || !e.name.endsWith(".bin")) continue;
      if (live.has(e.name)) continue;
      const rm = await disk.remove(e.path);
      if (!rm.ok) die(EXIT_BUILD_FAILED, `删旧包 ${e.path} 失败：${rm.error.code}`);
      pruned++;
    }
  }

  console.log(`manifest ${built.value.manifest.hash}`);
  console.log(`assets ${String(built.value.manifest.assets.length)}`);
  console.log(`bundles ${String(built.value.manifest.bundles.length)}`);
  console.log(`written ${String(written)} skipped ${String(skipped)}`);
  console.log(`pruned ${String(pruned)}`);
  process.exit(EXIT_OK);
}

void main();
