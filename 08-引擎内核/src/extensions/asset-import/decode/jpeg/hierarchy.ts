/**
 * L4 · JPEG 解码 · 分层（差分帧）合成
 *
 * ★ 证据等级：**这一块没有第三方实现可对照，必须如实标注。**
 *   libjpeg / libjpeg-turbo 已把分层支持整段移除（`jdcoefct.c`、`jdinput.c` 里
 *   搜不到 `hier_code`），Pillow、imagecodecs、liblj92 也一律不解分层。
 *   所以正确性只能靠：自洽回环（无损差分必须逐位可逆）+ 结构性校验。
 *   见 `tests/extensions/jpeg-modes.test.ts` 与 ADR-0009。
 *
 * ★ 语义按 T.81 J.1.1 的原文，而不是"看起来合理"的推导：
 *   · "Differential frames shall then be used to encode the two's complement
 *     differences between **source input components** and the **reference
 *     components**" —— 差是**样本之差**，不是系数之差。
 *     所以合成在平面域（反量化+IDCT 之后），不在系数域。
 *   · "When the resolution of a reference component does not match ... an
 *     upsampling filter shall be used"，"Bi-linear interpolation is used"
 *     （J.1.1.2，放大倍数按 J.1.1 只能是 2）。
 *     所以参考帧上采样是**双线性**，不是最近邻复制。
 *   · 有损帧的差图仍走"电平位移"（FDCT 前统一减 2^(P-1)），所以
 *     `sample = diff_plane - 2^(P-1) + ref`；
 *     无损帧没有电平位移（Annex H 不做位移），所以 `sample = diff_plane + ref`。
 *     ★ 曾经对无损也减 2^(P-1)：8 位整张图会整体压暗 128，看起来像"曝光错了"。
 */

import type { Component, Frame } from "./frame.ts";
import { clampSample, maxValueOf } from "./reconstruct.ts";
import { fail } from "./types.ts";

/**
 * 双线性上采样一个分量平面（放大倍数只能是整数 1..2，按 T.81 J.1.1.2）。
 *
 * 相位约定（规范图 J.2 的几何）：参考样本 i 位于它覆盖的 2×2 输出块的中心，
 * 于是两个输出位置各偏移 1/4 个参考样本间距，取 3:1 双线性权重：
 *   out[2i]   = (3·ref[i] + ref[i-1] + 2) >> 2
 *   out[2i+1] = (3·ref[i] + ref[i+1] + 2) >> 2
 * 边缘按最近样本钳位。常数平面放大后仍是常数 —— 否则"参考帧是纯色"会凭空出现波纹。
 *
 * ★ 这个相位是**本实现的选择**：规范给了图但没给可执行的取整规则，
 *   而没有第三方解码器能验证它。编码器（tests/tools/jpeg-encode.ts）用同一份规则，
 *   所以无损分层的回环仍然逐位相等；但"真实文件是否也用这个相位"无法证明。
 *   这一点写在 ADR-0009 的"证据缺口"里，不粉饰。
 */
function upsamplePlane(
  src: Uint16Array,
  sw: number,
  sh: number,
  dw: number,
  dh: number,
): Uint16Array {
  const out = new Uint16Array(dw * dh);
  // ★ 边界必须**两侧**都钳：只写 `Math.min(sh-1, y)` 时 y=-1 会读到负下标 → undefined
  //   → NaN 落进 Uint16Array 变 0，第一行/第一列整片变黑（而且不抛错）。
  const cx = (x: number): number => (x < 0 ? 0 : x >= sw ? sw - 1 : x);
  const cy = (y: number): number => (y < 0 ? 0 : y >= sh ? sh - 1 : y);
  const at = (x: number, y: number): number => src[cy(y) * sw + cx(x)]!;
  for (let y = 0; y < dh; y++) {
    // 输出行 y 对应参考行的中心与邻居
    const y0 = Math.floor(y / 2);
    const yc = y % 2 === 0 ? y0 - 1 : y0 + 1;
    for (let x = 0; x < dw; x++) {
      const x0 = Math.floor(x / 2);
      const xc = x % 2 === 0 ? x0 - 1 : x0 + 1;
      const v =
        at(x0, y0) * 9 + at(xc, y0) * 3 + at(x0, yc) * 3 + at(xc, yc);
      // 9+3+3+1 = 16 份权重，1/4 偏移下的标准双线性
      out[y * dw + x] = Math.floor((v + 8) / 16);
    }
  }
  return out;
}

