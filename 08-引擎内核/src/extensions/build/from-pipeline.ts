/**
 * L4 · 构建发布 ← 导入管线（把"导入了什么"变成"要发布什么"）
 *
 * `publish.ts` 只要 `PublishInput`（id / 字节 / 依赖边），它不关心这些从哪来。
 * 本文件回答"从哪来"：**从导入管线的注册表里来，不从目录列表里来**。
 *
 * ★ 这个区分不是形式主义，它决定了三条行为：
 *   ① **身份**：资产 id 由导入器给（`MetaIdTable`），不是由文件名拼的。
 *      自己拼 id 的后果是"重命名文件 = 换一个资产"，依赖边、增量缓存全断。
 *   ② **依赖**：依赖边来自 `.meta`，是导入器解析出来的（图集的 `textures`）。
 *      自己扫目录猜依赖，猜漏一条就会发布出一个缺件的包 —— 而它"能上线"。
 *   ③ **哪些算资产**：只有被导入器认领的文件才是资产。目录里的草稿、`.DS_Store`、
 *      已经删掉的源文件留下的 `.meta`，都不该进产物。
 *      所以这里**只收"注册表里查得到 id"的文件**，查不到的报错而不是跳过：
 *      静默跳过会让"少发布了一个资产"变成发布成功。
 *
 * ★ 发布的是**源字节**（导入器的输入），不是解码后的 GPU 产物。
 *   原因：运行时的加载器（`createImportLoaders`）吃的就是源字节 + 导入产物元数据。
 *   把解码后的像素发布出去需要一套"发布格式 + 运行时直读"的新契约，那是另一批的事；
 *   在那之前假装做了，只会得到一个"看起来很先进、实际上没法加载"的包。
 *   这条界线写在这里，免得以后有人以为漏了。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import type { IReadableFileSystem } from "../../platform/fs/fs.ts";
import type { AssetDatabase, AssetId } from "../../core/asset/asset.ts";
import type { PublishAsset, PublishInput } from "./publish.ts";
import { IMPORT_LIBRARY_REL } from "../asset-import/pipeline.ts";

export const BUILD_UNREGISTERED_ASSET = "BUILD.UNREGISTERED_ASSET";
export const BUILD_SCAN_FAILED = "BUILD.SCAN_FAILED";

/** `.meta` 文件不是资产，是资产的说明书 —— 它自己不能被发布。 */
const META_SUFFIX = ".meta";

export interface CollectOptions {
  /** 资产根（scheme 内的绝对路径，如 `/web/assets`）。 */
  readonly root: string;
  /** 入口资产 id。**必须显式给**：从"目录里所有文件"倒推入口，等于没有闭包。 */
  readonly entries: readonly string[];
  /**
   * 要跳过的子目录（相对资产根）。默认跳过导入缓存 `library/imported`。
   * ★ 这不是"容错"：缓存目录里装的是**导入器的输出**，把它当资产发布出去，
   *   产物就会随"这次有没有命中缓存"变化 —— 而可复现构建正是发布的前提。
   */
  readonly skipDirs?: readonly string[];
}

/** 递归列出目录下的所有**文件**（不含目录本身），顺序确定（按路径升序）。 */
async function walk(fs: IReadableFileSystem, dir: string, out: string[]): Promise<Result<void, EngineError>> {
  const listed = await fs.list(dir);
  if (!listed.ok) return listed;
  for (const e of listed.value) {
    if (e.isDirectory) {
      const r = await walk(fs, e.path, out);
      if (!r.ok) return r;
    } else {
      out.push(e.path);
    }
  }
  out.sort();
  return ok(undefined);
}

/**
 * 扫描资产根，产出 `PublishInput`。
 *
 * @throws 不抛 —— 一切失败都走 `Result`（调用方是构建脚本，需要区分"配置错"与"IO 错"）。
 */
export async function collectPublishInput(
  fs: IReadableFileSystem,
  db: AssetDatabase,
  options: CollectOptions,
): Promise<Result<PublishInput, EngineError>> {
  if (!fs.scheme) {
    return err(engineError(BUILD_SCAN_FAILED, "文件系统没有 scheme —— 路径归属不明"));
  }
  const skip = (options.skipDirs ?? [IMPORT_LIBRARY_REL]).map((d) => `${options.root.replace(/\/+$/, "")}/${d.replace(/^\/+|\/+$/g, "")}/`);
  const paths: string[] = [];
  const walked = await walk(fs, options.root, paths);
  if (!walked.ok) return walked;

  const assets: PublishAsset[] = [];
  const dependencies = new Map<string, readonly string[]>();
  for (const path of paths) {
    if (path.endsWith(META_SUFFIX)) continue;
    if (skip.some((s) => path.startsWith(s))) continue;
    const id = db.idAtPath(path);
    if (id === undefined) {
      // ★ 不跳过：跳过 = "这个文件不是资产"与"这个文件本该是资产但没进管线"两种情况混在一起
      return err(
        engineError(BUILD_UNREGISTERED_ASSET, `${path} 没有资产 id —— 它没进导入管线（未知扩展名？或是构建前忘了跑导入）`, {
          path,
        }),
      );
    }
    const read = await fs.readBinary(path);
    if (!read.ok) return read;
    const meta = db.meta(id);
    assets.push({ id, path, bytes: read.value });
    dependencies.set(id, meta?.dependencies ?? []);
  }

  return ok({ entries: options.entries, assets, dependencies });
}

/** 从注册表里挑出"没人依赖"的资产 id（构建脚本给 `--entry auto` 时用）。 */
export function rootAssetIds(db: AssetDatabase, ids: readonly AssetId[]): readonly AssetId[] {
  const depended = new Set<string>();
  for (const id of ids) for (const d of db.dependencies(id)) depended.add(d);
  return ids.filter((id) => !depended.has(id)).sort();
}
