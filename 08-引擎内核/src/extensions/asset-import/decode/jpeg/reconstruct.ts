/**
 * L4 · JPEG 解码 · 重建（反量化 → IDCT → 上采样 → 颜色 → RGBA）
 *
 * ★ IDCT 用浮点 + 分离的一维变换（行再列），不做整数近似：
 *   整数 IDCT 是给"解码速度"用的，代价是与金标的差异变成"实现细节"而不可解释。
 *   我们已经有容差判据，要的是"差异能被解释"，不是"每次少算几个周期"。
 *
 * ★ 分量平面恒为 `Uint16Array`（值域 0..2^P-1，P=8/12/16）。
 *   8 位图在这里多花一倍内存，换的是"8 位与 12 位走同一份 IDCT / 上采样 / 颜色变换"。
 *   如果给 8 位单开一条路径，12 位那条路上的错就永远只有 12 位的判据能测 ——
 *   而 12 位没有第三方解码器可对照（Pillow 只编译了 8 位）。
 */

import type { Component, Frame } from "./frame.ts";
import { COS } from "./tables.ts";
import type { DecodedJpeg, DecodeJpegOptions } from "./types.ts";
import { fail } from "./types.ts";

export function clampSample(v: number, maxval: number): number {
  return v < 0 ? 0 : v > maxval ? maxval : v;
}

/** 位深 → 满量程（8→255 / 12→4095 / 16→65535）。 */
export function maxValueOf(precision: number): number {
  return (1 << precision) - 1;
}

/**
 * 反量化 + 8×8 IDCT，写进分量平面（自动裁掉超出 compW/compH 的右/下边界）。
 *
 * 电平位移量是 `2^(P-1)`（8 位→128，12 位→2048）：JPEG 的样本以 0 为中心，
 * 常数必须随精度一起变，写死 128 会让 12 位图整体压到最暗的 1/16。
 */
function idctBlock(
  coefs: Int16Array,
  bo: number,
  qt: Uint16Array,
  plane: Uint16Array,
  planeW: number,
  planeH: number,
  originX: number,
  originY: number,
  offset: number,
  maxval: number,
): void {
  const block = new Float64Array(64);
  for (let i = 0; i < 64; i++) block[i] = coefs[bo + i]! * qt[i]!;

  const tmp = new Float64Array(64);
  for (let y = 0; y < 8; y++) {
    const o = y * 8;
    for (let x = 0; x < 8; x++) {
      let s = 0;
      for (let u = 0; u < 8; u++) s += block[o + u]! * COS[u * 8 + x]!;
      tmp[o + x] = s;
    }
  }
  for (let y = 0; y < 8; y++) {
    const py = originY + y;
    if (py >= planeH) break;
    for (let x = 0; x < 8; x++) {
      const px = originX + x;
      if (px >= planeW) continue;
      let s = 0;
      for (let v = 0; v < 8; v++) s += tmp[v * 8 + x]! * COS[v * 8 + y]!;
      plane[py * planeW + px] = clampSample(Math.round(s + offset), maxval);
    }
  }
}

export function buildPlane(c: Component, qt: Uint16Array, precision: number): Uint16Array {
  const offset = 1 << (precision - 1);
  const maxval = maxValueOf(precision);
  const plane = new Uint16Array(c.compW * c.compH);
  for (let by = 0; by < c.blocksH; by++) {
    for (let bx = 0; bx < c.blocksW; bx++) {
      const bo = (by * c.strideBlocksW + bx) * 64;
      idctBlock(c.coefs, bo, qt, plane, c.compW, c.compH, bx * 8, by * 8, offset, maxval);
    }
  }
  return plane;
}

/**
 * DCT 类帧：把系数重建成分量平面。
 *
 * 无损帧的平面在熵解码阶段就已经写好（`scan-lossless.ts` 直接写 plane），
 * 这里只是跳过 —— 两条路径的产物是同一个字段，下游不必知道帧是哪一类。
 */
