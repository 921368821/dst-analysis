/**
 * L4 · 资产导入 · 解码 · zlib / deflate（纯 TS，同步）
 *
 * ★★ 为什么手写一份 inflate，而不用 `DecompressionStream` / `node:zlib`：
 *   ① **必须同步**：导入链（`AssetImportPipeline` → 图集合成）是同步的，
 *      `DecompressionStream` 只能异步读流；把它塞进同步管线就意味着整条链
 *      变异步，或者在外面用 Atomics 假同步 —— 两者都比写一个 inflate 贵。
 *   ② **跨宿主字节级一致**：Node 的 `zlib` 与浏览器 `DecompressionStream`
 *      是两份不同实现，对"坏数据"的容忍度不同（有的截断返回半截、有的抛）。
 *      判据要能断言"这个 PNG 解码出的每个字节"，就不能让底层实现换宿主就变。
 *   ③ **可诊断**：这里能报 "invalid distance 300 > 120 produced bytes at byte 512"，
 *      而原生实现只给一句 "invalid distance too far back"。修复坏资产时，
 *      前者能定位，后者只能猜。
 *   代价：比原生实现慢（大概 5~10 倍）。这只发生在**导入期**，一次导入
 *   几千张小图是可接受的；绝不能把它放到每帧渲染路径上。
 *
 * ★ 只支持 **zlib 包装**（RFC 1950：2 字节头 + deflate + adler32），
 *   不支持 gzip（RFC 1952）。PNG 的 IDAT 只可能是 zlib，多一个分支
 *   就多一种"看起来支持、实际没测"的路径。
 */

import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err, ok } from "../../../foundation/result.ts";

export const InflateErrorCode = {
  /** zlib 头/流/校验和任何一处不合法。message 带字节偏移，足够定位。 */
  BadZlib: "ASSET.BAD_ZLIB",
} as const;

/** 默认解压上限 256 MB：2048×2048 RGBA8 原始扫描线也才 ~16.8 MB。 */
const DEFAULT_MAX_BYTES = 256 * 1024 * 1024;

const MAX_BITS = 15;

/** 内部异常：只在 inflate 内部抛，边界统一转成 `Result`（见导出函数）。 */
class ZlibError extends Error {}

interface Huffman {
  /** `(len << 9) | symbol`；0 表示该前缀没有合法码字。 */
  readonly table: Uint16Array;
  readonly maxLen: number;
}

function reverseBits(code: number, len: number): number {
  let out = 0;
  for (let i = 0; i < len; i++) {
    out = (out << 1) | (code & 1);
    code >>>= 1;
  }
  return out;
}

/**
 * 由码长表构造查表式 Huffman。
 * ★ 用 2^maxLen 的表而不是逐位比较：解码每个符号是 "peek + 移位"，
 *   对 16 MB 的输出（几百万个符号）差别是数量级的。
 */
function buildHuffman(lengths: Uint8Array): Huffman {
  const counts = new Uint16Array(MAX_BITS + 1);
  for (let i = 0; i < lengths.length; i++) {
    const l = lengths[i]!;
    if (l > MAX_BITS) throw new ZlibError(`Huffman 码长 ${l} 超过 ${MAX_BITS}`);
    counts[l] = counts[l]! + 1;
  }
  counts[0] = 0; // 0 表示"未使用"，不参与 canonical 码分配

  let maxLen = MAX_BITS;
  while (maxLen > 0 && counts[maxLen] === 0) maxLen--;
  if (maxLen === 0) {
    // 全 0：没有任何码字（距离表允许，字面量表不允许 —— 由调用方在解码时报错）
    return { table: new Uint16Array(1), maxLen: 1 };
  }

  // 过订阅检查：left 是"这一层还剩多少码字空间"。
  // 未订阅（left > 0）是合法的（只有 1 个距离码的块就是这样），
  // 它不会让解码变危险 —— 只是某些位模式必然落到"非法码"。
  let left = 1;
  for (let len = 1; len <= MAX_BITS; len++) {
    left = (left << 1) - counts[len]!;
    if (left < 0) throw new ZlibError(`Huffman 码长表过订阅（len=${len} 时超出 ${-left}）`);
  }

  const nextCode = new Uint16Array(MAX_BITS + 1);
  let code = 0;
  for (let len = 1; len <= MAX_BITS; len++) {
    code = (code + counts[len - 1]!) << 1;
    nextCode[len] = code;
  }

  const size = 1 << maxLen;
  const table = new Uint16Array(size);
  for (let sym = 0; sym < lengths.length; sym++) {
    const len = lengths[sym]!;
    if (len === 0) continue;
    const c = nextCode[len]!;
    nextCode[len] = c + 1;
    // 位流是 LSB-first，canonical 码是 MSB-first：先反转再按低 len 位铺表
    const rev = reverseBits(c, len);
    const entry = (len << 9) | sym;
    const step = 1 << len;
    for (let i = rev; i < size; i += step) table[i] = entry;
  }
  return { table, maxLen };
}

