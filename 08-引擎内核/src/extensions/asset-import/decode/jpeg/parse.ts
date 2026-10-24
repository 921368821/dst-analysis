/**
 * L4 · JPEG 解码 · 标记段主循环（多帧）
 *
 * ★ 只做一件事：按 JPEG 的段结构走一遍，把该给谁的东西交给谁。
 *   熵数据的**边界**由 `splitEntropy` 判定，返回值 `next` 让这里继续往下走 ——
 *   主循环永远停在标记上，不会停在一个数据字节中间。
 *
 * ★ 为什么主循环要支持**多个 SOF**（分层 JPEG）：DHP 声明"N 帧"，
 *   每帧有自己的 SOF/表/熵数据，帧与帧之间靠 EXP 声明放大因子。
 *   把"每遇到 SOF 就把上一帧收尾"写进主循环，多帧与单帧就是同一条路径；
 *   否则分层会变成"另一个解码器"，而另一个解码器只有它自己的判据能测。
 *
 * ★ 表的生命周期：DQT/DHT/DAC 是**文件级可重定义**的，所以
 *   · 帧对象持有的是"当前数组的引用"，后续帧改表会覆盖它（这是允许的）；
 *   · 但每个分量的量化表在 **SOS 时**就绑到 `c.qtTable`，
 *     重建时不再查 `frame.qt` —— 否则先解的帧会用上后定义的量化表，而且不报错。
 */

import { parseDac, parseDht, parseDqt, parseSof, readExifOrientation, u16be } from "./frame.ts";
import type { Frame } from "./frame.ts";
import type { HuffTable } from "./bits.ts";
import { addReferencePlanes, expansionMatchesGeometry } from "./hierarchy.ts";
import { buildFramePlanes } from "./reconstruct.ts";
import { decodeArithScan } from "./scan-arith.ts";
import { decodeLosslessScan } from "./scan-lossless.ts";
import { decodeScan } from "./scan-huffman.ts";
import { fail } from "./types.ts";

const MARKER_DHT = 0xc4;
const MARKER_SOI = 0xd8;
const MARKER_EOI = 0xd9;
const MARKER_SOS = 0xda;
const MARKER_DQT = 0xdb;
const MARKER_DRI = 0xdd;
const MARKER_DHP = 0xde;
const MARKER_EXP = 0xdf;
const MARKER_APP0 = 0xe0;
const MARKER_APP1 = 0xe1;
const MARKER_APP14 = 0xee;
const MARKER_DAC = 0xcc;

/** 解析结果：所有帧（已重建出分量平面）+ 文件级元信息。 */
export interface JpegFile {
  readonly frames: Frame[];
  readonly width: number;
  readonly height: number;
  readonly precision: number;
  readonly adobeTransform: number | null;
  readonly orientation: number;
  readonly sawEoi: boolean;
  readonly scanCount: number;
  readonly hierarchical: boolean;
}

