/**
 * L4 · JPEG · 模式矩阵与分层/多帧的结构判据（进程内回环）
 *
 * ★ 为什么这个文件不读 `tests/fixtures/jpeg/` 的金标：
 *   算术与分层**没有第三方编码器**能产语料（Pillow 不暴露 arith_code，
 *   libjpeg 早已移除 `hier_code`），所以"外部金标"这条路走不通。
 *   这里换一条**不依赖任何外部实现、但比"看起来对"强得多**的判据：
 *
 *   ① 同一份源图用 4 种有损过程（baseline / 渐进 / 算术顺序 / 算术渐进）编码，
 *      解出的像素必须**逐字节相同**。量化表与 DCT 一样 ⇒ 系数必须一样 ⇒
 *      重建必须一样。任何一处熵解码错位、任何一处统计区建错，都会破坏它。
 *      这条比"和 libjpeg 差 ≤3"更硬：它没有容差。
 *   ② 无损过程（SOF3 / SOF11 / SOF7）必须**逐样本相等**（max = 0）。
 *      无损格式没有"取整"这个借口。
 *   ③ 分层有损的成像质量必须与**同参数的非分层基线**同量级（不超过基线 + 小余量）。
 *      这条挡的是"合成语义写错但看起来还是张图"——半分辨率参考帧 + 双线性上采样
 *      一旦相位错，误差会成片放大，而 max 阈值立刻爆。
 *
 * ★ 这些判据的盲区（写在 ADR-0009，不粉饰）：
 *   编解码两侧对规范的理解如果是**同一种错**，回环永远绿。所以这里每条断言都尽量
 *   写成"跨实现"或"跨模式"的形式，而不是"我们和我们自己一致"。
 *   QM 那组回环比的是"测试端编码器 vs 生产端解码器"两个独立实现。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { decodeJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";
import type { DecodedJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";
import { HuffTable } from "../../src/extensions/asset-import/decode/jpeg/bits.ts";
import { predictLossless } from "../../src/extensions/asset-import/decode/jpeg/lossless-pred.ts";
import { buildPlane, planesToRgba, sampleComponent } from "../../src/extensions/asset-import/decode/jpeg/reconstruct.ts";
import { checkProcessSupport } from "../../src/extensions/asset-import/decode/jpeg/frame.ts";
import type { Component, Frame } from "../../src/extensions/asset-import/decode/jpeg/frame.ts";
import { QM_SWITCH_STATES, QmDecoder, newStats } from "../../src/extensions/asset-import/decode/jpeg/qm.ts";
import { arithTrace, encodeArithBins, encodeJpeg } from "../tools/jpeg-encode.ts";
import type { EncodeSpec, JpegMode } from "../tools/jpeg-encode.ts";

// 分层编码要求宽高为偶数（参考帧取 1/2 分辨率），所以整张矩阵统一用 40×24。
const W = 40;
const H = 24;

function maxOf(precision: number): number {
  return (1 << precision) - 1;
}

/** 平滑内容：低频渐变，用来看"有损质量是否与基线同量级"。 */
function smoothGray(precision: number): Uint16Array {
  const max = maxOf(precision);
  const a = new Uint16Array(W * H);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      a[y * W + x] = Math.round(((Math.sin(x * 0.25) + Math.cos(y * 0.3) + 2) / 4) * max);
    }
  }
  return a;
}

/** 高反差锯齿：无损必须一位不差，专门用来打"差不多就行"的实现。 */
function hardGray(precision: number): Uint16Array {
  const max = maxOf(precision);
  const a = new Uint16Array(W * H);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) a[y * W + x] = Math.round((((x * 7 + y * 13) % 97) / 96) * max);
  }
  return a;
}

function hardRgb(precision: number): Uint16Array {
  const max = maxOf(precision);
  const a = new Uint16Array(W * H * 3);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 3;
      a[o] = Math.round((x / (W - 1)) * max);
      a[o + 1] = Math.round((y / (H - 1)) * max);
      a[o + 2] = Math.round((((x + y) % 17) / 16) * max);
    }
  }
  return a;
}

function smoothRgb(precision: number): Uint16Array {
  const max = maxOf(precision);
  const a = new Uint16Array(W * H * 3);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 3;
      a[o] = Math.round(((Math.sin(x * 0.2) + 1) / 2) * max);
      a[o + 1] = Math.round(((Math.cos(y * 0.22) + 1) / 2) * max);
      a[o + 2] = Math.round(((x + y) / (W + H)) * max);
    }
  }
  return a;
}

function spec(components: 1 | 3, precision: 8 | 12, mode: JpegMode, quality = 90): EncodeSpec {
  return { width: W, height: H, components, precision, mode, quality };
}

function mustDecode(bytes: Uint8Array): DecodedJpeg {
  const r = decodeJpeg(bytes, { keep16: true });
  if (!r.ok) throw new Error(`期望解码成功，实际 ${r.error.code} ${r.error.message}`);
  return r.value;
}

/** 把解码输出（满 16 位量程）换回源精度域，便于和输入样本直接比。 */
function backToNative(
  d: DecodedJpeg,
  components: 1 | 3,
  precision: number,
  w: number = W,
  h: number = H,
): Uint16Array {
  const p16 = d.pixels16;
  assert.ok(p16 !== undefined, "必须用 keep16 解码，否则比的是 8 位量化后的值");
  const max = maxOf(precision);
  const out = new Uint16Array(w * h * components);
  for (let i = 0; i < w * h; i++) {
    for (let c = 0; c < components; c++) {
      out[i * components + c] = Math.round((p16[i * 4 + c]! * max) / 65535);
    }
  }
  return out;
}

interface Stat {
  readonly max: number;
  readonly mean: number;
  readonly differing: number;
  /** 首个偏差的文字描述：失败时必须能一眼看到"差在哪"，否则只知道差多少。 */
  readonly detail: string;
}

function diffStat(a: Uint16Array, b: Uint16Array): Stat {
  assert.equal(a.length, b.length, "比较的两份样本长度不同（尺寸或通道数算错了）");
  let max = 0;
  let sum = 0;
  let differing = 0;
  let detail = "";
  for (let i = 0; i < a.length; i++) {
    const d = Math.abs(a[i]! - b[i]!);
    if (d !== 0) differing++;
    if (d > max) {
      max = d;
      detail = `样本 ${i}：本地 ${b[i]} vs 期望 ${a[i]}`;
    }
    sum += d;
  }
  return { max, mean: sum / a.length, differing, detail };
}

function diffBytes(a: Uint16Array, b: Uint16Array): number {
  assert.equal(a.length, b.length);
  let n = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) n++;
  return n;
}

// ------------------------------------------------------------ ① 跨模式逐字节一致

const LOSSY_MODES: readonly JpegMode[] = ["baseline", "progressive", "arith-sequential", "arith-progressive"];

for (const precision of [8, 12] as const) {
  for (const components of [1, 3] as const) {
    const label = components === 1 ? "gray" : "rgb";
    test(`JPEG 模式矩阵 ${precision}bit/${label}：四种有损过程解出逐字节相同的像素`, () => {
      // 渐进/算术只是"把同一批系数换个顺序/换个熵编码器写出去"，
      // 所以四条的 pixels16 必须完全相等 —— 这条没有容差。
      const src = components === 1 ? smoothGray(precision) : smoothRgb(precision);
      const results = new Map<JpegMode, Uint16Array>();
      for (const mode of LOSSY_MODES) {
        const d = mustDecode(encodeJpeg(src, spec(components, precision, mode)));
        assert.equal(d.jpeg.precision, precision, `${mode}: 精度上报错误`);
        assert.equal(d.jpeg.progressive, mode === "progressive" || mode === "arith-progressive");
        assert.equal(d.jpeg.arithmetic, mode.startsWith("arith"));
        assert.equal(d.jpeg.lossless, false);
        results.set(mode, d.pixels16!);
      }
      const base = results.get("baseline")!;
      for (const mode of LOSSY_MODES) {
        if (mode === "baseline") continue;
        const n = diffBytes(base, results.get(mode)!);
        assert.equal(
          n,
          0,
          `${precision}bit/${label}: ${mode} 与 baseline 有 ${n} 个样本不同 —— 系数相同就该逐字节相同，` +
            "不同说明熵解码错位或重建路径分叉",
        );
      }
    });
  }
}

// ------------------------------------------------------------ ② 无损逐样本相等

const LOSSLESS_MODES: readonly JpegMode[] = ["lossless", "arith-lossless"];

for (const precision of [8, 12] as const) {
  for (const components of [1, 3] as const) {
    const label = components === 1 ? "gray" : "rgb";
    for (const mode of LOSSLESS_MODES) {
      test(`JPEG 无损回环 ${precision}bit/${label}/${mode}：逐样本相等（max=0）`, () => {
        const src = components === 1 ? hardGray(precision) : hardRgb(precision);
        const d = mustDecode(encodeJpeg(src, spec(components, precision, mode)));

        assert.equal(d.jpeg.lossless, true);
        assert.equal(d.jpeg.progressive, false, "无损过程没有渐进式");
        assert.equal(d.jpeg.differential, false, "单帧文件的帧头不是差分帧");
        assert.equal(d.jpeg.precision, precision);
        assert.equal(d.jpeg.frames, 1);

        const got = backToNative(d, components, precision);
        const st = diffStat(src, got);
        assert.equal(st.max, 0, `无损回环差 ${st.max}（${st.differing} 个样本不等）—— 无损格式不允许任何偏差`);
      });
    }
  }
}

// ------------------------------------------------------------ ③ 分层与多帧

for (const precision of [8, 12] as const) {
  for (const components of [1, 3] as const) {
    const label = components === 1 ? "gray" : "rgb";
    test(`JPEG 分层无损 ${precision}bit/${label}：两帧合成后逐样本相等（max=0）`, () => {
      // 高反差内容 + 半分辨率参考帧：上采样相位一旦错位，边缘立刻差几十级。
      const src = components === 1 ? hardGray(precision) : hardRgb(precision);
      const d = mustDecode(encodeJpeg(src, spec(components, precision, "hier-lossless")));

      assert.equal(d.jpeg.hierarchical, true, "有 DHP 的文件必须报 hierarchical");
      assert.equal(d.jpeg.frames, 2, "分层文件里有两个帧头");
      assert.equal(d.jpeg.sof, 0xc7, "最后一帧是 SOF7（差分无损），要从原始标记看出来");
      assert.equal(d.jpeg.differential, true, "最后一帧是差分帧");
      assert.equal(d.jpeg.lossless, true);
      assert.equal(d.jpeg.precision, precision);

      const got = backToNative(d, components, precision);
      const st = diffStat(src, got);
      assert.equal(st.max, 0, `分层无损差 ${st.max}（${st.differing} 个样本）—— 参考帧合成错了`);
    });
  }
}

for (const precision of [8, 12] as const) {
  for (const components of [1, 3] as const) {
    const label = components === 1 ? "gray" : "rgb";
    test(`JPEG 分层有损 ${precision}bit/${label}：质量与同参数非分层基线同量级`, () => {
      const src = components === 1 ? smoothGray(precision) : smoothRgb(precision);
      const hier = mustDecode(encodeJpeg(src, spec(components, precision, "hier-sequential")));
      const base = mustDecode(encodeJpeg(src, spec(components, precision, "baseline")));

      assert.equal(hier.jpeg.sof, 0xc5, "最后一帧是 SOF5（差分顺序）");
      assert.equal(hier.jpeg.hierarchical, true);
      assert.equal(hier.jpeg.frames, 2);

      const stHier = diffStat(src, backToNative(hier, components, precision));
      const stBase = diffStat(src, backToNative(base, components, precision));

      // 阈值形式是"基线 × 2 + 2"，不是拍一个绝对数：
      // 分层的参考帧是半分辨率再双线性放大，天生比全分辨率基线差一档，
      // 但**差一个数量级就说明是合成写错**（相位/电平位移），不是有损的代价。
      // 实测（quality 90，40×24）：8 位灰度 3 vs 2、8 位 RGB 12 vs 6、
      // 12 位灰度 3 vs 3、12 位 RGB 11 vs 9 —— 全部落在 2×+2 内。
      // 变异校验（tools/mutation-check.py）里把双线性权重改成最近邻后，这条会红。
      const limit = stBase.max * 2 + 2;
      assert.ok(
        stHier.max <= limit,
        `分层有损 max=${stHier.max} 超过 ${limit}（基线 max=${stBase.max}）—— ` +
          "参考帧上采样或差分合成写错了（相位/电平位移），而不是'有损本来就会差'",
      );
      assert.ok(
        stHier.mean <= stBase.mean * 1.5 + 0.5,
        `分层有损平均误差 ${stHier.mean.toFixed(3)} 远大于基线 ${stBase.mean.toFixed(3)}`,
      );
    });
  }
}

test("JPEG 分层：DHP 声明的是完成态几何，帧可以更小但不能更大", () => {
  // 反向用例：把第二帧的宽高改到超过 DHP，必须被拒绝（否则会读到帧外内存/错行）。
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"));
  const patched = withSofField(bytes, 0xc3, "height", 0x7fff);
  assert.ok(patched !== null, "分层文件里应该有半分辨率的 SOF3");
  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.error.message, /超过 DHP|DHP/);
});

test("JPEG 12 位：DC 差分类别必须允许超过 11（写死 8 位的上限会在这里死）", () => {
  // ★ 这条是被变异校验逼出来的：M22（把 maxDcCategory 写死 11）一开始**没有被抓住**，
  //   因为所有 12 位用例都是平滑渐变，块间 DC 差从没超过 2047（类别 11）。
  //   而 T.81 Table F.1 给 12 位留到类别 15 —— 也就是说"12 位支持"在最需要它的
  //   高反差素材上从没被验证过。修法不是放宽判据，而是**造出会跨过 11 的输入**：
  //   相邻 8×8 块在 0 与 4095 之间跳变 ⇒ DC 差 ≈ 32752，类别 15。
  const max = maxOf(12);
  const src = new Uint16Array(W * H);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const blockDark = ((x >> 3) + (y >> 3)) % 2 === 0;
      src[y * W + x] = blockDark ? 0 : max;
    }
  }

  // quality 100：量化步长全 1，DC 差按真实值写出来（类别才会真的到 15）
  const bytes = encodeJpeg(src, { ...spec(1, 12, "baseline"), quality: 100 });
  const d = mustDecode(bytes);
  assert.equal(d.jpeg.precision, 12);

  const got = backToNative(d, 1, 12);
  const st = diffStat(src, got);
  // 只断言"没崩且重建对"：量化步长=1 时误差应当只剩 DCT 的取整（≤2 级，满量程 4095）
  assert.ok(st.max <= 2, `12 位高反差图的 DC 重建误差 ${st.max} 过大 —— DC 类别/幅值位读错了`);
  assert.equal(st.differing, 0, "quality=100 时同值块的 DC 应精确重建（有偏差说明差分解码错位）");
});

// ------------------------------------------------------------ ④ QM 状态机（跨实现回环）
test("QM 算术引擎：测试端编码器 vs 生产端解码器，5000 个 bin 逐位一致", () => {
  // ★ 这条挡的是一个真实发生过的 bug：`Next_Index_LPS` 表漏了 Switch_MPS 位（bit 7）。
  //   症状极其隐蔽 —— DC 全对、块首 AC 偏小、其余全 0，位流依然"合法"。
  //   只喂 bin 的好处是：错一位就在下一位露出来，不需要等它污染到像素。
  let seed = 12345;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
  const ctxCount = 7;
  const bins = Array.from({ length: 5000 }, (_, i) => ({ ctx: i % ctxCount, val: rnd() < 0.15 ? 1 : 0 }));

  const { bytes, trace } = encodeArithBins(bins, ctxCount);
  assert.equal(trace.length, bins.length, "trace 必须逐 bin 记录，否则对不齐");
  assert.deepEqual(trace[0], bins[0]);
  assert.deepEqual(trace[bins.length - 1], bins[bins.length - 1]);

  // 解码端会预读 2 字节；补两个 0 等价于"扫描后面跟着标记"，避免最后几位被当成提前结束。
  const padded = new Uint8Array(bytes.length + 2);
  padded.set(bytes);
  const stats = newStats(ctxCount);
  const dec = new QmDecoder(padded, 0, padded.length);
  const got = bins.map((b) => dec.decode(stats, b.ctx));

  const firstBad = got.findIndex((v, i) => v !== bins[i]!.val);
  assert.equal(firstBad, -1, `第 ${firstBad} 个 bin 编解码不一致 —— QM 状态表（Next_Index/NMPS/Switch_MPS）错了`);
  assert.equal(dec.hitMarker, false, "补了 2 字节后不该再触底");
});

