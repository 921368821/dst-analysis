/**
 * L0 · 数学工具
 */

export const TAU = Math.PI * 2;

export function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}

export function clamp01(v: number): number {
  return clamp(v, 0, 1);
}

export function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

/** 角度归一化到 (-π, π]。 */
export function wrapAngle(rad: number): number {
  let a = rad % TAU;
  if (a <= -Math.PI) a += TAU;
  else if (a > Math.PI) a -= TAU;
  return a;
}

/** 近似相等：**相对 + 绝对**双判据（大数上绝对误差会失效，小数上相对误差会失效）。 */
export function nearlyEqual(a: number, b: number, relEps = 1e-9, absEps = 1e-12): boolean {
  if (a === b) return true;
  const diff = Math.abs(a - b);
  if (diff <= absEps) return true;
  const scale = Math.max(Math.abs(a), Math.abs(b));
  return diff <= relEps * scale;
}

/**
 * 把浮点四舍五入到指定小数位。
 *
 * ★ 存在的理由是**确定性**：跨平台的 `toFixed` 在极端值上行为有差异，
 *   而"两份存档/两次回放要逐字节相同"要求一个我们自己定义的量化函数。
 *   与上一代引擎 `string.format("%.3f")` 的口径对齐（三位小数）。
 */
export function quantize(v: number, decimals = 3): number {
  const f = Math.pow(10, decimals);
  // 加一个极小量避免 1.0005 → 1.000 这类边界抖动
  return (Math.sign(v) * Math.round(Math.abs(v) * f + 1e-9)) / f;
}
