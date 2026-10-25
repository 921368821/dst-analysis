/**
 * L4 · UI 布局判据（锚点 + 流式 + 命中）
 *
 * 布局的缺陷几乎都是"某个嵌套深度才错"，所以每条都用**可手算的绝对坐标**断言：
 * 只断言"相对父节点偏了 10"会让"父节点本身就摆错了"漏过去。
 *
 * ★ 命中测试放在这个文件里，是因为它**直接依赖布局结果**：
 *   两者分开写会出现"布局改了、命中的期望没改"却各自都绿的组合。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Rect } from "../../src/foundation/math/index.ts";
import {
  ANCHOR_BOTTOM_CENTER,
  ANCHOR_BOTTOM_LEFT,
  ANCHOR_CENTER,
  ANCHOR_TOP_LEFT,
  UiLayoutKind,
  UiWidget,
  buildUiTree,
  hitChain,
  hitTest,
  layoutTree,
  type UiNodeConfig,
} from "../../src/extensions/ui/layout.ts";

const BOUNDS = new Rect(0, 0, 400, 300);

function root(cfg: UiNodeConfig = {}): UiNodeConfig {
  return { id: "root", ...cfg };
}

test("根节点恒等于 bounds（自身 size 不生效）", () => {
  const tree = buildUiTree(root({ size: { w: 50, h: 50 } }));
  layoutTree(tree, BOUNDS);
  assert.equal(tree.rect.width, 400);
  assert.equal(tree.rect.height, 300);
});

test("锚点 + 枢轴 + 偏移：左上贴边、右下贴边都可手算", () => {
  const tree = buildUiTree(
    root({
      children: [
        { id: "tl", size: { w: 40, h: 20 }, offset: { x: 10, y: 12 } },
        {
          id: "br",
          anchor: { x: 1, y: 1 },
          pivot: { x: 1, y: 1 },
          size: { w: 40, h: 20 },
        },
      ],
    }),
  );
  const r = layoutTree(tree, BOUNDS);
  assert.deepEqual(r.get("tl"), new Rect(10, 12, 40, 20));
  // 右下角对齐 ⇒ 矩形是 (360, 280, 40, 20)
  assert.deepEqual(r.get("br"), new Rect(360, 280, 40, 20));
});

test("★ 居中：anchor=0.5 + pivot=0.5 时，中心落在父中心（枢轴写成 0 会红）", () => {
  const tree = buildUiTree(
    root({ children: [{ id: "c", anchor: ANCHOR_CENTER, pivot: ANCHOR_CENTER, size: { w: 100, h: 50 } }] }),
  );
  const r = layoutTree(tree, BOUNDS);
  const rect = r.get("c");
  assert.ok(rect !== undefined);
  assert.equal(rect.x + rect.width / 2, 200, "中心 x = 父宽一半");
  assert.equal(rect.y + rect.height / 2, 150);
  assert.equal(rect.x, 150, "左上角 = 中心 − 半个宽");
});

test("底中锚点（物品栏的典型位置）：水平居中、底边贴住", () => {
  const tree = buildUiTree(
    root({
      children: [
        { id: "hotbar", anchor: ANCHOR_BOTTOM_CENTER, pivot: ANCHOR_BOTTOM_CENTER, size: { w: 200, h: 40 } },
      ],
    }),
  );
  const r = layoutTree(tree, BOUNDS);
  assert.deepEqual(r.get("hotbar"), new Rect(100, 260, 200, 40));
});

test("size 优先于 percent；percent 相对父内区", () => {
  const tree = buildUiTree(
    root({
      padding: { left: 20, right: 20, top: 10, bottom: 10 },
      children: [
        { id: "half", percent: { w: 0.5, h: 0.5 } },
        { id: "fixed", percent: { w: 0.5, h: 0.5 }, size: { w: 30, h: 30 } },
      ],
    }),
  );
  const r = layoutTree(tree, BOUNDS);
  // 内区 360×280 ⇒ 半宽 180、半高 140
  assert.deepEqual(r.get("half"), new Rect(20, 10, 180, 140));
  assert.deepEqual(r.get("fixed"), new Rect(20, 10, 30, 30), "size 给了就用 size");
});

test("row：按顺序排 + gap；内容宽可手算", () => {
  const tree = buildUiTree(
    root({
      kind: UiLayoutKind.Row,
      gap: 5,
      children: [
        { id: "a", size: { w: 20, h: 10 } },
        { id: "b", size: { w: 20, h: 10 } },
        { id: "c", size: { w: 20, h: 10 } },
      ],
    }),
  );
  const r = layoutTree(tree, BOUNDS);
  assert.equal(r.get("a")?.x, 0);
  assert.equal(r.get("b")?.x, 25, "20 + gap 5");
  assert.equal(r.get("c")?.x, 50);
  assert.equal(tree.measured.w, 0 + 20 + 5 + 20 + 5 + 20, "内容宽 = 三段 + 两个 gap");
});

test("★ grow 分剩余空间：两个 grow=1 的子平分 100 宽", () => {
  // ★ 注意：grow 必须挂在一个**有确定宽度**的容器上。根节点按约定忽略自身 size
  //   （恒等于 bounds），所以这里先放一个 100 宽的 row 容器。
  const tree = buildUiTree(
    root({
      children: [
        {
          id: "row",
          kind: UiLayoutKind.Row,
          size: { w: 100, h: 20 },
          children: [
            { id: "a", size: { w: 20, h: 20 }, grow: 1 },
            { id: "b", size: { w: 20, h: 20 }, grow: 1 },
          ],
        },
      ],
    }),
  );
  const r = layoutTree(tree, BOUNDS);
  assert.equal(r.get("row")?.width, 100);
  assert.equal(r.get("a")?.width, 50, "各 20 + 剩余 60 的一半");
  assert.equal(r.get("b")?.width, 50);
  assert.equal(r.get("b")?.x, 50);
});

test("grid：3 列，第 4 个换到第二行（背包格的基础）", () => {
  const cells = Array.from({ length: 5 }, (_, i) => ({ id: `c${i}`, widget: UiWidget.Image }) as UiNodeConfig);
  const tree = buildUiTree(
    root({ kind: UiLayoutKind.Grid, columns: 3, cell: { w: 30, h: 30 }, gap: 4, children: cells }),
  );
  const r = layoutTree(tree, BOUNDS);
  assert.equal(r.get("c0")?.x, 0);
  assert.equal(r.get("c2")?.x, 68, "2 × (30 + 4)");
  assert.equal(r.get("c3")?.x, 0, "第 4 个回到第一列");
  assert.equal(r.get("c3")?.y, 34, "第二行");
  assert.equal(r.get("c4")?.y, 34);
});

test("★ visible=false 完全不参与布局（不占位，后面的前移）", () => {
  const tree = buildUiTree(
    root({
      kind: UiLayoutKind.Row,
      gap: 0,
      children: [
        { id: "a", size: { w: 20, h: 10 } },
        { id: "hidden", size: { w: 50, h: 10 }, visible: false },
        { id: "b", size: { w: 20, h: 10 } },
      ],
    }),
  );
  const r = layoutTree(tree, BOUNDS);
  assert.equal(r.get("b")?.x, 20, "隐藏的不占位，b 紧接着 a");
  assert.equal(r.get("hidden"), undefined, "不可见节点不该出现在布局结果里");
  assert.equal(tree.measured.w, 40, "内容宽只算可见的两个");
});

test("嵌套：row 里的 label 用它自己的内区，不叠加父的 padding", () => {
  const tree = buildUiTree(
    root({
      padding: { left: 10, top: 10 },
      kind: UiLayoutKind.Row,
      children: [{ id: "lbl", size: { w: 60, h: 20 } }],
    }),
  );
  const r = layoutTree(tree, BOUNDS);
  assert.deepEqual(r.get("lbl"), new Rect(10, 10, 60, 20));
});

test("margin 只影响自身位置，不影响内区（写成扣内区会少两次）", () => {
  const tree = buildUiTree(
    root({
      kind: UiLayoutKind.Row,
      children: [{ id: "a", size: { w: 20, h: 20 }, margin: { left: 8, top: 4 } }],
    }),
  );
  const r = layoutTree(tree, BOUNDS);
  assert.equal(r.get("a")?.x, 8);
  assert.equal(r.get("a")?.y, 4);
  assert.equal(r.get("a")?.width, 20, "margin 不该把宽度啃掉");
});

test("负尺寸与 NaN 夹成 0（不能让整棵子树消失）", () => {
  const tree = buildUiTree(root({ children: [{ id: "bad", size: { w: -30, h: Number.NaN } }] }));
  const r = layoutTree(tree, BOUNDS);
  assert.equal(r.get("bad")?.width, 0);
  assert.equal(r.get("bad")?.height, 0);
});

test("id 重复直接抛（否则命中会打到错的那个）", () => {
  const tree = buildUiTree(
    root({ children: [{ id: "dup", size: { w: 10, h: 10 } }, { id: "dup", size: { w: 10, h: 10 } }] }),
  );
  assert.throws(() => layoutTree(tree, BOUNDS), /id 重复/);
});

test("★ 命中：后画的先命中（叠放的两个按钮，点上面那个）", () => {
  const tree = buildUiTree(
    root({
      children: [
        { id: "under", size: { w: 100, h: 100 }, interactive: true, opaque: true },
        { id: "over", size: { w: 100, h: 100 }, offset: { x: 0, y: 0 }, interactive: true, opaque: true },
      ],
    }),
  );
  layoutTree(tree, BOUNDS);
  const hit = hitTest(tree, 50, 50);
  assert.equal(hit?.id, "over");
});

test("★ opaque 遮罩：点在不透明面板的空白处不会穿透到底下的按钮", () => {
  const tree = buildUiTree(
    root({
      children: [
        { id: "btn", size: { w: 100, h: 50 }, interactive: true, opaque: true },
        { id: "modal", size: { w: 400, h: 300 }, opaque: true, visible: false },
      ],
    }),
  );
  layoutTree(tree, BOUNDS);
  assert.equal(hitTest(tree, 50, 25)?.id, "btn", "没有遮罩时按钮可点");

  // 打开遮罩：它不 interactive，但 opaque ⇒ 必须挡住下层
  tree.children[1]!.visible = true;
  layoutTree(tree, BOUNDS);
  assert.equal(hitTest(tree, 50, 25), null, "遮罩不处理点击，但不能让点击穿透");
});

test("命中链：从目标一路向上到根（冒泡用）", () => {
  const tree = buildUiTree(
    root({
      children: [
        {
          id: "panel",
          size: { w: 200, h: 200 },
          interactive: true,
          children: [{ id: "child", size: { w: 50, h: 50 }, offset: { x: 10, y: 10 }, interactive: true }],
        },
      ],
    }),
  );
  layoutTree(tree, BOUNDS);
  const hit = hitTest(tree, 20, 20);
  assert.equal(hit?.id, "child");
  const chain = hitChain(hit).map((n) => n.id);
  assert.deepEqual(chain, ["child", "panel", "root"]);
});

test("锚点常量存在且语义正确（左上 / 底左是 HUD 最常用的两个）", () => {
  assert.deepEqual(ANCHOR_TOP_LEFT, { x: 0, y: 0 });
  assert.deepEqual(ANCHOR_BOTTOM_LEFT, { x: 0, y: 1 });
});
