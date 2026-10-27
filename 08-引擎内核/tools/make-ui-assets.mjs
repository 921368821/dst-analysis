/**
 * 生成 UI 用的**位图字体**与**皮肤图集**（`web/assets/ui-*.{png,fnt,json}`）
 *
 * 为什么要有这个脚本：
 *   引擎在批66 接上了 BMFont 解析与 UI 绘制，但仓库里**一个字体资产都没有** ——
 *   于是"引擎能画 UI"这件事没有证据，宿主的 HUD 仍旧是手写 DOM。
 *   这个脚本把「字形表 + 皮肤配色」变成真的 `.fnt` / `.png`，
 *   于是 UI 从"解析器能过判据"变成"画面上真有字"。
 *
 * ★ 为什么字形是**手写的位图表**，不是渲染系统字体：
 *   ① 可复现：系统字体随机器/版本变，同输入不同产物；手写表一个字节都不会变；
 *   ② 像素风：饥荒那一类游戏本来就不做字形抗锯齿，5×7 手绘比 12px 系统字体更像；
 *   ③ CI 可跑：Linux runner 上没有任何中文字体，一旦依赖系统字体，
 *      这条生成链在 CI 上会静默产出另一张图（同输入不同产物，判据却全绿）。
 *
 * ★ 五×七 那张的字符集 = 可打印 ASCII（32..126）+ 省略号（…）。**不含中文**。
 *   中文走**第二张**字体（`ui-font-cjk`），它由 `vendor/unifont` 里的上游 BDF 生成 ——
 *   见本文件末尾的"中文字体"一节，以及 `docs/adr/0014-vendored-font-asset.md`。
 *
 * ★★ 两个字体，不是"一个字体里的两类字"：
 *   5×7 是**手绘**的（大写字高 7、行高 10），16×16 的中文是**上游位图字库**里的。
 *   把中文塞进 5×7 的单元格是不可能的（汉字要 16 格），而把 ASCII 也换成 Unifont 的
 *   8×16 会让 HUD 的三行突然高 60% —— 那是**改版**，不是"支持中文"。
 *   于是它们各自是一张图集、一个 `.fnt`、一个字体 id；节点用 `props.fontId` 选。
 *
 * ★ 单元格：5 宽 × 8 高，**基线在第 7 行下沿**（`base = 7`）。
 *   于是行 0..6 在基线上方（大写字高 7）、行 7 在基线下方（`g j p q y` 的尾巴）。
 *   lineHeight = 10 留 2px 行距：字体放大到 2 倍时行距也跟着放大，不会挤在一起。
 *
 * 用法：node tools/make-ui-assets.mjs [--check]
 *   --check 只比对磁盘上的产物与"现在会生成的内容"，不一致就退出码 1
 *   （防止有人手改 PNG 却忘了改生成器 —— 那会让"可复现"变成一句空话）。
 */

import { deflateSync, gunzipSync } from "node:zlib";
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, dirname, resolve } from "node:path";
import { encodePng } from "./png-encode.mjs";
import { parseBdf } from "./bdf.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const OUT = join(HERE, "..", "web", "assets");

// ------------------------------------------------------------------ 字形表
//
// 每个字形是若干行、每行 5 个字符（"1" = 墨，"0" = 空）。
// `top` 是该字形第一行落在 8 行单元格的哪一行 —— 它决定了"这个字贴不贴基线"：
//   大写/数字/符号：top=0，7 行（占满基线上方）
//   小写 x-height：top=2，5 行（b/d/f 那类有升部的走 top=0）
//   带尾巴的（g/j/p/q/y）：top=2，6 行（最后一行落到基线下方）
//
// ★ 不写字距/字宽：宽度由图里的墨迹列数决定（见 buildGlyphs），
//   于是"i"窄、"W"宽 —— 固定 5 宽会让一句话里到处是空洞。

const CAP = (rows) => ({ top: 0, rows });
const ASC = (rows) => ({ top: 0, rows });
const LOW = (rows) => ({ top: 2, rows });
const DESC = (rows) => ({ top: 2, rows });

