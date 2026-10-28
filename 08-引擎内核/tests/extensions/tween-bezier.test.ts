/**
 * 三次贝塞尔缓动的判据（C14-a）
 *
 * 这一组守的是**曲线本身**，与 `tween.test.ts` 里那组命名曲线的口径相同：
 * 端点精确、方向（单调）、区间外夹取。多出来的两类是贝塞尔特有的：
 *   ① **反解正确性** —— 贝塞尔给的是参数曲线 (x(t), y(t))，要得到 f(x) 必须反解 t。
 *      实现里用牛顿 + 二分，判据不能只看"输出像不像"，必须用**独立算法**
 *      （de Casteljau 几何构造）算出的 (x, y) 对去验证 f(x) === y；
 *   ② **形状锚点** —— 手算两个点的精确值（0.3125 → 0.5375、0.6575 → 0.5），
 *      它们不来自任何实现，是从三次式里算出来的字面数。
 *
 * ★ 为什么必须有一条「cubic-bezier 真的被采样用了」的端到端判据：
 *   批118 之前 `sampleTween` 里是 `EASINGS[spec.easing]!` —— 自定义曲线名不在表里，
 *   拿到 `undefined` 会在第一帧崩。函数构造得再对，只要采样还走查表，
 *   这条链就是断的。变异 M672 打的正是这个点。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  BEZIER_ERR,
  cubicBezier,
  looksLikeCubicBezier,
  parseCubicBezier,
} from "../../src/extensions/tween/bezier.ts";
import { EASING_ERR, EASINGS, getEasing } from "../../src/extensions/tween/easing.ts";
import { makeTween, sampleTween, TWEEN_ERR } from "../../src/extensions/tween/tween.ts";

/** 独立实现：de Casteljau 几何构造（与源码里的多项式展开是两条路）。 */
function deCasteljau(p0: number, p1: number, p2: number, p3: number, t: number): number {
  const a = p0 + (p1 - p0) * t;
  const b = p1 + (p2 - p1) * t;
  const c = p2 + (p3 - p2) * t;
  const d = a + (b - a) * t;
  const e = b + (c - b) * t;
  return d + (e - d) * t;
}

/** 四条代表曲线：标准 ease、ease-in、y 越界（回弹）、y 交叉（非单调）。 */
const CURVES: readonly (readonly [number, number, number, number])[] = [
  [0.25, 0.1, 0.25, 1],
  [0.42, 0, 1, 1],
  [0.34, 1.56, 0.64, 1],
  [0.3, 0.7, 0.6, 0.2],
  // ★ x1=x2=0 ⇒ x(t)=t³，在 t 很小时导数为 0：牛顿法在这里必然失效，
  //   只有二分兜底能救。没有这条曲线，删掉二分兜底的变异是抓不到的（M669）。
  [0, 0, 0, 1],
];

// ---------------------------------------------------------------- 性质

test("★ 端点精确等于 0 与 1（不是 1e-16 的近似）", () => {
  for (const [x1, y1, x2, y2] of CURVES) {
    const f = cubicBezier(x1, y1, x2, y2);
    assert.equal(f(0), 0, `f(0) 必须严格为 0：${String(f(0))}`);
    assert.equal(f(1), 1, `f(1) 必须严格为 1：${String(f(1))}`);
  }
});

test("★ 区间外夹取：t<0 给 0、t>1 给 1（不许外推成回弹放大）", () => {
  const f = cubicBezier(0.34, 1.56, 0.64, 1);
  assert.equal(f(-0.5), 0);
  assert.equal(f(1.5), 1);
  assert.equal(f(-1000), 0);
});

test("★ cubic-bezier(0,0,1,1) 与 linear 逐点等价（端点控制点即恒等）", () => {
  const f = cubicBezier(0, 0, 1, 1);
  const lin = EASINGS.linear!;
  for (let i = 0; i <= 100; i++) {
    const t = i / 100;
    assert.ok(Math.abs(f(t) - lin(t)) < 1e-6, `t=${String(t)}：${String(f(t))} vs ${String(lin(t))}`);
  }
});

test("★ x1===y1 且 x2===y2 的曲线都是恒等（不是只特判了 0,0,1,1）", () => {
  const f = cubicBezier(0.3, 0.3, 0.7, 0.7);
  for (let i = 0; i <= 100; i++) {
    const t = i / 100;
    assert.ok(Math.abs(f(t) - t) < 1e-6, `t=${String(t)}：${String(f(t))}`);
  }
});

