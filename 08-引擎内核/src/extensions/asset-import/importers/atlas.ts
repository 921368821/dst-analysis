/**
 * L4 · 资产导入 · 图集描述（`.atlas.json`）
 *
 * 图集文件本身**不含像素**，只声明"我用了哪几张图 + 帧矩形"。
 * 因此它是整个导入管线里唯一有依赖的资产类型，也是"两遍扫描"存在的理由：
 *   第一遍必须先把所有 `.meta` 建好（拿到 id 表），第二遍才能把
 *   `"textures": ["grass.png"]` 解析成 AssetId。
 *
 * ★ 依赖**保持声明顺序**，不排序：
 *   加载顺序由声明顺序决定（先声明的先加载），排序会把这份确定性来源丢掉，
 *   而"同一个图集在不同机器上依赖顺序不同"是很难查的 bug。
 *
 * ★ 缺依赖 → `IMPORT.MISSING_DEPENDENCY` 并点名是哪一个：
 *   只说"图集导入失败"的报错，在几百张图的工程里等于没说。
 *
 * ★ 帧矩形在这里只做**结构校验**（x/y/w/h 都是数字），不做越界校验：
 *   越界（帧超出贴图尺寸）需要读贴图 IHDR —— 那是另一个依赖的产物。
 *   把越界检查放在渲染/图集构建阶段，能拿到实际的贴图尺寸再判。
 */

import { AssetType, type AssetId } from "../../../core/asset/asset.ts";
import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err, ok } from "../../../foundation/result.ts";
import type { ImportedArtifact, SourceImporter } from "../importer.ts";
import { contentHash } from "../hash.ts";

const VERSION = 1;

function badSource(sourcePath: string, why: string): EngineError {
  return engineError("IMPORT.BAD_SOURCE", `${sourcePath}: ${why}`, { path: sourcePath, importer: "atlas" });
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

const FRAME_KEYS = ["x", "y", "w", "h"] as const;

export const atlasImporter: SourceImporter = {
  id: AssetType.Atlas,
  version: VERSION,
  extensions: [".atlas.json"],

  async import(sourcePath, source, _settings, ctx): Promise<Result<ImportedArtifact, EngineError>> {
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(source);
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e);
      return err(badSource(sourcePath, `不是合法 UTF-8（${why}）`));
    }

    let raw: unknown;
    try {
      raw = JSON.parse(text) as unknown;
    } catch (e) {
      const why = e instanceof Error ? e.message : String(e);
      return err(badSource(sourcePath, `JSON 解析失败（${why}）`));
    }
    if (!isPlainObject(raw)) {
      return err(badSource(sourcePath, "顶层必须是 JSON 对象"));
    }

    // ---- textures：声明顺序 = 依赖顺序 ----
    const texturesRaw = raw["textures"];
    if (!Array.isArray(texturesRaw)) {
      return err(badSource(sourcePath, "缺少 \"textures\" 数组"));
    }
    const dependencies: AssetId[] = [];
    for (const [i, tex] of texturesRaw.entries()) {
      if (typeof tex !== "string" || tex.length === 0) {
        return err(badSource(sourcePath, `textures[${i}] 必须是非空字符串`));
      }
      const id = ctx.lookupId(tex);
      if (id === undefined) {
        const resolved = ctx.resolveSibling(tex);
        return err(
          engineError(
            "IMPORT.MISSING_DEPENDENCY",
            `${sourcePath}: 依赖 "${tex}" 找不到（相对当前文件解析为 ${resolved}；本轮扫描里没有这个资产）`,
            { source: sourcePath, dependency: tex, resolved },
          ),
        );
      }
      dependencies.push(id);
    }

    // ---- frames：只校验形状 ----
    const framesRaw = raw["frames"];
    if (!isPlainObject(framesRaw)) {
      return err(badSource(sourcePath, "缺少 \"frames\" 对象"));
    }
    for (const [name, frame] of Object.entries(framesRaw)) {
      if (!isPlainObject(frame)) {
        return err(badSource(sourcePath, `帧 "${name}" 必须是对象`));
      }
      for (const k of FRAME_KEYS) {
        const v = frame[k];
        if (typeof v !== "number" || !Number.isFinite(v)) {
          return err(badSource(sourcePath, `帧 "${name}" 的 ${k} 必须是有限数字`));
        }
      }
    }

    return ok({
      type: AssetType.Atlas,
      dependencies,
      byteLength: source.byteLength,
      sourceHash: contentHash(source),
      importerVersion: VERSION,
      data: {
        frames: Object.keys(framesRaw).length,
        textures: dependencies,
      },
    });
  },
};
