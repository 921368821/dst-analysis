/**
 * L4 · UI 滚动容器判据（C9）
 *
 * 这块东西看起来只是"内容装不下就滚"，但真正会坏的地方有三处，各自对一类症状：
 *
 *   ① **上限算错**（用 `measured` 而不是 `contentExtent`）⇒ 永远滚不动，或滚到底还空一段。
 *      症状与"滚轮没接上"一模一样，所以上限必须单独一条判据钉住。
 *   ② **越界偏移不夹回**：内容变短（删一行 / 换分辨率）之后偏移还在旧位置，
 *      症状是"列表底部空着、滚不回去"，而且**只在内容变短时**出现。
 *      夹取之后还必须**写回状态表**，否则下一次改内容又跳。
 *   ③ **裁剪只做一半**：画的时候裁了、命中没裁 ⇒ 点在露在面板外的半个按钮上，
 *      点中了看不见的东西。两者必须读同一个 `clipRect`。
 *
 * ★ 数字全部手算：面板 100 高、5 行 × 30 = 150 ⇒ 上限 50；
 *   末行 30 高、只露出 10 ⇒ UV 从 20/30 开始。
 *   抄实现算出来的数字不算判据（那种断言只能证明"改了两处都一样"）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { Rect } from "../../src/foundation/math/index.ts";
import {
  buildUiTree,
  hitTest,
  layoutTree,
  UiLayoutKind,
  UiNode,
  type UiNodeConfig,
  type UiScrollSource,
} from "../../src/extensions/ui/layout.ts";
import { UiInputRouter } from "../../src/extensions/ui/events.ts";
import { buildUiQuads, type UiSkin } from "../../src/extensions/ui/widgets.ts";
import { UiStateStore } from "../../src/extensions/ui/state.ts";
import { FontRegistry } from "../../src/extensions/ui/font.ts";
import { makeTestFont } from "./ui-fixtures.ts";

const BOUNDS = new Rect(0, 0, 400, 300);

/** 内存里的滚动源，顺带记下"谁写过什么"（写回是判据的一部分，不记就验不到）。 */
interface MemSource extends UiScrollSource {
  readonly writes: Array<readonly [number, number]>;
}

function memSource(init: { readonly [uid: number]: number } = {}): MemSource {
  const m = new Map<number, number>(Object.entries(init).map(([k, v]) => [Number(k), v]));
  const writes: Array<readonly [number, number]> = [];
  return {
    writes,
    get: (uid) => m.get(uid) ?? 0,
    set: (uid, v) => {
      writes.push([uid, v]);
      m.set(uid, v);
    },
  };
}

interface ListRig {
  readonly tree: UiNode;
  readonly list: UiNode;
  readonly rows: readonly UiNode[];
}

/** root(400×300, free) > list(200×panelH, column, scroll) > rows × (200×rowH) */
function listRig(rowCount: number, rowH = 30, panelH = 100, widget: "image" | "label" = "image"): ListRig {
  const children: UiNodeConfig[] = [];
  for (let i = 0; i < rowCount; i++) {
    children.push(
      widget === "image"
        ? { id: `r${String(i)}`, widget: "image", size: { w: 200, h: rowH }, props: { frame: "px" } }
        : { id: `r${String(i)}`, widget: "label", size: { w: 200, h: rowH }, props: { text: "AB", fontId: "test" } },
    );
  }
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "list",
        kind: UiLayoutKind.Column,
        scroll: true,
        size: { w: 200, h: panelH },
        children,
      },
    ],
  });
  const list = tree.find("list");
  assert.ok(list !== undefined, "夹具里的 list 不见了");
  return {
    tree,
    list,
    rows: children.map((c) => {
      const n = tree.find(c.id!);
      assert.ok(n !== undefined, `夹具里的 ${c.id!} 不见了`);
      return n;
    }),
  };
}

// ── ① 上限 ─────────────────────────────────────────────────

test("★ 滚动上限 = 内容长 − 内区（5×30 装进 100 ⇒ 50）", () => {
  const { tree, list } = listRig(5);
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  assert.equal(list.contentExtent.h, 150, "内容长 = 5 行 × 30");
  assert.equal(list.measured.h, 100, "可视长 = 固定尺寸（不能被内容撑开）");
  assert.equal(list.scrollMax, 50);
});

