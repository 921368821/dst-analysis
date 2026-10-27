/**
 * L6 · HUD/背包 UI 树的判据
 *
 * 这组判据守两件事：
 *  ① **资产 → 皮肤** 的换算（json 里的像素矩形 → UV + 九宫格边距）。
 *     错了的症状是"面板画成一片空白"或"边框糊成一团"，而两处都不报错。
 *  ② **状态 → 节点** 的写入（行数、文本、选中、开合）。
 *     错了的症状是"点了没反应"或"面板列的还是上一个背包"。
 *
 * ★ 为什么这两件事能在 Node 里验：`createHudUi` 只建对象、不 init（纹理与管线在
 *   `init` 里才碰 device）。所以"树长什么样、props 写没写对"完全不需要浏览器 ——
 *   浏览器只负责最后那一步"像素对不对"（`web/selftest.html`）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { Rect } from "../../src/foundation/math/index.ts";
import { parseBmFont, type BitmapFont } from "../../src/extensions/ui/font.ts";
import { layoutText } from "../../src/extensions/ui/text-layout.ts";
import { layoutTree } from "../../src/extensions/ui/layout.ts";
import { buildUiQuads } from "../../src/extensions/ui/widgets.ts";
import { FontRegistry } from "../../src/extensions/ui/font.ts";
import { UiStateStore } from "../../src/extensions/ui/state.ts";
import {
  createHudUi,
  buildSkin,
  HUD_LAYOUT,
  type HudUiOptions,
  type UiSkinJson,
} from "../../src/host/hud-ui.ts";
import {
  bagEmptyLine,
  bagFooter,
  hudLine,
  hudRows,
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

function realSkinJson(): UiSkinJson {
  return JSON.parse(readFileSync(join(ROOT, "web", "assets", "ui-skin.json"), "utf8")) as UiSkinJson;
}

/** 一页假纹理的数据（`init` 之前不会上传，只要求字段齐）。 */
function fakePage(name: string, w = 8, h = 8): { name: string; width: number; height: number; pixels: Uint8Array } {
  return { name, width: w, height: h, pixels: new Uint8Array(w * h * 4).fill(255) };
}

function makeHud(over: Partial<HudUiOptions> = {}) {
  const r = createHudUi({
    font: realFont(),
    skinJson: realSkinJson(),
    fontPage: fakePage("ui-font.png"),
    skinPage: fakePage("ui-skin.png"),
    viewport: { designWidth: 960, designHeight: 600 },
    hints: { drop: "Q", bag: "Tab", pick: "G" },
    onSelectRow: () => undefined,
    ...over,
  });
  if (!r.ok) throw new Error(`createHudUi 失败：${r.error.code} ${r.error.message}`);
  return r.value;
}

// ------------------------------------------------------------------ ① 皮肤换算

test("★ 像素矩形 → UV：按图尺寸归一化，帧名与 slice 原样带出", () => {
  const json: UiSkinJson = {
    image: "x.png",
    width: 64,
    height: 16,
    frames: [
      { name: "panel", x: 0, y: 0, w: 16, h: 16, slice: 6 },
      { name: "slot", x: 48, y: 0, w: 16, h: 8, slice: 3 },
    ],
  };
  const r = buildSkin(json);
  assert.equal(r.ok, true);
  if (!r.ok) return;
  const f = r.value.skin.frames.get("panel");
  assert.ok(f !== undefined, "panel 帧没建出来");
  assert.equal(f.u0, 0);
  assert.equal(f.v0, 0);
  assert.equal(f.u1, 16 / 64);
  assert.equal(f.v1, 1);
  assert.equal(f.width, 16);
  assert.equal(f.height, 16);
  // ★ 皮肤帧必须在**页 1**（页 0 是字形）：接反的症状是"字模被当成面板画出来"
  assert.equal(f.page, 1);
  const s = r.value.skin.frames.get("slot");
  assert.ok(s !== undefined);
  assert.equal(s.u0, 48 / 64, "slot 的 u0 错了 —— x 没除以图宽");
  assert.equal(s.v1, 8 / 16);
  assert.equal(r.value.slice.get("slot"), 3);
});

