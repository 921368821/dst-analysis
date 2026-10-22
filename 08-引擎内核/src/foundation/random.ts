/**
 * L0 · 确定性随机
 *
 * ★ 为什么不能用 `Math.random()`：饥荒风格游戏的核心承诺是
 *   **同一个种子 ⇒ 同一个世界**。上一代引擎在这上面栽过：
 *   地图用的是自己的种子随机（确定），而 prefab 构造函数里一句 `math.random()`
 *   走的是全局 RNG（从没播种）⇒ 同一棵树这次是小的、下次是大的。
 *   结果是"分享种子没意义、回放不可重复、判据只能靠容差"，而且**不报错**。
 *
 * 所以：**引擎内所有随机必须走注入的 IRandom**，且状态可序列化（存档要恢复序列）。
 * 机器守护见 `tests/arch/no-ambient-random.test.ts`。
 *
 * 算法选 XorShift128+：
 *  - 状态只有两个 64 位整数（用两个 32 位模拟，便于 JSON 序列化）；
 *  - 周期 2^128-1，质量足够游戏用；
 *  - 纯整数运算 ⇒ 跨平台逐位一致（这是"存档字节确定"的前提）。
 *  不用 Mersenne Twister：状态 624 个整数，存档里塞不进去。
 */

export interface IRandom {
  /** [0, 1) */
  next(): number;
  /** [lo, hi) 整数 */
  int(lo: number, hi: number): number;
  /** [lo, hi) 浮点 */
  range(lo: number, hi: number): number;
  /** 以 p 概率返回 true */
  chance(p: number): boolean;
  /** 原地洗牌（Fisher-Yates），返回同一数组便于链式 */
  shuffle<T>(arr: T[]): T[];
  /** 从数组取一个；空数组返回 undefined（不抛，调用方决定语义） */
  pick<T>(arr: readonly T[]): T | undefined;
  /** 可序列化状态：存档要能恢复随机序列 */
  getState(): RandomState;
  setState(s: RandomState): void;
}

export interface RandomState {
  readonly s0: number;
  readonly s1: number;
}

export class XorShift128 implements IRandom {
  private s0: number;
  private s1: number;

  constructor(seed: number) {
    // splitmix 把任意低熵种子打散，避免 0/1 之类的种子产生退化序列
    let x = seed | 0 || 0x9e3779b9;
    const next = (): number => {
      x = (x + 0x9e3779b9) | 0;
      let z = x;
      z = Math.imul(z ^ (z >>> 16), 0x85ebca6b);
      z = Math.imul(z ^ (z >>> 13), 0xc2b2ae35);
      return (z ^ (z >>> 16)) >>> 0;
    };
    this.s0 = next() || 1;
    this.s1 = next() || 2;
  }

  /** 32 位 xorshift128，返回 [0, 2^32) */
  private nextU32(): number {
    let x = this.s0;
    const y = this.s1;
    this.s0 = y;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.s1 = x >>> 0;
    return this.s1;
  }

  next(): number {
    // 取两个 32 位拼成 53 位尾数（与 double 精度对齐，不浪费也不失真）
    const hi = this.nextU32() >>> 5; // 27 位
    const lo = this.nextU32() >>> 6; // 26 位
    return (hi * 67108864 + lo) / 9007199254740992;
  }

  int(lo: number, hi: number): number {
    if (hi <= lo) return lo;
    return lo + Math.floor(this.next() * (hi - lo));
  }

  range(lo: number, hi: number): number {
    return lo + this.next() * (hi - lo);
  }

  chance(p: number): boolean {
    return this.next() < p;
  }

  shuffle<T>(arr: T[]): T[] {
    for (let i = arr.length - 1; i > 0; i--) {
      const j = this.int(0, i + 1);
      const t = arr[i]!;
      arr[i] = arr[j]!;
      arr[j] = t;
    }
    return arr;
  }

  pick<T>(arr: readonly T[]): T | undefined {
    if (arr.length === 0) return undefined;
    return arr[this.int(0, arr.length)];
  }

  getState(): RandomState {
    return { s0: this.s0, s1: this.s1 };
  }

  setState(s: RandomState): void {
    // 0/0 会让 xorshift 卡死在 0，显式拒绝
    if (s.s0 === 0 && s.s1 === 0) throw new RangeError("随机状态不能是全零");
    this.s0 = s.s0 >>> 0;
    this.s1 = s.s1 >>> 0;
  }
}

/** 固定序列随机：判据里让"随机"完全可预测（不需要猜种子）。 */
export class ScriptedRandom implements IRandom {
  private i = 0;

  constructor(private readonly seq: readonly number[]) {}

  next(): number {
    if (this.seq.length === 0) return 0;
    const v = this.seq[this.i % this.seq.length]!;
    this.i++;
    return v;
  }

  int(lo: number, hi: number): number {
    return lo + Math.floor(this.next() * (hi - lo));
  }

  range(lo: number, hi: number): number {
    return lo + this.next() * (hi - lo);
  }

  chance(p: number): boolean {
    return this.next() < p;
  }

  shuffle<T>(arr: T[]): T[] {
    return arr;
  }

  pick<T>(arr: readonly T[]): T | undefined {
    return arr[this.int(0, arr.length)];
  }

  getState(): RandomState {
    return { s0: this.i, s1: 0 };
  }

  setState(_s: RandomState): void {
    this.i = 0;
  }

  get calls(): number {
    return this.i;
  }
}

/** 派生一条独立序列（用于"每个子系统一条流"，避免互相扰动）。 */
export function deriveRandom(parent: IRandom, salt: number): XorShift128 {
  const r = new XorShift128((parent.int(1, 0x7fffffff) ^ salt) >>> 0);
  // 空转几次，打散与父序列的相关性
  for (let i = 0; i < 4; i++) r.next();
  return r;
}