test("★ 装得下时上限是 0（不能出现「能往上拖一点空」）", () => {
  const { tree, list } = listRig(3); // 3×30 = 90 < 100
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  assert.equal(list.scrollMax, 0);
});

test("padding 会缩小可视区，因而抬高上限", () => {
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "list",
        kind: UiLayoutKind.Column,
        scroll: true,
        size: { w: 200, h: 100 },
        padding: { top: 10, bottom: 10 },
        children: [
          { id: "a", widget: "image", size: { w: 200, h: 150 }, props: { frame: "px" } },
        ],
      },
    ],
  });
  const list = tree.find("list")!;
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  // 内区 80，内容 150 ⇒ 70（不是 50：padding 是真占地方的）
  assert.equal(list.scrollMax, 70);
});

test("★ 不给滚动源：上限照样算对，内容不动", () => {
  const { tree, list, rows } = listRig(5);
  layoutTree(tree, BOUNDS);
  assert.equal(list.scrollMax, 50, "上限是布局的产物，不依赖状态表");
  assert.equal(rows[0]!.rect.y, 0, "没有源 ⇒ 偏移按 0");
});

// ── ② 偏移与夹取 ────────────────────────────────────────────

test("偏移把内容整体上推（第 i 行 y = 30i − 偏移）", () => {
  const { tree, list, rows } = listRig(5);
  const src = memSource({ [list.uid]: 20 });
  layoutTree(tree, BOUNDS, { scroll: src });
  assert.equal(rows[0]!.rect.y, -20);
  assert.equal(rows[1]!.rect.y, 10);
  assert.equal(src.writes.length, 0, "20 在 [0,50] 里，不该被写回");
});

test("★ 越界偏移被夹到上限，并**写回**状态表", () => {
  const { tree, list, rows } = listRig(5);
  const src = memSource({ [list.uid]: 999 });
  layoutTree(tree, BOUNDS, { scroll: src });
  assert.equal(rows[0]!.rect.y, -50, "夹到 50 而不是 999");
  assert.deepEqual(src.writes, [[list.uid, 50]], "必须写回：只夹不写，下一次改内容又会跳");
  assert.equal(src.get(list.uid), 50);
});

test("★ 内容变短之后旧偏移自动回落（列表底部不再空一段）", () => {
  const { tree, list, rows } = listRig(5);
  const src = memSource({ [list.uid]: 50 });
  layoutTree(tree, BOUNDS, { scroll: src });
  assert.equal(rows[0]!.rect.y, -50);

  // 删掉后两行 ⇒ 内容 90 < 内区 100 ⇒ 上限 0
  rows[3]!.visible = false;
  rows[4]!.visible = false;
  src.writes.length = 0;
  layoutTree(tree, BOUNDS, { scroll: src });
  assert.equal(list.scrollMax, 0);
  assert.equal(rows[0]!.rect.y, 0, "回落到底");
  assert.deepEqual(src.writes, [[list.uid, 0]]);
});

test("负偏移夹到 0", () => {
  const { tree, list, rows } = listRig(5);
  const src = memSource({ [list.uid]: -30 });
  layoutTree(tree, BOUNDS, { scroll: src });
  assert.equal(rows[0]!.rect.y, 0);
  assert.deepEqual(src.writes, [[list.uid, 0]]);
});

test("★ 非有限偏移当 0 处理（NaN 不能变成「滚回顶部」的假象）", () => {
  const { tree, list, rows } = listRig(5);
  const src = memSource({ [list.uid]: Number.NaN });
  layoutTree(tree, BOUNDS, { scroll: src });
  assert.equal(rows[0]!.rect.y, 0);
  assert.deepEqual(src.writes, [[list.uid, 0]]);
});

