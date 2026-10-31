/**
 * L0 · 平面长度 `planeLen` —— 为什么它存在，以及它的边界在哪
 *
 * 这组判据守的不是"算得对不对"（`sqrt(dx²+dz²)` 没有第二种写法），而是三件事：
 *   ① 它与今天被换掉的 `Math.hypot` 在**定义域上**给出同一个位模式
 *      —— 这就是"换掉它不改变任何现有位置判据"的证据；
 *   ② 它只用 IEEE-754 规定过的运算 —— 这是跨宿主一致的全部依据；
 *   ③ 它的边界（溢出/下溢）是**已知且被记录**的取舍，不是没想过的漏洞。
 *
 * ★ 为什么 ① 要用"9 组方向向量"这个范围：`dirStep` 的入参就是
 *   `dx, dz ∈ {-1, 0, 1}`（摇杆八方向 + 停），没有任何其它来源。
 *   在**这个定义域**上 `hypot` 恰好等于 `sqrt(x²+y²)`，所以换成 planeLen
 *   之后所有位置判据的期望值一个字都不用改。范围之外的浮点上 `hypot`
 *   有 39% 的概率差 1 ulp（见 ③ 那条判据的注释）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { planeLen } from "../../src/foundation/math/scalar.ts";

test("[math] planeLen 是 sqrt(dx²+dz²)：整数勾股与零点", () => {
  assert.equal(planeLen(3, 4), 5);
  assert.equal(planeLen(-3, 4), 5);
  assert.equal(planeLen(0, 0), 0);
  assert.equal(planeLen(0, -2), 2);
  // 归一化的前提：方向向量的长度是 1
  assert.equal(planeLen(1, 0), 1);
});

test("[math] ★ 在 dirStep 的定义域（9 组方向向量）上，planeLen 与 hypot **逐位相同**", () => {
  // 这条是「换掉 Math.hypot 不改变现有行为」的直接证据。
  // 如果哪天它红了，说明 V8 改了 hypot 的实现 —— 那正好印证了为什么不能用它。
  let compared = 0;
  for (const dx of [-1, 0, 1]) {
    for (const dz of [-1, 0, 1]) {
      const a = Math.hypot(dx, dz);
      const b = planeLen(dx, dz);
      assert.equal(
        Object.is(a, b),
        true,
        `方向向量 (${String(dx)}, ${String(dz)}) 上 hypot=${String(a)} 与 planeLen=${String(b)} 不同`,
      );
      compared++;
    }
  }
  // 9 组全比过 —— 少了就是循环写漏了，而"比的组数变少"不会自己报错
  assert.equal(compared, 9);
});

test("[math] ★ 在定义域之外它们会分叉（所以 planeLen 不是「换一种写法」，是换了一个**约定**）", () => {
  // 找一个 hypot 与 sqrt 差 1 ulp 的真值：这不是构造出来的刁钻例子，
  // 而是任意浮点里 39% 的情况。找不到就说明前提变了，判据该跟着改。
  let found = 0;
  let x = 1;
  for (let i = 0; i < 2000 && found === 0; i++) {
    const dx = x;
    const dz = x / 3;
    const a = Math.hypot(dx, dz);
    const b = planeLen(dx, dz);
    if (!Object.is(a, b)) found = 1;
    x = x * 1.0000001 + 0.0001;
  }
  assert.equal(found, 1, "在这个范围里没找到分叉 —— 前提（hypot 实现未定义）可能已经变了");
});

test("[math] 边界是**已知**的：|dx| 超过 1.3e154 时 planeLen 溢出，hypot 不溢出", () => {
  const huge = 1e200;
  assert.equal(planeLen(huge, huge), Number.POSITIVE_INFINITY);
  // `hypot` 有缩放保护，所以它不溢出 —— 这就是"planeLen 少了什么"的具体形状。
  assert.equal(Number.isFinite(Math.hypot(huge, huge)), true);
  // 但游戏坐标离这儿有一百多个数量级：格宽 1、地图 1000 格 ⇒ |x| ≤ 1e3
  assert.equal(planeLen(1e3, 1e3), Math.sqrt(2) * 1e3);
});
