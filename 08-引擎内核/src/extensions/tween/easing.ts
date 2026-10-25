/**
 * L4 · 补间 · 缓动函数族
 *
 * 这一层回答一个问题：**"归一化进度 t ∈ [0,1] 该映射成什么比例"**。
 * 它不知道补间的两端是什么、不知道时长、不知道谁在用它 —— 那些都在 `tween.ts`。
 *
 * ★ 为什么不直接让调用方传一条贝塞尔/曲线数据：
 *   曲线数据要解决"怎么编辑、怎么序列化、怎么和美术对齐"，那是编辑器的事。
 *   而引擎侧的最小可用集是**一组数学上已证明的性质**（见下面的判据口径），
 *   先用命名函数把这些性质固定下来，将来要支持自定义曲线时，
 *   新曲线必须通过同一组性质判据才能进注册表 —— 不会因为"能传函数"就放进坏曲线。
 *
 * ★ 值域允许越界 [0,1]：`back`/`elastic` 会先冲过目标再回来，
 *   这是"回弹手感"的来源，夹住它就等于只剩一个二次曲线。
 *   越界由调用方决定是否夹取（UI 透明度通常要夹，物理位移不要）。
 *
 * ★ 边界 t=0 / t=1 必须精确等于 0 / 1：
 *   `elastic` 与 `bounce` 的解析式在端点会有 0×∞ 或空段，
 *   不特判就会得到 NaN 或 ±ε 的漂移。NaN 会沿补间扩散成"这个控件永远不出现"，
 *   而端点漂移会让"播完"判定在最后一帧抖动。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 缓动函数：输入归一化进度，输出比例（可越界）。 */
export type EasingFn = (t: number) => number;

export const EASING_ERR = {
  UNKNOWN: "TWEEN.UNKNOWN_EASING",
} as const;

// ---------------------------------------------------------------- 基础族
//
// 命名沿用 Robert Penner 的经典分组（quad/cubic/quart/quint/sine/expo/circ），
// 后缀 in（慢起）/ out（慢收）/ inOut（两端慢）。三者的关系是一条恒等式：
//     out(t)  = 1 - in(1 - t)
//     inOut(t) = t < 0.5 ? in(2t)/2 : 1 - out(2t - 1)/2
// 但**不**用这条恒等式去生成 —— 手写展开式可以让端点精确落 0/1，
// 而恒等式会把 in(1) 的浮点误差带进 out(0)。判据里有"out 与 in 互为镜像"
// 这一条，它验证的是等价性，不是实现方式。

function quadIn(t: number): number {
  return t * t;
}
function quadOut(t: number): number {
  return t * (2 - t);
}
function quadInOut(t: number): number {
  return t < 0.5 ? 2 * t * t : -1 + (4 - 2 * t) * t;
}

function cubicIn(t: number): number {
  return t * t * t;
}
function cubicOut(t: number): number {
  const u = t - 1;
  return u * u * u + 1;
}
function cubicInOut(t: number): number {
  return t < 0.5 ? 4 * t * t * t : (t - 1) * (2 * t - 2) * (2 * t - 2) + 1;
}

function quartIn(t: number): number {
  return t * t * t * t;
}
function quartOut(t: number): number {
  const u = t - 1;
  return 1 - u * u * u * u;
}
function quartInOut(t: number): number {
  return t < 0.5 ? 8 * t * t * t * t : 1 - 8 * (t - 1) * (t - 1) * (t - 1) * (t - 1);
}

function quintIn(t: number): number {
  return t * t * t * t * t;
}
function quintOut(t: number): number {
  const u = t - 1;
  return 1 + u * u * u * u * u;
}
function quintInOut(t: number): number {
  return t < 0.5 ? 16 * t * t * t * t * t : 1 + 16 * (t - 1) * (t - 1) * (t - 1) * (t - 1) * (t - 1);
}

