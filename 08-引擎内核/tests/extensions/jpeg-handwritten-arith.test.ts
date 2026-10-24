/**
 * L4 · JPEG · SOF11（算术无损）：**手写最小流**
 *
 * ★ 缺口在哪
 * ---------
 * SOF11 是 JPEG 里证据最薄的一格：libjpeg 对 `lossless && arith` 直接 `JERR_ARITH_NOTIMPL`，
 * ffmpeg 根本不解算术，liblj92 只管 Huffman 无损。所以此前的依据是"组合可信"——
 * 算术引擎被 SOF9/SOF10 对着 libjpeg 验过、无损预测被 SOF3 对着 liblj92 验过，两者拼起来应该对。
 * 但"两块各自对"不等于"接缝对"：DC 模型用在**样本差分**上时，
 * 预测初值要不要跟着 Pt 缩小、重建要不要再把 Pt 左移回来，这两条都只在接缝上出错。
 *
 * ★ 做法：段结构手写，期望像素手算
 * ------------------------------
 * 熵数据用**测试端的 QM 编码器**（`encodeArithBins`，独立实现 —— 它在 SOF9/10 上
 * 是被 libjpeg 的解码器验过的）。这里只把"节的骨架"手写出来：
 *
 *   SOI · SOF11(P, Y, X, 1 分量) · SOS(Ss=1 预测器 P1, Se=0, Ah=0, Al=Pt) · QM 熵数据 · EOI
 *
 * 每个样本 1 个 bin（上下文 0、值 0 = MPS）⇒ 差分为 0 ⇒ 重建只由**预测初值**决定：
 *
 *   `initial = 2^(P - Pt - 1)`，平面里存的就是它，之后 `<< Pt` 还原
 *   ⇒ 输出恒为 `2^(P-Pt-1) << Pt = 2^(P-1)`（与 Pt 无关！）
 *
 * 8 位恒为 **128**、12 位恒为 **2048**。写错时的结果互不相同：
 *   · 初值忘了随 Pt 缩小（用 2^(P-1)）：Pt=2 时得 128<<2 = 512 → 钳到 255
 *   · 重建忘了 `<< Pt`：Pt=2 时得 32
 *   · 精度没进公式（写死 128）：12 位时得 128 而不是 2048
 *
 * ★ 这个判据**不能**证明的部分：非零差分的上下文转移（图 F.23/F.24 的幅度树与
 *   `nextCtx` 选择）。那一段仍然只有"测试端 QM 编码器 ↔ 生产端 QM 解码器"的回环，
 *   而那不是第三方 —— 已在 ADR-0009 ⑥-b 如实标注。
 *   这里补的是**接缝**（初值 / Pt / 位深），不是整条 SOF11 通路。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { decodeJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";
import { DC_STAT_BINS } from "../../src/extensions/asset-import/decode/jpeg/qm.ts";
import { encodeArithBins } from "../tools/jpeg-encode.ts";

/**
 * 手写 SOF11 流：所有样本的差分都是 0（每个样本 1 个 MPS bin）。
 *
 * `pt` 是点变换（SOS 里的 Al），`precision` 决定样本量程。
 */
function sof11AllZeroDiff(width: number, height: number, precision: number, pt: number): Uint8Array {
  const samples = width * height;
  const bins = Array.from({ length: samples }, () => ({ ctx: 0, val: 0 }));
  const { bytes } = encodeArithBins(bins, DC_STAT_BINS);
  return Uint8Array.from([
    0xff, 0xd8, // SOI
    // SOF11（0xCB）：P、Y、X、Nf=1、[id=1, h=1 v=1, Tq=0]
    0xff, 0xcb, 0x00, 0x0b, precision, (height >> 8) & 0xff, height & 0xff, (width >> 8) & 0xff, width & 0xff,
    0x01, 0x01, 0x11, 0x00,
    // SOS：Ns=1、Td=Ta=0、Ss=1（预测器 P1）、Se=0、Ah<<4|Al = Pt
    0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x01, 0x00, pt & 0x0f,
    ...bytes,
    0xff, 0xd9, // EOI
  ]);
}

/** 解码并返回 8 位灰度（所有样本应相同）。 */
function grayValues(bytes: Uint8Array): { w: number; h: number; values: number[]; sof: number; precision: number } {
  const r = decodeJpeg(bytes, { keep16: true });
  if (!r.ok) throw new Error(`手写 SOF11 流被拒绝：${r.error.code} ${r.error.message}`);
  const d = r.value;
  const values: number[] = [];
  for (let i = 0; i < d.width * d.height; i++) values.push(d.pixels[i * 4]!);
  return { w: d.width, h: d.height, values, sof: d.jpeg.sof, precision: d.jpeg.precision };
}

