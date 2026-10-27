/**
 * 中文字体位图资产（`ui-font-cjk.{png,fnt}`）的判据
 *
 * 这一组守的是**资产与它的来源**，不是解析器（解析器有 `ui-font.test.ts`）。
 * 为什么要分开：解析器的判据用手搓的夹具字体，它证明"能解析合法 BMFont"，
 * 但证明不了"仓库里这份 7540 字形的图集是对的"。真正会坏的是后者 ——
 * 上游 BDF 换了版本、字符集里少写一个字、打包坐标错一位、行高算错一格。
 *
 * ★★ 这份资产有两类"看起来全绿"的坏法，各自要一条专门的判据：
 *   ① **字形有了但墨没了**：`width/height/xadvance` 全对、排版宽度全对，
 *      只是某个字在图上是一个空格子。结构类判据一条都抓不住（数据自洽），
 *      只有真去数像素能抓住 → 见「每个字形在图集里都真的有墨」。
 *   ② **图集内容与源字形不一致**：UV 指到了相邻那格、或者整列错位一格。
 *      像素判据也绿（那格里确实有墨，只是别人的墨）→
 *      见「图集里的位与 BDF 里的位逐位相同」，它拿**源文件**当金标，不是拿自己比自己。
 *
 * ★ 判据直接调 `build()`（在内存里跑生成器），不只看磁盘：
 *   只比磁盘的话，"改了生成器但没重跑"红在"不一致"上，而"改了且重跑了"就全绿 ——
 *   那守的是"记得跑生成器"，不是"生成的资产是对的"。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { parseBmFont, type BitmapFont } from "../../src/extensions/ui/font.ts";
import { layoutText } from "../../src/extensions/ui/text-layout.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";
import { parseBdf } from "../../tools/bdf.mjs";
import { build, loadCharset, CJK_FACE } from "../../tools/make-ui-assets.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const ASSETS = join(ROOT, "web", "assets");
const VENDOR = join(ROOT, "vendor", "unifont", "unifont-18.0.01.bdf.gz");

/** GB2312 全集（6763 汉字 + 682 符号）+ 可打印 ASCII。 */
const CHARSET_TOTAL = 7540;
/** 其中汉字个数 —— 这是"能写中文"这件事的下限，写死一个数是为了让字符集缩水必红。 */
const HANZI_TOTAL = 6763;

/**
 * 生成器在内存里的产物。**缓存一份**：`build()` 要一秒左右（解压 + 解析 5.7 万字形），
 * 而它是纯函数（同样输入同样输出），每个用例各跑一次只是白等。
 */
let cachedBuild: ReturnType<typeof build> | null = null;
function built(): ReturnType<typeof build> {
  cachedBuild ??= build();
  return cachedBuild;
}

function fromDisk(name: string): string {
  return readFileSync(join(ASSETS, name), "utf8");
}

