/**
 * L4 · JPEG 解码 · 算术熵解码（SOF9/10/11 与差分 SOF13/14/15）
 *
 * ★ 算术编码不是"另一种哈夫曼"：它没有码字，只有一张**自适应的概率表**。
 *   每个二进制决策用哪个上下文桶，由规范固定（D.5/D.6）——
 *   桶的编号错一个，解出来的图不会报错，只会从那个符号开始整片错，
 *   而且**位流位置仍然"合法"**（算术解码器永远能解出东西）。
 *   所以这里的每个桶偏移都直接对应规范图号，注释里写明是哪张图。
 *
 * ★ 与 libjpeg 的 `jdarith.c` 逐句对齐（DAC 默认值 L=0/U=1/K=5，
 *   DC 桶布局 0..19 + 幅度类别 20 起，AC 每频点 3 桶 + 189/217 两大类）。
 *   对齐不是为了抄，而是因为**互操作性由这个模型唯一决定**：
 *   任何偏移不同，流就解不开 —— 而我们能拿 libjpeg 当对照，
 *   对照不上的实现是错的，不是"口味不同"。
 *
 * ★ SOF11（算术无损）没有任何参考实现（libjpeg 对 `lossless && arith`
 *   直接 `JERR_ARITH_NOTIMPL`），这里按"把 DC 模型用于样本差分"实现，
 *   判据只能是我们自己的编码器回环 + 结构性不变量。文档里如实标注。
 */

import type { Component, Frame } from "./frame.ts";
import { LosslessSampleWriter } from "./lossless-pred.ts";
import { AC_STAT_BINS, DC_STAT_BINS, FIXED_BIN_STATE, QmDecoder, newStats } from "./qm.ts";
import { expectIntervals, readScanHeader, scanGeometry, splitEntropy } from "./scan-common.ts";
import { ZIGZAG } from "./tables.ts";
import { fail } from "./types.ts";

