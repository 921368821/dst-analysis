/**
 * L4 · JPEG · 构造性拒绝：把"审计里触发不了的 fail 分支"逐条收掉
 *
 * ★ 背景：`tools/audit-error-paths.py` 会统计"每条 `fail()` 在整套判据里被真实触发过没有"。
 *   一开始 94 条里有 7 条触发不了，补了几轮之后剩 5 条。这 5 条分成两类，处理方式完全不同：
 *
 *   A. **能构造的**（2 条）：算术渐进扫描的"零游程走过谱段末端"。
 *      它们看着难打，其实只要用测试端的 QM 编码器把 bin 序列摆成
 *      "每个 k 都读 (EOB=0, 零游程=0)"，k 就会一路加到超过 Se。这里把它钉住。
 *
 *   B. **被上游守卫支配、结构上不可达的**（3 条）。不能靠"造个文件"触发，
 *      因为它们前面那条守卫已经先报错了。可验证的做法不是硬造，而是**断言"哪条守卫赢"**——
 *      只要上游守卫还在、报的还是它，下游那行就永远是死防御；一旦有人删掉上游守卫，
 *      这些断言会立刻失败（因为报错文本变了）。
 *
 *       下游（触发不了）                    ← 支配它的上游守卫（本身有判据）
 *       `bits.ts` DHT 查表越界              ← 构造时就校验 `k === values.length`
 *       `hierarchy.ts` 找不到参考分量        ← `checkPairing` 先校验分量数一致
 *       `parse.ts` 没有找到 SOS 扫描         ← `finishFrame` 先校验"每帧至少一个扫描"
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { decodeJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";
import { AC_STAT_BINS } from "../../src/extensions/asset-import/decode/jpeg/qm.ts";
import { encodeArithBins } from "../tools/jpeg-encode.ts";

function sof11or10(marker: number, width: number, height: number, components: readonly number[]): number[] {
  return [
    0xff, marker, 0x00, (8 + components.length * 3) & 0xff, 0x08,
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    components.length,
    ...components.flatMap((id) => [id, 0x11, 0x00]),
  ];
}

function sos(ids: readonly number[], ss: number, se: number, ah: number, al: number): number[] {
  return [
    0xff, 0xda, 0x00, (6 + ids.length * 2) & 0xff, ids.length,
    ...ids.flatMap((id) => [id, 0x00]),
    ss & 0xff, se & 0xff, ((ah & 15) << 4) | (al & 15),
  ];
}

function decodeErr(bytes: Uint8Array): { code: string; message: string } {
  const r = decodeJpeg(bytes, { keep16: true });
  assert.equal(r.ok, false, "这份流本该被拒绝，实际解出来了");
  if (r.ok) throw new Error("unreachable");
  return { code: r.error.code, message: r.error.message };
}

test("拒绝（构造）：算术渐进 AC 首扫的零游程走过 Se", () => {
  // 每个 k 读两 bin：ctx=3(k-1) 判 EOB（0 = 不是 EOB）、ctx=3(k-1)+1 判零游程（0 = 继续）
  const bins: Array<{ ctx: number; val: number }> = [];
  for (let k = 1; k <= 4; k++) {
    bins.push({ ctx: 3 * (k - 1), val: 0 });
    bins.push({ ctx: 3 * (k - 1) + 1, val: 0 });
  }
  const bytes = Uint8Array.from([
    0xff, 0xd8,
    ...sof11or10(0xca, 8, 8, [1]), // SOF10 算术渐进
    ...sos([1], 1, 3, 0, 0), // Ss=1, Se=3
    ...encodeArithBins(bins, AC_STAT_BINS).bytes,
    0xff, 0xd9,
  ]);
  const e = decodeErr(bytes);
  assert.match(e.message, /算术渐进 AC 越过谱段末端（k>Se=3）/, `实际报的是：${e.message}`);
});

test("拒绝（构造）：算术 AC 精修扫描的零游程走过 Se", () => {
  // 扫描 1：AC 首扫立刻 EOB ⇒ 系数全 0；扫描 2：精修（Ah=1,Al=0），kex=0
  // ⇒ 每个 k 都进 for(;;)，(EOB, 零游程) 都为 0 就一路 ++
  const scan1 = encodeArithBins([{ ctx: 0, val: 1 }], AC_STAT_BINS).bytes;
  const bins2: Array<{ ctx: number; val: number }> = [];
  for (let k = 1; k <= 4; k++) {
    bins2.push({ ctx: 3 * (k - 1), val: 0 });
    bins2.push({ ctx: 3 * (k - 1) + 1, val: 0 });
  }
  const bytes = Uint8Array.from([
    0xff, 0xd8,
    ...sof11or10(0xca, 8, 8, [1]),
    ...sos([1], 1, 3, 0, 1),
    ...scan1,
    ...sos([1], 1, 3, 1, 0),
    ...encodeArithBins(bins2, AC_STAT_BINS).bytes,
    0xff, 0xd9,
  ]);
  const e = decodeErr(bytes);
  assert.match(e.message, /算术 AC 精修越过谱段末端（k>Se=3）/, `实际报的是：${e.message}`);
});

test("不可达（有守卫支配）：有 SOF 没 SOS 时，报的是帧级检查而不是扫描级检查", () => {
  // ★ `parse.ts` 末尾那条 `scanCount === 0 → 没有找到 SOS 扫描` 永远轮不到：
  //   `finishFrame()` 在收尾每一帧时已经先报了"第 N 帧没有任何扫描"。
  //   这条断言钉的是"**哪条守卫赢**"，而不是那条死分支本身。
  const bytes = Uint8Array.from([
    0xff, 0xd8,
    0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x02, 0x00, 0x02, 0x01, 0x01, 0x11, 0x00,
    0xff, 0xd9,
  ]);
  const e = decodeErr(bytes);
  assert.match(e.message, /第 1 帧没有任何扫描/, `实际报的是：${e.message}`);
  assert.ok(!e.message.includes("没有找到 SOS 扫描"), "下游那条死分支不该先报（说明上游守卫被删了？）");
});

test("不可达（有守卫支配）：DHT 符号数不足时，报的是解析期检查而不是查表越界", () => {
  // 造一张 counts 说有 1 个长度 1 的码、却给了 0 个符号的表。
  // ★ 这里连着三层守卫，只有第一层会报：
  //   ① 解析期 `parseDht` 发现"段长不足以承载 counts 声明的符号数"→ 截断（实际报的就是它）；
  //   ② 构造期 `HuffTable` 校验 `k === values.length`（自相矛盾）—— 有直接的构造测试覆盖它；
  //   ③ 查表期 `v === undefined`（查表越界）—— 被 ② 保证，结构上永远到不了。
  //   所以这条断言钉的是"**最先说话的守卫**"；上游任一环被拆掉，报错文本都会变。
  const bytes = Uint8Array.from([
    0xff, 0xd8,
    0xff, 0xc4, 0x00, 0x13, 0x00, // DHT，L=19，Tc=Th=0
    0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 长度1:1 个码，其余 0
    // 0 个符号 ⇒ 段长声称 19，实际只够 counts 的部分
    0xff, 0xd9,
  ]);
  const e = decodeErr(bytes);
  assert.match(e.message, /DHT 段被截断（符号数不足）/, `实际报的是：${e.message}`);
  assert.ok(!e.message.includes("DHT 查表越界"), "查表越界是死防御，不该先报");
});

test("不可达（有守卫支配）：分层差分帧分量数不同时，报的是配对检查而不是找不到参考分量", () => {
  // `hierarchy.ts` 的"找不到分量 X 的参考分量"需要 prev.components[ci] 也是 undefined，
  // 而 `checkPairing` 已经在它之前校验了两帧分量数相等 ⇒ 结构上不可能。
  const dht = [0xff, 0xc4, 0x00, 0x14, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00];
  const bytes = Uint8Array.from([
    0xff, 0xd8,
    ...dht,
    // DHP：完成态 4×4、1 分量
    0xff, 0xde, 0x00, 0x0b, 0x08, 0x00, 0x04, 0x00, 0x04, 0x01, 0x01, 0x11, 0x00,
    // 参考帧：1 分量 2×2
    ...sof11or10(0xc3, 2, 2, [1]),
    ...sos([1], 1, 0, 0, 0),
    0x0f, // 4 个样本，差全 0
    0xff, 0xdf, 0x00, 0x04, 0x01, 0x22,
    // 差分帧：**3 分量** 4×4（与参考帧的 1 个分量不一致）
    // ★ 不能用 2 分量：`checkProcessSupport` 直接拒绝"2 个分量"（只支持 1/3/4），
    //   第一版这么写时报的是"不支持 2 个分量的 JPEG"，比配对检查还早。
    ...sof11or10(0xc7, 4, 4, [1, 2, 3]),
    ...sos([1, 2, 3], 1, 0, 0, 0),
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // 48 个样本，差全 0
    0xff, 0xd9,
  ]);
  const e = decodeErr(bytes);
  assert.match(e.message, /分量数不一致/, `实际报的是：${e.message}`);
  assert.ok(!e.message.includes("找不到分量"), "配对兜底是死防御，不该先报");
});
