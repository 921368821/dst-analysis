/**
 * 测试专用 JPEG 编码器 —— 只为给解码器造语料，不追求速度与体积。
 *
 * 为什么手写：Pillow/libjpeg 编不出 12 位、算术编码、无损、渐进的全部组合，
 * 而解码器要覆盖这些过程就必须有对应的合法文件。代价是得把 T.81 的位级规则
 * 重写一遍，所以注释只写「为什么这么选」，便于逐句对照规范排查。
 *
 * 约束：不依赖 src/（会随实现一起演化），纯自包含。
 *
 * 谁能验证什么（写在这里，省得下一个人重新猜）：
 *   · 8 位 SOF0/SOF1/SOF2/SOF3/SOF9/SOF10 都能被 Pillow（libjpeg-turbo）解码，
 *     有损模式的误差就是量化 + 色度降采样的量级，无损模式逐像素相等。
 *   · SOF11（算术无损）没有外部解码器：libjpeg-turbo 的 jdmaster.c 在
 *     lossless + arith_code 时直接 ERREXIT(JERR_ARITH_NOTIMPL)。
 *     它的可信度来自组合：算术引擎被 SOF9/SOF10 验证过，无损预测被 SOF3 验证过。
 *   · 12 位整条链路都没有外部解码器（Pillow 只编译了 8 位），只能做结构校验；
 *     SOF3/12 位无损另有一个独立的最小解码器可逐像素核对。
 */

export type JpegMode =
  | "baseline" // SOF0 哈夫曼顺序式
  | "progressive" // SOF2 哈夫曼渐进式（两趟：Ah=0,Al=1 然后 Ah=1,Al=0）
  | "lossless" // SOF3 哈夫曼无损
  | "arith-sequential" // SOF9 算术顺序式
  | "arith-progressive" // SOF10 算术渐进式（同上两趟）
  | "arith-lossless" // SOF11 算术无损
  | "hier-sequential" // DHP + SOF1(1/2 分辨率) + EXP + SOF5（差分帧）
  | "hier-lossless" // DHP + SOF3(1/2 分辨率) + EXP + SOF7（差分无损）
  | "hier-arith-sequential" // DHP + SOF9(1/2) + EXP + SOF13（算术差分帧）
  | "hier-arith-lossless" // DHP + SOF11(1/2) + EXP + SOF15（算术差分无损）
  | "hier-progressive" // DHP + SOF1(1/2) + EXP + SOF6（差分帧用渐进编码）
  | "hier-arith-progressive"; // DHP + SOF9(1/2) + EXP + SOF14（算术差分渐进）

export interface EncodeSpec {
  readonly width: number;
  readonly height: number;
  /**
   * 分量数。
   *
   * ★ 4 分量时 `samples` 是 **反相 CMYK**（也就是 Adobe 在文件里存的那四个数：
   *   `maxval-C, maxval-M, maxval-Y, maxval-K`），不是"打印用的 CMYK"。
   *   这样编码器不需要做任何颜色空间转换就能产出与真实 4 分量文件同构的样本；
   *   解码端 `reconstruct.ts` 的 `n===4` 分支也正好按这个约定把像素合回 RGB。
   */
  readonly components: 1 | 3 | 4; // 灰度 / RGB(内部转 YCbCr) / 反相 CMYK
  readonly precision: 8 | 12;
  readonly mode: JpegMode;
  /**
   * 4 分量时写 APP14(Adobe) 并声明颜色变换：0 = CMYK 直通，2 = YCCK。
   *
   * 不写 APP14 的 4 分量流在真实世界几乎不存在（解码器无法判断是 CMYK 还是 YCCK），
   * 而"transform=2 时前三个平面要先转 YCbCr"正是 4 分量实现最容易漏的一步。
   */
  readonly adobeTransform?: 0 | 2;
  /**
   * DRI 区间长度（MCU 数），0/undefined = 不用重启。
   *
   * 无损模式（SOF3/SOF11）额外要求它是**行宽的整数倍**，否则直接抛错：
   * libjpeg 的 jddiffct.c / jclossls.c 在 start_pass 里 ERREXIT，非整数倍的流
   * 没有任何外部解码器能验证（详见 predictSample 的注释）。
   */
  readonly restart?: number;
  readonly predictor?: number; // 无损模式的预测器 1..7，默认 1
  readonly pointTransform?: number; // Pt，无损模式默认 0
  readonly quality?: number; // 有损模式 1..100，默认 90
  readonly subsampling?: "444" | "420" | "422"; // 默认 "444"
  /**
   * 写 DAC 段（DC L=0 U=1 / AC K=5）。默认不写。
   *
   * 为什么不写也能解码：这组值就是 T.81/libjpeg 的默认条件（jcmarker.c 只在
   * 非默认值时才 emit DAC），libjpeg 的算术解码器缺省按同一组值建统计桶。
   * 需要专门测「DAC 段存在」这条路径时传 true。
   */
  readonly dac?: boolean;
}

// ------------------------------------------------------------------ 基础工具

/** zigzag 扫描序 → 自然（行主序）下标。与解码端的表必须逐项一致。 */
const ZIGZAG: readonly number[] = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27,
  20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58,
  59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

function clampInt(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

/** 幅值类别（F.12 的 size）：0 单独处理，其余是 |v| 的二进制位数。 */
function magcat(v: number): number {
  let a = v < 0 ? -v : v;
  let n = 0;
  while (a !== 0) {
    a >>= 1;
    n++;
  }
  return n;
}

class ByteWriter {
  private buf: Uint8Array = new Uint8Array(4096);
  private len = 0;

  private ensure(n: number): void {
    if (this.len + n <= this.buf.length) return;
    let cap = this.buf.length * 2;
    while (cap < this.len + n) cap *= 2;
    const next = new Uint8Array(cap);
    next.set(this.buf.subarray(0, this.len));
    this.buf = next;
  }

  byte(b: number): void {
    this.ensure(1);
    this.buf[this.len++] = b & 0xff;
  }

  u16(v: number): void {
    this.byte(v >> 8);
    this.byte(v);
  }

  marker(m: number): void {
    this.byte(0xff);
    this.byte(m);
  }

  bytes(v: readonly number[]): void {
    for (const b of v) this.byte(b);
  }

  take(): Uint8Array {
    return this.buf.slice(0, this.len);
  }
}

/**
 * 熵数据位写入器。
 *
 * ★ 每个 0xFF 输出后立即补 0x00（byte stuffing），所以调用方永远只写裸位。
 *   重启/扫描结束时补 **1** 位到字节边界：libjpeg 也补 1，补 0 会让
 *   「文件被截断」与「合法填充」在解码端难以区分（位读取器补 0 时尤其明显）。
 */
class BitWriter {
  private acc = 0;
  private nbits = 0;
  private readonly out: ByteWriter;

  constructor(out: ByteWriter) {
    this.out = out;
  }

  bit(b: number): void {
    this.acc = (this.acc << 1) | (b & 1);
    this.nbits++;
    if (this.nbits === 8) {
      const v = this.acc & 0xff;
      this.out.byte(v);
      if (v === 0xff) this.out.byte(0x00);
      this.acc = 0;
      this.nbits = 0;
    }
  }

  bits(v: number, n: number): void {
    for (let i = n - 1; i >= 0; i--) this.bit((v >>> i) & 1);
  }

  align(): void {
    while (this.nbits !== 0) this.bit(1);
  }
}

// ------------------------------------------------------------------ 标准表

/** Annex K.1 亮度量化表（自然序）。 */
const QUANT_LUMA: readonly number[] = [
  16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
  14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113,
  92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];

/** Annex K.1 色度量化表（自然序）。 */
const QUANT_CHROMA: readonly number[] = [
  17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
  47, 66, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
];

/** Annex K.3 四张标准哈夫曼表。解码器就按这些表建表，编码端直接用同一份。 */
const DC_LUMA_BITS: readonly number[] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const DC_CHROMA_BITS: readonly number[] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const AC_LUMA_BITS: readonly number[] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 125];
const AC_CHROMA_BITS: readonly number[] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 119];

const DC_LUMA_VALS: readonly number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const DC_CHROMA_VALS: readonly number[] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

const AC_LUMA_VALS: readonly number[] = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
  0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
  0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
  0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
  0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
  0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
  0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];

const AC_CHROMA_VALS: readonly number[] = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
  0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
  0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
  0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
  0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
  0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
  0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
  0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
  0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
  0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];

/** symbol → (长度 << 16) | 码字。查不到就是这张表编不了这个符号，必须报错而不是静默截断。 */
type HuffEnc = ReadonlyMap<number, number>;

interface HuffTableSpec {
  readonly bits: number[];
  readonly vals: number[];
  readonly codes: HuffEnc;
}

/**
 * 在 Annex K 表的基础上补齐缺失符号，全部挂到 16 位码的尾部。
 *
 * ★ 为什么不硬用 K 表：K 的 AC 表只有 0x00/0xF0 两个 size=0 符号，
 *   而渐进式的跨块 EOB 需要 0x10..0xE0；12 位的 DC 类别也会到 15（K 只到 11）。
 *   追加 16 位码不会改动任何已有码字（canonical 表在 16 位仍有大量空位），
 *   所以常见符号的码流与标准编码器逐位一致，只在用到扩展符号时才不同。
 */
function makeHuffTable(bits: readonly number[], vals: readonly number[], ensureUpTo: number): HuffTableSpec {
  const present = new Set(vals);
  const eb = bits.slice();
  const ev = vals.slice();
  let added = 0;
  for (let s = 0; s < ensureUpTo; s++) {
    if (!present.has(s)) {
      ev.push(s);
      added++;
    }
  }
  eb[15] = eb[15]! + added;
  return canonical(eb, ev);
}

function canonical(eb: readonly number[], ev: readonly number[]): HuffTableSpec {
  const map = new Map<number, number>();
  let code = 0;
  let p = 0;
  for (let len = 1; len <= 16; len++) {
    const n = eb[len - 1]!;
    for (let i = 0; i < n; i++) {
      if (code > 0xffff) throw new Error("JPEG 编码器：哈夫曼表构造溢出（码字超过 16 位）");
      map.set(ev[p++]!, (len << 16) | code);
      code++;
    }
    code <<= 1;
  }
  if (p !== ev.length) throw new Error("JPEG 编码器：哈夫曼表符号数与码长计数不一致");
  return { bits: eb.slice(), vals: ev.slice(), codes: map };
}

/**
 * AC 用「平表」：255 个符号 8 位、最后一个符号 9 位。
 *
 * ★ 为什么不用 Annex K：K 的 AC 表是**完备**的（Kraft 和 1 - 1/65536），
 *   没有空间再加 0x10..0xE0 这 14 个渐进式 EOBn 符号；而 EOBn 是跨块 EOBRUN 必需的。
 * ★ 为什么不是「128 个 7 位 + 128 个 8 位」：128 个 7 位码正好占满 7 位空间，
 *   再接 8 位码会得到 256 这种 9 位值（非法码字），解码端会从第一位就错。
 *   255 个 8 位码只占 8 位空间的 255/256，还剩一个 9 位码的位置给第 256 个符号。
 *   每个码长计数都 ≤ 255（DHT 的计数是单字节，256 写不进去）。
 *   代价只是体积，测试语料不关心。
 */
