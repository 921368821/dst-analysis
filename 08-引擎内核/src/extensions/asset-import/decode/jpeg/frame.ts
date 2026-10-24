/**
 * L4 · JPEG 解码 · 帧结构与过程分类
 *
 * ★ 这里只回答"文件声明了什么"：过程（SOF 标记）、精度、几何、分量、
 *   量化表、哈夫曼表、算术条件参数、重启间隔、点变换、放大因子。
 *   不回答"像素是什么" —— 那是 `scan-*` 与 `reconstruct` 的事。
 *
 * ★ 为什么 `parseSof` 可重复调用：分层 JPEG（DHP）一个文件里有多个 SOF，
 *   每帧有自己的精度/几何/表。把"帧"做成值对象、不持有全局状态，
 *   多帧与单帧走同一条代码路径 —— 否则分层分支会变成"另一套解码器"，
 *   而另一套解码器永远只有它自己的判据能测。
 */

import { HuffTable } from "./bits.ts";
import { ZIGZAG } from "./tables.ts";
import { fail } from "./types.ts";

// ------------------------------------------------------------------ 过程分类

/** SOF 标记 → 过程描述。含我们不实现的部分时也要能点名。 */
export const SOF_NAMES: Readonly<Record<number, string>> = {
  0xc0: "SOF0 基线顺序（Huffman）",
  0xc1: "SOF1 扩展顺序（Huffman）",
  0xc2: "SOF2 渐进（Huffman）",
  0xc3: "SOF3 无损（Huffman）",
  0xc5: "SOF5 差分顺序（Huffman）",
  0xc6: "SOF6 差分渐进（Huffman）",
  0xc7: "SOF7 差分无损（Huffman）",
  0xc9: "SOF9 扩展顺序（算术）",
  0xca: "SOF10 渐进（算术）",
  0xcb: "SOF11 无损（算术）",
  0xcd: "SOF13 差分顺序（算术）",
  0xce: "SOF14 差分渐进（算术）",
  0xcf: "SOF15 差分无损（算术）",
};

/** SOF 标记 → 是否算术编码。 */
function isArithmeticSof(sof: number): boolean {
  return sof === 0xc9 || sof === 0xca || sof === 0xcb || sof === 0xcd || sof === 0xce || sof === 0xcf;
}

/** SOF 标记 → 是否无损（无 DCT）。 */
function isLosslessSof(sof: number): boolean {
  return sof === 0xc3 || sof === 0xc7 || sof === 0xcb || sof === 0xcf;
}

/** SOF 标记 → 是否渐进。 */
function isProgressiveSof(sof: number): boolean {
  return sof === 0xc2 || sof === 0xc6 || sof === 0xca || sof === 0xce;
}

/**
 * SOF 标记 → 是否"差分帧"（分层 JPEG 里第 2..N 帧）。
 *
 * ★ 差分帧的样本是"与参考帧之差"，解码时要加上参考帧上采样后的样本。
 *   这一点没有外部实现可对照（libjpeg 对分层直接 `JERR_NOTIMPL`），
 *   语义按 T.81 A.2.3 的"样本域相减/相加"实现，见 `hierarchy.ts`。
 */
export function isDifferentialSof(sof: number): boolean {
  return sof === 0xc5 || sof === 0xc6 || sof === 0xc7 || sof === 0xcd || sof === 0xce || sof === 0xcf;
}

// ------------------------------------------------------------------ 帧结构

