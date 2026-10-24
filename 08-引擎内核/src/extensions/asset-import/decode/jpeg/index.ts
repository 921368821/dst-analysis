/**
 * L4 · JPEG 解码 · 入口
 *
 * ★★ 为什么自己写 DCT 解码，而不是"交给宿主/浏览器"：
 *   与 `png.ts` 同一条理由（见那个文件头）：headless 判据看到的像素，
 *   必须与浏览器看到的像素是**同一份**。一旦 JPEG 走 `createImageBitmap`，
 *   "解码正确性"就变成了"我相信那个浏览器"。而 JPEG 是**有损**格式，
 *   不同实现之间的差异（IDCT 精度、色度上采样滤波器）本来就需要被**测量**，
 *   而不是被隐藏。
 *
 * ★ 支持范围（不是"看起来支持"，每一条都有判据，见 tests/extensions/jpeg*.test.ts）：
 *   · 过程：SOF0/1（顺序）、SOF2（渐进）、SOF3（无损）、SOF5/6/7（差分）、
 *     SOF9/10/11（算术）、SOF13/14/15（算术差分）。**全部 13 个 SOF 都实现**，
 *     不再有"明确不支持"的 SOF。
 *   · 精度：DCT 类 8/12 bit；无损类 2..16 bit。12 位默认输出 8 位 + 全精度在
 *     `pixels16`（`keep16: true`）—— 与 PNG 16 位同一条口径。
 *   · 采样：任意 h/v 因子；1×1/2×1/1×2/2×2 用**三角滤波**上采样（与 libjpeg 的
 *     "fancy upsampling" 同族），更大因子用最近邻复制（libjpeg 对非 2 倍因子
 *     也是复制，不是插值 —— 见 jdsample.c 的 `int_upsample`）。
 *   · 分量：1（灰度）、3（YCbCr / RGB）、4（CMYK / YCCK）。
 *   · 重启标记：DRI + RSTn，按区间重置 DC 预测器 / 算术统计区 / 无损预测器。
 *   · 分层：DHP + EXP + 多帧。差分帧按 T.81 J.1.1 合成 —— 差是**样本之差**，
 *     所以在反量化+IDCT 之后、平面域相加（不是"只把 DC 加回系数"那种偷懒写法）。
 *     无损帧按 mod 2^P 回绕（J.1.1 原文 "calculated modulo 2^16"），
 *     有损帧先减掉电平位移 2^(P-1) 再钳位。参考帧按双线性放大 2 倍。
 *   · EXIF 方向：**解析并报告**，默认不旋转（`orientation: "apply"` 才应用）。
 *     理由：解码器的职责是"还原文件里的像素"，旋转是呈现策略；调用方要哪个都能拿到。
 *
 * ★ 证据等级（哪条是"和别人的解码器对过"，哪条只是自洽）：
 *   · 有外部金标：8 位 SOF0/1/2（Pillow/libjpeg-turbo 编 + 解）、
 *     8 位 SOF9/10（libjpeg-turbo 能解算术流）、8/12/16 位 SOF3（liblj92 编 + 解）。
 *   · 只有自洽回环：SOF11（算术无损，libjpeg 直接 JERR_ARITH_NOTIMPL）、
 *     SOF5/6/7 与 SOF13/14/15（分层，所有主流实现都不做）、12 位 DCT
 *     （Pillow 只编译了 8 位，imagecodecs 没有 jpeg12）。
 *   自洽回环不是"什么都不验证"：它验证"编解码两侧对规范的理解一致"，
 *   对"理解本身错了"无能为力 —— 这一点写在 ADR-0009 里，不粉饰。
 */

import type { EngineError, Result } from "../../../../foundation/result.ts";
import { engineError, err, ok } from "../../../../foundation/result.ts";
import { parse } from "./parse.ts";
import { toDecodedJpeg } from "./reconstruct.ts";
import type { DecodedJpeg, DecodeJpegOptions } from "./types.ts";
import { DEFAULT_MAX_PIXELS, JpegFailure } from "./types.ts";

export { JpegErrorCode } from "./types.ts";
export type { DecodedJpeg, DecodeJpegOptions, JpegInfo } from "./types.ts";

/**
 * 解码 JPEG。**同步**（与 `decodePng` 同一条设计：导入期一次性成本，
 * 换成异步只会让调用方多一层 await，不会更快）。
 */
export function decodeJpeg(bytes: Uint8Array, opts?: DecodeJpegOptions): Result<DecodedJpeg, EngineError> {
  const o = opts ?? {};
  try {
    const file = parse(bytes, o.maxPixels ?? DEFAULT_MAX_PIXELS);
    if (o.strict === true && !file.sawEoi) {
      return err(
        engineError(
          "ASSET.BAD_JPEG",
          `JPEG 不完整：熵数据在偏移 ${bytes.length} 处就结束了，没有 EOI（FF D9）。` +
            "已解码的像素来自补 0 的数据，strict 模式下不返回",
          { byteLength: bytes.length },
        ),
      );
    }
    // 分层的差分合成在 parse 的 finishFrame 里完成（都在样本/平面域，无损按 mod 2^P，
    // 有损先减电平位移）：必须在 buildFramePlanes 之后、返回最终帧之前。
    // 放在这个函数里做就太晚了 —— 拿到的是最后一帧，参考帧的中间状态已经丢了。
    const last = file.frames[file.frames.length - 1]!;
    return ok(
      toDecodedJpeg(
        last,
        {
          orientation: file.orientation,
          truncated: !file.sawEoi,
          frames: file.frames.length,
          hierarchical: file.hierarchical,
        },
        o,
      ),
    );
  } catch (e) {
    if (e instanceof JpegFailure) {
      return err(engineError(e.code, e.message, e.detail));
    }
    return err(
      engineError("ASSET.BAD_JPEG", `JPEG 解码内部错误：${e instanceof Error ? e.message : String(e)}`),
    );
  }
}

/** SOI 检查：给导入器/分发器用，不读像素。 */
export function isJpeg(bytes: Uint8Array): boolean {
  return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
}
