/**
 * L4 · JPEG · 鲁棒性：**按段结构**取样 + 覆盖 12 位 / YCCK / 窄图 / 渐进+重启
 *
 * ★ 与 `jpeg-modes.test.ts` 里那条"单字节篡改"判据的分工
 * ----------------------------------------------------
 * 那条用**等距抽样**（按文件长度均分 ~160 个位置）。这在真实文件上有个结构性偏差：
 * 熵数据通常占 80%~95% 的字节，于是 160 个位置里绝大多数落在熵数据里，
 * 头部那些**只有 1~3 个字节**的关键字段（段长、表号、采样因子、谱段边界、重启计数、EXP 因子）
 * 只能靠"恰好抽到"才被覆盖 —— 而这类字段一改就是"能不能解"的分水岭。
 *
 * 这里换成**按段结构取样**：先把文件切成标记段，每个段头单独取位置（短段全取），
 * 熵数据再均匀取少量。最后断言"每一类标记段都真的被篡改过"，
 * 而不是"我希望它被覆盖到"。
 *
 * ★ 种子扩了 6 类：12 位 DCT、12 位 4:2:0、渐进+重启、YCCK（transform=2）、
 *   窄图（3×97）、算术渐进 12 位 —— 这几条正是最近几轮才修/才补的路径
 *   （fancy 开关、12 位电平位移、YCCK 反相、渐进精修状态机）。
 *   旧种子表里一份 12 位都没有，等于"12 位的坏输入路径从没被扫过"。
 *
 * ★ 判据本身只有一条、但很强：**解码器永远返回 Result，永远不抛异常；返回 ok 时
 *   像素数组长度必须等于 w×h×4**。外加"不许落到兜底 catch"——
 *   兜底会把"读到 undefined"变成"内部错误"，真实缺陷就藏在里面。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import { decodeJpeg } from "../../src/extensions/asset-import/decode/jpeg.ts";
import { encodeJpeg } from "../tools/jpeg-encode.ts";
import type { EncodeSpec, JpegMode } from "../tools/jpeg-encode.ts";

const W = 40;
const H = 24;

function maxOf(precision: number): number {
  return (1 << precision) - 1;
}

function smoothGray(precision: number, w = W, h = H): Uint16Array {
  const max = maxOf(precision);
  const a = new Uint16Array(w * h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) a[y * w + x] = Math.round(((Math.sin(x * 0.25) + Math.cos(y * 0.3) + 2) / 4) * max);
  }
  return a;
}

function smoothRgb(precision: number, w = W, h = H): Uint16Array {
  const max = maxOf(precision);
  const a = new Uint16Array(w * h * 3);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const o = (y * w + x) * 3;
      a[o] = Math.round(((Math.sin(x * 0.2) + 1) / 2) * max);
      a[o + 1] = Math.round(((Math.cos(y * 0.22) + 1) / 2) * max);
      a[o + 2] = Math.round(((x + y) / (w + h)) * max);
    }
  }
  return a;
}

function cmyk(precision: number): Uint16Array {
  const max = maxOf(precision);
  const a = new Uint16Array(W * H * 4);
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const o = (y * W + x) * 4;
      a[o] = Math.round((0.7 + 0.25 * Math.sin(x * 0.2)) * max);
      a[o + 1] = Math.round((0.6 + 0.3 * Math.cos(y * 0.15)) * max);
      a[o + 2] = Math.round(((x + y) / (W + H)) * max);
      a[o + 3] = Math.round((0.5 + 0.4 * Math.sin((x + y) * 0.13)) * max);
    }
  }
  return a;
}

function spec(components: 1 | 3, precision: 8 | 12, mode: JpegMode, extra: Partial<EncodeSpec> = {}): EncodeSpec {
  return { width: W, height: H, components, precision, mode, quality: 88, ...extra };
}

interface Seed {
  readonly name: string;
  readonly bytes: Uint8Array;
}

const seeds: Seed[] = [
  ["baseline 8 位灰度", encodeJpeg(smoothGray(8), spec(1, 8, "baseline"))],
  ["baseline 8 位 4:2:0", encodeJpeg(smoothRgb(8), spec(3, 8, "baseline"))],
  ["渐进 8 位灰度", encodeJpeg(smoothGray(8), spec(1, 8, "progressive"))],
  ["渐进 + 重启 8 位 4:2:0", encodeJpeg(smoothRgb(8), spec(3, 8, "progressive", { restart: 3 }))],
  ["算术顺序 8 位灰度", encodeJpeg(smoothGray(8), spec(1, 8, "arith-sequential"))],
  ["无损 8 位灰度", encodeJpeg(smoothGray(8), spec(1, 8, "lossless"))],
  ["分层 8 位 RGB", encodeJpeg(smoothRgb(8), spec(3, 8, "hier-sequential"))],
  ["4 分量 CMYK", encodeJpeg(cmyk(8), { ...spec(3, 8, "baseline"), components: 4 } as EncodeSpec)],
  // ★ 旧种子表里一份 12 位都没有 —— 下面这些才是这一组新增的覆盖面
  ["12 位 baseline 灰度", encodeJpeg(smoothGray(12), spec(1, 12, "baseline"))],
  ["12 位 4:2:0", encodeJpeg(smoothRgb(12), spec(3, 12, "baseline"))],
  ["12 位 渐进 + 重启", encodeJpeg(smoothGray(12), spec(1, 12, "progressive", { restart: 5 }))],
  ["12 位 算术渐进", encodeJpeg(smoothGray(12), spec(1, 12, "arith-progressive"))],
  ["YCCK 4 分量（transform=2）", encodeJpeg(cmyk(8), { ...spec(3, 8, "baseline"), components: 4, adobeTransform: 2 } as EncodeSpec)],
  // 窄图：色度样本 ≤2 时 libjpeg 会关掉 fancy 退回复制（第十批修的真缺陷就在这）
  [
    "窄图 3×97 4:2:0",
    encodeJpeg(smoothRgb(8, 3, 97), { width: 3, height: 97, components: 3, precision: 8, mode: "baseline", quality: 88, subsampling: "420" }),
  ],
].map(([name, bytes]) => ({ name: name as string, bytes: bytes as Uint8Array }));

interface Seg {
  readonly marker: number;
  /** 段头起始（0xFF 的位置） */
  readonly start: number;
  /** 段体起始（熵数据段就是熵数据起点） */
  readonly bodyStart: number;
  /** 段结束（不含） */
  readonly end: number;
  readonly isScan: boolean;
}

