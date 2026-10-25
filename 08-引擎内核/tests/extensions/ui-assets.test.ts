/**
 * UI 资产（位图字体 + 皮肤图集）的判据
 *
 * 这一组判据守的是**资产本身**，不是解析器（解析器有 `ui-font.test.ts`）。
 * 分开的理由很实际：解析器的判据用的是**手搓的夹具字体**，
 * 它证明"能解析合法的 BMFont"，但证明不了"仓库里的那份 .fnt 是好的"。
 * 而真正会坏的是后者：生成器里手写的字形表打错一个字符、
 * 打包坐标算错一位、或者有人手改了 PNG 却没改生成器。
 *
 * ★★ 最要紧的一条是「每个字形在图集里至少有一个不透明像素」。
 *   字体这类资产坏掉的形状特别隐蔽：`xadvance` 还在、排版照旧推进、
 *   布局宽度全对，只是**某个字母不见了**。任何"结构类"判据
 *   （字宽 > 0、UV 在界内、码点覆盖全）都照样绿 —— 因为数据自洽，
 *   错的是数据与像素之间的对应关系。只有真去数像素才能抓住它。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseBmFont } from "../../src/extensions/ui/font.ts";
import { decodePng } from "../../src/extensions/asset-import/decode/png.ts";
import { textImporter } from "../../src/extensions/asset-import/importers/text.ts";

const ROOT = join(dirnameOf(fileURLToPath(import.meta.url)), "..", "..");
const ASSETS = join(ROOT, "web", "assets");

function dirnameOf(p: string): string {
  const i = Math.max(p.lastIndexOf("/"), p.lastIndexOf("\\"));
  return p.slice(0, i);
}

function loadFont() {
  const text = readFileSync(join(ASSETS, "ui-font.fnt"), "utf8");
  const r = parseBmFont(text, { id: "ui5x7" });
  if (!r.ok) throw new Error(`ui-font.fnt 解析失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

function loadPng(name: string) {
  const r = decodePng(new Uint8Array(readFileSync(join(ASSETS, name))));
  if (!r.ok) throw new Error(`${name} 解码失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

interface SkinJson {
  image: string;
  width: number;
  height: number;
  frames: { name: string; x: number; y: number; w: number; h: number; slice: number }[];
}

function loadSkin(): SkinJson {
  return JSON.parse(readFileSync(join(ASSETS, "ui-skin.json"), "utf8")) as SkinJson;
}

test("ui-font.fnt 能解析，且覆盖全部可打印 ASCII（缺一个就会在界面上变成缺字）", () => {
  const font = loadFont();
  const missing: number[] = [];
  for (let c = 32; c <= 126; c++) if (!font.glyphs.has(c)) missing.push(c);
  assert.deepEqual(missing, [], `缺这些码点：${missing.map((c) => String.fromCodePoint(c)).join("")}`);
  // 省略号必须在：截断时的默认补字符就是它，缺了会变成"裁了还少一个字"
  assert.ok(font.glyphs.has(0x2026), "缺省略号 U+2026");
});

test("★ 每个字形在图集里都真的有墨（结构判据全绿也挡不住这一类的坏）", () => {
  const font = loadFont();
  const img = loadPng("ui-font.png");
  assert.equal(img.width, font.scaleW, "图宽与 .fnt 的 scaleW 不一致（UV 会整体错位）");
  assert.equal(img.height, font.scaleH, "图高与 .fnt 的 scaleH 不一致");

  const blank: string[] = [];
  for (const g of font.glyphs.values()) {
    if (g.code === 32 || g.width === 0 || g.height === 0) continue; // 空格本来就没墨
    // 像素矩形由 UV 反算（`FontGlyph` 只留 UV，不重复存一份像素坐标 —— 两份必然漂）
    const x0 = Math.round(g.u0 * font.scaleW);
    const y0 = Math.round(g.v0 * font.scaleH);
    let lit = 0;
    for (let y = 0; y < g.height; y++) {
      for (let x = 0; x < g.width; x++) {
        const at = ((y0 + y) * img.width + (x0 + x)) * 4;
        if ((img.pixels[at + 3] ?? 0) > 0) lit++;
      }
    }
    if (lit === 0) blank.push(`U+${g.code.toString(16).padStart(4, "0")} ${JSON.stringify(String.fromCodePoint(g.code))}`);
  }
  assert.deepEqual(blank, [], `这些字形在图集里一个不透明像素都没有：${blank.join(" / ")}`);
});

test("UV 与 .fnt 里的像素矩形一一对应（不是「差半个像素」那种对不上）", () => {
  const font = loadFont();
  // ★ 独立于解析器取一遍像素坐标：直接从文件文本里读 `char` 行。
  //   拿解析结果自己比自己是没有信息量的（`u0 = x/scaleW` 恒成立），
  //   但"文件里写的 x"与"解析器给出的 UV"是两条路径 —— 除数是 scaleW 还是整张图宽、
  //   有没有算偏移，都会在这条上露出来。
  const text = readFileSync(join(ASSETS, "ui-font.fnt"), "utf8");
  const rows = [...text.matchAll(/^char id=(\d+) x=(-?\d+) y=(-?\d+) width=(\d+) height=(\d+)/gm)];
  assert.equal(rows.length, font.glyphs.size, "char 行数与解析出的字形数不一致");
  for (const m of rows) {
    const code = Number(m[1]);
    const x = Number(m[2]);
    const y = Number(m[3]);
    const w = Number(m[4]);
    const h = Number(m[5]);
    const g = font.glyphs.get(code);
    assert.ok(g !== undefined, `解析结果里缺 U+${code}`);
    assert.equal(Math.round(g.u0 * font.scaleW), x, `U+${code} 的 u0·scaleW ≠ 文件里的 x=${x}`);
    assert.equal(Math.round(g.v0 * font.scaleH), y, `U+${code} 的 v0·scaleH ≠ 文件里的 y=${y}`);
    assert.equal(Math.round((g.u1 - g.u0) * font.scaleW), w, `U+${code} 的 UV 宽 ≠ width=${w}`);
    assert.equal(Math.round((g.v1 - g.v0) * font.scaleH), h, `U+${code} 的 UV 高 ≠ height=${h}`);
  }
});

test("★ 基线语义：大写顶在基线上方 7px，带尾巴的字真的探到基线下方", () => {
  const font = loadFont();
  // 大写字高 7：墨迹顶 = base - 7，底 = base
  for (const ch of ["A", "Z", "0", "M"]) {
    const g = font.glyphs.get(ch.codePointAt(0) ?? 0);
    assert.ok(g !== undefined, `缺字形 ${ch}`);
    assert.equal(font.base + g.yoffset, 0, `${ch} 的墨迹顶应正好在单元格第一行（base + yoffset = 0）`);
    assert.equal(font.base + g.yoffset + g.height, font.base, `${ch} 的墨迹底应落在基线上`);
  }
  // g / p / y 的尾巴要过基线：否则一行里的下降部会"悬在空中"
  for (const ch of ["g", "p", "y"]) {
    const g = font.glyphs.get(ch.codePointAt(0) ?? 0);
    assert.ok(g !== undefined, `缺字形 ${ch}`);
    assert.ok(
      font.base + g.yoffset + g.height > font.base,
      `${ch} 的墨迹底 ${font.base + g.yoffset + g.height} 没有落到基线 ${font.base} 下方 —— 尾巴没了`,
    );
  }
});

test("xadvance = 墨迹宽 + 1（空格只有前进量），行高够放下下降部", () => {
  const font = loadFont();
  for (const g of font.glyphs.values()) {
    if (g.code === 32) {
      assert.equal(g.width, 0, "空格不该有墨迹宽");
      assert.ok(g.xadvance > 0, "空格必须有前进量，否则两个词会粘在一起");
      continue;
    }
    assert.equal(g.xadvance, g.width + 1, `U+${g.code} 的 xadvance 应等于 width + 1`);
  }
  // 下降部到底（base+1）之后还要留 1px，下一行的大写才不会贴上去
  assert.ok(font.lineHeight >= font.base + 2, `lineHeight ${font.lineHeight} 太小：下降部会撞到下一行`);
});

test("皮肤：帧都在图内、切片边距合法、图与 json 尺寸一致", () => {
  const skin = loadSkin();
  const img = loadPng(skin.image);
  assert.equal(img.width, skin.width, "皮肤图宽与 json 声明不一致");
  assert.equal(img.height, skin.height, "皮肤图高与 json 声明不一致");
  const names = new Set<string>();
  for (const f of skin.frames) {
    assert.equal(names.has(f.name), false, `帧名重复：${f.name}`);
    names.add(f.name);
    assert.ok(f.x >= 0 && f.y >= 0, `${f.name} 的坐标是负的`);
    assert.ok(f.x + f.w <= img.width, `${f.name} 横向越界`);
    assert.ok(f.y + f.h <= img.height, `${f.name} 纵向越界`);
    // 9-slice 的边距超过源帧一半时，中间块会变负宽（nineSlice 会夹取，但那说明资产本身错了）
    assert.ok(f.slice >= 0, `${f.name} 的 slice 不能是负的`);
    assert.ok(f.slice <= Math.min(f.w, f.h) / 2, `${f.name} 的 slice=${f.slice} 超过源帧一半（${f.w}x${f.h}）`);
  }
  for (const need of ["panel", "button", "bar", "slot"]) {
    assert.ok(names.has(need), `缺帧 ${need}`);
  }
});

test("文本导入器接受 .fnt（否则字体文件在资产目录里、导入报告里却没有它）", () => {
  assert.ok(
    (textImporter.extensions as readonly string[]).includes(".fnt"),
    `textImporter 的扩展名里没有 .fnt：${textImporter.extensions.join(", ")}`,
  );
});

test("★ 磁盘上的资产与生成器一致（手改 PNG 会让「可复现」变成空话）", () => {
  const r = spawnSync(process.execPath, [join(ROOT, "tools", "make-ui-assets.mjs"), "--check"], {
    cwd: ROOT,
    encoding: "utf8",
  });
  assert.equal(r.status, 0, `生成器与磁盘产物不一致：\n${(r.stdout ?? "") + (r.stderr ?? "")}`);
});