export function buildFramePlanes(frame: Frame): void {
  if (frame.lossless) {
    // ★ 无损帧的平面里存的是**点变换后**的样本（预测/重建都在 Pt 之后的域里做）：
    //   预测器 P5/P6/P7 含向下取整的除法，先还原再预测与先预测再还原**不相等**
    //   （Pt=1 时 (1>>1)=0 但 (1<<1)>>1=1）。所以这里统一左移回来，只做一次。
    if (frame.pt > 0) {
      for (const c of frame.components) {
        const p = c.plane!;
        for (let i = 0; i < p.length; i++) p[i] = p[i]! << frame.pt;
      }
    }
    return;
  }
  for (const c of frame.components) {
    const q = c.qtTable ?? frame.qt[c.tq] ?? null;
    if (q === null) {
      fail("ASSET.BAD_JPEG", `分量 ${c.id} 引用的量化表 ${c.tq} 没有在文件里定义（DQT 缺失）`);
    }
    c.plane = buildPlane(c, q, frame.precision);
  }
}

/**
 * 三角（1/4, 3/4）上采样：与 libjpeg 的 h2v1/h2v2 "fancy upsampling" 同族。
 *
 * ★ 为什么不是最近邻：色度是 2×2 降采样的，最近邻会在色块边界留下硬台阶，
 *   而 libjpeg（以及所有主流解码器）默认用三角滤波。用最近邻的图与金标差得很远，
 *   于是"差异"里混进了"滤波器选择"，真正该被发现的错位反而看不出来。
 *   非 2 倍因子（4:1:1 的 h=4）libjpeg 也是复制而非插值，这里保持一致。
 *
 * ★ 为什么某一轴只有 1~2 个样本时要退回复制（不是"优化"，是 libjpeg 的行为）：
 *   libjpeg 的 `jinit_upsampler` 只在 `downsampled_width > 2` 时才启用 fancy，
 *   否则走 `h2v1_upsample` / `h2v2_upsample` —— 也就是**复制**。
 *   这条分支只在"图宽 3~4 像素"（色度 2 个样本）这种极端尺寸下可见，
 *   而它的差异可以大到 40 级：三角滤波把最后一个色度样本和它的左邻混在一起，
 *   复制则原样铺开。窄图不是常见素材，但"和 libjpeg 一致"这句话要么成立要么不成立。
 *   n 用的是**真实降采样宽高**（`compW/compH` = ceil(宽×h/maxH)），不是补块后的 8 的倍数。
 */
export function sampleComponent(
  plane: Uint16Array,
  w: number,
  h: number,
  factorH: number,
  factorV: number,
  x: number,
  y: number,
): number {
  const axis = (pos: number, factor: number, n: number, fancy: boolean): [number, number, number, number] => {
    if (factor === 1) {
      const p = pos < n ? pos : n - 1;
      return [p, p, 0, 1];
    }
    if (factor === 2) {
      if (!fancy) {
        const p = pos >> 1 < n ? pos >> 1 : n - 1;
        return [p, p, 0, 1];
      }
      const i = pos >> 1;
      if (i >= n) return [n - 1, n - 1, 0, 1];
      if ((pos & 1) === 1) {
        const j = i + 1 < n ? i + 1 : i;
        return [i, j, 0.75, 0.25];
      }
      const j = i - 1 >= 0 ? i - 1 : i;
      return [j, i, 0.25, 0.75];
    }
    const p = Math.floor(pos / factor);
    const q = p < n ? p : n - 1;
    return [q, q, 0, 1];
  };
  // libjpeg 的 fancy 开关是**按分量**定的，不是按轴：
  //   h2v1（只看宽）/ h1v2（只看高）/ h2v2（只看宽！高再小也照样 fancy）。
  // 所以 4:2:0 的图宽 >2 而高 =2 时，纵向仍然走三角而不是复制——
  // 这一条是靠 97×3 的格点抓到的：一开始两轴都按"样本 ≤2 就复制"处理，
  // 结果 3×97 修好了、97×3 立刻从差 2 变成差 30。
  const fancyH = factorH === 2 && w > 2;
  const fancyV = factorV === 2 && (factorH === 2 ? w > 2 : h > 2);
  const [x0, x1, wx0, wx1] = axis(x, factorH, w, fancyH);
  const [y0, y1, wy0, wy1] = axis(y, factorV, h, fancyV);
  const a = plane[y0 * w + x0]!;
  const b = plane[y0 * w + x1]!;
  const c = plane[y1 * w + x0]!;
  const d = plane[y1 * w + x1]!;
  const top = a * wx0 + b * wx1;
  const bottom = c * wx0 + d * wx1;
  return top * wy0 + bottom * wy1;
}

/**
 * 采样比例名（"4:2:0" 这一族）。
 *
 * ★ 单分量返回 `"none"` 而不是 `"4:4:4"`：
 *   `4:x:y` 的记法描述的是**亮度与两个色度**的比例，灰度图没有色度，
 *   给它安一个 `4:4:4` 会让调用方以为"这张灰度图有三个分量"。
 *   四分量（CMYK/YCCK）沿用同一记法，表示四个平面都按该比例采样。
 */