test("QM 表：Switch_MPS 的 10 个状态索引必须逐项正确（漏一个就会污染同桶的第二次决策）", () => {
  // T.81 Table D.3 / libjpeg jaricom.c 的 V() 宏第 4 列。索引写错不会崩，只会静默错。
  assert.deepEqual([...QM_SWITCH_STATES], [0, 14, 36, 64, 80, 88, 95, 105, 110, 112]);
  for (const s of QM_SWITCH_STATES) assert.ok(s >= 0 && s < 114, `状态索引 ${s} 越界`);
  assert.equal(new Set(QM_SWITCH_STATES).size, QM_SWITCH_STATES.length, "索引不能重复");
});

test("QM trace 钩子：不装钩子时生产路径不受影响（全局变量不能漏进正常编码）", () => {
  assert.equal(arithTrace.fn, null, "测试结束必须复位，否则后续编码会一直往数组里写");
});

// ------------------------------------------------------------ ⑤ DHP / EXP 结构判据

test("JPEG 拒绝：DHP 的量化表选择器必须是 0", () => {
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xde);
  assert.ok(at >= 0, "分层文件必须带 DHP（0xDE）");
  const segLen = (bytes[at + 2]! << 8) | bytes[at + 3]!;
  assert.ok(segLen >= 9, "DHP 里至少有一个分量（6 + 3 字节）");
  const patched = Uint8Array.from(bytes);
  patched[at + 4 + 8] = 1; // 第 1 个分量的 Tq（6 + 0*3 + 2）

  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "ASSET.BAD_JPEG");
    assert.match(r.error.message, /量化表选择器应为 0/);
  }
});

test("JPEG 拒绝：EXP 的放大因子必须在 1..4（0 和 5 都不行）", () => {
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xdf);
  assert.ok(at >= 0, "分层文件必须带 EXP（0xDF）");
  for (const bad of [0x05, 0x50]) {
    const patched = Uint8Array.from(bytes);
    patched[at + 5] = bad; // 第一个分量的 Eh/Ev 字节
    const r = decodeJpeg(patched);
    assert.equal(r.ok, false, `Eh/Ev=0x${bad.toString(16)} 应该被拒绝`);
    if (!r.ok) assert.match(r.error.message, /放大因子非法/);
  }
});

test("JPEG 拒绝：EXP 出现在 DHP 之前（没有参考帧可放大）", () => {
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xdf);
  assert.ok(at >= 0);
  const segLen = (bytes[at + 2]! << 8) | bytes[at + 3]!;
  const expSeg = bytes.subarray(at, at + 2 + segLen);
  // SOI + EXP + 原文件（去掉 SOI）
  const patched = new Uint8Array(2 + expSeg.length + bytes.length - 2);
  patched.set(bytes.subarray(0, 2));
  patched.set(expSeg, 2);
  patched.set(bytes.subarray(2), 2 + expSeg.length);

  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.error.message, /EXP 出现在 DHP 之前/);
});

test("JPEG 拒绝：EXP 之后没有帧头（放大因子无处生效）", () => {
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xdf);
  assert.ok(at >= 0);
  const segLen = (bytes[at + 2]! << 8) | bytes[at + 3]!;
  const expSeg = bytes.subarray(at, at + 2 + segLen);
  const body = bytes.subarray(0, bytes.length - 2); // 去掉 EOI
  const patched = new Uint8Array(body.length + expSeg.length + 2);
  patched.set(body, 0);
  patched.set(expSeg, body.length);
  patched.set([0xff, 0xd9], body.length + expSeg.length);

  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.error.message, /EXP 段之后没有帧头/);
});

test("JPEG 拒绝：DHP 只能出现在第一帧之前（放在帧后面就是坏流）", () => {
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xde);
  assert.ok(at >= 0);
  const segLen = (bytes[at + 2]! << 8) | bytes[at + 3]!;
  const dhpSeg = bytes.subarray(at, at + 2 + segLen);
  const body = bytes.subarray(0, bytes.length - 2);
  const patched = new Uint8Array(body.length + dhpSeg.length + 2);
  patched.set(body, 0);
  patched.set(dhpSeg, body.length);
  patched.set([0xff, 0xd9], body.length + dhpSeg.length);

  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.error.message, /DHP 只能出现在第一帧之前/);
});

test("JPEG 拒绝：DHP 声明的精度与帧不一致", () => {
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xde);
  assert.ok(at >= 0);
  const patched = Uint8Array.from(bytes);
  patched[at + 4] = 12; // DHP 的 P 字节

  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.error.message, /精度不一致/);
});

test("JPEG 拒绝：差分帧少声明分量时，SOS 引用不存在的分量必须点名", () => {
  // 分层文件里三个分量必须能逐分量配对。这里只改第二帧 SOF 的 Nf 字节，段体不动，
  // 于是 SOS 里仍然引用 3 个分量 —— 第一道关卡就会拦下，而且**点名缺哪个 id**。
  // （第二道关卡是 hierarchy.ts 的 checkPairing：帧级分量数 1 vs 3。
  //   要走到它得同时改 SOS 的 Ns 与段体长度，那样文件已经不成形，测的是构造器而不是解码器。）
  const bytes = encodeJpeg(hardRgb(8), spec(3, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xc7);
  assert.ok(at >= 0, "第二帧应该是 SOF7（差分无损）");
  const patched = Uint8Array.from(bytes);
  patched[at + 9] = 1; // SOF 数据区：P(1) Y(2) X(2) Nf(1) → at+4+5

  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "ASSET.BAD_JPEG");
    assert.match(r.error.message, /SOS 引用了帧里不存在的分量 id=/);
  }
});

test("JPEG 拒绝：差分帧精度与参考帧不一致", () => {
  const bytes = encodeJpeg(hardGray(8), spec(1, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xc7);
  assert.ok(at >= 0);
  const patched = Uint8Array.from(bytes);
  patched[at + 4] = 12; // 第二帧的 P
  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.error.message, /精度.*不一致|精度 12/);
});

test("JPEG 拒绝：EXP 放大因子与实际几何不符（解析了却不用 = 装饰）", () => {
  // ★ 这条盯的是一个真实的"半接线"状态：EXP 被解析进 `expansions`，
  //   但 `expansionMatchesGeometry()` 从来没被调用过 —— 参数读进来就没人看。
  //   现在合成前会核对"Eh/Ev 是否等于参考帧到本帧的尺寸比"，矛盾就报错。
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"));
  const at = findSeg(bytes, 0xdf);
  assert.ok(at >= 0);
  const patched = Uint8Array.from(bytes);
  patched[at + 5] = 0x44; // 实际是 2×，文件却声明 4×
  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) assert.match(r.error.message, /EXP 放大因子与实际几何不一致/);

  // 反向守卫：不改成 4× 时同一条路径必须通过（判据不是恒红）
  assert.ok(decodeJpeg(bytes).ok, "原文件的 EXP 与几何一致，必须解得开");
});

test("JPEG 拒绝：首帧就是差分帧（没有参考帧可以相减）", () => {  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "lossless"));
  const at = findSeg(bytes, 0xc3);
  assert.ok(at >= 0, "无损文件应该是 SOF3");
  const patched = Uint8Array.from(bytes);
  patched[at + 1] = 0xc7; // SOF3 → SOF7（差分无损）

  const r = decodeJpeg(patched);
  assert.equal(r.ok, false);
  if (!r.ok) {
    assert.equal(r.error.code, "ASSET.BAD_JPEG");
    assert.match(r.error.message, /第 1 帧就是差分帧/);
  }
});

// ------------------------------------------------------------ ⑥ 边界尺寸 / 截断鲁棒性

/**
 * ★ 为什么单独做一组"退化尺寸 × 全模式"：
 *   固定 40×24 的矩阵永远碰不到"宽不是 MCU 整数倍""只有一列""8×8 恰好一个块"
 *   这些分支，而它们正是块索引、块步长（`strideBlocksW`）、上采样边界最容易出错的地方。
 *   编码端与解码端都按 T.81 独立实现，所以这里既不是自证，也不依赖外部文件。
 */
const SIZES: ReadonlyArray<readonly [number, number]> = [
  [1, 1],
  [1, 7],
  [7, 1],
  [8, 8],
  [9, 9],
  [13, 11],
  [17, 23],
  [33, 33],
];

for (const [w, h] of SIZES) {
  test(`JPEG 退化尺寸 ${w}×${h}：无损（含算术）逐样本相等、有损不崩且与基线一致`, () => {
    const max = maxOf(8);
    // 用坐标哈希造高反差内容：小图上也能产生非零 AC，避免"全零系数"掩盖错误
    const src = new Uint16Array(w * h);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) src[y * w + x] = ((x * 37 + y * 59) % 256) & 0xff;
    }
    const base = { width: w, height: h, components: 1 as const, precision: 8 as const };
    void max;

    // 无损：两个熵编码器都必须一位不差
    for (const mode of LOSSLESS_MODES) {
      const d = mustDecode(encodeJpeg(src, { ...base, mode }));
      assert.equal(d.width, w);
      assert.equal(d.height, h);
      assert.equal(d.pixels.byteLength, w * h * 4, "输出必须是紧凑 RGBA8");
      const got = new Uint16Array(w * h);
      for (let i = 0; i < w * h; i++) got[i] = Math.round((d.pixels16![i * 4]! * 255) / 65535);
      assert.deepEqual([...got], [...src], `${mode} 在 ${w}×${h} 上不无损`);
    }

    // 有损：四种过程解出的像素必须一致（同系数 ⇒ 同重建）
    const canvas = new Map<JpegMode, Uint16Array>();
    for (const mode of LOSSY_MODES) {
      const d = mustDecode(encodeJpeg(src, { ...base, mode, quality: 90 }));
      assert.equal(d.width, w);
      assert.equal(d.height, h);
      canvas.set(mode, d.pixels16!);
    }
    const ref = canvas.get("baseline")!;
    for (const mode of LOSSY_MODES) {
      assert.equal(diffBytes(ref, canvas.get(mode)!), 0, `${mode} 与 baseline 不一致（${w}×${h}）`);
    }
  });
}

test("JPEG 鲁棒性：任意截断前缀都返回 Result，不抛异常、不返回尺寸不符的像素", () => {
  // ★ 判据是"不炸"而不是"能解"：截断文件本来就解不出完整图。
  //   真正的失败形态是**抛异常穿出 API**（调用方没接住就整帧崩）或
  //   返回 `pixels.length != w*h*4`（下游按行读就越界）。
  const samples: ReadonlyArray<readonly [string, Uint8Array]> = [
    ["baseline", encodeJpeg(hardGray(8), spec(1, 8, "baseline"))],
    ["arith", encodeJpeg(hardGray(8), spec(1, 8, "arith-sequential"))],
    ["lossless", encodeJpeg(hardGray(8), spec(1, 8, "lossless"))],
    ["progressive", encodeJpeg(smoothRgb(8), spec(3, 8, "progressive"))],
    ["hier", encodeJpeg(smoothGray(8), spec(1, 8, "hier-lossless"))],
  ];
  let checked = 0;
  for (const [name, bytes] of samples) {
    for (let k = 0; k <= bytes.length; k += 7) {
      const cut = bytes.subarray(0, k);
      let r: ReturnType<typeof decodeJpeg>;
      try {
        r = decodeJpeg(cut);
      } catch (e) {
        assert.fail(`${name} 截到 ${k}/${bytes.length} 字节时抛出了异常：${(e as Error).message}`);
      }
      if (r.ok) {
        const d = r.value;
        assert.equal(
          d.pixels.byteLength,
          d.width * d.height * 4,
          `${name} 截到 ${k} 字节时返回了尺寸不符的像素（${d.width}×${d.height}）`,
        );
        // k == 全长时它就是完整文件，报 truncated=false 才对；只有真截短才要求标记
        if (k < bytes.length) {
          assert.equal(d.jpeg.truncated, true, `${name} 截到 ${k} 字节还报"完整"，调用方会当真`);
        }
      }
      checked++;
    }
  }
  assert.ok(checked > 300, `只检查了 ${checked} 个前缀，步长/样本数不对`);
});

// ------------------------------------------------------------ ⑥ 12 位的采样与方向

test("JPEG 12 位 + 4:2:0：三种有损过程解出逐字节相同的像素（子采样路径也走 12 位数学）", () => {
  // ★ 为什么单独一条：12 位 × 4:2:0 是"上采样 + 12 位 IDCT + 逆电平位移"三层叠加，
  //   而固定用 4:4:4 的矩阵根本走不到色度上采样那一段。
  const src = smoothRgb(12);
  const out = new Map<JpegMode, Uint16Array>();
  for (const mode of ["baseline", "progressive", "arith-sequential"] as JpegMode[]) {
    const d = mustDecode(encodeJpeg(src, { ...spec(3, 12, mode), subsampling: "420" }));
    assert.equal(d.jpeg.subsampling, "4:2:0", "文件里必须真的是 4:2:0，否则这段判据没被走到");
    assert.equal(d.jpeg.precision, 12);
    out.set(mode, d.pixels16!);
  }
  const ref = out.get("baseline")!;
  for (const [mode, px] of out) {
    assert.equal(diffBytes(ref, px), 0, `${mode} 与 baseline 在 12 位 4:2:0 下不一致`);
  }
});

test("JPEG 12 位：EXIF Orientation=6 应用后尺寸互换，pixels16 也被旋转（不是只转 8 位视图）", () => {
  // ★ applyOrientation 是泛型（Uint8Array | Uint16Array），一旦有人只处理 8 位，
  //   症状是"8 位看着是正的、16 位是躺的" —— 而图集用哪个视图取决于调用方。
  const src = hardRgb(12);
  const plain = encodeJpeg(src, spec(3, 12, "baseline"));
  const withExif = insertApp1Orientation(plain, 6);

  const ignored = mustDecode(withExif);
  assert.equal(ignored.jpeg.orientation, 6, "EXIF 里的方向必须被解析出来");
  assert.equal(ignored.width, W, "默认 ignore：尺寸保持文件声明值");

  const applied = decodeJpeg(withExif, { keep16: true, orientation: "apply" });
  assert.ok(applied.ok, `apply 失败：${applied.ok ? "" : applied.error.message}`);
  const d = applied.value;
  assert.equal(d.width, H, "orientation 6 要交换宽高");
  assert.equal(d.height, W);
  const p16 = d.pixels16!;
  assert.equal(p16.length, W * H * 4, "旋转不该改变样本总数");

  // 顺时针 90°：dst(0,0) 来自 src(0, H-1)；逐点核对前 3 个通道
  const plainPx = mustDecode(plain).pixels16!;
  for (let c = 0; c < 3; c++) {
    const want = plainPx[((H - 1) * W + 0) * 4 + c]!;
    assert.equal(p16[0 * 4 + c], want, `通道 ${c}：旋转后左上角不等于原图左下角`);
  }
  // 8 位视图必须与 pixels16 同步（同一条派生关系）
  for (let i = 0; i < p16.length; i++) {
    assert.equal(d.pixels[i], Math.round(p16[i]! / 257), `样本 ${i}: 8 位视图没跟着旋转`);
  }
});

/**
 * EXIF 1..8 八种方向逐个核对。
 *
 * ★ 为什么以前只测了 6：其余 6 种（2/3/4/5/7/8）在代码里是三个 `ox/oy` 赋值的不同组合，
 *   写错一个符号出来的图只是"镜像方向反了"或"差一列"，肉眼几乎看不出来，
 *   而**像素层的容差判据也看不出来** —— 它们全都是"一张方向错的图"。
 *
 * ★ 为什么能逐样本精确核对：源图用**无损**过程（SOF3），且每个像素的 R/G 通道里写着
 *   自己的 (x, y) 坐标（W=40、H=24 都在 8 位范围内）。于是"输出像素 (x,y) 来自源图哪个
 *   坐标"是可以直接读出来的，不需要任何参考实现在场。
 */
test("JPEG EXIF：1..8 八种方向逐个核对（坐标索引图 + 无损，逐样本精确）", () => {
  const idx = new Uint16Array(W * H * 3);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 3;
      idx[o] = x; // R = 源 x
      idx[o + 1] = y; // G = 源 y
      idx[o + 2] = 0;
    }
  }
  const base = encodeJpeg(idx, spec(3, 8, "lossless"));

  // 源坐标 ← 输出坐标（EXIF 2.3 §4.6.4 的 8 种变换；注意 5..8 要交换宽高）
  const inverse = (o: number, x: number, y: number): readonly [number, number] => {
    switch (o) {
      case 1:
        return [x, y];
      case 2:
        return [W - 1 - x, y];
      case 3:
        return [W - 1 - x, H - 1 - y];
      case 4:
        return [x, H - 1 - y];
      case 5:
        return [y, x];
      case 6:
        return [y, H - 1 - x];
      case 7:
        return [W - 1 - y, H - 1 - x];
      default:
        return [W - 1 - y, x];
    }
  };

  for (let o = 1; o <= 8; o++) {
    const r = decodeJpeg(insertApp1Orientation(base, o), { orientation: "apply" });
    assert.ok(r.ok, `方向 ${o}：解码失败 ${r.ok ? "" : r.error.message}`);
    const d = r.value;
    assert.equal(d.jpeg.orientation, o, `方向 ${o} 必须被解析出来`);

    const swap = o >= 5;
    assert.equal(d.width, swap ? H : W, `方向 ${o} 的宽度`);
    assert.equal(d.height, swap ? W : H, `方向 ${o} 的高度`);
    assert.equal(d.pixels.length, d.width * d.height * 4, `方向 ${o} 的像素数`);

    let bad = 0;
    let firstBad = "";
    for (let y = 0; y < d.height; y++) {
      for (let x = 0; x < d.width; x++) {
        const [sx, sy] = inverse(o, x, y);
        const i = (y * d.width + x) * 4;
        if (d.pixels[i] !== sx || d.pixels[i + 1] !== sy) {
          if (bad === 0) {
            firstBad = `输出(${x},${y})=(${d.pixels[i]},${d.pixels[i + 1]}) 期望来自源(${sx},${sy})`;
          }
          bad++;
        }
      }
    }
    assert.equal(bad, 0, `方向 ${o}：${bad} 个像素位置不对，第一个是 ${firstBad}`);
  }
});