test("横向列表按 x 滚（row 的主轴），y 不受影响", () => {
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "strip",
        kind: UiLayoutKind.Row,
        scroll: true,
        size: { w: 100, h: 40 },
        children: Array.from({ length: 4 }, (_, i) => ({
          id: `c${String(i)}`,
          widget: "image" as const,
          size: { w: 50, h: 40 },
          props: { frame: "px" },
        })),
      },
    ],
  });
  const strip = tree.find("strip")!;
  const src = memSource({ [strip.uid]: 30 });
  layoutTree(tree, BOUNDS, { scroll: src });
  assert.equal(strip.scrollAxis, "x");
  assert.equal(strip.scrollMax, 100, "4×50 − 100");
  assert.equal(tree.find("c0")!.rect.x, -30);
  assert.equal(tree.find("c1")!.rect.x, 20);
  assert.equal(tree.find("c0")!.rect.y, 0, "横向滚动不能带动纵向");
});

test("★ free 容器：内容总尺寸由 contentSize 给，不给就滚不动", () => {
  const mk = (contentSize?: { w: number; h: number }) => {
    const t = buildUiTree({
      id: "root",
      children: [
        {
          id: "free",
          scroll: true,
          size: { w: 100, h: 100 },
          ...(contentSize === undefined ? {} : { contentSize }),
          children: [{ id: "big", widget: "image", size: { w: 100, h: 400 }, props: { frame: "px" } }],
        },
      ],
    });
    const n = t.find("free")!;
    const src = memSource({ [n.uid]: 120 });
    layoutTree(t, BOUNDS, { scroll: src });
    return { n, src };
  };
  // ★ free 容器没有"内容包围盒"（子节点按锚点定位，反推会得到等于父尺寸的假值），
  //   所以这里必须由作者显式给 —— 不给就是 **0，滚不动**。这是**有意**的：
  //   猜一个"子节点最小公共外框"，在贴底/居中的子节点上会随分辨率变化。
  assert.equal(mk().n.scrollMax, 0, "没给 contentSize ⇒ 滚不动");
  assert.equal(mk({ w: 100, h: 400 }).n.scrollMax, 300);
});

// ── ③ 裁剪框 ───────────────────────────────────────────────

test("滚动容器的子节点被裁到内区；容器自己不裁", () => {
  const { tree, list, rows } = listRig(5);
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  assert.equal(list.clipRect, null, "list 自己是普通节点（由祖先决定裁不裁）");
  assert.deepEqual(rows[0]!.clipRect, new Rect(0, 0, 200, 100));
  assert.deepEqual(rows[4]!.clipRect, new Rect(0, 0, 200, 100));
});

test("不滚动的容器不产生裁剪框（子节点照样不裁）", () => {
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "box",
        kind: UiLayoutKind.Column,
        size: { w: 200, h: 100 },
        children: [{ id: "a", widget: "image", size: { w: 200, h: 30 }, props: { frame: "px" } }],
      },
    ],
  });
  layoutTree(tree, BOUNDS);
  assert.equal(tree.find("box")!.clipRect, null);
  assert.equal(tree.find("a")!.clipRect, null);
});

test("★ 横向列表按 x 滚（row 的主轴），y 不受影响", () => {
  const tree = buildUiTree({
    id: "root",
    children: [
      {
        id: "outer",
        kind: UiLayoutKind.Column,
        scroll: true,
        size: { w: 300, h: 200 },
        padding: { top: 10, left: 10, bottom: 10, right: 10 },
        children: [
          {
            id: "inner",
            kind: UiLayoutKind.Column,
            scroll: true,
            size: { w: 400, h: 300 },
            children: [{ id: "row", widget: "image", size: { w: 400, h: 50 }, props: { frame: "px" } }],
          },
        ],
      },
    ],
  });
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  // outer 内区 (10,10,280,180)；inner 的内区更大 (10,10,400,300) ⇒ 取交 = (10,10,280,180)
  assert.deepEqual(tree.find("row")!.clipRect, new Rect(10, 10, 280, 180));
});

// ── ④ 事件：滚轮投给谁 ──────────────────────────────────────

function routerRig(): { r: UiInputRouter; rows: readonly UiNode[] } {
  const { tree, rows } = listRig(5);
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  return { r: new UiInputRouter(tree), rows };
}

test("★ 滚轮投给**最近的滚动容器祖先**，不是命中目标", () => {
  const { r } = routerRig();
  const evts = r.update({ x: 10, y: 10, down: false, wheelY: 12 });
  const wheel = evts.find((e) => e.type === "wheel");
  assert.ok(wheel !== undefined, "必须产生 wheel 事件");
  assert.equal(wheel.target.id, "list", "目标是滚动容器，不是被指着的行");
  assert.equal(wheel.wheelY, 12);
});