/** @type {Record<string, {top:number, rows:string[]}>} */
const GLYPHS = {
  "!": CAP(["00100", "00100", "00100", "00100", "00100", "00000", "00100"]),
  '"': CAP(["01010", "01010", "00000", "00000", "00000", "00000", "00000"]),
  "#": CAP(["01010", "01010", "11111", "01010", "11111", "01010", "01010"]),
  $: CAP(["00100", "01111", "10100", "01110", "00101", "11110", "00100"]),
  "%": CAP(["11001", "11010", "00100", "01000", "10011", "00011", "00000"]),
  "&": CAP(["01100", "10010", "01100", "10101", "10010", "01101", "00010"]),
  "'": CAP(["00100", "00100", "00000", "00000", "00000", "00000", "00000"]),
  "(": CAP(["00010", "00100", "01000", "01000", "01000", "00100", "00010"]),
  ")": CAP(["01000", "00100", "00010", "00010", "00010", "00100", "01000"]),
  "*": CAP(["00000", "10101", "01110", "11111", "01110", "10101", "00000"]),
  "+": CAP(["00000", "00100", "00100", "11111", "00100", "00100", "00000"]),
  ",": CAP(["00000", "00000", "00000", "00000", "00000", "00110", "00100"]),
  "-": CAP(["00000", "00000", "00000", "11111", "00000", "00000", "00000"]),
  ".": CAP(["00000", "00000", "00000", "00000", "00000", "00110", "00110"]),
  "/": CAP(["00001", "00001", "00010", "00100", "01000", "10000", "10000"]),
  ":": CAP(["00000", "00110", "00110", "00000", "00110", "00110", "00000"]),
  ";": CAP(["00000", "00110", "00110", "00000", "00110", "00100", "00000"]),
  "<": CAP(["00010", "00100", "01000", "10000", "01000", "00100", "00010"]),
  "=": CAP(["00000", "00000", "11111", "00000", "11111", "00000", "00000"]),
  ">": CAP(["01000", "00100", "00010", "00001", "00010", "00100", "01000"]),
  "?": CAP(["01110", "10001", "00001", "00010", "00100", "00000", "00100"]),
  "@": CAP(["01110", "10001", "10111", "10101", "10111", "10000", "01110"]),
  "[": CAP(["00110", "00100", "00100", "00100", "00100", "00100", "00110"]),
  "\\": CAP(["10000", "10000", "01000", "00100", "00010", "00001", "00001"]),
  "]": CAP(["01100", "00100", "00100", "00100", "00100", "00100", "01100"]),
  "^": CAP(["00100", "01010", "10001", "00000", "00000", "00000", "00000"]),
  _: CAP(["00000", "00000", "00000", "00000", "00000", "00000", "11111"]),
  "`": CAP(["01000", "00100", "00000", "00000", "00000", "00000", "00000"]),
  "{": CAP(["00010", "00100", "00100", "01000", "00100", "00100", "00010"]),
  "|": CAP(["00100", "00100", "00100", "00100", "00100", "00100", "00100"]),
  "}": CAP(["01000", "00100", "00100", "00010", "00100", "00100", "01000"]),
  "~": CAP(["00000", "00000", "01000", "10101", "00010", "00000", "00000"]),

  A: CAP(["01110", "10001", "10001", "11111", "10001", "10001", "10001"]),
  B: CAP(["11110", "10001", "11110", "10001", "10001", "10001", "11110"]),
  C: CAP(["01110", "10001", "10000", "10000", "10000", "10001", "01110"]),
  D: CAP(["11110", "10001", "10001", "10001", "10001", "10001", "11110"]),
  E: CAP(["11111", "10000", "11110", "10000", "10000", "10000", "11111"]),
  F: CAP(["11111", "10000", "11110", "10000", "10000", "10000", "10000"]),
  G: CAP(["01110", "10001", "10000", "10111", "10001", "10001", "01111"]),
  H: CAP(["10001", "10001", "10001", "11111", "10001", "10001", "10001"]),
  I: CAP(["11111", "00100", "00100", "00100", "00100", "00100", "11111"]),
  J: CAP(["00111", "00010", "00010", "00010", "00010", "10010", "01100"]),
  K: CAP(["10001", "10010", "10100", "11000", "10100", "10010", "10001"]),
  L: CAP(["10000", "10000", "10000", "10000", "10000", "10000", "11111"]),
  M: CAP(["10001", "11011", "10101", "10101", "10001", "10001", "10001"]),
  N: CAP(["10001", "11001", "10101", "10011", "10001", "10001", "10001"]),
  O: CAP(["01110", "10001", "10001", "10001", "10001", "10001", "01110"]),
  P: CAP(["11110", "10001", "10001", "11110", "10000", "10000", "10000"]),
  Q: CAP(["01110", "10001", "10001", "10001", "10101", "10010", "01101"]),
  R: CAP(["11110", "10001", "10001", "11110", "10100", "10010", "10001"]),
  S: CAP(["01111", "10000", "10000", "01110", "00001", "00001", "11110"]),
  T: CAP(["11111", "00100", "00100", "00100", "00100", "00100", "00100"]),
  U: CAP(["10001", "10001", "10001", "10001", "10001", "10001", "01110"]),
  V: CAP(["10001", "10001", "10001", "10001", "10001", "01010", "00100"]),
  W: CAP(["10001", "10001", "10001", "10101", "10101", "11011", "10001"]),
  X: CAP(["10001", "10001", "01010", "00100", "01010", "10001", "10001"]),
  Y: CAP(["10001", "10001", "01010", "00100", "00100", "00100", "00100"]),
  Z: CAP(["11111", "00001", "00010", "00100", "01000", "10000", "11111"]),

  0: CAP(["01110", "10001", "10011", "10101", "11001", "10001", "01110"]),
  1: CAP(["00100", "01100", "00100", "00100", "00100", "00100", "11111"]),
  2: CAP(["01110", "10001", "00001", "00010", "00100", "01000", "11111"]),
  3: CAP(["11111", "00010", "00100", "00010", "00001", "10001", "01110"]),
  4: CAP(["00010", "00110", "01010", "10010", "11111", "00010", "00010"]),
  5: CAP(["11111", "10000", "11110", "00001", "00001", "10001", "01110"]),
  6: CAP(["00110", "01000", "10000", "11110", "10001", "10001", "01110"]),
  7: CAP(["11111", "00001", "00010", "00100", "01000", "01000", "01000"]),
  8: CAP(["01110", "10001", "10001", "01110", "10001", "10001", "01110"]),
  9: CAP(["01110", "10001", "10001", "01111", "00001", "00010", "01100"]),

  a: LOW(["01110", "00001", "01111", "10001", "01111"]),
  b: ASC(["10000", "10000", "11110", "10001", "10001", "10001", "11110"]),
  c: LOW(["01110", "10000", "10000", "10000", "01110"]),
  d: ASC(["00001", "00001", "01111", "10001", "10001", "10001", "01111"]),
  e: LOW(["01110", "10001", "11111", "10000", "01110"]),
  f: ASC(["00110", "01000", "11110", "01000", "01000", "01000", "01000"]),
  g: DESC(["01111", "10001", "10001", "01111", "00001", "01110"]),
  h: ASC(["10000", "10000", "11110", "10001", "10001", "10001", "10001"]),
  i: ASC(["00100", "00000", "00100", "00100", "00100", "00100", "00100"]),
  j: ASC(["00010", "00000", "00010", "00010", "00010", "10010", "01100"]),
  k: ASC(["10000", "10000", "10010", "10100", "11000", "10100", "10010"]),
  l: ASC(["01100", "00100", "00100", "00100", "00100", "00100", "01110"]),
  m: LOW(["11010", "10101", "10101", "10101", "10101"]),
  n: LOW(["11110", "10001", "10001", "10001", "10001"]),
  o: LOW(["01110", "10001", "10001", "10001", "01110"]),
  p: DESC(["11110", "10001", "10001", "11110", "10000", "10000"]),
  q: DESC(["01111", "10001", "10001", "01111", "00001", "00001"]),
  r: LOW(["10110", "11000", "10000", "10000", "10000"]),
  s: LOW(["01111", "10000", "01110", "00001", "11110"]),
  t: ASC(["01000", "01000", "11110", "01000", "01000", "01000", "01100"]),
  u: LOW(["10001", "10001", "10001", "10001", "01111"]),
  v: LOW(["10001", "10001", "10001", "01010", "00100"]),
  w: LOW(["10001", "10001", "10101", "10101", "01010"]),
  x: LOW(["10001", "01010", "00100", "01010", "10001"]),
  y: DESC(["10001", "10001", "10001", "01111", "00001", "01110"]),
  z: LOW(["11111", "00010", "00100", "01000", "11111"]),

  // 省略号：截断时补的那个字符。**必须在字体里**，否则"文字被裁了"会变成
  // "裁了而且末尾缺一个字"—— 看起来像另一个 bug。
  "\u2026": CAP(["00000", "00000", "00000", "00000", "00000", "00000", "10101"]),
};