test("★★ 反解正确性：对每条曲线、每个 t，f(x(t)) === y(t)（x/y 由 de Casteljau 独立算出）", () => {
  CURVES.forEach(([x1, y1, x2, y2], ci) => {
    const f = cubicBezier(x1, y1, x2, y2);
    for (let i = 1; i < 20; i++) {
      const t = i / 20;
      const x = deCasteljau(0, x1, x2, 1, t);
      const y = deCasteljau(0, y1, y2, 1, t);
      assert.ok(
        Math.abs(f(x) - y) < 1e-6,
        `曲线#${String(ci)} t=${String(t)}：f(${String(x)})=${String(f(x))} 应为 ${String(y)}`,
      );
    }
  });
});

test("★★ 手算锚点 1：cubic-bezier(0.25,0.1,0.25,1) 在 0.3125 处给 0.5375", () => {
  // t=0.5 时 x=3·0.25·0.5·0.25 + 3·0.5·0.25·0.25 + 0.125 = 0.3125
  //         y=3·0.25·0.5·0.1  + 3·0.5·0.25·1    + 0.125 = 0.5375
  const f = cubicBezier(0.25, 0.1, 0.25, 1);
  assert.ok(Math.abs(f(0.3125) - 0.5375) < 1e-6, `得到 ${String(f(0.3125))}`);
});

test("★★ 手算锚点 2：cubic-bezier(0.42,0,1,1) 在 0.6575 处给 0.5", () => {
  // t=0.5 时 x=3·0.25·0.5·0.42 + 3·0.5·0.25·1 + 0.125 = 0.6575，y=0.5
  const f = cubicBezier(0.42, 0, 1, 1);
  assert.ok(Math.abs(f(0.6575) - 0.5) < 1e-6, `得到 ${String(f(0.6575))}`);
});

test("★ y 落在 [0,1] 的曲线单调不减（x1/x2 在范围内 ⇒ x(t) 单调 ⇒ f 单调）", () => {
  const f = cubicBezier(0.25, 0.1, 0.25, 1);
  let prev = -Infinity;
  for (let i = 0; i <= 200; i++) {
    const v = f(i / 200);
    assert.ok(v >= prev - 1e-12, `i=${String(i)}：${String(v)} < ${String(prev)}`);
    prev = v;
  }
});

test("★ y 越界的曲线必须真的冲出 1（回弹不许被夹住）", () => {
  const f = cubicBezier(0.34, 1.56, 0.64, 1);
  let max = -Infinity;
  for (let i = 0; i <= 200; i++) max = Math.max(max, f(i / 200));
  assert.ok(max > 1.02, `峰值只有 ${String(max)}，回弹被夹掉了`);
});

test("★ 不是恒等：ease-in 在 0.5 处明显小于 0.5", () => {
  const f = cubicBezier(0.42, 0, 1, 1);
  assert.ok(f(0.5) < 0.4, `得到 ${String(f(0.5))}`);
});

// ---------------------------------------------------------------- 构造期校验

test("★ x 越出 [0,1] 在构造期就被拒绝（否则反解不唯一）", () => {
  assert.throws(() => cubicBezier(-0.1, 0, 0.5, 1), RangeError);
  assert.throws(() => cubicBezier(0.5, 0, 1.1, 1), RangeError);
});

test("★ 非有限控制点在构造期就被拒绝（NaN 会一路扩散成控件消失）", () => {
  assert.throws(() => cubicBezier(Number.NaN, 0, 0.5, 1), RangeError);
  assert.throws(() => cubicBezier(0.5, Infinity, 0.5, 1), RangeError);
});

// ---------------------------------------------------------------- 字符串入口

