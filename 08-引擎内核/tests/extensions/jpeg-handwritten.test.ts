/**
 * L4 · JPEG · 分层：**手写最小流**（不经过我们的编码器）
 *
 * ★ 为什么必须补这一条
 * ------------------
 * 分层（DHP + EXP + 差分帧）是 JPEG 里唯一既没有第三方实现、又**没有第三方语料**的一块：
 * libjpeg / libjpeg-turbo 早把 `hier_code` 整段删了，Pillow、imagecodecs、liblj92 一律不解。
 * 在此之前，分层的全部判据都是"我们的编码器产流 → 我们的解码器解"——
 * 这种判据只能证明两侧一致，不能证明两侧**都按 T.81 的意思**。
 * 典型的塌陷方式：把 EXP 的方向搞反、把"参考帧放大"写成"差分帧缩小"、
 * 或者把差分的取模写成钳位 —— 只要编码器和解码器同错，回环永远绿。
 *
 * ★ 这里换的做法：**字节是手写的**，期望像素是**手算的常量**。
 *   编码器完全不参与，所以"同错"这条路被堵死了。每个流都带完整注释，
 *   每一条 `0x..` 对应 T.81 的哪个字段，可以逐字节核对。
 *
 * ★ 手写的账（每个数字都算一遍，别信"看起来对"）
 * --------------------------------------------
 * 场景 A（无损分层，4×4，参考帧 2×2 全 128，差分帧差全 0）：
 *   参考帧重建 = 128（Annex H 没有电平位移）
 *   差分帧：预测器 P1，初值 2^(P-1) = 128，差值全 0 ⇒ 差分分量重建 = 128
 *   合成按 J.1.1：`s = (diff + ref) mod 2^P` = (128 + 128) mod 256 = **0**
 *   ⇒ 钳位实现给 255、忘掉参考帧给 128 —— 三种结果互不相同，判据有分辨力。
 *
 * 场景 B（有损分层，4×4，两帧系数全 0）：
 *   系数全 0 ⇒ IDCT 输出 0 ⇒ 加电平位移后样本 = 2^(P-1) = 128（两帧都是）
 *   合成：`s = diff - 2^(P-1) + ref` = 128 - 128 + 128 = **128**
 *   ⇒ 忘掉减位移给 256→钳位 255；少加参考帧给 0。
 *
 * 场景 C（同 A，但**不写 EXP 段**）：放大比例由两帧几何决定，EXP 只是声明。
 *   ⇒ 期望仍是 0。这条挡的是"没 EXP 就崩 / 就当 1 倍"。
 *
 * 场景 D（无损分层，2×2，参考帧 1×1 = 200，差分帧差全 0）：
 *   参考帧 1×1 放大到 2×2 必须是**常数 200**（双线性对常数平面不得产生波纹）
 *   差分分量重建 = 128 ⇒ s = (200 + 128) mod 256 = **72**
 *   ⇒ 若上采样在边缘按"缺失邻居"插值，边缘会与内部不同，4 个像素就不再都是 72。
 *
 * ★ 这些判据**不能**证明的：参考帧上采样用**哪种相位**（9:3:3:1 的 1/4 偏移是本实现的选择，
 *   规范只给了图 J.2 没给可执行的取整规则）。所以场景 D 特意用常数参考帧 ——
 *   只有常数平面能与相位无关，才不会把"本实现的相位"当成"规范的要求"写进期望值。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { decodeJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";

const SOI = [0xff, 0xd8];
const EOI = [0xff, 0xd9];

/** DHT：DC 表 0，只有"类别 0"一个符号（1 位码 `0`）→ 每个 0 差值只需 1 bit。 */
const DHT_DC0_ONLY_ZERO = [0xff, 0xc4, 0x00, 0x14, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00];

/** DHT：DC 表 0，含类别 0（长度1，码 `0`）与类别 7（长度2，码 `10`）。 */
const DHT_DC0_CAT0_CAT7 = [
  0xff, 0xc4, 0x00, 0x15, 0x00,
  0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0x00, 0x07,
];

/** DHT：AC 表 0，只有 EOB（符号 0x00，1 位码 `0`）→ 系数全 0 的块只需 2 bit（DC+EOB）。 */
const DHT_AC0_ONLY_EOB = [0xff, 0xc4, 0x00, 0x14, 0x10, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x00];

