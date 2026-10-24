/**
 * L4 · JPEG 解码 · QM 算术解码器（T.81 Annex D）+ 统计区（D.5 / D.6）
 *
 * ★ 这份实现按 Annex D 的**位级流程**写，而不是按"看起来等价"的简化写：
 *   算术解码器的状态只有 A（区间）、C（码值）、CT（位数）三个量，
 *   任何一个写错都不会抛错 —— 只会让后面每一个符号都错，最后解出一片噪点。
 *   所以这里的每一句都能对上规范原文，`tests/extensions/jpeg-arith.test.ts`
 *   用"解我们自己编码的流 + 与 libjpeg 的算术解码器对拍"两条路验证。
 *
 * ★ 为什么统计区是 `Uint8Array`（1 字节/桶）而不是对象数组：
 *   一个桶只需要"当前 MPS 值（1 位）+ 概率状态索引（7 位）"。
 *   用对象存会让 AC 频带每块的 256 个桶产生 256 次分配/访问，
 *   而解码是逐位调用的最内层循环 —— 这里的常数因子决定整张图的解码时间。
 */

/** Qe 值（Table D.2）。 */
const QM_QE = new Uint16Array([
  0x5a1d, 0x2586, 0x1114, 0x080b, 0x03d8, 0x01da, 0x00e5, 0x006f, 0x0036, 0x001a, 0x000d, 0x0006, 0x0003,
  0x0001, 0x5a7f, 0x3f25, 0x2cf2, 0x207c, 0x17b9, 0x1182, 0x0cef, 0x09a1, 0x072f, 0x055c, 0x0406, 0x0303,
  0x0240, 0x01b1, 0x0144, 0x00f5, 0x00b7, 0x008a, 0x0068, 0x004e, 0x003b, 0x002c, 0x5ae1, 0x484c, 0x3a0d,
  0x2ef1, 0x261f, 0x1f33, 0x19a8, 0x1518, 0x1177, 0x0e74, 0x0bfb, 0x09f8, 0x0861, 0x0706, 0x05cd, 0x04de,
  0x040f, 0x0363, 0x02d4, 0x025c, 0x01f8, 0x01a4, 0x0160, 0x0125, 0x00f6, 0x00cb, 0x00ab, 0x008f, 0x5b12,
  0x4d04, 0x412c, 0x37d8, 0x2fe8, 0x293c, 0x2379, 0x1edf, 0x1aa9, 0x174e, 0x1424, 0x119c, 0x0f6b, 0x0d51,
  0x0bb6, 0x0a40, 0x5832, 0x4d1c, 0x438e, 0x3bdd, 0x34ee, 0x2eae, 0x299a, 0x2516, 0x5570, 0x4ca9, 0x44d9,
  0x3e22, 0x3824, 0x32b4, 0x2e17, 0x56a8, 0x4f46, 0x47e5, 0x41cf, 0x3c3d, 0x375e, 0x5231, 0x4c0f, 0x4639,
  0x415e, 0x5627, 0x50e7, 0x4b85, 0x5597, 0x504f, 0x5a10, 0x5522, 0x59eb, 0x5a1d,
]);

/**
 * LPS 后的下一状态（低 7 位）与"是否翻转 MPS"（bit 7）。
 *
 * ★ 翻转位必须和状态索引一起打包：`Table D.2` 里 Switch_MPS 只对
 *   "走到 LPS 的那一侧"生效，单独存一个布尔数组会让人忘记"往哪儿翻"。
 *   这里沿用 IJG 的紧凑表示（`next = index | switch<<7`），
 *   更新写成 `stats[i] = (old & 0x80) ^ nl` 一行就对。
 *
 * ★★ 这一版修的是一个**真实事故**，不是笔误清理：
 *   上一版的数组原来是**裸的 Next_Index_LPS**（没有 bit 7），于是"读完 LPS 后
 *   该翻转 MPS"这件事从来没发生过。后果极其隐蔽 ——
 *   同一个统计桶**连续用两次**时（AC 量值编码图 F.23 就是这样：%第一个"m>1"
 *   判定与"m>2"判定打在同一个桶上%），第二次决策会把已被判成 LPS 的符号
 *   又当成 MPS 解出来。症状是：DC 全对、块首 AC 系数幅值偏小、其余系数全 0，
 *   而位流位置依然"合法"，看不到任何异常。
 *   判据来源是 libjpeg 的 `jaricom.c`（`V(索引, Qe, Next_LPS, Next_MPS, Switch)`），
 *   带 Switch_MPS=1 的索引恰好是 0,14,36,64,80,88,95,105,110,112 这 10 个。
 */
const QM_NLPS_RAW = [
  1, 14, 16, 18, 20, 23, 25, 28, 30, 33, 35, 9, 10, 12, 15, 36, 38, 39, 40, 42,
  43, 45, 46, 48, 49, 51, 52, 54, 56, 57, 59, 60, 62, 63, 32, 33, 37, 64, 65, 67,
  68, 69, 70, 72, 73, 74, 75, 77, 78, 79, 48, 50, 50, 51, 52, 53, 54, 55, 56, 57,
  58, 59, 61, 61, 65, 80, 81, 82, 83, 84, 86, 87, 87, 72, 72, 74, 74, 75, 77, 77,
  80, 88, 89, 90, 91, 92, 93, 86, 88, 95, 96, 97, 99, 99, 93, 95, 101, 102, 103, 104,
  99, 105, 106, 107, 103, 105, 108, 109, 110, 111, 110, 112, 112, 113,
] as const;