test("★ 帧越界要报错，不能夹取（夹取的后果是面板静默变空白）", () => {
  const bad: UiSkinJson = {
    image: "x.png",
    width: 16,
    height: 16,
    frames: [{ name: "panel", x: 8, y: 0, w: 16, h: 16, slice: 0 }],
  };
  const r = buildSkin(bad);
  assert.equal(r.ok, false);
  if (r.ok) return;
  assert.equal(r.error.code, "UI.SKIN_FRAME_OOB");
});

test("皮肤图尺寸非法 / 一帧都没有 / 帧名重复 —— 三种配置错误各有明确错误码", () => {
  const codes: string[] = [];
  const push = (j: UiSkinJson): void => {
    const r = buildSkin(j);
    codes.push(r.ok ? "OK" : r.error.code);
  };
  push({ image: "x.png", width: 0, height: 16, frames: [] });
  push({ image: "x.png", width: 16, height: 16, frames: [] });
  push({
    image: "x.png",
    width: 16,
    height: 16,
    frames: [
      { name: "a", x: 0, y: 0, w: 8, h: 8, slice: 0 },
      { name: "a", x: 8, y: 0, w: 8, h: 8, slice: 0 },
    ],
  });
  assert.deepEqual(codes, ["UI.SKIN_BAD_SIZE", "UI.SKIN_NO_FRAME", "UI.SKIN_DUP_FRAME"]);
});

test("★ 仓库里那份 ui-skin.json 真的能被加载器吃下（生成器与加载器是一条链的两端）", () => {
  const json = realSkinJson();
  const r = buildSkin(json, 1);
  assert.equal(r.ok, true, r.ok ? "" : `${r.error.code} ${r.error.message}`);
  if (!r.ok) return;
  // 四个帧名是控件层硬编码用的（panel/button/bar/slot），少一个就有控件静默不画
  for (const name of ["panel", "button", "bar", "slot"]) {
    assert.ok(r.value.skin.frames.has(name), `皮肤里缺帧 ${name}`);
  }
  assert.equal(r.value.skin.frames.size, json.frames.length, "有帧没被建出来");
  // slice 必须与 json 一致：控件层拿它做九宫格，取错了边框会糊
  for (const f of json.frames) assert.equal(r.value.slice.get(f.name), f.slice);
});

// ------------------------------------------------------------------ ② 树与状态

test("★ HUD 三行节点都在，且默认不吃点击（HUD 是显示层，不是控件）", () => {
  const hud = makeHud();
  assert.equal(hud.hudRowIds.length, 3);
  for (const id of hud.hudRowIds) {
    const n = hud.module.root.find(id);
    assert.ok(n !== undefined, `找不到节点 ${id}`);
    assert.equal(n.interactive, false, `${id} 不该可点（会挡住世界上的点击）`);
    assert.equal(n.opaque, false);
  }
  assert.equal(hud.module.root.find("hud.fed")?.visible, false, "没有饱食数据时进度条必须隐藏");
  assert.equal(hud.module.root.find("bag.panel")?.visible, false, "背包面板默认关闭");
  assert.ok(hud.module.root.find("hud.panel") !== undefined, "HUD 底板节点丢了");
});

test("★ setBag：行数跟着堆叠数走，第 9 堆之后不画（面板不越界）", () => {
  const hud = makeHud();
  hud.setBag([{ kind: "berry", count: 3 }], 0);
  assert.equal(hud.bagOpen, true);
  assert.equal(hud.module.root.find("bag.panel")?.visible, true);
  assert.equal(hud.module.root.find("bag.row0")?.visible, true);
  assert.equal(hud.module.root.find("bag.row1")?.visible, false, "只有 1 堆时第 2 行必须隐藏");
  assert.equal(hud.module.root.find("bag.empty")?.visible, false);
  assert.deepEqual(hud.bagRowTexts, ["1. berry x3"]);

  // 9 堆：面板只有 8 行节点，第 9 堆**不画**（`visible` 没有第 9 个可开）
  const nine = Array.from({ length: 9 }, (_, i) => ({ kind: "rock", count: i + 1 }));
  hud.setBag(nine, 0);
  assert.equal(hud.module.root.find("bag.row7")?.visible, true);
  assert.equal(hud.bagRowTexts.length, 9, "文本仍然给全（调用方要知道有几堆）");

  // 空 → 显示空包提示（这句是玩家唯一能看到的"背包是空的"）
  hud.setBag([], 0);
  assert.deepEqual(hud.bagRowTexts, []);
  assert.equal(hud.module.root.find("bag.empty")?.visible, true);
  assert.equal(hud.module.root.find("bag.row0")?.visible, false);
  assert.equal(hud.module.root.find("bag.empty")?.props.text, bagEmptyLine("G"));

  // 关闭 → 整块不可见
  hud.setBag(null, 0);
  assert.equal(hud.bagOpen, false);
  assert.equal(hud.module.root.find("bag.panel")?.visible, false);
});

