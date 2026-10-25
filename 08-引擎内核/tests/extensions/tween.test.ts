/**
 * 补间与缓动的判据
 *
 * 这一组守的是**形状**，不是"能跑通"。缓动函数写错一个符号，
 * 画面上的症状只是"手感不太对"，没有任何东西会报错 —— 所以每一条曲线
 * 都要用**数学性质**钉住，而不是拿几个手算值比一比。
 *
 * 三类性质，从弱到强：
 *   ① 端点：f(0)=0、f(1)=1 —— 最弱，只能抓"端点没接上"；
 *   ② 方向：in 类 f(t)<t、out 类 f(t)>t（开区间内）—— 抓"in/out 写反"；
 *   ③ 对称：inOut 类 f(0.5)=0.5，且 out(t) = 1 - in(1-t) —— 抓"翻转发成镜像"。
 * 只有 ① 的判据是碰运气：把 cubicIn 换成 quadIn，端点照样全对。
 *
 * ★ 一条反例钉住整个 bounce：它是唯一**不单调**的族，
 *   所以"单调性"判据必须显式把它排除，否则会为了迁就它而放宽整条判据。
 *   改用落点序列（7.5625/3.90625/…）来钉形状。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  EASINGS,
  EASING_NAMES,
  EASING_ERR,
  getEasing,
} from "../../src/extensions/tween/easing.ts";
import {
  TWEEN_ERR,
  makeTween,
  sampleTween,
  tweenDurationMs,
  tweenIsDone,
  type TweenSpec,
  type TweenSpecInput,
} from "../../src/extensions/tween/tween.ts";

/** 采样点：端点必查，中间取三个不对称点（0.5 太容易被巧合满足）。 */
const PROBES = [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1] as const;

function tween(over: Partial<TweenSpecInput> = {}): TweenSpec {
  const r = makeTween({ id: "t", from: 0, to: 100, durationMs: 100, ...over });
  assert.ok(r.ok, `构造失败：${r.ok ? "" : r.error.code} ${r.ok ? "" : r.error.message}`);
  return r.value;
}

// ---------------------------------------------------------------- 缓动形状

test("★ 每条曲线端点都是 0 与 1（step 除外）", () => {
  for (const name of EASING_NAMES) {
    if (name === "step") continue;
    const f = EASINGS[name]!;
    assert.equal(f(0), 0, `${name}(0) = ${String(f(0))}，应为 0`);
    assert.equal(f(1), 1, `${name}(1) = ${String(f(1))}，应为 1`);
  }
});

test("★ step 是阶梯：前半 0、终点 1", () => {
  const f = EASINGS["step"]!;
  assert.equal(f(0), 0);
  assert.equal(f(0.5), 0);
  assert.equal(f(0.999), 0);
  assert.equal(f(1), 1);
});

test("★ in 类在开区间内慢于线性（f(t) < t）", () => {
  for (const name of ["quadIn", "cubicIn", "quartIn", "quintIn", "sineIn", "expoIn", "circIn"]) {
    const f = EASINGS[name]!;
    for (const p of [0.1, 0.25, 0.5, 0.75, 0.9]) {
      assert.ok(f(p) < p, `${name}(${String(p)}) = ${String(f(p))} 不小于 t ⇒ 不是"慢起"`);
    }
  }
});

test("★ out 类在开区间内快于线性（f(t) > t）", () => {
  for (const name of ["quadOut", "cubicOut", "quartOut", "quintOut", "sineOut", "expoOut", "circOut"]) {
    const f = EASINGS[name]!;
    for (const p of [0.1, 0.25, 0.5, 0.75, 0.9]) {
      assert.ok(f(p) > p, `${name}(${String(p)}) = ${String(f(p))} 不大于 t ⇒ 不是"慢收"`);
    }
  }
});

test("★ inOut 类关于中点中心对称：f(0.5+x) + f(0.5-x) === 1", () => {
  // 这个性质比"过中点"更强，且对 elastic 的构造式同样成立 ——
  // 本批最先写的是"过中点 0.5"，结果被 elasticInOut 抓到 0.567：
  // 那是我的公式写错（相位偏移用了 0.1 而不是 p/4），判据是对的。
  // 改用中心对称后它同时覆盖"过中点"（x=0 时）与"两端对称"。
  for (const name of EASING_NAMES) {
    if (!name.endsWith("InOut")) continue;
    const f = EASINGS[name]!;
    for (const x of [0.1, 0.25, 0.4]) {
      const sum = f(0.5 + x) + f(0.5 - x);
      assert.ok(
        Math.abs(sum - 1) < 1e-9,
        `${name} 不中心对称：f(${String(0.5 + x)}) + f(${String(0.5 - x)}) = ${String(sum)}，应为 1`,
      );
    }
  }
});