function loadDiskFont(): BitmapFont {
  const r = parseBmFont(fromDisk("ui-font-cjk.fnt"), { id: "ui-cjk" });
  if (!r.ok) throw new Error(`ui-font-cjk.fnt 解析失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

/** 源 BDF 里的字形位（金标）。按需只解析用得到的码点，省掉四万多个无关字形。 */
function sourceShapes(codes: readonly number[]) {
  const text = gunzipSync(readFileSync(VENDOR)).toString("utf8");
  return parseBdf(text, new Set(codes));
}

test("字符集是一份真的清单：7540 个码点、其中 6763 个汉字、没有重复", () => {
  const codes = loadCharset();
  assert.equal(codes.size, CHARSET_TOTAL, "字符集码点数变了（改了 cjk-charset.txt 就要同步这条与图集）");
  const hanzi = [...codes].filter((c) => c >= 0x4e00 && c <= 0x9fff).length;
  assert.equal(hanzi, HANZI_TOTAL, `汉字数 ${String(hanzi)} ≠ ${String(HANZI_TOTAL)}（GB2312 一级+二级共 6763）`);
  // ASCII 走 `@ascii` 指令而不是正文行 —— 正文会被 trim，行首行尾的空格根本留不住
  for (let c = 32; c <= 126; c++) assert.ok(codes.has(c), `ASCII 缺 U+${String(c)}`);
});

test("★ 字符集里的每个字都在字体里（子集化漏字 = 那个字永远不显示，且不报错）", () => {
  const font = loadDiskFont();
  const codes = loadCharset();
  const missing = [...codes].filter((c) => !font.glyphs.has(c)).sort((a, b) => a - b);
  assert.deepEqual(
    missing,
    [],
    `这些码点在 .fnt 里没有字形：${missing.slice(0, 20).map((c) => `U+${c.toString(16)} ${String.fromCodePoint(c)}`).join(" / ")}`,
  );
  assert.equal(font.glyphs.size, codes.size, ".fnt 里的字形数与字符集不一致（多出来的字是谁？）");
});

test("全角/半角的度量：汉字 16×16 前进 16，ASCII 8×16 前进 8（混排宽度全靠它）", () => {
  const font = loadDiskFont();
  let full = 0;
  let half = 0;
  let blank = 0;
  for (const g of font.glyphs.values()) {
    if (g.width === 0) {
      // 只有两个空白字形：半角空格与全角空格。多出来的一定是某个字没墨了。
      blank++;
      continue;
    }
    assert.equal(g.height, 16, `U+${String(g.code)} 的高度不是 16（Unifont 的 FONTBOUNDINGBOX 是 16×16）`);
    if (g.code >= 0x4e00 && g.code <= 0x9fff) {
      assert.equal(g.width, 16, `汉字 U+${String(g.code)} ${String.fromCodePoint(g.code)} 应该是全角 16 宽`);
      assert.equal(g.xadvance, 16, `汉字 U+${String(g.code)} 的前进量应该是 16`);
      full++;
    } else {
      assert.ok(g.width === 8 || g.width === 16, `U+${String(g.code)} 的宽度是 ${String(g.width)}（不是 8 也不是 16）`);
      assert.equal(g.xadvance, g.width, `U+${String(g.code)} 的前进量应等于宽度（Unifont 由 DWIDTH 给，不含额外字距）`);
      half++;
    }
  }
  assert.equal(full, HANZI_TOTAL, `全角汉字数 ${String(full)} ≠ ${String(HANZI_TOTAL)}`);
  assert.equal(blank, 2, `空白字形 ${String(blank)} 个（应该正好是两个空格）`);
  assert.equal(full + half + blank, CHARSET_TOTAL, "字形总数对不上");
});

test("★ 每个字形在图集里都真的有墨（结构判据全绿也挡不住这一类的坏）", () => {
  const cjk = built().cjk;
  const img = decodePng(new Uint8Array(cjk.png));
  if (!img.ok) throw new Error(`生成的 ui-font-cjk.png 解不开：${img.error.code} ${img.error.message}`);
  const png = img.value;
  assert.equal(png.width, cjk.atlas.width, "图宽与 atlas 声明不一致（UV 会整体错位）");
  assert.equal(png.height, cjk.atlas.height, "图高与 atlas 声明不一致");

  const blank: string[] = [];
  for (const g of cjk.placed) {
    if (g.w === 0) continue;
    let lit = 0;
    for (let y = 0; y < g.h; y++) {
      for (let x = 0; x < g.w; x++) {
        if ((png.pixels[((g.y + y) * png.width + (g.x + x)) * 4 + 3] ?? 0) > 0) lit++;
      }
    }
    if (lit === 0) blank.push(`U+${g.code.toString(16).padStart(4, "0")} ${JSON.stringify(String.fromCodePoint(g.code))}`);
  }
  assert.deepEqual(blank, [], `这些字形在图集里一个不透明像素都没有：${blank.slice(0, 20).join(" / ")}`);
});

test("★★ 图集里的位与源 BDF 的位逐位相同（UV 指错格 / 整列错位都在这条上现形）", () => {
  const cjk = built().cjk;
  const img = decodePng(new Uint8Array(cjk.png));
  if (!img.ok) throw new Error(`png 解不开：${img.error.message}`);
  const png = img.value;

  // 抽样：固定的几个"笔画数差别大"的字 + 按步长均匀取 64 个（步长由数据长度算出，不写死）
  const fixed = [0x4e2d, 0x6587, 0x4e00, 0x5668, 0x51f9, 0x51f8, 0x7684, 0x41];
  const step = Math.max(1, Math.floor(cjk.placed.length / 64));
  const codes = new Set<number>(fixed);
  for (let i = 0; i < cjk.placed.length; i += step) codes.add(cjk.placed[i]!.code);

  const src = sourceShapes([...codes]);
  let checked = 0;
  for (const g of cjk.placed) {
    if (!codes.has(g.code) || g.w === 0) continue;
    const s = src.glyphs.get(g.code);
    assert.ok(s !== undefined, `源 BDF 里没有 U+${g.code.toString(16)}`);
    const srcCols = s.cols;
    assert.ok(srcCols !== null, `源 BDF 里 U+${g.code.toString(16)} 没有墨，而图集里有`);
    for (let y = 0; y < g.h; y++) {
      for (let x = 0; x < g.w; x++) {
        const got = (png.pixels[((g.y + y) * png.width + (g.x + x)) * 4 + 3] ?? 0) > 0 ? 1 : 0;
        const want: number = srcCols[x]![y] === 1 ? 1 : 0;
        if (got !== want) {
          assert.fail(
            `U+${g.code.toString(16)} 的 (${String(x)},${String(y)}) 位不符：图集 ${String(got)} / 源 ${String(want)}`,
          );
        }
      }
    }
    checked++;
  }
  assert.ok(checked >= 60, `只比了 ${String(checked)} 个字形，抽样没生效`);
});

test("★★ 墨迹总量守恒：图里的不透明像素 = 所有字形墨迹位之和（两个字形叠在一格会在这条上现形）", () => {
  const cjk = built().cjk;
  const img = decodePng(new Uint8Array(cjk.png));
  if (!img.ok) throw new Error(`png 解不开：${img.error.message}`);
  const png = img.value;

  let inPng = 0;
  for (let i = 3; i < png.pixels.length; i += 4) if ((png.pixels[i] ?? 0) > 0) inPng++;
  let inGlyphs = 0;
  for (const g of cjk.placed) {
    for (const col of g.cols) for (const bit of col) if (bit === 1) inGlyphs++;
  }
  assert.ok(inGlyphs > 100000, `字形墨迹只有 ${String(inGlyphs)} 位，太小了（图集是不是空的？）`);
  // 相等意味着：① 没有墨落在字形矩形之外；② 没有两个字形共用一个像素。
  // 少一个像素都说明有一处叠了（叠在两处都有墨的地方，PNG 只记一次）。
  assert.equal(inPng, inGlyphs, `图里有 ${String(inPng)} 个不透明像素，字形墨迹是 ${String(inGlyphs)} 位`);
});

test("★ 货架式排布不重叠：同一行内 x 只增不减，相邻行的 y 间距 ≥ 上一行的最大字高", () => {
  const cjk = built().cjk;
  const bands = new Map<number, { x: number; w: number; h: number }[]>();
  for (const g of cjk.placed) {
    if (g.w === 0) continue;
    const list = bands.get(g.y) ?? [];
    list.push({ x: g.x, w: g.w, h: g.h });
    bands.set(g.y, list);
  }
  const ys = [...bands.keys()].sort((a, b) => a - b);
  assert.ok(ys.length > 100, `只有 ${String(ys.length)} 行货架，图集像是空的`);
  let prevBottom = -1;
  for (const y of ys) {
    const list = bands.get(y)!;
    list.sort((a, b) => a.x - b.x);
    let reach = 1; // 左边距 1px
    for (const g of list) {
      assert.ok(g.x > 0 && g.x + g.w <= cjk.atlas.width, `有字形横向越界：x=${String(g.x)} w=${String(g.w)}`);
      assert.ok(g.x >= reach, `同一行里 x=${String(g.x)} 与上一个字形（末尾 ${String(reach)}）重叠`);
      reach = g.x + g.w + 1;
    }
    const maxH = Math.max(...list.map((g) => g.h));
    assert.ok(y >= prevBottom, `第 y=${String(y)} 行压到了上一行（上一行底 ${String(prevBottom)}）`);
    prevBottom = y + maxH;
  }
  assert.ok(prevBottom <= cjk.atlas.height, `最后一个字形探到 ${String(prevBottom)}，图高只有 ${String(cjk.atlas.height)}`);
});

test("★ 基线：全高字形顶行落在行内第 1 行，底行不超出 lineHeight（否则下一行会切掉它）", () => {
  const font = loadDiskFont();
  // 14 - 13 = 1；18 - 1 = 17 ≥ 16
  assert.equal(font.base, 14, "base 应该是 Unifont 的 FONT_ASCENT=14");
  assert.equal(font.lineHeight, 18, "lineHeight = 上伸 14 + 下伸 2 + 2 行距");
  for (const code of [0x4e2d, 0x4e00, 0x41, 0x31]) {
    const g = font.glyphs.get(code);
    assert.ok(g !== undefined, `缺字形 U+${String(code)}`);
    assert.equal(font.base + g.yoffset, 1, `U+${String(code)} 的墨迹顶不在行内第 1 行（base + yoffset = ${String(font.base + g.yoffset)}）`);
    assert.ok(
      font.base + g.yoffset + g.height <= font.lineHeight,
      `U+${String(code)} 的墨迹底 ${String(font.base + g.yoffset + g.height)} 超出 lineHeight ${String(font.lineHeight)}`,
    );
  }
});

test("★★ 空白字形：半角空格前进 8、全角空格前进 16 —— 都是「宽 0 但推进」", () => {
  const font = loadDiskFont();
  const space = font.glyphs.get(0x20);
  assert.ok(space !== undefined, "缺半角空格");
  assert.equal(space.width, 0, "空格不该有墨迹宽");
  assert.equal(space.xadvance, 8, "半角空格前进 8（Unifont 的 DWIDTH）");
  const wide = font.glyphs.get(0x3000);
  assert.ok(wide !== undefined, "缺全角空格 U+3000（中文排版的缩进全靠它）");
  assert.equal(wide.width, 0, "全角空格不该有墨迹");
  assert.equal(wide.xadvance, 16, "全角空格前进 16 —— 写 8 的话中文缩进会少一半");
});

test("★ 混排宽度：中文 16、ASCII 8，一个不多一个不少", () => {
  const font = loadDiskFont();
  const l = layoutText(font, "中文 ABC");
  assert.deepEqual([...l.missing], [], "量算时出现了缺字（字符集与字体不一致）");
  assert.equal(l.width, 16 + 16 + 8 + 8 + 8 + 8, `宽度 ${String(l.width)} ≠ 16+16+8×4`);
  assert.equal(l.lineCount, 1);
  assert.equal(l.height, font.lineHeight, "单行高度应等于 lineHeight");
});

test("★ CJK 按字断行：32 个汉字在 100px 盒里每行 6 个（这条以前是死代码 —— 没有中文字形就走不到）", () => {
  const font = loadDiskFont();
  const text = "中".repeat(32);
  const l = layoutText(font, text, { maxWidth: 100 });
  // 6 × 16 = 96 ≤ 100，7 个就 112 超了
  assert.equal(l.lineCount, 6, `行数 ${String(l.lineCount)}（32 个字应折成 6/6/6/6/6/2 六行）`);
  assert.equal(l.width, 100, "有 maxWidth 时排版宽度就是盒子宽");
  for (const q of l.quads) {
    assert.ok(q.x + q.w <= 100 + 1e-9, `有四边形超出盒子：x=${String(q.x)} w=${String(q.w)}`);
  }
  // 断行只能发生在字与字之间：每个四边形都是完整的 16 宽，没有一个被切
  for (const q of l.quads) assert.equal(q.w, 16, "有字形被横切了");
});

test("★ 生成器与磁盘逐字节一致（六个资产，任何一个手改过都会红）", () => {
  const files = built().files;
  assert.equal(files.length, 6, "资产文件数变了（.fnt/.json 也算）");
  const drift: string[] = [];
  for (const [name, buf] of files) {
    let disk: Buffer;
    try {
      disk = readFileSync(join(ASSETS, name));
    } catch {
      drift.push(`${name} 不存在`);
      continue;
    }
    if (!disk.equals(Buffer.from(buf))) drift.push(`${name} 与生成器不一致`);
  }
  assert.deepEqual(drift, [], `这些资产与生成器不一致（手改过？还是忘了跑生成器？）：${drift.join(" / ")}`);
});

test("字体名不复用上游的 Unifont（OFL 的改名要求，见 ADR-0014）", () => {
  const text = fromDisk("ui-font-cjk.fnt");
  assert.ok(text.startsWith(`info face="${CJK_FACE}" `), `face 名不是 ${CJK_FACE}：${text.slice(0, 80)}`);
  assert.equal(text.includes('face="Unifont"'), false, "不能把上游字体名直接当成我方产物名");
  // `chars count` 与真实字形数一致：数字写错时解析器会照单全收（它不做交叉核对）
  const m = /^chars count=(\d+)$/m.exec(text);
  assert.ok(m !== null, ".fnt 里没有 chars count 行");
  assert.equal(Number(m[1]), CHARSET_TOTAL, `chars count=${m[1]} 与字形数 ${String(CHARSET_TOTAL)} 不一致`);
  // ★ 页号必须是**局部**的 0：`.fnt` 里写全局页号会得到自相矛盾的资产
  //   （`page id=2` 却没有 0/1 两行 ⇒ 解析器判"引用不存在的页"）。
  //   落到全局第 2 页靠 `parseBmFont({ pageBase: 2 })`，那也是判据在
  //   `ui-font.test.ts` 里单独守的一条。
  const pageLines = [...text.matchAll(/^page id=(\d+) file="([^"]+)"$/gm)];
  assert.equal(pageLines.length, 1, `.fnt 里应该正好一条 page 行，实际 ${String(pageLines.length)} 条`);
  assert.equal(pageLines[0]![1], "0", "page id 必须是 0（字体局部编号）");
  assert.equal(pageLines[0]![2], "ui-font-cjk.png", "page 的文件名要指向中文字形图");
});

// ── 金标与坏数据 ────────────────────────────────────────────────

/**
 * 手抄的位图金标。
 *
 * ★★ 为什么必须有这一条：上面那条「图集里的位与源 BDF 相同」拿**同一个解析器**
 *   当金标 —— 解析器把位序读反了，两边会一起反，那条判据照样绿。
 *   所以这里要一份**独立于代码**的期望值：从字形本来的样子抄下来。
 *
 * 四个字形各有分工：
 *   · `R` —— 不对称（左上圆弧 + 右下斜腿）：**水平镜像**在这里必死；
 *   · `A` —— 上下不对称（横杠偏下、两腿向上张开）：**垂直翻转**必死；
 *   · `中` —— 16×16 全角、笔画居中对称，但那一竖偏右一格：整列错位必死；
 *   · `月` —— 右下的钩在最后一行的最左一格：整体错位 / 少一行都必死。
 */
const GOLD: Readonly<Record<number, readonly string[]>> = {
  // A（8×16，墨迹在第 4..13 行）
  0x41: [
    "........",
    "........",
    "........",
    "........",
    "...##...",
    "..#..#..",
    "..#..#..",
    ".#....#.",
    ".#....#.",
    ".######.",
    ".#....#.",
    ".#....#.",
    ".#....#.",
    ".#....#.",
    "........",
    "........",
  ],
  // R（8×16）
  0x52: [
    "........",
    "........",
    "........",
    "........",
    ".#####..",
    ".#....#.",
    ".#....#.",
    ".#....#.",
    ".#####..",
    ".#..#...",
    ".#...#..",
    ".#...#..",
    ".#....#.",
    ".#....#.",
    "........",
    "........",
  ],
  // 中（16×16）
  0x4e2d: [
    ".......#........",
    ".......#........",
    ".......#........",
    ".......#........",
    "..###########...",
    "..#....#....#...",
    "..#....#....#...",
    "..#....#....#...",
    "..#....#....#...",
    "..#....#....#...",
    "..###########...",
    "..#....#....#...",
    ".......#........",
    ".......#........",
    ".......#........",
    ".......#........",
  ],
  // 月（16×16）
  0x6708: [
    "................",
    "....#########...",
    "....#.......#...",
    "....#.......#...",
    "....#.......#...",
    "....#########...",
    "....#.......#...",
    "....#.......#...",
    "....#.......#...",
    "....#########...",
    "....#.......#...",
    "....#.......#...",
    "...#........#...",
    "...#........#...",
    "..#.......#.#...",
    ".#.........#....",
  ],
};

test("★★★ 金标字形：四个字的位与手抄的期望逐位相同（镜像 / 翻转 / 错列必死）", () => {
  const cjk = built().cjk;
  const byCode = new Map(cjk.placed.map((g) => [g.code, g]));
  for (const [codeText, want] of Object.entries(GOLD)) {
    const code = Number(codeText);
    const g = byCode.get(code);
    assert.ok(g !== undefined, `字集里没有 U+${code.toString(16)}`);
    const cols = g.cols;
    assert.ok(cols !== null, `U+${code.toString(16)} 是空白字形，金标里不该有它`);
    const art: string[] = [];
    for (let y = 0; y < g.h; y++) {
      let row = "";
      for (const column of cols) row += column[y] === 1 ? "#" : ".";
      art.push(row);
    }
    assert.deepEqual(
      art,
      [...want],
      `U+${code.toString(16)} ${String.fromCodePoint(code)} 的位图与金标不一致：\n实际:\n${art.join("\n")}\n期望:\n${want.join("\n")}`,
    );
  }
});

/** 造一份最小 BDF（只留测试要动的那几行）。 */
function bdfText(over: { char?: string; bitmap?: string; bbx?: string; dwidth?: boolean } = {}): string {
  const bbx = over.bbx ?? "8 2 0 0";
  const bitmap = over.bitmap ?? "80\nC0";
  return [
    "STARTFONT 2.1",
    "FONTBOUNDINGBOX 8 16 0 -2",
    "FONT_ASCENT 14",
    "FONT_DESCENT 2",
    "CHARS 1",
    "STARTCHAR A",
    "ENCODING 65",
    ...(over.dwidth === false ? [] : ["DWIDTH 8 0"]),
    `BBX ${bbx}`,
    "BITMAP",
    bitmap,
    "ENDCHAR",
    ...(over.char === undefined ? [] : [over.char]),
    "ENDFONT",
  ].join("\n");
}

/**
 * ★★ 坏 BDF 必须报错，且**错误码能指出是哪一类坏**。
 *   容忍一个少一行的 BITMAP，得到的是"这个字缺一块"—— 排版照旧推进、
 *   宽度全对、界面上只是少了几笔。那类错误只有解析器能挡。
 */
test("★★ 坏 BDF 一律报错：行数不符 / 十六进制位数不符 / 缺字段 / 嵌套字形", () => {
  const code = (text: string): string => {
    try {
      parseBdf(text);
      return "OK";
    } catch (e) {
      return (e as Error).message.split("：")[0] ?? "?";
    }
  };
  assert.equal(code(bdfText()), "OK", "最小合法样本自己先得能过");

  // BITMAP 少一行（BBX 说 2 行，实际给 1 行）→ 那个字会缺一整行
  assert.equal(code(bdfText({ bitmap: "80" })), "BDF.BAD_ROW_COUNT");
  // 每行按字节对齐：8 宽 ⇒ 2 个十六进制字符。给 4 个不是"多写了一位"，是坏数据
  assert.equal(code(bdfText({ bitmap: "8000\nC000" })), "BDF.BAD_ROW");
  assert.equal(code(bdfText({ bitmap: "8Z\nC0" })), "BDF.BAD_HEX");
  assert.equal(code(bdfText({ bbx: "8" })), "BDF.BAD_BBX");
  assert.equal(code(bdfText({ dwidth: false })), "BDF.NO_DWIDTH");
  // 上一个字形没 ENDCHAR 就开下一个 → 状态机会把两段混成一段
  // （手工拼一份：第二个 STARTCHAR 必须插在**第一个 ENDCHAR 之前**，那是"忘了 ENDCHAR"的真实形态）
  const nested = [
    "STARTFONT 2.1",
    "FONT_ASCENT 14",
    "FONT_DESCENT 2",
    "STARTCHAR A",
    "ENCODING 65",
    "DWIDTH 8 0",
    "BBX 8 2 0 0",
    "BITMAP",
    "80",
    "C0",
    "STARTCHAR B",
    "ENCODING 66",
    "ENDCHAR",
    "ENDFONT",
  ].join("\n");
  assert.equal(code(nested), "BDF.NESTED");
  // 缺上伸/下伸 ⇒ 行高与基线都不可知
  assert.equal(code("STARTFONT 2.1\nFONTBOUNDINGBOX 8 16 0 -2\nCHARS 0\nENDFONT"), "BDF.NO_METRIC");
});