test("★ 选中的行必须**看起来**不一样（换 tint），不是只改一个数字", () => {
  const hud = makeHud();
  const two = [
    { kind: "berry", count: 1 },
    { kind: "rock", count: 2 },
  ];
  hud.setBag(two, 1);
  const t0 = hud.module.root.find("bag.row0")?.props.tint;
  const t1 = hud.module.root.find("bag.row1")?.props.tint;
  assert.ok(t0 !== undefined && t1 !== undefined);
  assert.notDeepEqual(t0, t1, "选中行与未选中行 tint 一样 —— 玩家看不出选的是哪堆");
  // 选中换到第 0 行：两行底色必须**互换**（"只给选中行上色、忘了给另一行还原"会在这里红）
  hud.setBag(two, 0);
  assert.deepEqual(hud.module.root.find("bag.row0")?.props.tint, t1);
  assert.deepEqual(hud.module.root.find("bag.row1")?.props.tint, t0);
});

test("★ 点中行会回调行号（走真实命中测试，不是直接赋值）", () => {
  const picked: number[] = [];
  const hud = makeHud({ onSelectRow: (i) => picked.push(i) });
  hud.setBag(
    [
      { kind: "berry", count: 1 },
      { kind: "rock", count: 2 },
    ],
    0,
  );
  // Node 里没有 device，`sync()` 会直接返回 —— 所以手工给节点矩形，
  // 验的是**路由**（命中→click→回调），布局有另外的判据。
  // ★ 还要把视口设成"CSS = 设计"（960×600 @1x），否则 `screenToDesign`
  //   会按默认的 1×1 视口换算，点 (20,60) 跑到设计坐标 (499,359) 去 —— 那不是被测代码的问题。
  hud.module.viewport.setScreen(960, 600, 1);
  const row0 = hud.module.root.find("bag.row0");
  const row1 = hud.module.root.find("bag.row1");
  assert.ok(row0 !== undefined && row1 !== undefined);
  row0.rect = new Rect(10, 40, 200, 14);
  row1.rect = new Rect(10, 56, 200, 14);
  hud.pointer(20, 60, true);
  hud.pointer(20, 60, false);
  assert.deepEqual(picked, [1], "点在第二行上必须回调 1（0 起）");
  // 点空白处不该有任何回调（否则"点哪儿都选中第一堆"这类错会静默通过）
  hud.pointer(900, 500, true);
  hud.pointer(900, 500, false);
  assert.deepEqual(picked, [1], "点在面板外也回调了 —— 命中测试漏了边界");
});

// ------------------------------------------------------------------ ③ 排版与缺字

/** 最坏情况：数字都顶到上限（HUD 是给人扫一眼的，但判据要按上限验）。 */
const WORST: HudFacts = {
  fps: 59.73,
  tick: 999999999,
  quads: 999999,
  drawCalls: 999,
  culled: 999999,
  nodes: 999999,
  bodies: 999999,
  atlas: "assets*11",
  world: { terrain: 9999, sites: 9999 },
  resources: { alive: 9999, spawned: 9999, released: 9999 },
  bagStacks: 8,
  hunger: { value: 100, max: 100 },
  backends: { gfx: "webgl2", audio: "webaudio", input: "dom", script: "lua" },
  script: { calls: 9999999, errors: 999, timeouts: 999 },
  droppedSteps: 999,
};