function makeFlatAcTable(): HuffTableSpec {
  const bits = new Array<number>(16).fill(0);
  bits[7] = 255;
  bits[8] = 1;
  const vals: number[] = [];
  for (let s = 0; s < 256; s++) vals.push(s);
  return canonical(bits, vals);
}

function emitHuff(bw: BitWriter, table: HuffEnc, sym: number): void {
  const v = table.get(sym);
  if (v === undefined) {
    throw new Error(
      `JPEG 编码器：哈夫曼表里没有符号 0x${sym.toString(16).padStart(2, "0")}（符号超出 0..255 或表被截断）`,
    );
  }
  bw.bits(v & 0xffff, v >>> 16);
}

/** 写 n 位有符号幅值（正数原样，负数按 F.12 取反）。 */
function writeSigned(bw: BitWriter, v: number, n: number): void {
  if (n === 0) return;
  bw.bits(v < 0 ? v + (1 << n) - 1 : v, n);
}

// ------------------------------------------------------------------ QM 算术编码器

/**
 * T.81 表 D.2 / 图 D.3 的 113 个概率状态 + 一个固定 0.5 桶（索引 113）。
 * 每项 [Qe, Next_Index_LPS, Next_Index_MPS, Switch_MPS]。
 * switch 折进 NLPS 的 0x80 位：编码时 (sv & 0x80) ^ nl 正好同时完成「换 MPS」与「换状态」。
 */
const QM_TABLE: ReadonlyArray<readonly [number, number, number, number]> = [
  [0x5a1d, 1, 1, 1], [0x2586, 14, 2, 0], [0x1114, 16, 3, 0], [0x080b, 18, 4, 0],
  [0x03d8, 20, 5, 0], [0x01da, 23, 6, 0], [0x00e5, 25, 7, 0], [0x006f, 28, 8, 0],
  [0x0036, 30, 9, 0], [0x001a, 33, 10, 0], [0x000d, 35, 11, 0], [0x0006, 9, 12, 0],
  [0x0003, 10, 13, 0], [0x0001, 12, 13, 0], [0x5a7f, 15, 15, 1], [0x3f25, 36, 16, 0],
  [0x2cf2, 38, 17, 0], [0x207c, 39, 18, 0], [0x17b9, 40, 19, 0], [0x1182, 42, 20, 0],
  [0x0cef, 43, 21, 0], [0x09a1, 45, 22, 0], [0x072f, 46, 23, 0], [0x055c, 48, 24, 0],
  [0x0406, 49, 25, 0], [0x0303, 51, 26, 0], [0x0240, 52, 27, 0], [0x01b1, 54, 28, 0],
  [0x0144, 56, 29, 0], [0x00f5, 57, 30, 0], [0x00b7, 59, 31, 0], [0x008a, 60, 32, 0],
  [0x0068, 62, 33, 0], [0x004e, 63, 34, 0], [0x003b, 32, 35, 0], [0x002c, 33, 9, 0],
  [0x5ae1, 37, 37, 1], [0x484c, 64, 38, 0], [0x3a0d, 65, 39, 0], [0x2ef1, 67, 40, 0],
  [0x261f, 68, 41, 0], [0x1f33, 69, 42, 0], [0x19a8, 70, 43, 0], [0x1518, 72, 44, 0],
  [0x1177, 73, 45, 0], [0x0e74, 74, 46, 0], [0x0bfb, 75, 47, 0], [0x09f8, 77, 48, 0],
  [0x0861, 78, 49, 0], [0x0706, 79, 50, 0], [0x05cd, 48, 51, 0], [0x04de, 50, 52, 0],
  [0x040f, 50, 53, 0], [0x0363, 51, 54, 0], [0x02d4, 52, 55, 0], [0x025c, 53, 56, 0],
  [0x01f8, 54, 57, 0], [0x01a4, 55, 58, 0], [0x0160, 56, 59, 0], [0x0125, 57, 60, 0],
  [0x00f6, 58, 61, 0], [0x00cb, 59, 62, 0], [0x00ab, 61, 63, 0], [0x008f, 61, 32, 0],
  [0x5b12, 65, 65, 1], [0x4d04, 80, 66, 0], [0x412c, 81, 67, 0], [0x37d8, 82, 68, 0],
  [0x2fe8, 83, 69, 0], [0x293c, 84, 70, 0], [0x2379, 86, 71, 0], [0x1edf, 87, 72, 0],
  [0x1aa9, 87, 73, 0], [0x174e, 72, 74, 0], [0x1424, 72, 75, 0], [0x119c, 74, 76, 0],
  [0x0f6b, 74, 77, 0], [0x0d51, 75, 78, 0], [0x0bb6, 77, 79, 0], [0x0a40, 77, 48, 0],
  [0x5832, 80, 81, 1], [0x4d1c, 88, 82, 0], [0x438e, 89, 83, 0], [0x3bdd, 90, 84, 0],
  [0x34ee, 91, 85, 0], [0x2eae, 92, 86, 0], [0x299a, 93, 87, 0], [0x2516, 86, 71, 0],
  [0x5570, 88, 89, 1], [0x4ca9, 95, 90, 0], [0x44d9, 96, 91, 0], [0x3e22, 97, 92, 0],
  [0x3824, 99, 93, 0], [0x32b4, 99, 94, 0], [0x2e17, 93, 86, 0], [0x56a8, 95, 96, 1],
  [0x4f46, 101, 97, 0], [0x47e5, 102, 98, 0], [0x41cf, 103, 99, 0], [0x3c3d, 104, 100, 0],
  [0x375e, 99, 93, 0], [0x5231, 105, 102, 0], [0x4c0f, 106, 103, 0], [0x4639, 107, 104, 0],
  [0x415e, 103, 99, 0], [0x5627, 105, 106, 1], [0x50e7, 108, 107, 0], [0x4b85, 109, 103, 0],
  [0x5597, 110, 109, 0], [0x504f, 111, 107, 0], [0x5a10, 110, 111, 1], [0x5522, 112, 109, 0],
  [0x59eb, 112, 111, 1], [0x5a1d, 113, 113, 0],
];

const QE = new Uint16Array(114);
const NMPS = new Uint8Array(114);
const NLPS = new Uint8Array(114);
for (let i = 0; i < 114; i++) {
  const row = QM_TABLE[i]!;
  QE[i] = row[0];
  NLPS[i] = row[1] | (row[3] !== 0 ? 0x80 : 0);
  NMPS[i] = row[2];
}

/**
 * 探针钩子：算术编码每次写一位时回调 `(统计区长度, 桶下标, 位值)`。
 *
 * ★ 只给测试用（生产路径下恒为 null）。它存在的理由是**定位算术解码错**：
 *   算术流没有码字边界，解错之后位流依然"合法"，靠看像素永远只能知道"错了"，
 *   不知道错在哪个桶。把编码端"打算写哪一位"与解码端"实际读了哪一位"逐项对齐，
 *   第一处 `桶号` 不同就是模型错，第一处 `值` 不同就是位流错位 —— 两者修法完全不同。
 */
export const arithTrace: { fn: ((kind: number, index: number, val: number) => void) | null } = {
  fn: null,
};

/** Annex D 图 D.3 的 QM 编码器，逐句对应规范里的 C 伪代码。 */
export class QmEncoder {
  private c = 0;
  private a = 0x10000;
  private sc = 0;
  private zc = 0;
  private ct = 11;
  private buffer = -1;
  private readonly out: ByteWriter;

  constructor(out: ByteWriter) {
    this.out = out;
  }

  private flushZeros(): void {
    while (this.zc > 0) {
      this.out.byte(0);
      this.zc--;
    }
  }

  /** 对应 C 版里 `if (--ct == 0) { ... }` 那段输出逻辑：sc/zc/buffer 是进位链的延迟队列。 */
  private drain(): void {
    const temp = this.c >>> 19;
    if (temp > 0xff) {
      if (this.buffer >= 0) {
        this.flushZeros();
        this.out.byte((this.buffer + 1) & 0xff);
        if (((this.buffer + 1) & 0xff) === 0xff) this.out.byte(0);
      }
      this.zc += this.sc;
      this.sc = 0;
      this.buffer = temp & 0xff;
    } else if (temp === 0xff) {
      this.sc++;
    } else {
      if (this.buffer === 0) this.zc++;
      else if (this.buffer >= 0) {
        this.flushZeros();
        this.out.byte(this.buffer);
      }
      if (this.sc !== 0) {
        this.flushZeros();
        do {
          this.out.byte(0xff);
          this.out.byte(0);
        } while (--this.sc !== 0);
      }
      this.buffer = temp & 0xff;
    }
    this.c &= 0x7ffff;
    this.ct += 8;
  }

  encode(stats: Int32Array, i: number, val: number): void {
    if (arithTrace.fn !== null) arithTrace.fn(stats.length, i, val);
    const sv = stats[i]!;
    const idx = sv & 0x7f;
    const qe = QE[idx]!;
    let a = this.a - qe;
    if (val !== (sv >> 7)) {
      if (a >= qe) {
        this.c = (this.c + a) >>> 0;
        a = qe;
      }
      stats[i] = (sv & 0x80) ^ NLPS[idx]!;
    } else {
      if (a >= 0x8000) {
        this.a = a;
        return;
      }
      if (a < qe) {
        this.c = (this.c + a) >>> 0;
        a = qe;
      }
      stats[i] = (sv & 0x80) ^ NMPS[idx]!;
    }
    this.a = a;
    do {
      this.a = (this.a << 1) >>> 0;
      this.c = (this.c << 1) >>> 0;
      if (--this.ct === 0) this.drain();
    } while (this.a < 0x8000);
  }

  /** Annex D.1.8 的冲洗：补齐到字节并把延迟队列全部落地。 */
  flush(): void {
    let temp = (((this.a - 1 + this.c) & 0xffff0000) >>> 0);
    this.c = temp < this.c ? (temp + 0x8000) >>> 0 : temp;
    this.c = (this.c << this.ct) >>> 0;
    if ((this.c & 0xf8000000) !== 0) {
      if (this.buffer >= 0) {
        this.flushZeros();
        this.out.byte((this.buffer + 1) & 0xff);
        if (((this.buffer + 1) & 0xff) === 0xff) this.out.byte(0);
      }
      this.zc += this.sc;
      this.sc = 0;
    } else {
      if (this.buffer === 0) this.zc++;
      else if (this.buffer >= 0) {
        this.flushZeros();
        this.out.byte(this.buffer);
      }
      if (this.sc !== 0) {
        this.flushZeros();
        do {
          this.out.byte(0xff);
          this.out.byte(0);
        } while (--this.sc !== 0);
      }
    }
    if ((this.c & 0x7fff800) !== 0) {
      this.flushZeros();
      const b1 = (this.c >>> 19) & 0xff;
      this.out.byte(b1);
      if (b1 === 0xff) this.out.byte(0);
      if ((this.c & 0x7f800) !== 0) {
        const b2 = (this.c >>> 11) & 0xff;
        this.out.byte(b2);
        if (b2 === 0xff) this.out.byte(0);
      }
    }
  }