/** 解析头部与所有扫描（熵数据就地解码），每帧结束时立刻重建平面。 */
export function parse(bytes: Uint8Array, maxPixels: number): JpegFile {
  // ★ 只判"开头是不是 SOI"，不顺手把"长度 < 4"也算成缺 SOI：
  //   一个只有 `FF D8` 的 2 字节文件**确实**有 SOI，缺的是后面的帧头。
  //   把两件事混在一个条件里，报错就会写成"缺少 SOI，实际开头 ff d8"——自相矛盾，
  //   对着日志排查的人会以为魔数判错了方向。
  if (bytes.length < 2 || bytes[0] !== 0xff || bytes[1] !== MARKER_SOI) {
    fail("ASSET.BAD_JPEG", `缺少 SOI（FF D8），实际开头 ${hex(bytes, 0, Math.min(4, bytes.length))}`);
  }

  const frames: Frame[] = [];
  let current: Frame | null = null;
  const qt: Array<Uint16Array | null> = [null, null, null, null];
  const dcTables: Array<HuffTable | null> = [null, null, null, null];
  const acTables: Array<HuffTable | null> = [null, null, null, null];
  // DAC 不写就是缺省条件（T.81 B.2.4.3）：L=0 / U=1 / K=5
  const dcCond: Array<{ l: number; u: number }> = [
    { l: 0, u: 1 },
    { l: 0, u: 1 },
    { l: 0, u: 1 },
    { l: 0, u: 1 },
  ];
  const acCond: number[] = [5, 5, 5, 5];
  let restartInterval = 0;
  let adobeTransform: number | null = null;
  let orientation = 1;
  let scanCount = 0;
  let sawEoi = false;
  let hierarchical = false;
  /**
   * EXP 只作用于**下一个帧头**（T.81 B.3.3："apply only to the next frame ...
   * shall not precede a scan header or a DHP marker segment"），
   * 所以在遇到 SOF 时把它挂上去，而不是当场写进当前帧。
   */
  let pendingExp = new Map<number, { eh: number; ev: number }>();
  /** DHP 声明的是"完成态图像"的几何（B.3.2），用来校验后面每一帧不超过它。 */
  let sequenceHeader: { precision: number; width: number; height: number } | null = null;

  const finishFrame = (): void => {
    if (current === null) return;
    if (current.scanCount === 0) {
      fail("ASSET.BAD_JPEG", `第 ${current.index + 1} 帧没有任何扫描（只有 SOF 没有 SOS）`);
    }
    current.restartInterval = restartInterval;
    current.adobeTransform = adobeTransform;

    const prev = frames.length > 0 ? frames[frames.length - 1]! : null;
    if (current.differential && prev === null) {
      fail("ASSET.BAD_JPEG", `第 1 帧就是差分帧（SOF0x${current.sof.toString(16)}），没有参考帧可以相减`);
    }
    // ★ EXP 必须真的被用上，否则它就是"解析了但没人读"的装饰：
    //   B.3.3 规定 Eh/Ev 是参考帧的放大倍数，而合成按**实际几何**（compW 之比）走。
    //   两者矛盾时只有两种可能：文件坏了，或我们对几何的理解错了 —— 两种都不该静默继续，
    //   否则画面会"糊得很自然"，而任何像素判据都以为那是正常的量化误差。
    const cur = current; // 闭包里不能依赖外层的 null 收窄（TS 会认为它又变回 null）
    if (cur.differential && prev !== null && cur.expansions.size > 0) {
      if (!expansionMatchesGeometry(prev, cur)) {
        const detail = [...cur.expansions]
          .map(([id, e]) => {
            const c = cur.components.find((x) => x.id === id);
            const p = prev.components.find((x) => x.id === id) ?? prev.components[0]!;
            const rw = c === undefined ? 0 : c.compW / p.compW;
            const rh = c === undefined ? 0 : c.compH / p.compH;
            return `${id}: EXP ${e.eh}×${e.ev} vs 几何 ${rw.toFixed(2)}×${rh.toFixed(2)}`;
          })
          .join("，");
        fail(
          "ASSET.BAD_JPEG",
          `分层 JPEG 的 EXP 放大因子与实际几何不一致（${detail}）` +
            "：按 T.81 B.3.3，Eh/Ev 必须等于参考帧到本帧的尺寸比",
        );
      }
    }
    buildFramePlanes(current);
    // ★ 差分合成必须在“平面已经建好”之后：差是**样本之差**（T.81 J.1.1），
    //   有损帧还要减掉电平位移。放到 IDCT 之前做就只能对系数动手，那是另一套语义。
    if (current.differential && prev !== null) {
      addReferencePlanes(current, prev);
    }
    frames.push(current);
    current = null;
  };

  let pos = 2;
  while (pos + 1 < bytes.length) {
    if (bytes[pos] !== 0xff) {
      // 标记之间不该有垃圾；容忍并跳过（有些编码器会在 EOI 后追加数据）
      pos++;
      continue;
    }
    const marker = bytes[pos + 1]!;
    if (marker === 0xff) {
      pos++;
      continue;
    }
    if (marker === MARKER_EOI) {
      sawEoi = true;
      break;
    }
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd8)) {
      // TEM / RSTn / SOI：无长度的独立标记
      pos += 2;
      continue;
    }
    if (pos + 4 > bytes.length) {
      fail("ASSET.BAD_JPEG", `段 0x${marker.toString(16)} 的头被截断（偏移 ${pos}）`);
    }
    const segLen = u16be(bytes, pos + 2);
    if (segLen < 2) fail("ASSET.BAD_JPEG", `段 0x${marker.toString(16)} 长度非法：${segLen}`);
    const dataStart = pos + 4;
    const dataLen = segLen - 2;
    if (dataStart + dataLen > bytes.length) {
      fail(
        "ASSET.BAD_JPEG",
        `段 0x${marker.toString(16)} 声明 ${dataLen} 字节数据，但文件只剩 ${bytes.length - dataStart} 字节`,
      );
    }
    const seg = bytes.subarray(dataStart, dataStart + dataLen);

    // SOF：0xC0..0xCF 去掉 DHT(0xC4) / JPG(0xC8) / DAC(0xCC)
    if (marker >= 0xc0 && marker <= 0xcf && marker !== MARKER_DHT && marker !== 0xc8 && marker !== MARKER_DAC) {
      finishFrame();
      current = parseSof(seg, marker, frames.length, maxPixels);
      if (pendingExp.size > 0) {
        current.expansions = pendingExp;
        const first = pendingExp.values().next();
        if (!first.done) {
          current.expandH = first.value.eh;
          current.expandV = first.value.ev;
        }
        pendingExp = new Map();
      }
      if (sequenceHeader !== null) {
        if (current.precision !== sequenceHeader.precision) {
          fail(
            "ASSET.BAD_JPEG",
            `分层序列的精度不一致：DHP 声明 ${sequenceHeader.precision} 位，第 ${frames.length + 1} 帧是 ${current.precision} 位` +
              "（T.81 B.3.1 要求所有帧的精度与 DHP 相同）",
          );
        }
        if (current.width > sequenceHeader.width || current.height > sequenceHeader.height) {
          fail(
            "ASSET.BAD_JPEG",
            `第 ${frames.length + 1} 帧尺寸 ${current.width}x${current.height} 超过 DHP 声明的 ` +
              `${sequenceHeader.width}x${sequenceHeader.height}（DHP 是完成态图像尺寸，各帧不得超出）`,
          );
        }
      }
      current.qt = qt;
      current.dcTables = dcTables;
      current.acTables = acTables;
      current.dcCond = dcCond;
      current.acCond = acCond;
      pos = dataStart + dataLen;
      continue;
    }

    switch (marker) {
      case MARKER_DQT:
        parseDqt(seg, qt);
        break;
      case MARKER_DHT:
        parseDht(seg, dcTables, acTables);
        break;
      case MARKER_DAC:
        parseDac(seg, dcCond, acCond);
        break;
      case MARKER_DRI:
        if (seg.length < 2) fail("ASSET.BAD_JPEG", "DRI 段长度不足");
        restartInterval = u16be(seg, 0);
        break;
      case MARKER_DHP: {
        // 分层：DHP 段体与帧头同结构（B.3.2），声明的是**完成态图像**的分量/尺寸/采样因子。
        // 它不是一帧（帧结构与非分层一致，第一帧仍有自己的 SOF），所以这里只留几何做校验。
        if (seg.length < 6) fail("ASSET.BAD_JPEG", "DHP 段长度不足（至少 6 字节：P/Y/X/Nf）");
        const nf = seg[5]!;
        if (nf < 1 || nf > 4) fail("ASSET.BAD_JPEG", `DHP 声明了 ${nf} 个分量（1..4）`);
        if (seg.length < 6 + nf * 3) fail("ASSET.BAD_JPEG", "DHP 段被截断（分量列表不完整）");
        for (let i = 0; i < nf; i++) {
          // B.3.2：DHP 里的量化表选择器必须为 0（完成态不绑定具体表）
          const tq = seg[6 + i * 3 + 2]!;
          if (tq !== 0) fail("ASSET.BAD_JPEG", `DHP 第 ${i + 1} 个分量的量化表选择器应为 0，实际 ${tq}`);
        }
        sequenceHeader = { precision: seg[0]!, width: u16be(seg, 3), height: u16be(seg, 1) };
        hierarchical = true;
        if (frames.length > 0 || current !== null) {
          fail("ASSET.BAD_JPEG", "DHP 只能出现在第一帧之前（T.81 B.3.2 要求单个 DHP 且在最前）");
        }
        break;
      }
      case MARKER_EXP: {
        // 段体是 (Ci, (Eh<<4)|Ev) 的**重复**，一段里可以只声明部分分量（T.81 B.2.4.5）
        if (seg.length < 2) fail("ASSET.BAD_JPEG", "EXP 段长度不足（至少要 Ci 与 Eh/Ev 两个字节）");
        if (seg.length % 2 !== 0) {
          fail("ASSET.BAD_JPEG", `EXP 段体必须是 (分量 id, Eh/Ev) 的整组，实际 ${seg.length} 字节`);
        }
        // B.2.4.5：EXP 只对**下一个**帧头生效，因此它必须处在分层序列里（DHP 之后）。
        // 没有 DHP 就出现 EXP，意味着"放大一个不存在的参考帧" —— 静默忽略会让
        // 后续帧按错误的比例被合成（画面糊但不报错），所以这里必须拒绝。
        if (sequenceHeader === null) {
          fail("ASSET.BAD_JPEG", "EXP 出现在 DHP 之前：EXP 只对分层序列的下一帧生效，没有 DHP 就无从放大");
        }
        for (let i = 0; i + 1 < seg.length; i += 2) {
          const ci = seg[i]!;
          const eh = seg[i + 1]! >> 4;
          const ev = seg[i + 1]! & 15;
          if (eh < 1 || ev < 1 || eh > 4 || ev > 4) {
            fail("ASSET.BAD_JPEG", `分量 ${ci} 的 EXP 放大因子非法：${eh}×${ev}（规范范围 1..4）`);
          }
          pendingExp.set(ci, { eh, ev });
        }
        break;
      }
      case MARKER_APP0:
        // JFIF：不解析密度/缩略图，只确认它不是我们该拒绝的东西
        break;
      case MARKER_APP1:
        orientation = readExifOrientation(seg);
        break;
      case MARKER_APP14:
        // "Adobe" + version(2) + flags0(2) + flags1(2) + transform(1)
        if (seg.length >= 12 && seg[0] === 0x41 && seg[1] === 0x64 && seg[2] === 0x6f && seg[3] === 0x62) {
          adobeTransform = seg[11]!;
        }
        break;
      case MARKER_SOS: {
        if (current === null) fail("ASSET.BAD_JPEG", "SOS 出现在 SOF 之前（没有帧头就无从解码）");
        // 量化表在这一刻绑定：后定义的 DQT 不该影响已经解完的帧
        for (const c of current.components) {
          if (!current.lossless) c.qtTable = qt[c.tq] ?? null;
        }
        const next = decodeScanByMode(bytes, dataStart, dataLen, current, dcTables, acTables, restartInterval);
        current.scanCount++;
        scanCount++;
        pos = next;
        continue;
      }
      default:
        // 其余 APPn / COM / 未知块：跳过（JPEG 允许解码器忽略不认识的应用段）
        break;
    }
    pos = dataStart + dataLen;
  }

  finishFrame();
  if (frames.length === 0) fail("ASSET.BAD_JPEG", "没有找到 SOF 帧头");
  if (scanCount === 0) fail("ASSET.BAD_JPEG", "没有找到 SOS 扫描（文件只有头、没有像素数据）");
  // EXP 只对"下一个帧头"生效；文件结束时还挂着，说明它后面没有帧 —— 这条流是坏的，
  // 而不是"多写了一个无害的段"：它意味着最后一次放大被无声丢弃了。
  if (pendingExp.size > 0) {
    fail("ASSET.BAD_JPEG", "EXP 段之后没有帧头：放大因子无处生效（EXP 只对下一个帧头生效）");
  }

  const last = frames[frames.length - 1]!;
  return {
    frames,
    width: last.width,
    height: last.height,
    precision: last.precision,
    adobeTransform,
    orientation,
    sawEoi,
    scanCount,
    hierarchical: hierarchical || frames.length > 1,
  };
}

/**
 * 按"无损 / 算术 / 哈夫曼"分发。
 *
 * ★ 三者的扫描头参数语义不同（无损的 Ss 是预测器、Al 是 Pt），
 *   所以校验放在各自文件里；这里只做分发，避免主循环长出一棵 if 树。
 */
function decodeScanByMode(
  bytes: Uint8Array,
  dataStart: number,
  dataLen: number,
  frame: Frame,
  dcTables: Array<HuffTable | null>,
  acTables: Array<HuffTable | null>,
  restartInterval: number,
): number {
  if (frame.arithmetic) return decodeArithScan(bytes, dataStart, dataLen, frame, restartInterval);
  if (frame.lossless) return decodeLosslessScan(bytes, dataStart, dataLen, frame, dcTables, restartInterval);
  return decodeScan(bytes, dataStart, dataLen, frame, dcTables, acTables, restartInterval);
}

export function hex(b: Uint8Array, from: number, to: number): string {
  return Array.from(b.subarray(from, to), (x) => x.toString(16).padStart(2, "0")).join(" ");
}
