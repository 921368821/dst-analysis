/**
 * L4 · JPEG 解码 · 无损样本重建（预测器 + 边界约定）
 *
 * ★ 为什么要单独一个文件：无损有两条熵解码路径（Huffman 的 SOF3/SOF7、
 *   算术的 SOF11/SOF15），但它们**重建样本的方式必须完全一样**。
 *   如果各写一份，"预测器 P5 的右移在一边是算术右移、另一边是逻辑右移"
 *   这种错会让两种编码模式解出不同的图，而两种模式各自都有判据 —— 判据都绿。
 *
 * ★ 边界约定（T.81 H.2.1，与 libjpeg `jdlossls.c` 逐条对齐）：
 *   1. 扫描/重启区间的**第一行**：首样本用常数 `2^(P-Pt-1)`，该行其余用一维预测（左）。
 *      第一行必须退化成一维 —— 用扫描头预测器会让首行逐像素漂移。
 *   2. **其余行的首样本**：用正上方样本（Rb）。
 *   3. **不做钳位**：`sample = (pred + diff) & 0xFFFF`。
 *      钳位看着"更安全"，实则致命：预测器本身可以超出值域（P4 的 Ra+Rb-Rc 就能），
 *      钳位会让解码端算出与编码端不同的邻居，误差沿行累积。
 *      这是本轮被金标抓出来的第一个真错。
 */

import type { Component } from "./frame.ts";
import { fail } from "./types.ts";

/**
 * 二维预测器（P1..P7）。`>>` 是算术右移，负数向下取整 —— 与 C 的 `>>` 一致，
 * 也与规范的 `⌊·⌋` 一致（P5/P6/P7 的除法是向下取整，不是向零取整）。
 */
export function predictLossless(psv: number, ra: number, rb: number, rc: number): number {
  switch (psv) {
    case 1:
      return ra;
    case 2:
      return rb;
    case 3:
      return rc;
    case 4:
      return ra + rb - rc;
    case 5:
      return ra + ((rb - rc) >> 1);
    case 6:
      return rb + ((ra - rc) >> 1);
    case 7:
      return (ra + rb) >> 1;
    default:
      return fail("ASSET.BAD_JPEG", `无损预测器选择值必须是 1..7，实际 ${psv}`);
  }
}

/**
 * 把"差分"写成分量平面里的样本。
 *
 * 每个重启区间要调一次 `beginInterval()`：libjpeg 在 `process_restart` 里
 * 把重建函数复位成"首行版本"，即区间第一行重新按一维处理。
 */
export class LosslessSampleWriter {
  private readonly initial: number;
  /** 每个分量在当前区间里"第一行"的行号；-1 = 该区间还没落过样本。 */
  private readonly firstRow = new Map<Component, number>();

  constructor(
    precision: number,
    pt: number,
    private readonly psv: number,
    private readonly comps: readonly Component[],
  ) {
    // 首样本的预测常数随点变换一起缩小：Pt>0 时样本已经被右移，
    // 用 2^(P-1) 会让第一个像素就偏（这是被金标抓到的第二个真错）
    this.initial = 1 << (precision - pt - 1);
  }

  beginInterval(): void {
    for (const c of this.comps) this.firstRow.set(c, -1);
  }

  /** `diff` 是解出的差分；`x/y` 是分量平面坐标。 */
  write(c: Component, x: number, y: number, diff: number): void {
    const plane = c.plane!;
    const w = c.compW;
    let rt = this.firstRow.get(c)!;
    if (rt === -1) {
      rt = y;
      this.firstRow.set(c, y);
    }

    let pred: number;
    if (y === rt) {
      pred = x === 0 ? this.initial : plane[y * w + x - 1]!;
    } else if (x === 0) {
      pred = plane[(y - 1) * w + x]!;
    } else {
      pred = predictLossless(this.psv, plane[y * w + x - 1]!, plane[(y - 1) * w + x]!, plane[(y - 1) * w + x - 1]!);
    }
    plane[y * w + x] = (pred + diff) & 0xffff;
  }
}