  reset(): void {
    this.c = 0;
    this.a = 0x10000;
    this.sc = 0;
    this.zc = 0;
    this.ct = 11;
    this.buffer = -1;
  }
}

/**
 * 位级回环用的最小编码入口：一串 `(桶号, 位值)` → 一段算术码流。
 *
 * ★ 为什么需要它（而不是直接编一张图）：算术流没有码字边界，一旦模型表错
 *   （比如 Next_Index_LPS 漏了 Switch_MPS 位），错的是**状态机**而不是像素，
 *   表现为"大部分对、少数系数错"，而且位流依然合法。要钉住这种错，就得绕过
 *   JPEG 的块结构，只喂 bin：任何一位不同都会立刻在下一位露出。
 *   配对的解码端是 `QmDecoder`（生产实现），所以这条回环比的是
 *   "两个独立实现的 QM 状态机是否同解"，不是自己和自己比。
 */
export interface ArithBin {
  readonly ctx: number;
  readonly val: number;
}

export function encodeArithBins(
  bins: readonly ArithBin[],
  ctxCount: number,
): { readonly bytes: Uint8Array; readonly trace: readonly ArithBin[] } {
  const out = new ByteWriter();
  const enc = new QmEncoder(out);
  const stats = new Int32Array(ctxCount);
  const trace: ArithBin[] = [];
  arithTrace.fn = (kind, index, val) => {
    // kind 是桶数组长度，index 是桶号 —— 回环里两者都要对上
    if (kind !== ctxCount) throw new Error(`trace: 桶数 ${kind} != ${ctxCount}`);
    trace.push({ ctx: index, val });
  };
  try {
    for (const b of bins) enc.encode(stats, b.ctx, b.val);
  } finally {
    arithTrace.fn = null;
  }
  enc.flush();
  return { bytes: out.take(), trace };
}

// DAC 默认条件：DC 的 L=0/U=1，AC 的 K=5。dac:true 时把同样的值写进 DAC 段。
const ARITH_DC_L = 0;
const ARITH_DC_U = 1;
const ARITH_AC_K = 5;

// ------------------------------------------------------------------ 像素平面

interface Plane {
  readonly w: number;
  readonly h: number;
  readonly data: Uint16Array;
}

function boxDownsample(src: Plane, fx: number, fy: number): Plane {
  if (fx === 1 && fy === 1) return src;
  const w = Math.ceil(src.w / fx);
  const h = Math.ceil(src.h / fy);
  const data = new Uint16Array(w * h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let sum = 0;
      let cnt = 0;
      for (let dy = 0; dy < fy; dy++) {
        const sy = y * fy + dy;
        if (sy >= src.h) continue;
        for (let dx = 0; dx < fx; dx++) {
          const sx = x * fx + dx;
          if (sx >= src.w) continue;
          sum += src.data[sy * src.w + sx]!;
          cnt++;
        }
      }
      data[y * w + x] = Math.round(sum / cnt);
    }
  }
  return { w, h, data };
}

/**
 * 把交错样本拆成分量平面。
 *
 * ★ 3 分量按 JFIF 约定转 YCbCr：解码端（无论 libjpeg 还是我们自己的）都会
 *   按 JFIF/APP14 反变换回 RGB，所以「文件里是 YCbCr」是唯一能被外部工具核对的形式。
 *   代价是无损模式在 RGB 域不严格可逆（浮点矩阵有 ±1 舍入），无损性只在 YCbCr 域成立。
 */
function buildPlanes(samples: Uint16Array | Uint8Array, spec: EncodeSpec, lossless: boolean): Plane[] {
  const { width, height, precision } = spec;
  const n = width * height;
  const maxv = (1 << precision) - 1;
  const center = 1 << (precision - 1);
  if (spec.components === 1) {
    const data = new Uint16Array(n);
    for (let i = 0; i < n; i++) data[i] = samples[i]!;
    return [{ w: width, h: height, data }];
  }
  // 无损必须真的可逆：RGB→YCbCr 的浮点矩阵会引入 ±1 舍入，之后再解码就不是原图了。
  // libjpeg 对「无 JFIF/Adobe 标记、分量 id=1/2/3」的无损图按 RGB 解释（jdapimin.c），
  // 所以三分量无损直接存 R/G/B 平面，并在写段时省略 JFIF。
  if (lossless || spec.components === 4) {
    // 4 分量两种情况都走这里：
    //  · 无损：样本必须一位不差地进文件，任何颜色变换都会让"无损"变成谎话；
    //  · 有损 + transform=0（CMYK 直通）：文件里存的就是反相 CMY，不需要变换。
    // transform=2（YCCK）才需要把反相 CMY 当"RGB 三元组"转成 YCbCr，见下面的分支。
    const planes: Plane[] = [];
    for (let c = 0; c < spec.components; c++) {
      const data = new Uint16Array(n);
      for (let i = 0; i < n; i++) data[i] = samples[i * spec.components + c]!;
      planes.push({ w: width, h: height, data });
    }
    if (spec.components === 4 && spec.adobeTransform === 2) {
      // YCCK：前三个平面装的是**反相 CMY**，而文件的 Y/Cb/Cr 编码的是**墨量**，
      // 所以先反相（反相 CMY → 墨量），再做 RGB→YCbCr。第四平面（K）原样保留。
      //
      // ★ 这一步的"先反相"是拿 libjpeg 判出来的，不是抄文档：
      //   少了它，libjpeg 解出来的整幅图是反相的（白变黑，max=255），
      //   带上它则与 transform=0 的同图相差 ≤3。
      //   解码端 reconstruct.ts 的 ycck 分支严格做逆运算。
      const [p0, p1, p2] = planes as [Plane, Plane, Plane, Plane];
      for (let i = 0; i < n; i++) {
        const r = maxv - p0.data[i]!;
        const g = maxv - p1.data[i]!;
        const b = maxv - p2.data[i]!;
        p0.data[i] = clampInt(Math.round(0.299 * r + 0.587 * g + 0.114 * b), 0, maxv);
        p1.data[i] = clampInt(Math.round(-0.168736 * r - 0.331264 * g + 0.5 * b + center), 0, maxv);
        p2.data[i] = clampInt(Math.round(0.5 * r - 0.418688 * g - 0.081312 * b + center), 0, maxv);
      }
    }
    return planes;
  }
  const yPlane = new Uint16Array(n);
  const cbPlane = new Uint16Array(n);
  const crPlane = new Uint16Array(n);
  for (let i = 0; i < n; i++) {
    const r = samples[i * 3]!;
    const g = samples[i * 3 + 1]!;
    const b = samples[i * 3 + 2]!;
    yPlane[i] = clampInt(Math.round(0.299 * r + 0.587 * g + 0.114 * b), 0, maxv);
    cbPlane[i] = clampInt(Math.round(-0.168736 * r - 0.331264 * g + 0.5 * b + center), 0, maxv);
    crPlane[i] = clampInt(Math.round(0.5 * r - 0.418688 * g - 0.081312 * b + center), 0, maxv);
  }
  const sub = lossless ? "444" : (spec.subsampling ?? "444");
  const fx = sub === "444" ? 1 : 2;
  const fy = sub === "420" ? 2 : 1;
  const y = { w: width, h: height, data: yPlane };
  const cb = boxDownsample({ w: width, h: height, data: cbPlane }, fx, fy);
  const cr = boxDownsample({ w: width, h: height, data: crPlane }, fx, fy);
  return [y, cb, cr];
}

interface Comp {
  id: number;
  h: number;
  v: number;
  tq: number;
  td: number;
  ta: number;
  w: number;
  hgt: number;
  blocksW: number;
  blocksH: number;
  strideW: number;
  strideH: number;
  sample: Uint16Array;
  coef: Int32Array;
  pred: number;
  dcCtx: number;
}

function samplingFactors(mode: "444" | "420" | "422"): ReadonlyArray<readonly [number, number]> {
  if (mode === "420") return [[2, 2], [1, 1], [1, 1]];
  if (mode === "422") return [[2, 1], [1, 1], [1, 1]];
  return [[1, 1], [1, 1], [1, 1]];
}

function buildComps(planes: readonly Plane[], spec: EncodeSpec, lossless: boolean): Comp[] {
  const sub = lossless ? "444" : (spec.subsampling ?? "444");
  // 4 分量（CMYK/YCCK）不采样：libjpeg 的 jcparam.c 在 JCS_CMYK/JCS_YCCK 下把四个
  // 分量的采样因子都设成 1×1（不像 YCbCr 那样给亮度 2×2）。照它的取值写，
  // 才能用"Pillow 解同一个文件"当外部金标，而不是拿我们的假设去核我们的假设。
  const factors =
    spec.components === 1
      ? [[1, 1] as const]
      : spec.components === 4
        ? [
            [1, 1] as const,
            [1, 1] as const,
            [1, 1] as const,
            [1, 1] as const,
          ]
        : samplingFactors(sub);
  let maxH = 1;
  let maxV = 1;
  for (const f of factors) {
    if (f[0] > maxH) maxH = f[0];
    if (f[1] > maxV) maxV = f[1];
  }
  const mcusX = Math.ceil(spec.width / (8 * maxH));
  const mcusY = Math.ceil(spec.height / (8 * maxV));
  return planes.map((p, i) => {
    const f = factors[i]!;
    const strideW = mcusX * f[0];
    const strideH = mcusY * f[1];
    return {
      /**
       * 分量 id。
       *
       * ★ 三分量**无损**必须写成 ASCII 'R','G','B'（0x52/0x47/0x42）：
       *   无损存的是原样本而不是 YCbCr，如果沿用 1/2/3，按 T.81 与 libjpeg
       *   `default_decompress_parms` 的规则会被解释成 YCbCr（"JFIF wannabee"），
       *   解码端就会对一串 RGB 样本做 YCbCr→RGB，得到偏色图。
       *   规范留的出口就是这三个 id —— libjpeg 认得，我们的解码器也认得
       *   （`reconstruct.ts` 的 `rgbDirect`）。有 JFIF/APP14 的 DCT 图仍用 1/2/3。
       */
      id: lossless && spec.components === 3 ? [0x52, 0x47, 0x42][i]! : i + 1,
      h: f[0],
      v: f[1],
      tq: i === 0 ? 0 : 1,
      td: i === 0 ? 0 : 1,
      ta: i === 0 ? 0 : 1,
      w: p.w,
      hgt: p.h,
      blocksW: Math.ceil(p.w / 8),
      blocksH: Math.ceil(p.h / 8),
      strideW,
      strideH,
      sample: p.data,
      coef: lossless ? new Int32Array(0) : new Int32Array(strideW * strideH * 64),
      pred: 0,
      dcCtx: 0,
    };
  });
}

// ------------------------------------------------------------------ DCT