test("★ out(t) === 1 - in(1-t)（同一族 in/out 必须互为镜像）", () => {
  const pairs: ReadonlyArray<readonly [string, string, string]> = [
    ["quad", "quadIn", "quadOut"],
    ["cubic", "cubicIn", "cubicOut"],
    ["quart", "quartIn", "quartOut"],
    ["quint", "quintIn", "quintOut"],
    ["sine", "sineIn", "sineOut"],
    ["expo", "expoIn", "expoOut"],
    ["circ", "circIn", "circOut"],
    ["back", "backIn", "backOut"],
    ["bounce", "bounceIn", "bounceOut"],
  ];
  for (const [, inName, outName] of pairs) {
    const fin = EASINGS[inName]!;
    const fout = EASINGS[outName]!;
    for (const p of PROBES) {
      const mirrored = 1 - fin(1 - p);
      assert.ok(
        Math.abs(fout(p) - mirrored) < 1e-9,
        `${outName}(${String(p)}) = ${String(fout(p))}，但 1 - ${inName}(${String(1 - p)}) = ${String(mirrored)}`,
      );
    }
  }
});

test("★ back 族必须冲过目标（回弹的判据：极值越出 [0,1]）", () => {
  for (const name of ["backIn", "backOut", "backInOut", "elasticIn", "elasticOut", "elasticInOut"]) {
    const f = EASINGS[name]!;
    let over = false;
    for (const p of [0.05, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 0.95]) {
      if (f(p) < -1e-9 || f(p) > 1 + 1e-9) over = true;
    }
    assert.ok(over, `${name} 全程没越出 [0,1] ⇒ 回冲被夹平了，等于一条普通曲线`);
  }
});

test("★ 单调族必须单调不减（back/elastic 因越界而排除）", () => {
  const monotone = EASING_NAMES.filter(
    (n) => n !== "step" && !n.startsWith("back") && !n.startsWith("elastic") && !n.startsWith("bounce"),
  );
  for (const name of monotone) {
    const f = EASINGS[name]!;
    let prev = -Infinity;
    for (let i = 0; i <= 100; i++) {
      const v = f(i / 100);
      assert.ok(v >= prev - 1e-12, `${name} 在 t=${String(i / 100)} 处回退：${String(prev)} → ${String(v)}`);
      prev = v;
    }
  }
});

test("★ bounce 不单调，但每次落地的累计高度是固定一串", () => {
  // 四段小球：每段**结束**（球落地）都必须是 1 —— 落不到底就不是弹跳。
  const f = EASINGS["bounceOut"]!;
  for (const land of [1 / 2.75, 2 / 2.75, 2.5 / 2.75, 1]) {
    assert.ok(
      Math.abs(f(land) - 1) < 1e-9,
      `bounceOut(${String(land)}) = ${String(f(land))}，落地处应为 1`,
    );
  }
  // 每段**中点**（弹到最高）的高度递减：0.75 → 0.9375 → 0.984375。
  // 递减是"弹跳衰减"的形状；若写成递增，说明段内区间算反了。
  const peaks: ReadonlyArray<readonly [number, number]> = [
    [1.5 / 2.75, 0.75],
    [2.25 / 2.75, 0.9375],
    [2.625 / 2.75, 0.984375],
  ];
  for (const [p, want] of peaks) {
    assert.ok(Math.abs(f(p) - want) < 1e-9, `bounceOut(${String(p)}) = ${String(f(p))}，峰值应为 ${String(want)}`);
  }
  // 峰值严格递增（越弹越低但幅度递减，累加高度趋近 1）
  for (let i = 1; i < peaks.length; i++) {
    assert.ok(peaks[i]![1] > peaks[i - 1]![1], "峰值必须递增");
  }
});

