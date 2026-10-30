/**
 * L6 · 画布后备存储尺寸的判据
 *
 * 守的是一件**三个地方各写过一遍**的公式：CSS 尺寸 × 像素比（上限 2）。
 *
 * 为什么值得单守：
 *   ① `Math.min(2, dpr)` 的上限**只在 dpr ≥ 3 时才可观察**，而开发机与 CI 都是 1 或 2 ——
 *     把上限删掉，所有既有判据照绿，只有 4K 屏用户的填充率翻 2.25 倍。
 *   ② `floor` 与 `round` 只在 CSS 尺寸带小数时不同（958.6 → 958 vs 959），
 *     而 `clientWidth` 在小数缩放 / 分数像素布局下**就是小数**。
 *   ③ 兜底（dpr=0、CSS=0）走的是异常路径，正常启动永远碰不到 —— 但碰上时
 *     `canvas.width = 0` 会让 WebGL 上下文直接失效（不是"画小一点"，是"没有渲染器"）。
 *
 * ★ 接线（入口真的用了这个函数）不在 Node 里验 —— 那是浏览器那条 dpr 检查的事
 *   （`tools/browser-selftest.mjs` 的「物理尺寸 = CSS × 上限 2」一段）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { MAX_DPR, backingStoreSize } from "../../src/host/backing-store.ts";

test("dpr=1 时物理尺寸等于 CSS 尺寸（桌面默认，一切旧基线的参照点）", () => {
  const s = backingStoreSize(958, 598, 1);
  assert.equal(s.width, 958);
  assert.equal(s.height, 598);
  assert.equal(s.dpr, 1);
});

test("dpr=2 时物理尺寸翻倍（retina / 真机最常见的档位）", () => {
  const s = backingStoreSize(958, 598, 2);
  assert.equal(s.width, 1916);
  assert.equal(s.height, 1196);
  assert.equal(s.dpr, 2);
});

test("★ dpr=3 被钳到 2：尺寸只翻一倍，且返回的 dpr 也是钳后的值", () => {
  // ★ 两个观测量一起断言：尺寸对了、返回的 dpr 没钳，调用方会拿 3 去设视口
  //   （位图 1916 宽、视口按 3 倍算 ⇒ 画面被压扁 1.5 倍，而尺寸判据全绿）。
  const s = backingStoreSize(960, 600, 3);
  assert.equal(s.width, 1920, "上限 2 ⇒ 1920，不是 2880");
  assert.equal(s.height, 1200);
  assert.equal(s.dpr, MAX_DPR, "返回的 dpr 必须是钳后的 2");
  assert.equal(s.width, 960 * s.dpr, "宽度必须与返回的 dpr 自洽");
});

test("dpr 为 0 / NaN / 负数时当 1（否则 canvas.width 会变成 0，WebGL 直接没了）", () => {
  for (const bad of [0, Number.NaN, -2, Number.NEGATIVE_INFINITY]) {
    const s = backingStoreSize(800, 600, bad);
    assert.equal(s.dpr, 1, `dpr=${String(bad)} 应退回 1`);
    assert.equal(s.width, 800);
  }
});

test("CSS 尺寸为 0 / NaN 时给 1 像素，而不是 0（\"还没布局\"是正常状态）", () => {
  for (const bad of [0, Number.NaN, -10]) {
    const s = backingStoreSize(bad, bad, 2);
    assert.equal(s.width, 1, `css=${String(bad)}`);
    assert.equal(s.height, 1);
  }
});

test("★ 取整是 floor 不是 round：958.6 → 958（多 1 像素会让视口比布局大，采样偏半像素）", () => {
  // ★ 958.6 而不是 958.5：×1 之后 .5 恰好落在中点，floor 与 round 会有分歧但
  //   容易被"四舍五入的实现恰好也是 floor"蒙对；用 .6 让分歧稳定可读。
  const s = backingStoreSize(958.6, 598.6, 1);
  assert.equal(s.width, 958, "floor(958.6)=958");
  assert.equal(s.height, 598);
});

test("maxDpr 可覆盖：传 1.5 时按 1.5 算（编辑器那种\"够用就行\"的档位）", () => {
  const s = backingStoreSize(1000, 800, 2, 1.5);
  assert.equal(s.dpr, 1.5);
  assert.equal(s.width, 1500);
  assert.equal(s.height, 1200);
});

test("maxDpr 传非法值时退回 MAX_DPR（调用方写错不该让整块画布缩成 1 像素）", () => {
  for (const bad of [0, Number.NaN, -1]) {
    const s = backingStoreSize(900, 700, 2, bad);
    assert.equal(s.dpr, MAX_DPR, `maxDpr=${String(bad)}`);
    assert.equal(s.width, 1800);
  }
});