/** 与解码端同一套基：COS[u*8+x] = C(u)cos((2x+1)uπ/16)/2，行/列各乘一次正好是 1/4。 */
const COS_T = (() => {
  const t = new Float64Array(64);
  for (let u = 0; u < 8; u++) {
    for (let x = 0; x < 8; x++) {
      t[u * 8 + x] = ((u === 0 ? Math.SQRT1_2 : 1) * Math.cos(((2 * x + 1) * u * Math.PI) / 16)) / 2;
    }
  }
  return t;
})();

function fdct(src: Float64Array, tmp: Float64Array, dst: Float64Array): void {
  for (let y = 0; y < 8; y++) {
    for (let u = 0; u < 8; u++) {
      let s = 0;
      for (let x = 0; x < 8; x++) s += src[y * 8 + x]! * COS_T[u * 8 + x]!;
      tmp[y * 8 + u] = s;
    }
  }
  for (let u = 0; u < 8; u++) {
    for (let v = 0; v < 8; v++) {
      let s = 0;
      for (let y = 0; y < 8; y++) s += tmp[y * 8 + u]! * COS_T[v * 8 + y]!;
      dst[v * 8 + u] = s;
    }
  }
}

function fillCoefficients(comps: readonly Comp[], qt: readonly Uint16Array[], precision: number): void {
  const center = 1 << (precision - 1);
  const src = new Float64Array(64);
  const tmp = new Float64Array(64);
  const freq = new Float64Array(64);
  for (const c of comps) {
    const q = qt[c.tq]!;
    for (let by = 0; by < c.blocksH; by++) {
      for (let bx = 0; bx < c.blocksW; bx++) {
        for (let y = 0; y < 8; y++) {
          const sy = Math.min(by * 8 + y, c.hgt - 1);
          for (let x = 0; x < 8; x++) {
            const sx = Math.min(bx * 8 + x, c.w - 1);
            src[y * 8 + x] = c.sample[sy * c.w + sx]! - center;
          }
        }
        fdct(src, tmp, freq);
        const bo = (by * c.strideW + bx) * 64;
        for (let i = 0; i < 64; i++) c.coef[bo + i] = Math.round(freq[i]! / q[i]!);
      }
    }
  }
}

function scaledQuant(base: readonly number[], quality: number): Uint16Array {
  const q = clampInt(Math.round(quality), 1, 100);
  const scale = q < 50 ? 5000 / q : 200 - 2 * q;
  const out = new Uint16Array(64);
  for (let i = 0; i < 64; i++) out[i] = clampInt(Math.floor((base[i]! * scale + 50) / 100), 1, 255);
  return out;
}

// ------------------------------------------------------------------ 无损预测

/**
 * 无损预测（T.81 H.1.2.1）。
 *
 * 前两行邻居的取值规则（与 jdlossls.c 的 INITIAL_PREDICTORx / INITIAL_PREDICTOR2
 * 一一对应）：
 *   · 一行（或一个重启区间）的第一个样本：2^(P-Pt-1)。行首、区间首都是这个值，
 *     因为此时"上一行"要么不存在，要么按规范视为不存在。
 *   · 该行其余样本只用左邻居 Ra（预测器 1）—— 上一行还没进来。
 *   · 之后的行：列 0 用 Rb，其余用扫描头里的预测器。
 *
 * ★ 为什么重启区间也算"第一行"：libjpeg 的压缩与解压两侧（jclossls.c 的
 *   reset_predictor、jddiffct.c 的 process_restart → start_pass）都在每个区间
 *   开头把预测器复位成"首行"，并且强迫 restart_interval 是 MCUs_per_row 的整数倍。
 *   不跟着复位，Pillow 解出来的每个区间首像素都会错；跟着复位，row-aligned 的
 *   文件能被逐像素验证。这是唯一有外部解码器可验证的口径。
 *
 * ★ 为什么**不**把 P4/P5/P6 的结果 clamp 进 [0, 2^P-1]：
 *   解码端的重建是 `Ra = (pred + diff) & 0xFFFF`（jdlossls.c 的 UNDIFFERENCE 宏，
 *   注释明写"计算模 2^16"），不是钳位。第一版在这里 clamp 了，
 *   Pillow 解 P4 时 max 差 3、P5/P6 也错 —— 因为 `(pred + (s - clamp(pred)))`
 *   和 `s` 只在不 clamp 时才相等。所以 pred 允许越界，让差分把它带回范围内。
 */
function predictSample(
  c: Comp,
  x: number,
  y: number,
  precAfterPt: number,
  predictor: number,
  firstRowOfInterval: boolean,
): number {
  const w = c.w;
  const s = c.sample;
  if (x === 0) return firstRowOfInterval ? 1 << (precAfterPt - 1) : s[(y - 1) * w]!;
  if (firstRowOfInterval) return s[y * w + x - 1]!;
  const ra = s[y * w + x - 1]!;
  const rb = s[(y - 1) * w + x]!;
  const rc = s[(y - 1) * w + x - 1]!;
  switch (predictor) {
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
      return ra;
  }
}

// ------------------------------------------------------------------ 段写出

function writeApp0(out: ByteWriter): void {
  out.marker(0xe0);
  out.u16(16);
  out.bytes([0x4a, 0x46, 0x49, 0x46, 0x00]);
  out.byte(1);
  out.byte(1);
  out.byte(0);
  out.u16(1);
  out.u16(1);
  out.byte(0);
  out.byte(0);
}

/**
 * APP14(Adobe)：4 分量文件靠它区分 CMYK（transform=0）与 YCCK（transform=2）。
 * 结构与 libjpeg 的 emit_adobe_app14 一致（"Adobe" + 版本 100 + flags0/1 + transform）。
 */
function writeApp14(out: ByteWriter, transform: number): void {
  out.marker(0xee);
  out.u16(14);
  out.bytes([0x41, 0x64, 0x6f, 0x62, 0x65]); // "Adobe"
  out.u16(100); // version
  out.u16(0); // flags0
  out.u16(0); // flags1
  out.byte(transform); // 0 = CMYK, 2 = YCCK
}

function writeDqt(out: ByteWriter, tables: readonly Uint16Array[]): void {
  out.marker(0xdb);
  out.u16(2 + tables.length * 65);
  for (let t = 0; t < tables.length; t++) {
    out.byte(t); // Pq=0, Tq=t：标准表最大 121，缩放后仍 < 256，8 位就够
    const q = tables[t]!;
    for (let i = 0; i < 64; i++) out.byte(q[ZIGZAG[i]!]!);
  }
}

function writeDht(out: ByteWriter, entries: ReadonlyArray<readonly [number, number, readonly number[], readonly number[]]>): void {
  let len = 2;
  for (const e of entries) len += 1 + 16 + e[3].length;
  out.marker(0xc4);
  out.u16(len);
  for (const e of entries) {
    out.byte((e[0] << 4) | e[1]);
    for (let i = 0; i < 16; i++) out.byte(e[2][i]!);
    for (const v of e[3]) out.byte(v);
  }
}

function writeDac(out: ByteWriter, tables: ReadonlyArray<readonly [number, number, number]>): void {
  out.marker(0xcc);
  out.u16(2 + tables.length * 2);
  for (const t of tables) {
    out.byte((t[0] << 4) | t[1]);
    out.byte(t[2]);
  }
}

function writeSof(
  out: ByteWriter,
  marker: number,
  comps: readonly Comp[],
  precision: number,
  width: number,
  height: number,
): void {
  out.marker(marker);
  out.u16(8 + comps.length * 3);
  out.byte(precision);
  out.u16(height);
  out.u16(width);
  out.byte(comps.length);
  for (const c of comps) {
    out.byte(c.id);
    out.byte((c.h << 4) | c.v);
    out.byte(c.tq);
  }
}

function writeSos(
  out: ByteWriter,
  comps: readonly Comp[],
  ss: number,
  se: number,
  ah: number,
  al: number,
): void {
  out.marker(0xda);
  out.u16(6 + comps.length * 2);
  out.byte(comps.length);
  for (const c of comps) {
    out.byte(c.id);
    out.byte((c.td << 4) | c.ta);
  }
  out.byte(ss);
  out.byte(se);
  out.byte((ah << 4) | al);
}

// ------------------------------------------------------------------ 哈夫曼扫描

function restartMarker(bw: BitWriter, k: number, out: ByteWriter): void {
  bw.align();
  out.marker(0xd0 + (k % 8));
}

/** 顺序式单块：DC 差分 + AC 行程。 */
function encodeSeqBlock(
  bw: BitWriter,
  c: Comp,
  bo: number,
  dc: HuffEnc,
  ac: HuffEnc,
): void {
  const d = c.coef[bo]!;
  const diff = d - c.pred;
  c.pred = d;
  const cat = magcat(diff);
  emitHuff(bw, dc, cat);
  writeSigned(bw, diff, cat);

  let run = 0;
  for (let k = 1; k < 64; k++) {
    const v = c.coef[bo + ZIGZAG[k]!]!;
    if (v === 0) {
      run++;
      continue;
    }
    while (run > 15) {
      emitHuff(bw, ac, 0xf0);
      run -= 16;
    }
    const size = magcat(v);
    emitHuff(bw, ac, (run << 4) | size);
    writeSigned(bw, v, size);
    run = 0;
  }
  if (run > 0) emitHuff(bw, ac, 0x00);
}

function encodeSequentialHuffman(
  out: ByteWriter,
  comps: readonly Comp[],
  mcusX: number,
  mcusY: number,
  interval: number,
  dcTables: readonly HuffEnc[],
  acTables: readonly HuffEnc[],
): void {
  const bw = new BitWriter(out);
  const total = mcusX * mcusY;
  for (let m = 0; m < total; m++) {
    if (interval > 0 && m > 0 && m % interval === 0) {
      restartMarker(bw, m / interval - 1, out);
      for (const c of comps) c.pred = 0;
    }
    const mx = m % mcusX;
    const my = Math.floor(m / mcusX);
    for (const c of comps) {
      const dc = dcTables[c.td]!;
      const ac = acTables[c.ta]!;
      for (let vy = 0; vy < c.v; vy++) {
        for (let vx = 0; vx < c.h; vx++) {
          const bo = ((my * c.v + vy) * c.strideW + (mx * c.h + vx)) * 64;
          encodeSeqBlock(bw, c, bo, dc, ac);
        }
      }
    }
  }
  bw.align();
}

/** 渐进 AC 首扫的 EOB run：run 是「块数」，用 (1<<r)+extra 表示。 */
function emitEobRun(bw: BitWriter, ac: HuffEnc, run: number): void {
  let r = 0;
  while ((run >> (r + 1)) !== 0) r++;
  emitHuff(bw, ac, r << 4);
  if (r > 0) bw.bits(run - (1 << r), r);
}

