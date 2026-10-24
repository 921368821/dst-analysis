/**
 * L4 · JPEG · 12 位 DCT 的**外部金标**（ffmpeg 独立实现）
 *
 * ★ 这一组判据补的是哪一段证据链
 * ----------------------------
 * 到目前为止 JPEG 的外部参照有两根柱子：
 *   ① Pillow / libjpeg-turbo 编的 8 位流 → 我们解（17 例语料 + 1420 例网格扫描）
 *   ② 我们编的流 → libjpeg-turbo 解（6 例自产哈夫曼 + 算术/4 分量反向）
 * 这两根都**只覆盖 8 位**。12 位 DCT 此前只有"跨精度锚定"一根间接的柱子：
 * 8 位金标像素 → 12 位编码 → 解回 → 降 8 位必须落回原像素。
 * 跨精度锚定的硬伤是：**12 位那一段的编码器和解码器都是我们自己写的**。
 * 若两边对"12 位电平位移该加 2^11=2048 还是 128"理解同错，回环永远是绿的 ——
 * 这正是 8 位完全看不出来、12 位整幅塌陷的那类错误（变异 M50 就是它）。
 *
 * ffmpeg 的 mjpeg 解码器是独立实现（不基于 libjpeg），并且认 12 位（SOF1 + P=12）。
 * 拿它当参照之后，链条变成两条互相独立的路：
 *
 *   源样本 ──我们的编码器──▶ .jpg ──我们的解码器──▶ 像素A
 *                              └────ffmpeg 解码───▶ 像素B（金标）
 *
 *   · 像素B vs 源 = 0..2 级 ⇒ 编码器把源**正确写进了合规流**（ffmpeg 认同）
 *   · 像素A vs 像素B = 0..1 级 ⇒ 解码器与 ffmpeg 理解一致
 * 任何"编解码同错"都会让第一条爆掉 —— 因为错的那份流 ffmpeg 不会照着我们的理解解。
 *
 * ★ 这个判据不能证明什么（写在 ADR-0009 ⑥-g，不含糊）
 *   ffmpeg 与 libjpeg 都是"大体按 T.81 实现"，两家都可能对某个细节同样偏离；
 *   这一组只覆盖 4:4:4 与灰度，4:2:0 的色度上采样在 ffmpeg 侧归 swscale，
 *   比出来是"libjpeg 的 fancy 三角 vs swscale"（12 位 4:2:0 实测差 177 级），
 *   那个数字与我们的解码器无关，所以不纳入。算术编码 ffmpeg 不支持，也不纳入。
 *
 * ★ 为什么金标文件是"裸 u16"而不是 PNG：ffmpeg 落盘时按 `gray` / `gray12le` /
 *   `rgb48le` **原生位打包**输出，数值就是原生样本值，不经过任何缩放；
 *   存 PNG 会再引入一次编码/解码，把"金标"变成"我们另一个解码器的输出"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import { decodeJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";
import { encodeJpeg } from "../tools/jpeg-encode.ts";
import { FF_GOLD_CASES, FF_GOLD_DIR, ffGoldTolerance } from "../tools/jpeg-ff-gold-cases.ts";

const ROOT = fileURLToPath(new URL("../../", import.meta.url));
const DIR = join(ROOT, FF_GOLD_DIR);

/** 读 u16 小端。★ 不能用 `new Uint16Array(buf.buffer)`：Node 的 Buffer 是池化的，byteOffset 不为 0。 */
function readU16(path: string): Uint16Array {
  const b = readFileSync(path);
  assert.equal(b.length % 2, 0, `${path} 的字节数不是偶数，不可能是 u16 数组`);
  const copy = Uint8Array.from(b);
  return new Uint16Array(copy.buffer, 0, copy.length / 2);
}

interface Meta {
  readonly cases: Array<{
    name: string;
    width: number;
    height: number;
    components: number;
    precision: number;
    precisionMax: number;
    pixFmt: string;
    samples: number;
    maxDiffGoldVsSource: number;
    meanDiffGoldVsSource: number;
    tolerance: number;
  }>;
}

const meta = JSON.parse(readFileSync(join(DIR, "_ffgold.json"), "utf8")) as Meta;

/** 最大绝对差；`shift` 用来做反退化自检（把金标整体抬一档，差必须跟着抬）。 */
function maxDiff(a: ArrayLike<number>, b: ArrayLike<number>, limit: number, shift = 0): number {
  assert.equal(a.length, b.length, `样本数不符：${a.length} vs ${b.length}`);
  let worst = 0;
  for (let i = 0; i < a.length; i++) {
    const v = Math.min(limit, b[i]! + shift);
    const d = Math.abs(a[i]! - v);
    if (d > worst) worst = d;
  }
  return worst;
}