test("★ HUD 每一行都放得进面板（960 设计宽）：溢出是**静默**的，只能靠量", () => {
  const font = realFont();
  const rows = hudRows(WORST);
  // ★ 宽度取自**实现**导出的常量：判据里抄一份 640 的话，实现改成 320 时谁都不会红
  const inner = HUD_LAYOUT.width - HUD_LAYOUT.pad * 2;
  for (const [i, row] of rows.entries()) {
    // ★ 量的是**排版宽度**（与绘制同源），不是 `row.length * 6` 的估算
    const layout = layoutText(font, row, { maxWidth: 0 });
    assert.ok(
      layout.width <= inner,
      `第 ${String(i + 1)} 行宽 ${layout.width.toFixed(1)}px 超过面板内区 ${String(inner)}px：\n  ${row}`,
    );
  }
});

test("★ 面板里的每一句文案都画得出来（含底栏与空包提示）", () => {
  const font = realFont();
  for (const row of hudRows(WORST)) assert.deepEqual(missingGlyphsIn(row, font), [], `\n  ${row}`);
  assert.deepEqual(missingGlyphsIn(bagFooter({ drop: "Q", bag: "Tab" }), font), []);
  assert.deepEqual(missingGlyphsIn(bagEmptyLine("G"), font), []);
});

test("★ hudLine 与 hudRows 同源：拼起来必须**逐字**相同（两份格式化逻辑分叉会立刻红）", () => {
  assert.equal(hudLine(WORST), hudRows(WORST).join(" | "));
});

// ------------------------------------------------------------------ ⑥ 中文（批101）

/** 与宿主的 `ITEM_LABEL` 同一张表（宿主那份在 `browser-entry.ts`，这里抄一份只做判据用）。 */
const CJK_LABEL: Record<string, string> = {
  tree: "木头",
  rock: "石头",
  berry: "浆果",
  flint: "燧石",
  grass_tuft: "草",
  reed: "芦苇",
  meat: "肉",
  hide: "皮",
  cooked_meat: "熟肉",
  rope: "绳子",
};

function realCjkFont(): BitmapFont {
  const text = readFileSync(join(ROOT, "web", "assets", "ui-font-cjk.fnt"), "utf8");
  const r = parseBmFont(text, { id: "unifont-cjk-16-subset", pageBase: 2 });
  if (!r.ok) throw new Error(`ui-font-cjk.fnt 解析失败：${r.error.message}`);
  return r.value;
}

/**
 * ★★ 这条守的是**接线**：字体资产做好了不等于它被用上了。
 *   三件事同时成立才算接上：行文本是中文、行高按 16px 字体算、量出来的宽度放得进行宽。
 *   ★ 第三条是当初"中文不许进 UI"的原始理由（标签溢出边框一点点，只在特定行才出现），
 *     所以现在必须反过来被守住 —— 否则只是换一种方式坏掉。
 */
test("★★ 中文字体接进背包：物品名是中文、行高按 18px 算、宽度放得进行宽", () => {
  const cjk = realCjkFont();
  const hud = makeHud({
    cjkFont: cjk,
    cjkPage: fakePage("ui-font-cjk.png"),
    labelOf: (kind: string): string => CJK_LABEL[kind] ?? kind,
  });
  hud.setBag(
    Object.keys(CJK_LABEL).map((kind, i) => ({ kind, count: i + 1 })),
    0,
  );
  assert.equal(hud.bagRowTexts[0], "1. 木头 x1");
  assert.equal(hud.bagRowTexts[9], "10. 绳子 x10");

  const inner = 268 - HUD_LAYOUT.pad * 2;
  for (const row of hud.bagRowTexts) {
    const l = layoutText(cjk, row);
    assert.deepEqual([...l.missing], [], `行里有中文字体画不出的字（会静默变空白）：${row}`);
    assert.ok(l.width <= inner, `行宽 ${l.width.toFixed(1)}px 超过内区 ${String(inner)}px：${row}`);
  }

  // ★ 看的是**节点自己的尺寸**，不是布局矩形：Node 里没有 device，`sync()` 不跑，
  //   布局结果是空的。而这条要守的正是"行高是按哪张字体算的"，那是节点的 `size`。
  assert.equal(
    hud.module.root.find("bag.row0")?.size.h,
    cjk.lineHeight + 4,
    "行高没跟着 16px 字走 —— 18 高的字塞进 14 高的行会上下各溢出 2px",
  );
});