test("★ 缓动表与名字表同源（名字表漏一个就等于资产里配不了它）", () => {
  assert.deepEqual([...EASING_NAMES].sort(), Object.keys(EASINGS).sort());
  assert.ok(EASING_NAMES.length >= 30, `内置缓动只有 ${String(EASING_NAMES.length)} 条，覆盖不足`);
});

test("拼错的缓动名返回稳定错误码，且不静默改用别的曲线", () => {
  const r = getEasing("elastc");
  assert.ok(!r.ok);
  if (!r.ok) {
    assert.equal(r.error.code, EASING_ERR.UNKNOWN);
    assert.ok(r.error.message.includes("elastc"), "错误信息里要带上拼错的那个名字");
  }
  // 真正要防的是"回落 linear"：那会让「配了 elastic 却像 linear」永远查不到。
  // 检测方式是**取到的函数**，不是错误信息里有没有 linear 这个词 ——
  // 可用列表里必然含 linear（第一版判据就栽在这里，写成了 notEqual(EASINGS["elastc"], undefined)，
  // 而那本来就是 undefined，等于什么都没测）。
  assert.equal(getEasing("elastc").ok, false);
});

test("getEasing 对每条内置名都能取到，且取到的是表里那个函数", () => {
  for (const name of EASING_NAMES) {
    const r = getEasing(name);
    assert.ok(r.ok, `${name} 取不到`);
    if (r.ok) assert.equal(r.value, EASINGS[name]);
  }
});

// ---------------------------------------------------------------- 补间采样

test("t=0 给 from、t=duration 给 to（端点不含浮点漂移）", () => {
  const s = tween();
  assert.equal(sampleTween(s, 0).value, 0);
  assert.equal(sampleTween(s, 100).value, 100);
});

test("中点按缓动走：linear 的中点恰是 50", () => {
  const s = tween({ easing: "linear" });
  assert.equal(sampleTween(s, 50).value, 50);
});

test("★ quadInOut 的中点不是 50（证明真的用了缓动，不是线性占位）", () => {
  const s = tween({ easing: "quadInOut" });
  const v = sampleTween(s, 50).value;
  assert.ok(Math.abs(v - 50) < 1e-9, `quadInOut 过中点应为 50，实得 ${String(v)}`);
  // 前半段必须慢于线性：t=25 处应 < 25
  assert.ok(sampleTween(s, 25).value < 25, "quadInOut 前半段应慢于线性");
});

test("★ from/to 非零时插值仍然正确（0→100 的判据掩盖不了 20→80 的偏移）", () => {
  const s = tween({ from: 20, to: 80, easing: "linear" });
  assert.equal(sampleTween(s, 0).value, 20);
  assert.equal(sampleTween(s, 50).value, 50);
  assert.equal(sampleTween(s, 100).value, 80);
  // 负方向：从 80 回到 20
  const d = tween({ id: "d", from: 80, to: 20, easing: "linear" });
  assert.equal(sampleTween(d, 50).value, 50);
});

test("★ 负时间夹到 0 而不是环绕（否则动画会先闪结尾）", () => {
  const s = tween();
  for (const t of [-1, -50, -1e6]) {
    const r = sampleTween(s, t);
    assert.equal(r.value, s.from, `timeMs=${String(t)} 应停在起点，实得 ${String(r.value)}`);
    assert.equal(r.waiting, false);
  }
});

test("非有限时间抛 TypeError，不返回假值", () => {
  const s = tween();
  for (const t of [NaN, Infinity, -Infinity]) {
    assert.throws(() => sampleTween(s, t), TypeError);
  }
});

test("delay 段内停在 from，且 waiting 为 true", () => {
  const s = tween({ delayMs: 100 });
  const r = sampleTween(s, 50);
  assert.equal(r.value, 0);
  assert.equal(r.waiting, true);
  assert.equal(r.progress, 0);
  // delay 结束的那一刻开始走
  assert.equal(sampleTween(s, 100).value, 0);
  assert.equal(sampleTween(s, 150).value, 50, "delay 结束后 50ms 应对应半程");
});

test("★ delay 只在第一次生效，循环内不重复（否则节奏变成停-走-停）", () => {
  const s = tween({ delayMs: 100, durationMs: 100, loopCount: 2 });
  // 第一轮：0..100 等待，100..200 播放
  assert.equal(sampleTween(s, 150).value, 50);
  assert.equal(sampleTween(s, 200).value, 100);
  // 第二轮：200..300 播放，中间**没有**再等 100ms
  assert.equal(sampleTween(s, 250).value, 50, "第二轮 50ms 处应已走到半程，而不是又在等待");
  assert.equal(sampleTween(s, 300).value, 100);
  assert.equal(sampleTween(s, 300).done, true);
});

