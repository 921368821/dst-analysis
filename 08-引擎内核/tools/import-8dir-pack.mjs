/**
 * 从 CC0 八向角色包派生引擎用的方向帧。
 *
 * 来源包：OpenGameArt「Hand-Drawn Square Characters Animated 8 Directions Top Down
 * FREE CC0」（作者 Raphael Gonçalves / @rgs_dev，CC0 1.0）。包内每个角色有
 * `idle_<方向> (<帧>).png` —— **方向写在文件名里**，这是它能被自动导入的全部原因。
 *
 * ★★ 包里只有 **5 个方向**（down / down_right / right / up / up_right），另外 3 个
 *   靠镜像。这不是偷懒：正对的角色左右对称，镜像出来的 3 向在数学上就是对的。
 *   但镜像必须**关于角色自己的中线**翻，不能关于裁剪框中线翻 —— 见 `flipAbout`。
 *
 * ★★ 裁剪用**整角色的统一包围盒**（20 帧的并集），不是逐帧紧贴。
 *   逐帧紧贴会让每帧的内容各自居中，于是"跑动时身体前后晃"这个信息被裁掉了 ——
 *   播放起来像原地抖动的人偶。统一包围盒保留了艺术家安排的相对位置。
 *
 * ★ 输出尺寸**不做缩放**：源图内容约 45×55，与工程里 player.png(32×48)、
 *   hound_e(34×36) 同一量级。缩放要么引入重采样（抗锯齿图缩到一半会糊），
 *   要么要改成整格对齐 —— 两件都不该由一个导入脚本悄悄决定。
 *
 * 用法（导入器直接复用仓库自己的 PNG 解码/编码器，不写第二份）：
 *   node --experimental-transform-types tools/import-8dir-pack.mjs --src <包内 Sprites 目录>
 *   可选：--char hero=Hero --frames 4 --prefix hero --out web/assets --dry
 */

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { decodePng } from "../src/extensions/asset-import/decode/png.ts";
import { encodePng } from "./png-encode.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ENGINE_ROOT = resolve(HERE, "..");

/** 8 向字母表：下标与 `dirIndex(angle, 8)` 一致（0 = 东，顺时针）。顺序不许改。 */
const LETTERS8 = ["e", "se", "s", "sw", "w", "nw", "n", "ne"];

/**
 * 方向 → 包里对应的方向名 + 是否镜像。
 *
 * ★ 这张表是**唯一的**方向映射。宿主的帧名、判据的镜像校验都从它派生，
 *   所以"改了映射忘了改别处"在结构上不可能发生。
 */
export const PACK_DIR_OF = {
  e: { src: "right", mirror: false },
  se: { src: "down_right", mirror: false },
  s: { src: "down", mirror: false },
  sw: { src: "down_right", mirror: true },
  w: { src: "right", mirror: true },
  nw: { src: "up_right", mirror: true },
  n: { src: "up", mirror: false },
  ne: { src: "up_right", mirror: false },
};

/** 包内 5 个方向名（= `PACK_DIR_OF` 里出现过的 src 去重，保持声明顺序）。 */
export const PACK_SRC_DIRS = [...new Set(Object.values(PACK_DIR_OF).map((d) => d.src))];

// ------------------------------------------------------------------ 像素工具

