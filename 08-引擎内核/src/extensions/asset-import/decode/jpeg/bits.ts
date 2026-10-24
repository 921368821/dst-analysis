/**
 * L4 · JPEG 解码 · 熵数据位读取
 *
 * ★ `BitReader` 只在**一个 RST 区间内**使用（边界由 `splitEntropy` 预切分），
 *   所以它只处理 `FF 00` 填充，不需要在解码中途判断标记。
 *
 * ★ `HuffTable` 用 mincode/maxcode/valptr 三条表解码（F.16），
 *   而不是建一棵树：树在 16 层深度、上百个符号时既慢又占内存，且不好报错。
 */

import { fail } from "./types.ts";

/**
 * 熵编码段位读取器。**只在一个 RST 区间内使用**（边界由调用方预切分）。
 * 因此它只处理 `FF 00` 填充，不需要在解码中途判断标记 —— 这是刻意的简化。
 */
export class BitReader {
  private pos: number;
  private buf = 0;
  private cnt = 0;
  /** 区间里意外出现了标记（说明预切分与数据不一致）：之后全部补 0，让解码"跑完"而不是死循环。 */
  private stalled = false;

  constructor(
    private readonly data: Uint8Array,
    start: number,
    private readonly end: number,
  ) {
    this.pos = start;
  }

  private push(b: number): void {
    this.buf = ((this.buf << 8) | b) >>> 0;
    this.cnt += 8;
  }

  private fill(): void {
    // 每轮 cnt 至少 +8，所以循环必然在 cnt > 24 时结束（不会因 stalled 死循环）
    while (this.cnt <= 24) {
      if (this.stalled || this.pos >= this.end) {
        // 数据结束：补 0 位。规范允许用任意位填充，libjpeg 也补 0 ——
        // 用 1 填充会把"截断的文件"解成一片白，看不出这是坏文件。
        this.push(0);
        continue;
      }
      const b = this.data[this.pos]!;
      if (b !== 0xff) {
        this.pos++;
        this.push(b);
        continue;
      }
      const next = this.pos + 1 < this.end ? this.data[this.pos + 1]! : 0;
      if (next === 0x00) {
        this.pos += 2;
        this.push(0xff);
        continue;
      }
      this.stalled = true;
    }
  }

  readBit(): number {
    if (this.cnt === 0) this.fill();
    this.cnt--;
    return (this.buf >>> this.cnt) & 1;
  }

  /** 读 n 位（n ≤ 16），按 JPEG 的 MSB-first 顺序。 */
  receive(n: number): number {
    let v = 0;
    for (let i = 0; i < n; i++) v = (v << 1) | this.readBit();
    return v;
  }
}

/** JPEG 的"符号扩展"：n 位补码 → 有符号差分值（F.12 / 图 F.2）。 */
export function extend(v: number, n: number): number {
  if (n === 0) return 0;
  return v < 1 << (n - 1) ? v - (1 << n) + 1 : v;
}

// ------------------------------------------------------------------ 哈夫曼表

export class HuffTable {
  private readonly mincode = new Int32Array(17);
  private readonly maxcode = new Int32Array(18).fill(-1);
  private readonly valptr = new Int32Array(17);

  constructor(
    readonly counts: Uint8Array,
    readonly values: Uint8Array,
  ) {
    let code = 0;
    let k = 0;
    for (let len = 1; len <= 16; len++) {
      const n = counts[len - 1]!;
      this.valptr[len] = k;
      this.mincode[len] = code;
      if (n > 0) this.maxcode[len] = code + n - 1;
      k += n;
      code = (code + n) << 1;
    }
    if (k !== values.length) {
      fail("ASSET.BAD_JPEG", `DHT 表自相矛盾：code length 计数合计 ${k}，实际给了 ${values.length} 个符号`);
    }
  }

  decode(r: BitReader): number {
    let code = 0;
    for (let len = 1; len <= 16; len++) {
      code = (code << 1) | r.readBit();
      const mx = this.maxcode[len]!;
      if (mx >= 0 && code <= mx) {
        const at = this.valptr[len]! + code - this.mincode[len]!;
        const v = this.values[at];
        if (v === undefined) {
          fail("ASSET.BAD_JPEG", `DHT 查表越界：len=${len} code=${code} at=${at}`);
        }
        return v;
      }
    }
    fail("ASSET.BAD_JPEG", "哈夫曼码流非法：连续 16 位都没有匹配的码字（文件被截断或熵数据错位）");
  }
}