test("上采样：非 2 倍采样因子必须复制而不是插值（4:1:1 与 libjpeg 同族）", () => {
  // ★ 行覆盖率审计发现这条分支从未被执行过：我们自己只产 4:4:4 / 4:2:2 / 4:2:0，
  //   而 4:1:1（h=4）走的是 `axis()` 的第三条路。规范没规定，libjpeg 对非 2 倍因子
  //   是**复制**而非三角滤波；写成插值会让 4:1:1 的色度整体偏移，且只在那种文件上错。
  const plane = Uint16Array.from([10, 20, 30, 40]); // 宽 4
  const row: number[] = [];
  for (let x = 0; x < 16; x++) row.push(sampleComponent(plane, 4, 1, 4, 1, x, 0));
  assert.deepEqual(
    row,
    [10, 10, 10, 10, 20, 20, 20, 20, 30, 30, 30, 30, 40, 40, 40, 40],
    "factor=4 必须是复制（每个样本铺 4 份），不能是插值",
  );
  assert.equal(sampleComponent(plane, 4, 1, 4, 1, 99, 0), 40, "越界位置必须钳到最后一个样本");
  // 对照：factor=2 且样本数 >2 时走三角滤波（1/4、3/4 权重），两条路必须真的不同
  const p2 = Uint16Array.from([10, 20, 30, 40]);
  const r2: number[] = [];
  for (let x = 0; x < 8; x++) r2.push(sampleComponent(p2, 4, 1, 2, 1, x, 0));
  assert.deepEqual(
    r2,
    [10, 12.5, 17.5, 22.5, 27.5, 32.5, 37.5, 40],
    "factor=2 且样本 ≥3 必须是 1/4-3/4 三角插值",
  );
});

/**
 * 上采样：某一轴的样本数只有 1~2 个时，libjpeg 关掉 fancy、退回复制。
 *
 * ★ 这条是**大规模差分扫描抓出来的真缺陷**（tools/jpeg-diff-sweep.py + .mjs）：
 *   3×97 的 4:2:0 图在我们的解码器上整列差 40 级。原因是宽 3 的图色度只有 2 个样本，
 *   而 libjpeg 的 `jinit_upsampler` 只在 `downsampled_width > 2` 时才用 h2v1/h2v2_fancy，
 *   否则走 `h2v1_upsample`/`h2v2_upsample` —— 也就是**复制**。
 *   三角滤波在这种尺寸上会把最后一个色度样本和左邻混在一起，而复制原样铺开。
 *
 * ★ 第二条结论同样来自那次扫描，而且是"改错一次才看清"的：
 *   开关是**按分量**定的，不是按轴。h2v2 的条件只看宽——
 *   所以 97×3（宽 97、色度高 2）纵向仍然走三角。
 *   一开始两轴都按"样本 ≤2 就复制"处理，3×97 修好了，97×3 立刻从差 2 变成差 30。
 */
test("上采样：色度样本 ≤2 时退回复制（且开关按分量定，不按轴）", () => {
  // 宽 3 的 4:2:0：色度只有 2 个样本 → 横向复制 [c0, c0, c1]
  const narrow = Uint16Array.from([0, 100]);
  const row: number[] = [];
  for (let x = 0; x < 3; x++) row.push(sampleComponent(narrow, 2, 1, 2, 1, x, 0));
  assert.deepEqual(row, [0, 0, 100], "色度 2 个样本时必须是复制，不能是 0.75/0.25 三角");
  // 同样的 2 个样本，走 4:4:4（factor=1）时也必须是复制 —— 两条路在这一尺寸下重合
  assert.deepEqual(
    [0, 1].map((x) => sampleComponent(narrow, 2, 1, 1, 1, x, 0)),
    [0, 100],
    "factor=1 不该有任何插值",
  );

  // 4:2:0 且宽 4、高 2：横向 fancy（4 个色度样本），纵向**仍然 fancy**（h2v2 只看宽）
  const col = new Uint16Array(4 * 2); // 4 宽、2 行
  col.fill(0, 0, 4);
  col.fill(100, 4, 8);
  const v2: number[] = [];
  for (let y = 0; y < 4; y++) v2.push(sampleComponent(col, 4, 2, 2, 2, 0, y));
  assert.deepEqual(v2, [0, 25, 75, 100], "h2v2 的纵向在宽 >2 时必须仍是三角（97×3 的教训）");

  // 4:4:0（横向不扩、纵向扩 2 倍）走的是 h1v2，条件看**高**：高 2 → 复制
  const col2 = new Uint16Array(1 * 2);
  col2[0] = 0;
  col2[1] = 100;
  const v3: number[] = [];
  for (let y = 0; y < 4; y++) v3.push(sampleComponent(col2, 1, 2, 1, 2, 0, y));
  assert.deepEqual(v3, [0, 0, 100, 100], "h1v2 的条件只看高：高 2 时纵向必须复制");
});

/**
 * IDCT 的独立参照：按定义直接算二维变换，不做任何分解。
 *
 * ★ 为什么这条判据重要：**12 位 DCT 是唯一完全没有外部金标的路径**
 *   （Pillow 是 8 位构建，"四种有损过程跨模式逐字节一致"只证明四条路径互相一致，
 *   不证明它们都对）。这里补的参照是"教科书定义式"：
 *     s(x,y) = 1/4 · ΣΣ C(u)C(v)·F(u,v)·cos((2x+1)uπ/16)·cos((2y+1)vπ/16)
 *   它和解码器用的"分离式（先行一维、再列一维）"在**归一化、转置、电平位移**上
 *   完全独立 —— 少乘 1/4、行列写反、offset 写死 128 都会立刻对不上。
 */
test("IDCT：与教科书定义式逐样本一致（8 位 / 12 位 / 多块布局）", () => {
  const refIdct = (f: Float64Array, x: number, y: number): number => {
    let sum = 0;
    for (let v = 0; v < 8; v++) {
      for (let u = 0; u < 8; u++) {
        const cu = u === 0 ? Math.SQRT1_2 : 1;
        const cv = v === 0 ? Math.SQRT1_2 : 1;
        sum +=
          cu *
          cv *
          f[v * 8 + u]! *
          Math.cos(((2 * x + 1) * u * Math.PI) / 16) *
          Math.cos(((2 * y + 1) * v * Math.PI) / 16);
      }
    }
    return sum / 4;
  };

  // 确定性 PRNG：判据必须可复现，失败时能原样重跑
  let seed = 0x2545f491;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };

  for (const precision of [8, 12] as const) {
    const maxval = (1 << precision) - 1;
    const offset = 1 << (precision - 1);
    const blocksW = 3;
    const blocksH = 2;
    const coefs = new Int16Array(blocksW * blocksH * 64);
    for (let i = 0; i < coefs.length; i++) {
      // ±60 的随机系数：足以让高频项参与（而不是只有 DC），又不至于整块被钳死
      coefs[i] = Math.round((rnd() * 2 - 1) * 60);
    }
    const qt = new Uint16Array(64).fill(1); // 量化表全 1 ⇒ 反量化是恒等，便于对账
    const comp: Component = {
      id: 1,
      h: 1,
      v: 1,
      tq: 0,
      blocksW,
      blocksH,
      strideBlocksW: blocksW,
      strideBlocksH: blocksH,
      coefs,
      pred: 0,
      compW: blocksW * 8,
      compH: blocksH * 8,
      td: 0,
      ta: 0,
      plane: null,
      qtTable: null,
    };
    const plane = buildPlane(comp, qt, precision);
    assert.equal(plane.length, comp.compW * comp.compH, `${precision} 位：平面尺寸`);

    let maxDiff = 0;
    let exact = 0;
    for (let by = 0; by < blocksH; by++) {
      for (let bx = 0; bx < blocksW; bx++) {
        const f = new Float64Array(64);
        const bo = (by * blocksW + bx) * 64;
        for (let i = 0; i < 64; i++) f[i] = coefs[bo + i]!;
        for (let y = 0; y < 8; y++) {
          for (let x = 0; x < 8; x++) {
            const want = Math.min(maxval, Math.max(0, Math.round(refIdct(f, x, y) + offset)));
            const got = plane[(by * 8 + y) * comp.compW + bx * 8 + x]!;
            const d = Math.abs(got - want);
            if (d === 0) exact++;
            if (d > maxDiff) maxDiff = d;
            assert.ok(
              d <= 1,
              `${precision} 位块(${bx},${by}) 像素(${x},${y})：解码器 ${got}，定义式 ${want}`,
            );
          }
        }
      }
    }
    // 允许 1 的差来自"分离式两轮取整 vs 一次取整"的浮点末位；不允许更大
    assert.ok(maxDiff <= 1, `${precision} 位：最大偏差 ${maxDiff}`);
    const total = blocksW * blocksH * 64;
    assert.ok(
      exact / total > 0.98,
      `${precision} 位：只有 ${exact}/${total} 个样本完全相等 —— 偏差不像"浮点末位"`,
    );
    // ★ 反退化：如果这块全被钳到 0 或 maxval，上面所有断言都会因为"两边都钳死"而全绿。
    //   要求绝大多数样本落在开区间内，才算真的在比 IDCT 的数值。
    const inside = plane.reduce((n, v) => n + (v > 0 && v < maxval ? 1 : 0), 0);
    assert.ok(
      inside / total > 0.5,
      `${precision} 位：只有 ${inside}/${total} 个样本落在 (0, ${maxval}) 内 —— 判据可能在比"两边都钳死"`,
    );
  }
});

/**
 * 颜色变换：用"定义式"独立重算一遍，覆盖 8 位与 12 位。
 *
 * ★ 这里的诚实说明：它**不是**独立算法（同一组 BT.601 系数），所以它不守系数本身
 *   —— 系数由 8 位的 libjpeg 金标守。它守的是**这条路径上真正容易错的三件事**：
 *     ① 偏移量必须是 2^(P-1)：12 位套 128 会把色度整体拧掉；
 *     ② 4 分量 YCCK 要先转回"墨量"再反相一次（少一次 = 白变黑，且不报错）；
 *     ③ 钳位与取整发生在**乘完之后**，以及 RGBA 输出与 `pixels16` 的派生关系。
 *   12 位**没有任何外部金标**，所以这三件事只能靠"定义式 + 不变量"来钉。
 */
test("颜色变换：YCbCr / CMYK / YCCK 与定义式一致（8 位与 12 位）", () => {
  const mkComp = (id: number, plane: Uint16Array, w: number, h: number): Component => ({
    id,
    h: 1,
    v: 1,
    tq: 0,
    blocksW: Math.ceil(w / 8),
    blocksH: Math.ceil(h / 8),
    strideBlocksW: Math.ceil(w / 8),
    strideBlocksH: Math.ceil(h / 8),
    coefs: new Int16Array(0),
    pred: 0,
    compW: w,
    compH: h,
    td: 0,
    ta: 0,
    plane,
    qtTable: null,
  });

  const mkFrame = (
    precision: number,
    planes: Uint16Array[],
    w: number,
    h: number,
    adobeTransform: number | null,
  ): Frame => ({
    index: 0,
    sof: planes.length === 1 ? 0xc0 : 0xc0,
    precision,
    width: w,
    height: h,
    progressive: false,
    lossless: false,
    arithmetic: false,
    differential: false,
    components: planes.map((pl, i) => mkComp(i + 1, pl, w, h)),
    qt: [],
    dcTables: [],
    acTables: [],
    dcCond: [],
    acCond: [],
    restartInterval: 0,
    scanCount: 1,
    pt: 0,
    expansions: new Map(),
    expandH: 1,
    expandV: 1,
    adobeTransform,
  });

  for (const precision of [8, 12] as const) {
    const maxval = (1 << precision) - 1;
    const offset = 1 << (precision - 1);
    const w = 2;
    const h = 2;
    const n = w * h;
    /** 定义式：BT.601 全范围 YCbCr → RGB（输入是"存储值"，含 2^(P-1) 偏移） */
    const ycc = (s0: number, s1: number, s2: number): readonly [number, number, number] => {
      const cb = s1 - offset;
      const cr = s2 - offset;
      return [s0 + 1.402 * cr, s0 - 0.344136 * cb - 0.714136 * cr, s0 + 1.772 * cb];
    };
    const q = (v: number): number => Math.min(maxval, Math.max(0, Math.round(v)));
    const full = (v: number): number =>
      precision === 8 ? v * 257 : Math.round((v * 65535) / maxval);

    // ---------------- ① 3 分量 YCbCr：中性灰 / 偏红 / 偏蓝 / 高饱和
    const Y = Uint16Array.from([offset, q(maxval * 0.5), q(maxval * 0.4), q(maxval * 0.9)]);
    const Cb = Uint16Array.from([offset, q(maxval * 0.35), q(maxval * 0.8), q(maxval * 0.1)]);
    const Cr = Uint16Array.from([offset, q(maxval * 0.85), q(maxval * 0.2), q(maxval * 0.95)]);
    const rgb = planesToRgba(mkFrame(precision, [Y, Cb, Cr], w, h, null), { keep16: true });
    const rgb16 = rgb.pixels16!;
    for (let i = 0; i < n; i++) {
      const [r, g, b] = ycc(Y[i]!, Cb[i]!, Cr[i]!);
      const want = [q(r), q(g), q(b)];
      const got = [rgb16[i * 4]! / (65535 / maxval), rgb16[i * 4 + 1]! / (65535 / maxval), rgb16[i * 4 + 2]! / (65535 / maxval)];
      for (let c = 0; c < 3; c++) {
        assert.ok(
          Math.abs(got[c]! - want[c]!) <= 1,
          `${precision} 位 YCbCr 样本 ${i} 通道 ${c}：解码器 ${got[c]!.toFixed(2)}，定义式 ${want[c]}`,
        );
      }
      assert.equal(rgb16[i * 4 + 3], 65535, "alpha 恒不透明");
      // 不变量：8 位视图必须由 pixels16 派生
      for (let c = 0; c < 4; c++) {
        assert.equal(rgb.pixels[i * 4 + c], Math.round(rgb16[i * 4 + c]! / 257), "8 位视图没跟着 16 位走");
      }
    }
    // 中性灰必须严格等于 offset：Y=Cb=Cr=offset ⇒ R=G=B（任何偏移量错都会破坏它）
    assert.equal(rgb16[0], full(offset), `${precision} 位：中性灰的 R 必须等于 2^(P-1)`);
    assert.equal(rgb16[1], full(offset), `${precision} 位：中性灰的 G`);
    assert.equal(rgb16[2], full(offset), `${precision} 位：中性灰的 B`);

    // ---------------- ② 4 分量 CMYK（transform=0）：反相 CMY × 反相 K / maxval
    const C0 = Uint16Array.from([q(maxval * 0.9), q(maxval * 0.2), q(maxval * 0.5), 0]);
    const C1 = Uint16Array.from([q(maxval * 0.8), q(maxval * 0.3), q(maxval * 0.5), q(maxval * 0.6)]);
    const C2 = Uint16Array.from([q(maxval * 0.7), q(maxval * 0.4), q(maxval * 0.5), q(maxval * 0.3)]);
    const K = Uint16Array.from([maxval, q(maxval * 0.5), 0, q(maxval * 0.75)]);
    const cmyk = planesToRgba(mkFrame(precision, [C0, C1, C2, K], w, h, 0), { keep16: true });
    const cmyk16 = cmyk.pixels16!;
    for (let i = 0; i < n; i++) {
      const want = [q((C0[i]! * K[i]!) / maxval), q((C1[i]! * K[i]!) / maxval), q((C2[i]! * K[i]!) / maxval)];
      for (let c = 0; c < 3; c++) {
        const got = cmyk16[i * 4 + c]! / (65535 / maxval);
        assert.ok(
          Math.abs(got - want[c]!) <= 1,
          `${precision} 位 CMYK 样本 ${i} 通道 ${c}：解码器 ${got.toFixed(2)}，定义式 ${want[c]}`,
        );
      }
    }

    // ---------------- ③ 4 分量 YCCK（transform=2）：YCbCr 编码的是**墨量**，要再反相一次
    const ycck = planesToRgba(mkFrame(precision, [Y, Cb, Cr, K], w, h, 2), { keep16: true });
    const ycck16 = ycck.pixels16!;
    for (let i = 0; i < n; i++) {
      const ink = ycc(Y[i]!, Cb[i]!, Cr[i]!);
      const want = [0, 1, 2].map((c) => q((((maxval - ink[c]!) * K[i]!) / maxval)));
      for (let c = 0; c < 3; c++) {
        const got = ycck16[i * 4 + c]! / (65535 / maxval);
        assert.ok(
          Math.abs(got - want[c]!) <= 1,
          `${precision} 位 YCCK 样本 ${i} 通道 ${c}：解码器 ${got.toFixed(2)}，定义式 ${want[c]}` +
            "（少一次反相会让白变黑，且不报错）",
        );
      }
    }
    // YCCK 与 CMYK 在"同一份墨量"下必须解出不同的图 —— 否则上面那条判据可能两边都反相
    assert.notDeepEqual(
      Array.from(ycck16.slice(0, 8)),
      Array.from(cmyk16.slice(0, 8)),
      `${precision} 位：YCCK 与 CMYK 用同一批平面值时不该解出同一张图`,
    );
  }
});