export interface Component {
  readonly id: number;
  readonly h: number;
  readonly v: number;
  readonly tq: number;
  /** 该分量的实际块列/行数（= ceil(compW/8)）。非交错扫描按这个遍历。 */
  blocksW: number;
  blocksH: number;
  /** 存储步长（按 MCU 对齐）：交错扫描会把块写在 mcuX*h 的位置上，可能超出 blocksW。 */
  strideBlocksW: number;
  strideBlocksH: number;
  /**
   * 反量化前的 DCT 系数，按块连续存放：块号*64 + 自然下标。
   *
   * ★ 无损帧不用系数（`lossless` 为 true 时长度 0）：
   *   给一张 4K 无损图分配 64 倍于样本量的 Int16 是纯粹的内存浪费，
   *   而"无损帧也走 DCT 数组"会让两条路径的边界变得模糊。
   */
  coefs: Int16Array;
  /** DC 差分预测值（DCT 帧）或上一采样预测值（无损帧）。每个扫描区间重置。 */
  pred: number;
  /** 上采样后的分量平面尺寸（= compW × compH）。 */
  compW: number;
  compH: number;
  td: number;
  ta: number;
  /**
   * 解码后的分量样本，恒为 16 位容器（值域 0..2^P-1）。
   *
   * ★ 为什么不分 8/16 位两条路径：12 位与无损（最大 16 位）本来就需要 16 位，
   *   而给 8 位单开一条 `Uint8Array` 路径只会让"颜色变换/上采样/输出"每个环节
   *   都要写两遍，且两遍之间的差异没人测。统一成 16 位，8 位图的进程内内存翻倍，
   *   换来的是一份实现、一份判据。
   */
  plane: Uint16Array | null;
  /**
   * 本次扫描实际引用的量化表（在 SOS 时绑定）。
   *
   * ★ 不能等到重建时再查 `frame.qt[c.tq]`：分层 JPEG 允许下一帧重新定义 DQT，
   *   那时上一帧的量化表已经被覆盖，重建出的上一帧会悄悄用错表 —— 而且不报错。
   */
  qtTable: Uint16Array | null;
}

export interface Frame {
  /** 在文件里的序号（0 起）。 */
  readonly index: number;
  readonly sof: number;
  readonly precision: number;
  readonly width: number;
  readonly height: number;
  readonly progressive: boolean;
  readonly lossless: boolean;
  readonly arithmetic: boolean;
  readonly differential: boolean;
  readonly components: Component[];
  /** 自然顺序的量化表（已去 zigzag）。 */
  qt: Array<Uint16Array | null>;
  dcTables: Array<HuffTable | null>;
  acTables: Array<HuffTable | null>;
  /** 算术编码的 DC 条件参数（DAC）：每表 L/U。缺省 L=0,U=1。 */
  dcCond: Array<{ l: number; u: number }>;
  /** 算术编码的 AC 条件参数（DAC）：每表 K。缺省 5。 */
  acCond: number[];
  restartInterval: number;
  scanCount: number;
  /** 点变换 Pt（无损模式的 Al；渐进式里是最后一次扫描的 Al）。 */
  pt: number;
  /**
   * EXP 声明的放大因子：**本帧各分量**在被后一帧当作参考时要放大的倍数。
   *
   * ★ 按分量存（不是每帧一个全局值）：EXP 段体是 `Ci, (Eh<<4)|Ev` 的重复，
   *   一段里可以只给部分分量。上一版把 `seg[0]`（分量 id）当成 Eh、
   *   `seg[1]`（Eh/Ev 打包字节）当成 Ev —— 单分量文件里恰好"不报错但全错"。
   */
  expansions: Map<number, { eh: number; ev: number }>;
  /** 便于上报/调试：第一个分量的放大因子（没有 EXP 时是 1,1）。 */
  expandH: number;
  expandV: number;
  /** Adobe APP14 的 transform（null = 没有 APP14）。0=RGB/CMYK, 1=YCbCr, 2=YCCK。 */
  adobeTransform: number | null;
}

export function u16be(b: Uint8Array, at: number): number {
  return (b[at]! << 8) | b[at + 1]!;
}