test("★ 没有中文字体时一切照旧（降级不是崩溃，也不是中文变空白）", () => {
  const hud = makeHud();
  hud.setBag([{ kind: "grass_tuft", count: 25 }], 0);
  assert.deepEqual(hud.bagRowTexts, ["1. grass tuft x25"]);
  assert.equal(hud.module.root.find("bag.row0")?.size.h, realFont().lineHeight + 4, "没有中文时行高不该变");
});

// ------------------------------------------------------------------ ④ toast 进 UI 树

test("★ toast：文案 → 节点，收起时**面板也不可见**（不能留一条空条）", () => {
  const hud = makeHud();
  assert.equal(hud.toastText, "");
  assert.equal(hud.module.root.find("toast.panel")?.visible, false, "没有提示时不该画空面板");
  hud.setToast("背包已打开");
  assert.equal(hud.toastText, "背包已打开");
  assert.equal(hud.module.root.find("toast.panel")?.visible, true);
  assert.equal(hud.module.root.find("toast.line")?.props.text, "背包已打开");
  hud.setToast(null);
  assert.equal(hud.toastText, "");
  assert.equal(hud.module.root.find("toast.panel")?.visible, false);
  // 空串与 null 同义：底栏那条"面板可见但一个字没有"是最容易被当成渲染故障的样子
  hud.setToast("x");
  hud.setToast("");
  assert.equal(hud.module.root.find("toast.panel")?.visible, false);
});

test("★ toast 不吃点击、不挡下层（它正好压在玩家点世界的那块地方）", () => {
  const hud = makeHud();
  hud.setToast("背包已打开");
  const panel = hud.module.root.find("toast.panel");
  assert.ok(panel !== undefined, "toast.panel 不见了");
  assert.equal(panel.interactive, false);
  assert.equal(panel.opaque, false, "opaque=true 会让底部一整条静默失效，玩家只觉得「这里点不动」");
});

test("★ toast 画在**最上层**（背包开着时提示也要看得见）", () => {
  const hud = makeHud();
  const ids = hud.module.root.children.map((n) => n.id);
  assert.equal(ids[ids.length - 1], "toast.panel", "绘制顺序 = children 顺序，最后 add 的才在最上面");
});

test("★ 长提示只画一行（省略号截断，而不是换行把提示条撑高）", () => {
  // ★ 这条要读**字形落在几行**，而不是读样式里写了 maxLines ——
  //   样式写了但绘制没用它（或换行宽算错）时，前一种读法照样绿。
  const hud = makeHud();
  const font = realFont();
  const fonts = new FontRegistry();
  fonts.register(font);

  // 字形在页 0、皮肤在页 1：只看页 0 的四边形就是「画出来的那些字」，
  // 不必去猜"哪些 quad 属于 toast"（猜错的判据会在无关的重构里变红）
  const glyphsOf = (): readonly { readonly z: number; readonly h: number }[] => {
    layoutTree(hud.module.root, new Rect(0, 0, 960, 600));
    const res = buildUiQuads(hud.module.root, fonts, hud.built.skin, new UiStateStore());
    return res.quads.filter((q) => q.atlas === 0);
  };

  hud.setToast("OK");
  assert.equal(glyphsOf().length, 2, "两个字母就是两个字形（先确认这条判据不是空转）");

  const long = "y".repeat(400);
  hud.setToast(long);
  const wide = glyphsOf();
  // ★ 判"几行"不能数 `z` 的**不同值**：同一行里不同字形的高度不一样（`y` 有下伸、`…` 很扁），
  //   于是同一行也会给出两个 z。要判的是**纵向跨度** —— 一行字必然落在 `lineHeight` 之内。
  const top = Math.min(...wide.map((q) => q.z));
  const bottom = Math.max(...wide.map((q) => q.z + q.h));
  assert.ok(
    bottom - top <= font.lineHeight,
    `只许有一行：纵向跨度 ${String(bottom - top)} 超过行高 ${String(font.lineHeight)}（换行会把提示条撑出屏幕）`,
  );
  assert.ok(
    wide.length < long.length / 2,
    `必须截断：400 个字画了 ${String(wide.length)} 个（若接近 400，说明 maxLines 没生效）`,
  );
  assert.ok(wide.length > 10, `但也不能截没了 —— 只画了 ${String(wide.length)} 个`);
});