// ------------------------------------------------------------------ 定长表（懒构造）

let fixedLit: Huffman | null = null;
let fixedDist: Huffman | null = null;

function getFixedLit(): Huffman {
  if (fixedLit !== null) return fixedLit;
  const lengths = new Uint8Array(288);
  for (let i = 0; i < 144; i++) lengths[i] = 8;
  for (let i = 144; i < 256; i++) lengths[i] = 9;
  for (let i = 256; i < 280; i++) lengths[i] = 7;
  for (let i = 280; i < 288; i++) lengths[i] = 8;
  fixedLit = buildHuffman(lengths);
  return fixedLit;
}

function getFixedDist(): Huffman {
  if (fixedDist !== null) return fixedDist;
  const lengths = new Uint8Array(32).fill(5);
  fixedDist = buildHuffman(lengths);
  return fixedDist;
}

// ------------------------------------------------------------------ 长度/距离表（RFC 1951 §3.2.5）

const LEN_BASE = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195,
  227, 258,
] as const;
const LEN_EXTRA = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0] as const;

const DIST_BASE = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
  6145, 8193, 12289, 16385, 24577,
] as const;
const DIST_EXTRA = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
] as const;

const CLEN_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15] as const;

// ------------------------------------------------------------------ adler32

export function adler32(data: Uint8Array): number {
  let a = 1;
  let b = 0;
  let i = 0;
  while (i < data.length) {
    // 5552 是 zlib 的经典分块大小：保证 a*255+b 不越过 2^53 之前的 32 位累加上限
    const end = Math.min(i + 5552, data.length);
    for (; i < end; i++) {
      a += data[i]!;
      b += a;
    }
    a %= 65521;
    b %= 65521;
  }
  return ((b << 16) | a) >>> 0;
}

// ------------------------------------------------------------------ 位读取器

class BitReader {
  pos: number;
  private bitBuf = 0;
  private bitCnt = 0;

  constructor(
    private readonly data: Uint8Array,
    start: number,
  ) {
    this.pos = start;
  }

  /** 尽可能补到 n 位（不抛）：流末尾不足时由调用方判断。 */
  private ensure(n: number): void {
    while (this.bitCnt < n && this.pos < this.data.length) {
      this.bitBuf |= this.data[this.pos]! << this.bitCnt;
      this.bitCnt += 8;
      this.pos++;
    }
  }

  readBits(n: number): number {
    if (n === 0) return 0;
    this.ensure(n);
    if (this.bitCnt < n) throw new ZlibError(`位流截断：需要 ${n} 位，只剩 ${this.bitCnt} 位`);
    const v = this.bitBuf & ((1 << n) - 1);
    this.bitBuf >>>= n;
    this.bitCnt -= n;
    return v;
  }

  decode(h: Huffman): number {
    this.ensure(h.maxLen);
    if (this.bitCnt === 0) throw new ZlibError("位流截断：Huffman 解码时已无数据");
    const entry = h.table[this.bitBuf & ((1 << h.maxLen) - 1)]!;
    if (entry === 0) throw new ZlibError(`非法 Huffman 码（peek 0x${(this.bitBuf & ((1 << h.maxLen) - 1)).toString(16)}）`);
    const len = entry >>> 9;
    if (len > this.bitCnt) throw new ZlibError("位流截断：Huffman 码字跨越了输入末尾");
    this.bitBuf >>>= len;
    this.bitCnt -= len;
    return entry & 0x1ff;
  }

  /**
   * 丢弃当前字节里剩余的位，并把"已预读但未消费的整字节"退回 pos。
   * 之后 `pos` 指向下一个未读字节 —— stored 块和 adler32 都靠它对齐。
   */
  alignToByte(): void {
    const drop = this.bitCnt & 7;
    this.bitBuf >>>= drop;
    this.bitCnt -= drop;
    this.pos -= this.bitCnt >> 3;
    this.bitBuf = 0;
    this.bitCnt = 0;
  }

  /** u16 小端（stored 块的 LEN/NLEN）。调用前必须 `alignToByte()`。 */
  u16le(): number {
    if (this.pos + 2 > this.data.length) throw new ZlibError("stored 块头截断");
    const v = this.data[this.pos]! | (this.data[this.pos + 1]! << 8);
    this.pos += 2;
    return v;
  }
}

// ------------------------------------------------------------------ 输出缓冲

class ByteSink {
  buf: Uint8Array;
  len = 0;
  private readonly maxBytes: number;

  constructor(initial: number, maxBytes: number) {
    this.maxBytes = maxBytes;
    this.buf = new Uint8Array(Math.max(1, Math.min(initial, maxBytes)));
  }