test("手写 SOF11：全零差分时，重建就等于预测初值（8 位 = 128）", () => {
  const d = grayValues(sof11AllZeroDiff(2, 2, 8, 0));
  assert.equal(d.sof, 0xcb, "必须是 SOF11");
  assert.equal(d.precision, 8);
  assert.equal(d.w, 2);
  assert.equal(d.h, 2);
  assert.deepEqual(d.values, [128, 128, 128, 128], "初值 2^(8-0-1) = 128");
});

test("手写 SOF11：Pt>0 时初值必须跟着缩小，重建再把 Pt 左移回来（结果仍 = 128）", () => {
  // 这条是接缝上的关键：initial = 2^(P-Pt-1) = 2^(8-2-1) = 32，32 << 2 = 128。
  // 若初值忘了随 Pt 缩小（用 128）：128 << 2 = 512 → 钳到 255；
  // 若重建忘了左移：得 32。三个结果的差别足够大。
  const d = grayValues(sof11AllZeroDiff(2, 2, 8, 2));
  assert.deepEqual(d.values, [128, 128, 128, 128], "32 << 2 = 128");
  // Pt=4 同样成立：2^3 = 8，8 << 4 = 128
  const d4 = grayValues(sof11AllZeroDiff(2, 2, 8, 4));
  assert.deepEqual(d4.values, [128, 128, 128, 128], "8 << 4 = 128");
});

test("手写 SOF11（12 位）：初值必须走 2^(P-1) = 2048，不是写死的 128", () => {
  const d = grayValues(sof11AllZeroDiff(2, 2, 12, 0));
  assert.equal(d.precision, 12);
  // pixels 是 8 位输出：2048 在 12 位量程上正好是中点 ⇒ 128
  assert.deepEqual(d.values, [128, 128, 128, 128], "12 位的中点降到 8 位仍是 128");
  // 但全精度值必须是 2048 附近（不是 128 那种"忘了精度"的结果）
  const r = decodeJpeg(sof11AllZeroDiff(2, 2, 12, 0), { keep16: true });
  assert.ok(r.ok);
  const p16 = r.value.pixels16!;
  const native = Math.round((p16[0]! * 4095) / 65535);
  assert.equal(native, 2048, `12 位样本必须是 2048（实际 ${native}）—— 128 说明精度没进初值公式`);
});

test("手写 SOF11：块大小为 8×8 时逐样本都成立（不是只有第一个样本对）", () => {
  const d = grayValues(sof11AllZeroDiff(8, 8, 8, 0));
  assert.equal(d.values.length, 64);
  assert.deepEqual(d.values, Array.from({ length: 64 }, () => 128), "每个样本都必须等于初值");
});

test("手写 SOF11：全 MPS 的熵数据几乎不增长（这同时说明 QM 真的是算术编码）", () => {
  // ★ 一开始我写了"样本更多的流必须更长"，跑出来是**相等**。
  //   原因是算术编码对全 MPS 的压缩率极端：实测 4 / 16 / 64 / 256 / 1024 个零 bin
  //   都压成 **1 字节**，4096 个才 2 字节。
  //   这个"反直觉"的事实正好可以当判据：如果哪天实现退化成"一位一码"（哈夫曼式），
  //   长度会随 bin 数线性增长，这条立刻红。
  const len = (n: number): number => {
    const bins = Array.from({ length: n }, () => ({ ctx: 0, val: 0 }));
    return encodeArithBins(bins, DC_STAT_BINS).bytes.length;
  };
  assert.equal(len(4), 1, "4 个 MPS bin → 1 字节");
  assert.equal(len(1024), 1, "1024 个 MPS bin 仍是 1 字节（不是线性增长）");
  assert.ok(len(4096) <= 3, `4096 个 MPS bin 用了 ${len(4096)} 字节 —— 线性增长说明不是算术编码`);

  // 头部恒定：Pt 不改变熵数据长度（差分全 0 ⇒ bin 序列一样）
  const a = sof11AllZeroDiff(2, 2, 8, 0);
  const b = sof11AllZeroDiff(2, 2, 8, 2);
  assert.equal(a.length, b.length, "Pt 不改变熵数据长度");
  // 头部 = SOI2 + SOF13 + SOS10 + EOI2 = 27 字节
  assert.equal(a.length, 27 + 1, "2×2：头部 27 + 熵数据 1");
});

test("手写 SOF11：算术编码段没有 DHT/DQT 也必须能解（算术过程不带哈夫曼表）", () => {
  const bytes = sof11AllZeroDiff(4, 4, 8, 0);
  // 走查一遍：整条流里不能出现 DHT(0xC4)/DQT(0xDB)
  for (let i = 0; i + 1 < bytes.length; i++) {
    if (bytes[i] !== 0xff) continue;
    const m = bytes[i + 1]!;
    assert.ok(m !== 0xc4, "SOF11 的流里不该有 DHT");
    assert.ok(m !== 0xdb, "无损没有量化表，不该有 DQT");
  }
  const d = grayValues(bytes);
  assert.deepEqual(d.values, Array.from({ length: 16 }, () => 128));
});