// ------------------------------------------------------------ ⑦ Pt 点变换 / 重启标记
test("JPEG 无损的点变换 Pt：解出的样本必须精确等于 (源 >> Pt) << Pt", () => {
  // ★ Pt（SOS 里的 Al）在无损过程里是**源样本右移**：低 Pt 位被丢掉，这是规范允许的唯一损失。
  //   没人测过的风险：解码端忘了左移回去，或预测器初值用错量程（`2^(P-Pt-1)`）——
  //   两种错都只表现为"整体偏暗"，肉眼看像曝光问题。
  const src = hardGray(8);
  // ★ Pt 走满 0..7（8 位样本的合法上界是 P-1=7）：只测 0..3 时，
  //   "预测器初值 = 2^(P-Pt-1)"这条公式在 Pt≥4 时算出的数（2^0 .. 2^-1 附近）
  //   从没被验证过，而它正好是唯一会因 Pt 变化而改变的量。
  for (const pt of [0, 1, 2, 3, 4, 5, 6, 7]) {
    for (const mode of LOSSLESS_MODES) {
      const d = mustDecode(encodeJpeg(src, { ...spec(1, 8, mode), pointTransform: pt }));
      assert.equal(d.jpeg.pointTransform, pt, "Pt 必须如实上报，否则调用方无从判断精度损失");
      const got = backToNative(d, 1, 8);
      for (let i = 0; i < src.length; i++) {
        const want = (src[i]! >>> pt) << pt;
        if (got[i] !== want) {
          assert.fail(`Pt=${pt}（${mode}）样本 ${i}: 解出 ${got[i]}，期望 ${want}（源 ${src[i]}）`);
        }
      }
    }
  }
  // 12 位再走一趟深 Pt：P 变了，"右移多少才合法"也跟着变（Pt<P=12）。
  const src12 = hardGray(12);
  for (const pt of [8, 10, 11]) {
    const d = mustDecode(encodeJpeg(src12, { ...spec(1, 12, "lossless"), pointTransform: pt }));
    const got = backToNative(d, 1, 12);
    for (let i = 0; i < src12.length; i++) {
      const want = (src12[i]! >>> pt) << pt;
      if (got[i] !== want) {
        assert.fail(`12 位 Pt=${pt} 样本 ${i}: 解出 ${got[i]}，期望 ${want}（源 ${src12[i]}）`);
      }
    }
  }
});

test("JPEG 分层 + 重启：DRI 对两帧都生效（无损仍逐样本相等、有损仍跨模式一致）", () => {
  // ★ DRI 是**文件级**状态，一旦出现就对后面所有扫描生效。分层文件有两帧，
  //   而第二帧是差分帧（每帧的预测器各自从区间头重来），所以"只在第一帧生效"或
  //   "每帧重发 DRI"都会让第二帧解错 —— 但错得很像量化误差，容差判据看不出来。
  //   无损分层因此是唯一能把它照出来的形式：任何一点错位都不再 max=0。
  //
  // ★ 区间长度必须同时是两帧行宽的整数倍：帧0 是 1/2 分辨率（W/2 个样本一行），
  //   帧1 是 W。取 W 就同时满足（W 是 W/2 的整数倍），这也是 libjpeg 那条
  //   `JERR_BAD_RESTART` 的同一条件。
  const gray = hardGray(8);
  for (const mode of ["hier-lossless", "hier-arith-lossless"] as JpegMode[]) {
    const d = mustDecode(encodeJpeg(gray, { ...spec(1, 8, mode), restart: W }));
    assert.equal(d.jpeg.restartInterval, W, "DRI 声明的区间长度要报出来");
    assert.equal(d.jpeg.frames, 2);
    assert.equal(diffStat(gray, backToNative(d, 1, 8)).max, 0, `${mode} 带重启后不再无损`);
  }

  // 有损分层：带不带重启必须解出同一份像素（重启只影响码流组织，不影响系数）
  const rgb = smoothRgb(8);
  const withRst = mustDecode(encodeJpeg(rgb, { ...spec(3, 8, "hier-sequential"), restart: 4 }));
  const without = mustDecode(encodeJpeg(rgb, spec(3, 8, "hier-sequential")));
  assert.equal(withRst.jpeg.restartInterval, 4);
  assert.equal(diffBytes(withRst.pixels16!, without.pixels16!), 0, "重启只该改变码流，不该改变重建");
});

test("JPEG 分层：帧间重定义 DQT 后，第二帧必须用新表（表在 SOS 时绑定，不是解析时）", () => {
  // ★ 这条盯的是"表的生命周期"：DQT 是文件级可重定义的，帧对象持有的是**数组引用**。
  //   如果重建时再查 `frame.qt`（而不是在 SOS 时绑定的 `c.qtTable`），
  //   先解的帧会用上后定义的量化表 —— 而且不报错，只是画面变了。
  //   判据：同一份差分样本，把帧1 的量化表换成"全 1"（等于不量化）后，
  //   重建结果必须**变**（说明新表被用上了），而帧0 的结果不受影响。
  const src = smoothGray(8);
  const base = encodeJpeg(src, spec(1, 8, "hier-sequential"));
  // tq 必须选**分量实际引用的那张**（我们的编码器里分量 0 用 tq=0），
  // 换一张没人引用的表当然不起作用 —— 第一次写这条时就是拿 1 试的，得到"无变化"的假阴性。
  const coarser = reinsertDqtForFrame1(base, 0);
  assert.ok(coarser !== null, "找不到帧1 的量化表——用例前提不成立");
  const a = mustDecode(base);
  const b = mustDecode(coarser);

  assert.equal(a.jpeg.frames, 2);
  assert.equal(b.jpeg.frames, 2);
  assert.notEqual(diffBytes(a.pixels16!, b.pixels16!), 0, "换了第二帧的量化表却解出同一份像素 —— 新表没被用上");

  // ★ 反过来的那一半同样必要：把同一张表插到 EOI 之前（所有 SOS 都过了），
  //   像素必须**一点不变**。没有这条，"在重建时现查 frame.qt"这种实现也能让上面那条变绿 ——
  //   因为它一样会让像素变，只是变的原因错了（连第一帧都被改）。
  const late = mustDecode(appendDqtBeforeEoi(base, 0));
  assert.equal(diffBytes(a.pixels16!, late.pixels16!), 0, "表插在所有扫描之后还影响了像素 —— 说明绑定发生在重建时，而不是 SOS 时");
});

test("JPEG 重启标记：四种过程都按区间复位（无损仍逐样本相等、有损仍跨模式一致）", () => {
  // DRI 的语义是"每 N 个 MCU 重置预测器/统计区"。写错的话图仍然像样，
  // 只是每个区间头一个块偏一截 —— 只有"无损必须 max=0"和"跨模式必须逐字节相同"抓得住。
  const gray = hardGray(8);
  for (const mode of LOSSLESS_MODES) {
    const d = mustDecode(encodeJpeg(gray, { ...spec(1, 8, mode), restart: W }));
    assert.equal(d.jpeg.restartInterval, W, "DRI 声明的区间长度要报出来");
    const st = diffStat(gray, backToNative(d, 1, 8));
    assert.equal(st.max, 0, `${mode} 带重启后不再无损（max=${st.max}）`);
  }

  const rgb = smoothRgb(8);
  const base = mustDecode(encodeJpeg(rgb, { ...spec(3, 8, "baseline"), restart: 4 }));
  const arith = mustDecode(encodeJpeg(rgb, { ...spec(3, 8, "arith-sequential"), restart: 4 }));
  assert.equal(base.jpeg.restartInterval, 4);
  assert.equal(diffBytes(base.pixels16!, arith.pixels16!), 0, "带重启的算术流与哈夫曼流必须解出同一份像素");
});

// ------------------------------------------------------------ ⑦ 算术 × 分层（SOF13/15）

for (const precision of [8, 12] as const) {
  for (const components of [1, 3] as const) {
    const label = components === 1 ? "gray" : "rgb";
    test(`JPEG 分层 + 算术无损 ${precision}bit/${label}（SOF11 + SOF15）：逐样本相等`, () => {
      // ★ 这两个 SOF 之前**一条用例都没有**：分层只测了 Huffman 的 SOF5/SOF7。
      //   "13 个 SOF 全实现"里若有三条从没跑过，那句话就只是注释。
      const src = components === 1 ? hardGray(precision) : hardRgb(precision);
      const d = mustDecode(encodeJpeg(src, spec(components, precision, "hier-arith-lossless")));
      assert.equal(d.jpeg.sof, 0xcf, "最后一帧必须是 SOF15（算术差分无损）");
      assert.equal(d.jpeg.arithmetic, true);
      assert.equal(d.jpeg.lossless, true);
      assert.equal(d.jpeg.differential, true);
      assert.equal(d.jpeg.frames, 2);
      const st = diffStat(src, backToNative(d, components, precision));
      assert.equal(st.max, 0, `算术分层无损差 ${st.max} —— 第二帧的统计区没从初始状态开始？`);
    });

    test(`JPEG 分层 + 算术有损 ${precision}bit/${label}（SOF9 + SOF13）：质量与基线同量级`, () => {
      const src = components === 1 ? smoothGray(precision) : smoothRgb(precision);
      const hier = mustDecode(encodeJpeg(src, spec(components, precision, "hier-arith-sequential")));
      const base = mustDecode(encodeJpeg(src, spec(components, precision, "baseline")));
      assert.equal(hier.jpeg.sof, 0xcd, "最后一帧必须是 SOF13（算术差分顺序）");
      assert.equal(hier.jpeg.arithmetic, true);
      assert.equal(hier.jpeg.differential, true);

      const stHier = diffStat(src, backToNative(hier, components, precision));
      const stBase = diffStat(src, backToNative(base, components, precision));
      const limit = stBase.max * 2 + 2;
      assert.ok(stHier.max <= limit, `算术分层有损 max=${stHier.max} 超过 ${limit}（基线 ${stBase.max}）`);
    });
  }
}

// ------------------------------------------------------------ ⑦-b 分层的渐进变体（SOF6 / SOF14）

/**
 * 分层的四种有损过程：帧0 完全相同（顺序 SOF0/1/9 + SOF0/1/9 之外的差异在帧1），
 * 帧1 走同一个 `fillCoefficients`，所以**无论帧1 用哪种扫描组织方式，解出的像素必须逐字节相同**。
 */
const HIER_LOSSY_MODES: readonly JpegMode[] = [
  "hier-sequential",
  "hier-progressive",
  "hier-arith-sequential",
  "hier-arith-progressive",
];

for (const precision of [8, 12] as const) {
  for (const components of [1, 3] as const) {
    const label = components === 1 ? "gray" : "rgb";

    test(`JPEG 分层有损四变体 ${precision}bit/${label}：逐字节相同（SOF5/6/13/14 是同一个重建）`, () => {
      // ★ 为什么这条比"质量与基线同量级"更硬：分层有损的过程差异只在**第二帧的扫描组织**，
      //   系数完全一样，所以解码结果必须一位不差。用容差比较等于允许扫描组织影响重建，
      //   而那只可能是编码端把系数写错了（例：渐进的首扫 Al 与精修 Al 不配对）。
      const src = components === 1 ? smoothGray(precision) : smoothRgb(precision);
      const canvas = new Map<JpegMode, Uint16Array>();
      for (const mode of HIER_LOSSY_MODES) {
        const d = mustDecode(encodeJpeg(src, { ...spec(components, precision, mode), quality: 90 }));
        assert.equal(d.jpeg.frames, 2, `${mode} 必须是两帧`);
        assert.equal(d.jpeg.differential, true, `${mode} 第二帧必须是差分帧`);
        canvas.set(mode, d.pixels16!);
      }
      const ref = canvas.get("hier-sequential")!;
      for (const mode of HIER_LOSSY_MODES) {
        assert.equal(
          diffBytes(ref, canvas.get(mode)!),
          0,
          `${mode} 与 hier-sequential 不一致 —— 同一批系数解出了两份像素`,
        );
      }
    });

    test(`JPEG 分层渐进 ${precision}bit/${label}：帧1 用 SOF6/SOF14 且标记为渐进`, () => {
      // ★ SOF6 / SOF14 在这条用例之前**零覆盖**（ADR-0009 ⑥-b 里挂着"未验证分支"）。
      //   只断言"能解"不够：若编码端悄悄退回顺序式，SOF 号仍是 0xC6/0xCE 但扫描只有一趟，
      //   所以还要断言 `progressive === true` 且像素与顺序变体相同（上一条已经覆盖后者）。
      const src = components === 1 ? smoothGray(precision) : smoothRgb(precision);

      const hp = mustDecode(encodeJpeg(src, { ...spec(components, precision, "hier-progressive"), quality: 90 }));
      assert.equal(hp.jpeg.sof, 0xc6, "hier-progressive 的最后一帧必须是 SOF6（差分的渐进哈夫曼）");
      assert.equal(hp.jpeg.progressive, true);
      assert.equal(hp.jpeg.differential, true);
      assert.equal(hp.jpeg.arithmetic, false);

      const hap = mustDecode(
        encodeJpeg(src, { ...spec(components, precision, "hier-arith-progressive"), quality: 90 }),
      );
      assert.equal(hap.jpeg.sof, 0xce, "hier-arith-progressive 的最后一帧必须是 SOF14");
      assert.equal(hap.jpeg.progressive, true);
      assert.equal(hap.jpeg.differential, true);
      assert.equal(hap.jpeg.arithmetic, true);

      // 首个帧头（参考帧）仍是顺序式：SOF6/SOF14 只描述差分帧，
      // 断言它不被打成渐进，否则"两帧各自的过程"这件事就没被验证。
      const bytes = encodeJpeg(src, { ...spec(components, precision, "hier-progressive"), quality: 90 });
      const at0 = findSeg(bytes, 0xc1) >= 0 ? findSeg(bytes, 0xc1) : findSeg(bytes, 0xc0);
      const at1 = findSeg(bytes, 0xc6);
      assert.ok(at0 >= 0 && at1 > at0, `帧0 应是 SOF0/SOF1 且在 SOF6 之前（0x${at0.toString(16)} / 0x${at1.toString(16)}）`);
    });
  }
}

// ------------------------------------------------------------ ⑧ 4 分量（CMYK / YCCK）

/**
 * 反相 CMYK 样本：`C' = maxval - C`。K' 必须在 0..maxval 中间变化，
 * 否则 `RGB = C' × K' / maxval` 里的乘法整段退化成直通。
 */
function cmykSample(precision: 8 | 12): Uint16Array {
  const maxv = (1 << precision) - 1;
  const a = new Uint16Array(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 4;
      a[o] = Math.round((0.7 + 0.25 * Math.sin(x * 0.2)) * maxv);
      a[o + 1] = Math.round((0.6 + 0.3 * Math.cos(y * 0.15)) * maxv);
      a[o + 2] = Math.round(((x + y) / (W + H)) * maxv);
      a[o + 3] = Math.round((0.5 + 0.4 * Math.sin((x + y) * 0.13)) * maxv);
    }
  }
  return a;
}

/** 4 分量解码出的 RGB 与"反相 CMYK 合成的 RGB"逐样本比较。 */
function cmykStat(src: Uint16Array, px16: Uint16Array, precision: 8 | 12): { max: number; mean: number } {
  const maxv = (1 << precision) - 1;
  let max = 0;
  let sum = 0;
  const n = W * H;
  for (let i = 0; i < n; i++) {
    const k = src[i * 4 + 3]!;
    for (let c = 0; c < 3; c++) {
      const want = Math.round((src[i * 4 + c]! * k) / maxv);
      const got = Math.round((px16[i * 4 + c]! * maxv) / 65535);
      const d = Math.abs(got - want);
      if (d > max) max = d;
      sum += d;
    }
  }
  return { max, mean: sum / (n * 3) };
}