test("解析成功：允许空白，求值结果与直接构造逐点相同", () => {
  const r = parseCubicBezier("cubic-bezier(0.25, 0.1, 0.25, 1)");
  assert.ok(r.ok, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  const direct = cubicBezier(0.25, 0.1, 0.25, 1);
  for (let i = 0; i <= 20; i++) {
    const t = i / 20;
    assert.ok(Math.abs(r.value(t) - direct(t)) < 1e-12);
  }
});

test("★ 语法错给 BAD_SYNTAX（三个参数 / 非数字 / 不是这个名字）", () => {
  for (const bad of ["cubic-bezier(1,2,3)", "cubic-bezier(a,b,c,d)", "ease", "cubic-bezier()"]) {
    const r = parseCubicBezier(bad);
    assert.equal(r.ok, false, `${bad} 不该解析成功`);
    if (!r.ok) assert.equal(r.error.code, BEZIER_ERR.BAD_SYNTAX, bad);
  }
});

test("★ 参数越界给 BAD_CONTROL（抄对了但用不了，与「抄错了」分开）", () => {
  const r = parseCubicBezier("cubic-bezier(-1,0,0.5,1)");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, BEZIER_ERR.BAD_CONTROL);
});

test("★ 看起来像那么回事就交出去：looksLikeCubicBezier 只管前缀", () => {
  assert.equal(looksLikeCubicBezier("cubic-bezier(0.1,0.2,0.3,0.4)"), true);
  assert.equal(looksLikeCubicBezier("  cubic-bezier ("), true);
  assert.equal(looksLikeCubicBezier("quadInOut"), false);
  assert.equal(looksLikeCubicBezier("my-cubic-bezier(0,0,1,1)"), false);
});

test("★ getEasing 走同一个入口：自定义曲线可取、坏形状报语法错", () => {
  const good = getEasing("cubic-bezier(0.42,0,1,1)");
  assert.ok(good.ok);
  assert.ok(Math.abs(good.value(0.6575) - 0.5) < 1e-6);

  const badShape = getEasing("cubic-bezier(1,2)");
  assert.equal(badShape.ok, false);
  if (!badShape.ok) assert.equal(badShape.error.code, BEZIER_ERR.BAD_SYNTAX);

  // 拼错的命名曲线仍然是 UNKNOWN，不许被当成贝塞尔去解析。
  const unknown = getEasing("elastc");
  assert.equal(unknown.ok, false);
  if (!unknown.ok) assert.equal(unknown.error.code, EASING_ERR.UNKNOWN);
});

test("内置表不受影响：31 条名字还在、表仍冻结", () => {
  assert.equal(Object.isFrozen(EASINGS), true);
  for (const name of ["linear", "quadInOut", "bounceOut", "step"]) {
    assert.equal(getEasing(name).ok, true, name);
  }
});

// ---------------------------------------------------------------- 接线（最重要）

test("★★★ 自定义曲线真的进了采样：t=31.25ms 时 0→100 给 53.75", () => {
  const made = makeTween({
    id: "t",
    from: 0,
    to: 100,
    durationMs: 100,
    easing: "cubic-bezier(0.25,0.1,0.25,1)",
  });
  assert.ok(made.ok, made.ok ? "" : `${made.error.code} ${made.error.message}`);
  // progress = 0.3125 ⇒ f = 0.5375 ⇒ value = 53.75
  // ★ 容差而非精确相等：反解精度 1e-9，乘 100 之后是 1e-7 量级 —— 这里验的是
  //   「这条链走的是贝塞尔」，不是求解器的最后一位。
  assert.ok(
    Math.abs(sampleTween(made.value, 31.25).value - 53.75) < 1e-5,
    `得到 ${String(sampleTween(made.value, 31.25).value)}`,
  );
  assert.equal(sampleTween(made.value, 0).value, 0);
  assert.equal(sampleTween(made.value, 100).value, 100);
});

test("★ 坏曲线在构造期报错，错误码仍归到 UNKNOWN_EASING（不新增第二个出口）", () => {
  const made = makeTween({ id: "t", from: 0, to: 1, durationMs: 10, easing: "cubic-bezier(1,2)" });
  assert.equal(made.ok, false);
  if (!made.ok) {
    assert.equal(made.error.code, TWEEN_ERR.UNKNOWN_EASING);
    assert.ok(made.error.message.includes("cubic-bezier"), made.error.message);
  }
});

test("★ spec 里带了冻结的曲线引用（ease），且与 easing 名字一致", () => {
  const made = makeTween({ id: "t", from: 0, to: 1, durationMs: 10, easing: "quadInOut" });
  assert.ok(made.ok);
  assert.equal(typeof made.value.ease, "function");
  assert.equal(made.value.ease, EASINGS.quadInOut);
  assert.equal(made.value.easing, "quadInOut");
});