test("滚轮冒泡到根（容器自己也能被宿主截断）", () => {
  const { r } = routerRig();
  const seen: string[] = [];
  r.update({ x: 10, y: 10, down: false, wheelY: 5 }, (ev) => {
    if (ev.type === "wheel") seen.push(ev.currentTarget.id);
  });
  assert.deepEqual(seen, ["list", "root"]);
});

test("指针不在任何滚动容器里 ⇒ 没有 wheel 事件", () => {
  const { r } = routerRig();
  const evts = r.update({ x: 350, y: 250, down: false, wheelY: 12 });
  assert.equal(evts.some((e) => e.type === "wheel"), false);
});

test("★ 滚轮不打断拖拽：按下中滚一下，抬起仍算同一个目标的点击", () => {
  // ★ 这条守的是"滚轮改 `downTarget`"这类错误。真实动作序列"按住一个条目滚一下再松开"
  //   在手机与触控板上都很常见，坏了的表现是"点了没反应"。
  const { r, rows } = routerRig();
  rows[0]!.interactive = true;
  rows[0]!.opaque = true;
  r.update({ x: 10, y: 10, down: true });
  r.update({ x: 10, y: 10, down: true, wheelY: 30 });
  const up = r.update({ x: 10, y: 10, down: false });
  const types = up.map((e) => e.type);
  assert.ok(types.includes("pointerup"));
  assert.ok(types.includes("click"), "滚动不该把这次点击吃掉");
  assert.equal(up.find((e) => e.type === "click")?.target.id, "r0");
});

test("★ 隐藏一个容器 ⇒ **整棵子树**都不画（这是隐藏的语义，不是优化）", () => {
  // ★ 这条是批105 顺着 C9 摸出来的一个**既有漏洞**：`visible=false` 原来只挡住
  //   容器自己，子节点保留上一次布局的矩形继续画 —— 实测把一个面板隐藏后
  //   quads 数一点没变（"关不掉的背包"）。而文件头上写着"等价于从树上摘掉"，
  //   那句话是所有人写代码时的前提，所以坏掉的时候没人会往这里想。
  const rig = listRig(5);
  const before = draw(rig, 0);
  assert.equal(before.quads.length, 4, "先确认它本来是画出来的（否则下面那条是空转）");
  rig.list.visible = false;
  const after = draw(rig, 0);
  assert.equal(after.quads.length, 0, "容器藏了，里面的行也不能画");
  assert.equal(after.stats.labels, 0);
});

test("★ 隐藏容器的子节点也**点不中**（旧矩形不该还能响应点击）", () => {
  const { tree, list, rows } = listRig(5);
  rows[0]!.interactive = true;
  rows[0]!.opaque = true;
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  assert.equal(hitTest(tree, 10, 10)?.id, "r0", "先确认它本来能点中");
  list.visible = false;
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  assert.equal(hitTest(tree, 10, 10), null, "容器藏了，子节点不能再吃到点击");
});

test("隐藏的滚动容器不收滚轮（滚了看不见的列表最莫名其妙）", () => {
  const { tree, list } = listRig(5);
  list.visible = false;
  layoutTree(tree, BOUNDS, { scroll: memSource() });
  const r = new UiInputRouter(tree);
  const evts = r.update({ x: 10, y: 10, down: false, wheelY: 12 });
  assert.equal(evts.some((e) => e.type === "wheel"), false);
});

test("滚轮量为 0 ⇒ 不发事件（避免每帧空投）", () => {
  const { r } = routerRig();
  const evts = r.update({ x: 10, y: 10, down: false, wheelY: 0 });
  assert.equal(evts.some((e) => e.type === "wheel"), false);
});

// ── ⑤ 绘制：CPU 侧裁剪 ─────────────────────────────────────

const SKIN: UiSkin = {
  frames: new Map([["px", { page: 0, u0: 0, v0: 0, u1: 1, v1: 1, width: 8, height: 8 }]]),
};