test("JPEG 4 分量：重编码后 RGB 仍是 (反相 CMY × K)，四种过程逐字节相同", () => {
  // ★ 4 分量是解码器里独立的一支（`n === 4`）：先按 CMYK 反相合成，YCCK 还要再反相一次。
  //   这里比的是"我们编码 → 我们解码"的一致性，外部金标在
  //   `tests/fixtures/jpeg/` 的 cmyk-*/ycck-* 四张（金标 = libjpeg 解同一个文件）。
  // ★ 跨模式一致这条在 4 分量上同样硬：四种过程系数相同 ⇒ 重建必须相同。
  for (const precision of [8, 12] as const) {
    const src = cmykSample(precision);
    // ★ 只在**同一个 transform** 内比：t2（YCCK）先把反相 CMY 转成 YCbCr，
    //   那一步本身有取整，系数与 t0 不同 —— 跨 transform 比像素是把两种量化混为一谈。
    for (const t of [0, 2] as const) {
      const canvas = new Map<JpegMode, Uint16Array>();
      for (const mode of ["baseline", "progressive", "arith-sequential", "arith-progressive"] as JpegMode[]) {
        const d = mustDecode(
          encodeJpeg(src, {
            width: W,
            height: H,
            components: 4,
            precision,
            mode,
            quality: 92,
            adobeTransform: t,
          }),
        );
        assert.equal(d.jpeg.adobeTransform, t, `${mode}/t${t} 的 APP14 transform 必须被解析出来`);
        canvas.set(mode, d.pixels16!);
      }
      const ref = canvas.get("baseline")!;
      for (const [mode, px] of canvas) {
        assert.equal(diffBytes(ref, px), 0, `${precision} 位 t${t} ${mode} 与 baseline 不一致（同系数必须同重建）`);
      }
      // 交叉核对"和源图接近"：只有逐模式一致还不够，整批一起错也会一致。
      const st = cmykStat(src, ref, precision);
      assert.ok(
        st.max <= (precision === 8 ? 8 : 24),
        `4 分量 ${precision} 位 t${t} 与源图差 ${st.max}（均值 ${st.mean.toFixed(2)}）`,
      );
    }
  }
});

test("JPEG 4 分量无损：SOF3/SOF11 逐样本相等，K 通道不被丢弃", () => {
  // 无损 4 分量必须**逐位**还原，K' 也是样本的一部分：
  // 少写第四个分量、或把它当索引丢弃，症状是"图看着对，但 K 全 0"（整幅提亮）。
  const src = cmykSample(8);
  for (const mode of ["lossless", "arith-lossless"] as JpegMode[]) {
    const d = mustDecode(encodeJpeg(src, { width: W, height: H, components: 4, precision: 8, mode }));
    const st = cmykStat(src, d.pixels16!, 8);
    assert.equal(st.max, 0, `${mode} 4 分量不无损（max=${st.max}）`);
  }
  // 分层无损：帧0 也是 4 分量，DHP 的 Nf 必须是 4
  const hier = mustDecode(
    encodeJpeg(src, { width: W, height: H, components: 4, precision: 8, mode: "hier-lossless", adobeTransform: 0 }),
  );
  assert.equal(hier.jpeg.frames, 2);
  assert.equal(cmykStat(src, hier.pixels16!, 8).max, 0, "4 分量分层无损不无损");
});

test("JPEG 4 分量：K=0 时整幅为黑、K=maxval 时等于三个色平面（乘法路径的两端）", () => {
  // ★ 端点是"公式写错"最容易被抓的地方，也是最容易被误判的地方：
  //   K'=0 → RGB 恒 0（不是"没影响"）；K'=maxval → RGB 等于 C'/M'/Y' 本身。
  for (const precision of [8, 12] as const) {
    const maxv = (1 << precision) - 1;
    const src = new Uint16Array(W * H * 4);
    for (let i = 0; i < W * H; i++) {
      src[i * 4] = Math.round((i % 201) / 200 * maxv);
      src[i * 4 + 1] = Math.round(((i * 7) % 199) / 198 * maxv);
      src[i * 4 + 2] = Math.round(((i * 13) % 197) / 196 * maxv);
      // 左半 K'=0（全黑），右半 K'=maxval（直通）
      src[i * 4 + 3] = (i % W) < W / 2 ? 0 : maxv;
    }
    const d = mustDecode(
      encodeJpeg(src, { width: W, height: H, components: 4, precision, mode: "baseline", quality: 100, adobeTransform: 0 }),
    );
    let black = 0;
    for (let i = 0; i < W * H; i++) {
      if ((i % W) >= W / 2) continue;
      for (let c = 0; c < 3; c++) if (d.pixels16![i * 4 + c]! !== 0) black++;
    }
    assert.ok(black <= W * H * 3 * 0.02, `K=0 的半幅应当全黑，实际有 ${black} 个通道不为 0`);
    const st = cmykStat(src, d.pixels16!, precision);
    assert.ok(st.max <= (precision === 8 ? 6 : 20), `4 分量端点用例 max=${st.max}`);
  }
});

// ------------------------------------------------------------ ⑨ 拒绝路径（结构校验逐条点名）

/**
 * 这一节是"审计出来的"，不是"想到哪写到哪"：
 * `tools/audit-error-paths.py` 给 `fail()` 插埋点跑全量判据，发现 94 条拒绝理由里
 * 只有不到三分之一真的被执行过 —— 其余 60 多条从写下那天起就没有任何输入能让它跑起来。
 * 一条永远不会执行的检查，和没写过的检查在事故里没有区别（它给人"我检查过了"的错觉）。
 * 下面每条用例的目标：**让那段代码真的跑一遍**，并断言它点出的原因能被调用方读到。
 */
test("JPEG 拒绝：段结构（长度非法 / 越界 / 段体不足）", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const sof = findSeg(base, 0xc0);
  assert.ok(sof > 0, "smooth 灰度应当是 SOF0");

  // 段长 1（规范要求 ≥ 2）
  mustReject(patchU16(base, sof + 2, 1), /长度非法/, "段长为 1 必须拒绝");
  // 段长指到文件外
  mustReject(patchU16(base, sof + 2, 0xffff), /声明 \d+ 字节数据，但文件只剩/, "段长越界必须拒绝");
  // 段长比内容短（6 + Nf*3 = 9 才够一个分量）
  mustReject(patchU16(base, sof + 2, 5), /SOF 段长度不足/, "SOF 段长不足必须拒绝");
});

test("JPEG 拒绝：SOF 字段（宽高为 0 / 分量数不支持 / 采样因子非法 / 量化表未定义）", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const sof = findSeg(base, 0xc0);

  // 负载：[precision, H_hi, H_lo, W_hi, W_lo, Nf, ...] —— 高宽各两字节，改一个字节不够
  mustReject(patchU16(base, sof + 4 + 1, 0), /宽高必须非 0/, "高度 0（DNL 写法）明确不支持");
  mustReject(patchU16(base, sof + 4 + 3, 0), /宽高必须非 0/, "宽度 0 同样拒绝");

  const rgb = encodeJpeg(smoothRgb(8), spec(3, 8, "baseline"));
  const sofRgb = findSeg(rgb, 0xc0);
  mustReject(patchPayload(rgb, sofRgb, 5, 2), /不支持 2 个分量的 JPEG/, "2 分量不支持");
  mustReject(patchPayload(rgb, sofRgb, 5, 5), /不支持 5 个分量的 JPEG/, "5 分量不支持");
  // 分量 0 的 HV 字节设成 0×1
  // HV 字节整字节为 0 ⇒ 0×0；规范要求两个因子都在 1..4
  mustReject(patchPayload(rgb, sofRgb, 7, 0x00), /采样因子 0×0 非法/, "采样因子 0 必须拒绝");
  // 分量 1 引用 tq=3（文件里没有这张表）
  mustReject(patchPayload(rgb, sofRgb, 11, 0x03), /引用的量化表 3 没有在文件里定义/, "引用未定义的量化表必须拒绝");
});

test("JPEG 拒绝：DQT / DHT 段体（表号越界、表类型非法、计数与符号数不符）", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const dqt = findSeg(base, 0xdb);
  mustReject(patchPayload(base, dqt, 0, 0x05), /DQT 表号 5 非法/, "DQT 表号 5 非法");

  const dht = findSeg(base, 0xc4);
  // 表信息字节：Tb = tc<<4 | th
  mustReject(patchPayload(base, dht, 0, 0x20), /DHT 表类型 2 非法/, "DHT 表类型 2 非法");
  mustReject(patchPayload(base, dht, 0, 0x05), /DHT 表号 5 非法/, "DHT 表号 5 非法");
  // 把 counts[0] 从 0 改成 5：声明了 5 个 1 位码字，但符号数没变 —— 表自相矛盾
  mustReject(patchPayload(base, dht, 1, 5), /DHT 表自相矛盾|DHT 段被截断/, "DHT 计数与符号数不符");
});

test("JPEG 拒绝：没有 SOS / SOS 段体非法 / 重启区间数不符", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const sos = findSeg(base, 0xda);
  assert.ok(sos > 0, "应当有 SOS");

  // 截到 SOI 之后：连帧头都没有
  mustReject(base.slice(0, 2), /没有找到 SOF 帧头/, "只有 SOI 必须拒绝");
  // 截到 SOS 之前：有帧头、但一帧都没扫描过
  mustReject(base.slice(0, sos), /没有任何扫描/, "缺少 SOS 必须拒绝");

  // SOS 的 Ns 改成 0 / 5
  mustReject(patchPayload(base, sos, 0, 0), /SOS 声明了 0 个分量/, "SOS 分量数 0 非法");
  mustReject(patchPayload(base, sos, 0, 5), /SOS 声明了 5 个分量/, "SOS 分量数 5 非法");

  // 重启区间数不符：把 DRI 声明的区间改小一档，熵数据里的 RST 数量就对不上了
  const rst = encodeJpeg(smoothGray(8), { ...spec(1, 8, "baseline"), restart: 4 });
  const dri = findSeg(rst, 0xdd);
  assert.ok(dri > 0, "带 restart 的文件必须有 DRI");
  mustReject(patchU16(rst, dri + 4, 64), /重启区间数不符/, "DRI 与实际 RST 数量不符必须拒绝");
});

test("JPEG 拒绝：扫描参数（无损的 Se/Ah/Pt、顺序式的 Ss/Se、渐进的 Ah/Al 关系）", () => {
  const lossless = encodeJpeg(hardGray(8), spec(1, 8, "lossless"));
  const sosL = findSeg(lossless, 0xda);
  // SOS 负载：[Ns, (Cs,Td/Ta)*, Ss, Se, Ah/Al]
  mustReject(patchPayload(lossless, sosL, 1 + 2, 0), /无损扫描的预测器选择值必须是 1..7/, "无损 Ss=0 非法");
  mustReject(patchPayload(lossless, sosL, 1 + 2, 8), /无损扫描的预测器选择值必须是 1..7/, "无损 Ss=8 非法");
  mustReject(patchPayload(lossless, sosL, 2 + 2, 5), /无损扫描的 Se 必须是 0/, "无损 Se≠0 非法");

  const seq = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const sosS = findSeg(seq, 0xda);
  mustReject(patchPayload(seq, sosS, 2 + 2, 10), /顺序式扫描的 Ss\/Se 必须是 0\/63/, "顺序式 Se≠63 非法");

  const prog = encodeJpeg(smoothGray(8), spec(1, 8, "progressive"));
  // 第一个渐进扫描是 DC 首扫（Ss=0 Se=0 Ah=0 Al=1）：把 Ah 改成 3，破坏 Ah=Al+1
  const sosP = findSeg(prog, 0xda);
  mustReject(patchPayload(prog, sosP, 3 + 2, 0x31), /渐进式逼近参数不连续/, "Ah=3 Al=1 非法");
  mustReject(patchPayload(prog, sosP, 3 + 2, 0xee), /渐进式逐次逼近位数非法/, "Al=14 非法");
});

test("JPEG 拒绝：分层序列（DHP 位置/分量表选择器、EXP 形状与放大因子）", () => {
  const hier = encodeJpeg(smoothGray(8), spec(1, 8, "hier-sequential"));
  const dhp = findSeg(hier, 0xde);
  assert.ok(dhp > 0, "分层文件必须有 DHP");

  // DHP 的分量表选择器必须为 0
  // DHP 负载：[P, H(2), W(2), Nf, (id, HV, tq)*] → 第 1 个分量的 tq 在偏移 8
  mustReject(patchPayload(hier, dhp, 8, 1), /量化表选择器应为 0/, "DHP 的 tq 必须为 0");
  // DHP 的 Nf 越界
  mustReject(patchPayload(hier, dhp, 5, 5), /DHP 声明了 5 个分量/, "DHP 分量数 5 非法");

  // EXP 放大因子越界（规范 1..4；写成 0 或 5 都非法）
  const exp = findSeg(hier, 0xdf);
  assert.ok(exp > 0, "分层文件必须有 EXP");
  mustReject(patchPayload(hier, exp, 1, 0x55), /EXP 放大因子非法/, "Eh/Ev=5 越界");

  // DHP 段长不足
  mustReject(patchU16(hier, dhp + 2, 4), /DHP 段长度不足/, "DHP 段长 4 不足");
});

test("JPEG 拒绝：分层两帧不匹配（分量数不同 / 精度不同 / 参考分量找不到）", () => {
  const hier = encodeJpeg(smoothRgb(8), spec(3, 8, "hier-sequential"));
  const sof5 = findSeg(hier, 0xc5);
  assert.ok(sof5 > 0, "第二帧应当是 SOF5");

  // 差分帧的 Nf 改成 1（参考帧是 3）
  mustReject(patchPayload(hier, sof5, 5, 1), /分量|精度|参考/, "两帧分量数不同必须拒绝");
  // 差分帧精度改成 12（参考帧是 8）
  const hier12 = patchPayload(hier, sof5, 0, 12);
  mustReject(hier12, /精度|分量|12/, "两帧精度不同必须拒绝");
});

test("JPEG 拒绝：各段体的长度下限（DQT / DHT / DRI / DHP / EXP）", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const dqt = findSeg(base, 0xdb);
  // 段长 20：一个 8 位表要 1 + 64 = 65 字节负载，装不下
  mustReject(patchU16(base, dqt + 2, 20), /DQT 段被截断/, "DQT 负载不足 65 字节");

  const dht = findSeg(base, 0xc4);
  // 段长 5：连 17 字节的表头都放不下
  mustReject(patchU16(base, dht + 2, 5), /DHT 段被截断（表头不足 17 字节）/, "DHT 段长 5");

  // DRI 段长 2 ⇒ 负载为空
  const rst = encodeJpeg(smoothGray(8), { ...spec(1, 8, "baseline"), restart: 4 });
  const dri = findSeg(rst, 0xdd);
  mustReject(patchU16(rst, dri + 2, 2), /DRI 段长度不足/, "DRI 负载为空");

  const hier = encodeJpeg(smoothGray(8), spec(1, 8, "hier-sequential"));
  const dhp = findSeg(hier, 0xde);
  // DHP 段长 9：Nf=1 时需要 6 + 3 = 9 字节负载，但段长 9 只给 7 字节
  mustReject(patchU16(hier, dhp + 2, 9), /DHP 段被截断|DHP 段长度不足/, "DHP 分量列表不完整");
  const exp = findSeg(hier, 0xdf);
  // 段长 2 ⇒ 负载为空（正常是 4：2 字节长度 + (Ci, Eh/Ev)）
  mustReject(patchU16(hier, exp + 2, 2), /EXP 段长度不足/, "EXP 负载为空");
  // 段长 5 ⇒ 负载 3 字节，不是 (Ci, Eh/Ev) 的整组
  mustReject(patchU16(hier, exp + 2, 5), /EXP 段体必须是/, "EXP 负载不是整组");
});

test("JPEG 拒绝：DAC 段（表号越界 / 条件参数非法 / 长度奇数）", () => {
  // 只有算术流才有 DAC。语料是"我们编码 + dac: true"，其余段与 arith-seq 完全一致。
  const base = encodeJpeg(smoothGray(8), { ...spec(1, 8, "arith-sequential"), dac: true });
  const dac = findSeg(base, 0xcc);
  assert.ok(dac > 0, "dac: true 时必须写 DAC 段");
  // DAC 负载：[Tc/Tb, Cs] × n。第 0 项是 DC 表 0，第 1 项是 AC 表 0
  mustReject(patchPayload(base, dac, 0, 0x05), /DAC 的 DC 表号 5 非法/, "DC 表号 5");
  mustReject(patchPayload(base, dac, 2, 0x15), /DAC 的 AC 表号 5 非法/, "AC 表号 5");
  // Cs 字节 = (U<<4)|L。U=0 L=5 ⇒ 条件区间是空的（要求 L ≤ U）
  mustReject(patchPayload(base, dac, 1, 0x05), /DAC 的 DC 条件参数非法/, "L=5 U=0 非法");
  // 段长 7 ⇒ 负载 5 字节：读完两对（4 字节）后剩 1 字节，凑不成一对
  mustReject(patchU16(base, dac + 2, 7), /DAC 段长度不是 2 的倍数/, "DAC 负载奇数长度");
});

