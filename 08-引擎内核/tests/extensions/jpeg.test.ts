/**
 * L4 · JPEG 解码 · 外部金标 + 结构性不变量 + 拒绝路径 + 消费方接线
 *
 * ★ 为什么 JPEG 的判据必须"比容差"而不是"逐字节"：
 *   JPEG 是**有损**格式，不同实现的差异来自两处——IDCT 的中间精度、色度上采样滤波器。
 *   这两处规范只给了"足够接近"的空间，所以 libjpeg 与任何自研解码器都不会给出
 *   同一位流。要求逐字节相同，等于要求"重写得和 libjpeg 一模一样"，做不到也没意义。
 *   于是判据改成：**与 libjpeg-turbo 的每个通道差异有上限**（max/mean 两个数），
 *   上限写进 manifest、来自实测（见 tools/make-jpeg-fixtures.py），不是拍脑袋的常数。
 *
 * ★ 那条容差不允许"宽到永远绿"：
 *   `JPEG 判据自检` 把金标整体 +（maxAbs+1），再跑一遍同一个比较器，必须**判失败**。
 *   没有这条，`maxAbs` 被谁改成 255 都能全绿，而"全绿"就不再是证据。
 *
 * ★ 金标怎么来的（不是我们自己解出来的）：
 *   `tools/make-jpeg-fixtures.py` 用 **Pillow 13（底层 libjpeg-turbo）** 编码出 14 个用例，
 *   再用 Pillow 把同一批文件解成 `.rgba` 存为金标，同时记录 `maxAbs/meanAbs/sha256`。
 *   测试运行时**不依赖 Pillow**，只读固定字节。
 *
 * ★ 除了"和金标像"，还有三条**不依赖任何外部实现**的不变量，它们才是真正钉住实现的：
 *   ① 同一张源图分别编成 baseline / 渐进 / 带重启 / 渐进+重启，必须解出**逐字节相同**的像素
 *      （系数相同 ⇒ 重建必须相同；任何一处熵解码错位都会破坏它）；
 *   ② 灰度图的 R=G=B；
 *   ③ EXIF `orientation:"apply"` 的结果必须等于金标旋转 90° 顺时针。
 *   金标能证明"和 libjpeg 一致"，这三条能证明"我们自己是自洽的"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import type { EngineError, Result } from "../../src/foundation/result.ts";
import type { DecodedJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";
import { decodeJpeg, isJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";
import type { DecodedPng } from "../../src/extensions/asset-import/decode/png.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";
import { decodeImage, sniffImageFormat } from "../../src/extensions/asset-import/decode/image.ts";
import { encodeJpeg } from "../tools/jpeg-encode.ts";
import type { EncodeSpec } from "../tools/jpeg-encode.ts";
import { buildAtlasFromSources, type AtlasSource } from "../../src/extensions/render/atlas-from-assets.ts";
import { MemoryFileSystem } from "../../src/backends/fs-memory/fs.ts";
import { Logger, LogLevel } from "../../src/foundation/log/logger.ts";
import { AssetDatabase } from "../../src/core/asset/asset.ts";
import { ImporterRegistry } from "../../src/extensions/asset-import/importer.ts";
import { AssetImportPipeline } from "../../src/extensions/asset-import/pipeline.ts";
import { textureImporter } from "../../src/extensions/asset-import/importers/texture.ts";
import { ImportedTexture, createImportLoaders } from "../../src/extensions/asset-import/loaders.ts";

const DIR = fileURLToPath(new URL("../fixtures/jpeg/", import.meta.url));
const PNG_DIR = fileURLToPath(new URL("../fixtures/png/", import.meta.url));

interface Fixture {
  readonly name: string;
  readonly file: string;
  readonly golden: string;
  readonly width: number;
  readonly height: number;
  readonly mode: string;
  readonly sha256: string;
  readonly goldenSha256: string;
  readonly maxAbs: number;
  readonly meanAbs: number;
  readonly note: string;
  readonly exifOrientation: number;
  readonly pillow_sampling: number;
}

interface WideFixture {
  readonly name: string;
  readonly file: string;
  readonly golden16: string;
  readonly width: number;
  readonly height: number;
  readonly channels: number;
  readonly precision: number;
  readonly sha256: string;
  readonly goldenSha256: string;
  readonly note: string;
}

const manifest = JSON.parse(readFileSync(DIR + "manifest.json", "utf8")) as {
  readonly generator: string;
  readonly reference: string;
  readonly losslessReference?: string;
  readonly cases: readonly Fixture[];
  readonly wide?: readonly WideFixture[];
};

const fixtures = manifest.cases;
const wideFixtures = manifest.wide ?? [];

function read(name: string): Uint8Array {
  return new Uint8Array(readFileSync(DIR + name));
}

function readPng(name: string): Uint8Array {
  return new Uint8Array(readFileSync(PNG_DIR + name));
}

function sha256b(b: Uint8Array): string {
  return createHash("sha256").update(b).digest("hex");
}

function must(bytes: Uint8Array, opts?: Parameters<typeof decodeJpeg>[1]): DecodedJpeg {
  const r = decodeJpeg(bytes, opts);
  if (!r.ok) throw new Error(`期望成功，实际失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function mustFail(r: Result<unknown, EngineError>): EngineError {
  if (r.ok) throw new Error("期望失败，实际成功 —— 这条判据保护的缺陷又回来了");
  return r.error;
}

function fixture(name: string): Fixture {
  const f = fixtures.find((x) => x.name === name);
  assert.ok(f !== undefined, `manifest 里找不到用例 ${name}`);
  return f;
}

/** 12/16 位用例在 manifest.wide 里（金标是 .u16 原生量程，不进 RGBA8 比较）。 */
function wideFixture(name: string): WideFixture {
  const f = wideFixtures.find((x) => x.name === name);
  assert.ok(f !== undefined, `manifest.wide 里找不到用例 ${name}`);
  return f;
}

/** 逐通道差异统计。`differing` 用来区分"差在几百个像素上"和"整幅都差"。 */
interface Diff {
  readonly max: number;
  readonly mean: number;
  readonly differing: number;
}