/** 读 APP1 里的 EXIF Orientation（0x0112）。读不到就返回 1（不猜）。 */
export function readExifOrientation(seg: Uint8Array): number {
  // 段数据以 "Exif\0\0" 开头，然后是 TIFF 头
  if (seg.length < 14) return 1;
  if (seg[0] !== 0x45 || seg[1] !== 0x78 || seg[2] !== 0x69 || seg[3] !== 0x66) return 1;
  const tiff = 6;
  const le = seg[tiff] === 0x49 && seg[tiff + 1] === 0x49;
  const be = seg[tiff] === 0x4d && seg[tiff + 1] === 0x4d;
  if (!le && !be) return 1;
  const rd16 = (at: number): number => (le ? seg[at]! | (seg[at + 1]! << 8) : (seg[at]! << 8) | seg[at + 1]!);
  const rd32 = (at: number): number =>
    le
      ? (seg[at]! | (seg[at + 1]! << 8) | (seg[at + 2]! << 16) | (seg[at + 3]! << 24)) >>> 0
      : ((seg[at]! << 24) | (seg[at + 1]! << 16) | (seg[at + 2]! << 8) | seg[at + 3]!) >>> 0;
  const ifd0 = tiff + rd32(tiff + 4);
  if (ifd0 + 2 > seg.length) return 1;
  const count = rd16(ifd0);
  for (let i = 0; i < count; i++) {
    const entry = ifd0 + 2 + i * 12;
    if (entry + 12 > seg.length) return 1;
    if (rd16(entry) === 0x0112) {
      const v = rd16(entry + 8);
      return v >= 1 && v <= 8 ? v : 1;
    }
  }
  return 1;
}

/**
 * SOF 标记 + 精度 → 这个解码器能不能解。
 *
 * ★ 为什么单独导出：**导入器也要用同一条规则**。
 *   以前导入器自己维护一张"不支持的 SOF"清单，解码器支持了算术/无损之后，
 *   清单没跟着改 —— 结果是"解码器能解、导入器在门口就拦下"，
 *   下游永远吃不到新能力，而两边的测试各自都是绿的。
 *   规则只能有一份，两个调用点都从这里取。
 *
 * ★ 精度规则（按 T.81 B.2.2）：
 *   · DCT 类过程（顺序/渐进/差分）：P 只允许 8 或 12。
 *     —— 基线（SOF0）严格只能 8，但我们不把它当作拒绝理由：
 *     现实里有编码器把 12 位图写成 SOF0，拒绝它对用户没有价值；
 *     真正的判据是"12 位的 DCT 数学"有没有实现，而不是标记是 C0 还是 C1。
 *   · 无损类过程：P 允许 2..16（DICOM 的 16 位无损就是 P=16）。
 *   · 其余精度一律拒绝并写清实际值 —— "不支持 12 bit"这种话必须能被搜到。
 */
export interface ProcessSupport {
  readonly ok: boolean;
  /** `ok === false` 时给出人读原因（含实际位数），调用方原样透出。 */
  readonly reason?: string;
}

export function checkProcessSupport(sof: number, precision: number): ProcessSupport {
  const name = SOF_NAMES[sof];
  if (name === undefined) return { ok: false, reason: `未知的 SOF 标记 0x${sof.toString(16)}` };
  if (isLosslessSof(sof)) {
    if (precision < 2 || precision > 16) {
      return { ok: false, reason: `${name}：样本精度必须是 2..16，文件声明 ${precision} bit` };
    }
  } else if (precision !== 8 && precision !== 12) {
    return { ok: false, reason: `${name}：DCT 过程的样本精度只支持 8 或 12 bit，文件声明 ${precision} bit` };
  }
  return { ok: true };
}

/**
 * 解析 SOF 段，产出一帧的几何与分量。精度规则见 `checkProcessSupport`。
 */
