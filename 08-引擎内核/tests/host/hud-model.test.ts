/**
 * L6 · 宿主 HUD / 背包文案的判据
 *
 * 这组判据守的是一件事：**进入 UI 的每个字符，字体都画得出来**。
 *
 * 为什么值得单独守：
 *   位图字体缺字时不会报错、不会崩、不会变红 —— 它只是**不画那个字**，
 *   而 `xadvance` 照旧推进，于是那一段变成空白。
 *   屏幕上"少了一个字"和"本来就该有个空格"看起来一模一样，
 *   而 HUD 恰好是没人会逐字读的东西 —— 它可以坏很久都没人发现。
 *
 * 反面也被守住了：`missingGlyphsIn` 这个守门函数自己必须**真的会返回东西**
 * （拿一段中文去喂它，必须报出一堆码点）。否则它对任何输入都返回空数组，
 * 于是所有"文案全绿"的结论都是假绿 —— 判据自己的假绿灯比被测代码的更贵。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { parseBmFont, type BitmapFont } from "../../src/extensions/ui/font.ts";
import {
  bagEmptyLine,
  bagFooter,
  bagRows,
  hudLine,
  missingGlyphsIn,
  type HudFacts,
} from "../../src/host/hud-model.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");

function realFont(): BitmapFont {
  const text = readFileSync(join(ROOT, "web", "assets", "ui-font.fnt"), "utf8");
  const r = parseBmFont(text, { id: "ui5x7" });
  if (!r.ok) throw new Error(`ui-font.fnt 解析失败：${r.error.message}`);
  return r.value;
}

/** 全字段都"有值"的一份事实 —— 最容易长出非 ASCII 的那个分支。 */
const FULL: HudFacts = {
  fps: 59.73,
  tick: 12034,
  quads: 1420,
  drawCalls: 3,
  culled: 71,
  nodes: 481,
  bodies: 71,
  atlas: "assets*11",
  world: { terrain: 120, sites: 40 },
  resources: { alive: 12, spawned: 30, released: 18 },
  bagStacks: 3,
  hunger: { value: 78, max: 100 },
  backends: { gfx: "webgl2", audio: "webaudio", input: "dom", script: "lua" },
  script: { calls: 12034, errors: 0, timeouts: 2 },
  droppedSteps: 0,
};

test("★ HUD 正文里没有一个字体画不出来的字符（含 × 这种随手会写进来的符号）", () => {
  const font = realFont();
  const text = hudLine(FULL);
  const missing = missingGlyphsIn(text, font);
  assert.deepEqual(
    missing.map((c) => `U+${c.toString(16)} ${String.fromCodePoint(c)}`),
    [],
    `HUD 里有字体画不出的字符（会静默变成空白）：\n  ${text}`,
  );
});

test("★ 「不存在」的三个分支（world / hunger / script）也必须画得出来", () => {
  const font = realFont();
  const text = hudLine({ ...FULL, world: null, hunger: null, script: null });
  assert.deepEqual(missingGlyphsIn(text, font), [], `\n  ${text}`);
  // 三种"没有"的写法必须彼此可辨：`-` / `off` 与 0 是不同的事实
  assert.ok(text.includes("world -"), "世界没装配要写成 `world -`，不是 0 块");
  assert.ok(text.includes("fed -"), "没有饱食组件要写成 `fed -`，不是 0/0");
  assert.ok(text.includes("script off"), "脚本没接要写成 `script off`，不是 0c/0e");
  assert.ok(!text.includes("×"), "分隔/乘号不能用 ×（U+00D7，字体里没有）");
});

test("★ 背包行的物品名全部画得出来（kind 本身必须能进 UI）", () => {
  const font = realFont();
  const src = readFileSync(join(ROOT, "src", "browser-entry.ts"), "utf8");
  // 从 `ITEM_LABEL` 表里把 kind 抠出来：不手抄一份，手抄的那份迟早和真实数据分叉
  const block = /const ITEM_LABEL: Record<string, string> = \{([\s\S]*?)\n  \};/.exec(src);
  assert.ok(block !== null, "browser-entry.ts 里找不到 ITEM_LABEL 表 —— 判据的取数路径失效了");
  const kinds = [...(block[1] ?? "").matchAll(/^\s{4}([A-Za-z_][\w]*):/gm)].map((m) => m[1] as string);
  assert.ok(kinds.length >= 8, `只抠到 ${String(kinds.length)} 个 kind，取数正则可能失效了`);

  const rows = bagRows(
    kinds.map((kind, i) => ({ kind, count: i + 1 })),
    0,
  );
  assert.equal(rows.length, kinds.length);
  for (const row of rows) {
    assert.deepEqual(
      missingGlyphsIn(row.text, font),
      [],
      `背包行画不出来：${JSON.stringify(row.text)}`,
    );
  }
});

test("背包行的选中：越界夹到最后一堆（与宿主旧行为一致）", () => {
  const stacks = [
    { kind: "tree", count: 3 },
    { kind: "rock", count: 1 },
  ];
  assert.equal(bagRows(stacks, 0)[0]?.selected, true);
  assert.equal(bagRows(stacks, 1)[1]?.selected, true);
  // 丢了东西导致堆数变少后还按旧下标取 —— 不能崩，也不能一行都不选中
  assert.equal(bagRows(stacks, 9)[1]?.selected, true, "越界要夹到最后一堆");
  assert.equal(bagRows([], 5).length, 0, "空背包没有行");
});

test("背包底栏与空包提示画得出来（这两句最容易被写成中文）", () => {
  const font = realFont();
  assert.deepEqual(missingGlyphsIn(bagFooter({ drop: "Q", bag: "Tab" }), font), []);
  assert.deepEqual(missingGlyphsIn(bagEmptyLine("G"), font), []);
});

test("★ 守门函数自己会红：中文文本必须被报成缺字（否则所有「全绿」都是假绿）", () => {
  const font = realFont();
  const missing = missingGlyphsIn("背包 2/8", font);
  assert.ok(missing.length >= 2, `中文应当至少报出 2 个缺字，实际 ${String(missing.length)} 个`);
  // 反向：纯 ASCII 一句话必须一个都不报（否则这个函数只会喊狼）
  assert.deepEqual(missingGlyphsIn("hud 42 quad 7", font), []);
});