const CELL_W = 5;
const CELL_H = 8;
const BASE = 7;
const LINE_HEIGHT = 10;
/** 字间空隙（px）。加在墨迹宽度上得到 xadvance。 */
const TRACKING = 1;
/** 空格不画东西，但要有前进量 —— 它是唯一"宽 0 高 0 且 xadvance > 0"的字形。 */
const SPACE_ADVANCE = 4;

// ------------------------------------------------------------------ 墨迹盒
//
// 把字符表里的行数组变成「裁剪后的墨迹矩形 + 落点」。
// 水平也裁：固定 5 宽会让 "i" 与 "W" 占同样的位置，一句话里到处是空洞。

function buildGlyphs() {
  /** @type {{code:number, cols:number[][], w:number, h:number, top:number}[]} */
  const out = [];
  for (const [ch, def] of Object.entries(GLYPHS)) {
    const code = ch.codePointAt(0);
    // 行对齐到 8 行单元格：顶部补 `top` 个空行
    const rows = [];
    for (let i = 0; i < def.top; i++) rows.push("00000");
    for (const r of def.rows) {
      if (r.length !== CELL_W) throw new Error(`字形 ${JSON.stringify(ch)} 有一行不是 ${CELL_W} 列：${r}`);
      rows.push(r);
    }
    if (rows.length > CELL_H) throw new Error(`字形 ${JSON.stringify(ch)} 有 ${rows.length} 行，超过单元格 ${CELL_H}`);
    while (rows.length < CELL_H) rows.push("00000");

    // 墨迹盒（左/右/上/下）
    let x0 = CELL_W;
    let x1 = -1;
    let y0 = CELL_H;
    let y1 = -1;
    for (let y = 0; y < CELL_H; y++) {
      for (let x = 0; x < CELL_W; x++) {
        if (rows[y][x] !== "1") continue;
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
    if (x1 < 0) throw new Error(`字形 ${JSON.stringify(ch)} 是空的（手写表里全是 0）`);
    const w = x1 - x0 + 1;
    const h = y1 - y0 + 1;
    // 逐列取出（后面按列写像素）
    const cols = [];
    for (let x = x0; x <= x1; x++) {
      const col = [];
      for (let y = y0; y <= y1; y++) col.push(rows[y][x] === "1" ? 1 : 0);
      cols.push(col);
    }
    // `top` 是墨迹顶行在单元格里的行号（0 = 单元格第一行）。
    // 换成**相对基线的高度** `inkTop` —— 那是 `.fnt` 里 `yoffset` 要的东西，
    // 而 BDF 那边天生给的也是这个量（`yoff + h - 1`），于是两条来源在这一点上统一。
    out.push({ code, cols, w, h, inkTop: BASE - y0, advance: w + TRACKING });
  }
  // 空格单独加：没有墨迹，只有前进量
  out.push({ code: 32, cols: [], w: 0, h: 0, inkTop: 0, advance: SPACE_ADVANCE });
  out.sort((a, b) => a.code - b.code);
  return out;
}

// ------------------------------------------------------------------ 排布

/**
 * 货架式打包（与图集打包同一个思路，但不需要 rotation/padding 那些花样）：
 * 一行排不下就换行，行高 = 该字体的单元格高 + 1 间距。
 * 结果对输入顺序**完全确定**，所以产物逐字节可复现。
 *
 * ★ `rowH` 必须传进来，不能用全局的 `CELL_H`：两张字体的单元格高不同（8 与 16），
 *   而**每行多高决定了下一行的 y** —— 用错常量不会报错，只会让字形逐行往下错。
 */
function pack(glyphs, atlasW, rowH) {
  let x = 1;
  let row = 0;
  const placed = [];
  for (const g of glyphs) {
    if (g.w === 0) {
      placed.push({ ...g, x: 0, y: 0 });
      continue;
    }
    // `+ 1` 是左右各留半个像素之外的那 1px 间距：两个字形紧贴时，
    // 双线性放大（mipmap 或 UI scale）会把邻居的墨**渗**过来。
    if (x + g.w + 1 > atlasW) {
      row++;
      x = 1;
    }
    placed.push({ ...g, x, y: row * rowH + 1 });
    x += g.w + 1;
  }
  const rows = row + 1;
  return { placed, height: rows * rowH + 1 };
}

// ------------------------------------------------------------------ 画字体图

function buildFontImage(placed, width, height) {
  const samples = new Array(width * height * 4).fill(0);
  for (const g of placed) {
    if (g.w === 0) continue;
    for (let cx = 0; cx < g.w; cx++) {
      for (let cy = 0; cy < g.h; cy++) {
        if (g.cols[cx][cy] !== 1) continue;
        const px = g.x + cx;
        const py = g.y + cy;
        const at = (py * width + px) * 4;
        // 纯白不透明：颜色由顶点的 tint 决定，图里只存"形状"
        samples[at] = 255;
        samples[at + 1] = 255;
        samples[at + 2] = 255;
        samples[at + 3] = 255;
      }
    }
  }
  return encodePng({ width, height, colorType: 6, bitDepth: 8, samples, interlace: 0, filter: 0 });
}

// ------------------------------------------------------------------ 皮肤图
//
// 三块 16×16 的补丁，颜色写死（不跟随主题）：皮肤是**资产**，
// 换配色应该换一张图，而不是在代码里改常量 —— 后者会让"美术改了个色"
// 变成一次代码提交。

const SKIN_W = 64;
const SKIN_H = 16;

const PATCHES = [
  { name: "panel", x: 0, y: 0, w: 16, h: 16, slice: 6, fill: [30, 34, 40, 220], edge: [120, 134, 150, 255] },
  { name: "button", x: 16, y: 0, w: 16, h: 16, slice: 5, fill: [52, 60, 72, 240], edge: [150, 168, 190, 255] },
  { name: "bar", x: 32, y: 0, w: 16, h: 8, slice: 0, fill: [200, 210, 120, 255], edge: [200, 210, 120, 255] },
  { name: "slot", x: 48, y: 0, w: 16, h: 8, slice: 3, fill: [44, 50, 60, 230], edge: [96, 108, 124, 255] },
];

function buildSkinImage() {
  const samples = new Array(SKIN_W * SKIN_H * 4).fill(0);
  const put = (x, y, rgba) => {
    if (x < 0 || y < 0 || x >= SKIN_W || y >= SKIN_H) return;
    const at = (y * SKIN_W + x) * 4;
    samples[at] = rgba[0];
    samples[at + 1] = rgba[1];
    samples[at + 2] = rgba[2];
    samples[at + 3] = rgba[3];
  };
  for (const p of PATCHES) {
    const radius = p.slice > 0 ? Math.min(3, Math.floor(p.slice / 2)) : 0;
    for (let y = 0; y < p.h; y++) {
      for (let x = 0; x < p.w; x++) {
        // 圆角：四个角的方块按半径切掉（像素风不要抗锯齿）
        const inCorner =
          (x < radius && y < radius && x + y < radius) ||
          (x >= p.w - radius && y < radius && (p.w - 1 - x) + y < radius) ||
          (x < radius && y >= p.h - radius && x + (p.h - 1 - y) < radius) ||
          (x >= p.w - radius && y >= p.h - radius && (p.w - 1 - x) + (p.h - 1 - y) < radius);
        if (inCorner) {
          put(p.x + x, p.y + y, [0, 0, 0, 0]);
          continue;
        }
        const isEdge = x === 0 || y === 0 || x === p.w - 1 || y === p.h - 1;
        put(p.x + x, p.y + y, isEdge ? p.edge : p.fill);
      }
    }
  }
  return encodePng({ width: SKIN_W, height: SKIN_H, colorType: 6, bitDepth: 8, samples, interlace: 0, filter: 0 });
}

// ------------------------------------------------------------------ .fnt

function buildFnt(placed, width, height, meta) {
  const lines = [];
  lines.push(
    `info face="${meta.face}" size=${String(meta.size)} bold=0 italic=0 charset="" unicode=1 ` +
      `stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=${String(meta.tracking)},0`,
  );
  lines.push(
    `common lineHeight=${String(meta.lineHeight)} base=${String(meta.base)} scaleW=${String(width)} scaleH=${String(height)} ` +
      `pages=1 packed=0 alphaChnl=0 redChnl=0 greenChnl=0 blueChnl=0`,
  );
  // ★ 页号在 `.fnt` 里**恒为 0**：BMFont 的 `page id` 是字体局部的，
  //   "这份字体落在全局图集的第几页"由宿主在解析时给（`parseBmFont({ pageBase })`）。
  //   在这里写全局页号会得到自相矛盾的资产：只声明 `page id=2` 却没有 0/1 两行。
  lines.push(`page id=0 file="${meta.page}"`);
  lines.push(`chars count=${String(placed.length)}`);
  for (const g of placed) {
    // `yoffset` 相对**基线**、向上为负：墨迹顶行在基线上方 `inkTop` 像素。
    // ★ 宽 0 的字形也要写 yoffset=0：写了别的值会让"空格之后的那一格"整体偏移。
    const yoffset = g.w === 0 ? 0 : -g.inkTop;
    lines.push(
      `char id=${String(g.code)} x=${String(g.x)} y=${String(g.y)} width=${String(g.w)} height=${String(g.h)} ` +
        `xoffset=${String(g.xoff ?? 0)} yoffset=${String(yoffset)} xadvance=${String(g.advance)} page=0 chnl=15`,
    );
  }
  lines.push(`kernings count=0`);
  return lines.join("\n") + "\n";
}

function buildSkinJson() {
  return (
    JSON.stringify(
      {
        image: "ui-skin.png",
        width: SKIN_W,
        height: SKIN_H,
        // 每块补丁的切片边距（设计 px）。9-slice 的边距是**源图**的边距，
        // 与目标尺寸无关 —— 所以它跟图走，不跟控件走。
        frames: PATCHES.map((p) => ({ name: p.name, x: p.x, y: p.y, w: p.w, h: p.h, slice: p.slice })),
      },
      null,
      2,
    ) + "\n"
  );
}

// ------------------------------------------------------------------ 中文字体
//
// 与上面 5×7 那张的关系是「另一张字体」，不是「同一张的扩展」（见文件头）：
// 汉字要 16×16 的格，塞不进 5×7 的单元格；而把 ASCII 也换成 16 高的，
// HUD 三行会突然高 60% —— 那是改版，不是"支持中文"。
//
// 字形**不手绘**：来自 `vendor/unifont` 的上游 BDF（GNU Unifont 18.0.01，OFL-1.1）。
// 手绘 6763 个汉字不现实，而"渲染系统字体再截图"会把可复现性交给宿主 ——
// 那正是这个脚本从第一天起就在避免的事。
//
// ★★ 为什么只打**声明的字符集**而不是整字库：
//   Unifont 有 57086 个字形，其中四万多个我们永远用不到。全打进去的图集大十倍，
//   而"大部分字不出现"这件事在产物里看不出来 —— 于是没人会去删。
//   反过来，字符集是仓库里的一个文本文件（`tools/cjk-charset.txt`），
//   "某个字没打进去"是可 diff 的事实，而且有判据盯着它的另一面：
//   **字符集里的每个字，在图集里都必须真的有墨**。

const CJK_VENDOR = join(HERE, "..", "vendor", "unifont", "unifont-18.0.01.bdf.gz");
const CHARSET_FILE = join(HERE, "cjk-charset.txt");
/** 图集宽度（px）。1024 让一行放得下六十来个全角字，图集接近正方。 */
const CJK_ATLAS_W = 1024;
/** `info face` 里的名字。**不复用上游的 `Unifont` 这个名字**（OFL 的要求，见 ADR-0014）。 */
const CJK_FACE = "unifont-cjk-16-subset";

/**
 * 读字符集。三种行：`#` 注释与空行、`@ascii LO HI`、以及"每个字符都是一次请求"的行。
 *
 * ★ 以 `@` 开头却不认识的指令**必须报错**：将来的自己会想加 `@range 4E00 9FFF`，
 *   而拼错成 `@rang` 之后静默忽略，得到的是"少了几千个字"的图集 —— 没人在看。
 * ★ 空白字符只能经 `@ascii` 声明：正文行会被 `trim()`，行首行尾的空格根本留不住。
 */
function loadCharset() {
  const codes = new Set();
  const text = readFileSync(CHARSET_FILE, "utf8");
  const rows = text.split(/\r?\n/);
  for (let i = 0; i < rows.length; i++) {
    const line = rows[i].trim();
    if (line === "" || line.startsWith("#")) continue;
    const m = /^@ascii\s+(\d+)\s+(\d+)$/.exec(line);
    if (m !== null) {
      const lo = Number(m[1]);
      const hi = Number(m[2]);
      if (!(lo <= hi)) throw new Error(`字符集第 ${i + 1} 行：@ascii 的区间反了（${lo} > ${hi}）`);
      for (let c = lo; c <= hi; c++) codes.add(c);
      continue;
    }
    if (line.startsWith("@")) throw new Error(`字符集第 ${i + 1} 行：不认识的指令 ${line}`);
    for (const ch of line) codes.add(ch.codePointAt(0));
  }
  if (codes.size === 0) throw new Error("字符集是空的（连 ASCII 都没有声明）");
  return codes;
}

function buildCjkFont() {
  const codes = loadCharset();
  const bdf = parseBdf(gunzipSync(readFileSync(CJK_VENDOR)).toString("utf8"), codes);

  // ★ 字符集里的每个码点都必须在字库里。缺一个字的症状是"这个字永远不显示"，
  //   而它不报错：排版照旧推进（走到 `missingAdvance`），界面上是一片空白。
  const missing = [...codes].filter((c) => !bdf.glyphs.has(c)).sort((a, b) => a - b);
  if (missing.length > 0) {
    const show = missing.slice(0, 20).map((c) => `U+${c.toString(16).toUpperCase()} ${String.fromCodePoint(c)}`);
    throw new Error(`字符集里有 ${missing.length} 个码点在 Unifont 里没有字形：${show.join(" / ")}`);
  }

  const glyphs = [...bdf.glyphs.values()]
    .map((g) => ({
      code: g.code,
      cols: g.cols ?? [],
      w: g.w,
      h: g.h,
      // BDF 的 `yoff` 是**位图底行**相对基线、向上为正 ⇒ 顶行 = yoff + h - 1。
      // ★ 这个换算是整条链上唯一一处"BDF 坐标 → BMFont 坐标"，所以它必须只有一份。
      inkTop: g.yoff + g.h - 1,
      advance: g.advance,
      xoff: g.xoff,
    }))
    .sort((a, b) => a.code - b.code);

  const packed = pack(glyphs, CJK_ATLAS_W, bdf.bboxH + 1);
  const meta = {
    face: CJK_FACE,
    size: bdf.bboxH,
    // Unifont 是等宽格：字距为 0，前进量已经在 `DWIDTH` 里（半角 8 / 全角 16）
    tracking: 0,
    // 行高 = 上伸 + 下伸 + 2：像素风的小字如果行紧贴，两句之间会**粘成一行**
    lineHeight: bdf.ascent + bdf.descent + 2,
    base: bdf.ascent,
    page: "ui-font-cjk.png",
  };
  return {
    png: buildFontImage(packed.placed, CJK_ATLAS_W, packed.height),
    fnt: buildFnt(packed.placed, CJK_ATLAS_W, packed.height, meta),
    glyphCount: glyphs.length,
    blank: glyphs.filter((g) => g.w === 0).length,
    atlas: { width: CJK_ATLAS_W, height: packed.height },
    placed: packed.placed,
    meta,
  };
}

// ------------------------------------------------------------------ main

const ATLAS_W = 128;

function build() {
  const glyphs = buildGlyphs();
  const packed = pack(glyphs, ATLAS_W, CELL_H + 1);
  const fontPng = buildFontImage(packed.placed, ATLAS_W, packed.height);
  const fnt = buildFnt(packed.placed, ATLAS_W, packed.height, {
    face: "engine5x7",
    size: CELL_H,
    tracking: TRACKING,
    lineHeight: LINE_HEIGHT,
    base: BASE,
    page: "ui-font.png",
  });
  const cjk = buildCjkFont();
  const skinPng = buildSkinImage();
  const skinJson = buildSkinJson();
  return {
    files: [
      ["ui-font.png", fontPng],
      ["ui-font.fnt", Buffer.from(fnt, "utf8")],
      ["ui-font-cjk.png", cjk.png],
      ["ui-font-cjk.fnt", Buffer.from(cjk.fnt, "utf8")],
      ["ui-skin.png", skinPng],
      ["ui-skin.json", Buffer.from(skinJson, "utf8")],
    ],
    glyphCount: glyphs.length,
    placed: packed.placed,
    atlas: { width: ATLAS_W, height: packed.height },
    cjk,
  };
}

/** 把字面渲染成 ASCII 图 —— 手写表写错时，这是唯一"用眼睛就能发现"的通道。 */
function preview(placed, text, cellH) {
  const rows = new Array(cellH).fill("");
  for (const ch of text) {
    const g = placed.find((x) => x.code === ch.codePointAt(0));
    if (g === undefined) throw new Error(`预览文本里有字体没有的字符：${JSON.stringify(ch)}`);
    for (let y = 0; y < cellH; y++) {
      let line = "";
      for (let x = 0; x < g.w; x++) line += g.cols[x][y] === 1 ? "#" : ".";
      rows[y] += line + (g.w === 0 ? ".." : " ");
    }
  }
  return rows.map((r) => r.trimEnd()).join("\n");
}

function main() {
  const check = process.argv.includes("--check");
  const built = build();
  mkdirSync(OUT, { recursive: true });

  if (check) {
    const drift = [];
    for (const [name, buf] of built.files) {
      const p = join(OUT, name);
      if (!existsSync(p)) {
        drift.push(`${name} 不存在`);
        continue;
      }
      if (!readFileSync(p).equals(buf)) drift.push(`${name} 与生成器不一致`);
    }
    if (drift.length > 0) {
      console.error(`✗ UI 资产与生成器不一致（有人手改过？）：\n  ${drift.join("\n  ")}`);
      console.error("  修法：node tools/make-ui-assets.mjs");
      process.exit(1);
    }
    console.log(
      `✓ UI 资产与生成器一致（5×7：${String(built.glyphCount)} 个字形 / ${String(built.atlas.width)}x${String(built.atlas.height)}；` +
        `中文：${String(built.cjk.glyphCount)} 个字形 / ${String(built.cjk.atlas.width)}x${String(built.cjk.atlas.height)}）`,
    );
    return;
  }

  for (const [name, buf] of built.files) {
    writeFileSync(join(OUT, name), buf);
    console.log(`· ${name}  ${String(buf.length)} 字节`);
  }
  console.log(`5×7 字形 ${String(built.glyphCount)} 个 · 图集 ${String(built.atlas.width)}x${String(built.atlas.height)}`);
  console.log(
    `中文 字形 ${String(built.cjk.glyphCount)} 个（其中空白 ${String(built.cjk.blank)} 个）· ` +
      `图集 ${String(built.cjk.atlas.width)}x${String(built.cjk.atlas.height)} · ` +
      `行高 ${String(built.cjk.meta.lineHeight)} 基线 ${String(built.cjk.meta.base)}`,
  );
  // 自检预览：两行足够看出"字母是不是歪的、基线是不是齐的"
  console.log("\n" + preview(built.placed, "READY go 0123 hp 45/100", CELL_H));
  // 中文预览同样必要：**字形错位/串行**在这上面一眼可见，而像素级判据只会说"有墨"。
  // 挑的都是笔画数差别大的字：一（1 画）／繁（17 画）／凹凸（结构怪）／器（四个口）。
  // ★ 这里只能用**字符集里有的字**：预览函数遇到图集外的字会直接抛错 ——
  //   这正是"字符集是一份可核对的清单"的另一面（第一版写了个「囧」，它不是 GB2312 字，
  //   于是这条预览当场报错，而不是在屏幕上悄悄缺一个字）。
  console.log("\n" + preview(built.cjk.placed, "中文 ABC 一繁凹凸器 123", built.cjk.meta.size));
}

// ★ 只在"被当成脚本执行"时跑 main()：判据要 `import { build }` 拿到**内存里的产物**
//   去逐条断言（见 `tests/extensions/ui-cjk-font.test.ts`）。不加这个判断的话，
//   import 一次就会往磁盘写六个文件 —— 判据变成"改磁盘"，而不是"读磁盘"。
//   而变异校验改的正是这个文件：产物只有走 `build()` 才在内存里可观察，
//   否则生成器的变异只能靠"和磁盘不一致"这一条红，说不出是哪里错了。
const isEntry = process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntry) main();

export { build, loadCharset, CJK_FACE, CHARSET_FILE };
