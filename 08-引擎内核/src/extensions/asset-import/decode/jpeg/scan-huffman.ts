/**
 * L4 · JPEG 解码 · 哈夫曼熵解码（顺序式 / 渐进式）
 *
 * ★ 熵数据**先按 RST 切分**再逐区间建位读取器：单一位流 + "读着遇到标记就跳过"
 *   是这类解码器最常见的错源（缓冲里预读了几位、标记位置对不上，于是整幅变噪点，
 *   而且不抛错）。预切分把区间边界变成输入，位读取器只需处理 FF00。
 */

import type { HuffTable } from "./bits.ts";
import { BitReader, extend } from "./bits.ts";
import type { Component, Frame } from "./frame.ts";
import { expectIntervals, readScanHeader, scanGeometry, splitEntropy } from "./scan-common.ts";
import { ZIGZAG } from "./tables.ts";
import { fail } from "./types.ts";

interface ScanState {
  eobrun: number;
}

export function decodeScan(
  bytes: Uint8Array,
  dataStart: number,
  dataLen: number,
  frame: Frame,
  dcTables: Array<HuffTable | null>,
  acTables: Array<HuffTable | null>,
  restartInterval: number,
): number {
  const head = readScanHeader(bytes, dataStart, dataLen, frame);
  const scanComps = head.comps;
  const { ss, se, ah, al } = head;

  const progressive = frame.progressive;
  if (!progressive) {
    if (ss !== 0 || se !== 63) {
      fail("ASSET.BAD_JPEG", `顺序式扫描的 Ss/Se 必须是 0/63，实际 ${ss}/${se}`);
    }
    if (ah !== 0 || al !== 0) {
      fail("ASSET.BAD_JPEG", `顺序式扫描的 Ah/Al 必须是 0/0，实际 ${ah}/${al}`);
    }
  } else {
    if (ss > se || se > 63) fail("ASSET.BAD_JPEG", `渐进式扫描的谱段非法：Ss=${ss} Se=${se}`);
    if (ss === 0 && se !== 0) fail("ASSET.BAD_JPEG", "DC 扫描（Ss=0）必须 Se=0");
    if (ss > 0 && scanComps.length !== 1) fail("ASSET.BAD_JPEG", "AC 扫描（Ss>0）必须是单分量扫描");
    if (al > 13 || ah > 13) fail("ASSET.BAD_JPEG", `渐进式逐次逼近位数非法：Al=${al} Ah=${ah}`);
    if (ah !== 0 && ah !== al + 1) {
      // 规范要求 Ah = Al + 1（同一谱段的相邻两次逼近）；不符就是文件结构错
      fail("ASSET.BAD_JPEG", `渐进式逼近参数不连续：Ah=${ah} Al=${al}（要求 Ah = Al+1）`);
    }
  }

  const interleaved = scanComps.length > 1;
  const geo = scanGeometry(frame, scanComps, interleaved);
  const split = splitEntropy(bytes, head.entropyStart);
  expectIntervals(split.ranges.length, restartInterval, geo.totalMcus);

  /**
   * DC 差分的幅值类别上限。
   *
   * ★ 这个上限**随精度变**（T.81 F.1.2.1 / Table F.1）：8 位样本的 DC 差分最多
   *   ±2047（类别 11），12 位最多 ±32767（类别 15）。上一版写死 11，
   *   于是 12 位彩色图（每分量 DC 可达 4095，差分类别可到 12）**必然误判成坏文件**，
   *   而 12 位灰度因为色块平缓恰好没触发 —— 正是最难发现的那种"只在特定输入下错"。
   */
  const maxDcCategory = frame.precision > 8 ? 15 : 11;

  let reader: BitReader | null = null;
  let currentInterval = -1;
  const state: ScanState = { eobrun: 0 };
  /** AC 精修的状态机（跨块保留，块内不重置）。每次换区间/扫描都要归零。 */
  const refine = { state: 0, next: 0, eobrun: 0 };

  const beginInterval = (idx: number): void => {
    const r = split.ranges[idx]!;
    reader = new BitReader(bytes, r[0], r[1]);
    state.eobrun = 0;
    refine.state = 0;
    refine.next = 0;
    refine.eobrun = 0;
    for (const c of scanComps) c.pred = 0;
  };

  const huff = (table: HuffTable | null, kind: "DC" | "AC", compId: number): HuffTable => {
    if (table === null) {
      fail("ASSET.BAD_JPEG", `分量 ${compId} 需要 ${kind} 哈夫曼表，但文件里没有定义（DHT 缺失）`);
    }
    return table;
  };

  /** 顺序式（baseline / extended sequential）单块。 */
  const decodeSequentialBlock = (c: Component, bo: number): void => {
    const r = reader!;
    const dc = huff(dcTables[c.td] ?? null, "DC", c.id);
    const ac = huff(acTables[c.ta] ?? null, "AC", c.id);
    const s = dc.decode(r);
    if (s > maxDcCategory) {
      fail("ASSET.BAD_JPEG", `DC 差分位数 ${s} 超过 ${maxDcCategory}（${frame.precision} 位样本的上限）`);
    }
    c.pred += extend(r.receive(s), s);
    c.coefs[bo] = c.pred;
    let k = 1;
    while (k < 64) {
      const rs = ac.decode(r);
      const run = rs >> 4;
      const size = rs & 15;
      if (size === 0) {
        if (run === 15) {
          k += 16;
          continue;
        }
        break; // EOB
      }
      k += run;
      if (k > 63) fail("ASSET.BAD_JPEG", `AC 系数越过块尾：k=${k}（run=${run}）`);
      c.coefs[bo + ZIGZAG[k]!] = extend(r.receive(size), size);
      k++;
    }
  };

  const decodeProgressiveDc = (c: Component, bo: number): void => {
    const r = reader!;
    if (ah === 0) {
      const dc = huff(dcTables[c.td] ?? null, "DC", c.id);
      const s = dc.decode(r);
      if (s > maxDcCategory) {
        fail("ASSET.BAD_JPEG", `DC 差分位数 ${s} 超过 ${maxDcCategory}（${frame.precision} 位样本的上限）`);
      }
      c.pred += extend(r.receive(s), s);
      c.coefs[bo] = c.pred << al;
    } else {
      // 逐次逼近：只补一位到已有 DC 的 Al 位上
      if (r.readBit() === 1) c.coefs[bo] = c.coefs[bo]! | (1 << al);
    }
  };

  const decodeProgressiveAcFirst = (c: Component, bo: number): void => {
    const r = reader!;
    if (state.eobrun > 0) {
      state.eobrun--;
      return;
    }
    const ac = huff(acTables[c.ta] ?? null, "AC", c.id);
    let k = ss;
    while (k <= se) {
      const rs = ac.decode(r);
      const run = rs >> 4;
      const size = rs & 15;
      if (size === 0) {
        if (run < 15) {
          state.eobrun = (1 << run) - 1;
          if (run > 0) state.eobrun += r.receive(run);
          break;
        }
        k += 16;
        continue;
      }
      k += run;
      if (k > 63) fail("ASSET.BAD_JPEG", `渐进 AC 系数越过块尾：k=${k}`);
      c.coefs[bo + ZIGZAG[k]!] = extend(r.receive(size), size) << al;
      k++;
    }
  };

  /**
   * 渐进 AC 逐次逼近（G.1.2.3）。
   *
   * ★ 为什么是"状态机 + 跨块保留状态"而不是"一个 while 循环把一块解完"：
   *   第一版写的是循环版，看起来等价，但渐进式图整片花（baseline 全对）。
   *   关键差别在 EOB 的 `r=0` 编码：它表示"本块到此为止"，但**本块剩下的
   *   非零系数仍要各读一位修正位**。循环版把 EOBRUN 记成 `(1<<r)-1+receive(r)`，
   *   r=0 时得到 0，于是"还有 EOBRUN 剩余"为假，这 N 位一个没读 ——
   *   位流少读、随后整段错位，最后抛"哈夫曼码流非法"或解出花屏。
   *   这里用"包含当前块"的计数（`(1<<r) + receive(r)`）并在块尾统一减一，
   *   语义自洽；状态显式化为 0=取符号 / 1,2=跳过零 / 3=放新值 / 4=EOB，
   *   每个 case 只做一件事，可与规范逐句对照。
   *
   * ★ 另一条容易写错的规则：扫过一个**历史非零**系数时只读一位修正位，
   *   **不消耗 run**（run 只数零系数）。写成"遇到非零就 run--"会让后续
   *   系数全部错位，而画面只是"有点噪"，不会报错。
   */
  const decodeProgressiveAcRefine = (c: Component, bo: number): void => {
    const r = reader!;
    const p1 = 1 << al;
    const st = refine;
    let k = ss;
    let run = 0;

    while (k <= se) {
      const pos = bo + ZIGZAG[k]!;
      const cur = c.coefs[pos]!;
      const dir = cur < 0 ? -1 : 1;

      switch (st.state) {
        case 0: {
          const rs = huff(acTables[c.ta] ?? null, "AC", c.id).decode(r);
          const size = rs & 15;
          run = rs >> 4;
          if (size === 0) {
            if (run < 15) {
              st.eobrun = (1 << run) + (run > 0 ? r.receive(run) : 0);
              st.state = 4;
            } else {
              run = 16; // ZRL：跳过 16 个零系数
              st.state = 1;
            }
          } else {
            if (size !== 1) fail("ASSET.BAD_JPEG", `渐进 AC 精修里出现了 size=${size}（规范只允许 1）`);
            st.next = r.readBit() === 1 ? 1 : -1;
            st.state = run > 0 ? 2 : 3;
          }
          continue; // 这个位置还没有落值，不推进 k
        }
        case 1:
        case 2:
          if (cur !== 0) {
            if (r.readBit() === 1 && (cur & p1) === 0) c.coefs[pos] = cur + p1 * dir;
          } else {
            run--;
            if (run === 0) st.state = st.state === 2 ? 3 : 0;
          }
          break;
        case 3:
          if (cur !== 0) {
            if (r.readBit() === 1 && (cur & p1) === 0) c.coefs[pos] = cur + p1 * dir;
          } else {
            c.coefs[pos] = st.next * p1;
            st.state = 0;
          }
          break;
        default:
          // 4：EOB 覆盖区内，只给已有非零系数补修正位
          if (cur !== 0 && r.readBit() === 1 && (cur & p1) === 0) c.coefs[pos] = cur + p1 * dir;
          break;
      }
      k++;
    }

    if (st.state === 4) {
      st.eobrun--;
      if (st.eobrun <= 0) st.state = 0;
    }
  };

  for (let mcu = 0; mcu < geo.totalMcus; mcu++) {
    const intervalIdx = restartInterval > 0 ? Math.floor(mcu / restartInterval) : 0;
    if (intervalIdx !== currentInterval) {
      currentInterval = intervalIdx;
      beginInterval(intervalIdx);
    }

    if (interleaved) {
      // 只需要 mcusX：MCU 行号由 mcu / mcusX 得到，不必再算一次 maxV
      const mcuX = mcu % geo.mcusX;
      const mcuY = Math.floor(mcu / geo.mcusX);
      for (const c of scanComps) {
        for (let by = 0; by < c.v; by++) {
          for (let bx = 0; bx < c.h; bx++) {
            const blockX = mcuX * c.h + bx;
            const blockY = mcuY * c.v + by;
            const bo = (blockY * c.strideBlocksW + blockX) * 64;
            if (progressive) {
              if (ss === 0) decodeProgressiveDc(c, bo);
              else if (ah === 0) decodeProgressiveAcFirst(c, bo);
              else decodeProgressiveAcRefine(c, bo);
            } else {
              decodeSequentialBlock(c, bo);
            }
          }
        }
      }
    } else {
      const c = scanComps[0]!;
      const bx = mcu % c.blocksW;
      const by = Math.floor(mcu / c.blocksW);
      const bo = (by * c.strideBlocksW + bx) * 64;
      if (progressive) {
        if (ss === 0) decodeProgressiveDc(c, bo);
        else if (ah === 0) decodeProgressiveAcFirst(c, bo);
        else decodeProgressiveAcRefine(c, bo);
      } else {
        decodeSequentialBlock(c, bo);
      }
    }
  }

  void reader;
  return split.next;
}