/** Table D.2 中 Switch_MPS = 1 的状态索引（10 个，别删）。 */
export const QM_SWITCH_STATES: readonly number[] = [0, 14, 36, 64, 80, 88, 95, 105, 110, 112];

const QM_NLPS = new Uint8Array(114);
for (let i = 0; i < 114; i++) {
  QM_NLPS[i] = QM_NLPS_RAW[i]! | (QM_SWITCH_STATES.includes(i) ? 0x80 : 0);
}

const QM_NMPS = new Uint8Array([
  1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 13, 15, 16, 17, 18, 19, 20,
  21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 9, 37, 38, 39, 40,
  41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60,
  61, 62, 63, 32, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 78, 79, 48,
  81, 82, 83, 84, 85, 86, 87, 71, 89, 90, 91, 92, 93, 94, 86, 96, 97, 98, 99, 100,
  93, 102, 103, 104, 99, 106, 107, 103, 109, 107, 111, 109, 111, 113,
]);

/** 固定 0.5 概率桶的初始状态（T.851 Table 5 的推荐值，也是 IJG 的 113）。 */
export const FIXED_BIN_STATE = 113;

/** DC 统计区桶数：规范要求 ≥49（F.1.4.4.1.3），这里取 64。 */
export const DC_STAT_BINS = 64;
/** AC 统计区桶数：规范要求 ≥245（F.1.4.4.2），这里取 256。 */
export const AC_STAT_BINS = 256;

export function newStats(size: number): Uint8Array {
  // 全 0 = MPS 为 0、状态索引 0（Qe=0x5a1d，等价于"什么都不知道"）
  return new Uint8Array(size);
}

/**
 * QM 解码器。**只在一个 RST 区间内使用**（与 `BitReader` 同一条约定）：
 * 区间边界由 `splitEntropy` 预切分，所以这里只需要处理 `FF 00` 填充，
 * 遇到真标记就把后续数据当 0 —— 这正是规范对"扫描在标记处提前结束"的约定，
 * 也是 libjpeg 的行为（它把标记后的数据当 0 继续解完）。
 */
export class QmDecoder {
  private c = 0;
  private a = 0;
  private ct = -16; // -16 ⇒ 先读 2 个字节把 C 填满
  private pos: number;
  private stalled = false;

  constructor(
    private readonly data: Uint8Array,
    start: number,
    private readonly end: number,
  ) {
    this.pos = start;
  }

  /** 熵数据里是否撞到了标记（预切分与数据不一致 / 扫描提前结束）。 */
  get hitMarker(): boolean {
    return this.stalled;
  }

  private nextByte(): number {
    if (this.stalled || this.pos >= this.end) {
      this.stalled = true;
      return 0;
    }
    let data = this.data[this.pos++]!;
    if (data === 0xff) {
      // FF 00 是数据里的字面 FF；连续 FF 是填充；其余是标记
      do {
        if (this.pos >= this.end) {
          this.stalled = true;
          return 0;
        }
        data = this.data[this.pos++]!;
      } while (data === 0xff);
      if (data === 0x00) {
        data = 0xff;
      } else {
        this.stalled = true;
        return 0;
      }
    }
    return data;
  }

  /**
   * 解一位。
   *
   * ★ 重归一化必须**在**解码之前跑（Annex D.2.6 / 图 D.2）：A 小于 0x8000 时
   *   先把 A、C 左移并补入新字节，再拿 A 与 Qe 比。写成"解码后再归一化"也能跑，
   *   但 `ct` 的进位时机差一个字节，整条流会从某个符号起全错。
   */
  decode(stats: Uint8Array, at: number): number {
    while (this.a < 0x8000) {
      if (--this.ct < 0) {
        const data = this.nextByte();
        this.c = ((this.c << 8) | data) >>> 0;
        this.ct += 8;
        if (this.ct < 0) {
          this.ct++;
          if (this.ct === 0) this.a = 0x8000; // 读完 2 个初始字节 ⇒ A = 0x10000
        }
      }
      this.a <<= 1;
    }

    let sv = stats[at]!;
    const qe = QM_QE[sv & 0x7f]!;
    const nl = QM_NLPS[sv & 0x7f]!;
    const nm = QM_NMPS[sv & 0x7f]!;

    const temp = this.a - qe;
    this.a = temp;
    // C 里是 `temp <<= ct`。ct 在比较点恒为 0..7（重归一化循环保证），
    // 所以直接移位不会溢出 32 位；写成负位移兜底是为了不在读坏文件时悄悄取模。
    const shifted = this.ct >= 0 ? (temp << this.ct) >>> 0 : (temp >>> -this.ct) >>> 0;
    if (this.c >= shifted) {
      this.c = (this.c - shifted) >>> 0;
      if (this.a < qe) {
        // 条件交换：MPS 区间反而更小 ⇒ 交换两个符号的区间
        this.a = qe;
        stats[at] = (sv & 0x80) ^ nm;
      } else {
        this.a = qe;
        stats[at] = (sv & 0x80) ^ nl;
        sv ^= 0x80;
      }
    } else if (this.a < 0x8000) {
      if (this.a < qe) {
        stats[at] = (sv & 0x80) ^ nl;
        sv ^= 0x80;
      } else {
        stats[at] = (sv & 0x80) ^ nm;
      }
    }

    return sv >> 7;
  }
}
