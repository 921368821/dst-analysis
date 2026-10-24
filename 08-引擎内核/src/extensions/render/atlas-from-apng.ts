/**
 * L4 · 渲染 · APNG 帧 → 一张 sprite sheet
 *
 * ★ 为什么需要这一步（否则 APNG 支持就是"解出来放着"）：
 *   `decodeApng` 产出的是 N 张整幅画布，但引擎的纹理上传路径只有
 *   `createTexture(desc, rgba8)` —— 一帧一张纹理会变成 N 次上传 + N 个句柄，
 *   而且 `RenderModule` 的精灵只认图集里的帧矩形。
 *   把帧拼成一张图集，动图就退化成"按帧矩形切换 UV"，**不需要改渲染模块**。
 *
 * ★ 为什么帧名用零填充的序号（`0000`/`0001`…）而不是 `frame-1`：
 *   图集打包的排序规则是"高度降序 → 名字升序"。零填充让字典序等于播放序，
 *   于是"图集里第几块"与"第几帧"一致，播放端按下标取帧就是对的。
 *   不填充的话 `frame-10` 会排在 `frame-2` 前面，播放顺序静默错乱。
 *
 * ★ 边界：拼图只回答"每一帧长什么样"，不回答"现在该显示第几帧"。
 *   时间轴在 `animation.ts`（不可变 clip + 纯采样）与 `sprite-animator.ts`
 *   （每实体一个 `timeMs`）里，本文件**不持有任何计时状态**。
 *   这不是洁癖：图集/素材会被多个世界共享，把播放进度放进共享数据里，
 *   等于让两个世界共用一个时钟 —— A 世界暂停，B 世界的同一段动作也会停。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import type { ApngFrame } from "../asset-import/decode/apng.ts";
import type { AtlasData } from "./atlas.ts";
import type { AtlasBuildOptions, AtlasSource } from "./atlas-from-assets.ts";
import { buildAtlasFromSources } from "./atlas-from-assets.ts";

export interface ApngAtlasResult {
  readonly atlas: AtlasData;
  /** 帧名（与 `atlas.frames` 的键一致），按播放顺序排列。 */
  readonly frameNames: readonly string[];
  /** 每帧显示时长（毫秒），与 `frameNames` 同序。 */
  readonly frameDurationsMs: readonly number[];
  /** 一轮总时长（毫秒）。 */
  readonly totalDurationMs: number;
  /** acTL.num_plays；0 = 无限循环。 */
  readonly loopCount: number;
}

function frameName(i: number, total: number): string {
  // 宽度随总帧数自适应：10 帧用 2 位，1000 帧用 4 位，保证字典序 == 播放序
  const width = String(Math.max(0, total - 1)).length;
  return String(i).padStart(width, "0");
}

/**
 * 把 APNG 的每一帧拼成一张图集。
 *
 * 帧的 `rect`（在画布上的位置）**被丢弃**：`decodeApng` 返回的是"合成后的整幅画布"，
 * 已经包含位移，再保留 rect 会把偏移算两次。
 */
export function buildAtlasFromApng(
  frames: readonly ApngFrame[],
  width: number,
  height: number,
  loopCount: number,
  opts?: AtlasBuildOptions,
): Result<ApngAtlasResult, EngineError> {
  if (frames.length === 0) {
    return err(engineError("ATLAS.EMPTY_APNG", "APNG 没有任何帧，无法拼图集"));
  }

  const sources: AtlasSource[] = frames.map((f, i) => ({
    name: frameName(i, frames.length),
    png: {
      width,
      height,
      pixels: f.pixels,
      bitDepth: 8,
      colorType: 6,
      hasAlpha: true,
      usedTransparencyKey: false,
      interlaced: false,
      // 图集里的一帧是"合成后的静态图"，不是动图本身
      isApng: false,
    },
  }));

  const built = buildAtlasFromSources(sources, opts);
  if (!built.ok) return err(built.error);

  const frameNames = sources.map((s) => s.name);
  const frameDurationsMs = frames.map((f) => f.delayMs);
  return ok({
    atlas: built.value,
    frameNames,
    frameDurationsMs,
    totalDurationMs: frameDurationsMs.reduce((a, b) => a + b, 0),
    loopCount,
  });
}

/**
 * 便捷入口：把这个结果直接变成时间轴 clip（`atlas` 会被忽略）。
 * ★ 只是 re-export，不改 `buildAtlasFromApng` 的签名 —— 现有调用方与判据不变。
 */
export { clipFromApngResult } from "./animation.ts";