export function decodeArithScan(
  bytes: Uint8Array,
  dataStart: number,
  dataLen: number,
  frame: Frame,
  restartInterval: number,
): number {
  const head = readScanHeader(bytes, dataStart, dataLen, frame);
  const { ss, se, ah, al } = head;
  const progressive = frame.progressive;
  const lossless = frame.lossless;

  // ---------------- 扫描参数校验（各过程不同）
  if (lossless) {
    if (ss < 1 || ss > 7) fail("ASSET.BAD_JPEG", `无损扫描的预测器选择值必须是 1..7（Ss），实际 ${ss}`);
    if (se !== 0) fail("ASSET.BAD_JPEG", `无损扫描的 Se 必须是 0，实际 ${se}`);
    if (ah !== 0) fail("ASSET.BAD_JPEG", `无损扫描的 Ah 必须是 0，实际 ${ah}`);
    if (al >= frame.precision) {
      fail("ASSET.BAD_JPEG", `无损扫描的点变换 Pt=${al} 必须小于精度 ${frame.precision}`);
    }
    frame.pt = al;
  } else if (progressive) {
    if (ss > se || se > 63) fail("ASSET.BAD_JPEG", `渐进式扫描的谱段非法：Ss=${ss} Se=${se}`);
    if (ss === 0 && se !== 0) fail("ASSET.BAD_JPEG", "DC 扫描（Ss=0）必须 Se=0");
    if (ss > 0 && head.comps.length !== 1) fail("ASSET.BAD_JPEG", "AC 扫描（Ss>0）必须是单分量扫描");
    if (al > 13 || ah > 13) fail("ASSET.BAD_JPEG", `渐进式逐次逼近位数非法：Al=${al} Ah=${ah}`);
    if (ah !== 0 && ah !== al + 1) {
      fail("ASSET.BAD_JPEG", `渐进式逼近参数不连续：Ah=${ah} Al=${al}（要求 Ah = Al+1）`);
    }
  } else {
    if (ss !== 0 || se !== 63) fail("ASSET.BAD_JPEG", `顺序式扫描的 Ss/Se 必须是 0/63，实际 ${ss}/${se}`);
    if (ah !== 0 || al !== 0) fail("ASSET.BAD_JPEG", `顺序式扫描的 Ah/Al 必须是 0/0，实际 ${ah}/${al}`);
  }

  const interleaved = head.comps.length > 1;
  const geo = scanGeometry(frame, head.comps, interleaved);
  const split = splitEntropy(bytes, head.entropyStart);
  expectIntervals(split.ranges.length, restartInterval, geo.totalMcus);

  const fixed = new Uint8Array([FIXED_BIN_STATE]);
  let dcStats: Array<Uint8Array | null> = [null, null, null, null];
  let acStats: Array<Uint8Array | null> = [null, null, null, null];
  const lastDc = new Map<Component, number>();
  const dcContext = new Map<Component, number>();
  let reader: QmDecoder | null = null;
  let currentInterval = -1;
  const writer = lossless ? new LosslessSampleWriter(frame.precision, al, ss, head.comps) : null;

  /**
   * 换区间：新建解码器 + 统计区清零 + 预测器复位。
   *
   * ★ 统计区必须清零（D.2.7 / libjpeg `process_restart`）：算术编码的自适应状态
   *   是"从区间起点重新学"的，跨区间沿用会让解码端与编码端的状态在第二个区间分叉。
   */
  const beginInterval = (idx: number): void => {
    const r = split.ranges[idx]!;
    reader = new QmDecoder(bytes, r[0], r[1]);
    dcStats = [null, null, null, null];
    acStats = [null, null, null, null];
    for (const c of head.comps) {
      // 渐进式的 DC 精修扫描不用表；AC 只在 Se>0 时才需要 AC 表
      if (!progressive || (ss === 0 && ah === 0)) {
        dcStats[c.td] = newStats(DC_STAT_BINS);
        lastDc.set(c, 0);
        dcContext.set(c, 0);
      }
      if (!progressive || se !== 0) {
        acStats[c.ta] = newStats(AC_STAT_BINS);
      }
    }
    writer?.beginInterval();
  };

  const dec = (stats: Uint8Array, at: number): number => reader!.decode(stats, at);

  const dcStatsOf = (c: Component): Uint8Array => {
    const s = dcStats[c.td];
    if (s === null || s === undefined) {
      fail("ASSET.BAD_JPEG", `分量 ${c.id} 需要算术 DC 表 ${c.td}，但统计区没有建立（扫描参数自相矛盾）`);
    }
    return s;
  };
  const acStatsOf = (c: Component): Uint8Array => {
    const s = acStats[c.ta];
    if (s === null || s === undefined) {
      fail("ASSET.BAD_JPEG", `分量 ${c.id} 需要算术 AC 表 ${c.ta}，但统计区没有建立（扫描参数自相矛盾）`);
    }
    return s;
  };

  /**
   * 解一个"差分值"（图 F.19–F.24）。
   *
   * 三个用途共用：顺序式 DC、渐进式 DC 首扫、无损样本差分。
   * ★ 共用同一段代码是刻意的：这三者在规范里就是同一棵树，
   *   分别实现等于给"条件类别比较用的是 m 还是 m+1"这类差异留三份出错机会。
   */
  const decodeDiff = (c: Component, st: Uint8Array, ctx: number): { diff: number; ctx: number } => {
    if (dec(st, ctx) === 0) return { diff: 0, ctx: 0 };

    // 图 F.22：符号（SP = S0+2 正 / SN = S0+3 负）
    const sign = dec(st, ctx + 1);
    let at = ctx + 2 + sign;
    // 图 F.23：幅度类别（X1 = 20 起的一元编码）
    let m = dec(st, at);
    if (m !== 0) {
      at = 20;
      while (dec(st, at) !== 0) {
        m <<= 1;
        if (m === 0x8000) fail("ASSET.BAD_JPEG", "算术编码的 DC 幅度类别溢出（≥ 0x8000）");
        at += 1;
      }
    }
    // F.1.4.4.1.2：用类别 m 与前一个差值建立条件类别
    const cond = frame.dcCond[c.td] ?? { l: 0, u: 1 };
    const nextCtx =
      m < (1 << cond.l) >> 1 ? 0 : m > (1 << cond.u) >> 1 ? 12 + sign * 4 : 4 + sign * 4;

    // 图 F.24：幅度位模式
    let v = m;
    at += 14;
    while ((m >>= 1) !== 0) {
      if (dec(st, at) !== 0) v |= m;
    }
    v += 1;
    return { diff: sign !== 0 ? -v : v, ctx: nextCtx };
  };

  // ---------------- 顺序式：DC + AC（图 F.19 / F.20）
  const decodeSequentialBlock = (c: Component, bo: number): void => {
    const st = dcStatsOf(c);
    const r = decodeDiff(c, st, dcContext.get(c)!);
    dcContext.set(c, r.ctx);
    lastDc.set(c, lastDc.get(c)! + r.diff);
    // (JCOEF) 转换在 C 里是 16 位补码回绕；这里显式写出来，避免 12 位 DC 出现"大正数"
    c.coefs[bo] = (lastDc.get(c)! << 16) >> 16;

    const ac = acStatsOf(c);
    const K = frame.acCond[c.ta] ?? 5;
    for (let k = 1; k <= 63; k++) {
      let at = 3 * (k - 1);
      if (dec(ac, at) !== 0) break; // EOB
      while (dec(ac, at + 1) === 0) {
        at += 3;
        k++;
        if (k > 63) fail("ASSET.BAD_JPEG", "算术 AC 系数越过块尾（频谱溢出）");
      }
      const sign = dec(fixed, 0);
      at += 2;
      let m = dec(ac, at);
      if (m !== 0) {
        if (dec(ac, at) !== 0) {
          m <<= 1;
          at = k <= K ? 189 : 217;
          while (dec(ac, at) !== 0) {
            m <<= 1;
            if (m === 0x8000) fail("ASSET.BAD_JPEG", "算术编码的 AC 幅度类别溢出（≥ 0x8000）");
            at += 1;
          }
        }
      }
      let v = m;
      at += 14;
      while ((m >>= 1) !== 0) {
        if (dec(ac, at) !== 0) v |= m;
      }
      v += 1;
      c.coefs[bo + ZIGZAG[k]!] = sign !== 0 ? -v : v;
    }
  };

  // ---------------- 渐进式 DC 首扫 / 精修
  const decodeDcFirst = (c: Component, bo: number): void => {
    const st = dcStatsOf(c);
    const r = decodeDiff(c, st, dcContext.get(c)!);
    dcContext.set(c, r.ctx);
    lastDc.set(c, lastDc.get(c)! + r.diff);
    c.coefs[bo] = ((lastDc.get(c)! << 16) >> 16) << al;
  };

  const decodeDcRefine = (c: Component, bo: number): void => {
    if (dec(fixed, 0) !== 0) c.coefs[bo] = c.coefs[bo]! | (1 << al);
  };

  // ---------------- 渐进式 AC 首扫
  const decodeAcFirst = (c: Component, bo: number): void => {
    const ac = acStatsOf(c);
    const K = frame.acCond[c.ta] ?? 5;
    for (let k = ss; k <= se; k++) {
      let at = 3 * (k - 1);
      if (dec(ac, at) !== 0) break; // EOB
      while (dec(ac, at + 1) === 0) {
        at += 3;
        k++;
        if (k > se) fail("ASSET.BAD_JPEG", `算术渐进 AC 越过谱段末端（k>Se=${se}）`);
      }
      const sign = dec(fixed, 0);
      at += 2;
      let m = dec(ac, at);
      if (m !== 0) {
        if (dec(ac, at) !== 0) {
          m <<= 1;
          at = k <= K ? 189 : 217;
          while (dec(ac, at) !== 0) {
            m <<= 1;
            if (m === 0x8000) fail("ASSET.BAD_JPEG", "算术编码的 AC 幅度类别溢出（≥ 0x8000）");
            at += 1;
          }
        }
      }
      let v = m;
      at += 14;
      while ((m >>= 1) !== 0) {
        if (dec(ac, at) !== 0) v |= m;
      }
      v += 1;
      c.coefs[bo + ZIGZAG[k]!] = (sign !== 0 ? -v : v) << al;
    }
  };

  /**
   * 渐进式 AC 精修。
   *
   * ★ 与顺序式/首扫最大的不同：**只有 k > kex 才判断 EOB**。
   *   `kex` 是上一阶段（Al+1 位）该块最后一个非零系数的位置；
   *   在 k <= kex 的区间里只可能"细化已有系数"或"新增系数"，不会有块尾 ——
   *   多加一次 EOB 判断就会多读一位，整条流从这里错开。
   */
  const decodeAcRefine = (c: Component, bo: number): void => {
    const ac = acStatsOf(c);
    const p1 = 1 << al;
    const m1 = -p1;
    let kex = se;
    while (kex > 0 && c.coefs[bo + ZIGZAG[kex]!] === 0) kex--;

    for (let k = ss; k <= se; k++) {
      let at = 3 * (k - 1);
      if (k > kex && dec(ac, at) !== 0) break; // EOB
      for (;;) {
        const pos = bo + ZIGZAG[k]!;
        const cur = c.coefs[pos]!;
        if (cur !== 0) {
          // 上一阶段已非零：只读一位修正位（按当前符号决定加还是减）
          if (dec(ac, at + 2) !== 0) c.coefs[pos] = cur + (cur < 0 ? m1 : p1);
          break;
        }
        // 本阶段新变为非零：一位"非零"标志 + 一位符号
        if (dec(ac, at + 1) !== 0) {
          c.coefs[pos] = dec(fixed, 0) !== 0 ? m1 : p1;
          break;
        }
        at += 3;
        k++;
        if (k > se) fail("ASSET.BAD_JPEG", `算术 AC 精修越过谱段末端（k>Se=${se}）`);
      }
    }
  };

  // ---------------- 主循环
  for (let mcu = 0; mcu < geo.totalMcus; mcu++) {
    const intervalIdx = restartInterval > 0 ? Math.floor(mcu / restartInterval) : 0;
    if (reader === null || intervalIdx !== currentInterval) {
      currentInterval = intervalIdx;
      beginInterval(intervalIdx);
    }

    if (lossless) {
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
              const st = dcStatsOf(c);
              const r = decodeDiff(c, st, dcContext.get(c)!);
              dcContext.set(c, r.ctx);
              writer!.write(c, x, y, r.diff);
            }
          }
        }
      } else {
        const c = head.comps[0]!;
        const st = dcStatsOf(c);
        const r = decodeDiff(c, st, dcContext.get(c)!);
        dcContext.set(c, r.ctx);
        writer!.write(c, mcu % c.compW, Math.floor(mcu / c.compW), r.diff);
      }
      continue;
    }

    const blockAt = (c: Component, blockX: number, blockY: number): number =>
      (blockY * c.strideBlocksW + blockX) * 64;

    const decodeBlock = (c: Component, bo: number): void => {
      if (!progressive) decodeSequentialBlock(c, bo);
      else if (ss === 0) {
        if (ah === 0) decodeDcFirst(c, bo);
        else decodeDcRefine(c, bo);
      } else if (ah === 0) decodeAcFirst(c, bo);
      else decodeAcRefine(c, bo);
    };

    if (interleaved) {
      const mcuX = mcu % geo.mcusX;
      const mcuY = Math.floor(mcu / geo.mcusX);
      for (const c of head.comps) {
        for (let by = 0; by < c.v; by++) {
          for (let bx = 0; bx < c.h; bx++) {
            decodeBlock(c, blockAt(c, mcuX * c.h + bx, mcuY * c.v + by));
          }
        }
      }
    } else {
      const c = head.comps[0]!;
      decodeBlock(c, blockAt(c, mcu % c.blocksW, Math.floor(mcu / c.blocksW)));
    }
  }

  void dataLen;
  return split.next;
}