function encodeProgressiveDcFirst(
  out: ByteWriter,
  comps: readonly Comp[],
  mcusX: number,
  mcusY: number,
  interval: number,
  al: number,
  dcTables: readonly HuffEnc[],
): void {
  const bw = new BitWriter(out);
  const total = mcusX * mcusY;
  for (let m = 0; m < total; m++) {
    if (interval > 0 && m > 0 && m % interval === 0) {
      restartMarker(bw, m / interval - 1, out);
      for (const c of comps) c.pred = 0;
    }
    const mx = m % mcusX;
    const my = Math.floor(m / mcusX);
    for (const c of comps) {
      const dc = dcTables[c.td]!;
      for (let vy = 0; vy < c.v; vy++) {
        for (let vx = 0; vx < c.h; vx++) {
          const bo = ((my * c.v + vy) * c.strideW + (mx * c.h + vx)) * 64;
          // DC 用算术右移：解码端是 `pred << Al`，之后用 OR 补低位；
          // 若这里用「向零截断」，负 DC 的低位会补错。
          const scaled = c.coef[bo]! >> al;
          const diff = scaled - c.pred;
          c.pred = scaled;
          const cat = magcat(diff);
          emitHuff(bw, dc, cat);
          writeSigned(bw, diff, cat);
        }
      }
    }
  }
  bw.align();
}

function encodeProgressiveDcRefine(
  out: ByteWriter,
  comps: readonly Comp[],
  mcusX: number,
  mcusY: number,
  interval: number,
  al: number,
): void {
  const bw = new BitWriter(out);
  const total = mcusX * mcusY;
  for (let m = 0; m < total; m++) {
    if (interval > 0 && m > 0 && m % interval === 0) restartMarker(bw, m / interval - 1, out);
    const mx = m % mcusX;
    const my = Math.floor(m / mcusX);
    for (const c of comps) {
      for (let vy = 0; vy < c.v; vy++) {
        for (let vx = 0; vx < c.h; vx++) {
          const bo = ((my * c.v + vy) * c.strideW + (mx * c.h + vx)) * 64;
          // 解码端是 `coef |= 1<<Al`，所以直接取幅值的第 Al 位（补码语义与 OR 一致）。
          bw.bit((c.coef[bo]! >> al) & 1);
        }
      }
    }
  }
  bw.align();
}

/** 渐进 AC 首扫（单分量）：截断到 Al 位后按行程编码，尾部 EOB 跨块合并。 */
function encodeProgressiveAcFirst(
  out: ByteWriter,
  c: Comp,
  interval: number,
  ss: number,
  se: number,
  al: number,
  ac: HuffEnc,
): void {
  const bw = new BitWriter(out);
  const total = c.blocksW * c.blocksH;
  let eobrun = 0;
  const flushEob = (): void => {
    if (eobrun === 0) return;
    emitEobRun(bw, ac, eobrun);
    eobrun = 0;
  };

  for (let m = 0; m < total; m++) {
    if (interval > 0 && m > 0 && m % interval === 0) {
      flushEob(); // EOBRUN 不能跨区间：解码端换区间时会清零
      restartMarker(bw, m / interval - 1, out);
    }
    const bx = m % c.blocksW;
    const by = Math.floor(m / c.blocksW);
    const bo = (by * c.strideW + bx) * 64;

    // 先找截断域里最后一个非零，决定是整块 EOB 还是编码到 ke
    let ke = 0;
    for (let k = ss; k <= se; k++) {
      const v = c.coef[bo + ZIGZAG[k]!]!;
      const t = v < 0 ? -((-v) >> al) : (v >> al);
      if (t !== 0) ke = k;
    }
    if (ke === 0) {
      eobrun++;
      if (eobrun === 0x7fff) flushEob();
      continue;
    }
    flushEob();

    let run = 0;
    for (let k = ss; k <= ke; k++) {
      const v = c.coef[bo + ZIGZAG[k]!]!;
      // AC 首扫按「向零截断」：解码端是 `extend << Al`，精修位再按幅值加减，
      // 与算术右移不同（负数的中间值会差一个 Al 量级）。
      const t = v < 0 ? -((-v) >> al) : (v >> al);
      if (t === 0) {
        run++;
        continue;
      }
      while (run > 15) {
        emitHuff(bw, ac, 0xf0);
        run -= 16;
      }
      const size = magcat(t);
      emitHuff(bw, ac, (run << 4) | size);
      writeSigned(bw, t, size);
      run = 0;
    }
    if (ke < se) eobrun = 1; // 本块尾部交给 EOBRUN，后续空块继续累加
  }
  flushEob();
  bw.align();
}

/**
 * 渐进 AC 精修（单分量）。
 *
 * ★ 关键规则：历史非零系数（上一趟 |coef|>>(Al+1) != 0）只补 1 位修正位，
 *   不消耗 run；run 只数「零」位置。ZRL 的 16 个零必须按块内位置切段，
 *   每段后面紧跟该段历史非零的修正位——否则解码端会把这些位当成下一个符号。
 * ★ EOB 可以跨块合并，但被 EOB 覆盖的每个块的历史非零修正位仍要按位置顺序补齐。
 */
function encodeProgressiveAcRefine(
  out: ByteWriter,
  c: Comp,
  interval: number,
  ss: number,
  se: number,
  al: number,
  ac: HuffEnc,
): void {
  const bw = new BitWriter(out);
  const total = c.blocksW * c.blocksH;
  const absv = new Int32Array(64);
  const loadAbs = (bo: number): void => {
    for (let k = ss; k <= se; k++) {
      const v = c.coef[bo + ZIGZAG[k]!]!;
      absv[k] = v < 0 ? ((-v) >> al) : (v >> al);
    }
  };
  const hasNew = (bo: number): boolean => {
    loadAbs(bo);
    for (let k = ss; k <= se; k++) if (absv[k] === 1) return true;
    return false;
  };
  /** 扫描序第 t 个块的数据偏移（非交错扫描按 blocksW 光栅遍历）。 */
  const boOf = (t: number): number =>
    (Math.floor(t / c.blocksW) * c.strideW + (t % c.blocksW)) * 64;
  const emitCorrections = (): void => {
    for (let k = ss; k <= se; k++) {
      const a = absv[k]!;
      if (a >= 2) bw.bit(a & 1);
    }
  };

  for (let m = 0; m < total; m++) {
    if (interval > 0 && m > 0 && m % interval === 0) {
      restartMarker(bw, m / interval - 1, out);
    }
    const bx = m % c.blocksW;
    const by = Math.floor(m / c.blocksW);
    const bo = (by * c.strideW + bx) * 64;
    loadAbs(bo);

    let lastNew = -1;
    for (let k = ss; k <= se; k++) if (absv[k] === 1) lastNew = k;

    if (lastNew >= 0) {
      let zc = 0;
      const bits: number[] = [];
      for (let k = ss; k <= lastNew; k++) {
        const a = absv[k]!;
        if (a === 0) {
          zc++;
          if (zc === 16) {
            emitHuff(bw, ac, 0xf0);
            for (const b of bits) bw.bit(b);
            bits.length = 0;
            zc = 0;
          }
        } else if (a >= 2) {
          bits.push(a & 1);
        } else {
          emitHuff(bw, ac, (zc << 4) | 1);
          // 精修扫描的「新系数」符号位是 1=正 / 0=负（G.1.2.3），
          // 与顺序式 AC 的补码幅值编码不是一套约定，写反会让所有新系数反号。
          bw.bit(c.coef[bo + ZIGZAG[k]!]! < 0 ? 0 : 1);
          for (const b of bits) bw.bit(b);
          bits.length = 0;
          zc = 0;
        }
      }
    }

    // 尾部：lastNew 之后（或整块）交给 EOB。可跨块，但不能越过重启区间。
    const tailStart = lastNew < 0 ? ss : lastNew + 1;
    if (tailStart <= se) {
      const limit =
        interval > 0
          ? Math.min(total, (Math.floor(m / interval) + 1) * interval)
          : total;
      let j = m;
      while (j + 1 < limit && j - m + 1 < 0x7fff && !hasNew(boOf(j + 1))) j++;
      emitEobRun(bw, ac, j - m + 1);
      // 前瞻用的 hasNew 会覆盖 absv，当前块的尾部修正位必须重新载入后再写
      loadAbs(bo);
      for (let k = tailStart; k <= se; k++) {
        const a = absv[k]!;
        if (a >= 2) bw.bit(a & 1);
      }
      // 被 EOB 覆盖的后续整块
      for (let t = m + 1; t <= j; t++) {
        loadAbs(boOf(t));
        emitCorrections();
      }
      m = j;
    }
  }
  bw.align();
}

/** 无损（SOF3）：逐样本空间预测 + DC 差分，无 DCT/量化。 */
function encodeLosslessHuffman(
  out: ByteWriter,
  comps: readonly Comp[],
  width: number,
  height: number,
  interval: number,
  precision: number,
  predictor: number,
  pt: number,
  dcTables: readonly HuffEnc[],
): void {
  const bw = new BitWriter(out);
  const total = width * height;
  const rowsPerInterval = interval > 0 ? interval / width : 0;
  for (let m = 0; m < total; m++) {
    if (interval > 0 && m > 0 && m % interval === 0) restartMarker(bw, m / interval - 1, out);
    const x = m % width;
    const y = Math.floor(m / width);
    const firstRow = y === 0 || (rowsPerInterval > 0 && y % rowsPerInterval === 0);
    for (const c of comps) {
      const s = c.sample[y * c.w + x]!;
      // 点变换后样本只有 P-Pt 位，首样本的中点也随之降到 2^(P-Pt-1)。
      const diff = s - predictSample(c, x, y, precision - pt, predictor, firstRow);
      const cat = magcat(diff);
      emitHuff(bw, dcTables[c.td]!, cat);
      writeSigned(bw, diff, cat);
    }
  }
  bw.align();
}

// ------------------------------------------------------------------ 算术扫描

/**
 * 每帧一套独立的算术统计区。
 *
 * ★ 为什么不是复用主入口那三个数组：分层文件有**两个帧**，每帧的扫描是独立的统计区
 *   （规范要求每个扫描从初始状态开始）。复用会让第二帧继承第一帧的桶状态，
 *   编出来的流自己解得开、别人解得开才怪 —— 而这种错在回环里看不出来。
 */
function newArithStats(): readonly [Int32Array, Int32Array, Int32Array] {
  return [new Int32Array(128), new Int32Array(512), new Int32Array(1)] as const;
}

function resetArithState(
  dcStats: Int32Array,
  acStats: Int32Array,
  fixed: Int32Array,
  comps: readonly Comp[],
): void {
  dcStats.fill(0);
  acStats.fill(0);
  fixed[0] = 113;
  for (const c of comps) {
    c.pred = 0;
    c.dcCtx = 0;
  }
}