test("ffmpeg 金标：语料与清单自洽（少一例就是少一块证据，必须炸）", () => {
  assert.ok(meta.cases.length >= 12, `金标只有 ${meta.cases.length} 例`);
  assert.deepEqual(
    meta.cases.map((c) => c.name).sort(),
    FF_GOLD_CASES.map((c) => c.name).sort(),
    "生成器写出的清单与案例表不一致",
  );
  // 12 位必须是主角：没有 12 位这一组就退化成"8 位的第二个参照"，那不值 119 KiB
  const p12 = meta.cases.filter((c) => c.precision === 12);
  assert.ok(p12.length >= 5, `12 位案例只有 ${p12.length} 例`);
  // 四条路径都要有，缺一条就等于那个路径的 12 位行为没人管
  for (const need of ["baseline", "progressive", "restart", "lossless"]) {
    assert.ok(
      p12.some((c) => c.name.includes(need)),
      `12 位缺少 ${need} 路径的案例`,
    );
  }
  for (const c of FF_GOLD_CASES) {
    assert.ok(c.samples.length > 0, `${c.name}：源样本是空的`);
    assert.equal(c.samples.length, c.width * c.height * c.components, `${c.name}：源样本数与几何不符`);
  }
});

test("ffmpeg 金标：12 位流解出来必须落在 12 位域（存成 8 位缩放就是 0..255）", () => {
  for (const c of meta.cases) {
    const gold = readU16(join(DIR, `${c.name}.ff.u16`));
    assert.equal(gold.length, c.samples, `${c.name}：金标样本数 ${gold.length} ≠ ${c.samples}`);
    let lo = 65535;
    let hi = 0;
    for (const v of gold) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    assert.ok(hi <= c.precisionMax, `${c.name}：金标最大值 ${hi} 超出 ${c.precision} 位量程 ${c.precisionMax}（量程/位打包搞错了）`);
    assert.ok(lo >= 0, `${c.name}：金标出现负值`);
    if (c.precision === 12) {
      // ★ 这一条挡的是"把 12 位金标存成满 16 位或 8 位缩放"：12 位源里既有贴 0 也有贴 4095 的像素
      assert.ok(hi > 4095 * 0.9, `${c.name}：12 位金标最大值只有 ${hi}，源本身贴着量程上沿，不该这么小`);
      assert.ok(hi > 255, `${c.name}：12 位金标最大值 ${hi} ≤ 255 —— 看起来是 8 位数据`);
    }
    // 金标不能是常数值（全 0/全 max 的"金标"能让任何解码器都通过）
    assert.ok(hi - lo > c.precisionMax * 0.5, `${c.name}：金标动态范围只有 ${hi - lo}，不足以判别`);
  }
});

test("ffmpeg 金标：编码器把源写对了（金标 vs 源 ≤ 容差）", () => {
  for (const c of FF_GOLD_CASES) {
    const m = meta.cases.find((x) => x.name === c.name);
    assert.ok(m !== undefined, `${c.name}：清单里没有这一例`);
    const gold = readU16(join(DIR, `${c.name}.ff.u16`));
    const got = maxDiff(gold, c.samples, m.precisionMax);
    assert.ok(
      got <= m.tolerance,
      `${c.name}：ffmpeg 解我们的流，与源最大差 ${got} 级（容差 ${m.tolerance}）—— ` +
        "说明编码器写进流的样本与源不符（电平位移/量程钳位/量化缩放）",
    );
    // 清单里的数字必须是真算出来的，不能是"写死的一个好看值"
    assert.equal(
      m.maxDiffGoldVsSource,
      got,
      `${c.name}：清单记的 maxDiffGoldVsSource=${m.maxDiffGoldVsSource}，实测 ${got} —— 清单已过期`,
    );
  }
});