test("JPEG 拒绝：算术扫描参数（顺序式 Ah/Al、渐进 DC 的 Se、谱段越界）", () => {
  const seq = encodeJpeg(smoothGray(8), spec(1, 8, "arith-sequential"));
  const sos = findSeg(seq, 0xda);
  // Ah/Al 字节改成 0x11（顺序式必须 0/0）
  mustReject(patchPayload(seq, sos, 3 + 2, 0x11), /顺序式扫描的 Ah\/Al 必须是 0\/0/, "顺序式 Ah/Al≠0/0");

  const prog = encodeJpeg(smoothGray(8), spec(1, 8, "arith-progressive"));
  const sosP = findSeg(prog, 0xda);
  // 首扫是 DC（Ss=0 Se=0）：把 Se 改成 5
  mustReject(patchPayload(prog, sosP, 2 + 2, 5), /DC 扫描（Ss=0）必须 Se=0/, "算术 DC 扫描 Se≠0");
  // Se 越过 63：谱段非法
  mustReject(patchPayload(prog, sosP, 2 + 2, 200), /谱段非法/, "Se=200 越界");
  // 逐次逼近位数 Al/Ah 只能是 0..13（D.2：12 位样本最多 13 级逼近，8 位更少）。
  // ★ 这条以前没有任何用例走到，行覆盖率审计才发现 —— 上限值本身没人钉过。
  mustReject(patchPayload(prog, sosP, 3 + 2, 0x0e), /逐次逼近位数非法：Al=14 Ah=0/, "Al=14 越界");
  // 逼近必须逐级：Ah 只能是 0（首扫）或 Al+1（下一次精修）。Ah=3 Al=1 是"跳级"。
  mustReject(patchPayload(prog, sosP, 3 + 2, 0x31), /逼近参数不连续/, "Ah/Al 跳级");
});

test("JPEG 拒绝：SOS 段体（为空 / 被截断 / 声明的分量数超过段体）", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const sos = findSeg(base, 0xda);
  // 段长 2 ⇒ 负载为空
  mustReject(patchU16(base, sos + 2, 2), /SOS 段为空/, "SOS 负载为空");
  // 段长 4 ⇒ 只有 Ns 一个字节，后面缺 (Cs,Td/Ta) 与 Ss/Se/AhAl
  mustReject(patchU16(base, sos + 2, 4), /SOS 段被截断/, "SOS 负载只有 Ns");

  // SOF 声称 3 个分量，但段体只够 1 个
  const sof = findSeg(base, 0xc0);
  mustReject(patchPayload(base, sof, 5, 3), /SOF 声明 3 个分量，但段里只有/, "SOF 分量数超过段体");
});

test("JPEG 拒绝：SOS 出现在 SOF 之前 / DHT 计数与符号数不符", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const sos = findSeg(base, 0xda);
  const segLen = (base[sos + 2]! << 8) | base[sos + 3]!;
  // 只保留 SOI + 这一段 SOS：解析到 SOS 时还没有任何帧头
  const orphan = new Uint8Array(2 + 2 + segLen);
  orphan.set(base.subarray(0, 2), 0);
  orphan.set(base.subarray(sos, sos + 2 + segLen), 2);
  mustReject(orphan, /SOS 出现在 SOF 之前/, "孤立 SOS 必须拒绝");

  // DHT：把某个码长的计数改大，声明需要的符号数超过段里剩下的字节
  // ★ `HuffTable` 构造函数里还有一条 `k !== values.length` 的"自相矛盾"检查，
  //   但 `parseDht` 传给它的 values 就是按 k 切出来的（`subarray(at, at + total)`），
  //   两者永远相等 —— 那条检查**不可达**。这里测的是能走到的那条（符号数不足）。
  const dht = findSeg(base, 0xc4);
  let slot = -1;
  for (let i = 1; i <= 16; i++) {
    if (base[dht + 4 + i]! > 0) {
      slot = i;
      break;
    }
  }
  assert.ok(slot > 0, "DC 表的计数全为 0，用例前提不成立");
  mustReject(patchPayload(base, dht, slot, 200), /DHT 段被截断（符号数不足）/, "计数声称有 200 个符号");
});

test("JPEG 拒绝：无损扫描的 Ah 必须为 0 / Pt 必须小于精度（哈夫曼与算术各一遍）", () => {
  for (const mode of ["lossless", "arith-lossless"] as JpegMode[]) {
    const base = encodeJpeg(hardGray(8), spec(1, 8, mode));
    const sos = findSeg(base, 0xda);
    // Ah/Al 字节 = Ah<<4 | Al；无损过程要求 Ah=0，Al 就是 Pt
    mustReject(patchPayload(base, sos, 1 + 2 + 2, 0x10), /无损扫描的 Ah 必须是 0/, `${mode}：Ah=1 非法`);
    mustReject(patchPayload(base, sos, 1 + 2 + 2, 0x08), /点变换 Pt=8 必须小于精度/, `${mode}：Pt=8 不小于 8 位精度`);
  }
});

test("JPEG 拒绝：AC 扫描声明多个分量（渐进式的 AC 扫描必须单分量）", () => {
  for (const mode of ["progressive", "arith-progressive"] as JpegMode[]) {
    const base = encodeJpeg(smoothRgb(8), spec(3, 8, mode));
    // 找一个 AC 扫描（Ss>0）：逐段扫 SOS，第一个就是 DC 首扫，后面是 AC
    let at = -1;
    let from = 2;
    while (true) {
      const p = findSeg(base.subarray(from), 0xda);
      if (p < 0) break;
      const segAt = from + p;
      const ss = base[segAt + 4 + 1 + 2 * base[segAt + 4]!]!;
      if (ss > 0) {
        at = segAt;
        break;
      }
      from = segAt + 2;
    }
    assert.ok(at > 0, `${mode} 应当有 AC 扫描`);
    // 把 Ns 改成 3，并按 3 个分量重写段长与负载（熵数据原样保留在后面）
    const payload = [3, 1, 0x00, 2, 0x00, 3, 0x00, 1, 63, 0];
    const rebuilt = replaceSosPayload(base, at, payload);
    mustReject(rebuilt, /AC 扫描（Ss>0）必须是单分量扫描/, `${mode}：AC 扫描 3 分量必须拒绝`);
  }
});

test("JPEG 拒绝：分层两帧分量数不同（帧0 三分量 + 帧1 单分量 拼接）", () => {
  // ★ 为什么要拼接而不是改字节：直接改差分帧的 Nf 会让"SOF 声明的分量数"与段体、
  //   与 SOS 的分量列表同时不一致，先在更早的检查那里就报错了 —— 那样测到的是
  //   另一个判据，hierarchy.ts 里"两帧分量数不同"这条永远走不到。
  //   拼接能造出"两帧各自都合法、但彼此不匹配"的文件，这才是真实会遇到的情况
  //   （编码器把完成态图像的分量数搞错）。
  const rgb = encodeJpeg(smoothRgb(8), spec(3, 8, "hier-sequential"));
  const gray = encodeJpeg(smoothGray(8), spec(1, 8, "hier-sequential"));
  const cutRgb = findSeg(rgb, 0xc5);
  const cutGray = findSeg(gray, 0xc5);
  assert.ok(cutRgb > 0 && cutGray > 0, "两个文件都要有第二帧");

  // ★ 必须先把 EXP 段去掉：带 EXP 的拼接文件会先在"EXP 放大因子与几何不符"那里被拦下
  //   （差分帧少了两个分量，几何比算成 0），于是 hierarchy.ts 的这条永远走不到。
  //   去掉 EXP 之后，两帧几何按实际尺寸算，才轮到"两帧分量数不同"。
  const head = stripExp(rgb.subarray(0, cutRgb));
  assert.equal(
    hasMarker(head, 0xdf),
    false,
    "stripExp 必须真的把 EXP 剥干净（否则下面测到的是 EXP 判据，不是分量数判据）",
  );
  const spliced = new Uint8Array(head.length + (gray.length - cutGray));
  spliced.set(head, 0);
  spliced.set(gray.subarray(cutGray), head.length);
  mustReject(
    spliced,
    /差分帧有 1 个分量，参考帧有 3 个/,
    "两帧分量数不同必须拒绝",
  );
});

test("JPEG 拒绝：分层差分帧的分量数**多于**参考帧（帧0 单分量 + 帧1 三分量）", () => {
  // 反方向也要钉：只测"差分帧更少"会让"只比较了 <= 的一半"这种写法也绿。
  // 这一条同时把 pairComponent 的兜底路径（`prev.components[ci]` 为 undefined）压到
  // 可达 —— 见下面那条注释，正常情况下它被 checkPairing 挡在前面，够不到。
  const gray = encodeJpeg(smoothGray(8), spec(1, 8, "hier-sequential"));
  const rgb = encodeJpeg(smoothRgb(8), spec(3, 8, "hier-sequential"));
  const cutGray = findSeg(gray, 0xc5);
  const cutRgb = findSeg(rgb, 0xc5);
  assert.ok(cutGray > 0 && cutRgb > 0, "两个文件都要有第二帧");

  // ★ 灰度那份的 DHT 只定义了 0 号表，而拼接进来的三分量差分帧要用 1 号表 ——
  //   不先把 DHT 换成 rgb 的，就会先报"DHT 缺失"，测到的又不是分量数那条。
  //   换成 rgb 的 DHT（含 0/1 两套）之后，前三项检查都过得去，才轮到 checkPairing。
  const grayHead = replaceSegWith(stripExp(gray.subarray(0, cutGray)), rgb, 0xc4);
  const spliced = new Uint8Array(grayHead.length + (rgb.length - cutRgb));
  spliced.set(grayHead, 0);
  spliced.set(rgb.subarray(cutRgb), grayHead.length);
  mustReject(
    spliced,
    /差分帧有 3 个分量，参考帧有 1 个/,
    "差分帧分量数多于参考帧必须拒绝",
  );
});

// ★ 这里原本还想测"差分帧引用参考帧没有的分量"（hierarchy.ts:77 的那条 fail）。
//   结论是**当前代码里不可达**，所以不留假用例：
//   `addReferencePlanes()` 先调 `checkPairing()` 要求两帧分量数相等，然后才逐分量配对；
//   数相等 ⇒ `prev.components[ci]` 必然存在 ⇒ 兜底分支拿不到 undefined。
//   那条 `p === undefined` 现在的作用是给 TS 收窄 `Component | undefined`
//   （`noUncheckedIndexedAccess`），是类型需要而不是运行时判据 —— 已在 ADR-0009
//   的"不可达拒绝理由"清单里登记，不冒充成有覆盖的分支。

test("JPEG 拒绝：分层两帧精度不同（去 DHP 后把帧1 的精度字段改成 12）", () => {
  // ★ 为什么不是"8 位文件和 12 位文件拼接"：12 位那份的**熵数据**拿 8 位表去解，
  //   会先在"AC 系数越过块尾（k=64）"炸掉 —— 差分扫描在 checkPairing 之前就解完了，
  //   测到的不是精度判据。所以改成"同一份 8 位熵数据 + 帧头精度写成 12"：
  //   熵能解完，才轮得到比精度。
  const base = encodeJpeg(smoothRgb(8), spec(3, 8, "hier-sequential"));
  // ★ 去 DHP 是关键：有 DHP 时解析期就会报"分层序列的精度不一致（DHP 声明 8 位…）"，
  //   那条（B.3.1 要求所有帧精度等于 DHP 精度）**蕴含**了 checkPairing 的比较，
  //   于是后者永远走不到 —— 这也是它一直没被触发的原因。
  const noDhp = stripMarker(stripExp(base), 0xde);
  const cut = findSeg(noDhp, 0xc5);
  assert.ok(cut > 0, "帧1 的 SOF5 应当还在");
  // SOF 负载：[P, H,H, W,W, Nf, …] —— 精度在偏移 0
  mustReject(
    patchPayload(noDhp, cut, 0, 12),
    /精度 12 与参考帧 8 不一致/,
    "两帧精度不同必须拒绝",
  );
});

// ------------------------------------------------------------ 拒绝路径：编码端构造的坏熵数据
//
// ★ 这一组针对审计里"测试期间从未触发"的那批 `fail`。它们不是死代码 ——
//   是**没造出能走到那里的文件**。做法统一为：把 DHT 换成一张只有一个码字的表
//   （于是熵数据里的每一位都可控），再把这个扫描的熵数据整段换成我们写的字节。
//   这样每条断言都是"我喂了 X，必须报 Y"，而不是"随便坏掉就行"。

test("JPEG 拒绝：DC 差分类别超过该精度的上限（顺序式与渐进式两条路径）", () => {
  for (const mode of ["baseline", "progressive"] as JpegMode[]) {
    const base = encodeJpeg(smoothGray(8), spec(1, 8, mode));
    // DC 表：1 位码 `0` → 符号 15（8 位样本的上限是 11）
    const dht = replaceDht(base, [...tinyHuff(0, 0, 15), ...tinyHuff(1, 0, 0x00)]);
    const sos = findSeg(dht, 0xda);
    // 熵数据第一个 bit 就是 `0` ⇒ 解出 s=15 ⇒ 立刻超限
    mustReject(
      replaceEntropy(dht, sos, [0x00]),
      /DC 差分位数 15 超过 11（8 位样本的上限）/,
      `${mode}：DC 类别 15 对 8 位样本超限`,
    );
  }
});

test("JPEG 拒绝：AC 系数越过块尾（run 一路累加到 64）", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  // AC 表：1 位码 → 0xF1（run=15, size=1）。k 从 1 起，每次 +15：16/32/48/64
  const dht = replaceDht(base, [...tinyHuff(0, 0, 0x00), ...tinyHuff(1, 0, 0xf1)]);
  const sos = findSeg(dht, 0xda);
  mustReject(
    replaceEntropy(dht, sos, [0x00]),
    /AC 系数越过块尾：k=64（run=15）/,
    "AC run 累加越过 63",
  );
});

test("JPEG 拒绝：渐进 AC 首扫越过块尾 / 精修扫描里 size≠1", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "progressive"));
  const sosOffsetOf = (bytes: Uint8Array): number => {
    for (let from = 2; ; ) {
      const p = findSeg(bytes.subarray(from), 0xda);
      if (p < 0) return -1;
      const segAt = from + p;
      if (bytes[segAt + 4 + 1 + 2 * bytes[segAt + 4]!]! > 0) return segAt;
      from = segAt + 2;
    }
  };
  // ★ 先换 DHT 再找 SOS：换表会改变文件长度（原表 400 多字节，替身 36 字节），
  //   在“换表前”算出来的偏移换完就指向垃圾 —— 第一次写这条用例就栽在这里，
  //   报的是“哈夫曼码流非法”（从垃圾位置开始读熵数据），而不是块尾越界。
  const widenedDht = replaceDht(base, [...tinyHuff(0, 0, 0x00), ...tinyHuff(1, 0, 0xf1)]);

  // ★ 还要把**前面那个 DC 扫描**的熵数据也换成全 0：换过表之后 DC 扫描仍用同一份
  //   DHT，原熵数据里只要有一位是 1，就会先在 DC 扫描报“哈夫曼码流非法”，
  //   根本轮不到 AC 扫描。全 0 ⇒ 每位都解出 s=0（1 位码 `0` → 符号 0），读满块数即结束。
  const dcSos = findSeg(widenedDht, 0xda);
  const zeroed = replaceEntropy(widenedDht, dcSos, new Array<number>(8).fill(0));

  // ① 首扫（Ah=0）：把 Se 拉到 63，让 k 能一路加到 64
  const widened = patchPayload(zeroed, sosOffsetOf(zeroed), 1 + 2 * 1 + 1, 63);
  mustReject(
    replaceEntropy(widened, sosOffsetOf(widened), [0x00]),
    /渐进 AC 系数越过块尾：k=64/,
    "渐进 AC 首扫越过块尾",
  );

  // ② 精修（Ah>0）：AC 表给 run=1/size=2，规范只允许 size∈{0,1}
  const refineDht = replaceDht(base, [...tinyHuff(0, 0, 0x00), ...tinyHuff(1, 0, 0x12)]);
  const refineZeroed = replaceEntropy(
    refineDht,
    findSeg(refineDht, 0xda),
    new Array<number>(8).fill(0),
  );
  const refine = patchPayload(
    patchPayload(refineZeroed, sosOffsetOf(refineZeroed), 1 + 2 * 1 + 2, 0x10), // Ah=1, Al=0
    sosOffsetOf(refineZeroed),
    1 + 2 * 1 + 1, // Se=63
    63,
  );
  mustReject(
    replaceEntropy(refine, sosOffsetOf(refine), [0x00]),
    /渐进 AC 精修里出现了 size=2/,
    "精修扫描里 size 只能是 0 或 1",
  );
});