function diff(a: Uint8Array, b: Uint8Array): Diff {
  assert.equal(a.length, b.length, "比较的两份像素长度不同（尺寸算错了）");
  let max = 0;
  let sum = 0;
  let differing = 0;
  for (let i = 0; i < a.length; i++) {
    const d = Math.abs(a[i]! - b[i]!);
    if (d !== 0) differing++;
    if (d > max) max = d;
    sum += d;
  }
  return { max, mean: sum / a.length, differing };
}

// ---------------------------------------------------------------- 语料自检

test("JPEG 语料：manifest 记录了外部生成器与参考实现", () => {
  assert.match(manifest.generator, /^Pillow \d+\.\d+/, "必须记录金标由哪个外部实现产出");
  assert.equal(manifest.reference, "libjpeg-turbo");
  assert.ok(fixtures.length >= 30, `用例只有 ${fixtures.length} 个，少了说明生成器坏了`);
  // 覆盖度：三种过程 + 三种子采样 + 灰度 + 4 分量 + EXIF + 退化尺寸，缺一类就是"报告支持"里少一块
  const names = fixtures.map((f) => f.name).join(",");
  for (const need of ["progressive", "restart", "gray", "cmyk", "exif", "tiny", "422", "420", "444", "narrow", "flat", "selfenc", "arith"]) {
    assert.ok(names.includes(need), `语料里缺少 ${need} 这一类 —— 覆盖不全就等于没测到`);
  }
});

test("JPEG 语料：磁盘字节与金标的 sha256 都和 manifest 一致（防语料被悄悄替换）", () => {
  const bad: string[] = [];
  for (const f of fixtures) {
    const src = sha256b(read(f.file));
    const gold = sha256b(read(f.golden));
    if (src !== f.sha256) bad.push(`${f.file} 源字节`);
    if (gold !== f.goldenSha256) bad.push(`${f.golden} 金标`);
  }
  assert.deepEqual(bad, [], "语料变了却没更新 manifest —— 容差是按旧的实测算的，现在已经没意义了");
});

// ---------------------------------------------------------------- 外部金标

for (const f of fixtures) {
  test(`JPEG 金标：${f.name} 与 Pillow(libjpeg-turbo) 差异 ≤ ${f.maxAbs}/${f.meanAbs}`, () => {
    const golden = read(f.golden);
    const d = must(read(f.file));

    assert.equal(d.width, f.width, "宽度必须等于 SOF 声明值");
    assert.equal(d.height, f.height, "高度必须等于 SOF 声明值");
    assert.equal(d.pixels.byteLength, f.width * f.height * 4, "必须是紧凑的 RGBA8（少了会错行、多了会越界）");
    // 输出契约：JPEG 没有 alpha 通道，声称有 alpha 就是撒谎
    assert.equal(d.hasAlpha, false);
    assert.equal(d.colorType, 2);
    assert.equal(d.bitDepth, 8);
    assert.equal(d.interlaced, false, "JPEG 没有隔行扫描，这个字段必须是 false 而不是沿用 PNG 的默认值");

    const st = diff(d.pixels, golden);
    assert.ok(
      st.max <= f.maxAbs,
      `${f.name} 单通道最大差 ${st.max} > ${f.maxAbs}（${f.note}）—— 差异集中在 ${st.differing} 个样本上`,
    );
    assert.ok(st.mean <= f.meanAbs, `${f.name} 平均差 ${st.mean.toFixed(3)} > ${f.meanAbs}`);
  });

  test(`JPEG 输出：${f.name} 不是常量图（否则"全 128"也能通过容差判据）`, () => {
    const d = must(read(f.file));
    if (f.width * f.height < 4) return; // 1×1 只有一个像素，常量是合法的
    // 只看 R 通道：真图像一定有色阶分布，纯色/纯灰不会有
    const hist = new Set<number>();
    for (let i = 0; i < d.pixels.length; i += 4) hist.add(d.pixels[i]!);
    assert.ok(hist.size >= 4, `${f.name} 的 R 通道只有 ${hist.size} 种取值 —— 疑似解成色块`);
  });

  test(`JPEG 输出：${f.name} alpha 恒 255（不透明，不引用未初始化内存）`, () => {
    const d = must(read(f.file));
    for (let i = 3; i < d.pixels.length; i += 4) {
      if (d.pixels[i] !== 255) assert.fail(`第 ${i} 个样本 alpha=${d.pixels[i]}，JPEG 不该有透明像素`);
    }
  });
}

// ------------------------------------------------------- 12/16 位逐位相等

test("JPEG 语料：无损金标来自 liblj92（不是自产自销）", () => {
  assert.match(manifest.losslessReference ?? "", /^liblj92 /, "必须记录无损语料由哪个外部实现产出");
  assert.ok(wideFixtures.length >= 2, `12/16 位用例只有 ${wideFixtures.length} 个`);
  // ★ 精度要**逐个**覆盖 8..16，不能只测端点：`2^(P-1)` 的位移和 `maxval`
  //   在 9/10/11/13/14/15 上是"同一条公式、不同的数"，只测 8/12/16 时这些数从没被算过。
  const precs = wideFixtures.map((w) => w.precision).sort((a, b) => a - b);
  assert.deepEqual(precs, [9, 10, 11, 12, 13, 14, 15, 16], "无损宽位深语料必须是 9..16 各一张");
});

test("JPEG 语料：12/16 位的 .u16 金标 sha256 与 manifest 一致（防被替换）", () => {
  const bad: string[] = [];
  for (const w of wideFixtures) {
    if (sha256b(read(w.file)) !== w.sha256) bad.push(`${w.file} 源字节`);
    if (sha256b(read(w.golden16)) !== w.goldenSha256) bad.push(`${w.golden16} 金标`);
  }
  assert.deepEqual(bad, []);
});

