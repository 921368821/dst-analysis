/**
 * L4 · 渲染 · 从导入产物合成图集
 *
 * ★★ 补的是哪条断链：
 *   `AssetImportPipeline` 把 PNG 导成 `library/imported/<id>.json`（元数据 + 字节），
 *   但浏览器/headless 画面一直用 `buildProceduralAtlas()` 的**程序化假贴图** ——
 *   两条链各自全绿，却没有一根线把它们接起来。
 *   本文件就是那根线：**已解码的 PNG → 一张真正的 `AtlasData`**，
 *   然后原样交给 `createRenderModule({ atlas })`。
 *
 * ★ 为什么坚持**确定性**（同输入逐字节同输出）：
 *   图集是构建产物。如果同一批图在两台机器/两次构建里排布不同，
 *   产物哈希就会变，增量构建失效、golden image 判据随机红。
 *   所以这里不做旋转、不做裁剪、不做去重（这些都会引入"选择"），
 *   排序只用 (高度降序, 名字升序)，名字比较用 `<` 而**不是** `localeCompare`
 *   —— 后者依赖 ICU/locale，在 CI 与开发机上可能给出不同顺序。
 *
 * ★ 空白填**全透明 (0,0,0,0)**，不是黑色：
 *   图集会被最近邻/线性采样，超出帧的采样若取到黑边，会变成"精灵边缘一圈黑"。
 *   全透明至少在线性过滤下不会污染颜色（虽然本工程用 Nearest）。
 */

import type { EngineError, Result } from "../../foundation/result.ts";
import { engineError, err, ok } from "../../foundation/result.ts";
import { PixelFormat } from "../../platform/gfx/types.ts";
import type { AtlasData, AtlasFrame } from "./atlas.ts";
import type { DecodedPng } from "../asset-import/decode/png.ts";

export interface AtlasBuildOptions {
  /** 图集内边距（像素），避免相邻帧采样串色。默认 1。 */
  readonly padding?: number;
  /** 超过这个尺寸就报错（防 2048×2048 拼成 8192×8192 直接 OOM）。默认 2048。 */
  readonly maxSize?: number;
  /**
   * 图集的像素精度。
   *   · `"auto"`（默认）：**只要有一个源带 `pixels16`，整张图集就是 16 位**；
   *   · `8`：显式降采样（16 位源按 `round(v/257)`，与 `png.ts` 同口径）；
   *   · `16`：全部上转（8 位源按 `v*257`，0..255 → 0..65535 均匀且无损）。
   *
   * ★ 为什么"一个 16 位源就把整张图集拉成 16 位"而不是逐帧各自保留：
   *   一张纹理只有**一个**格式。混精度图集必然要在某处重采样一次；
   *   在合成期显式做（并把 8 位源无损上转）比"按 rgba8 上传、靠肉眼看不出"要诚实。
   *   代价是 8 位源也占 8 字节/像素 —— 要省显存请显式传 `precision: 8`。
   */
  readonly precision?: "auto" | 8 | 16;
}

export interface AtlasSource {
  /** 帧名。 */
  readonly name: string;
  /** 已解码。 */
  readonly png: DecodedPng;
}

const DEFAULT_PADDING = 1;
const DEFAULT_MAX_SIZE = 2048;

function errAtlas(code: string, message: string, detail?: Record<string, unknown>): EngineError {
  return detail === undefined ? engineError(code, message) : engineError(code, message, detail);
}

/** 名字升序（`<` 比较，不依赖 locale）。 */
function byName(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}

function nextPowerOfTwo(n: number): number {
  if (n <= 1) return 1;
  let p = 1;
  while (p < n) p *= 2;
  return p;
}

