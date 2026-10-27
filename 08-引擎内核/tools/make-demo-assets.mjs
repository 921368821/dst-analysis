/**
 * 生成浏览器 demo 用的**真实 PNG 资产**（web/assets/*.png）
 *
 * ★ 为什么不用工程里现成的 DST 素材：
 *   `06-引擎复刻/_inventory/png/` 里 3242 张是**特效/图集切片**（树叶粒子、盐堆、扑克牌），
 *   不是可直接当实体显示的贴图；硬拿来当 sprite 会出现"一棵树长成一张扑克牌"。
 *   素材解码能力已由 `tools/verify-png-corpus.mjs` 在 3367 个真实文件上证明过
 *   （3366 成功 / 1 个源文件本身被截半），不需要在 demo 里再证一次。
 *
 * ★ 这个脚本其实在证另一件更关键的事：**图里故意覆盖了五种行滤波编码**
 *   （None / Sub / Up / Average / Paeth），并混用 RGBA8 与 RGB8 两种色彩类型。
 *   浏览器 demo 一旦跑起来，就等于把 PNG 解码器的五条滤波路径 + 两条通道路径
 *   全部真机验证了一遍 —— 而不是靠自造字节在单测里"看起来支持"。
 *
 * 用法：node tools/make-demo-assets.mjs
 * 产物：web/assets/{tree,rock,player,berry,ground,rabbit,hound}.png
 *       ＋ 批108 的 16 张方向帧 web/assets/{rabbit,hound}_{e,se,s,sw,w,nw,n,ne}.png
 *
 * ★ `rabbit` / `hound` 是批66 加的：世界的"活物"必须有贴图，
 *   复用 `player` 或 `berry` 会让画面上分不清哪只是兔子 ——
 *   而"看得见会走路的生物"正是那一批要证明的东西。
 */

import { deflateSync } from "node:zlib";
import { mkdirSync, writeFileSync, statSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join, dirname } from "node:path";

/**
 * 输出目录。
 *
 * ★ 支持用环境变量指到临时目录：`tests/extensions/dir-sprite.test.ts` 会跑一遍生成器
 *   到临时目录、与已提交的图**逐字节比对**。没有这个入口，「生成器改坏了」就永远
 *   发现不了 —— 判据读的是仓库里那批 PNG，而它们不会自己跟着生成器变。
 */
const OUT = process.env.DEMO_ASSETS_OUT ?? join(dirname(fileURLToPath(import.meta.url)), "..", "web", "assets");

// ------------------------------------------------------------------ CRC32

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body), 0);
  return Buffer.concat([len, body, crc]);
}

// ------------------------------------------------------------------ 滤波

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

/**
 * 编码 PNG。
 * @param {number} w @param {number} h
 * @param {3|4} channels 3 = RGB8(colorType 2)，4 = RGBA8(colorType 6)
 * @param {Uint8Array} pixels 未滤波的原始像素（行主序）
 * @param {0|1|2|3|4} filterType PNG 行滤波类型
 */