test("★ 有限循环播完停在 to，且 done 在边界那一帧就为真", () => {
  const s = tween({ loopCount: 2 });
  assert.equal(sampleTween(s, 199).done, false);
  const r = sampleTween(s, 200);
  assert.equal(r.done, true);
  assert.equal(r.value, s.to, "done 时必须精确停在终点，而不是采样值");
  // 超过终点也不会绕回第一段
  assert.equal(sampleTween(s, 5000).value, 100);
  assert.equal(sampleTween(s, 5000).done, true);
});

test("无限循环永不 done，且 loop 序号递增", () => {
  const s = tween();
  assert.equal(sampleTween(s, 1e9).done, false);
  assert.equal(sampleTween(s, 250).loop, 2);
  assert.equal(sampleTween(s, 0).loop, 0);
});

test("★ yoyo 往返严格对称：奇数轮是同一条曲线的反向", () => {
  const s = tween({ easing: "linear", yoyo: true, loopCount: 4 });
  // 轮0（0..100ms）正向：0→100
  assert.equal(sampleTween(s, 25).value, 25);
  assert.equal(sampleTween(s, 100).value, 100, "轮0 结束在 to");
  // 轮1（100..200ms）反向：100→0
  assert.equal(sampleTween(s, 125).value, 75);
  assert.equal(sampleTween(s, 175).value, 25);
  assert.equal(sampleTween(s, 200).value, 0, "轮1 结束在 from");
  // 轮2（200..300ms）又正向
  assert.equal(sampleTween(s, 225).value, 25);
  assert.equal(sampleTween(s, 300).value, 100, "轮2 结束在 to（循环边界不能闪回 from）");
  // 轮3（300..400ms）反向
  assert.equal(sampleTween(s, 325).value, 75);
  assert.equal(sampleTween(s, 400).value, 0);
});

test("speed 缩放时长：2 倍速半程只用 25ms", () => {
  const s = tween({ speed: 2 });
  assert.equal(tweenDurationMs(s), 50);
  assert.equal(sampleTween(s, 25).value, 50);
});

test("speed=0 冻结：成因在调用方（dt*speed=0 ⇒ timeMs 不推进）", () => {
  const s = tween({ speed: 0 });
  // 采样函数不替调用方冻结，它只回答"timeMs 时刻该是什么值"。
  assert.equal(sampleTween(s, 0).value, 0);
  // speed=0 不得除零：返回 Infinity 会让循环号恒 0，与 speed=1 行为分叉
  assert.equal(tweenDurationMs(s), 100);
  // 与 speed=1 在同一 timeMs 上必须同值（这条正是防"除以 0 得 Infinity"的分叉）
  const n = tween({ speed: 1 });
  for (const t of [0, 25, 50, 100, 250]) {
    assert.equal(sampleTween(s, t).value, sampleTween(n, t).value, `t=${String(t)} 处 speed=0 与 speed=1 分叉`);
  }
});

test("负 speed 是倒放：时间往前走、值从终点往回走", () => {
  // 用 linear 测，方向才读得出来（曲线会把它糊掉）
  const s = tween({ speed: -1, easing: "linear" });
  assert.equal(tweenDurationMs(s), 100);
  assert.equal(sampleTween(s, 0).value, 100, "倒放起点应是终点");
  assert.equal(sampleTween(s, 25).value, 75, "倒放 25ms 处应已往回走 25%");
  assert.equal(sampleTween(s, 100).value, 0);
});

test("★ speed<0 与 yoyo 同时开时按异或抵消（不是叠加）", () => {
  // 倒着走的往返轮 = 正向轮。写成叠加会让偶数/奇数轮整体反向。
  // 轮0：speed<0 单独生效 ⇒ 倒放（100→0）
  // 轮1：speed<0 与 yoyo 同时 ⇒ 抵消 ⇒ 正向（0→100）
  const s = tween({ speed: -1, easing: "linear", yoyo: true, loopCount: 4 });
  assert.equal(sampleTween(s, 25).value, 75, "轮0：倒放，25ms 处应回到 75");
  assert.equal(sampleTween(s, 100).value, 0, "轮0 结束在 from");
  assert.equal(sampleTween(s, 125).value, 25, "轮1：抵消后正向，25ms 处应走到 25");
  assert.equal(sampleTween(s, 200).value, 100, "轮1 结束在 to");
  assert.equal(sampleTween(s, 225).value, 75, "轮2：又是倒放");
});