/** DQT：表 0，步长全 1（等价 q=100）。zigzag 序对"全 1"无影响。 */
const DQT_ALL_ONE = [0xff, 0xdb, 0x00, 0x43, 0x00, ...Array.from({ length: 64 }, () => 1)];

/**
 * DHP：完成态图像头，**不是帧头**（T.81 B.3.2），量化表选择器必须写 0。
 * 8 位、4×4、1 分量（id=1, h=1,v=1, Tq=0）。
 */
const DHP_4x4_GRAY = [0xff, 0xde, 0x00, 0x0b, 0x08, 0x00, 0x04, 0x00, 0x04, 0x01, 0x01, 0x11, 0x00];

/** DHP：8 位、2×2、1 分量。 */
const DHP_2x2_GRAY = [0xff, 0xde, 0x00, 0x0b, 0x08, 0x00, 0x02, 0x00, 0x02, 0x01, 0x01, 0x11, 0x00];

/** EXP：1 个分量条目，Eh=2 / Ev=2。**段长是 4**（2 字节头 + 2 字节条目）——写成 5 会多吃一个字节。 */
const EXP_2x2 = [0xff, 0xdf, 0x00, 0x04, 0x01, 0x22];

/** SOS（无损）：Ns=1、Td=Ta=0、**Ss=1（预测器 P1）**、Se=0、Ah/Al=0。 */
const SOS_LOSSLESS = [0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x01, 0x00, 0x00];

/** SOS（顺序 DCT）：Ns=1、Td=Ta=0、Ss=0、Se=63、Ah/Al=0。 */
const SOS_DCT = [0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00];

/** SOF：精度 8、给定宽高、1 分量（L = 8 + 3×1 = 11）。 */
function sof(marker: number, width: number, height: number): number[] {
  return [
    0xff, marker, 0x00, 0x0b, 0x08,
    (height >> 8) & 0xff, height & 0xff,
    (width >> 8) & 0xff, width & 0xff,
    0x01, 0x01, 0x11, 0x00,
  ];
}

/** 场景 A / C：无损分层，参考帧 2×2（差全 0），差分帧 4×4（差全 0）。 */
function hierLossless(withExp: boolean): Uint8Array {
  return Uint8Array.from([
    ...SOI,
    ...DHT_DC0_ONLY_ZERO,
    ...DHP_4x4_GRAY,
    ...sof(0xc3, 2, 2), // SOF3：参考帧 2×2
    ...SOS_LOSSLESS,
    0x0f, // 4 个样本 × 1 bit '0'，后 4 位填 1（T.81 规定填充用 1）
    ...(withExp ? EXP_2x2 : []),
    ...sof(0xc7, 4, 4), // SOF7：差分帧 4×4
    ...SOS_LOSSLESS,
    0x00, 0x00, // 16 个样本 × 1 bit '0'
    ...EOI,
  ]);
}

/** 场景 B：有损分层，两帧系数全 0。 */
function hierLossy(): Uint8Array {
  return Uint8Array.from([
    ...SOI,
    ...DQT_ALL_ONE,
    ...DHT_DC0_ONLY_ZERO,
    ...DHT_AC0_ONLY_EOB,
    ...DHP_4x4_GRAY,
    ...sof(0xc0, 2, 2), // SOF0：参考帧 2×2（1 个 8×8 块，其余是填充）
    ...SOS_DCT,
    0x3f, // DC '0' + EOB '0'，后 6 位填 1
    ...EXP_2x2,
    ...sof(0xc5, 4, 4), // SOF5：差分帧 4×4
    ...SOS_DCT,
    0x3f,
    ...EOI,
  ]);
}

/** 场景 D：无损分层，参考帧 1×1 = 200，差分帧 2×2 差全 0。 */
function hierLosslessOneByOneRef(): Uint8Array {
  return Uint8Array.from([
    ...SOI,
    ...DHT_DC0_CAT0_CAT7,
    ...DHP_2x2_GRAY,
    ...sof(0xc3, 1, 1), // 参考帧只有 1×1
    ...SOS_LOSSLESS,
    // 唯一那个样本：预测初值 128，值 200 ⇒ 差 = +72 ⇒ 类别 7。
    // 码字 '10'（2 位）+ 幅度 72 = 0b1001000（7 位）⇒ 共 9 位：'10 1001000'
    // 首字节 1010_0100 = 0xA4，余下 1 位 '0' + 7 位填充 1 = 0x7F
    0xa4, 0x7f,
    ...EXP_2x2,
    ...sof(0xc7, 2, 2), // 差分帧 2×2
    ...SOS_LOSSLESS,
    0x0f, // 4 个样本 × 1 bit '0'
    ...EOI,
  ]);
}