/** DC 差分（图 F.1-F.3）：返回下一个块的 context。 */
function encodeDcDiff(
  enc: QmEncoder,
  dcStats: Int32Array,
  table: number,
  ctx: number,
  diff: number,
): number {
  const base = table * 64;
  let st = base + ctx;
  if (diff === 0) {
    enc.encode(dcStats, st, 0);
    return 0;
  }
  enc.encode(dcStats, st, 1);
  let v = diff;
  let next: number;
  if (v > 0) {
    enc.encode(dcStats, st + 1, 0);
    st += 2;
    next = 4;
  } else {
    v = -v;
    enc.encode(dcStats, st + 1, 1);
    st += 3;
    next = 8;
  }
  let m = 0;
  if ((v -= 1) !== 0) {
    enc.encode(dcStats, st, 1);
    m = 1;
    st = base + 20;
    let t = v;
    while ((t >>= 1) !== 0) {
      enc.encode(dcStats, st, 1);
      m <<= 1;
      st += 1;
    }
  }
  enc.encode(dcStats, st, 0);
  // 与 libjpeg 的 ((1<<L)>>1) 完全一致：L=0 时 m<0 永假，
  // 也就是说「小正/小负」这两个 context 会保留，直到出现更大的幅值。
  if (m < ((1 << ARITH_DC_L) >> 1)) next = 0;
  else if (m > ((1 << ARITH_DC_U) >> 1)) next += 8;
  st += 14;
  while ((m >>= 1) !== 0) enc.encode(dcStats, st, (m & v) !== 0 ? 1 : 0);
  return next;
}

/**
 * AC 系数的量值编码（图 F.23）。
 *
 * 结构必须与解码端严格对称：先 1 位（m 是否非零），m=1 时再读**同一条统计桶**
 * 上的一位决定是否进入二级（m=2 并继续一元）；最后在 st+14 读 m 个量值位。
 * 第一版按草稿把「二级」写成另一个桶，Pillow 能解但系数全错位。
 */
function encodeAcValue(
  enc: QmEncoder,
  acStats: Int32Array,
  fixed: Int32Array,
  table: number,
  k: number,
  coef: number,
): void {
  const base = table * 256;
  let st = base + 3 * (k - 1) + 2;
  let v = coef;
  let m = 0;
  if (v < 0) {
    v = -v;
    enc.encode(fixed, 0, 1);
  } else {
    enc.encode(fixed, 0, 0);
  }
  if ((v -= 1) !== 0) {
    enc.encode(acStats, st, 1);
    m = 1;
    if ((v >> 1) !== 0) {
      enc.encode(acStats, st, 1);
      m = 2;
      st = base + (k <= ARITH_AC_K ? 189 : 217);
      let t = v;
      while ((t >>= 1) !== 0) {
        if (t <= 1) break;
        enc.encode(acStats, st, 1);
        m <<= 1;
        st += 1;
      }
      enc.encode(acStats, st, 0);
    } else {
      enc.encode(acStats, st, 0);
    }
  } else {
    enc.encode(acStats, st, 0);
  }
  st += 14;
  while ((m >>= 1) !== 0) enc.encode(acStats, st, (m & v) !== 0 ? 1 : 0);
}

function encodeArithSequential(
  out: ByteWriter,
  comps: readonly Comp[],
  mcusX: number,
  mcusY: number,
  interval: number,
  dcStats: Int32Array,
  acStats: Int32Array,
  fixed: Int32Array,
): void {
  const enc = new QmEncoder(out);
  resetArithState(dcStats, acStats, fixed, comps);
  const total = mcusX * mcusY;
  for (let m = 0; m < total; m++) {
    if (interval > 0 && m > 0 && m % interval === 0) {
      enc.flush();
      out.marker(0xd0 + (m / interval - 1) % 8);
      enc.reset();
      resetArithState(dcStats, acStats, fixed, comps);
    }
    const mx = m % mcusX;
    const my = Math.floor(m / mcusX);
    for (const c of comps) {
      const base = c.ta * 256;
      for (let vy = 0; vy < c.v; vy++) {
        for (let vx = 0; vx < c.h; vx++) {
          const bo = ((my * c.v + vy) * c.strideW + (mx * c.h + vx)) * 64;
          const d = c.coef[bo]!;
          c.dcCtx = encodeDcDiff(enc, dcStats, c.td, c.dcCtx, d - c.pred);
          c.pred = d;
          let ke = 0;
          for (let k = 1; k < 64; k++) if (c.coef[bo + ZIGZAG[k]!]! !== 0) ke = k;
          let st = base;
          let k = 1;
          while (k <= ke) {
            enc.encode(acStats, st, 0); // 不是块尾
            while (c.coef[bo + ZIGZAG[k]!]! === 0) {
              enc.encode(acStats, st + 1, 0);
              st += 3;
              k++;
            }
            enc.encode(acStats, st + 1, 1);
            encodeAcValue(enc, acStats, fixed, c.ta, k, c.coef[bo + ZIGZAG[k]!]!);
            k++;
            st = base + 3 * (k - 1);
          }
          if (k < 64) enc.encode(acStats, st, 1); // EOB
        }
      }
    }
  }
  enc.flush();
}

function encodeArithProgressive(
  out: ByteWriter,
  comps: readonly Comp[],
  mcusX: number,
  mcusY: number,
  interval: number,
  dcStats: Int32Array,
  acStats: Int32Array,
  fixed: Int32Array,
): void {
  const totalMcus = mcusX * mcusY;

  // 第 1 趟：DC 首扫（交错）+ 每分量 AC 首扫。
  // 每个 SOS 必须紧跟着自己的熵数据，所以扫描头只能在这里写，不能在外面预先写。
  writeSos(out, comps, 0, 0, 0, 1);
  {
    const enc = new QmEncoder(out);
    resetArithState(dcStats, acStats, fixed, comps);
    for (let m = 0; m < totalMcus; m++) {
      if (interval > 0 && m > 0 && m % interval === 0) {
        enc.flush();
        out.marker(0xd0 + (m / interval - 1) % 8);
        enc.reset();
        resetArithState(dcStats, acStats, fixed, comps);
      }
      const mx = m % mcusX;
      const my = Math.floor(m / mcusX);
      for (const c of comps) {
        for (let vy = 0; vy < c.v; vy++) {
          for (let vx = 0; vx < c.h; vx++) {
            const bo = ((my * c.v + vy) * c.strideW + (mx * c.h + vx)) * 64;
            const scaled = c.coef[bo]! >> 1;
            c.dcCtx = encodeDcDiff(enc, dcStats, c.td, c.dcCtx, scaled - c.pred);
            c.pred = scaled;
          }
        }
      }
    }
    enc.flush();
  }

  for (const c of comps) {
    writeSos(out, [c], 1, 63, 0, 1);
    const enc = new QmEncoder(out);
    resetArithState(dcStats, acStats, fixed, [c]);
    const blocks = c.blocksW * c.blocksH;
    const base = c.ta * 256;
    for (let m = 0; m < blocks; m++) {
      if (interval > 0 && m > 0 && m % interval === 0) {
        enc.flush();
        out.marker(0xd0 + (m / interval - 1) % 8);
        enc.reset();
        resetArithState(dcStats, acStats, fixed, [c]);
      }
      const bx = m % c.blocksW;
      const by = Math.floor(m / c.blocksW);
      const bo = (by * c.strideW + bx) * 64;
      let ke = 0;
      for (let k = 1; k <= 63; k++) {
        const v = c.coef[bo + ZIGZAG[k]!]!;
        if ((v < 0 ? -((-v) >> 1) : v >> 1) !== 0) ke = k;
      }
      let st = base;
      let k = 1;
      while (k <= ke) {
        enc.encode(acStats, st, 0);
        let v = c.coef[bo + ZIGZAG[k]!]!;
        v = v < 0 ? -((-v) >> 1) : v >> 1;
        while (v === 0) {
          enc.encode(acStats, st + 1, 0);
          st += 3;
          k++;
          const raw = c.coef[bo + ZIGZAG[k]!]!;
          v = raw < 0 ? -((-raw) >> 1) : raw >> 1;
        }
        enc.encode(acStats, st + 1, 1);
        encodeAcValue(enc, acStats, fixed, c.ta, k, v);
        k++;
        st = base + 3 * (k - 1);
      }
      if (k < 64) enc.encode(acStats, st, 1);
    }
    enc.flush();
  }

  // 第 2 趟：DC 精修（交错）+ 每分量 AC 精修
  writeSos(out, comps, 0, 0, 1, 0);
  {
    const enc = new QmEncoder(out);
    resetArithState(dcStats, acStats, fixed, comps);
    for (let m = 0; m < totalMcus; m++) {
      if (interval > 0 && m > 0 && m % interval === 0) {
        enc.flush();
        out.marker(0xd0 + (m / interval - 1) % 8);
        enc.reset();
        resetArithState(dcStats, acStats, fixed, comps);
      }
      const mx = m % mcusX;
      const my = Math.floor(m / mcusX);
      for (const c of comps) {
        for (let vy = 0; vy < c.v; vy++) {
          for (let vx = 0; vx < c.h; vx++) {
            const bo = ((my * c.v + vy) * c.strideW + (mx * c.h + vx)) * 64;
            enc.encode(fixed, 0, (c.coef[bo]! >> 0) & 1);
          }
        }
      }
    }
    enc.flush();
  }

  for (const c of comps) {
    writeSos(out, [c], 1, 63, 1, 0);
    const enc = new QmEncoder(out);
    resetArithState(dcStats, acStats, fixed, [c]);
    const blocks = c.blocksW * c.blocksH;
    const base = c.ta * 256;
    for (let m = 0; m < blocks; m++) {
      if (interval > 0 && m > 0 && m % interval === 0) {
        enc.flush();
        out.marker(0xd0 + (m / interval - 1) % 8);
        enc.reset();
        resetArithState(dcStats, acStats, fixed, [c]);
      }
      const bx = m % c.blocksW;
      const by = Math.floor(m / c.blocksW);
      const bo = (by * c.strideW + bx) * 64;
      // 与 jcarith 的 encode_mcu_AC_refine 逐句对应：
      //   ke  = 本趟精度下最后一个非零（截断到 0 位）
      //   kex = 上一趟精度下最后一个非零（截断到 1 位）
      // k > kex 的位置才需要写「非 EOB」位；已非零系数的修正位在 st+2，
      // 不是 fixed bin —— 用 fixed bin 会让解码端的概率状态从第一个修正位就分叉。
      let ke = 0;
      let kex = 0;
      for (let k = 1; k <= 63; k++) {
        const v = Math.abs(c.coef[bo + ZIGZAG[k]!]!);
        if (v !== 0) ke = k;
        if (v >> 1 !== 0) kex = k;
      }
      let k = 1;
      while (k <= ke) {
        let st = base + 3 * (k - 1);
        if (k > kex) enc.encode(acStats, st, 0);
        for (;;) {
          const raw = c.coef[bo + ZIGZAG[k]!]!;
          const v = Math.abs(raw);
          if (v !== 0) {
            if (v >> 1 !== 0) {
              enc.encode(acStats, st + 2, v & 1);
            } else {
              enc.encode(acStats, st + 1, 1);
              enc.encode(fixed, 0, raw < 0 ? 1 : 0);
            }
            break;
          }
          enc.encode(acStats, st + 1, 0);
          st += 3;
          k++;
        }
        k++;
      }
      if (k <= 63) enc.encode(acStats, base + 3 * (k - 1), 1);
    }
    enc.flush();
  }
}

