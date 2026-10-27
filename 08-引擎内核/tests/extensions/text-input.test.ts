/**
 * L4 · 单行输入框（批110）
 *
 * 这一批唯一值得单独立判据的是 **IME 组合的时序**：其余（退格、移动、选区）都是
 * 一眼能看懂的算术，而组合的三条规则每一条错了都**看不出来**：
 *
 *   ① **组合中不许动 `value`**。边打边写的实现里，取消（Esc / 切窗口 / 组合被打断）
 *      都要回滚，而"回滚"依赖被覆盖的内容还在 —— 一旦漏回滚，玩家会看到一串
 *      自己没打算留下的拼音。正确形状是：`value` 在那里不动，组合串是**预览**。
 *   ② **`compositionend` 带空串 ≠ 提交**。Esc 取消时浏览器就是这么发的。
 *      当成提交的话，"选中三个字 → 打拼音 → Esc"会把那三个字删掉。
 *   ③ **组合区间是范围不是插入点**。有选区时开始组合，那一段是要被替换的；
 *      只记插入点会让显示与结果不一致（先看到"三个字 + 拼音"，提交后只剩拼音）。
 *
 * ★ 下标一律码点下标：用 UTF-16 码元的话，emoji 上按一次退格会留下半个代理对，
 *   屏幕显示 `�` 而 `length` 只少 1 —— 两者都很难查。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { parseBmFont, type BitmapFont } from "../../src/extensions/ui/font.ts";
import { layoutText } from "../../src/extensions/ui/text-layout.ts";
import { TextInput, caretXOf, codePointsLength, inputGeometryOf, sliceCodePoints } from "../../src/extensions/ui/text-input.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");

function realFont(): BitmapFont {
  const r = parseBmFont(readFileSync(join(ROOT, "web", "assets", "ui-font.fnt"), "utf8"), { id: "ui5x7" });
  if (!r.ok) throw new Error(`ui-font.fnt 解析失败：${r.error.message}`);
  return r.value;
}

function typed(value = ""): TextInput {
  const t = TextInput.from(value);
  return t;
}

// ------------------------------------------------------------------ ① 组合中不提交

test("★★ 组合中 value 一个字都不动，display 是预览（改多少次都一样）", () => {
  const t = typed("ab");
  t.beginComposition();
  assert.equal(t.value, "ab", "beginComposition 就动了 value ⇒ 取消时无从回滚");
  t.updateComposition("n");
  t.updateComposition("ni");
  t.updateComposition("nihao");
  assert.equal(t.value, "ab", "组合期间 value 必须保持不变（组合串只是预览）");
  assert.equal(t.display, "abnihao", "屏幕上看得到预览");
  assert.equal(t.isComposing, true);
  assert.equal(t.displayCaret, 7, "组合中光标在组合串末尾（2 + 5）");
});

test("★★ 提交：value 变成替换后的串，光标落在串尾", () => {
  const t = typed("ab");
  t.beginComposition();
  t.updateComposition("你");
  t.commitComposition();
  assert.equal(t.value, "ab你");
  assert.equal(t.caret, 3);
  assert.equal(t.anchor, 3, "提交后锚点要同步，否则下一次 Shift+方向键会选到旧区间");
  assert.equal(t.isComposing, false);
  assert.equal(t.display, t.value, "提交后 display 与 value 必须完全一致");
});

test("★★ compositionend 空串 = 取消：不删任何东西，选中内容原样还在", () => {
  const t = typed("hello");
  t.setSelection(1, 4); // 选中 "ell"
  t.beginComposition();
  t.updateComposition("ni");
  assert.equal(t.display, "hnio", "组合中显示的是替换后的样子");
  t.commitComposition(""); // Esc：浏览器就发这个
  assert.equal(t.value, "hello", "取消把选中的三个字删掉了 —— 玩家觉得自己什么都没做");
  assert.equal(t.selectedText, "ell", "选区也要原样恢复");
  assert.equal(t.caret, 4, "光标回到**组合前**的位置（4），不是替换区间起点 —— 选区方向也要原样");
  assert.equal(t.anchor, 1, "锚点同样原样：方向决定下一次 Shift+方向键往哪边扩");
});

test("★ 组合开始时有选区：display 显示替换，不是「选中内容 + 拼音」", () => {
  const t = typed("hello");
  t.setSelection(0, 5);
  t.beginComposition();
  t.updateComposition("hi");
  assert.equal(t.display, "hi", "显示成「hello hi」的话，提交后只剩 hi，玩家会觉得字丢了");
  t.commitComposition();
  assert.equal(t.value, "hi", "整段被替换");
});

test("★ 选区反向（anchor 在右）也按左端开始替换", () => {
  const t = typed("abcd");
  t.setSelection(3, 1); // 从 3 拖到 1
  t.beginComposition();
  t.updateComposition("X");
  t.commitComposition();
  assert.equal(t.value, "aXd", "替换 [1,3)，与拖动方向无关");
});

test("★ 组合中 insert：先提交再插入（宿主事件顺序反了结果也对）", () => {
  const t = typed("ab");
  t.beginComposition();
  t.updateComposition("ni");
  t.insert("!");
  assert.equal(t.value, "abni!");
  assert.equal(t.isComposing, false, "插入之后不该还挂着组合态");
});

// ------------------------------------------------------------------ ② 普通编辑

test("★ 有选区时插入：替换选区，不是插在选区前面", () => {
  const t = typed("hello");
  t.setSelection(1, 3);
  t.insert("XY");
  assert.equal(t.value, "hXYlo");
  assert.equal(t.caret, 3);
  assert.equal(t.hasSelection, false);
});

test("★ 退格删一个**码点**：emoji 不会被劈成半个代理对", () => {
  const t = typed("a🍎");
  assert.equal(codePointsLength("a🍎"), 2, "码点数 2（emoji 算一个）");
  assert.equal(t.deleteBackward(), true);
  assert.equal(t.value, "a");
  assert.equal(codePointsLength(t.value), 1);
  assert.equal(t.deleteBackward(), true);
  assert.equal(t.deleteBackward(), false, "空了还报「删掉了」= 判据永远绿");
});

test("★ 有选区时退格删的是选区（不是再往前多删一个）", () => {
  const t = typed("abcdef");
  t.setSelection(2, 4);
  t.deleteBackward();
  assert.equal(t.value, "abef");
  assert.equal(t.caret, 2);
});

test("★ 前向删除只删光标之后那一个；在末尾返回 false", () => {
  const t = typed("abc");
  t.moveCaret(1);
  assert.equal(t.deleteForward(), true);
  assert.equal(t.value, "ac");
  t.moveCaret(99);
  assert.equal(t.deleteForward(), false);
});

test("★ 移动光标：夹取到 [0, 码点数]；Shift（extend）拖锚点形成选区", () => {
  const t = typed("abcd");
  t.moveCaret(99);
  assert.equal(t.caret, 4, "越界要夹到末尾");
  t.moveCaret(-5);
  assert.equal(t.caret, 0);
  t.moveCaret(3, true);
  assert.deepEqual(t.selection, { start: 0, end: 3 }, "extend 之后选区是 [0,3)");
  t.moveCaret(1, false);
  assert.equal(t.hasSelection, false, "不带 Shift 的移动要清掉选区");
});

test("★ 全选与选中文本", () => {
  const t = typed("中文abc");
  t.selectAll();
  assert.equal(t.selectedText, "中文abc");
  assert.equal(sliceCodePoints(t.value, 1, 3), "文a");
});

test("★ 组合中移动光标 = 放弃这次组合（DOM 里点别处也是先 compositionend）", () => {
  const t = typed("ab");
  t.beginComposition();
  t.updateComposition("ni");
  t.moveCaret(0);
  assert.equal(t.value, "abni", "组合内容按提交处理");
  assert.equal(t.isComposing, false);
  assert.equal(t.caret, 0);
});

test("★ 存档只导出**已提交**的值（组合中的半成品不该进档）", () => {
  const t = typed("ab");
  t.beginComposition();
  t.updateComposition("nihao");
  assert.equal(t.toJSON(), "ab", "半成品进了存档，读回来会是一串没人打算留下的拼音");
  t.commitComposition();
  assert.equal(t.toJSON(), "abnihao");
});

// ------------------------------------------------------------------ ③ 光标几何

const FONT = realFont();

test("★ caretXOf：开头 / 中间 / 末尾（末尾取整串宽度）三处边界", () => {
  const table = [0, 10, 15, 21];
  assert.equal(caretXOf(table, 0), 0);
  assert.equal(caretXOf(table, 2), 15);
  assert.equal(caretXOf(table, 3), 21, "末尾 = 整串宽度（不是最后一格的左边）");
  assert.equal(caretXOf(table, 99), 21, "越界夹到末尾");
  assert.equal(caretXOf(table, -3), 0);
  assert.equal(caretXOf([], 0), 0, "空串也要有定义");
});

test("★★ 光标表与排版一致：无空格的串，每一格左边 == 那一格的 x", () => {
  const s = "abcdefghij";
  const layout = layoutText(FONT, s);
  const table = layout.lineCaretX[0]!;
  assert.equal(table.length, codePointsLength(s) + 1, "表长必须是码点数 + 1");
  assert.equal(layout.quads.length, codePointsLength(s), "前提：无空格的串每个码点都有字形");
  for (let i = 0; i < layout.quads.length; i++) {
    assert.equal(table[i], layout.quads[i]!.x, `第 ${String(i)} 个码点的左边与排版不一致 —— 光标会偏`);
  }
  assert.equal(table[table.length - 1], layout.width, "末尾必须等于整串宽度");
});

test("★★ 有空格时：空格没有字形，但光标表必须照常给它一格", () => {
  const s = "give berry 3";
  const layout = layoutText(FONT, s);
  const table = layout.lineCaretX[0]!;
  assert.equal(table.length, codePointsLength(s) + 1, "空格也要占一格，否则光标从第一个空格起就左移");
  assert.ok(
    layout.quads.length < codePointsLength(s),
    "前提：空格确实不产生字形（这条判据就是为它写的）",
  );
  assert.equal(table[table.length - 1], layout.width, "整串宽度仍要与排版一致（含空格）");
});

test("★ 选区矩形：反向选区也给出正的 x/w", () => {
  const table = [0, 10, 15, 21];
  const forward = inputGeometryOf(table, { start: 0, end: 2 });
  assert.deepEqual(forward.selection, { x: 0, w: 15 });
  assert.equal(forward.caretX, 15);
  const backward = inputGeometryOf(table, { start: 2, end: 0 });
  assert.deepEqual(backward.selection, { x: 0, w: 15 }, "反向选区也必须是正的矩形（负宽度画不出来）");
  assert.equal(inputGeometryOf(table, { start: 1, end: 1 }).selection, null);
});

test("★★ 输入框用到的串不许有缺字（缺字会让光标从那里开始错位）", () => {
  const samples = ["give berry 3", "abcXYZ 019", "save", "clear"];
  for (const s of samples) {
    const layout = layoutText(FONT, s);
    const glyphs = codePointsLength(s) - 1; // 假设只有一个空格
    assert.ok(
      layout.missing.length === 0,
      `「${s}」缺 ${String(layout.missing.length)} 个字形的码点：${layout.missing.join(",")}`,
    );
    assert.ok(glyphs >= 0, "占位");
  }
});