for (const w of wideFixtures) {
  test(`JPEG 无损 ${w.precision} 位：${w.name} 逐位相等（max=0，无损没有"取整容差"这个借口）`, () => {
    const d = must(read(w.file), { keep16: true });

    assert.equal(d.width, w.width);
    assert.equal(d.height, w.height);
    assert.equal(d.jpeg.precision, w.precision, "精度必须如实上报，12 位不能写成 8");
    assert.equal(d.jpeg.lossless, true, `过程必须是无损，实际 ${d.jpeg.process}`);
    assert.equal(d.bitDepth, w.precision, "bitDepth 是**源精度**（与 PNG 16 位同义），不是输出容器宽度");

    const p16 = d.pixels16;
    assert.ok(p16 !== undefined, "keep16: true 时必须给 pixels16 —— 否则 12 位精度到手又被丢掉");
    assert.equal(p16.length, w.width * w.height * 4, "pixels16 必须是紧凑 RGBA16");

    const gold = read(w.golden16);
    const gv = new Uint16Array(gold.buffer, gold.byteOffset, gold.byteLength / 2);
    assert.equal(gv.length, w.width * w.height * w.channels);

    // 金标是 liblj92 解出的**原生量程**样本（12 位就是 0..4095，16 位是 0..65535），
    // 不做任何缩放 —— 缩放公式写在解码器的契约里（types.ts：映射到满 16 位量程），
    // 所以这里按同一条契约换算一次再比，比的是"两边样本是否相同"，不是"映射是否好看"。
    const maxval = (1 << w.precision) - 1;
    const toFull = (v: number): number => Math.round((v * 65535) / maxval);

    // 灰度：R=G=B=同一个样本，A=65535（不透明满量程）
    let worst = 0;
    let detail = "";
    for (let i = 0; i < w.width * w.height; i++) {
      const s = gv[i]!;
      for (let c = 0; c < 3; c++) {
        const dv = Math.abs(p16[i * 4 + c]! - toFull(s));
        if (dv > worst) {
          worst = dv;
          detail = `样本 ${i} 通道 ${c}：本地 ${p16[i * 4 + c]} vs 金标 ${s}（满量程 ${toFull(s)}）`;
        }
      }
      const da = Math.abs(p16[i * 4 + 3]! - 65535);
      if (da > worst) {
        worst = da;
        detail = `样本 ${i} 的 alpha=${p16[i * 4 + 3]}，应该是 65535`;
      }
    }
    assert.equal(worst, 0, `与 liblj92 的金标差 ${worst}（首个偏差：${detail}）—— 无损格式不允许任何偏差`);

    // 8 位视图必须是全精度的缩（不是"另算一遍"）：任何位深都满足 round(p16/257)
    for (let i = 0; i < p16.length; i++) {
      const want = Math.round(p16[i]! / 257);
      if (d.pixels[i] !== want) {
        assert.fail(`样本 ${i}: pixels=${d.pixels[i]} 而不是 round(pixels16/257)=${want}`);
      }
    }
  });

  test(`JPEG 无损 ${w.precision} 位：${w.name} 不给 keep16 时不产出 pixels16（省内存是默认）`, () => {
    const d = must(read(w.file));
    assert.equal(d.pixels16, undefined);
    assert.equal(d.jpeg.precision, w.precision, "不产出 16 位视图不影响精度上报");
  });
}

test("12 位 DCT：把外部 8 位金标喂进 12 位编码器，解回来必须落回同一批像素", () => {
  // ★ 12 位 DCT 是全项目唯一**没有任何外部实现**的路径（Pillow 是 8 位构建，
  //   liblj92 只管无损）。这里不假装找到了金标，而是把这条路径**绑到有金标的路径上**：
  //   取 Pillow 金标的像素当源 → 我们的编码器编成 12 位 → 我们的解码器解回来 → 降到 8 位，
  //   必须落回**同一批外部像素**。
  //
  //   能抓住的：电平位移写成 128、量程钳到 255、`toFull16` 的比例写错、
  //   12 位分支少乘/多乘一个系数 —— 这些都是"只在 12 位才犯"的错，8 位金标看不见
  //   （M47「颜色变换偏移写死 128」就是这个形状，只有 12 位判据能红）。
  //   抓不住的：与 8 位**共享**的那部分规范误读 —— 那部分由 8 位金标负责。
  //
  // ★ 为什么用 quality=100：量化表全 1 时 DCT 往返基本无损，
  //   于是这条判据量的就是"缩放/位移/钳位"这一层，而不是把量化误差也算进去。
  for (const [name, tol] of [["smooth-444", 1], ["edges-444", 1]] as const) {
    const f = fixture(name);
    const gold = read(f.golden);
    const W = f.width;
    const H = f.height;

    // 8 位 → 12 位：v*16+8 让 0..255 均匀铺到 (8..4088)，
    // 反变换 round(v12*255/4095) 正好回到 v（加上 8 那半格刚好抵消掉）
    const s12 = new Uint16Array(W * H * 3);
    for (let i = 0; i < W * H; i++) {
      for (let c = 0; c < 3; c++) s12[i * 3 + c] = gold[i * 4 + c]! * 16 + 8;
    }
    const bytes = encodeJpeg(s12, {
      width: W,
      height: H,
      components: 3,
      precision: 12,
      mode: "baseline",
      quality: 100,
      subsampling: "444",
    });
    const d = must(bytes, { keep16: true });
    assert.equal(d.jpeg.precision, 12, "12 位必须真的写成 SOF1 的 precision=12，而不是 8 位文件冒充");
    const p16 = d.pixels16;
    assert.ok(p16 !== undefined, "12 位必须给 pixels16，否则这条判据退化成比较两份 8 位");

    let worst = 0;
    let detail = "";
    for (let i = 0; i < W * H; i++) {
      for (let c = 0; c < 3; c++) {
        // pixels16 是满 16 位量程（契约见 types.ts），12 位样本先映射到 65535 再降回 8 位
        const back = Math.round((p16[i * 4 + c]! * 255) / 65535);
        const dv = Math.abs(back - gold[i * 4 + c]!);
        if (dv > worst) {
          worst = dv;
          detail = `像素 ${i} 通道 ${c}：回来是 ${back}，金标 ${gold[i * 4 + c]}`;
        }
      }
    }
    assert.ok(
      worst <= tol,
      `${name} 12 位往返后与 Pillow 金标差 ${worst} 级 > ${tol}（首个偏差：${detail}）` +
        `—— 12 位这条路径没有外部实现，它唯一的护栏就是"必须回到 8 位金标的同一批像素"`,
    );
  }
});