function encodeArithLossless(
  out: ByteWriter,
  comps: readonly Comp[],
  width: number,
  height: number,
  interval: number,
  precision: number,
  predictor: number,
  pt: number,
  dcStats: Int32Array,
  acStats: Int32Array,
  fixed: Int32Array,
): void {
  const enc = new QmEncoder(out);
  resetArithState(dcStats, acStats, fixed, comps);
  const total = width * height;
  const rowsPerInterval = interval > 0 ? interval / width : 0;
  for (let m = 0; m < total; m++) {
    if (interval > 0 && m > 0 && m % interval === 0) {
      enc.flush();
      out.marker(0xd0 + (m / interval - 1) % 8);
      enc.reset();
      resetArithState(dcStats, acStats, fixed, comps);
    }
    const x = m % width;
    const y = Math.floor(m / width);
    const firstRow = y === 0 || (rowsPerInterval > 0 && y % rowsPerInterval === 0);
    for (const c of comps) {
      const s = c.sample[y * c.w + x]!;
      const diff = s - predictSample(c, x, y, precision - pt, predictor, firstRow);
      c.dcCtx = encodeDcDiff(enc, dcStats, c.td, c.dcCtx, diff);
    }
  }
  enc.flush();
}

// ------------------------------------------------------------------ 分层（差分帧）

/**
 * 双线性上采样（放大 2 倍），与解码端独立实现同一规则。
 *
 * ★ 为什么编码器里要再写一份而不是从 src 里 import：
 *   编码器存在的意义就是"用另一个人写的另一份实现去对撞解码器"。
 *   如果连上采样都共用同一份代码，那么"差分帧合成正确"这件事就退化成
 *   "同一个函数被调用两次" —— 相位/取整写错也照样回环相等。
 *   这里按 T.81 J.1.1.2 的 3:1 双线性（1/4 偏移）重写：
 *     out[2i]   = (3·ref[i] + ref[i-1] + 2) / 4
 *     out[2i+1] = (3·ref[i] + ref[i+1] + 2) / 4
 *   二维是可分离的，所以直接乘 9/3/3/1 的权重。
 */
function upsample2x(src: Plane, w: number, h: number): Plane {
  const data = new Uint16Array(w * h);
  // 边界两侧都钳（y=-1 会读到负下标，NaN 落进 Uint16Array 就是 0）
  const cx = (x: number): number => (x < 0 ? 0 : x >= src.w ? src.w - 1 : x);
  const cy = (y: number): number => (y < 0 ? 0 : y >= src.h ? src.h - 1 : y);
  const at = (x: number, y: number): number => src.data[cy(y) * src.w + cx(x)]!;
  for (let y = 0; y < h; y++) {
    const y0 = y >> 1;
    const yn = (y & 1) === 0 ? y0 - 1 : y0 + 1;
    for (let x = 0; x < w; x++) {
      const x0 = x >> 1;
      const xn = (x & 1) === 0 ? x0 - 1 : x0 + 1;
      data[y * w + x] = Math.floor((at(x0, y0) * 9 + at(xn, y0) * 3 + at(x0, yn) * 3 + at(xn, yn) + 8) / 16);
    }
  }
  return { w, h, data };
}

/**
 * 分层编码：DHP（完成态头）+ 帧0（1/2 分辨率）+ EXP + 帧1（差分帧）。
 *
 * ★ 文件结构按 T.81 B.3.1 的图 B.13：`SOI DHP 表 SOF SOS 熵数据 EXP SOF SOS 熵数据 EOI`。
 *   DHP **不是**帧头：它声明"完成态图像"的尺寸/分量/采样因子（量化表选择器必须写 0），
 *   第一帧仍有自己的 SOF。这一点很容易搞反（把 DHP 当第一帧头），
 *   所以我们自己解的时候也按"每个 SOF 都是一帧"处理。
 *
 * ★ 差分的两种域（编码端与解码端必须一致，写错就是整片糊）：
 *   · 无损（SOF7）：残差按 **mod 2^P** 取差（J.1.1："calculated modulo 2^16"），
 *     所以 `residual = (s - ref) & mask`，解码端 `s = (residual + ref) & mask`。
 *     用 clamp 而不是 mod 会在 s 与 ref 跨越量程时错（例如 s=10, ref=250）。
 *   · 有损（SOF5）：残差走普通 DCT 通路，样本在 FDCT 前统一减 2^(P-1)，
 *     所以编码时喂 `clamp(s - ref + 2^(P-1))`，解码端 `s = diff - 2^(P-1) + ref`。
 */
function encodeHierarchical(
  samples: Uint16Array | Uint8Array,
  spec: EncodeSpec,
  lossless: boolean,
  arith: boolean,
  progressive: boolean,
  quality: number,
  restart: number,
  dcSpecs: ReadonlyArray<{ bits: readonly number[]; vals: readonly number[] }>,
  acSpecs: ReadonlyArray<{ bits: readonly number[]; vals: readonly number[] }>,
  dcTables: readonly HuffEnc[],
  acTables: readonly HuffEnc[],
): Uint8Array {
  const { width, height, components, precision } = spec;
  if (width % 2 !== 0 || height % 2 !== 0) {
    throw new Error(`JPEG 分层编码器：宽高必须是偶数（参考帧取 1/2 分辨率），实际 ${width}x${height}`);
  }
  const maxv = (1 << precision) - 1;
  const center = 1 << (precision - 1);
  const hw = width / 2;
  const hh = height / 2;

  // 完成态图像的分量平面（无损走 RGB 直通，有损走 YCbCr 444）
  const fullSpec: EncodeSpec = { ...spec, subsampling: "444" };
  const fullPlanes = buildPlanes(samples, fullSpec, lossless);
  // 参考帧：每隔一个样本取样（降采样滤波规范不规定，这里取确定性最近邻）
  const halfPlanes: Plane[] = fullPlanes.map((p) => {
    const data = new Uint16Array(hw * hh);
    for (let y = 0; y < hh; y++) {
      for (let x = 0; x < hw; x++) data[y * hw + x] = p.data[(y * 2) * p.w + x * 2]!;
    }
    return { w: hw, h: hh, data };
  });

  const qt: Uint16Array[] = [];
  if (!lossless) {
    qt.push(scaledQuant(QUANT_LUMA, quality));
    qt.push(scaledQuant(QUANT_CHROMA, quality));
  }

  const out = new ByteWriter();
  out.marker(0xd8);
  if (components === 4) writeApp14(out, spec.adobeTransform ?? 0);
  if (!lossless) writeDqt(out, qt);
  const dhtEntries: Array<readonly [number, number, readonly number[], readonly number[]]> = [
    [0, 0, dcSpecs[0]!.bits, dcSpecs[0]!.vals],
  ];
  if (!lossless) dhtEntries.push([1, 0, acSpecs[0]!.bits, acSpecs[0]!.vals]);
  if (components !== 1) {
    dhtEntries.push([0, 1, dcSpecs[1]!.bits, dcSpecs[1]!.vals]);
    if (!lossless) dhtEntries.push([1, 1, acSpecs[1]!.bits, acSpecs[1]!.vals]);
  }
  // 算术编码不需要 DHT（条件由 DAC/缺省值给）；写一张用不到的表只会让文件更像"混着抄的"
  if (!arith) writeDht(out, dhtEntries);
  // DRI 是"帧外"的状态：它一旦出现就对后续所有扫描生效，所以只在整条流里写一次，
  // 且必须在第一帧的 SOS 之前。漏写 DRI 而照常插 RST 标记，解码端会把它当错误。
  if (restart > 0) {
    out.marker(0xdd);
    out.u16(4);
    out.u16(restart);
  }

  // ---------------- DHP：完成态图像头（量化表选择器必须为 0）
  const halfSpec: EncodeSpec = { ...fullSpec, width: hw, height: hh };
  const halfComps = buildComps(halfPlanes, halfSpec, lossless);
  out.marker(0xde);
  out.u16(8 + halfComps.length * 3);
  out.byte(precision);
  out.u16(height);
  out.u16(width);
  out.byte(halfComps.length);
  for (const c of halfComps) {
    out.byte(c.id);
    out.byte((c.h << 4) | c.v);
    out.byte(0);
  }

  // ---------------- 帧 0：非差分（SOF1 / SOF3），1/2 分辨率
  const sof0 = lossless ? (arith ? 0xcb : 0xc3) : arith ? 0xc9 : precision === 8 ? 0xc0 : 0xc1;
  writeSof(out, sof0, halfComps, precision, hw, hh);
  const halfMcuX = Math.ceil(hw / (8 * Math.max(...halfComps.map((c) => c.h))));
  const halfMcuY = Math.ceil(hh / (8 * Math.max(...halfComps.map((c) => c.v))));
  if (lossless) {
    writeSos(out, halfComps, 1, 0, 0, 0);
    if (arith) {
      encodeArithLossless(out, halfComps, hw, hh, restart, precision, 1, 0, ...newArithStats());
    } else {
      encodeLosslessHuffman(out, halfComps, hw, hh, restart, precision, 1, 0, dcTables);
    }
  } else {
    fillCoefficients(halfComps, qt, precision);
    writeSos(out, halfComps, 0, 63, 0, 0);
    if (arith) {
      encodeArithSequential(out, halfComps, halfMcuX, halfMcuY, restart, ...newArithStats());
    } else {
      encodeSequentialHuffman(out, halfComps, halfMcuX, halfMcuY, restart, dcTables, acTables);
    }
  }

  // ---------------- EXP：参考帧要放大 2 倍（只作用于下一个帧头）
  for (const c of halfComps) {
    out.marker(0xdf);
    out.u16(4);
    out.byte(c.id);
    out.byte(0x22);
  }

  // ---------------- 帧 1：差分帧（SOF5 / SOF7），全分辨率
  const diffPlanes: Plane[] = fullPlanes.map((p, i) => {
    const up = upsample2x(halfPlanes[i]!, p.w, p.h);
    const data = new Uint16Array(p.data.length);
    for (let k = 0; k < data.length; k++) {
      const d = p.data[k]! - up.data[k]!;
      // 无损：模 2^P；有损：电平位移到无符号样本区间
      data[k] = lossless ? d & maxv : clampInt(d + center, 0, maxv);
    }
    return { w: p.w, h: p.h, data };
  });
  const diffComps = buildComps(diffPlanes, fullSpec, lossless);
  const sof1 = lossless
    ? arith
      ? 0xcf
      : 0xc7
    : progressive
      ? arith
        ? 0xce
        : 0xc6
      : arith
        ? 0xcd
        : 0xc5;
  writeSof(out, sof1, diffComps, precision, width, height);
  if (lossless) {
    writeSos(out, diffComps, 1, 0, 0, 0);
    if (arith) {
      encodeArithLossless(out, diffComps, width, height, restart, precision, 1, 0, ...newArithStats());
    } else {
      encodeLosslessHuffman(out, diffComps, width, height, restart, precision, 1, 0, dcTables);
    }
  } else {
    fillCoefficients(diffComps, qt, precision);
    const mcuX = Math.ceil(width / (8 * Math.max(...diffComps.map((c) => c.h))));
    const mcuY = Math.ceil(height / (8 * Math.max(...diffComps.map((c) => c.v))));
    // ★ 只有"单趟"过程需要在这里写扫描头；渐进（哈夫曼/算术）每一趟都有自己的 SOS，
    //   由各自的编码函数在熵数据前就地写。这里先写一个 (0,63,0,0) 会让解码端把
    //   后续的多趟数据当成一趟顺序扫描读，报"DC 扫描（Ss=0）必须 Se=0"。
    if (progressive) {
      if (arith) {
        encodeArithProgressive(out, diffComps, mcuX, mcuY, restart, ...newArithStats());
      } else {
        progressiveHuffmanScan(out, diffComps, mcuX, mcuY, restart, dcTables, acTables);
      }
    } else if (arith) {
      writeSos(out, diffComps, 0, 63, 0, 0);
      encodeArithSequential(out, diffComps, mcuX, mcuY, restart, ...newArithStats());
    } else {
      writeSos(out, diffComps, 0, 63, 0, 0);
      encodeSequentialHuffman(out, diffComps, mcuX, mcuY, restart, dcTables, acTables);
    }
  }

  out.marker(0xd9);
  return out.take();
}