function bboxOf(img) {
  let x0 = img.width;
  let y0 = img.height;
  let x1 = -1;
  let y1 = -1;
  for (let y = 0; y < img.height; y++) {
    for (let x = 0; x < img.width; x++) {
      if (img.pixels[(y * img.width + x) * 4 + 3] > 0) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  return x1 < 0 ? null : { x0, y0, x1, y1 };
}

/** 裁一块（越界补全透明）。 */
function crop(img, bx, by, w, h) {
  const out = new Uint8Array(w * h * 4);
  for (let y = 0; y < h; y++) {
    const sy = by + y;
    if (sy < 0 || sy >= img.height) continue;
    for (let x = 0; x < w; x++) {
      const sx = bx + x;
      if (sx < 0 || sx >= img.width) continue;
      const si = (sy * img.width + sx) * 4;
      const oi = (y * w + x) * 4;
      out[oi] = img.pixels[si];
      out[oi + 1] = img.pixels[si + 1];
      out[oi + 2] = img.pixels[si + 2];
      out[oi + 3] = img.pixels[si + 3];
    }
  }
  return { width: w, height: h, pixels: out };
}

/**
 * 关于竖直轴 `axisX` 水平翻转。
 *
 * ★★ 轴必须取**角色自己内容的中线**（`2 * axisX - x`），不是裁剪框的中线。
 *   两者差 1~3 像素时，镜像出来的那一向会整体偏一点点 —— 单看一张图看不出来，
 *   但角色转身时会"跳一下"。这个偏移量与源图里各方向内容的居中程度有关，
 *   所以不能写死成某个常数。
 */
function flipAbout(img, axisX) {
  const out = new Uint8Array(img.width * img.height * 4);
  for (let y = 0; y < img.height; y++) {
    for (let x = 0; x < img.width; x++) {
      const sx = Math.round(2 * axisX - x);
      if (sx < 0 || sx >= img.width) continue;
      const si = (y * img.width + sx) * 4;
      const oi = (y * img.width + x) * 4;
      out[oi] = img.pixels[si];
      out[oi + 1] = img.pixels[si + 1];
      out[oi + 2] = img.pixels[si + 2];
      out[oi + 3] = img.pixels[si + 3];
    }
  }
  return { width: img.width, height: img.height, pixels: out };
}

function sha256(buf) {
  return createHash("sha256").update(buf).digest("hex");
}

// ------------------------------------------------------------------ 参数

function parseArgs(argv) {
  const out = {
    src: process.env.EIGHT_DIR_PACK_DIR ?? "",
    char: "hero=Hero",
    frames: 4,
    prefix: "",
    out: join(ENGINE_ROOT, "web", "assets"),
    dry: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--src") out.src = argv[++i] ?? "";
    else if (a === "--char") out.char = argv[++i] ?? "";
    else if (a === "--frames") out.frames = Number(argv[++i] ?? "4");
    else if (a === "--prefix") out.prefix = argv[++i] ?? "";
    else if (a === "--out") out.out = resolve(argv[++i] ?? out.out);
    else if (a === "--dry") out.dry = true;
    else if (a === "--help" || a === "-h") {
      console.log(
        "用法: node --experimental-transform-types tools/import-8dir-pack.mjs --src <Sprites 目录>\n" +
          "  --char <前缀=包内角色名>  默认 hero=Hero\n" +
          "  --frames <每向帧数>       默认 4\n" +
          "  --prefix <输出前缀>       默认取 --char 的前缀\n" +
          "  --out <输出目录>          默认 web/assets\n" +
          "  --dry                     只统计，不写文件",
      );
      process.exit(0);
    }
  }
  if (out.prefix === "") out.prefix = out.char.split("=")[0];
  return out;
}

// ------------------------------------------------------------------ 主体

function main() {
  const opt = parseArgs(process.argv.slice(2));
  const [prefix, charDir] = opt.char.split("=");
  if (opt.src === "" || !existsSync(opt.src)) {
    console.error(
      `找不到源包目录：${opt.src === "" ? "(未提供 --src)" : opt.src}\n` +
        "先把 CC0 包解压，然后把 --src 指到 .../Sprites（里面有 Hero/ Monster/ Skeleton/ 目录）。",
    );
    process.exit(2);
  }
  const charPath = join(opt.src, charDir ?? "Hero");
  if (!existsSync(charPath)) {
    console.error(`包里没有角色目录：${charPath}`);
    process.exit(2);
  }

  // ---- ① 读入 5 个方向 × N 帧
  const frames = {};
  for (const d of PACK_SRC_DIRS) {
    frames[d] = [];
    for (let f = 1; f <= opt.frames; f++) {
      const p = join(charPath, `idle_${d} (${f}).png`);
      if (!existsSync(p)) {
        console.error(`缺帧：${p}`);
        process.exit(2);
      }
      const dec = decodePng(new Uint8Array(readFileSync(p)));
      if (!dec.ok) {
        console.error(`解码失败 ${p}: ${dec.error.message}`);
        process.exit(2);
      }
      frames[d].push({ path: p, img: dec.value });
    }
  }

  // ---- ② 整角色统一包围盒（20 帧并集）
  let ux0 = Infinity;
  let uy0 = Infinity;
  let ux1 = -Infinity;
  let uy1 = -Infinity;
  for (const d of PACK_SRC_DIRS) {
    for (const { img } of frames[d]) {
      const b = bboxOf(img);
      if (b === null) continue;
      if (b.x0 < ux0) ux0 = b.x0;
      if (b.y0 < uy0) uy0 = b.y0;
      if (b.x1 > ux1) ux1 = b.x1;
      if (b.y1 > uy1) uy1 = b.y1;
    }
  }
  const bw = ux1 - ux0 + 1;
  const bh = uy1 - uy0 + 1;

  // ---- ③ 每个方向：裁统一盒 → （必要时）镜像
  const outputs = [];
  for (const letter of LETTERS8) {
    const map = PACK_DIR_OF[letter];
    const srcFrames = frames[map.src];
    // 镜像轴 = 该源方向第 1 帧内容的中线（角色自己的中轴，不是裁剪框中线）
    const srcBox = bboxOf(crop(srcFrames[0].img, ux0, uy0, bw, bh));
    const axisX = srcBox === null ? (bw - 1) / 2 : (srcBox.x0 + srcBox.x1) / 2;
    for (let i = 0; i < srcFrames.length; i++) {
      let piece = crop(srcFrames[i].img, ux0, uy0, bw, bh);
      if (map.mirror) piece = flipAbout(piece, axisX);
      const name = `${prefix}_${letter}_${i}`;
      const buf = encodePng({
        width: piece.width,
        height: piece.height,
        colorType: 6,
        bitDepth: 8,
        samples: piece.pixels,
      });
      outputs.push({ name, letter, frame: i, mirror: map.mirror, from: map.src, buf });
    }
  }

  // ---- ④ 报告 + 写出
  console.log(`角色 ${charDir}：统一包围盒 ${bw}x${bh}（源画布 ${frames[PACK_SRC_DIRS[0]][0].img.width}x${frames[PACK_SRC_DIRS[0]][0].img.height}）`);
  console.log(`方向 ${LETTERS8.length} × 帧 ${opt.frames} = ${outputs.length} 张`);
  let total = 0;
  for (const o of outputs) total += o.buf.length;
  console.log(`总字节 ${total}（平均 ${Math.round(total / outputs.length)} B/张）`);

  if (opt.dry) {
    console.log("--dry：未写文件");
    return;
  }

  if (!existsSync(opt.out)) mkdirSync(opt.out, { recursive: true });
  for (const o of outputs) writeFileSync(join(opt.out, `${o.name}.png`), o.buf);

  // ---- ⑤ 出处清单：许可与来源是**资产的一部分**，不是注释里的一句话。
  //        没有它，半年后没人说得清这批图能不能商用。
  const provenance = {
    version: 1,
    _comment:
      "这批图由 tools/import-8dir-pack.mjs 从 CC0 包派生，不要手改。" +
      "mirrored 里的方向是镜像生成（包里只有 5 个方向），判据逐像素校验镜像关系。",
    license: "CC0 1.0",
    author: "Raphael Gonçalves (@rgs_dev)",
    source: "OpenGameArt: Hand-Drawn Square Characters Animated 8 Directions Top Down (FREE CC0)",
    sourceUrl: "https://opengameart.org/content/hand-drawn-square-characters-animated-8-directions-top-down-free-cc0",
    packDir: charDir,
    crop: { x: ux0, y: uy0, w: bw, h: bh },
    directions: Object.fromEntries(LETTERS8.map((l) => [l, PACK_DIR_OF[l]])),
    framesPerDirection: opt.frames,
    files: Object.fromEntries(outputs.map((o) => [`${o.name}.png`, sha256(o.buf)])),
  };
  const provPath = join(opt.out, "pack-provenance.json");
  writeFileSync(provPath, Buffer.from(JSON.stringify(provenance, null, 2) + "\n", "utf8"));
  console.log(`写出 ${outputs.length} 张 + ${join("web/assets", "pack-provenance.json")}`);
}

// 只在直接运行时执行（被测试 import 时不要跑）
if (process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