test("JPEG 拒绝：无损差分类别超过 16", () => {
  const base = encodeJpeg(hardGray(8), spec(1, 8, "lossless"));
  // 无损只查 DC 表；符号 20 > 16（无损没有"类别上限随精度变"的说法，上限就是 16）
  const dht = replaceDht(base, tinyHuff(0, 0, 20));
  const sos = findSeg(dht, 0xda);
  mustReject(replaceEntropy(dht, sos, [0x00]), /无损差分的类别位数 20 超过 16/, "无损类别 20 超限");
});

test("JPEG 拒绝：哈夫曼码流连续 16 位都没有匹配码字", () => {
  const base = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  // 表里只有 1 位码 `0`；熵数据全喂 1（0xFF 在文件里必须写成 FF 00，解码端还原成 8 个 1）
  const dht = replaceDht(base, [...tinyHuff(0, 0, 0x00), ...tinyHuff(1, 0, 0x00)]);
  const sos = findSeg(dht, 0xda);
  mustReject(
    replaceEntropy(dht, sos, [0xff, 0x00, 0xff, 0x00]),
    /哈夫曼码流非法：连续 16 位都没有匹配的码字/,
    "16 位全 1 但表里只有码字 0",
  );
});

test("JPEG 拒绝：算术编码的 DC 幅度类别溢出（≥ 0x8000）", () => {
  // ★ 构造方法：把熵数据整段换成 16 个 `FF 00`（文件里 0xFF 必须填充成 FF 00）。
  //   QM 在"一路 LPS"的位流上会把幅度类别一路左移，第 15 次就碰到 0x8000 上限。
  //   三种算术过程（顺序 / 渐进 / 无损）都要走这条，所以三个模式各测一遍。
  //   实测：常量填充只有 0xFF 能触发（0x00/0x55/0xAA 都只是"解出一张坏图"）；
  //   随机 16..64 字节填充 40 万次也没有命中 —— 这条路径对外部坏文件是"深度防御"。
  for (const mode of ["arith-sequential", "arith-progressive", "arith-lossless"] as JpegMode[]) {
    const base = encodeJpeg(smoothGray(8), spec(1, 8, mode));
    const sos = findSeg(base, 0xda);
    const fill: number[] = [];
    for (let i = 0; i < 16; i++) fill.push(0xff, 0x00);
    mustReject(
      replaceEntropy(base, sos, fill),
      /算术编码的 DC 幅度类别溢出（≥ 0x8000）/,
      `${mode}：DC 幅度类别溢出`,
    );
  }
});