test("decodeImage 分发：12 位 JPEG 走统一入口也能拿到全精度（能力不只存在于 decodeJpeg）", () => {
  // ★ 这条盯的是"能力藏在直连函数里、走分发入口就丢"：
  //   调用方（浏览器烘焙、图集、编辑器预览）统一走 decodeImage，
  //   如果它不透传 keep16，那 12 位/16 位精度在真实链路上永远拿不到。
  const bytes = read(wideFixture("lossless-12").file);
  const r = decodeImage(bytes, { jpeg: { keep16: true } });
  assert.ok(r.ok, "按魔数分发必须把 12 位无损也认出来");
  const d = r.value as DecodedJpeg;
  assert.equal("jpeg" in d, true, "走 JPEG 路径就该带 jpeg 元信息");
  assert.equal(d.jpeg.precision, 12);
  assert.ok(d.pixels16 !== undefined, "decodeImage 没有把 keep16 透传下去 —— 12 位精度在这里被丢掉了");
  assert.equal(d.pixels16.length, d.width * d.height * 4);

  // 反例：不传 keep16 时应当没有 pixels16（默认省一半内存），但精度上报不变
  const r2 = decodeImage(bytes);
  assert.ok(r2.ok);
  const d2 = r2.value as DecodedJpeg;
  assert.equal(d2.pixels16, undefined);
  assert.equal(d2.jpeg.precision, 12);
});

test("JPEG 判据自检：把金标整体 +（容差+1）必须判失败（比较器不是恒绿）", () => {
  // 挑 maxAbs 最小的那条：如果连它都不失败，说明比较器/断言根本没生效
  const f = fixtures.reduce((a, b) => (a.maxAbs <= b.maxAbs ? a : b));
  const golden = Uint8Array.from(read(f.golden));
  const bump = f.maxAbs + 1;
  const shifted = golden.map((v) => (v + bump > 255 ? 255 : v + bump));

  const st = diff(shifted, golden);
  assert.equal(st.max, bump, "自检本身要成立：位移必须真的落在数据上");
  assert.ok(st.max > f.maxAbs, `比较器对 +${bump} 仍然判通过 —— 这条判据是恒绿的`);
  // 同时确认"原图"没被这一步污染
  assert.equal(diff(must(read(f.file)).pixels, golden).max <= f.maxAbs, true);
});

// ---------------------------------------------------------------- 结构信息

test("JPEG 结构：渐进 / 重启间隔 / 子采样 / 分量数 与文件真实内容一致", () => {
  const expect: ReadonlyArray<readonly [string, { prog: boolean; ri: number; sub: string; comp: number }]> = [
    ["smooth-444", { prog: false, ri: 0, sub: "4:4:4", comp: 3 }],
    ["smooth-420", { prog: false, ri: 0, sub: "4:2:0", comp: 3 }],
    ["photo-422", { prog: false, ri: 0, sub: "4:2:2", comp: 3 }],
    ["progressive-420", { prog: true, ri: 0, sub: "4:2:0", comp: 3 }],
    ["restart-420", { prog: false, ri: 1, sub: "4:2:0", comp: 3 }],
    ["restart-prog-420", { prog: true, ri: 1, sub: "4:2:0", comp: 3 }],
    ["gray", { prog: false, ri: 0, sub: "none", comp: 1 }],
    ["cmyk", { prog: false, ri: 0, sub: "4:4:4", comp: 4 }],
  ];
  for (const [name, e] of expect) {
    const j = must(read(fixture(name).file)).jpeg;
    assert.equal(j.progressive, e.prog, `${name} 的 progressive`);
    assert.equal(j.restartInterval, e.ri, `${name} 的 DRI（重启间隔）`);
    assert.equal(j.subsampling, e.sub, `${name} 的采样因子名`);
    assert.equal(j.components, e.comp, `${name} 的分量数`);
  }
});

test("JPEG 结构：EXIF Orientation 被解析出来（默认不应用）", () => {
  const j = must(read(fixture("exif-orient6").file)).jpeg;
  assert.equal(j.orientation, 6, "APP1 里的 0x0112 必须读出来 —— 读不到就会把竖拍照片当横的");
  // 没写 EXIF 的文件必须是 1，不能是 0 或 undefined
  assert.equal(must(read(fixture("smooth-444").file)).jpeg.orientation, 1);
});

test("JPEG 不变量：同源的 baseline / 渐进 / 重启 / 渐进+重启 解出逐字节相同的像素", () => {
  const group = ["progressive-420", "restart-420", "restart-prog-420"];
  // 前提守卫：Pillow 对这组文件给出的金标也必须相同，否则"同源"这个前提不成立了
  const golds = new Set(group.map((n) => fixture(n).goldenSha256));
  assert.equal(golds.size, 1, "这组语料已不是同一份系数 —— 先重新生成语料，再谈这条不变量");

  const base = must(read(fixture(group[0]!).file)).pixels;
  for (const name of group.slice(1)) {
    const other = must(read(fixture(name).file)).pixels;
    const st = diff(base, other);
    assert.equal(
      st.max,
      0,
      `${name} 与 ${group[0]} 差 ${st.max}（${st.differing} 个样本）—— 系数相同就必须重建出相同像素：` +
        "渐进式 AC 精修或重启区间的 DC 预测器复位出错了",
    );
  }
});

// ---------------------------------------------------------------- 分量/色彩

test("JPEG 灰度：R=G=B（三个通道都填亮度），且不是把 Y 丢在 R 通道里", () => {
  const d = must(read(fixture("gray").file));
  for (let i = 0; i < d.pixels.length; i += 4) {
    const [r, g, b] = [d.pixels[i]!, d.pixels[i + 1]!, d.pixels[i + 2]!];
    if (r !== g || g !== b) assert.fail(`第 ${i / 4} 个像素不是灰度：${r},${g},${b}`);
  }
});