export function parseSof(seg: Uint8Array, sof: number, index: number, maxPixels: number): Frame {
  if (seg.length < 6) fail("ASSET.BAD_JPEG", "SOF 段长度不足");
  const precision = seg[0]!;
  const height = u16be(seg, 1);
  const width = u16be(seg, 3);
  const n = seg[5]!;
  const lossless = isLosslessSof(sof);
  const support = checkProcessSupport(sof, precision);
  if (!support.ok) fail("ASSET.UNSUPPORTED_JPEG", support.reason ?? "不支持的 JPEG 过程", { precision, sof });

  if (width === 0 || height === 0) {
    // height=0 表示高度在 DNL 段里 —— 极少见，明确拒绝好过解出 0 行
    fail("ASSET.BAD_JPEG", `SOF 的宽高必须非 0，实际 ${width}×${height}（高度在 DNL 里的写法不支持）`);
  }
  if (width * height > maxPixels) {
    fail("ASSET.BAD_JPEG", `图像 ${width}×${height} 超过像素上限 ${maxPixels}`, { width, height, maxPixels });
  }
  if (n !== 1 && n !== 3 && n !== 4) {
    fail("ASSET.UNSUPPORTED_JPEG", `不支持 ${n} 个分量的 JPEG（支持 1 灰度 / 3 YCbCr-RGB / 4 CMYK-YCCK）`, {
      components: n,
    });
  }
  if (seg.length < 6 + n * 3) fail("ASSET.BAD_JPEG", `SOF 声明 ${n} 个分量，但段里只有 ${seg.length - 6} 字节`);

  let maxH = 1;
  let maxV = 1;
  const raw: Array<{ id: number; h: number; v: number; tq: number }> = [];
  for (let i = 0; i < n; i++) {
    const at = 6 + i * 3;
    const id = seg[at]!;
    const hv = seg[at + 1]!;
    const h = hv >> 4;
    const v = hv & 15;
    const tq = seg[at + 2]!;
    if (h < 1 || h > 4 || v < 1 || v > 4) {
      fail("ASSET.BAD_JPEG", `分量 ${id} 的采样因子 ${h}×${v} 非法（1..4）`);
    }
    if (tq > 3) fail("ASSET.BAD_JPEG", `分量 ${id} 引用了不存在的量化表 ${tq}`);
    raw.push({ id, h, v, tq });
    if (h > maxH) maxH = h;
    if (v > maxV) maxV = v;
  }

  const mcusX = Math.ceil(width / (8 * maxH));
  const mcusY = Math.ceil(height / (8 * maxV));
  const components: Component[] = raw.map((r) => {
    const compW = Math.ceil((width * r.h) / maxH);
    const compH = Math.ceil((height * r.v) / maxV);
    const blocksW = Math.ceil(compW / 8);
    const blocksH = Math.ceil(compH / 8);
    // 交错扫描时块坐标是 mcuX*h + bx，可能超出 blocksW（宽不是 MCU 整数倍时）
    const strideBlocksW = mcusX * r.h;
    const strideBlocksH = mcusY * r.v;
    return {
      id: r.id,
      h: r.h,
      v: r.v,
      tq: r.tq,
      blocksW,
      blocksH,
      strideBlocksW,
      strideBlocksH,
      // 无损帧不分配系数数组（长度 0），省下 64 倍内存
      coefs: lossless ? new Int16Array(0) : new Int16Array(strideBlocksW * strideBlocksH * 64),
      pred: 0,
      compW,
      compH,
      td: 0,
      ta: 0,
      plane: lossless ? new Uint16Array(compW * compH) : null,
      qtTable: null,
    };
  });

  return {
    index,
    sof,
    precision,
    width,
    height,
    progressive: isProgressiveSof(sof),
    lossless,
    arithmetic: isArithmeticSof(sof),
    differential: isDifferentialSof(sof),
    components,
    // 量化表/哈夫曼表由 parse 统一持有（一次文件可以有多张表、多趟扫描），
    // parseSof 只负责几何与分量，这里先占位，parse 紧接着替换成真实数组。
    qt: [],
    dcTables: [],
    acTables: [],
    dcCond: [],
    acCond: [],
    restartInterval: 0,
    scanCount: 0,
    pt: 0,
    expansions: new Map(),
    expandH: 1,
    expandV: 1,
    adobeTransform: null,
  };
}