interface Placement {
  readonly name: string;
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

/**
 * 确定性 shelf packing：
 *   1. 高度降序 → 名字升序（结果与输入顺序无关）；
 *   2. 从左到右摆，放不下换行；行高 = 该行最高；
 *   3. 帧与帧之间留 `padding` 像素（**只留帧间，不留外边距** ——
 *      单帧图集才能是"整图 UV 0,0,1,1"，否则单帧会莫名其妙缩在中间）；
 *   4. 宽高向上取整到 2 的幂（GPU 友好，且 mipmap 不会因非 2 次幂退化）。
 */
export function buildAtlasFromSources(
  sources: readonly AtlasSource[],
  opts?: AtlasBuildOptions,
): Result<AtlasData, EngineError> {
  const padding = opts?.padding ?? DEFAULT_PADDING;
  const maxSize = opts?.maxSize ?? DEFAULT_MAX_SIZE;
  const precision = opts?.precision ?? "auto";
  if (!Number.isInteger(padding) || padding < 0) {
    return err(errAtlas("ASSET.BAD_ATLAS_OPTIONS", `padding 必须是非负整数，收到 ${padding}`));
  }
  if (!Number.isInteger(maxSize) || maxSize < 1) {
    return err(errAtlas("ASSET.BAD_ATLAS_OPTIONS", `maxSize 必须是 ≥1 的整数，收到 ${maxSize}`));
  }
  if (precision !== "auto" && precision !== 8 && precision !== 16) {
    // 静默当成 auto 会让"我明明传了 precision:12"变成"跑出来是 8 位"，而且没人报错
    return err(
      errAtlas(
        "ASSET.BAD_ATLAS_OPTIONS",
        `precision 只能是 "auto" | 8 | 16，收到 ${JSON.stringify(precision)}`,
      ),
    );
  }

  const seen = new Set<string>();
  for (const s of sources) {
    if (seen.has(s.name)) {
      // 帧名是 Map 的键：重名会让"后一个静默覆盖前一个"，而排序后谁在后面又依赖尺寸
      return err(
        errAtlas("ASSET.ATLAS_DUPLICATE_FRAME", `帧名重复："${s.name}"（图集帧名必须唯一）`, { name: s.name }),
      );
    }
    seen.add(s.name);
  }

  // ---- 精度决策（必须在拼像素之前定：它决定分配哪种缓冲） ----
  const use16 = precision === 16 || (precision === "auto" && sources.some((s) => s.png.pixels16 !== undefined));

  // ---- 排序（拷贝，不改调用方数组） ----
  const ordered = [...sources].sort((a, b) => {
    const dh = b.png.height - a.png.height;
    return dh !== 0 ? dh : byName(a.name, b.name);
  });

  // ---- 单帧本身超限：先报，避免后面算出无意义的布局 ----
  for (const s of ordered) {
    if (s.png.width > maxSize || s.png.height > maxSize) {
      return err(
        errAtlas(
          "ASSET.ATLAS_TOO_LARGE",
          `帧 "${s.name}" 是 ${s.png.width}×${s.png.height}，单帧就超过 maxSize=${maxSize}`,
          { frame: s.name, width: s.png.width, height: s.png.height, maxSize },
        ),
      );
    }
  }

  // ---- shelf packing ----
  const placements: Placement[] = [];
  let x = 0;
  let y = 0;
  let rowH = 0;
  let neededW = 0;
  let neededH = 0;
  let widestBy = "";
  let tallestBy = "";

  for (const s of ordered) {
    const w = s.png.width;
    const h = s.png.height;
    if (x > 0 && x + w > maxSize) {
      // 换行：下一行的起点 = 本行最高的那帧 + padding
      y += rowH + padding;
      x = 0;
      rowH = 0;
    }
    placements.push({ name: s.name, x, y, w, h });
    x += w + padding;
    if (h > rowH) rowH = h;
    if (x - padding > neededW) {
      neededW = x - padding;
      widestBy = s.name;
    }
    if (y + rowH > neededH) {
      neededH = y + rowH;
      tallestBy = s.name;
    }
  }

  if (ordered.length === 0) {
    // 空输入：给 1×1 全透明 + 空帧表。不报错 —— "还没导入任何图"不是错误，
    // 渲染模块拿到它只会画不出东西，而不会崩。
    // 精度仍然跟着请求走（precision:16 就返回 rgba16 的 1×1），否则"空图集"会是
    // 唯一一个不遵守 precision 的返回值。
    return ok(
      use16
        ? {
            width: 1,
            height: 1,
            pixels: new Uint8Array(4),
            format: PixelFormat.RGBA16,
            pixels16: new Uint16Array(4),
            frames: new Map<string, AtlasFrame>(),
          }
        : { width: 1, height: 1, pixels: new Uint8Array(4), frames: new Map<string, AtlasFrame>() },
    );
  }
  if (neededW > maxSize) {
    return err(
      errAtlas(
        "ASSET.ATLAS_TOO_LARGE",
        `图集宽度 ${neededW} 超过 maxSize=${maxSize}（最后一帧撑宽的是 "${widestBy}"）`,
        { frame: widestBy, neededWidth: neededW, maxSize },
      ),
    );
  }
  if (neededH > maxSize) {
    return err(
      errAtlas(
        "ASSET.ATLAS_TOO_LARGE",
        `图集高度 ${neededH} 超过 maxSize=${maxSize}（撑高的是 "${tallestBy}"）`,
        { frame: tallestBy, neededHeight: neededH, maxSize },
      ),
    );
  }

  const width = nextPowerOfTwo(neededW);
  const height = nextPowerOfTwo(neededH);
  if (width > maxSize || height > maxSize) {
    return err(
      errAtlas(
        "ASSET.ATLAS_TOO_LARGE",
        `向上取整到 2 的幂后尺寸 ${width}×${height} 超过 maxSize=${maxSize}`,
        { width, height, maxSize },
      ),
    );
  }

  // ---- 拼像素（空白保持 0,0,0,0：16 位图集里就是 0，仍是全透明） ----
  const pixels = new Uint8Array(width * height * 4);
  const pixels16 = use16 ? new Uint16Array(width * height * 4) : undefined;
  const byNameSource = new Map<string, DecodedPng>();
  for (const s of sources) byNameSource.set(s.name, s.png);

  for (const p of placements) {
    const src = byNameSource.get(p.name)!;
    for (let row = 0; row < p.h; row++) {
      const from = row * p.w * 4;
      const to = ((p.y + row) * width + p.x) * 4;
      if (pixels16 !== undefined) {
        if (src.pixels16 !== undefined) {
          pixels16.set(src.pixels16.subarray(from, from + p.w * 4), to);
        } else {
          // 8 位源上转：`v*257` 把 0..255 均匀铺到 0..65535，
          // 且 `round(v*257/257) === v` —— 所以"上转"对 8 位源是**无损**的，
          // 图集变 16 位不会让 8 位素材出现任何偏差。
          for (let i = 0; i < p.w * 4; i++) pixels16[to + i] = src.pixels[from + i]! * 257;
        }
      } else if (src.pixels16 !== undefined) {
        // precision: 8 的显式降采样，口径与 `png.ts` / pngjs 相同：`round(v/257)`。
        // ★ 刻意从 `pixels16` 重算，而不是复制 `src.pixels`：后者是解码器"顺手给出"的
        //   8 位视图，复制它等于把降采样决策偷偷留在解码器里 —— 那正是本任务要拆掉的东西。
        for (let i = 0; i < p.w * 4; i++) pixels[to + i] = Math.round(src.pixels16[from + i]! / 257);
      } else {
        pixels.set(src.pixels.subarray(from, from + p.w * 4), to);
      }
    }
  }

  if (pixels16 !== undefined) {
    // 由 16 位**派生** 8 位视图（不是各拼一份）：这样 `pixels[i] === round(pixels16[i]/257)`
    // 是构造出来的性质，而不是靠两条代码路径"碰巧一致"。padding 的 0 也满足。
    for (let i = 0; i < pixels.length; i++) pixels[i] = Math.round(pixels16[i]! / 257);
  }

  // ---- UV 按最终图集尺寸归一化 ----
  const frames = new Map<string, AtlasFrame>();
  for (const p of placements) {
    frames.set(p.name, {
      u0: p.x / width,
      v0: p.y / height,
      u1: (p.x + p.w) / width,
      v1: (p.y + p.h) / height,
      w: p.w,
      h: p.h,
    });
  }

  return ok(
    pixels16 === undefined
      ? { width, height, pixels, frames }
      : // 16 位时**同时**给 8 位视图（见 atlas.ts 的不变量说明）
        { width, height, pixels, format: PixelFormat.RGBA16, pixels16, frames },
  );
}

// ------------------------------------------------------------------ 从导入产物构建

/**
 * `.atlas.json` 里的一帧。**这里比图纸多了一个可选 `texture`**，理由：
 *   当前的 `.atlas.json`（见 importers/atlas.ts）只声明
 *   `textures: ["a.png", ...]` 与 `frames: { name: {x,y,w,h} }`，
 *   **没有**表达"这个帧矩形属于哪张贴图"。产物里更是只存 frameCount 与 texture id。
 *   按原签名 `(frames, textures)` 分开传，多贴图时归属就是不可知的 ——
 *   猜"都来自第一张"会静默切错图。
 *   所以把归属放在帧上（`texture` 按 `AtlasSource.name` 匹配）：
 *     · 单贴图（当前真实语料）可省略，默认取唯一那张；
 *     · 多贴图时必须写明。做不到就报错，而不是猜。
 *
 * ★ 还有一处当前格式的缺口：产物 `library/imported/<id>.json` 的 `data` 只有
 *   `frames` 数量与 `textures` id 列表，**没有帧矩形**。也就是说调用方要拿矩形，
 *   必须回去读 `.atlas.json` 源文件（或把 importer 升版、把矩形落进产物）。
 *   本函数只负责"给定矩形 → 图集"，不替调用方猜产物格式。
 */
export interface ImportedFrameRect {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
  /** 帧来自哪个 `AtlasSource.name`。省略时要求 textures 恰好 1 个。 */
  readonly texture?: string;
}

/**
 * 读图集描述里的帧矩形，把每一帧从对应贴图裁出来，再重新排进一张新图集。
 *
 * ★ 语义是 **"切图 + 重排"**，不是"把原图集当一张大图直接用"：
 *   帧矩形之外的像素（旧图集的空白/其他帧）不应该进入新图集 ——
 *   那会白白浪费显存，也会让"图集尺寸是 2 的幂"这件事失去意义。
 */
export function buildAtlasFromImported(
  frames: ReadonlyMap<string, ImportedFrameRect>,
  textures: readonly AtlasSource[],
  opts?: AtlasBuildOptions,
): Result<AtlasData, EngineError> {
  if (textures.length === 0) {
    return err(errAtlas("ASSET.BAD_ATLAS_FRAME", "没有任何贴图可用于裁剪图集帧"));
  }
  const byName = new Map<string, DecodedPng>();
  for (const t of textures) byName.set(t.name, t.png);

  const cropped: AtlasSource[] = [];
  for (const [name, r] of frames) {
    if (!Number.isInteger(r.x) || !Number.isInteger(r.y) || !Number.isInteger(r.w) || !Number.isInteger(r.h)) {
      return err(
        errAtlas("ASSET.BAD_ATLAS_FRAME", `帧 "${name}" 的 x/y/w/h 必须是整数，收到 ${r.x},${r.y},${r.w},${r.h}`),
      );
    }
    if (r.w <= 0 || r.h <= 0) {
      return err(errAtlas("ASSET.BAD_ATLAS_FRAME", `帧 "${name}" 的宽高必须 > 0，收到 ${r.w}×${r.h}`));
    }
    let sourceName = r.texture;
    if (sourceName === undefined) {
      if (textures.length !== 1) {
        return err(
          errAtlas(
            "ASSET.BAD_ATLAS_FRAME",
            `帧 "${name}" 没有指定 texture，而这里有 ${textures.length} 张贴图 —— 无法判断它属于哪张（不猜）`,
            { frame: name, candidates: textures.map((t) => t.name) },
          ),
        );
      }
      sourceName = textures[0]!.name;
    }
    const png = byName.get(sourceName);
    if (png === undefined) {
      return err(
        errAtlas("ASSET.BAD_ATLAS_FRAME", `帧 "${name}" 引用的贴图 "${sourceName}" 不在 textures 里`, {
          frame: name,
          texture: sourceName,
        }),
      );
    }
    if (r.x < 0 || r.y < 0 || r.x + r.w > png.width || r.y + r.h > png.height) {
      return err(
        errAtlas(
          "ASSET.BAD_ATLAS_FRAME",
          `帧 "${name}" 的矩形 (${r.x},${r.y},${r.w}×${r.h}) 超出贴图 "${sourceName}" 的 ${png.width}×${png.height}`,
          { frame: name, texture: sourceName },
        ),
      );
    }
    cropped.push({ name, png: cropPng(png, r.x, r.y, r.w, r.h) });
  }

  return buildAtlasFromSources(cropped, opts);
}

/**
 * 从一张已解码 PNG 里裁一块（不复制多余字段）。
 *
 * ★ 必须**一起裁 `pixels16`**：否则 16 位源走 `buildAtlasFromImported` 时会静默退回 8 位
 *   （裁剪只带 RGBA8 ⇒ 后续 precision:auto 认不出它是 16 位源）。
 *   这是"链路上某一段悄悄降采样"的典型形态：裁剪、重排看起来都成功，精度没了。
 */
function cropPng(src: DecodedPng, x: number, y: number, w: number, h: number): DecodedPng {
  const pixels = new Uint8Array(w * h * 4);
  const src16 = src.pixels16;
  const pixels16 = src16 === undefined ? undefined : new Uint16Array(w * h * 4);
  for (let row = 0; row < h; row++) {
    const from = ((y + row) * src.width + x) * 4;
    pixels.set(src.pixels.subarray(from, from + w * 4), row * w * 4);
    if (pixels16 !== undefined) pixels16.set(src16!.subarray(from, from + w * 4), row * w * 4);
  }
  return {
    width: w,
    height: h,
    pixels,
    pixels16,
    // bitDepth 描述的是"这份解码结果的精度"（本函数本来就统一报 8，因为输出是 RGBA8）；
    // 带 pixels16 时它就不是 8 位了，继续写 8 会误导下游按 8 位处理。
    bitDepth: pixels16 === undefined ? 8 : 16,
    colorType: 6,
    hasAlpha: true,
    usedTransparencyKey: false,
    // 裁剪改的是像素布局，不改"文件从哪来"：隔行/动图标记照搬，避免裁剪后被误判成普通静态图
    interlaced: src.interlaced,
    isApng: src.isApng,
  };
}