test("JPEG CMYK：按反相语义还原（白纸仍是白的，不能解成负片）", () => {
  const f = fixture("cmyk");
  const d = must(read(f.file));
  const golden = read(f.golden);
  const meanOf = (b: Uint8Array): number => {
    let s = 0;
    for (let i = 0; i < b.length; i += 4) s += b[i]! + b[i + 1]! + b[i + 2]!;
    return s / ((b.length / 4) * 3);
  };
  const ours = meanOf(d.pixels);
  const theirs = meanOf(golden);
  assert.ok(
    Math.abs(ours - theirs) <= 2,
    `CMYK 平均亮度 ${ours.toFixed(1)} 与金标 ${theirs.toFixed(1)} 差太多 —— ` +
      "4 分量直通忘了反相时，整幅会变成负片（亮度差约 100，不会只差 2）",
  );
});

// ---------------------------------------------------------------- EXIF 旋转

test("JPEG EXIF：默认 ignore（宽高 = 文件声明值，像素与金标一致）", () => {
  const f = fixture("exif-orient6");
  const d = must(read(f.file));
  assert.equal(d.width, f.width);
  assert.equal(d.height, f.height);
  assert.ok(diff(d.pixels, read(f.golden)).max <= f.maxAbs, "不应用方向时，像素应与金标同向");
});

test("JPEG EXIF：orientation:'apply' 后宽高互换，且等于金标旋转 90° 顺时针", () => {
  const f = fixture("exif-orient6");
  const applied = must(read(f.file), { orientation: "apply" });
  assert.equal(applied.width, f.height, "Orientation=6 是 90° 旋转，宽高必须互换");
  assert.equal(applied.height, f.width);
  assert.equal(applied.pixels.byteLength, f.width * f.height * 4, "旋转不能改变像素数");

  // 金标是"未旋转"的原始像素；把它按 90° 顺时针转过来，应与 apply 的结果一致
  const golden = read(f.golden);
  const sw = f.width;
  const sh = f.height;
  const at = (buf: Uint8Array, w: number, x: number, y: number, c: number): number => buf[(y * w + x) * 4 + c]!;
  let max = 0;
  for (let y = 0; y < sw; y++) {
    for (let x = 0; x < sh; x++) {
      for (let c = 0; c < 4; c++) {
        // dst(x,y) = src(y, sh-1-x)：顺时针 90°
        const d = Math.abs(at(applied.pixels, sh, x, y, c) - at(golden, sw, y, sh - 1 - x, c));
        if (d > max) max = d;
      }
    }
  }
  assert.ok(max <= f.maxAbs, `旋转后与"金标顺时针 90°"最大差 ${max}（容差 ${f.maxAbs}）`);
});

test("JPEG EXIF：orientation:'apply' 对无方向信息的文件必须是恒等变换（不能整体镜像）", () => {
  const f = fixture("smooth-444");
  const plain = must(read(f.file));
  const applied = must(read(f.file), { orientation: "apply" });
  assert.equal(applied.width, plain.width);
  assert.equal(applied.height, plain.height);
  assert.equal(diff(applied.pixels, plain.pixels).max, 0, "orientation=1 时 apply 不该动任何像素");
});

// ---------------------------------------------------------------- 拒绝路径

test("JPEG 拒绝：PNG 字节 → ASSET.BAD_JPEG，消息里点明缺 SOI", () => {
  const e = mustFail(decodeJpeg(readPng("rgba8-13x11.plain.png")));
  assert.equal(e.code, "ASSET.BAD_JPEG");
  assert.match(e.message, /SOI|ff d8/i);
});

test("JPEG 拒绝：只有 SOI+EOI（没有 SOF）→ ASSET.BAD_JPEG", () => {
  const e = mustFail(decodeJpeg(new Uint8Array([0xff, 0xd8, 0xff, 0xd9])));
  assert.equal(e.code, "ASSET.BAD_JPEG");
  assert.match(e.message, /SOF|扫描/);
});

test("JPEG 过程名与标记：process 说明是顺序还是渐进，sof 给出原始标记", () => {
  const base = must(read(fixture("smooth-444").file)).jpeg;
  assert.equal(base.sof, 0xc0);
  assert.match(base.process, /顺序/);
  assert.equal(base.arithmetic, false);
  assert.equal(base.lossless, false);
  assert.equal(base.precision, 8);
  assert.equal(base.frames, 1);
  assert.equal(base.hierarchical, false);

  const prog = must(read(fixture("progressive-420").file)).jpeg;
  assert.equal(prog.sof, 0xc2, "渐进式文件必须报出 SOF2，而不是笼统的\"渐进\"");
  assert.match(prog.process, /渐进/);
  assert.equal(prog.progressive, true);
});

test("JPEG 拒绝：DCT 过程的精度不在 8/12（6 bit / 16 bit）→ 报错点名实际位数", () => {
  const src = read(fixture("smooth-444").file);
  const at = findSegment(src, 0xc0);
  assert.ok(at >= 0);
  for (const precision of [6, 16]) {
    const patched = Uint8Array.from(src);
    patched[at + 4] = precision; // SOF 段数据首字节 = 精度
    const e = mustFail(decodeJpeg(patched));
    assert.equal(e.code, "ASSET.UNSUPPORTED_JPEG");
    assert.match(e.message, new RegExp(`${precision} bit`), "报错要说清文件声明的是几位");
  }
});

test("JPEG 拒绝：超过像素上限时在分配像素之前失败", () => {
  const e = mustFail(decodeJpeg(read(fixture("smooth-444").file), { maxPixels: 100 }));
  assert.equal(e.code, "ASSET.BAD_JPEG");
  assert.match(e.message, /像素上限/);
});

test("JPEG 截断：默认仍解出像素但标记 truncated，strict 下直接失败（不静默出灰块）", () => {
  const src = read(fixture("photo-422").file);
  const cut = src.subarray(0, Math.floor(src.length * 0.9));

  const lenient = must(cut);
  assert.equal(lenient.jpeg.truncated, true, "缺 EOI 却没标记 —— 调用方会以为这是完整像素");

  const e = mustFail(decodeJpeg(cut, { strict: true }));
  assert.equal(e.code, "ASSET.BAD_JPEG");
  assert.match(e.message, /EOI|不完整/);

  // 反向守卫：完整文件在两种模式下都不能被判成截断
  const whole = must(src);
  assert.equal(whole.jpeg.truncated, false);
  assert.ok(decodeJpeg(src, { strict: true }).ok, "完整文件在 strict 下必须成功 —— 否则 strict 等于禁用 JPEG");
});