export function subsamplingName(c0: Component, maxH: number, maxV: number, components: number): string {
  if (components === 1) return "none";
  const hs = c0.h;
  const vs = c0.v;
  if (hs === maxH && vs === maxV) {
    if (maxH === 1 && maxV === 1) return "4:4:4";
    if (maxH === 2 && maxV === 1) return "4:2:2";
    if (maxH === 2 && maxV === 2) return "4:2:0";
    if (maxH === 4 && maxV === 1) return "4:1:1";
    if (maxH === 4 && maxV === 2) return "4:1:0";
    if (maxH === 1 && maxV === 2) return "4:4:0";
    return `${maxH}x${maxV}`;
  }
  return `${hs}x${vs}/${maxH}x${maxV}`;
}

/**
 * EXIF Orientation 应用（像素级旋转/镜像）。
 *
 * ★ 用泛型而不是写两份：8 位与 16 位输出必须**逐元素用同一个映射**，
 *   否则"orientation=6 的 12 位图比 8 位图偏一列"这种错只有在对比时才看得见。
 */
export function applyOrientation<T extends Uint8Array | Uint16Array>(
  src: T,
  w: number,
  h: number,
  orientation: number,
): { data: T; width: number; height: number } {
  if (orientation <= 1 || orientation > 8) return { data: src, width: w, height: h };
  const swap = orientation >= 5;
  const outW = swap ? h : w;
  const outH = swap ? w : h;
  const Ctor = src.constructor as new (n: number) => T;
  const out = new Ctor(outW * outH * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let ox = x;
      let oy = y;
      switch (orientation) {
        case 2: // 水平镜像
          ox = w - 1 - x;
          break;
        case 3: // 180°
          ox = w - 1 - x;
          oy = h - 1 - y;
          break;
        case 4: // 垂直镜像
          oy = h - 1 - y;
          break;
        case 5: // 转置
          ox = y;
          oy = x;
          break;
        case 6: // 顺时针 90°
          ox = h - 1 - y;
          oy = x;
          break;
        case 7: // 反转置
          ox = h - 1 - y;
          oy = w - 1 - x;
          break;
        case 8: // 逆时针 90°
          ox = y;
          oy = w - 1 - x;
          break;
        default:
          break;
      }
      const s = (y * w + x) * 4;
      const d = (oy * outW + ox) * 4;
      out[d] = src[s]!;
      out[d + 1] = src[s + 1]!;
      out[d + 2] = src[s + 2]!;
      out[d + 3] = src[s + 3]!;
    }
  }
  return { data: out, width: outW, height: outH };
}

export interface RgbaResult {
  readonly pixels: Uint8Array;
  readonly pixels16?: Uint16Array;
  readonly width: number;
  readonly height: number;
}

/**
 * 分量平面 → RGBA。
 *
 * ★ 输出契约（与 PNG 完全一致，这样下游不必区分格式）：
 *   `pixels16` 是把样本映射到**满 16 位量程**（`round(v * 65535 / maxval)`），
 *   `pixels` 恒为 `round(pixels16 / 257)`。8 位源因此有 `v*257`，与原路径逐字节相同。
 *
 * ★ 12 位的 8 位输出**不是"偷偷降采样"**：全精度像素在 `pixels16` 里，
 *   调用方要 12 位精度就传 `keep16: true`。默认只给 `pixels` 是因为"要 8 位"是常态，
 *   而不是因为拿不到 12 位。
 */