/**
 * 渐进式哈夫曼的四趟扫描（8 位 SOF2 / 12 位 SOF6 共用）。
 *
 * 抽出来是因为分层差分帧（SOF6）和普通渐进帧（SOF2）必须走**完全相同的**扫描序列，
 * 否则"两种文件解出同样的像素"这条判据会被编码端的差异污染。
 */
function progressiveHuffmanScan(
  out: ByteWriter,
  comps: readonly Comp[],
  mcuX: number,
  mcuY: number,
  restart: number,
  dcTables: readonly HuffEnc[],
  acTables: readonly HuffEnc[],
): void {
  // DC 首扫(Al=1) → 每个分量 AC 首扫(Al=1) → DC 精修 → 每个分量 AC 精修。
  // 扫描头必须**紧跟各自的熵数据**，所以 writeSos 与编码交替出现（不是先写 4 个 SOS）。
  writeSos(out, comps, 0, 0, 0, 1);
  encodeProgressiveDcFirst(out, comps, mcuX, mcuY, restart, 1, dcTables);
  for (const c of comps) {
    writeSos(out, [c], 1, 63, 0, 1);
    encodeProgressiveAcFirst(out, c, restart, 1, 63, 1, acTables[c.ta]!);
  }
  writeSos(out, comps, 0, 0, 1, 0);
  encodeProgressiveDcRefine(out, comps, mcuX, mcuY, restart, 0);
  for (const c of comps) {
    writeSos(out, [c], 1, 63, 1, 0);
    encodeProgressiveAcRefine(out, c, restart, 1, 63, 0, acTables[c.ta]!);
  }
}

// ------------------------------------------------------------------ 主入口

export function encodeJpeg(samples: Uint16Array | Uint8Array, spec: EncodeSpec): Uint8Array {
  const { width, height, components, precision, mode } = spec;
  if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1) {
    throw new Error(`JPEG 编码器：宽高必须是正整数，实际 ${width}x${height}`);
  }
  if (width > 65535 || height > 65535) throw new Error("JPEG 编码器：宽高不能超过 65535");
  if (precision !== 8 && precision !== 12) throw new Error(`JPEG 编码器：precision 只支持 8/12，实际 ${precision}`);
  const need = width * height * components;
  if (samples.length !== need) {
    throw new Error(`JPEG 编码器：samples 长度应为 ${need}，实际 ${samples.length}`);
  }
  const hier = mode.startsWith("hier-");
  const progressiveHier = mode === "hier-progressive" || mode === "hier-arith-progressive";
  const lossless =
    mode === "lossless" || mode === "arith-lossless" || mode === "hier-lossless" || mode === "hier-arith-lossless";
  const arith =
    mode === "arith-sequential" ||
    mode === "arith-progressive" ||
    mode === "arith-lossless" ||
    mode === "hier-arith-sequential" ||
    mode === "hier-arith-lossless" ||
    mode === "hier-arith-progressive";
  const quality = spec.quality ?? 90;
  const predictor = clampInt(spec.predictor ?? 1, 1, 7);
  const pt = lossless ? clampInt(spec.pointTransform ?? 0, 0, 15) : 0;
  const restart = Math.max(0, Math.floor(spec.restart ?? 0));
  if (lossless && restart > 0 && restart % width !== 0) {
    // 不是"我懒"：libjpeg 的 jddiffct.c / jclossls.c 在 start_pass 里直接
    // ERREXIT2(JERR_BAD_RESTART, interval, MCUs_per_row)，非整数倍的流连参考
    // 解码器都读不了 —— 与其产出一个谁也验不了的语料，不如在这里停下。
    throw new Error(
      `JPEG 编码器：无损模式的重启区间必须是行宽 ${width} 的整数倍（实际 ${restart}）；` +
        "libjpeg-turbo 的 jddiffct.c 要求 restart_interval % MCUs_per_row == 0",
    );
  }

  const planes = buildPlanes(samples, spec, lossless);
  if (lossless && pt > 0) {
    // 点数变换在预测之前做：编码端的「原样本」就是解码端会重建出的那个值，
    // 这样 Pt>0 时差分与预测仍然逐位一致（只是整体右移掉了低位）。
    for (const p of planes) for (let i = 0; i < p.data.length; i++) p.data[i] = p.data[i]! >> pt;
  }
  const comps = buildComps(planes, spec, lossless);

  const maxH = Math.max(...comps.map((c) => c.h));
  const maxV = Math.max(...comps.map((c) => c.v));
  const mcusX = Math.ceil(width / (8 * maxH));
  const mcusY = Math.ceil(height / (8 * maxV));

  const qt: Uint16Array[] = [];
  if (!lossless) {
    qt.push(scaledQuant(QUANT_LUMA, quality));
    if (components !== 1) qt.push(scaledQuant(QUANT_CHROMA, quality));
    fillCoefficients(comps, qt, precision);
  }

  const dcSpecs = [
    makeHuffTable(DC_LUMA_BITS, DC_LUMA_VALS, 16),
    makeHuffTable(DC_CHROMA_BITS, DC_CHROMA_VALS, 16),
  ];
  // 渐进式需要 EOBn（0x10..0xE0），12 位的 AC 幅值也会超过 size=10，K 表都覆盖不了；
  // 顺序式/无损的 8 位仍走 Annex K，出现 K 表没有的符号就报错（与规范实现一致）。
  const wideAc =
    precision === 12 ||
    mode === "progressive" ||
    mode === "arith-progressive" ||
    progressiveHier;
  const acSpecs = wideAc
    ? [makeFlatAcTable(), makeFlatAcTable()]
    : [makeHuffTable(AC_LUMA_BITS, AC_LUMA_VALS, 0), makeHuffTable(AC_CHROMA_BITS, AC_CHROMA_VALS, 0)];
  const dcTables: readonly HuffEnc[] = dcSpecs.map((s) => s.codes);
  const acTables: readonly HuffEnc[] = acSpecs.map((s) => s.codes);

  // 分层分支自己写整条标记链（SOI/DQT/DHT/DHP/两个 SOF/EXP/EOI），
  // 所以必须在写任何标记之前返回 —— 否则外层这些 SOI/DQT/SOF 会被丢掉（写进一个被丢弃的 writer）。
  if (hier) {
    return encodeHierarchical(
      samples,
      spec,
      lossless,
      arith,
      progressiveHier,
      quality,
      restart,
      dcSpecs,
      acSpecs,
      dcTables,
      acTables,
    );
  }

  const out = new ByteWriter();
  out.marker(0xd8);
  // 三分量无损不写 JFIF：一旦有 JFIF，libjpeg 会把分量当 YCbCr 并试图做颜色变换，
  // 而它的无损路径不做颜色变换，于是直接报错。无标记时它按 id=1/2/3 认作 RGB。
  // 4 分量不写 JFIF：JFIF 的定义只覆盖 1/3 分量，写了等于声明"这是 YCbCr"，
  // 而 4 分量的颜色空间由 APP14(Adobe) 的 transform 决定。
  if (components !== 4 && !(lossless && components === 3)) writeApp0(out);
  if (components === 4) writeApp14(out, spec.adobeTransform ?? 0);
  if (!lossless) writeDqt(out, qt);

  if (arith && spec.dac === true) {
    const dac: Array<readonly [number, number, number]> = [
      [0, 0, (ARITH_DC_U << 4) | ARITH_DC_L],
      [1, 0, ARITH_AC_K],
    ];
    if (components !== 1) {
      dac.push([0, 1, (ARITH_DC_U << 4) | ARITH_DC_L]);
      dac.push([1, 1, ARITH_AC_K]);
    }
    writeDac(out, dac);
  }

  // SOF0 只允许 8 位；12 位顺序式按规范应写 SOF1（扩展顺序式），否则文件本身非法。
  let sof: number;
  switch (mode) {
    case "baseline":
      sof = precision === 8 ? 0xc0 : 0xc1;
      break;
    case "progressive":
      sof = 0xc2;
      break;
    case "lossless":
      sof = 0xc3;
      break;
    case "arith-sequential":
      sof = 0xc9;
      break;
    case "arith-progressive":
      sof = 0xca;
      break;
    default:
      sof = 0xcb;
      break;
  }
  writeSof(out, sof, comps, precision, width, height);

  if (!arith) {
    const entries: Array<readonly [number, number, readonly number[], readonly number[]]> = [
      [0, 0, dcSpecs[0]!.bits, dcSpecs[0]!.vals],
      [1, 0, acSpecs[0]!.bits, acSpecs[0]!.vals],
    ];
    if (components !== 1) {
      entries.push([0, 1, dcSpecs[1]!.bits, dcSpecs[1]!.vals]);
      entries.push([1, 1, acSpecs[1]!.bits, acSpecs[1]!.vals]);
    }
    writeDht(out, entries);
  }

  if (restart > 0) {
    out.marker(0xdd);
    out.u16(4);
    out.u16(restart);
  }

  const dcStats = new Int32Array(128);
  const acStats = new Int32Array(512);
  const fixed = new Int32Array(1);

  if (mode === "baseline" || mode === "arith-sequential") {
    writeSos(out, comps, 0, 63, 0, 0);
    if (mode === "baseline") {
      encodeSequentialHuffman(out, comps, mcusX, mcusY, restart, dcTables, acTables);
    } else {
      encodeArithSequential(out, comps, mcusX, mcusY, restart, dcStats, acStats, fixed);
    }
  } else if (mode === "progressive") {
    progressiveHuffmanScan(out, comps, mcusX, mcusY, restart, dcTables, acTables);
  } else if (mode === "arith-progressive") {
    // 扫描头由这个函数自己写：每个 SOS 后面必须紧跟它自己的熵数据。
    encodeArithProgressive(out, comps, mcusX, mcusY, restart, dcStats, acStats, fixed);
  } else {
    writeSos(out, comps, predictor, 0, 0, pt);
    if (mode === "lossless") {
      encodeLosslessHuffman(out, comps, width, height, restart, precision, predictor, pt, dcTables);
    } else {
      encodeArithLossless(out, comps, width, height, restart, precision, predictor, pt, dcStats, acStats, fixed);
    }
  }

  out.marker(0xd9);
  return out.take();
}