function draw(rig: ListRig, offset: number) {
  const src = memSource({ [rig.list.uid]: offset });
  layoutTree(rig.tree, BOUNDS, { scroll: src });
  const fonts = new FontRegistry();
  fonts.register(makeTestFont());
  return buildUiQuads(rig.tree, fonts, SKIN, new UiStateStore());
}

test("★ 滚出裁剪框的行完全不产生四边形（省的是顶点，也是排版）", () => {
  const rig = listRig(5);
  // ★ 这条判据要同时读**两个观测量**：只数 quad 个数的话，「滚动没生效」与
  //   「滚动生效了但没裁」会得到同一个数字 —— 必须再加上「最上面/最下面落在哪」。
  const top = draw(rig, 0);
  assert.equal(top.quads.length, 4, "5 行里只有 4 行落在 0..100 的框里");
  assert.equal(top.stats.culled, 1, "culled 必须有数：否则「忘传 clip」会让 quad 数悄悄翻倍而画面正常");
  assert.equal(
    Math.max(...top.quads.map((q) => q.z + q.h)),
    100,
    "最下面那一块止于裁剪框底（不是 150 —— 那说明第 5 行漏画出来了）",
  );

  const bottom = draw(rig, 50);
  assert.equal(bottom.quads.length, 4);
  assert.equal(bottom.stats.culled, 1, "滚到底之后被裁的是**上面**那一行");
  assert.equal(
    Math.min(...bottom.quads.map((q) => q.z)),
    0,
    "最上面那一块从框顶开始 —— 若仍是 −20，说明偏移没生效",
  );
});

test("★ 半露的行按**比例裁 UV**（不是整块丢、也不是整块画）", () => {
  const rig = listRig(5);
  const res = draw(rig, 20);
  // 行 0 在 −20..10，只露 0..10 这 10px ⇒ 高度 10、v 从 20/30 开始
  const first = res.quads.find((q) => q.h === 10 && Math.abs(q.z - 0) < 1e-9);
  assert.ok(first !== undefined, "被裁的那块必须还在（只是变矮），否则列表边界会缺一整行");
  assert.equal(first.w, 200);
  assert.ok(Math.abs(first.v0 - 20 / 30) < 1e-9, `v0 应为 20/30，实际 ${String(first.v0)}`);
  assert.ok(Math.abs(first.v1 - 1) < 1e-9, "v1 落在图的下边缘");
});

test("★ 整块被裁的标签**连排版都不做**（labels/glyphs 计数是唯一能看见它的地方）", () => {
  const rig = listRig(5, 30, 100, "label");
  // 偏移 50：行 0 在 −50..−20（完全在外）、行 1 在 −20..10（露一半）
  const res = draw(rig, 50);
  assert.equal(res.stats.labels, 4, "5 行里只有 4 行的矩形碰到了裁剪框");
  assert.equal(res.stats.glyphs, 8, "每行 2 个字");
});

test("★ 裁掉的部分不能点：露在面板外的按钮点不中", () => {
  const { tree, rows } = listRig(5);
  rows[0]!.interactive = true;
  rows[0]!.opaque = true;
  // 第 1 行也做成按钮：后面要断言「框内的能点中」，没有它这条就只是
  // 「凡是有行都返回 null」也能过 —— 那等于没验证裁剪
  rows[1]!.interactive = true;
  rows[1]!.opaque = true;
  const src = memSource({ [rows[0]!.parent!.uid]: 30 });
  layoutTree(tree, BOUNDS, { scroll: src });
  // 行 0 现在在 −30..0，它的矩形确实包含 (10,−10)，但那里在裁剪框外
  assert.equal(hitTest(tree, 10, -10), null, "看不见的地方不该能点中");
  // 而面板内同一行的下半部分（−30..0 里 0 以下没有），行 1 在 0..30
  assert.equal(hitTest(tree, 10, 10)?.id, "r1");
});

// ── ⑥ 状态表口径 ───────────────────────────────────────────

test("滚动的归属：`reset()` 清、`invalidateDerived()` 不清（换字体不该回顶）", () => {
  const store = new UiStateStore();
  store.setScroll(7, 40);
  store.invalidateDerived();
  assert.equal(store.scrollOf(7), 40, "换字体只是重排，不该让用户正在看的位置回顶");
  store.reset();
  assert.equal(store.scrollOf(7), 0);
});