/**
 * 把文件切成标记段。
 *
 * ★ 这是**测试端自己的**走法（独立于解码器的 `splitEntropy`）：
 *   用被测实现的解析器来"准备测试输入"会让"解析器漏了什么"永远测不出来。
 *   规则按 T.81 B.1.1.2：`FF xx` 是标记，`FF 00` 是填充字节，`FF D0..D7` 是重启标记；
 *   熵数据里出现其它 `FF xx` 就说明熵段结束。
 */
function segments(bytes: Uint8Array): Seg[] {
  const out: Seg[] = [];
  let i = 0;
  while (i + 1 < bytes.length) {
    if (bytes[i] !== 0xff) {
      i++;
      continue;
    }
    const m = bytes[i + 1]!;
    if (m === 0x00 || (m >= 0xd0 && m <= 0xd7)) {
      i += 2;
      continue;
    }
    if (m === 0xd8 || m === 0xd9 || m === 0x01) {
      out.push({ marker: m, start: i, bodyStart: i + 2, end: i + 2, isScan: false });
      i += 2;
      continue;
    }
    if (i + 3 >= bytes.length) break;
    const len = (bytes[i + 2]! << 8) | bytes[i + 3]!;
    const end = i + 2 + len;
    if (m === 0xda) {
      // SOS：段头之后是熵数据，扫到下一个真正的标记为止
      let j = end;
      while (j + 1 < bytes.length) {
        if (bytes[j] === 0xff) {
          const n = bytes[j + 1]!;
          if (n !== 0x00 && !(n >= 0xd0 && n <= 0xd7)) break;
        }
        j++;
      }
      out.push({ marker: m, start: i, bodyStart: end, end: j, isScan: true });
      i = j;
      continue;
    }
    out.push({ marker: m, start: i, bodyStart: i + 4, end: Math.min(end, bytes.length), isScan: false });
    i = end;
  }
  return out;
}

