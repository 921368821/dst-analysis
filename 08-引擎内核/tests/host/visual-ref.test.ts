/**
 * 插值器晚绑定的判据（批169）
 *
 * ★ 这套判据的第一条就是"未绑定时什么也不发生" —— 因为单机与主机侧**永远**不绑，
 *   而那时渲染看到的是一个非 null 的对象（不是 `visual: null`）。转发壳一旦漏写
 *   空判断，最坏的情况不是崩溃而是"调用了一个不存在的东西"，然后整帧不画。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { createVisualRef } from "../../src/host/visual-ref.ts";
import type { VisualSmoothing } from "../../src/extensions/render/render-module.ts";

interface Fake {
  readonly visual: VisualSmoothing;
  readonly begins: number[];
  readonly ats: number[];
}

/** 一个记账用的假插值器。`at` 返回的数字与 id 有关，好分辨"转发给了谁"。 */
function fake(offset = 0): Fake {
  const begins: number[] = [];
  const ats: number[] = [];
  return {
    begins,
    ats,
    visual: {
      beginFrame: (dtMs: number): void => {
        begins.push(dtMs);
      },
      at: (nodeId: number) => {
        ats.push(nodeId);
        return { x: nodeId + offset, y: nodeId + offset + 0.5 };
      },
    },
  };
}

test("★★ 未绑定时 `at` 恒 null、`beginFrame` 不炸（单机与主机侧永远不绑）", () => {
  const ref = createVisualRef();
  assert.equal(ref.bound(), null);
  assert.equal(ref.visual.at(7), null, "没绑定却给了坐标 ⇒ 画在一个谁也没算过的位置");
  ref.visual.beginFrame(16);
  assert.equal(ref.bound(), null);
});

test("★★ 绑定之后两个方法都透传（只透 `at` 的话插值时钟不走，画面上所有人站着不动）", () => {
  const ref = createVisualRef();
  const a = fake();
  ref.bind(a.visual);
  assert.equal(ref.bound(), a.visual);
  assert.deepEqual(ref.visual.at(3), { x: 3, y: 3.5 });
  ref.visual.beginFrame(16.5);
  assert.deepEqual(a.ats, [3]);
  assert.deepEqual(a.begins, [16.5]);
});

test("★ 解绑之后回到「按节点真实坐标画」：两个方法都不再转发", () => {
  const ref = createVisualRef();
  const a = fake();
  ref.bind(a.visual);
  ref.visual.at(1);
  ref.bind(null);
  assert.equal(ref.bound(), null);
  assert.equal(ref.visual.at(2), null);
  ref.visual.beginFrame(8);
  assert.deepEqual(a.ats, [1], "解绑后还在问 `at` ⇒ 位置被一份已经作废的插值继续决定");
  assert.deepEqual(a.begins, [], "解绑后还在推进时钟");
});

test("★ 换绑只认最后一次（同一帧里两个来源都用 = 相机与精灵用两套坐标）", () => {
  const ref = createVisualRef();
  const a = fake(0);
  const b = fake(100);
  ref.bind(a.visual);
  ref.bind(b.visual);
  assert.deepEqual(ref.visual.at(1), { x: 101, y: 101.5 });
  ref.visual.beginFrame(4);
  assert.deepEqual(a.ats, [], "换绑之后旧的还在被调用");
  assert.deepEqual(b.ats, [1]);
});

test("★★ 转发壳的**身份**不随绑定改变（渲染模块拿的是最初那一个，换掉就永远读不到）", () => {
  const ref = createVisualRef();
  const held = ref.visual;
  const a = fake();
  ref.bind(a.visual);
  assert.equal(ref.visual, held, "`bind` 换掉了 `visual` 对象本身 ⇒ 渲染模块手里那个永远是未绑定的壳");
  // 从**最初那个引用**调进去，也要看得见绑定后的效果。
  assert.deepEqual(held.at(5), { x: 5, y: 5.5 });
});
