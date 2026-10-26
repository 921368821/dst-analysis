/**
 * L4 · 编辑器：从真实图片烘一张图集（批87）
 *
 * 批86 把资产摆上了面板，但只接了半条链：图集是 `buildProceduralAtlas()` 生成的
 * 6 帧假贴图，而 `web/assets` 有 10 张真位图 ⇒ 面板里大半资产「无帧」，点了加不进场景。
 * 这一层补的就是那一半：**已读到的图片字节 → 一张真正能渲染的图集**。
 *
 * ★ 三条边界，每条都对应一个会静默出错的做法：
 *
 * ① **一个坏文件不许炸整锅。**
 *    `decodeImage` 返回 `Result`，而"顺手 `unwrap`"会让一张坏的 png 让整个编辑器开不起来 ——
 *    人看到的只是白屏。所以逐张解、坏的记进 `skipped`、其余照烘。
 *    只有**一张都没解出来**才是错误（`EDIT.BAKE_EMPTY`），因为那时调用方需要回落
 *    到程序化图集并留痕，而不是拿到一张 0 帧的空图集去渲染。
 *
 * ② **帧名重复不许静默覆盖。**
 *    帧名是 `Map` 的键。`berry.png` 与 `sub/berry.png` 同时烘进来，后者会静默盖掉前者
 *    （`buildAtlasFromSources` 那边会报 `ASSET.ATLAS_DUPLICATE_FRAME`，但那时已经
 *    换了一批图进去）。这里先按"先到的赢"挡住，并把后来的记进 `skipped`，
 *    于是"为什么我的图没上"有答案。
 *
 * ③ **不在这里做贴图质量决策。**
 *    padding / maxSize / 精度全部原样转给 `buildAtlasFromSources` —— 那一层的默认值
 *    与判据都在（确定性排序、透明填边、16 位口径）。在这里另设一套默认值，
 *    等于把它们悄悄改掉。
 *
 * ★ 为什么这一层**不碰文件系统**：它只吃"名字 + 字节"，于是 Node 判据可以拿
 *   `web/assets` 的**真实字节**跑（`fs.readFileSync`），浏览器侧则自己用
 *   `HttpFileSystem` 读。两侧共用同一条合成规则，差异只剩在"字节从哪来"。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import type { AtlasData } from "../render/atlas.ts";
import {
  buildAtlasFromSources,
  type AtlasBuildOptions,
  type AtlasSource,
} from "../render/atlas-from-assets.ts";
import { decodeImage } from "../asset-import/decode/image.ts";

/** 一张都没解出来 —— 调用方应当回落到程序化图集，并把这件事显示出来。 */
export const EDIT_BAKE_EMPTY = "EDIT.BAKE_EMPTY";

export interface BakeImage {
  /** 帧名（`tree.png` → `tree`）。 */
  readonly name: string;
  readonly bytes: Uint8Array;
}

/** 没烘进图集的图，以及**为什么**。空着不记的后果是"我的图没上"没有答案。 */
export interface BakeSkip {
  readonly name: string;
  readonly reason: string;
}

export interface BakeReport {
  readonly atlas: AtlasData;
  /** 烘进图集的帧名，**升序**（确定性；判据与面板都按它）。 */
  readonly frames: readonly string[];
  readonly skipped: readonly BakeSkip[];
}

/**
 * 把一批图片字节烘成一张图集。
 *
 * 失败面只有两个：一张都没解出来（`EDIT_BAKE_EMPTY`），以及 `buildAtlasFromSources`
 * 自己的错误（太大 / 选项非法 / 帧名重复）。其余一律走 `skipped`。
 */
export function bakeAtlasFromImages(
  images: readonly BakeImage[],
  opts: AtlasBuildOptions = {},
): Result<BakeReport, EngineError> {
  const skipped: BakeSkip[] = [];
  const sources: AtlasSource[] = [];
  const seen = new Set<string>();

  for (const img of images) {
    const name = img.name.trim();
    if (name === "") {
      skipped.push({ name: img.name, reason: "EDIT.EMPTY_NAME" });
      continue;
    }
    if (seen.has(name)) {
      // ② 先到的赢：已经用过这个名字的图，后来的不再覆盖。
      skipped.push({ name, reason: "EDIT.DUPLICATE_NAME" });
      continue;
    }
    const dec = decodeImage(img.bytes);
    if (!dec.ok) {
      // ① 解不开只记账：一张坏图不该让编辑器开不起来。
      skipped.push({ name, reason: dec.error.code });
      continue;
    }
    seen.add(name);
    sources.push({ name, png: dec.value });
  }

  if (sources.length === 0) {
    return err(
      engineError(
        EDIT_BAKE_EMPTY,
        `一张图都没解出来（试了 ${String(images.length)} 张，失败 ${String(skipped.length)} 张）`
          + (skipped.length > 0 ? `：${skipped[0]?.name ?? ""} ${skipped[0]?.reason ?? ""}` : ""),
      ),
    );
  }

  const built = buildAtlasFromSources(sources, opts);
  if (!built.ok) return built;

  return ok({
    atlas: built.value,
    // 排序用 `<` 而不是 `localeCompare`：后者依赖 locale，CI 与开发机可能给出不同顺序。
    frames: Array.from(built.value.frames.keys()).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)),
    skipped,
  });
}