function encodePng(w, h, channels, pixels, filterType) {
  const bpp = channels;
  const stride = w * bpp;
  const raw = Buffer.alloc((stride + 1) * h);

  for (let y = 0; y < h; y++) {
    const o = y * (stride + 1);
    raw[o] = filterType;
    for (let x = 0; x < stride; x++) {
      const cur = pixels[y * stride + x];
      const left = x >= bpp ? pixels[y * stride + x - bpp] : 0;
      const up = y > 0 ? pixels[(y - 1) * stride + x] : 0;
      const upLeft = y > 0 && x >= bpp ? pixels[(y - 1) * stride + x - bpp] : 0;
      let pred = 0;
      if (filterType === 1) pred = left;
      else if (filterType === 2) pred = up;
      else if (filterType === 3) pred = (left + up) >> 1;
      else if (filterType === 4) pred = paeth(left, up, upLeft);
      raw[o + 1 + x] = (cur - pred) & 0xff;
    }
  }

  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; // bitDepth
  ihdr[9] = channels === 4 ? 6 : 2; // colorType: RGBA / RGB
  ihdr[10] = 0; // compression
  ihdr[11] = 0; // filter method
  ihdr[12] = 0; // interlace: none

  const sig = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  return Buffer.concat([
    sig,
    chunk("IHDR", ihdr),
    chunk("IDAT", deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

// ------------------------------------------------------------------ 画布

/** 极简 RGBA 画布（只做 source-over 混合，够画色块/圆/三角）。 */
class Canvas {
  constructor(w, h, channels) {
    this.w = w;
    this.h = h;
    this.ch = channels;
    this.px = new Uint8Array(w * h * channels);
  }

  put(x, y, r, g, b, a = 255) {
    x = Math.round(x);
    y = Math.round(y);
    if (x < 0 || y < 0 || x >= this.w || y >= this.h) return;
    const i = (y * this.w + x) * this.ch;
    if (this.ch === 3) {
      // 无 alpha 通道：直接覆盖（这些图不叠半透明）
      this.px[i] = r;
      this.px[i + 1] = g;
      this.px[i + 2] = b;
      return;
    }
    const src = a / 255;
    const dstA = this.px[i + 3] / 255;
    const outA = src + dstA * (1 - src);
    if (outA <= 0) return;
    this.px[i] = Math.round((r * src + this.px[i] * dstA * (1 - src)) / outA);
    this.px[i + 1] = Math.round((g * src + this.px[i + 1] * dstA * (1 - src)) / outA);
    this.px[i + 2] = Math.round((b * src + this.px[i + 2] * dstA * (1 - src)) / outA);
    this.px[i + 3] = Math.round(outA * 255);
  }

  rect(x, y, w, h, c, a = 255) {
    for (let j = y; j < y + h; j++) for (let i = x; i < x + w; i++) this.put(i, j, c[0], c[1], c[2], a);
  }

  disc(cx, cy, r, c, a = 255) {
    for (let j = -r; j <= r; j++)
      for (let i = -r; i <= r; i++) if (i * i + j * j <= r * r) this.put(cx + i, cy + j, c[0], c[1], c[2], a);
  }

  triangle(x0, y0, x1, y1, x2, y2, c, a = 255) {
    const minY = Math.min(y0, y1, y2);
    const maxY = Math.max(y0, y1, y2);
    for (let y = minY; y <= maxY; y++) {
      const xs = [];
      const edges = [
        [x0, y0, x1, y1],
        [x1, y1, x2, y2],
        [x2, y2, x0, y0],
      ];
      for (const [ax, ay, bx, by] of edges) {
        if ((ay <= y && by >= y) || (by <= y && ay >= y)) {
          if (Math.abs(by - ay) < 1e-9) xs.push(ax, bx);
          else xs.push(ax + ((y - ay) / (by - ay)) * (bx - ax));
        }
      }
      if (xs.length >= 2) {
        const lo = Math.round(Math.min(...xs));
        const hi = Math.round(Math.max(...xs));
        for (let x = lo; x <= hi; x++) this.put(x, y, c[0], c[1], c[2], a);
      }
    }
  }
}

// ------------------------------------------------------------------ 五张图

/** 树：褐干 + 三层绿冠。Paeth 滤波（最难写对的那条）。 */
function makeTree() {
  const c = new Canvas(64, 96, 4);
  c.rect(28, 60, 9, 36, [96, 64, 38]);
  c.rect(24, 88, 17, 6, [78, 50, 30]);
  c.triangle(32, 2, 3, 40, 61, 40, [44, 104, 50]);
  c.triangle(32, 22, 7, 58, 57, 58, [56, 128, 60]);
  c.triangle(32, 42, 11, 74, 53, 74, [68, 150, 72]);
  return c;
}

/** 石头：两层灰圆 + 高光。Sub 滤波。 */
function makeRock() {
  const c = new Canvas(48, 40, 4);
  c.disc(24, 26, 16, [92, 94, 100]);
  c.disc(20, 20, 11, [124, 128, 134]);
  c.disc(16, 15, 5, [158, 162, 168]);
  return c;
}

/** 角色：黄身体 + 头 + 眼睛 + 深色帽檐。Up 滤波。 */
function makePlayer() {
  const c = new Canvas(32, 48, 4);
  c.rect(10, 22, 13, 24, [198, 156, 84]);
  c.rect(10, 40, 5, 8, [86, 62, 40]);
  c.rect(18, 40, 5, 8, [86, 62, 40]);
  c.disc(16, 15, 10, [232, 198, 140]);
  c.rect(6, 6, 21, 4, [58, 44, 34]);
  c.rect(12, 13, 3, 4, [30, 30, 30]);
  c.rect(19, 13, 3, 4, [30, 30, 30]);
  return c;
}

/** 浆果：三颗红果 + 绿叶。Average 滤波。 */
function makeBerry() {
  const c = new Canvas(24, 24, 4);
  c.rect(11, 2, 3, 5, [64, 96, 44]);
  c.disc(9, 10, 5, [186, 42, 46]);
  c.disc(16, 13, 5, [206, 58, 54]);
  c.disc(11, 18, 4, [168, 34, 40]);
  c.disc(7, 8, 2, [232, 120, 110]);
  return c;
}

/** 地面：草色噪点。RGB8 无 alpha（顺手验证 colorType=2 路径）。None 滤波。 */
function makeGround() {
  const c = new Canvas(64, 64, 3);
  let seed = 0x1234567;
  const rnd = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
  for (let y = 0; y < 64; y++) {
    for (let x = 0; x < 64; x++) {
      const v = 52 + Math.floor(rnd() * 20);
      c.rect(x, y, 1, 1, [v, v + 24, v - 6]);
    }
  }
  return c;
}

/**
 * 兔子：白身 + 两只长耳 + 粉耳内。Sub 滤波。
 * ★ 它必须一眼是"猎物"而不是"又一棵树"：demo 里玩家要能分清该打谁。
 */
function makeRabbit() {
  const c = new Canvas(28, 30, 4);
  c.rect(8, 2, 3, 11, [236, 232, 226]);
  c.rect(13, 1, 3, 12, [236, 232, 226]);
  c.rect(9, 4, 1, 6, [226, 170, 176]);
  c.rect(14, 3, 1, 7, [226, 170, 176]);
  c.disc(13, 21, 9, [242, 238, 232]);
  c.disc(13, 13, 6, [250, 246, 240]);
  c.rect(10, 12, 2, 2, [40, 40, 44]);
  c.rect(16, 12, 2, 2, [40, 40, 44]);
  c.disc(22, 25, 3, [255, 255, 255]);
  return c;
}

/** 猎狗：深棕身 + 尖耳 + 黄眼。Paeth 滤波（与 tree 同，但尺寸不同）。 */
function makeHound() {
  const c = new Canvas(34, 36, 4);
  c.triangle(9, 5, 3, 3, 11, 16, [78, 58, 42]);
  c.triangle(25, 5, 31, 3, 23, 16, [78, 58, 42]);
  c.disc(17, 23, 11, [96, 74, 56]);
  c.disc(17, 13, 8, [112, 88, 66]);
  c.rect(12, 11, 2, 3, [240, 210, 90]);
  c.rect(20, 11, 2, 3, [240, 210, 90]);
  c.disc(17, 18, 3, [40, 32, 28]);
  return c;
}


// ------------------------------------------------------------------ 八向帧（批108）

/**
 * 8 向的**单位方向**，下标 = `dirIndex(angle, 8)` 的扇区号（`0` = 东，顺时针，y 向下为正）。
 *
 * ★ 这张表的下标顺序必须与 `src/extensions/render/dir-frames.ts` 的 `LETTERS8`
 *   逐项一致 —— 两处各写一份是刻意的：工具链不 import 引擎源码（`tools/` 是纯 node，
 *   没有 TS 转译），但**顺序错了会被判据抓住**：`tests/extensions/dir-sprite.test.ts`
 *   会逐帧读图上「眼睛在左还是右」，与这里的 `dx` 对账。
 *   只靠肉眼对齐的话，症状是「怪往西走、显示朝东」—— 画面看着完全正常，没人能报出来。
 */
const DIRS8 = [
  ["e", 1, 0],
  ["se", 0.7071, 0.7071],
  ["s", 0, 1],
  ["sw", -0.7071, 0.7071],
  ["w", -1, 0],
  ["nw", -0.7071, -0.7071],
  ["n", 0, -1],
  ["ne", 0.7071, -0.7071],
];

/** 眼睛颜色（判据按这个颜色找「眼睛像素」，所以它是契约的一部分，不能随手改）。 */
const EYE = [40, 40, 44];
const HOUND_EYE = [240, 210, 90];

/**
 * 兔子朝 `(dx, dz)` 的一帧。
 *
 * 画法只依赖三个量，方向才**可判**：
 *   · 头相对身体横向偏移 `dx * 2`（往哪边看，头往哪边偏）；
 *   · 耳朵整体横移 `dx * 3`（侧身时耳朵跟着甩到一侧）；
 *   · 眼睛——朝后（`dz < -0.4`）**一只都不画**，改画尾巴；朝前（`dz > 0.4`）画两只；
 *     纯侧面画一只，落在头偏向的那一侧。
 * 这三条正是 `dir-sprite` 判据要读的东西：方向如果画错了，眼睛的质心就会在错误的一侧。
 */
function rabbitAt(dx, dz) {
  const c = new Canvas(28, 30, 4);
  const cx = 13;
  const cy = 21;
  const away = dz < -0.4;
  const hx = Math.round(cx + dx * 2);
  const hy = Math.round(13 - dz);
  const lean = Math.round(dx * 3);
  const earTop = away ? 5 : 2;
  const earH = away ? 9 : 12;
  // 耳朵（先画，身体压在上面 ⇒ 朝后时耳朵「藏到脑后」）
  c.rect(8 + lean, earTop, 3, earH, [236, 232, 226]);
  c.rect(13 + lean, earTop - 1, 3, earH + 1, [236, 232, 226]);
  c.rect(9 + lean, earTop + 2, 1, earH - 5, [226, 170, 176]);
  c.rect(14 + lean, earTop + 1, 1, earH - 4, [226, 170, 176]);
  // 身体 + 头
  c.disc(cx, cy, 9, [242, 238, 232]);
  c.disc(hx, hy, 6, [250, 246, 240]);
  if (away) {
    // 朝后：没有脸，只有尾巴（尾巴是「背对」唯一可靠的视觉线索）
    c.disc(cx - lean, 25, 3, [255, 255, 255]);
  } else {
    const eyeDx = Math.round(dx * 3);
    if (dz > 0.4) {
      c.rect(hx - 3 + eyeDx, hy - 1, 2, 2, EYE);
      c.rect(hx + 3 + eyeDx, hy - 1, 2, 2, EYE);
      c.rect(hx + eyeDx, hy + 2, 2, 1, [226, 170, 176]);
    } else {
      c.rect(hx + (dx >= 0 ? 4 : -4), hy - 1, 2, 2, EYE);
    }
  }
  return c;
}

/** 猎犬朝 `(dx, dz)` 的一帧。与兔子同一套方向语义，只是尖耳换成长三角、眼睛换黄色。 */
function houndAt(dx, dz) {
  const c = new Canvas(34, 36, 4);
  const cx = 17;
  const cy = 23;
  const away = dz < -0.4;
  const hx = Math.round(cx + dx * 2);
  const hy = Math.round(13 - dz);
  const lean = Math.round(dx * 3);
  const earY = away ? 8 : 5;
  c.triangle(9 + lean, earY, 3 + lean, earY - 2, 11 + lean, earY + 11, [78, 58, 42]);
  c.triangle(25 + lean, earY, 31 + lean, earY - 2, 23 + lean, earY + 11, [78, 58, 42]);
  c.disc(cx, cy, 11, [96, 74, 56]);
  c.disc(hx, hy, 8, [112, 88, 66]);
  if (away) {
    c.disc(cx - lean, 27, 3, [70, 52, 38]);
  } else {
    const eyeDx = Math.round(dx * 3);
    if (dz > 0.4) {
      c.rect(hx - 4 + eyeDx, hy - 1, 2, 3, HOUND_EYE);
      c.rect(hx + 2 + eyeDx, hy - 1, 2, 3, HOUND_EYE);
      c.disc(hx + eyeDx, hy + 5, 3, [40, 32, 28]);
    } else {
      c.rect(hx + (dx >= 0 ? 5 : -5), hy - 1, 2, 3, HOUND_EYE);
      c.disc(hx + (dx >= 0 ? 6 : -6), hy + 4, 2, [40, 32, 28]);
    }
  }
  return c;
}

// ------------------------------------------------------------------ main

const SPEC = [
  { name: "tree", make: makeTree, filter: 4 },
  { name: "rock", make: makeRock, filter: 1 },
  { name: "player", make: makePlayer, filter: 2 },
  { name: "berry", make: makeBerry, filter: 3 },
  { name: "ground", make: makeGround, filter: 0 },
  { name: "rabbit", make: makeRabbit, filter: 1 },
  // 批108：方向帧。过滤类型按**方向**轮转（8 个方向刚好把 None..Paeth 各走一遍），
  // 这样一遍生成就把 PNG 编码器的五条滤波路径在「新增的这 16 张」上又验了一次。
  ...DIRS8.map(([letter, dx, dz], i) => ({
    name: `rabbit_${letter}`,
    make: () => rabbitAt(dx, dz),
    filter: i % 5,
  })),
  { name: "hound", make: makeHound, filter: 4 },
  ...DIRS8.map(([letter, dx, dz], i) => ({
    name: `hound_${letter}`,
    make: () => houndAt(dx, dz),
    filter: (i + 2) % 5,
  })),
];

mkdirSync(OUT, { recursive: true });
const FILTER_NAME = ["None", "Sub", "Up", "Average", "Paeth"];
let total = 0;
for (const s of SPEC) {
  const c = s.make();
  const buf = encodePng(c.w, c.h, c.ch, c.px, s.filter);
  const p = join(OUT, `${s.name}.png`);
  writeFileSync(p, buf);
  total += buf.length;
  console.log(
    `  ${s.name.padEnd(7)} ${String(c.w).padStart(3)}x${String(c.h).padEnd(3)} ` +
      `${c.ch === 4 ? "RGBA8" : "RGB8 "} filter=${FILTER_NAME[s.filter].padEnd(7)} ${buf.length} B`,
  );
}
console.log(`\n生成 ${SPEC.length} 张 → ${OUT}`);
console.log(`合计 ${total} B，实际磁盘 ${SPEC.reduce((a, s) => a + statSync(join(OUT, `${s.name}.png`)).size, 0)} B`);