/** 按分量配对：优先分量 id，id 对不上时退回序号（有些编码器会重排分量顺序）。 */
function pairComponent(cur: Frame, prev: Frame, ci: number): { c: Component; p: Component } {
  const c = cur.components[ci]!;
  const p = prev.components.find((x) => x.id === c.id) ?? prev.components[ci];
  if (p === undefined) {
    fail("ASSET.BAD_JPEG", `分层 JPEG 的差分帧找不到分量 ${c.id} 的参考分量`);
  }
  return { c, p };
}

function checkPairing(cur: Frame, prev: Frame): void {
  if (cur.components.length !== prev.components.length) {
    fail(
      "ASSET.BAD_JPEG",
      `分层 JPEG 的差分帧有 ${cur.components.length} 个分量，参考帧有 ${prev.components.length} 个` +
        "（分量数不一致就无法逐分量做预测）",
    );
  }
  if (cur.precision !== prev.precision) {
    fail(
      "ASSET.BAD_JPEG",
      `分层 JPEG 的差分帧精度 ${cur.precision} 与参考帧 ${prev.precision} 不一致` +
        "（不同位深的差没有定义，只能报错而不是猜）",
    );
  }
}

/**
 * 把参考帧合成进差分帧的平面（**必须在 `buildFramePlanes` 之后调用**）。
 *
 * 有损帧减 `2^(P-1)`（电平位移），无损帧不减 —— 这是两者唯一的差别，
 * 用 `cur.lossless` 分支而不是"传个参数"，因为传参一定会有人传错。
 */
export function addReferencePlanes(cur: Frame, prev: Frame): void {
  checkPairing(cur, prev);
  const maxval = maxValueOf(cur.precision);
  // 有损帧的差图走过电平位移，要减回来；无损帧走 Annex H，没有位移
  const shift = cur.lossless ? 0 : 1 << (cur.precision - 1);

  for (let ci = 0; ci < cur.components.length; ci++) {
    const { c, p } = pairComponent(cur, prev, ci);
    const dst = c.plane;
    const src = p.plane;
    if (dst === null || src === null) {
      fail("ASSET.BAD_JPEG", `分量 ${c.id} 的平面还没解出来（内部错误：分层合成的顺序错了）`);
    }
    const w = c.compW;
    const h = c.compH;
    // 与参考帧尺寸一致时不必插值（也避免把"1 倍放大"写成插值而引入 1 级误差）
    const up =
      p.compW === w && p.compH === h ? src : upsamplePlane(src, p.compW, p.compH, w, h);
    for (let y = 0; y < h; y++) {
      const row = y * w;
      for (let x = 0; x < w; x++) {
        const sum = dst[row + x]! - shift + up[row + x]!;
        // ★ 无损：按 2^P **取模**，不是钳位。J.1.1 原文："the reconstructed components
        //   calculated from the reconstructed differential components are also calculated
        //   modulo 2^16"。差本身是模 2^P 的差（s=10, ref=250 时差是 16，16+250=266 要回绕到 10），
        //   钳位会把它压成 255 —— 8 位图上就是"高光被剪掉"。
        dst[row + x] = cur.lossless ? sum & maxval : clampSample(sum, maxval);
      }
    }
  }
}

/**
 * EXP 声明与几何比例是否一致（只用于上报/校验，合成时以几何为准）。
 *
 * ★ 参数顺序容易被误读：按 T.81 B.3.3，EXP **挂在差分帧上**、描述"参考帧要放大多少"，
 *   所以这里读的是 `cur.expansions`，比例算的是 `cur / prev`。
 */
export function expansionMatchesGeometry(prev: Frame, cur: Frame): boolean {
  for (let ci = 0; ci < prev.components.length; ci++) {
    const c = prev.components[ci]!;
    const e = cur.expansions.get(c.id);
    if (e === undefined) continue;
    const n = cur.components.find((x) => x.id === c.id) ?? cur.components[ci];
    if (n === undefined) return false;
    if (Math.abs(n.compW / c.compW - e.eh) > 1e-9) return false;
    if (Math.abs(n.compH / c.compH - e.ev) > 1e-9) return false;
  }
  return true;
}