test("ffmpeg 金标：我们的解码器必须与 ffmpeg 逐样本一致（12 位 DCT 的外部参照）", () => {
  /** 每例的实测差，循环后统一做"金标没被替换成我们自己输出"的核查 */
  const measured: Array<{ name: string; precision: number; diff: number; lossless: boolean }> = [];
  for (const c of FF_GOLD_CASES) {
    const m = meta.cases.find((x) => x.name === c.name);
    assert.ok(m !== undefined);
    const bytes = new Uint8Array(readFileSync(join(DIR, `${c.name}.jpg`)));
    const r = decodeJpeg(bytes, { keep16: true });
    assert.ok(r.ok, `${c.name}：解码失败 ${r.ok ? "" : r.error.message}`);
    const d = r.value;
    assert.equal(d.width, c.width, `${c.name}：宽不符`);
    assert.equal(d.height, c.height, `${c.name}：高不符`);
    const p16 = d.pixels16;
    assert.ok(p16 !== undefined, `${c.name}：keep16 必须给 pixels16`);

    // pixels16 是**满 16 位量程**，金标是**原生精度域** —— 先换到同一域再比，
    // 否则比的是"满量程 vs 位对齐"两种缩放，差值没有意义（这个坑踩过一次）。
    const ch = c.components;
    const n = c.width * c.height * ch;
    const ours = new Uint16Array(n);
    for (let i = 0; i < c.width * c.height; i++) {
      for (let k = 0; k < ch; k++) {
        ours[i * ch + k] = Math.round((p16[i * 4 + k]! * m.precisionMax) / 65535);
      }
    }
    const gold = readU16(join(DIR, `${c.name}.ff.u16`));
    const got = maxDiff(ours, gold, m.precisionMax);
    assert.ok(
      got <= m.tolerance,
      `${c.name}：我们与 ffmpeg 最大差 ${got} 级（容差 ${m.tolerance}）—— ` +
        "两个独立实现对同一份流的理解不一致，先确认不是自己的 IDCT/电平位移/上采样相位问题",
    );

    // ★ 反退化自检：把金标整体抬 (容差 + 1) 级，判据必须变红。
    //   没有这一条，把容差写成 65535 也能让上面全绿 —— 判据就变成了装饰。
    const bumped = maxDiff(ours, gold, m.precisionMax, m.tolerance + 1);
    assert.ok(
      bumped > m.tolerance,
      `${c.name}：金标整体 +${m.tolerance + 1} 级后最大差仍只有 ${bumped}，比较器或容差失效了`,
    );

    measured.push({ name: c.name, precision: c.precision, diff: got, lossless: c.name.includes("lossless") });
  }

  // ★ 反"金标被替换"核查：两套独立实现在**全部**有损案例上逐样本完全相同是不合理的，
  //   那更像是 gold 文件被写成了我们自己的解码输出（金标一旦变成"自证"，整组判据归零）。
  //   注意**不能要求每一例都非 0** —— 8 位 + 内容温和时，两个 IDCT 的取整恰好一致是正常的
  //   （实测 gray8-odd 就是 0 级）。所以按"至少有一例"来判，并单独要求 12 位里也有一例。
  const lossy = measured.filter((x) => !x.lossless);
  assert.ok(
    lossy.some((x) => x.diff > 0),
    "所有有损案例都与 ffmpeg 差 0 级 —— 金标极可能就是我们自己的解码输出",
  );
  assert.ok(
    lossy.some((x) => x.precision === 12 && x.diff > 0),
    "12 位有损案例全部与 ffmpeg 差 0 级 —— 12 位这一段没有第三方参与，金标可能是自证的",
  );
});

test("ffmpeg 金标：语料文件与当前编码器一致（编码器改了就必须重生成，否则金标在描述旧流）", () => {
  // 这条不需要 ffmpeg —— 它只重跑编码器比字节。
  // 目的：保证 fixtures 里的 .jpg 真的是**现在这份编码器**产出的，
  // 否则"gold = ffmpeg 解我们的流"这句话就只是历史陈述。
  const stale: string[] = [];
  for (const c of FF_GOLD_CASES) {
    const fresh = encodeJpeg(c.samples, c.spec);
    const onDisk = new Uint8Array(readFileSync(join(DIR, `${c.name}.jpg`)));
    if (fresh.length !== onDisk.length || fresh.some((b, i) => b !== onDisk[i])) {
      stale.push(c.name);
    }
  }
  assert.deepEqual(
    stale,
    [],
    `以下语料与当前编码器的产流不一致：${stale.join(", ")}\n` +
      "  跑 `python tools/jpeg-ffmpeg-gold.py` 重新生成（需要 ffmpeg）。",
  );
});

test("ffmpeg 金标：容差表本身受约束（防止把阈值悄悄放宽到没意义）", () => {
  for (const c of FF_GOLD_CASES) {
    const tol = ffGoldTolerance(c);
    // 8 位单通道的满量程是 255，12 位是 4095；容差按"级"给，不能跟着位深放大。
    assert.ok(tol <= 8, `${c.name}：容差 ${tol} 级太宽，够藏下真实的取整/相位错误`);
    const m = meta.cases.find((x) => x.name === c.name);
    assert.ok(m !== undefined);
    assert.equal(m.tolerance, tol, `${c.name}：清单里的容差 ${m.tolerance} 与阈值函数 ${tol} 不一致`);
  }
});