/** 段内取样位置：短段全取，长段按比例取至多 `want` 个。 */
function positionsIn(seg: Seg, want: number): number[] {
  const len = seg.end - seg.start;
  if (len <= 0) return [];
  if (len <= want) return Array.from({ length: len }, (_, k) => seg.start + k);
  const step = len / want;
  const out: number[] = [];
  for (let k = 0; k < want; k++) out.push(seg.start + Math.floor(k * step));
  return out;
}

test("JPEG 鲁棒性（按段结构取样）：每一类标记段都被单字节篡改过，且解码器永远返回 Result", () => {
  // 每个段头最多取 8 个位置，熵数据取 30 个 —— 段头才是"字段"，熵数据只需要足够量
  const HEAD_WANT = 10;
  const SCAN_WANT = 30;
  // ★ 6 个取值：0x00/0xFF 打全 0/全 1，0x80/0x7F 打**符号位**（段长、表号这类小整数
  //   改成 0x80 会变成 128，是"长度越界"最常见的来源），再两个"翻转一位"。
  const VALUES = (b: number): number[] => [0x00, 0x7f, 0x80, 0xff, b ^ 0x01, b ^ 0x80];

  let checked = 0;
  let rejected = 0;
  let accepted = 0;
  const hitMarkers = new Set<number>();

  /** 每份种子贡献的样本数 —— 防止"加了种子但取样器没走到它"那种静默空转 */
  const perSeed = new Map<string, number>();
  for (const seed of seeds) {
    const segs = segments(seed.bytes);
    const positions: number[] = [];
    for (const s of segs) {
      positions.push(...positionsIn(s, s.isScan ? SCAN_WANT : HEAD_WANT));
      if (s.end > s.start) hitMarkers.add(s.marker);
    }

    for (const pos of positions) {
      const orig = seed.bytes[pos]!;
      for (const v of VALUES(orig)) {
        const mut = Uint8Array.from(seed.bytes);
        mut[pos] = v;
        let r: ReturnType<typeof decodeJpeg>;
        try {
          // ★ 必须限 maxPixels：篡改 SOF 的宽高字段会造出"合法但巨大"的声明
          //   （0x7FFF×24 = 78 万像素），默认上限 64M 会放行 → 每个这样的样本都要
          //   老老实实解 78 万像素。第一版没限上限，整条判据跑了 13 秒，
          //   而多花的 11 秒全花在"解一张被篡改成大图的坏文件"上，对鲁棒性判据没有增量。
          //   本组种子最大 40×24=960 与 3×97=291，上限 65536 对真实种子毫无影响。
          r = decodeJpeg(mut, { keep16: true, maxPixels: 1 << 16 });
        } catch (e) {
          assert.fail(
            `${seed.name}：把第 ${pos} 字节（0x${orig.toString(16)}→0x${v.toString(16)}）改成 0x${v.toString(16)} 后**抛了异常**` +
              `（${(e as Error).constructor.name}: ${(e as Error).message}）—— 解码器必须返回 Result`,
          );
        }
        checked++;
        perSeed.set(seed.name, (perSeed.get(seed.name) ?? 0) + 1);
        if (!r.ok) {
          assert.ok(
            !r.error.message.includes("解码内部错误"),
            `${seed.name}：第 ${pos} 字节改成 0x${v.toString(16)} 后落到兜底 catch（${r.error.message}）` +
              "—— 说明某处读到了 undefined/NaN，而不是被结构化拒绝",
          );
          assert.ok(r.error.message.length > 0, `${seed.name}：拒绝时必须给出可读原因`);
          rejected++;
          continue;
        }
        accepted++;
        const d = r.value;
        assert.equal(d.pixels.length, d.width * d.height * 4, `${seed.name}：第 ${pos} 字节 → RGBA 长度与宽高不符`);
        assert.ok(d.pixels16 !== undefined && d.pixels16.length === d.width * d.height * 4, `${seed.name}：pixels16 长度不符`);
        assert.ok(d.width > 0 && d.height > 0, `${seed.name}：解出 ok 就必须有正的宽高`);
      }
    }
  }

  console.log(`[fuzz] 样本 ${checked}：拒绝 ${rejected} / 接受 ${accepted}，覆盖标记 ${hitMarkers.size} 类`);
  assert.ok(checked > 8000, `只检查了 ${checked} 个篡改样本，段数/取样数不对`);
  assert.ok(rejected > 2000, `只有 ${rejected} 个篡改被拒绝 —— 取样可能集中在无关字节上`);
  assert.ok(accepted > 3000, `只有 ${accepted} 个篡改仍能解出 —— 篡改可能没生效`);

  // ★ 每份种子都必须真的被扫到。取样器按段走，如果某份种子的段被走错（例如 SOS 之后
  //   一步跳出），它的样本数会掉到 0 而总计仍然达标 —— 那种情况下"它被覆盖了"是假的。
  for (const seed of seeds) {
    const n = perSeed.get(seed.name) ?? 0;
    assert.ok(n >= 50, `${seed.name}：只产生 ${n} 个篡改样本（段结构可能没走通）`);
  }

  // ★ 这一条是这一组存在的理由：**每一类标记段都被真的打到过**，
  //   而不是"熵数据占了 90% 于是只覆盖了熵数据"。
  for (const need of [0xd8, 0xdb, 0xc4, 0xc0, 0xc2, 0xc9, 0xca, 0xc3, 0xde, 0xdf, 0xda, 0xd9]) {
    assert.ok(hitMarkers.has(need), `标记 0x${need.toString(16)} 的段一次都没被取样到 —— 取样策略漏了这类段`);
  }
});