export function planesToRgba(frame: Frame, opts: DecodeJpegOptions): RgbaResult {
  const { width, height, components, precision } = frame;
  const maxH = Math.max(...components.map((c) => c.h));
  const maxV = Math.max(...components.map((c) => c.v));
  const maxval = maxValueOf(precision);
  const offset = 1 << (precision - 1);
  const n = components.length;

  const planes: Uint16Array[] = [];
  for (const c of components) {
    if (c.plane === null) {
      fail("ASSET.BAD_JPEG", `分量 ${c.id} 的平面还没有解码出来（内部错误：重建顺序错了）`);
    }
    planes.push(c.plane);
  }

  const keep16 = opts.keep16 === true;
  const pixels = new Uint8Array(width * height * 4);
  const pixels16 = keep16 ? new Uint16Array(width * height * 4) : undefined;

  // 3 分量是否 RGB 直通：SOS 里分量 id 是 'R','G','B'，或 APP14 transform=0
  const rgbDirect =
    n === 3 &&
    (frame.adobeTransform === 0 ||
      (components[0]!.id === 0x52 && components[1]!.id === 0x47 && components[2]!.id === 0x42));
  const ycck = n === 4 && frame.adobeTransform === 2;

  /** 平面样本 → 满 16 位量程。8 位时正好是 v*257，与原路径逐字节一致。 */
  const toFull16 = (v: number): number => {
    if (precision === 16) return v;
    if (precision === 8) return v * 257;
    return Math.round((v * 65535) / maxval);
  };

  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const o = (y * width + x) * 4;
      if (n === 1) {
        const g = sampleComponent(
          planes[0]!,
          components[0]!.compW,
          components[0]!.compH,
          maxH / components[0]!.h,
          maxV / components[0]!.v,
          x,
          y,
        );
        const v = clampSample(Math.round(g), maxval);
        writePixel(o, v, v, v);
        continue;
      }
      const s0 = sampleComponent(planes[0]!, components[0]!.compW, components[0]!.compH, maxH / components[0]!.h, maxV / components[0]!.v, x, y);
      const s1 = sampleComponent(planes[1]!, components[1]!.compW, components[1]!.compH, maxH / components[1]!.h, maxV / components[1]!.v, x, y);
      const s2 = sampleComponent(planes[2]!, components[2]!.compW, components[2]!.compH, maxH / components[2]!.h, maxV / components[2]!.v, x, y);

      let r: number;
      let g: number;
      let b: number;
      if (n === 4) {
        // Adobe 的 4 分量以**反相 CMYK** 存储：分量值就是 maxval-C / maxval-M / maxval-Y / maxval-K。
        // ★ 这一支**不能**套 YCbCr 变换（除非 APP14 transform=2 = YCCK）：
        //   把青色通道当亮度算，整张图会变成紫绿色 —— 而且不报错。
        // ★ YCCK 的 YCbCr 编码的是**墨量**（maxval − 反相 CMY），转回"RGB"后
        //   还要再反相一次才等于文件语义里的反相 CMY —— 详见下面 ycck 分支的注释。
        //   这一处曾经写反过（少一次反相），症状是纯白解成纯黑，而且不报错。
        const k = sampleComponent(
          planes[3]!,
          components[3]!.compW,
          components[3]!.compH,
          maxH / components[3]!.h,
          maxV / components[3]!.v,
          x,
          y,
        );
        let c0: number;
        let c1: number;
        let c2: number;
        if (ycck) {
          const cb = s1 - offset;
          const cr = s2 - offset;
          // ★ YCCK 的 Y/Cb/Cr 编码的是**墨量**（= maxval − 存储值），不是存储值本身。
          //   所以 YCbCr→RGB 得到的还是"墨量",要再反相一次才是 Adobe 在文件里放的
          //   反相 CMY（下面 `(c0 * k) / maxval` 用的就是那个）。
          //   少这一次反相 = 白变黑：整幅反相，而且不报错。
          //   这条约定不是从文档抄的，是拿 libjpeg 判出来的：同一个 CMYK 图，
          //   按"YCC 编码反相值"写会被 libjpeg 解成反相图（max=255），
          //   按"YCC 编码墨量"写则与 transform=0 的 RGB 相差 ≤3
          //   （见 tools/make-jpeg-fixtures.py 的 add_cmyk_cases）。
          c0 = maxval - (s0 + 1.402 * cr);
          c1 = maxval - (s0 - 0.344136 * cb - 0.714136 * cr);
          c2 = maxval - (s0 + 1.772 * cb);
        } else {
          c0 = s0;
          c1 = s1;
          c2 = s2;
        }
        // 反相 CMY × 反相 K / maxval = (maxval-C)(maxval-K)/maxval
        r = (c0 * k) / maxval;
        g = (c1 * k) / maxval;
        b = (c2 * k) / maxval;
      } else if (rgbDirect) {
        r = s0;
        g = s1;
        b = s2;
      } else {
        // JFIF / BT.601 全范围。系数与 libjpeg 的 jdcolor.c 同口径（差异 ≤1 级）。
        // ★ 公式是线性的，所以 12 位可以直接用同一组系数 —— 偏移量换成 2^11 即可；
        //   若把系数按 255/4095 缩放，等于白算一遍还引入额外舍入。
        const cb = s1 - offset;
        const cr = s2 - offset;
        r = s0 + 1.402 * cr;
        g = s0 - 0.344136 * cb - 0.714136 * cr;
        b = s0 + 1.772 * cb;
      }

      writePixel(o, r, g, b);
    }
  }

  function writePixel(o: number, r: number, g: number, b: number): void {
    const rv = clampSample(Math.round(r), maxval);
    const gv = clampSample(Math.round(g), maxval);
    const bv = clampSample(Math.round(b), maxval);
    if (pixels16 !== undefined) {
      pixels16[o] = toFull16(rv);
      pixels16[o + 1] = toFull16(gv);
      pixels16[o + 2] = toFull16(bv);
      pixels16[o + 3] = 65535;
      // 不变量：pixels 由 pixels16 派生 —— 任何位深都恒有 round(pixels16/257)
      pixels[o] = Math.round(pixels16[o]! / 257);
      pixels[o + 1] = Math.round(pixels16[o + 1]! / 257);
      pixels[o + 2] = Math.round(pixels16[o + 2]! / 257);
      pixels[o + 3] = 255;
      return;
    }
    pixels[o] = Math.round(toFull16(rv) / 257);
    pixels[o + 1] = Math.round(toFull16(gv) / 257);
    pixels[o + 2] = Math.round(toFull16(bv) / 257);
    pixels[o + 3] = 255;
  }

  return { pixels, pixels16, width, height };
}