interface Decoded {
  readonly w: number;
  readonly h: number;
  readonly gray: number[];
  readonly sof: number;
  readonly frames: number;
  readonly hierarchical: boolean;
  readonly lossless: boolean;
}

function decode(bytes: Uint8Array): Decoded {
  const r = decodeJpeg(bytes, { keep16: true });
  if (!r.ok) throw new Error(`手写流被拒绝：${r.error.code} ${r.error.message}`);
  const d = r.value;
  const gray: number[] = [];
  for (let i = 0; i < d.width * d.height; i++) gray.push(d.pixels[i * 4]!);
  return {
    w: d.width,
    h: d.height,
    gray,
    sof: d.jpeg.sof,
    frames: d.jpeg.frames,
    hierarchical: d.jpeg.hierarchical,
    lossless: d.jpeg.lossless,
  };
}

test("手写分层（无损）：差分的合成必须按 mod 2^P，不是钳位", () => {
  const d = decode(hierLossless(true));
  assert.equal(d.w, 4, "宽必须取差分帧（完成态）的宽度");
  assert.equal(d.h, 4);
  assert.equal(d.sof, 0xc7, "最终帧是 SOF7（差分无损）");
  assert.equal(d.frames, 2, "两帧（参考帧 + 差分帧）");
  assert.equal(d.hierarchical, true, "出现 DHP + 两个 SOF 必须被识别成分层");
  assert.equal(d.lossless, true, "SOF7 是无损差分帧");
  // (128 + 128) mod 256 = 0
  assert.deepEqual(d.gray, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "mod 2^8 的期望是 0（钳位会给 255）");
});

test("手写分层（有损）：差图必须减回电平位移再叠参考帧", () => {
  const d = decode(hierLossy());
  assert.equal(d.sof, 0xc5, "最终帧是 SOF5（差分帧）");
  // 128 - 128 + 128 = 128
  assert.deepEqual(d.gray, [128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128], "忘掉减位移会给 255");
});

test("手写分层：缺 EXP 段时按两帧几何决定放大比例（EXP 只是声明）", () => {
  const d = decode(hierLossless(false));
  assert.equal(d.w, 4);
  assert.equal(d.sof, 0xc7);
  assert.deepEqual(d.gray, [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], "没有 EXP 时语义不变");
});

test("手写分层：1×1 参考帧放大到 2×2 必须仍是常数（相位不该让边缘塌）", () => {
  const d = decode(hierLosslessOneByOneRef());
  assert.equal(d.w, 2);
  assert.equal(d.h, 2);
  // (200 + 128) mod 256 = 72
  assert.deepEqual(d.gray, [72, 72, 72, 72], "常数参考帧放大后仍是常数；(200+128) mod 256 = 72");
});

test("手写分层的字节数固定（手滑改掉一个 0x.. 会让上面几条悄悄失去意义）", () => {
  // 长度是把字段字节数加起来手算的，不是从解码器反推的：
  // A = SOI2 + DHT22 + DHP13 + SOF13 + SOS10 + 熵1 + EXP6 + SOF13 + SOS10 + 熵2 + EOI2 = 94
  assert.equal(hierLossless(true).length, 94, "场景 A 的总字节数");
  // C = A 去掉 6 字节的 EXP
  assert.equal(hierLossless(false).length, 88, "场景 C 的总字节数");
  // B = SOI2 + DQT69 + DHT22 + DHT22 + DHP13 + SOF13 + SOS10 + 熵1 + EXP6 + SOF13 + SOS10 + 熵1 + EOI2 = 184
  assert.equal(hierLossy().length, 184, "场景 B 的总字节数");
  // D = SOI2 + DHT23 + DHP13 + SOF13 + SOS10 + 熵2 + EXP6 + SOF13 + SOS10 + 熵1 + EOI2 = 95
  //   ★ 第一版这里写的是 105 —— 是**我加错了**（把 DHT 的 L 字段算重了），长度断言当场报 95≠105。
  //     这条断言的价值就在这里：手算也会错，所以手算的结论要落成断言，让机器每次复核。
  assert.equal(hierLosslessOneByOneRef().length, 95, "场景 D 的总字节数");
});
