/**
 * L4 · JPEG 解码 · 无损熵解码（SOF3 / SOF7：Huffman + DPCM）
 *
 * ★ 无损 JPEG 没有 DCT、没有量化表：样本值直接以"与邻居预测之差"编码。
 *   这和有损路径共享的部分只有"位读取器 + 哈夫曼表"，所以单独成文件，
 *   而不是在 `scan-huffman.ts` 里塞一堆 `if (lossless)`。
 *
 * ★ 样本重建（预测器边界、不钳位）在 `lossless-pred.ts`：算术无损（SOF11）用同一份，
 *   否则两种熵编码会各自把"首行用什么预测"实现一遍，而它们各有判据 ——
 *   两份实现之间的差异没有任何判据能测。
 */

import type { HuffTable } from "./bits.ts";
import { BitReader, extend } from "./bits.ts";
import type { Component, Frame } from "./frame.ts";
import { LosslessSampleWriter } from "./lossless-pred.ts";
import { expectIntervals, readScanHeader, scanGeometry, splitEntropy } from "./scan-common.ts";
import { fail } from "./types.ts";

export function decodeLosslessScan(
  bytes: Uint8Array,
  dataStart: number,
  dataLen: number,
  frame: Frame,
  dcTables: Array<HuffTable | null>,
  restartInterval: number,
): number {
  const head = readScanHeader(bytes, dataStart, dataLen, frame);
  const psv = head.ss;
  if (psv < 1 || psv > 7) {
    fail("ASSET.BAD_JPEG", `无损扫描的预测器选择值必须是 1..7（Ss），实际 ${psv}`);
  }
  if (head.se !== 0) fail("ASSET.BAD_JPEG", `无损扫描的 Se 必须是 0，实际 ${head.se}`);
  if (head.ah !== 0) fail("ASSET.BAD_JPEG", `无损扫描的 Ah 必须是 0，实际 ${head.ah}`);
  const al = head.al;
  if (al >= frame.precision) {
    fail("ASSET.BAD_JPEG", `无损扫描的点变换 Pt=${al} 必须小于精度 ${frame.precision}`);
  }
  frame.pt = al;

  const interleaved = head.comps.length > 1;
  const geo = scanGeometry(frame, head.comps, interleaved);
  const split = splitEntropy(bytes, head.entropyStart);
  expectIntervals(split.ranges.length, restartInterval, geo.totalMcus);

  const writer = new LosslessSampleWriter(frame.precision, al, psv, head.comps);
  let reader: BitReader | null = null;
  let currentInterval = -1;

  const beginInterval = (idx: number): void => {
    const r = split.ranges[idx]!;
    reader = new BitReader(bytes, r[0], r[1]);
    writer.beginInterval();
  };

  const dcTable = (c: Component): HuffTable => {
    const t = dcTables[c.td] ?? null;
    if (t === null) fail("ASSET.BAD_JPEG", `分量 ${c.id} 需要 DC 哈夫曼表 ${c.td}，但文件里没有定义（DHT 缺失）`);
    return t;
  };

  const writeSample = (c: Component, x: number, y: number): void => {
    const r = reader!;
    const s = dcTable(c).decode(r);
    if (s > 16) fail("ASSET.BAD_JPEG", `无损差分的类别位数 ${s} 超过 16`);
    writer.write(c, x, y, extend(r.receive(s), s));
  };

  for (let mcu = 0; mcu < geo.totalMcus; mcu++) {
    const intervalIdx = restartInterval > 0 ? Math.floor(mcu / restartInterval) : 0;
    if (reader === null || intervalIdx !== currentInterval) {
      currentInterval = intervalIdx;
      beginInterval(intervalIdx);
    }

    if (interleaved) {
      const mcuX = mcu % geo.mcusX;
      const mcuY = Math.floor(mcu / geo.mcusX);
      for (const c of head.comps) {
        for (let vy = 0; vy < c.v; vy++) {
          const y = mcuY * c.v + vy;
          if (y >= c.compH) continue;
          for (let hx = 0; hx < c.h; hx++) {
            const x = mcuX * c.h + hx;
            if (x >= c.compW) continue;
            writeSample(c, x, y);
          }
        }
      }
    } else {
      const c = head.comps[0]!;
      writeSample(c, mcu % c.compW, Math.floor(mcu / c.compW));
    }
  }

  return split.next;
}