// sine 的端点是三角函数算出来的：`1 - Math.cos(Math.PI/2)` 在浮点下等于
// 0.9999999999999999（cos(π/2) 不是精确 0）。端点是判据里最弱也最要紧的一条，
// 差 1e-16 会让"播完"的边界判定抖动，所以 t=1 特判。
function sineIn(t: number): number {
  if (t === 1) return 1;
  return 1 - Math.cos((t * Math.PI) / 2);
}
function sineOut(t: number): number {
  return Math.sin((t * Math.PI) / 2);
}
function sineInOut(t: number): number {
  return 0.5 * (1 - Math.cos(Math.PI * t));
}

// expo 的端点是 2 的大幂，t=0 时 2^-10 会给出 1-2^-10 ≈ 0.999 —— 那会让
// "刚开始"就已经走完 99.9%。必须特判（下同）。
function expoIn(t: number): number {
  return t === 0 ? 0 : Math.pow(2, 10 * (t - 1));
}
function expoOut(t: number): number {
  return t === 1 ? 1 : 1 - Math.pow(2, -10 * t);
}
function expoInOut(t: number): number {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return t < 0.5 ? 0.5 * Math.pow(2, 10 * (2 * t - 1)) : 1 - 0.5 * Math.pow(2, -10 * (2 * t - 1));
}

function circIn(t: number): number {
  return 1 - Math.sqrt(1 - t * t);
}
function circOut(t: number): number {
  const u = t - 1;
  return Math.sqrt(1 - u * u);
}
function circInOut(t: number): number {
  return t < 0.5 ? 0.5 * (1 - Math.sqrt(1 - 4 * t * t)) : 0.5 * (Math.sqrt(1 - (2 * t - 2) * (2 * t - 2)) + 1);
}

// ---------------------------------------------------------------- 越界族
//
// 这三个族会冲过目标再回来，所以值域超出 [0,1]。
// `s` 是回冲幅度，取 Penner 原值 1.70158；`inOut` 用 s*1.525（两段各回冲一次，
// 单段幅度要小一些，否则中点附近会甩出 1.3 以上的值）。

const BACK_S = 1.70158;

// ★ back 族三个都要特判 t===0：`0 * ((S+1)*0 - S)` 在 IEEE 下等于 **-0**
//   （0 乘负数得 -0），而 `assert.equal(-0, 0)` 在严格模式下不相等 ——
//   端点判据会红，而下游拿到 -0 存进坐标也只是个难看的数。
//   t===1 同理要特判 backIn：`1*1*((S+1)-S)` 浮点得 0.9999999999999998。
//   这类"符号位/末位为零"的问题在乘法里很常见，端点特判是最便宜的兜底。
function backIn(t: number): number {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return t * t * ((BACK_S + 1) * t - BACK_S);
}
function backOut(t: number): number {
  if (t === 0) return 0;
  const u = t - 1;
  return u * u * ((BACK_S + 1) * u + BACK_S) + 1;
}
function backInOut(t: number): number {
  if (t === 0) return 0;
  const s = BACK_S * 1.525;
  if (t < 0.5) {
    const u = 2 * t;
    return 0.5 * (u * u * ((s + 1) * u - s));
  }
  const u = 2 * t - 2;
  return 0.5 * (u * u * ((s + 1) * u + s) + 2);
}

// elastic：角频率与相位取自 Penner 参数化 `p = 0.3d`、`s = p/4`。
// ★ 端点特判**不能**代替公式正确：s 写成 0.1（而不是 0.075）时，t=0 仍被特判
//   成 0，一切判据都绿，而 elasticInOut 的中点会漂到 0.567 —— 那正是本批
//   判据抓到的真错。所以这里保留公式原样，让中点判据去守它。
const ELASTIC_P = 0.3; // 一次完整摆动的归一化周期
const ELASTIC_S = ELASTIC_P / 4; // 相位偏移：s*2π/p = π/2，保证 f(0)=0

function elasticIn(t: number): number {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return -Math.pow(2, 10 * (t - 1)) * Math.sin(((t - 1 - ELASTIC_S) * 2 * Math.PI) / ELASTIC_P);
}
function elasticOut(t: number): number {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return Math.pow(2, -10 * t) * Math.sin(((t - ELASTIC_S) * 2 * Math.PI) / ELASTIC_P) + 1;
}
/**
 * elasticInOut 不照抄 Penner 的分段式，而由 in/out 各半构造：
 *   t < 0.5 → elasticIn(2t)/2；否则 → elasticOut(2t-1)/2 + 0.5
 *
 * ★ 为什么：分段式的两支在中点并不自然相等（它靠相位偏移恰好对上，抄错一个
 *   数就漂），而这个构造**自动**满足：中点 = 0.5、端点 = 0/1、中心对称
 *   f(0.5+x)+f(0.5-x) = 1。基础族仍用展开式（见文件头），这里破例是因为
 *   elastic 的解析式分支切换点正是最容易写错的地方。
 */
