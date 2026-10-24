/**
 * L4 · JPEG 解码 · 扫描头与熵数据切分（三种熵编码共用）
 *
 * ★ 为什么单独抽出来：哈夫曼 / 算术 / 无损三条路径**读的是同一个 SOS 头**，
 *   但各自的 Ss/Se/Ah/Al 语义不同（无损模式 Ss 是预测器、Al 是 Pt）。
 *   如果每条路径各抄一份解析，第一次改"分量 id 匹配规则"时就会只改一处，
 *   于是某个模式悄悄解错而另外两个还正常 —— 这种错最难定位。
 */

import type { Component, Frame } from "./frame.ts";
import { fail } from "./types.ts";

export interface ScanHeader {
  readonly comps: Component[];
  /** 顺序/渐进：谱段起点；无损：预测器选择值 1..7。 */
  readonly ss: number;
  /** 顺序/渐进：谱段终点；无损：必须 0。 */
  readonly se: number;
  readonly ah: number;
  /** 顺序/渐进：逐次逼近低位；无损：点变换 Pt。 */
  readonly al: number;
  /** 熵数据起点（SOS 头之后）。 */
  readonly entropyStart: number;
}

/** 读 SOS 段头，绑定分量与表号。不做模式相关的合法性检查（那是各 scan-* 的事）。 */
export function readScanHeader(bytes: Uint8Array, dataStart: number, dataLen: number, frame: Frame): ScanHeader {
  if (dataLen < 1) fail("ASSET.BAD_JPEG", "SOS 段为空");
  const ns = bytes[dataStart]!;
  if (ns < 1 || ns > 4) fail("ASSET.BAD_JPEG", `SOS 声明了 ${ns} 个分量（1..4）`);
  if (dataLen < 1 + ns * 2 + 3) fail("ASSET.BAD_JPEG", "SOS 段被截断");
  const comps: Component[] = [];
  for (let i = 0; i < ns; i++) {
    const at = dataStart + 1 + i * 2;
    const id = bytes[at]!;
    const tables = bytes[at + 1]!;
    const c = frame.components.find((x) => x.id === id);
    if (c === undefined) {
      fail(
        "ASSET.BAD_JPEG",
        `SOS 引用了帧里不存在的分量 id=${id}（帧里是 ${frame.components.map((x) => x.id).join(",")}）`,
      );
    }
    c.td = tables >> 4;
    c.ta = tables & 15;
    if (c.td > 3 || c.ta > 3) fail("ASSET.BAD_JPEG", `分量 ${id} 的表号非法`);
    if (!comps.includes(c)) comps.push(c);
  }
  const at = dataStart + 1 + ns * 2;
  return {
    comps,
    ss: bytes[at]!,
    se: bytes[at + 1]!,
    ah: bytes[at + 2]! >> 4,
    al: bytes[at + 2]! & 15,
    entropyStart: dataStart + dataLen,
  };
}

export interface SplitRanges {
  readonly ranges: ReadonlyArray<readonly [number, number]>;
  /** 熵数据之后第一个标记的偏移（外层循环从这里继续）。 */
  readonly next: number;
}

/**
 * 把熵编码段按 RSTn 切成区间；返回值里的 `next` 是终止标记（下一个 SOS/EOI/其他段）的位置。
 * `FF 00` 是数据里的字面 0xFF，`FF FF` 是填充字节，两者都不是标记。
 */
export function splitEntropy(bytes: Uint8Array, start: number): SplitRanges {
  const ranges: Array<readonly [number, number]> = [];
  let segStart = start;
  let i = start;
  while (i + 1 < bytes.length) {
    if (bytes[i] !== 0xff) {
      i++;
      continue;
    }
    const m = bytes[i + 1]!;
    if (m === 0x00) {
      i += 2;
      continue;
    }
    if (m === 0xff) {
      i += 1;
      continue;
    }
    if (m >= 0xd0 && m <= 0xd7) {
      ranges.push([segStart, i]);
      i += 2;
      segStart = i;
      continue;
    }
    break;
  }
  ranges.push([segStart, i]);
  return { ranges, next: i };
}

/**
 * 校验"熵数据切出的区间数"与"DRI × MCU 数"是否自洽。
 *
 * ★ 这条检查值得单独存在：RST 标记缺失/多余时，DC 预测器会错位，
 *   解出的图不报错但会花 —— 与其让用户看到花屏再去猜原因，不如在这里点名。
 */
export function expectIntervals(found: number, restartInterval: number, totalMcus: number): void {
  const expected = restartInterval > 0 ? Math.ceil(totalMcus / restartInterval) : 1;
  if (found !== expected) {
    fail(
      "ASSET.BAD_JPEG",
      `重启区间数不符：熵数据里找到 ${found} 段，按 DRI=${restartInterval} 与 ${totalMcus} 个 MCU 应为 ${expected} 段` +
        "（RST 标记缺失/多余会让 DC 预测器错位，解出的图不会报错但会花）",
    );
  }
}

/** 一段扫描里 MCU 的几何。 */
export interface ScanGeometry {
  readonly interleaved: boolean;
  readonly mcusX: number;
  readonly mcusY: number;
  readonly totalMcus: number;
}

export function scanGeometry(frame: Frame, comps: readonly Component[], interleaved: boolean): ScanGeometry {
  if (interleaved) {
    const maxH = Math.max(...frame.components.map((c) => c.h));
    const maxV = Math.max(...frame.components.map((c) => c.v));
    if (frame.lossless) {
      // 无损模式的数据单元是**一个样本**，不是 8×8 块：MCU 网格按采样因子直接算
      const mcusX = Math.ceil(frame.width / maxH);
      const mcusY = Math.ceil(frame.height / maxV);
      return { interleaved, mcusX, mcusY, totalMcus: mcusX * mcusY };
    }
    const mcusX = Math.ceil(frame.width / (8 * maxH));
    const mcusY = Math.ceil(frame.height / (8 * maxV));
    return { interleaved, mcusX, mcusY, totalMcus: mcusX * mcusY };
  }
  const c = comps[0]!;
  return {
    interleaved,
    mcusX: c.blocksW,
    mcusY: c.blocksH,
    // 非交错扫描按"数据单元"遍历：有损是 8×8 块，无损是单个样本
    totalMcus: frame.lossless ? c.compW * c.compH : c.blocksW * c.blocksH,
  };
}