export interface DecodeMeta {
  readonly orientation: number;
  readonly truncated: boolean;
  readonly frames: number;
  readonly hierarchical: boolean;
}

/**
 * 组装解码结果（含 EXIF 方向应用）。
 *
 * ★ 为什么方向应用放在最后、且同时作用于 `pixels` 与 `pixels16`：
 *   两者是同一张图的两个精度，任何只对其中一个做变换的实现都会让
 *   "8 位与 16 位看到不同的朝向"，而这种错在下游看起来像"贴图旋转了"。
 */
export function toDecodedJpeg(frame: Frame, meta: DecodeMeta, opts: DecodeJpegOptions): DecodedJpeg {
  const rgba = planesToRgba(frame, opts);
  const apply = opts.orientation === "apply";
  const o8 = apply ? applyOrientation(rgba.pixels, rgba.width, rgba.height, meta.orientation) : null;
  const o16 =
    apply && rgba.pixels16 !== undefined
      ? applyOrientation(rgba.pixels16, rgba.width, rgba.height, meta.orientation)
      : null;

  const maxH = Math.max(...frame.components.map((c) => c.h));
  const maxV = Math.max(...frame.components.map((c) => c.v));
  const c0 = frame.components[0]!;
  const n = frame.components.length;

  return {
    width: o8?.width ?? rgba.width,
    height: o8?.height ?? rgba.height,
    pixels: o8?.data ?? rgba.pixels,
    ...(o16 !== null ? { pixels16: o16.data } : rgba.pixels16 !== undefined ? { pixels16: rgba.pixels16 } : {}),
    bitDepth: frame.precision,
    // 4 分量（CMYK/YCCK）也还原成 RGB，alpha 恒不透明；
    // colorType 用 2（RGB）而不是 6（RGBA）—— JPEG 没有 alpha 通道，写 6 就是撒谎。
    colorType: 2,
    hasAlpha: false,
    usedTransparencyKey: false,
    interlaced: false,
    isApng: false,
    jpeg: {
      process: processName(frame),
      sof: frame.sof,
      progressive: frame.progressive,
      arithmetic: frame.arithmetic,
      lossless: frame.lossless,
      differential: frame.differential,
      precision: frame.precision,
      pointTransform: frame.pt,
      subsampling: subsamplingName(c0, maxH, maxV, n),
      components: n,
      restartInterval: frame.restartInterval,
      orientation: meta.orientation,
      adobeTransform: frame.adobeTransform,
      truncated: meta.truncated,
      frames: meta.frames,
      hierarchical: meta.hierarchical,
    },
  };
}

/** "SOF0 顺序（Huffman）" 这类人读的过程名。 */
function processName(frame: Frame): string {
  const huff = frame.arithmetic ? "算术" : "Huffman";
  const kind = frame.lossless ? "无损" : frame.progressive ? "渐进" : "顺序";
  const diff = frame.differential ? "差分" : "";
  return `SOF${frame.sof & 15} ${diff}${kind}（${huff}）`;
}