test("JPEG isJpeg：只认 SOI 前缀，不认扩展名", () => {
  assert.equal(isJpeg(read(fixture("gray").file)), true);
  assert.equal(isJpeg(readPng("rgba8-13x11.plain.png")), false);
  assert.equal(isJpeg(new Uint8Array([0xff, 0xd8])), false, "两位不够：缺第三个 FF 就是别的格式");
  assert.equal(isJpeg(new Uint8Array(0)), false);
});

// ---------------------------------------------------------------- 分发与消费方

test("decodeImage：按魔数分发，PNG 走 PNG、JPEG 走 JPEG（扩展名不影响）", () => {
  const png = readPng("rgba8-13x11.plain.png");
  const jpg = read(fixture("smooth-444").file);

  assert.equal(sniffImageFormat(png), "png");
  assert.equal(sniffImageFormat(jpg), "jpeg");
  assert.equal(sniffImageFormat(new Uint8Array([1, 2, 3, 4])), null, "不认识的格式必须返回 null，不能猜");

  const p = decodeImage(png);
  assert.ok(p.ok);
  assert.equal("jpeg" in p.value, false, "PNG 不该带上 JPEG 专有字段");
  assert.deepEqual(Buffer.from(p.value.pixels), Buffer.from(mustPng(png).pixels), "PNG 路径必须与直接调 decodePng 一致");

  const j = decodeImage(jpg);
  assert.ok(j.ok);
  assert.ok("jpeg" in j.value, "JPEG 走 JPEG 路径时必然带上 jpeg 元信息");
  assert.equal((j.value as DecodedJpeg).jpeg.subsampling, "4:4:4");

  // 反例：把同一份字节改个"扩展名"（这里是函数参数里没有路径，所以用魔数相同的前提），
  // 证明判定完全基于内容 —— 一个 .jpg 后缀的 PNG 会被当成 PNG 解出正确尺寸
  const p2 = decodeImage(png);
  assert.ok(p2.ok);
  assert.equal(p2.value.width, 13);
});

test("decodeImage：未知格式 → ASSET.UNKNOWN_FORMAT，消息里带开头字节便于对账", () => {
  const e = mustFail(decodeImage(new Uint8Array([0x42, 0x4d, 0x36, 0x00])));
  assert.equal(e.code, "ASSET.UNKNOWN_FORMAT");
  assert.match(e.message, /42 4d 36 00/, "不认识就要报出看到的是什么，否则排查只能靠猜");
});

// ---------------------------------------------------------------- 导入管线接线

interface Rig {
  readonly fs: MemoryFileSystem;
  readonly db: AssetDatabase;
  readonly pipeline: AssetImportPipeline;
}

function rigFor(): Rig {
  const fs = new MemoryFileSystem();
  const log = new Logger(() => 0);
  log.setLevel(LogLevel.Off);
  const db = new AssetDatabase(fs, log.channel("asset"));
  const registry = new ImporterRegistry();
  registry.register(textureImporter);
  const pipeline = new AssetImportPipeline(fs, db, registry, log.channel("import"));
  for (const l of createImportLoaders({ root: "/assets" })) db.registerLoader(l);
  return { fs, db, pipeline };
}

async function rigWithJpeg(entries: ReadonlyArray<readonly [string, Uint8Array]>): Promise<Rig> {
  const rig = rigFor();
  for (const [name, bytes] of entries) {
    const w = await rig.fs.writeBinary(`/assets/${name}`, bytes);
    assert.ok(w.ok, `写入 ${name} 失败`);
  }
  return rig;
}

test("JPEG 导入：.jpg 走 textureImporter，产物 data.format = 'jpeg'，宽高来自 SOF", async () => {
  const f = fixture("photo-422");
  const rig = await rigWithJpeg([["photo.jpg", read(f.file)]]);

  const rep = await rig.pipeline.run("/assets");
  assert.ok(rep.ok, `导入失败：${rep.ok ? "" : rep.error.code + " " + rep.error.message}`);
  assert.equal(rep.value.imported, 1, "没有导入器时 .jpg 会进不了资产库 —— 那等于'解码器写完但用不上'");
  assert.deepEqual(rep.value.failed, []);

  const meta = JSON.parse(mustText(await rig.fs.readText("/assets/photo.jpg.meta"))) as {
    readonly id: string;
    readonly type: string;
  };
  assert.equal(meta.type, "texture");

  const artifact = JSON.parse(mustText(await rig.fs.readText(`/assets/library/imported/${meta.id}.json`))) as {
    readonly data: { readonly width: number; readonly height: number; readonly format?: string };
  };
  assert.equal(artifact.data.width, f.width);
  assert.equal(artifact.data.height, f.height);
  assert.equal(artifact.data.format, "jpeg", "产物要能说清源格式，否则下游只能靠猜");
});