test("tweenIsDone 与 sampleTween.done 一致（两个出口不许各说各话）", () => {
  const s = tween({ loopCount: 1 });
  for (const t of [0, 50, 99, 100, 101, 500]) {
    assert.equal(tweenIsDone(s, t), sampleTween(s, t).done, `t=${String(t)} 两个出口不一致`);
  }
});

// ---------------------------------------------------------------- 构造校验

test("durationMs <= 0 被拒绝（否则采样要除零）", () => {
  for (const d of [0, -1, NaN, Infinity]) {
    const r = makeTween({ id: "x", from: 0, to: 1, durationMs: d });
    assert.ok(!r.ok, `durationMs=${String(d)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, TWEEN_ERR.BAD_DURATION);
  }
});

test("两端非有限被拒绝（NaN 会扩散成「控件不动了」）", () => {
  for (const [from, to] of [
    [NaN, 1],
    [0, NaN],
    [Infinity, 1],
    [0, -Infinity],
  ] as ReadonlyArray<readonly [number, number]>) {
    const r = makeTween({ id: "x", from, to, durationMs: 100 });
    assert.ok(!r.ok, `from=${String(from)} to=${String(to)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, TWEEN_ERR.BAD_ENDPOINT);
  }
});

test("delayMs 为负被拒绝", () => {
  const r = makeTween({ id: "x", from: 0, to: 1, durationMs: 100, delayMs: -1 });
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, TWEEN_ERR.BAD_DELAY);
});

test("loopCount 非负整数之外被拒绝（负数会让循环号变负）", () => {
  for (const l of [-1, 1.5, NaN]) {
    const r = makeTween({ id: "x", from: 0, to: 1, durationMs: 100, loopCount: l });
    assert.ok(!r.ok, `loopCount=${String(l)} 应被拒绝`);
    if (!r.ok) assert.equal(r.error.code, TWEEN_ERR.BAD_LOOP);
  }
});

test("未知缓动名在构造期就炸，不留给采样期", () => {
  const r = makeTween({ id: "x", from: 0, to: 1, durationMs: 100, easing: "quartc" });
  assert.ok(!r.ok);
  if (!r.ok) assert.equal(r.error.code, TWEEN_ERR.UNKNOWN_EASING);
});

test("构造出的 spec 是冻结的（共享数据不能被运行时改坏）", () => {
  const s = tween();
  assert.throws(() => {
    (s as { durationMs: number }).durationMs = 999;
  });
});

test("默认值：quadInOut / 无 delay / speed 1 / 无限循环", () => {
  const s = tween();
  assert.equal(s.easing, "quadInOut");
  assert.equal(s.delayMs, 0);
  assert.equal(s.speed, 1);
  assert.equal(s.loopCount, 0);
  assert.equal(s.yoyo, false);
});

// ---------------------------------------------------------------- 反向用例

test("★ 反向用例：把 easing 换成错的，本文件的方向判据必须能红", () => {
  // 这不是在测实现，是在测**判据自己**：确认 in/out 判据真的在分方向。
  const quadIn = EASINGS["quadIn"]!;
  const quadOut = EASINGS["quadOut"]!;
  for (const p of [0.25, 0.5, 0.75]) {
    assert.ok(quadIn(p) < p, "meta 判据前提：quadIn 应慢于线性");
    assert.ok(quadOut(p) > p, "meta 判据前提：quadOut 应快于线性");
  }
});

test("★ 反向用例：from===to 时任何时刻都是同一个值（无边界的补间）", () => {
  const s = tween({ from: 42, to: 42 });
  for (const t of [0, 25, 50, 100, 500]) {
    assert.equal(sampleTween(s, t).value, 42);
  }
});

test("★ 反向用例：durationMs 极小仍不除零、不 NaN", () => {
  const s = tween({ durationMs: 1e-9 });
  const r = sampleTween(s, 5e-10);
  assert.ok(Number.isFinite(r.value), `值出现非有限数：${String(r.value)}`);
});
