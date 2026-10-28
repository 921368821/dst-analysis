/**
 * L4 · 补间 · 三次贝塞尔缓动（自定义曲线的**数据**形态）
 *
 * `easing.ts` 的 31 条命名曲线是**代码**（一组已证明性质的函数）。
 * 这一层补的是另一半：美术/策划要的曲线是**数据** —— 四个控制点，
 * 存在资产里、能被编辑器拖、能随存档走。
 *
 * ★★ 为什么曲线是「字符串」而不是「四个数」或「一个函数」：
 *   - 一个函数：对象进不了存档，编辑器也没法画它的控制柄；
 *   - 四个数：得先定义"谁的四元组"，于是每处调用都要拆包/组包，
 *     序列化时又多一层结构 —— 而字符串在资产里就是它自己；
 *   - 字符串：`cubic-bezier(0.25, 0.1, 0.25, 1)` 与 CSS 的写法逐字相同，
 *     美术从设计工具里复制过来就能用，**不需要翻译**。
 *   这就是 [C14] 卡住的那个前置问题（曲线是数据还是代码）的答案：
 *   **标识是数据（字符串），求值是代码（构造一次）**。`TweenSpec.ease`
 *   在构造期把它变成函数，采样期不再解析（每帧解析一次正则纯属浪费，
 *   而且会让"同一份 spec 两次采样结果不同"这种事有可乘之机）。
 *
 * ★ 与 CSS `cubic-bezier()` 的差异只有一处，且是**收紧**：
 *   CSS 只要求 x1/x2 ∈ [0,1]（保证 x(t) 单调、反解唯一），y 任意（回弹的来源）。
 *   这里同样要求 x ∈ [0,1]、y 不限 —— 没有放宽也没有多收。
 *
 * ★ 为什么端点必须特判而不是靠迭代收敛：
 *   `x(t)` 的反解在 t=0/1 附近导数最小（x1=0 时导数为 0），牛顿法在那儿
 *   收敛得最慢；而 f(0)/f(1) 是**被补间用来判终点**的量 ——
 *   差 1e-16 就会让"播完了但位置差一点"永久留在实体上（见 `tween.ts` 文件头）。
 *   特判让它精确等于字面 0 与 1，与命名曲线同一口径。
 */

import type { EasingFn } from "./easing.ts";
import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

export const BEZIER_ERR = {
  /** 字符串不是 `cubic-bezier(a,b,c,d)` 的形状。 */
  BAD_SYNTAX: "TWEEN.BAD_BEZIER_SYNTAX",
  /** 形状对，但控制点非法（非有限，或 x 越出 [0,1]）。 */
  BAD_CONTROL: "TWEEN.BAD_BEZIER_CONTROL",
} as const;

/**
 * 一个数字的字面量形状：`1` / `-0.25` / `.5` / `1e-3`。
 *
 * ★ 不用 `Number()` 直接试转：`Number("")` 是 0、`Number("  ")` 是 0、
 *   `Number("0x10")` 是 16 —— 一串"看着像数字"的垃圾会被悄悄接受。
 *   正则先钉形状，再交给 `Number` 取值。
 */
const NUM = "[-+]?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][-+]?\\d+)?";

/** `cubic-bezier(a, b, c, d)`，参数间允许空白（与 CSS 一样）。 */
const CUBIC_RE = new RegExp(
  `^\\s*cubic-bezier\\(\\s*(${NUM})\\s*,\\s*(${NUM})\\s*,\\s*(${NUM})\\s*,\\s*(${NUM})\\s*\\)\\s*$`,
);

/** 贝塞尔一维分量：P0=0、P1=a、P2=b、P3=1。 */
function sampleCurve(a: number, b: number, t: number): number {
  const mt = 1 - t;
  return 3 * mt * mt * t * a + 3 * mt * t * t * b + t * t * t;
}

/** `sampleCurve` 对 t 的导数（牛顿法的斜率）。 */
function sampleDeriv(a: number, b: number, t: number): number {
  const mt = 1 - t;
  return 3 * mt * mt * a + 6 * mt * t * (b - a) + 3 * t * t * (1 - b);
}

/** 牛顿迭代次数上限。收敛判据 1e-9 远小于判据的容差（1e-6）。 */
const NEWTON_STEPS = 8;
/** 二分兜底次数：2^-32 ≈ 2.3e-10，足够到 1e-9 量级。 */
const BISECT_STEPS = 32;
const SOLVE_EPS = 1e-9;