function elasticInOut(t: number): number {
  if (t === 0) return 0;
  if (t === 1) return 1;
  return t < 0.5 ? elasticIn(2 * t) / 2 : elasticOut(2 * t - 1) / 2 + 0.5;
}

// bounce：唯一一个**不单调**的族（落地前有多次小回落），所以判据不能对它
// 要求单调性。它的判据是"每段落点恰好命中 7.0625 / 3.90625 / … 这一串"
// （见 tween.test.ts），那才是它的形状。
const BOUNCE_N = 7.5625;
const BOUNCE_D = 2.75;

function bounceOut(t: number): number {
  if (t < 1 / BOUNCE_D) return BOUNCE_N * t * t;
  if (t < 2 / BOUNCE_D) {
    const u = t - 1.5 / BOUNCE_D;
    return BOUNCE_N * u * u + 0.75;
  }
  if (t < 2.5 / BOUNCE_D) {
    const u = t - 2.25 / BOUNCE_D;
    return BOUNCE_N * u * u + 0.9375;
  }
  const u = t - 2.625 / BOUNCE_D;
  return BOUNCE_N * u * u + 0.984375;
}
function bounceIn(t: number): number {
  return 1 - bounceOut(1 - t);
}
function bounceInOut(t: number): number {
  return t < 0.5 ? 0.5 * (1 - bounceOut(1 - 2 * t)) : 0.5 * bounceOut(2 * t - 1) + 0.5;
}

/** 阶梯：前半 0、后半 1。用于"逐格跳"的表现（像素风的位移常要它）。 */
function step(t: number): number {
  return t < 1 ? 0 : 1;
}

// ---------------------------------------------------------------- 注册表

/**
 * 内置缓动表。键名即资产/配置里写的字符串。
 *
 * ★ 表是**冻结**的：调用方拿到的是同一批函数对象，`getEasing` 不许返回可写入口。
 *   允许运行时塞曲线的话，"同一条曲线两次构造不一致"就无法归因。
 */
export const EASINGS: Readonly<Record<string, EasingFn>> = Object.freeze({
  linear: (t) => t,
  quadIn,
  quadOut,
  quadInOut,
  cubicIn,
  cubicOut,
  cubicInOut,
  quartIn,
  quartOut,
  quartInOut,
  quintIn,
  quintOut,
  quintInOut,
  sineIn,
  sineOut,
  sineInOut,
  expoIn,
  expoOut,
  expoInOut,
  circIn,
  circOut,
  circInOut,
  backIn,
  backOut,
  backInOut,
  elasticIn,
  elasticOut,
  elasticInOut,
  bounceIn,
  bounceOut,
  bounceInOut,
  step,
});

/** 全部内置缓动名（判据与文档清单同源，避免两处手写漂移）。 */
export const EASING_NAMES: readonly string[] = Object.freeze(Object.keys(EASINGS));

/**
 * 按名取缓动。
 *
 * ★ 拼错返回 `TWEEN.UNKNOWN_EASING` 而不是抛，也不回落 `linear`：
 *   与 `InputMap` 拼错抛错是同一条思路的两种落地 —— 这里是**资产/配置期**的错误，
 *   要让人在加载时就看见；回落 linear 会让"我配了 elastic 却像 linear"
 *   这种问题永远查不到。
 */
export function getEasing(name: string): Result<EasingFn, EngineError> {
  const fn = EASINGS[name];
  if (fn === undefined) {
    return err(
      engineError(
        EASING_ERR.UNKNOWN,
        `未知缓动 ${JSON.stringify(name)}；可用：${EASING_NAMES.join(", ")}`,
        { name },
      ),
    );
  }
  return ok(fn);
}