test("JPEG 导入：算术 / 无损 / 12 位都能进资产库（不是'解码器能解、导入器拦下'）", async () => {
  // ★ 这条测试以前写的是反面：断言 SOF9 在导入期被拒绝。
  //   它是"解码器只支持 SOF0/1/2"时代的判据，解码器补齐 13 个 SOF 后，
  //   这条测试反而成了**把新能力锁在门外**的东西 —— 而且它一直是绿的。
  //   判据反过来：这些过程必须 import 成功，否则"支持算术编码"就只存在于解码器里。
  const cases: ReadonlyArray<readonly [string, Uint8Array, number, string]> = [
    ["arith.jpg", read(fixture("arith-seq-gray").file), 8, "算术"],
    ["arith-prog.jpg", read(fixture("arith-prog-gray").file), 8, "算术"],
    ["lossless8.jpg", read(fixture("lossless-8-gray").file), 8, "无损"],
    ["lossless12.jpg", read(wideFixture("lossless-12").file), 12, "无损"],
    ["lossless16.jpg", read(wideFixture("lossless-16").file), 16, "无损"],
    // 4 分量也该进得来：导入器的支持判据是"过程 × 精度"，与分量数无关；
    // 但 4 分量曾经连一条语料都没有，所以顺手在这里钉住"改判据时别把 4 分量误伤"。
    ["cmyk.jpg", read(fixture("cmyk-baseline").file), 8, "SOF0"],
    ["ycck.jpg", read(fixture("ycck-baseline").file), 8, "SOF0"],
  ];
  const rig = await rigWithJpeg(cases.map(([file, bytes]) => [file, bytes] as const));

  const rep = await rig.pipeline.run("/assets");
  assert.ok(rep.ok, `导入失败：${rep.ok ? "" : rep.error.code + " " + rep.error.message}`);
  assert.deepEqual(rep.value.failed, [], "这些过程都实现了，不该有任何失败");
  assert.equal(rep.value.imported, cases.length, "这一批新过程文件必须全部进资产库");

  for (const [file, , precision, keyword] of cases) {
    const meta = JSON.parse(mustText(await rig.fs.readText(`/assets/${file}.meta`))) as { readonly id: string };
    const artifact = JSON.parse(mustText(await rig.fs.readText(`/assets/library/imported/${meta.id}.json`))) as {
      readonly data: { readonly bitDepth: number; readonly process?: string };
    };
    assert.equal(artifact.data.bitDepth, precision, `${file} 的源精度要如实报出来，不能一律写 8`);
    assert.match(artifact.data.process ?? "", new RegExp(keyword), `${file} 的产物要能说清是哪种过程`);
  }
});

test("JPEG 导入：分层过程也能进资产库，且元数据尺寸取 DHP 的完成态几何", async () => {
  // ★ 分层没有任何第三方编码器能产语料（libjpeg 早已移除 `hier_code`），所以这里的
  //   文件是**我们自己编码**的 —— 它证明不了"分层解对了"（那由 pixels 层的回环与
  //   跨模式逐字节一致去证），但能证明另一件一直被忽略的事：
  //   **导入器的放行判据没有把分层挡在门外**。"解码器支持"和"资产库能进"是两件事，
  //   上面 607 行那条测试当初就是因为只测了前者才把 SOF9 锁在门外。
  const W = 40;
  const H = 24;
  const sample = new Uint16Array(W * H * 3);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 3;
      sample[o] = Math.round(((Math.sin(x * 0.2) + 1) / 2) * 255);
      sample[o + 1] = Math.round(((Math.cos(y * 0.22) + 1) / 2) * 255);
      sample[o + 2] = Math.round(((x + y) / (W + H)) * 255);
    }
  }
  // ★ 期望看到的是**参考帧**的 SOF，不是差分帧的 —— 导入器只做轻量扫头（不跨熵数据），
  //   差分帧在熵数据之后，扫不到。这一点写在 process 文案里（"参考帧 SOF0 …"），
  //   免得下游把它读成"这张图是 baseline"。
  const modes: ReadonlyArray<readonly [string, string, string]> = [
    ["hier-seq.jpg", "hier-sequential", "参考帧 SOF0"],
    ["hier-prog.jpg", "hier-progressive", "参考帧 SOF0"],
    ["hier-arith.jpg", "hier-arith-sequential", "参考帧 SOF9"],
    ["hier-arith-prog.jpg", "hier-arith-progressive", "参考帧 SOF9"],
  ];
  const files = modes.map(([file, mode]) => {
    const bytes = encodeJpeg(sample, {
      width: W,
      height: H,
      components: 3,
      precision: 8,
      mode: mode as EncodeSpec["mode"],
      quality: 90,
    });
    // 先确认这份字节本身是两帧差分，否则下面的导入判据证明的是别的东西
    const d = decodeJpeg(bytes);
    assert.ok(d.ok, `${file} 应当解得开：${d.ok ? "" : d.error.message}`);
    assert.equal(d.value.jpeg.frames, 2, `${file} 必须是两帧`);
    assert.equal(d.value.jpeg.differential, true, `${file} 第二帧必须是差分帧`);
    return [file, bytes] as const;
  });

  const rig = await rigWithJpeg(files);
  const rep = await rig.pipeline.run("/assets");
  assert.ok(rep.ok, `导入失败：${rep.ok ? "" : rep.error.code + " " + rep.error.message}`);
  assert.deepEqual(rep.value.failed, [], "分层过程已实现，不该有任何失败");
  assert.equal(rep.value.imported, files.length, "四种分层过程都必须进资产库");

  for (let i = 0; i < modes.length; i++) {
    const [file, , sofName] = modes[i]!;
    const meta = JSON.parse(mustText(await rig.fs.readText(`/assets/${file}.meta`))) as {
      readonly id: string;
    };
    const artifact = JSON.parse(
      mustText(await rig.fs.readText(`/assets/library/imported/${meta.id}.json`)),
    ) as {
      readonly data: {
        readonly bitDepth: number;
        readonly process?: string;
        readonly width?: number;
        readonly height?: number;
      };
    };
    assert.equal(artifact.data.bitDepth, 8, `${file} 的源精度是 8`);
    assert.match(artifact.data.process ?? "", new RegExp(sofName), `${file} 的产物要说出是 ${sofName}`);
    assert.match(artifact.data.process ?? "", /分层/, `${file} 的过程名要说"分层"，不能只报参考帧的 SOF`);
    // ★ 这条是本次真正抓到的缺陷：分层文件第一帧是**半分辨率参考帧**，
    //   "扫到第一个 SOF 就返回宽高"会报出 20×12，而解码器解出来是 40×24。
    //   元数据与实际产物对不上，下游按元数据分配缓冲就会裁掉四分之三。
    assert.equal(artifact.data.width, W, `${file} 的元数据宽度必须是完成态图像宽度 ${W}`);
    assert.equal(artifact.data.height, H, `${file} 的元数据高度必须是完成态图像高度 ${H}`);
    const d = decodeJpeg(files[i]![1]);
    assert.ok(d.ok, `${file} 应当解得开`);
    assert.equal(d.value.width, artifact.data.width, `${file}：元数据宽度必须等于解码宽度`);
    assert.equal(d.value.height, artifact.data.height, `${file}：元数据高度必须等于解码高度`);
  }
});