  private reserve(n: number): void {
    const need = this.len + n;
    if (need > this.maxBytes) {
      throw new ZlibError(`解压输出超过上限 maxBytes=${this.maxBytes}（已产出 ${this.len} 字节，再写 ${n}）`);
    }
    if (need <= this.buf.length) return;
    let cap = this.buf.length * 2;
    if (cap < need) cap = need;
    if (cap > this.maxBytes) cap = this.maxBytes;
    const next = new Uint8Array(cap);
    next.set(this.buf.subarray(0, this.len));
    this.buf = next;
  }

  writeByte(b: number): void {
    this.reserve(1);
    this.buf[this.len++] = b;
  }

  writeBytes(src: Uint8Array, from: number, count: number): void {
    this.reserve(count);
    this.buf.set(src.subarray(from, from + count), this.len);
    this.len += count;
  }

  copyBack(distance: number, count: number): void {
    this.reserve(count);
    const b = this.buf;
    let src = this.len - distance;
    let dst = this.len;
    // 逐字节复制：距离 < 长度时源和目标是重叠的（LZ77 的自我引用），
    // 用 copyWithin/set 会读到还没写出的旧数据。
    for (let i = 0; i < count; i++) b[dst + i] = b[src + i]!;
    this.len += count;
  }

  finish(): Uint8Array {
    return this.buf.slice(0, this.len);
  }
}

// ------------------------------------------------------------------ 主流程

export interface InflateOptions {
  /** 输出字节上限（防解压炸弹）。默认 256 MB。 */
  readonly maxBytes?: number;
  /** 预期输出大小（只影响初始分配，不参与校验）。 */
  readonly sizeHint?: number;
}

/**
 * 解 zlib 流（RFC 1950）。
 *
 * 支持 deflate 的三种块：stored(0) / fixed Huffman(1) / dynamic Huffman(2)。
 * 校验 zlib 头、CM 必须为 8、FCHECK、FDICT 不支持、adler32、流尾无多余字节。
 */
export function inflateZlib(data: Uint8Array, opts?: InflateOptions): Result<Uint8Array, EngineError> {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_BYTES;
  try {
    if (data.length < 6) {
      // 2 字节头 + 至少 1 字节块 + 4 字节 adler32
      throw new ZlibError(`zlib 数据过短：${data.length} 字节（至少 6）`);
    }
    const cmf = data[0]!;
    const flg = data[1]!;
    if ((cmf & 0x0f) !== 8) {
      throw new ZlibError(`zlib CM=${cmf & 0x0f}（只支持 8 = deflate）`);
    }
    if (cmf >> 4 > 7) {
      throw new ZlibError(`zlib CINFO=${cmf >> 4} 非法（窗口 > 32K，规范上限 7）`);
    }
    if (((cmf << 8) | flg) % 31 !== 0) {
      throw new ZlibError(
        `zlib 头校验失败：CMF=0x${cmf.toString(16)} FLG=0x${flg.toString(16)}，(CMF*256+FLG)%31 != 0`,
      );
    }
    if ((flg & 0x20) !== 0) {
      throw new ZlibError("zlib FDICT=1：不支持预置字典（PNG 不会用）");
    }

    const br = new BitReader(data, 2);
    const sink = new ByteSink(opts?.sizeHint !== undefined ? opts.sizeHint : 64 * 1024, maxBytes);
    const fail = (msg: string): never => {
      throw new ZlibError(`${msg} at byte ${br.pos}`);
    };

    let isFinal = 0;
    do {
      isFinal = br.readBits(1);
      const type = br.readBits(2);
      if (type === 0) {
        // ---- stored ----
        br.alignToByte();
        const len = br.u16le();
        const nlen = br.u16le();
        if (((len ^ 0xffff) & 0xffff) !== nlen) {
          fail(`stored 块的 LEN/NLEN 不互补：LEN=${len} NLEN=${nlen}`);
        }
        if (br.pos + len > data.length) {
          fail(`stored 块截断：需要 ${len} 字节，剩余 ${data.length - br.pos}`);
        }
        sink.writeBytes(data, br.pos, len);
        br.pos += len;
      } else if (type === 1 || type === 2) {
        let lit: Huffman;
        let dist: Huffman;
        if (type === 1) {
          lit = getFixedLit();
          dist = getFixedDist();
        } else {
          const tables = readDynamicTables(br, fail);
          lit = tables.lit;
          dist = tables.dist;
        }
        decodeCompressed(br, lit, dist, sink, fail);
      } else {
        fail(`invalid block type ${type}（deflate 只有 0/1/2）`);
      }
    } while (isFinal === 0);

    // ---- 对齐 + adler32 + 尾部检查 ----
    br.alignToByte();
    if (br.pos + 4 > data.length) {
      throw new ZlibError(`zlib 流缺少 adler32 尾（pos=${br.pos} 长度=${data.length}）`);
    }
    const expected = ((data[br.pos]! << 24) | (data[br.pos + 1]! << 16) | (data[br.pos + 2]! << 8) | data[br.pos + 3]!) >>> 0;
    const actual = adler32(sink.buf.subarray(0, sink.len));
    if (expected !== actual) {
      throw new ZlibError(
        `adler32 校验失败：期望 0x${expected.toString(16).padStart(8, "0")}，实际 0x${actual
          .toString(16)
          .padStart(8, "0")}`,
      );
    }
    if (br.pos + 4 !== data.length) {
      throw new ZlibError(`zlib 流后有 ${data.length - (br.pos + 4)} 字节多余数据（pos=${br.pos + 4}）`);
    }

    return ok(sink.finish());
  } catch (e) {
    if (e instanceof ZlibError) return err(engineError(InflateErrorCode.BadZlib, e.message));
    // 意外异常（典型是超大分配 OOM 边界）也归类到这里，但保留"内部"前缀便于区分
    return err(
      engineError(InflateErrorCode.BadZlib, `inflate 内部错误：${e instanceof Error ? e.message : String(e)}`),
    );
  }
}