test("JPEG 鲁棒性：段结构走查器自身可信（用它自己走一遍已知结构的文件）", () => {
  // ★ 取样器是判据的一部分：它要是把 SOS 之后的熵数据算错，
  //   "每一类段都被打到"就会变成"每一类段都被**跳过**"，而断言仍然可能绿。
  const bytes = encodeJpeg(smoothGray(8), spec(1, 8, "baseline"));
  const segs = segments(bytes);
  const markers = segs.map((s) => s.marker);
  // 顺序必须符合 T.81：SOI 在最前，EOI 在最后，SOS 在 EOI 之前
  assert.equal(markers[0], 0xd8, "第一个段必须是 SOI");
  assert.equal(markers[markers.length - 1], 0xd9, "最后一个段必须是 EOI");
  const daIdx = markers.indexOf(0xda);
  assert.ok(daIdx > 0 && daIdx < markers.length - 1, "SOS 必须在中间");
  // 段必须首尾相接、无空洞（除填充），否则取样会漏字节
  for (let k = 0; k + 1 < segs.length; k++) {
    assert.ok(segs[k]!.end <= segs[k + 1]!.start + 1, `第 ${k} 段与下一段之间有空洞，取样器算错了段边界`);
  }
  // 熵段不能是空的（空说明 SOS 后面一步都没走就跳出）
  const scan = segs[daIdx]!;
  assert.ok(scan.isScan && scan.end > scan.bodyStart, "SOS 的熵数据长度必须 > 0");
  // 段长字段必须自洽：DQT 的 L 应该等于 2 + 1 + 64
  const dqt = segs.find((s) => s.marker === 0xdb);
  assert.ok(dqt !== undefined, "baseline 必须有 DQT");
  assert.equal(dqt!.end - dqt!.start, 69, "DQT 段（表 0、8 位、64 字节）总长必须是 69");
});