/**
 * 求 `t` 使 `x(t) = x`。
 *
 * ★ 先牛顿、后二分，两层不是为了"更快"，是为了**确定**：
 *   牛顿在 `x1=0`（导数为 0）附近会给出 `t=NaN` 或跳出 [0,1]；
 *   直接返回会让一段合法曲线的某个进度得到 NaN，症状是"控件闪一下就没了"。
 *   二分在 `x(t)` 单调（x1/x2 ∈ [0,1] 已保证）时**必然**收敛，
 *   代价是 32 次迭代 —— 每帧每条轨道一次，可忽略。
 */
function solveT(x1: number, x2: number, x: number): number {
  let t = x;
  for (let i = 0; i < NEWTON_STEPS; i++) {
    const diff = sampleCurve(x1, x2, t) - x;
    if (Math.abs(diff) < SOLVE_EPS) return t;
    const d = sampleDeriv(x1, x2, t);
    if (Math.abs(d) < 1e-6) break;
    const next = t - diff / d;
    if (!(next >= 0 && next <= 1)) break;
    t = next;
  }
  let lo = 0;
  let hi = 1;
  t = x;
  for (let i = 0; i < BISECT_STEPS; i++) {
    const xt = sampleCurve(x1, x2, t);
    if (Math.abs(xt - x) < SOLVE_EPS) return t;
    if (xt < x) lo = t;
    else hi = t;
    t = (lo + hi) / 2;
  }
  return t;
}

/**
 * 构造一条三次贝塞尔缓动：`cubic-bezier(x1, y1, x2, y2)`。
 *
 * ★ 控制点非法在这里**抛**，不返回 Result：四个数是**代码**给的（算出来的、
 *   写死的），传错是编程错误；而字符串来自资产，那条入口是 `parseCubicBezier`
 *   （返回 Result，带可诊断的错误码）。两条入口各给合适的形态，
 *   而不是让资产错误去接受一个 RangeError。
 *
 * ★ x1/x2 必须落在 [0,1]：这保证 `x(t)` 单调 ⇒ 每个 x 只有一个 t。
 *   放宽会让"同一进度对应两个时刻"，反解取哪个都是猜的 —— CSS 也在这里拒绝。
 *   y1/y2 **不限**：`0.34, 1.56, 0.64, 1` 这类越界 y 正是回弹的来源。
 */
export function cubicBezier(x1: number, y1: number, x2: number, y2: number): EasingFn {
  for (const [name, v] of [["x1", x1], ["y1", y1], ["x2", x2], ["y2", y2]] as const) {
    if (!Number.isFinite(v)) {
      throw new RangeError(`cubic-bezier 的 ${name} 必须是有限数：${String(v)}`);
    }
  }
  if (x1 < 0 || x1 > 1 || x2 < 0 || x2 > 1) {
    throw new RangeError(
      `cubic-bezier 的 x1/x2 必须在 [0,1]：x1=${String(x1)} x2=${String(x2)}` +
        "（越界会让 x(t) 非单调，同一进度对应多个时刻）",
    );
  }
  return (t: number): number => {
    // 端点特判：精确 0/1（见文件头）。
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return sampleCurve(y1, y2, solveT(x1, x2, t));
  };
}

/**
 * 解析 `cubic-bezier(a, b, c, d)` 字符串。
 *
 * ★ 语法错与参数越界分两个错误码：前者是"抄错了"，后者是"抄对了但不能用"，
 *   排查时该看的地方不同（前者去资产里找那行字，后者去设计工具里看控制柄）。
 */
export function parseCubicBezier(text: string): Result<EasingFn, EngineError> {
  const m = CUBIC_RE.exec(text);
  if (m === null) {
    return err(
      engineError(BEZIER_ERR.BAD_SYNTAX, `不是 cubic-bezier(a,b,c,d) 的形状：${JSON.stringify(text)}`, {
        text,
      }),
    );
  }
  const nums: number[] = [];
  for (let i = 1; i <= 4; i++) nums.push(Number(m[i]));
  try {
    return ok(cubicBezier(nums[0]!, nums[1]!, nums[2]!, nums[3]!));
  } catch (e) {
    return err(
      engineError(BEZIER_ERR.BAD_CONTROL, e instanceof Error ? e.message : String(e), { text }),
    );
  }
}

/** 这个字符串是不是 `cubic-bezier(` 形式（用于 `getEasing` 分流，不解析内容）。 */
export function looksLikeCubicBezier(text: string): boolean {
  return /^\s*cubic-bezier\s*\(/.test(text);
}