test("JPEG 导入：真不支持的精度仍在导入期拒绝（判据不是全放行）", async () => {
  // 反向守卫：如果导入器只是"把清单删了、什么都不查"，上面那条会绿，这条会红。
  const patched = withPrecision(read(fixture("smooth-444").file), 0xc0, 6);
  assert.ok(patched !== null, "smooth-444 应该是 SOF0");

  const rig = await rigWithJpeg([["bad.jpg", patched]]);
  const rep = await rig.pipeline.run("/assets");
  assert.ok(rep.ok, "一个坏文件不该让整轮导入失败");
  assert.equal(rep.value.imported, 0);
  assert.equal(rep.value.failed.length, 1, "坏文件必须出现在 failed 里，不能被静默跳过");
  assert.equal(rep.value.failed[0]?.code, "IMPORT.UNSUPPORTED_SOURCE");
  assert.match(rep.value.failed[0]?.message ?? "", /6 bit/, "报错要点名文件声明的位数");
});

test("JPEG 导入：无损过程精度上界 16，17 bit 必须被拒绝（边界不是'越大越好'）", async () => {
  const patched = withPrecision(read(wideFixture("lossless-16").file), 0xc3, 17);
  assert.ok(patched !== null, "lossless-16 应该是 SOF3");
  const rig = await rigWithJpeg([["bad17.jpg", patched]]);
  const rep = await rig.pipeline.run("/assets");
  assert.ok(rep.ok);
  assert.equal(rep.value.imported, 0);
  assert.equal(rep.value.failed[0]?.code, "IMPORT.UNSUPPORTED_SOURCE");
  assert.match(rep.value.failed[0]?.message ?? "", /17 bit/);
});

test("JPEG 闭环：导入 → 解码 → 图集合成，帧尺寸等于 SOF 声明（'能解'变成'能用'）", async () => {
  const names = ["smooth-444", "photo-422", "gray"] as const;
  const rig = await rigWithJpeg(names.map((n) => [n + ".jpg", read(fixture(n).file)] as const));
  const rep = await rig.pipeline.run("/assets");
  assert.ok(rep.ok);
  assert.equal(rep.value.imported, names.length);

  const sources: AtlasSource[] = [];
  for (const n of names) {
    const id = rig.db.idAtPath(`/assets/${n}.jpg`);
    assert.ok(id !== undefined, `${n}.jpg 导入后应能按路径查到 id`);
    const h = await rig.db.load(id);
    assert.ok(h.ok, `${n}.jpg 加载失败：${h.ok ? "" : h.error.code + " " + h.error.message}`);
    try {
      const asset = h.value.asset;
      assert.ok(asset instanceof ImportedTexture, `${n} 应加载成 ImportedTexture，实际 ${asset.constructor.name}`);
      const dec = decodeImage(asset.bytes);
      assert.ok(dec.ok, `${n} 解码失败：${dec.ok ? "" : dec.error.code + " " + dec.error.message}`);
      assert.equal(dec.value.width, asset.width, `${n} 解码宽度必须等于导入产物声明的宽度`);
      sources.push({ name: n, png: dec.value });
    } finally {
      h.value.release();
    }
  }

  const built = buildAtlasFromSources(sources, { padding: 1 });
  assert.ok(built.ok, `图集合成失败：${built.ok ? "" : built.error.code + " " + built.error.message}`);
  const atlas = built.value;
  assert.equal(atlas.frames.size, names.length, "每一帧都必须进图集");
  assert.equal(atlas.pixels.byteLength, atlas.width * atlas.height * 4);
  for (const n of names) {
    const frame = atlas.frames.get(n);
    assert.ok(frame !== undefined, `图集里缺少帧 ${n}`);
    assert.equal(frame.w, fixture(n).width, `${n} 帧宽必须等于 SOF 声明值`);
    assert.equal(frame.h, fixture(n).height, `${n} 帧高必须等于 SOF 声明值`);
  }
  // 像素真的被画进去了：JPEG 帧区域不能整块是黑的（合成器只写了帧表没拷像素时会这样）
  const f0 = atlas.frames.get(names[0]!)!;
  const x = Math.floor(f0.u0 * atlas.width);
  const y = Math.floor(f0.v0 * atlas.height);
  const i = (y * atlas.width + x) * 4;
  assert.ok(atlas.pixels[i]! + atlas.pixels[i + 1]! + atlas.pixels[i + 2]! > 0, "帧区域全黑 —— 像素没有被拷进图集");
});

// ---------------------------------------------------------------- 小工具

function mustText(r: Result<string, EngineError>): string {
  if (!r.ok) throw new Error(`读文件失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function mustPng(bytes: Uint8Array): DecodedPng {
  const r = decodePng(bytes);
  if (!r.ok) throw new Error(`PNG 解码失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

/** 走段结构找标记的位置；找不到返回 -1（不能在熵数据里瞎找 FF xx）。 */
function findSegment(bytes: Uint8Array, marker: number): number {
  let pos = 2;
  while (pos + 3 < bytes.length) {
    if (bytes[pos] !== 0xff) {
      pos++;
      continue;
    }
    const m = bytes[pos + 1]!;
    if (m === 0xff) {
      pos++;
      continue;
    }
    if (m === 0xd8 || m === 0x01 || (m >= 0xd0 && m <= 0xd7)) {
      pos += 2;
      continue;
    }
    if (m === 0xd9) return -1;
    if (m === marker) return pos;
    const segLen = (bytes[pos + 2]! << 8) | bytes[pos + 3]!;
    if (segLen < 2) return -1;
    pos += 2 + segLen;
  }
  return -1;
}

/** 复制一份并改写 SOF 段数据区的首字节（精度）。返回 null 表示文件里没有该 SOF。 */
function withPrecision(bytes: Uint8Array, sof: number, precision: number): Uint8Array | null {
  const at = findSegment(bytes, sof);
  if (at < 0) return null;
  const copy = Uint8Array.from(bytes);
  copy[at + 4] = precision;
  return copy;
}