test("JPEG 拒绝：HuffTable 自身的构造契约（文件路径上不可达，只由本判据覆盖）", () => {
  // ★ 为什么这条要直接构造而不是造文件：`parseDht` 传进来的 values 就是按
  //   `counts` 的合计切出来的子数组，所以 `k !== values.length` 在文件路径上**恒假**。
  //   但 HuffTable 是导出类，这条不变量保护的是"将来的调用方" —— 一旦有人直接
  //   用错配的两个数组构造，maxcode/valptr 会指向 values 之外，读出一堆 undefined。
  //   与其把它算成"没有覆盖的分支"，不如把契约本身钉住。
  assert.throws(
    () => new HuffTable(Uint8Array.from([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), new Uint8Array([])),
    /DHT 表自相矛盾：code length 计数合计 1，实际给了 0 个符号/,
  );
  assert.doesNotThrow(
    () => new HuffTable(Uint8Array.from([1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]), Uint8Array.from([7])),
  );
});

test("JPEG 拒绝：无损预测器选择值只能是 1..7（函数契约，文件路径上被扫描头先挡）", () => {
  // 文件路径上 Ss=0 会先被 `scan-lossless` 的"预测器必须是 1..7"拦下，
  // 所以 predictLossless 的 default 分支走不到；但它是导出函数，
  // 兜底存在的意义就是"别人误传给 0 时不要静默按 P1 算"。
  assert.throws(() => predictLossless(0, 1, 2, 3), /无损预测器选择值必须是 1..7，实际 0/);
  assert.throws(() => predictLossless(8, 1, 2, 3), /无损预测器选择值必须是 1..7，实际 8/);
  assert.equal(predictLossless(1, 11, 22, 33), 11);
});

// ------------------------------------------------------------ ⑩ 单字节篡改的鲁棒性
//
// ★ 为什么还要这一条：截断前缀只覆盖"文件少了尾巴"，而真实坏文件更多是"某几个字节被写坏"
//   （存储位翻转、传输截断到一半、编辑器把某个段改错）。这类输入的破坏点可能落在
//   **任何一个字段**上：段长、表号、采样因子、预测器、谱段边界、重启计数……
//   判据只有一条、但很强：**解码器永远返回 Result，永远不抛异常；返回 ok 时像素数组
//   长度必须等于 w×h×4**。它挡的是"读到 undefined 再崩在调用方"那一类错误 ——
//   这种错误不会出现在正常语料里，但会让整个导入流水线崩掉。
//
// ★ 为什么用固定种子而不是随机：判据必须可复现。这里是"遍历 + 少量固定取值"，
//   不是随机采样，所以失败时能直接报出"第几个字节、改成了什么"。

test("JPEG 鲁棒性：任意单字节篡改都返回 Result（不抛异常、像素长度自洽）", () => {
  const seeds: Array<[string, Uint8Array]> = [
    ["baseline 8 位灰度", encodeJpeg(smoothGray(8), spec(1, 8, "baseline"))],
    ["baseline 8 位 4:2:0", encodeJpeg(smoothRgb(8), spec(3, 8, "baseline"))],
    ["渐进 8 位灰度", encodeJpeg(smoothGray(8), spec(1, 8, "progressive"))],
    ["算术顺序 8 位灰度", encodeJpeg(smoothGray(8), spec(1, 8, "arith-sequential"))],
    ["无损 8 位灰度", encodeJpeg(smoothGray(8), spec(1, 8, "lossless"))],
    ["分层 8 位 RGB", encodeJpeg(smoothRgb(8), spec(3, 8, "hier-sequential"))],
    ["4 分量 CMYK", encodeJpeg(cmykSample(8), { ...spec(3, 8, "baseline"), components: 4 } as EncodeSpec)],
  ];

  let checked = 0;
  let rejected = 0;
  let accepted = 0;
  for (const [name, bytes] of seeds) {
    // 每份文件取 ~160 个位置（覆盖头部 + 熵数据），每个位置试 5 个值
    const stride = Math.max(1, Math.floor(bytes.length / 160));
    for (let pos = 0; pos < bytes.length; pos += stride) {
      for (const v of [0x00, 0x55, 0xaa, 0xff, bytes[pos]! ^ 0x01]) {
        const mut = Uint8Array.from(bytes);
        mut[pos] = v;
        const r = (() => {
          try {
            return decodeJpeg(mut, { keep16: true });
          } catch (e) {
            assert.fail(
              `${name}：把第 ${pos} 字节改成 0x${v.toString(16)} 之后**抛了异常**` +
                `（${(e as Error).constructor.name}: ${(e as Error).message}）—— 解码器必须返回 Result`,
            );
          }
        })();
        checked++;
        if (!r.ok) {
          // ★ 真正有信息量的是这一条：`decodeJpeg` 末尾有兜底 catch，任何内部
          //   TypeError 都会被包成"JPEG 解码内部错误"。也就是说"不抛异常"是**结构性保证**，
          //   它挡不住"读到 undefined 再被兜底吞掉"这种错 —— 那种错在正常语料里看不见，
          //   但会把一张坏图变成"内部错误"，且真实缺陷被掩盖。
          //   所以这里要求：坏输入必须被**结构化地拒绝**（点名了原因），不能落到兜底。
          assert.ok(
            !r.error.message.includes("解码内部错误"),
            `${name}：把第 ${pos} 字节改成 0x${v.toString(16)} 之后落到兜底 catch（${r.error.message}）` +
              "—— 说明某处读到了 undefined/NaN，而不是被结构化拒绝",
          );
          assert.ok(r.error.message.length > 0, `${name}：拒绝时必须给出可读原因`);
          rejected++;
          continue;
        }
        accepted++;
        const d = r.value;
        assert.equal(
          d.pixels.length,
          d.width * d.height * 4,
          `${name}：第 ${pos} 字节改成 0x${v.toString(16)} 后返回的 RGBA 长度与宽高不符`,
        );
        assert.ok(d.pixels16 !== undefined, `${name}：keep16 时必须给 pixels16`);
        assert.equal(
          d.pixels16!.length,
          d.width * d.height * 4,
          `${name}：pixels16 长度与宽高不符`,
        );
        assert.ok(
          d.width > 0 && d.height > 0,
          `${name}：解出 ok 就必须有正的宽高`,
        );
      }
    }
  }
  assert.ok(checked > 4000, `只检查了 ${checked} 个篡改样本，样本数/步长不对`);
  // 两条路都必须真的走到：全拒说明"什么都解不开"也能让上面全绿；全收说明篡改没生效。
  assert.ok(rejected > 500, `只有 ${rejected} 个篡改被拒绝，篡改可能落在无关字节上`);
  assert.ok(accepted > 500, `只有 ${accepted} 个篡改仍能解出，篡改可能没生效`);
});

// ------------------------------------------------------------ 工具

/**
 * 去掉所有 EXP 段（FF DF）：用来构造"没有放大声明"的畸形分层序列。
 *
 * ★ `FF 00` 必须当**两个普通字节**（字节填充），不能当段头。
 *   熵数据里每个裸 0xFF 都由编码端补成 `FF 00`；把它当成"段长在 +2 处"的段头，
 *   会按随机长度一口气跳过几十字节 —— 于是这个遍历会**跳出对齐**，
 *   后面靠"遇到下一个 FF 就重新对齐"勉强接上，但正好跨过了 EXP，
 *   结果"去 EXP"这个前提没成立，用例测的又是 EXP 那条判据。
 *   （40×24 的语料里有 4 处 `FF 00`，必然踩中；8×8 的小图偶然没踩中才让初版看起来是对的。）
 */
function stripExp(bytes: Uint8Array): Uint8Array {
  return stripMarker(bytes, 0xdf);
}

/** 去掉某一种标记段（同 `stripExp`，只是标记可变）。 */
function stripMarker(bytes: Uint8Array, drop: number): Uint8Array {
  const keep: Uint8Array[] = [];
  let pos = 0;
  while (pos < bytes.length) {
    if (bytes[pos] !== 0xff) {
      keep.push(bytes.subarray(pos, pos + 1));
      pos++;
      continue;
    }
    const marker = bytes[pos + 1]!;
    if (
      marker === 0x00 ||
      marker === 0xd8 ||
      (marker >= 0xd0 && marker <= 0xd7) ||
      marker === 0x01
    ) {
      keep.push(bytes.subarray(pos, pos + 2));
      pos += 2;
      continue;
    }
    const len = (bytes[pos + 2]! << 8) | bytes[pos + 3]!;
    if (marker !== drop) keep.push(bytes.subarray(pos, pos + 2 + len));
    pos += 2 + len;
  }
  const total = keep.reduce((n, c) => n + c.length, 0);
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of keep) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

/** 用新的负载重建某个 SOS 段（段长跟着改），熵数据保持原位。 */
function replaceSosPayload(bytes: Uint8Array, sosAt: number, payload: readonly number[]): Uint8Array {
  const oldLen = (bytes[sosAt + 2]! << 8) | bytes[sosAt + 3]!;
  const oldEnd = sosAt + 2 + oldLen;
  const seg = new Uint8Array(4 + payload.length);
  seg[0] = 0xff;
  seg[1] = 0xda;
  const len = 2 + payload.length;
  seg[2] = (len >> 8) & 0xff;
  seg[3] = len & 0xff;
  seg.set(payload, 4);
  const out = new Uint8Array(bytes.length - (oldEnd - sosAt) + seg.length);
  out.set(bytes.subarray(0, sosAt), 0);
  out.set(seg, sosAt);
  out.set(bytes.subarray(oldEnd), sosAt + seg.length);
  return out;
}

/**
 * 找某个标记段的起点。
 *
 * ★ 不能用"按段长逐段跳"的走法：分层文件的第二帧在**熵数据之后**，
 *   而熵数据里没有段长，逐段跳会直接走进码流里乱猜。
 *   扫描 `FF <marker>` 是对的，因为熵数据里的 0xFF 必须被填充成 `FF 00`
 *   （T.81 B.1.1.5），所以真标记不会和码流混淆。
 *   再用"段长合理且不越界"复核一次，排除偶然匹配。
 */
function findSeg(bytes: Uint8Array, marker: number): number {
  for (let i = 2; i + 3 < bytes.length; i++) {
    if (bytes[i] !== 0xff || bytes[i + 1] !== marker) continue;
    const len = (bytes[i + 2]! << 8) | bytes[i + 3]!;
    if (len >= 2 && i + 2 + len <= bytes.length) return i;
  }
  return -1;
}

/** 用 source 里的某个段整段替换 target 里的同名段（段长不同也能换）。 */function replaceSegWith(target: Uint8Array, source: Uint8Array, marker: number): Uint8Array {
  const t = findSeg(target, marker);
  const s = findSeg(source, marker);
  if (t < 0 || s < 0) throw new Error(`replaceSegWith：找不到 ff${marker.toString(16)}`);
  const tLen = 2 + ((target[t + 2]! << 8) | target[t + 3]!);
  const sLen = 2 + ((source[s + 2]! << 8) | source[s + 3]!);
  const out = new Uint8Array(target.length - tLen + sLen);
  out.set(target.subarray(0, t), 0);
  out.set(source.subarray(s, s + sLen), t);
  out.set(target.subarray(t + tLen), t + sLen);
  return out;
}

/** 从熵数据起点往后找第一个真正的标记（`FF 00` 是字节填充，`FF D0..D7` 是 RST）。 */
function entropyEnd(bytes: Uint8Array, start: number): number {
  for (let i = start; i + 1 < bytes.length; i++) {
    if (bytes[i] !== 0xff) continue;
    const m = bytes[i + 1]!;
    if (m === 0x00 || (m >= 0xd0 && m <= 0xd7)) {
      i++;
      continue;
    }
    return i;
  }
  return bytes.length;
}

/**
 * 整段替换某个 SOS 之后的熵数据（SOS 段本身不动，段长因此也不必改）。
 *
 * ★ 熵数据的**结尾不能靠段长算**：它一直延续到下一个真标记为止。
 *   按"跳过 len 字节"的走法在这里会把后面整段文件当成熵数据。
 */
function replaceEntropy(bytes: Uint8Array, sosAt: number, entropy: readonly number[]): Uint8Array {
  const len = (bytes[sosAt + 2]! << 8) | bytes[sosAt + 3]!;
  const start = sosAt + 2 + len;
  const end = entropyEnd(bytes, start);
  const out = new Uint8Array(bytes.length - (end - start) + entropy.length);
  out.set(bytes.subarray(0, start), 0);
  out.set(Uint8Array.from(entropy), start);
  out.set(bytes.subarray(end), start + entropy.length);
  return out;
}

/**
 * 造一张"只有一个码字"的哈夫曼表：1 位码 `0` → 给定的符号。
 *
 * 只有这种表才能让熵数据的**每一位都可控** —— 换成真实表的话，
 * "喂 0x00 会解出什么符号"取决于表的排布，断言就变成猜。
 */
function tinyHuff(tc: number, th: number, symbol: number): number[] {
  return [(tc << 4) | th, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, symbol];
}

/** 用给定负载整段替换文件里的 DHT（段长按负载重算）。 */
function replaceDht(bytes: Uint8Array, payload: readonly number[]): Uint8Array {
  const at = findSeg(bytes, 0xc4);
  if (at < 0) throw new Error("replaceDht：这份文件没有 DHT 段");
  const total = 2 + ((bytes[at + 2]! << 8) | bytes[at + 3]!);
  const seg = new Uint8Array(4 + payload.length);
  seg[0] = 0xff;
  seg[1] = 0xc4;
  const len = 2 + payload.length;
  seg[2] = (len >> 8) & 0xff;
  seg[3] = len & 0xff;
  seg.set(payload, 4);
  const out = new Uint8Array(bytes.length - total + seg.length);
  out.set(bytes.subarray(0, at), 0);
  out.set(seg, at);
  out.set(bytes.subarray(at + total), at + seg.length);
  return out;
}

/** 文件里还有没有这个标记（按段结构走，不认熵数据里的 `FF 00`）。 */
function hasMarker(bytes: Uint8Array, marker: number): boolean {
  for (let pos = 2; pos + 3 < bytes.length; ) {
    if (bytes[pos] !== 0xff) {
      pos++;
      continue;
    }
    const m = bytes[pos + 1]!;
    if (m === 0x00 || (m >= 0xd0 && m <= 0xd7)) {
      pos += 2;
      continue;
    }
    if (m === marker) return true;
    if (m === 0xd8 || m === 0x01) {
      pos += 2;
      continue;
    }
    pos += 2 + ((bytes[pos + 2]! << 8) | bytes[pos + 3]!);
  }
  return false;
}

/**
 * 在第二帧（差分帧 SOF5）之前插入一张"全 1"量化表（tq 个槽位），用来验证
 * "表在 SOS 时绑定"这件事：如果解码器在重建时才查 `frame.qt`，
 * 先解的帧会被后来的表影响，而这条插入会让结果**必然**变化。
 */
function reinsertDqtForFrame1(bytes: Uint8Array, tq: number): Uint8Array | null {
  const at = findSeg(bytes, 0xc5);
  if (at < 0) return null;
  return insertDqtAt(bytes, at, tq);
}

/** 把同一张"全 1"量化表插到 EOI 之前：太晚了，任何帧都不该受它影响。 */
function appendDqtBeforeEoi(bytes: Uint8Array, tq: number): Uint8Array {
  assert.equal(bytes[bytes.length - 2], 0xff, "文件末尾应当是 EOI");
  assert.equal(bytes[bytes.length - 1], 0xd9, "文件末尾应当是 EOI");
  return insertDqtAt(bytes, bytes.length - 2, tq);
}

function insertDqtAt(bytes: Uint8Array, at: number, tq: number): Uint8Array {
  const seg = new Uint8Array(4 + 1 + 64);
  seg[0] = 0xff;
  seg[1] = 0xdb;
  seg[2] = 0x00;
  seg[3] = 0x43; // 段长 = 2 + 1 + 64 = 67
  seg[4] = tq; // Pq=0（8 位表）, Tq=tq
  seg.fill(1, 5); // 全 1 = 不量化
  const out = new Uint8Array(bytes.length + seg.length);
  out.set(bytes.subarray(0, at), 0);
  out.set(seg, at);
  out.set(bytes.subarray(at), at + seg.length);
  return out;
}

/** 改一个段**负载**里的字节：`segAt` 是段起点（FF xx），`off` 从负载首字节算起。 */
function patchPayload(bytes: Uint8Array, segAt: number, off: number, v: number): Uint8Array {
  const out = Uint8Array.from(bytes);
  out[segAt + 4 + off] = v & 0xff;
  return out;
}

/** 改任意位置的两个字节（大端）。用来改段长。 */
function patchU16(bytes: Uint8Array, at: number, v: number): Uint8Array {
  const out = Uint8Array.from(bytes);
  out[at] = (v >> 8) & 0xff;
  out[at + 1] = v & 0xff;
  return out;
}

/** 断言这份字节**被拒绝**，且错误消息点名了预期原因。 */
function mustReject(bytes: Uint8Array, re: RegExp, why: string): void {
  const r = decodeJpeg(bytes);
  if (r.ok) assert.fail(`${why}：期望被拒绝，实际解码成功（${r.value.width}×${r.value.height}）`);
  assert.match(r.error.message, re, `${why}（实际：${r.error.code} ${r.error.message}）`);
}

/** 插入一个只带 Orientation 标签的 APP1(EXIF) 段（小端 TIFF，32 字节负载）。 */
function insertApp1Orientation(bytes: Uint8Array, orientation: number): Uint8Array {
  const payload = new Uint8Array(32);
  payload.set([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]); // "Exif\0\0"
  const t = 6;
  payload.set([0x49, 0x49, 0x2a, 0x00], t); // II + 0x2A00
  payload.set([0x08, 0x00, 0x00, 0x00], t + 4); // IFD0 偏移 = 8
  payload.set([0x01, 0x00], t + 8); // 条目数 1
  const e = t + 10;
  payload.set([0x12, 0x01], e); // tag 0x0112 = Orientation
  payload.set([0x03, 0x00], e + 2); // type 3 = SHORT
  payload.set([0x01, 0x00, 0x00, 0x00], e + 4); // count 1
  payload.set([orientation & 0xff, 0x00], e + 8);
  // payload 末尾 4 字节（下一个 IFD 偏移）保持 0

  const seg = new Uint8Array(4 + payload.length);
  seg[0] = 0xff;
  seg[1] = 0xe1;
  seg[2] = ((payload.length + 2) >> 8) & 0xff;
  seg[3] = (payload.length + 2) & 0xff;
  seg.set(payload, 4);

  const out = new Uint8Array(2 + seg.length + bytes.length - 2);
  out.set(bytes.subarray(0, 2));
  out.set(seg, 2);
  out.set(bytes.subarray(2), 2 + seg.length);
  return out;
}

/** 改 SOF 的某个字段：precision(1B) / height(2B) / width(2B)。找不到该 SOF 返回 null。 */
function withSofField(
  bytes: Uint8Array,
  sof: number,
  field: "precision" | "height" | "width",
  value: number,
): Uint8Array | null {
  const at = findSeg(bytes, sof);
  if (at < 0) return null;
  const copy = Uint8Array.from(bytes);
  if (field === "precision") {
    copy[at + 4] = value;
  } else if (field === "height") {
    copy[at + 5] = (value >> 8) & 0xff;
    copy[at + 6] = value & 0xff;
  } else {
    copy[at + 7] = (value >> 8) & 0xff;
    copy[at + 8] = value & 0xff;
  }
  return copy;
}

// ------------------------------------------------------------ ⑧ 13 个 SOF 的"全实现"必须是可执行的句子

/**
 * SOF 标记 ↔ 编码模式 ↔ 期望精度。这张表就是 README 里"13 个 SOF 全实现"的**执行版**。
 *
 * ★ 为什么需要它：单独的用例各自断言了自己的 SOF，但**没有任何一条判据保证 13 个都被覆盖**。
 *   删掉一个模式、或者把某个模式的 SOF 标记写错，其他用例照样绿 —— 因为它们各测各的。
 *   这里把"标记集合"本身变成断言：少一个就红，多一个（不支持的 SOF 被放行）也红。
 */
const SOF_MATRIX: readonly { readonly mode: JpegMode; readonly precision: 8 | 12; readonly sof: number; readonly name: string }[] = [
  { mode: "baseline", precision: 8, sof: 0xc0, name: "SOF0 顺序 DCT" },
  { mode: "baseline", precision: 12, sof: 0xc1, name: "SOF1 扩展顺序 DCT" },
  { mode: "progressive", precision: 8, sof: 0xc2, name: "SOF2 渐进 DCT" },
  { mode: "lossless", precision: 8, sof: 0xc3, name: "SOF3 无损（哈夫曼）" },
  { mode: "hier-sequential", precision: 8, sof: 0xc5, name: "SOF5 差分顺序 DCT" },
  { mode: "hier-progressive", precision: 8, sof: 0xc6, name: "SOF6 差分渐进 DCT" },
  { mode: "hier-lossless", precision: 8, sof: 0xc7, name: "SOF7 差分无损" },
  { mode: "arith-sequential", precision: 8, sof: 0xc9, name: "SOF9 算术顺序 DCT" },
  { mode: "arith-progressive", precision: 8, sof: 0xca, name: "SOF10 算术渐进 DCT" },
  { mode: "arith-lossless", precision: 8, sof: 0xcb, name: "SOF11 算术无损" },
  { mode: "hier-arith-sequential", precision: 8, sof: 0xcd, name: "SOF13 算术差分顺序" },
  { mode: "hier-arith-progressive", precision: 8, sof: 0xce, name: "SOF14 算术差分渐进" },
  { mode: "hier-arith-lossless", precision: 8, sof: 0xcf, name: "SOF15 算术差分无损" },
];

test("13 个 SOF：每一个都有一份真实文件能解出来，且标记集合与支持判据一致", () => {
  const seen: number[] = [];
  for (const row of SOF_MATRIX) {
    const src = row.precision === 8 ? hardGray(8) : hardGray(12);
    const d = mustDecode(encodeJpeg(src, spec(1, row.precision, row.mode, 90)));
    assert.equal(d.jpeg.sof, row.sof, `${row.name}：文件解出来是 0x${d.jpeg.sof.toString(16)}，不是 0x${row.sof.toString(16)}`);
    assert.equal(d.width, W, `${row.name}：宽度被解错`);
    assert.equal(d.height, H, `${row.name}：高度被解错`);
    assert.ok(d.pixels.byteLength > 0, `${row.name}：解出来了但没有像素`);
    // 与"支持判据"必须同源：支持 = 能解，不能出现"判据说支持、解码器不认"或反过来
    const s = checkProcessSupport(row.sof, row.precision);
    assert.equal(s.ok, true, `${row.name}：checkProcessSupport 说不能用 —— ${s.reason ?? ""}`);
    seen.push(row.sof);
  }

  // 13 个标记必须互不相同，且正好是"13 个"
  const uniq = [...new Set(seen)].sort((a, b) => a - b);
  assert.deepEqual(
    uniq,
    [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf],
    "SOF 覆盖集合变了：要么少实现了一个，要么放进来了一个不在 T.81 13 个里的标记",
  );
  assert.equal(seen.length, 13, `矩阵里有 ${seen.length} 行，应该是 13（有重复模式就是没真覆盖）`);
});

test("13 个 SOF：不是 SOF 的标记不能被当成过程接受（0xC4/0xC8/0xCC 是别的段）", () => {
  // 0xC4 = DHT、0xC8 = JPG（保留）、0xCC = DAC、0xDC = DNL、0xDD = DRI
  for (const notSof of [0xc4, 0xc8, 0xcc, 0xdc, 0xdd]) {
    const s = checkProcessSupport(notSof, 8);
    assert.equal(s.ok, false, `0x${notSof.toString(16)} 不是 SOF，支持判据不能放行`);
  }
  // 精度边界：DCT 只允许 8/12，无损允许 2..16
  assert.equal(checkProcessSupport(0xc0, 10).ok, false, "SOF0 的精度 10 位必须拒绝（DCT 只有 8/12）");
  assert.equal(checkProcessSupport(0xc3, 2).ok, true, "SOF3 的 2 位必须接受（无损范围 2..16）");
  assert.equal(checkProcessSupport(0xc3, 1).ok, false, "SOF3 的 1 位必须拒绝");
  assert.equal(checkProcessSupport(0xc3, 17).ok, false, "SOF3 的 17 位必须拒绝");
});

// ------------------------------------------------------------ ⑨ 随机尺寸 × 全模式

/**
 * 固定尺寸（40×24）的用例覆盖不到"边块补齐"的绝大多数形状：
 * MCU 宽 16、块宽 8，只有 w/h 落在特定余数上时才会走到"最后一个块只用了一部分"。
 *
 * ★ 之前那条"窄图"缺陷（色度只剩 2 个样本时 libjpeg 退回复制）就是只在 3×97 上可见，
 *   固定尺寸的用例一张都碰不到 —— 所以这里把尺寸本身随机化，并且在**同一尺寸**上
 *   把全部 12 种模式跑一遍：
 *     · 无损四种：必须逐样本相等（无损没有"取整容差"这个借口）
 *     · 有损八种：同一份系数、只是扫描组织不同 ⇒ 必须**逐字节相同**
 *   "逐字节相同"这条不需要任何阈值，也正因如此它能在任意尺寸上都成立。
 */
test("随机尺寸 × 12 种模式：无损逐样本相等，有损跨模式逐字节相同", () => {
  let seed = 0x9e3779b9;
  const rnd = (): number => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };

  const samples = (w: number, h: number, precision: number, components: 1 | 3, hard: boolean): Uint16Array => {
    const max = maxOf(precision);
    const n = components === 1 ? w * h : w * h * 3;
    const a = new Uint16Array(n);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        const o = components === 1 ? y * w + x : (y * w + x) * 3;
        for (let c = 0; c < components; c++) {
          a[o + c] = hard
            ? Math.round((((x * 7 + y * 13 + c * 29) % 97) / 96) * max)
            : Math.round((((Math.sin(x * 0.2 + c) + Math.cos(y * 0.17 + c) + 2) / 4) * max));
        }
      }
    }
    return a;
  };

  // ★ 分层的参考帧取 1/2 分辨率，所以**编码器**要求宽高都是偶数（它会直接抛错）。
  //   奇数尺寸因此只能跑单帧模式 —— 这是编码器的限制，不是解码器的。
  //   （真实世界也没有任何工具能产奇数尺寸的分层 JPEG，所以这里没有语料可补。）
  const LOSSLESS_PLAIN: readonly JpegMode[] = ["lossless", "arith-lossless"];
  const LOSSLESS_HIER: readonly JpegMode[] = ["hier-lossless", "hier-arith-lossless"];
  // ★ 有损要分两组比，不能八种一起比 —— 这是这条判据第一次跑就纠正了我一个想当然：
  //   "同一份源、同一套量化表 ⇒ 系数相同 ⇒ 像素必须相同"只对**同一帧结构**成立。
  //   分层图有两帧：帧0 是 1/2 分辨率的独立编码（自己过一遍量化），帧1 编码的是
  //   "全分辨率下、扣掉重建后参考帧"的差分。参考帧的量化误差不可能被差分帧完全补回来，
  //   所以分层重建本来就**不等于**单帧重建。
  //   实测（26×22 / 4:2:0 / q80，与源比）：baseline max=16 mean=2.08，hier max=9 mean=2.04 ——
  //   分层反而更好（多了一次细化），差的是"路径"不是"质量"。
  const PLAIN_LOSSY: readonly JpegMode[] = ["baseline", "progressive", "arith-sequential", "arith-progressive"];
  const HIER_LOSSY: readonly JpegMode[] = [
    "hier-sequential",
    "hier-progressive",
    "hier-arith-sequential",
    "hier-arith-progressive",
  ];

  const sizes: Array<[number, number]> = [];
  for (let i = 0; i < 14; i++) sizes.push([1 + Math.floor(rnd() * 33), 1 + Math.floor(rnd() * 33)]);
  // 手工补几个"余数边界"：1、8、9、15、16、17 宽/高都出现过至少一次
  sizes.push([1, 17], [17, 1], [8, 9], [9, 8], [16, 16], [17, 17], [15, 31], [33, 1]);

  for (const [w, h] of sizes) {
    const precision: 8 | 12 = rnd() < 0.5 ? 8 : 12;
    const components: 1 | 3 = rnd() < 0.5 ? 1 : 3;
    const tag = `${w}×${h} ${precision}bit ${components === 1 ? "gray" : "rgb"}`;

    // ---- 无损：逐样本相等
    const even = w % 2 === 0 && h % 2 === 0;
    const losslessSrc = samples(w, h, precision, components, true);
    for (const mode of even ? [...LOSSLESS_PLAIN, ...LOSSLESS_HIER] : LOSSLESS_PLAIN) {
      const d = mustDecode(encodeJpeg(losslessSrc, { width: w, height: h, components, precision, mode }));
      assert.equal(d.width, w, `${tag} ${mode}：宽度`);
      assert.equal(d.height, h, `${tag} ${mode}：高度`);
      const back = backToNative(d, components, precision, w, h);
      const st = diffStat(losslessSrc, back);
      assert.equal(st.max, 0, `${tag} ${mode}：无损差 ${st.max}（首个偏差：${st.detail}）`);
    }

    // ---- 有损：同一帧结构内，扫描组织不同但系数相同 ⇒ 重建必须逐字节相同
    const lossySrc = samples(w, h, precision, components, false);
    const subsampling = components === 1 ? "444" : rnd() < 0.5 ? "444" : "420";
    const encode = (mode: JpegMode, quality = 80, sub: "444" | "420" | "422" = subsampling): Uint8Array =>
      encodeJpeg(lossySrc, { width: w, height: h, components, precision, mode, quality, subsampling: sub });

    const groups: ReadonlyArray<readonly [string, readonly JpegMode[], string]> = even
      ? [
          ["单帧", PLAIN_LOSSY, "baseline"],
          ["分层", HIER_LOSSY, "hier-sequential"],
        ]
      : [["单帧", PLAIN_LOSSY, "baseline"]];
    for (const [groupName, group, anchor] of groups) {
      const base = mustDecode(encode(anchor as JpegMode));
      for (const mode of group) {
        const d = mustDecode(encode(mode));
        assert.equal(
          diffBytes(base.pixels16!, d.pixels16!),
          0,
          `${tag}：${groupName}组里 ${mode} 与 ${anchor} 解出的像素不同 —— 系数相同，重建必须相同（subsampling=${subsampling}）`,
        );
      }
    }

    // ---- 绝对量级的锚：4:4:4 + q100 时量化表全 1，解码结果必须贴着源
    if (components === 3) {
      // ★ 这里必须**强制 4:4:4**：随机挑中的可能是 4:2:0，那样"偏离源"里混进了色度下采样
      //   的损失（实测能到 7 级），量的就不是解码器了。判据要量的东西必须唯一。
      const d = mustDecode(encode("baseline", 100, "444"));
      const back = backToNative(d, 3, precision, w, h);
      const st = diffStat(lossySrc, back);
      assert.ok(
        st.max <= 3,
        `${tag}：4:4:4 q100 的解码结果偏离源 ${st.max} 级 > 3（首个偏差：${st.detail}）—— ` +
          `上面的"跨模式相同"只证明自洽，这条才证明它真的贴着源`,
      );
    }
  }
});