// ------------------------------------------------------------------ dynamic Huffman

function readDynamicTables(
  br: BitReader,
  fail: (msg: string) => never,
): { readonly lit: Huffman; readonly dist: Huffman } {
  const hlit = br.readBits(5) + 257;
  const hdist = br.readBits(5) + 1;
  const hclen = br.readBits(4) + 4;
  if (hlit > 286) fail(`HLIT=${hlit - 257} 非法（最多 286 个字面量/长度码）`);
  if (hdist > 30) fail(`HDIST=${hdist - 1} 非法（最多 30 个距离码）`);

  const clenLengths = new Uint8Array(19);
  for (let i = 0; i < hclen; i++) clenLengths[CLEN_ORDER[i]!] = br.readBits(3);
  let clen: Huffman;
  try {
    clen = buildHuffman(clenLengths);
  } catch (e) {
    fail(`码长表的 Huffman 构造失败：${e instanceof Error ? e.message : String(e)}`);
  }

  const total = hlit + hdist;
  const lengths = new Uint8Array(total);
  let i = 0;
  while (i < total) {
    const sym = br.decode(clen);
    if (sym < 16) {
      lengths[i++] = sym;
    } else if (sym === 16) {
      if (i === 0) fail("码长重复码 16 出现在第一个码长之前（没有可复制的上一个值）");
      const repeat = br.readBits(2) + 3;
      if (i + repeat > total) fail(`码长重复码 16 越界：i=${i} repeat=${repeat} total=${total}`);
      const prev = lengths[i - 1]!;
      for (let k = 0; k < repeat; k++) lengths[i++] = prev;
    } else if (sym === 17) {
      const repeat = br.readBits(3) + 3;
      if (i + repeat > total) fail(`码长重复码 17 越界：i=${i} repeat=${repeat} total=${total}`);
      i += repeat; // Uint8Array 默认 0
    } else if (sym === 18) {
      const repeat = br.readBits(7) + 11;
      if (i + repeat > total) fail(`码长重复码 18 越界：i=${i} repeat=${repeat} total=${total}`);
      i += repeat;
    } else {
      fail(`非法码长符号 ${sym}（只允许 0..18）`);
    }
  }

  const litLengths = lengths.subarray(0, hlit);
  const distLengths = lengths.subarray(hlit);
  if (litLengths[256] === 0) fail("字面量表缺少块结束符 256 的码字");
  try {
    return { lit: buildHuffman(litLengths), dist: buildHuffman(distLengths) };
  } catch (e) {
    fail(`Huffman 表构造失败：${e instanceof Error ? e.message : String(e)}`);
  }
}

// ------------------------------------------------------------------ 压缩块解码

function decodeCompressed(
  br: BitReader,
  lit: Huffman,
  dist: Huffman,
  sink: ByteSink,
  fail: (msg: string) => never,
): void {
  for (;;) {
    const sym = br.decode(lit);
    if (sym < 256) {
      sink.writeByte(sym);
      continue;
    }
    if (sym === 256) return;
    if (sym > 285) fail(`非法长度符号 ${sym}（286/287 保留）`);

    const li = sym - 257;
    const length = LEN_BASE[li]! + br.readBits(LEN_EXTRA[li]!);

    const dsym = br.decode(dist);
    if (dsym > 29) fail(`非法距离符号 ${dsym}（30/31 保留）`);
    const distance = DIST_BASE[dsym]! + br.readBits(DIST_EXTRA[dsym]!);
    if (distance > sink.len) {
      fail(`invalid distance ${distance} > 已产出 ${sink.len} 字节`);
    }
    sink.copyBack(distance, length);
  }
}