export function parseDqt(seg: Uint8Array, qt: Array<Uint16Array | null>): void {
  let at = 0;
  while (at < seg.length) {
    const pq = seg[at]! >> 4;
    const tq = seg[at]! & 15;
    at++;
    if (tq > 3) fail("ASSET.BAD_JPEG", `DQT 表号 ${tq} 非法（0..3）`);
    const bytesPer = pq === 1 ? 2 : 1;
    if (at + 64 * bytesPer > seg.length) fail("ASSET.BAD_JPEG", "DQT 段被截断");
    const t = new Uint16Array(64);
    // 表里是按 zigzag 序写的，存成自然序：反量化时可以直接按自然下标乘
    for (let i = 0; i < 64; i++) {
      t[ZIGZAG[i]!] = bytesPer === 2 ? u16be(seg, at + i * 2) : seg[at + i]!;
    }
    qt[tq] = t;
    at += 64 * bytesPer;
  }
}

export function parseDht(seg: Uint8Array, dc: Array<HuffTable | null>, ac: Array<HuffTable | null>): void {
  let at = 0;
  while (at < seg.length) {
    if (at + 17 > seg.length) fail("ASSET.BAD_JPEG", "DHT 段被截断（表头不足 17 字节）");
    const tc = seg[at]! >> 4;
    const th = seg[at]! & 15;
    at++;
    if (tc > 1) fail("ASSET.BAD_JPEG", `DHT 表类型 ${tc} 非法（0=DC, 1=AC）`);
    if (th > 3) fail("ASSET.BAD_JPEG", `DHT 表号 ${th} 非法（0..3）`);
    const counts = seg.subarray(at, at + 16);
    at += 16;
    let total = 0;
    for (let i = 0; i < 16; i++) total += counts[i]!;
    if (at + total > seg.length) fail("ASSET.BAD_JPEG", "DHT 段被截断（符号数不足）");
    const values = seg.subarray(at, at + total);
    at += total;
    const table = new HuffTable(Uint8Array.from(counts), Uint8Array.from(values));
    if (tc === 0) dc[th] = table;
    else ac[th] = table;
  }
}

/**
 * 解析 DAC（算术编码条件参数，B.2.4.3）。
 *
 * ★ 一个字节里塞两个参数：低 4 位 L、高 4 位 U（DC 表），AC 表则是完整的 K。
 *   默认值 L=0 / U=1 / K=5 —— 这三个数不是"随便挑的"，它们是 T.81 规定的缺省值，
 *   不写 DAC 的文件必须按它们解码，否则第一位就错。
 */
export function parseDac(seg: Uint8Array, dcCond: Array<{ l: number; u: number }>, acCond: number[]): void {
  let at = 0;
  while (at + 2 <= seg.length) {
    const index = seg[at]!;
    const val = seg[at + 1]!;
    at += 2;
    if (index >= 0x10) {
      const t = index - 0x10;
      if (t > 3) fail("ASSET.BAD_JPEG", `DAC 的 AC 表号 ${t} 非法（0..3）`);
      acCond[t] = val;
    } else {
      if (index > 3) fail("ASSET.BAD_JPEG", `DAC 的 DC 表号 ${index} 非法（0..3）`);
      const l = val & 15;
      const u = val >> 4;
      // ★ 这里原来写的是 `if (l > 15 || u > 15)` —— 永远为假：两个值都是从 4 位字段
      //   取出来的，构造上就不可能超过 15。等于这条检查从来没生效过。
      //   T.81 D.2 真正的约束是 **L ≤ U**（libjpeg 的 jdarith.c 也按这个报错）：
      //   L > U 意味着"条件区间是空的"，解码器会建出一张永远不会被用到的统计表，
      //   之后每个 bin 都落到缺省路径 —— 图能解出来，但系数全错。
      if (l > u) fail("ASSET.BAD_JPEG", `DAC 的 DC 条件参数非法：L=${l} U=${u}（要求 L ≤ U）`);
      dcCond[index] = { l, u };
    }
  }
  if (at !== seg.length) fail("ASSET.BAD_JPEG", "DAC 段长度不是 2 的倍数（被截断）");
}
