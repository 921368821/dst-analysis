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
import { Color } from "../../src/foundation/math/index.ts";
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

// ------------------------------------------------------------------ 背包拖拽标记（批109）

test("★ 不传拖拽状态时文本与旧格式一字不差（回归：标记不能污染正常状态）", () => {
  const stacks = [
    { kind: "tree", count: 3 },
    { kind: "rock", count: 7 },
  ];
  const rows = bagRows(stacks, 0);
  assert.equal(rows[0]!.text, "1. tree x3");
  assert.equal(rows[1]!.text, "2. rock x7");
  assert.equal(rows[0]!.drag, null);
  assert.equal(rows[1]!.drag, null);
});

test("★★ 拖拽：起点缀 moving、落点缀 drop，其余行一个字都不改", () => {
  const stacks = [
    { kind: "tree", count: 3 },
    { kind: "rock", count: 7 },
    { kind: "berry", count: 2 },
  ];
  const rows = bagRows(stacks, 0, undefined, { from: 0, to: 2 });
  assert.equal(rows[0]!.drag, "from");
  assert.equal(rows[0]!.text, "1. tree x3  (moving)");
  assert.equal(rows[1]!.drag, null);
  assert.equal(rows[1]!.text, "2. rock x7", "既不是起点也不是落点的行必须一字不动");
  assert.equal(rows[2]!.drag, "to");
  assert.equal(rows[2]!.text, "3. berry x2  (drop)");
});

test("★ 拖拽 from === to：只显示 moving（还没换位，不能提前说「放这里」）", () => {
  const stacks = [{ kind: "tree", count: 3 }];
  const rows = bagRows(stacks, 0, undefined, { from: 0, to: 0 });
  assert.equal(rows[0]!.drag, "from", "同一格时 from 优先");
  assert.ok(rows[0]!.text.endsWith("(moving)"), `实际：${rows[0]!.text}`);
  assert.equal(rows[0]!.text.includes("drop"), false);
});

test("★ 拖到面板外（to === null）：起点仍是 moving，且没有任何 drop 行", () => {
  const stacks = [
    { kind: "tree", count: 3 },
    { kind: "rock", count: 7 },
  ];
  const rows = bagRows(stacks, 0, undefined, { from: 1, to: null });
  assert.equal(rows[1]!.drag, "from");
  assert.deepEqual(
    rows.map((r) => r.drag),
    [null, "from"],
    "落点为空时不该有第二行被标成 drop",
  );
});

// ------------------------------------------------------------------ 行内分段（批114）

/**
 * 分段判据守两件事：
 *   ① **哪几个字符是计数**（这是关于文案的事实，改文案时最容易漂）；
 *   ② `text` 与 `runs` **不会各写一遍**（拼不起来就说明有人只改了一边）。
 */
test("★★ runs 拼起来必须等于 text（两处各拼一遍就会漂）", () => {
  const rows = bagRows(
    [
      { kind: "tree", count: 3 },
      { kind: "grass_tuft", count: 25 },
    ],
    0,
    undefined,
    { from: 0, to: 1 },
  );
  for (const r of rows) {
    assert.equal(r.runs.map((x) => x.text).join(""), r.text, `第 ${String(r.index)} 行的分段与整句不一致`);
  }
  // 反向：分段不是"一段就是整句" —— 那样等于没分段，颜色永远只有一种。
  assert.ok(rows[0]!.runs.length >= 2, "至少要有「主体」与「计数」两段");
});

test("★★ 计数是独立的一段，且它是最后一段（没有拖拽标记时）", () => {
  const rows = bagRows([{ kind: "tree", count: 3 }], 0);
  assert.deepEqual(
    rows[0]!.runs.map((r) => r.text),
    ["1. tree", " x3"],
    "序号+物品名一段、空格+计数一段（空格跟计数走，视觉上才贴在一起）",
  );
  // 主体段**不带颜色**：它要继承行自己的 textColor（选中行的高亮才不会失效）
  assert.equal(rows[0]!.runs[0]?.color, undefined, "主体段不许写死颜色");
});

test("★ 拖拽标记是第三段，只有真的在拖时才出现", () => {
  const stacks = [
    { kind: "tree", count: 3 },
    { kind: "rock", count: 7 },
  ];
  const idle = bagRows(stacks, 0);
  assert.deepEqual(
    idle.map((r) => r.runs.length),
    [2, 2],
    "没在拖时每行两段",
  );
  const dragging = bagRows(stacks, 0, undefined, { from: 0, to: 1 });
  assert.deepEqual(
    dragging.map((r) => r.runs.length),
    [3, 3],
    "起点与落点各多一段标记；中间行仍是两段",
  );
  assert.equal(dragging[0]!.runs[2]?.text, "  (moving)");
  assert.equal(dragging[1]!.runs[2]?.text, "  (drop)");
});

test("★ 配色只落在非主体段（模型给结构、面板给颜色）", () => {
  const count = new Color(0.5, 0.5, 0.5, 1);
  const mark = new Color(1, 0.8, 0.3, 1);
  const rows = bagRows([{ kind: "tree", count: 3 }], 0, undefined, { from: 0, to: null }, { count, mark });
  assert.equal(rows[0]!.runs[0]?.color, undefined, "主体段仍然不带颜色");
  assert.deepEqual(rows[0]!.runs[1]?.color, count, "计数段拿到面板给的颜色");
  assert.deepEqual(rows[0]!.runs[2]?.color, mark, "标记段拿到面板给的颜色");
  // 不传配色 ⇒ 两段都不带颜色（面板没要求就不许自作主张）
  const plain = bagRows([{ kind: "tree", count: 3 }], 0, undefined, { from: 0, to: null });
  assert.equal(plain[0]!.runs[1]?.color, undefined);
  assert.equal(plain[0]!.runs[2]?.color, undefined);
});
