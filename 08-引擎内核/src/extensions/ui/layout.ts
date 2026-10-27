/**
 * L4 · UI 布局（锚点 + 流式，一遍测量、一遍摆放）
 *
 * UI 节点树**不进 Scene**，是独立的一棵树。理由不是"图省事"：
 *   · Scene 的节点有 `worldPosition`、参与空间索引与存档，而 UI 的"位置"是
 *     父容器的相对量，存下来没有意义（换个分辨率就该重算）；
 *   · 把 UI 塞进 Scene 会让 `componentsOf` 的遍历多出一类永远不参与物理/AI 的节点，
 *     而 2.5D 的可见性裁剪是按世界矩形做的 —— UI 会被裁掉。
 *
 * ★★ 两套摆放算法，各有各的适用面（饥荒那一类游戏两套都要）：
 *   · **锚点（free）**：贴边元素——血条贴左上、物品栏贴底中、提示贴顶中。
 *     这是 HUD 的绝大多数；它必须对"屏幕尺寸变化"稳定，所以锚定在父容器的
 *     **比例点**上，而不是绝对坐标。
 *   · **流式（row / column / grid）**：背包格、制作列表、按钮组。
 *     它的尺寸由内容决定，不该靠手写坐标维护 —— 加一个配方就要改一次坐标是灾难。
 *
 * ★ 测量与摆放分开，且**测量只做一次**：
 *   若边测边摆，`percent` 尺寸会拿到"还没算完的父尺寸"，症状是"嵌套百分比
 *   在某些层级上偏一点点"，而且只在特定嵌套深度出现。
 *
 * ★ `visible=false` 的节点**完全不参与**布局（不占位），等价于从树上摘掉。
 *   需要"占位但看不见"用 `visible=false + 保留 size` 做不到 —— 那是两种语义，
 *   混在一起会让"隐藏一个按钮后后面的按钮跳不跳"变成需要试才知道的问题。
 */

import { Color, Rect } from "../../foundation/math/index.ts";
import type { TextStyle } from "./text-layout.ts";

export const UiLayoutKind = { Free: "free", Row: "row", Column: "column", Grid: "grid" } as const;
export type UiLayoutKindValue = (typeof UiLayoutKind)[keyof typeof UiLayoutKind];

export const UiWidget = {
  Group: "group",
  Panel: "panel",
  Image: "image",
  Label: "label",
  Button: "button",
  Progress: "progress",
  Spacer: "spacer",
} as const;
export type UiWidgetValue = (typeof UiWidget)[keyof typeof UiWidget];

/** 九宫格锚点：0 = 左/上，0.5 = 中，1 = 右/下。 */
export interface UiPoint {
  readonly x: number;
  readonly y: number;
}

export const ANCHOR_TOP_LEFT: UiPoint = { x: 0, y: 0 };
export const ANCHOR_TOP_CENTER: UiPoint = { x: 0.5, y: 0 };
export const ANCHOR_CENTER: UiPoint = { x: 0.5, y: 0.5 };
export const ANCHOR_BOTTOM_CENTER: UiPoint = { x: 0.5, y: 1 };
export const ANCHOR_BOTTOM_LEFT: UiPoint = { x: 0, y: 1 };

export interface UiPadding {
  readonly top?: number;
  readonly right?: number;
  readonly bottom?: number;
  readonly left?: number;
}

/** 控件绘制参数。`widgets.ts` 解释它们，布局层只透传。 */
export interface UiProps {
  readonly frame?: string;
  /** 九宫格边距（设计 px）。0 = 整图拉伸。 */
  readonly slice?: number;
  readonly text?: string;
  readonly fontId?: string;
  readonly style?: TextStyle;
  readonly tint?: Color;
  readonly value?: number;
  readonly textColor?: Color;
  /** button 的按下/悬停底色（缺省用 tint）。 */
  readonly activeTint?: Color;
}

export interface UiNodeConfig {
  readonly id?: string;
  readonly widget?: UiWidgetValue;
  readonly kind?: UiLayoutKindValue;
  readonly anchor?: UiPoint;
  readonly pivot?: UiPoint;
  readonly offset?: UiPoint;
  readonly size?: { readonly w?: number; readonly h?: number };
  /** 相对父容器内区的比例（0..1）。与 size 同时给时 **size 优先**。 */
  readonly percent?: { readonly w?: number; readonly h?: number };
  /** 流式布局里占剩余空间的比例。0 = 不占。 */
  readonly grow?: number;
  readonly padding?: UiPadding;
  readonly margin?: UiPadding;
  readonly gap?: number;
  readonly columns?: number;
  readonly cell?: { readonly w: number; readonly h: number };
  readonly visible?: boolean;
  /**
   * 自身不透明度（0..1，默认 1）。**会与父节点的相乘**（见 `UiNode.opacity`）。
   */
  readonly opacity?: number;
  /**
   * 自身缩放（默认 1，绕 `pivot` 缩放）。**会与父节点的相乘**。
   */
  readonly scale?: number;
  /** 参与命中测试。false = 点击穿透到下层。 */
  readonly interactive?: boolean;
  /** 命中后是否阻断下层（面板/按钮必须 true，否则点按钮会同时点到背后）。 */
  readonly opaque?: boolean;
  /** 叶子的自然尺寸（文本量出来的宽高、图片帧的尺寸）。由控件层写入。 */
  readonly contentSize?: { readonly w: number; readonly h: number };
  readonly props?: UiProps;
  readonly children?: readonly UiNodeConfig[];
}

let nextNodeId = 1;

export class UiNode {
  readonly uid: number;
  id: string;
  widget: UiWidgetValue;
  kind: UiLayoutKindValue;
  anchor: UiPoint;
  pivot: UiPoint;
  offset: UiPoint;
  size: { w?: number; h?: number };
  percent: { w?: number; h?: number };
  grow: number;
  padding: Required<UiPadding>;
  margin: Required<UiPadding>;
  gap: number;
  columns: number;
  cell: { w: number; h: number } | null;
  visible: boolean;
  /**
   * 自身不透明度 0..1（默认 1）。
   *
   * ★ 为什么是"自身"而不是"最终"：过渡动画（批76 `tween.player`）要能把父节点淡到 0.5、
   *   子节点淡到 0.5 而得到 0.25。若这里存的是最终值，动画一改父节点就得遍历子树重算 ——
   *   而"遍历子树"与"每帧"叠在一起就是 O(节点数) 的隐式成本，且父子谁覆盖谁说不清。
   *   最终值在**画的时候**乘出来（`widgets.ts` 的 `alphaOf`），是纯粹的读取。
   *
   * ★ 语义边界：`opacity` **不参与布局**（不透明的东西和透明的占一样的位置）。
   *   要"不占位"用 `visible=false` —— 两者是两件事（见文件头 ★）。
   */
  opacity: number;
  /**
   * 自身缩放 1 = 原尺寸，绕 `pivot` 缩放。
   *
   * ★ **不改 `measured`**：改 measured 会让父容器的流式布局把"放大到 1.2 倍"算进尺寸，
   *   于是弹一下的按钮会把它后面的按钮挤开。过渡要的是"原地变大"，不是"重新排版"。
   * ★ **沿父链组合**（见 `arrange` 的注释）：父 2 倍、子再 2 倍 ⇒ 子看到的是 4 倍，
   *   位置也一起放大 —— 一组 UI 弹出时是整体放大，不是各自从自己的左上角长。
   */
  scale: number;
  interactive: boolean;
  opaque: boolean;
  contentSize: { w: number; h: number };
  props: UiProps;
  readonly children: UiNode[] = [];
  parent: UiNode | null = null;
  /** 布局结果（设计坐标，绝对值）。 */
  rect: Rect = Rect.zero;
  /** 测量阶段的自然尺寸。 */
  measured: { w: number; h: number } = { w: 0, h: 0 };

  constructor(cfg: UiNodeConfig = {}) {
    this.uid = nextNodeId++;
    this.id = cfg.id ?? `#${this.uid}`;
    this.widget = cfg.widget ?? UiWidget.Group;
    this.kind = cfg.kind ?? UiLayoutKind.Free;
    this.anchor = cfg.anchor ?? ANCHOR_TOP_LEFT;
    this.pivot = cfg.pivot ?? ANCHOR_TOP_LEFT;
    this.offset = cfg.offset ?? { x: 0, y: 0 };
    this.size = { ...(cfg.size ?? {}) };
    this.percent = { ...(cfg.percent ?? {}) };
    this.grow = cfg.grow ?? 0;
    this.padding = {
      top: cfg.padding?.top ?? 0,
      right: cfg.padding?.right ?? 0,
      bottom: cfg.padding?.bottom ?? 0,
      left: cfg.padding?.left ?? 0,
    };
    this.margin = {
      top: cfg.margin?.top ?? 0,
      right: cfg.margin?.right ?? 0,
      bottom: cfg.margin?.bottom ?? 0,
      left: cfg.margin?.left ?? 0,
    };
    this.gap = cfg.gap ?? 0;
    this.columns = Math.max(1, Math.floor(cfg.columns ?? 1));
    this.cell = cfg.cell === undefined ? null : { w: cfg.cell.w, h: cfg.cell.h };
    this.visible = cfg.visible ?? true;
    this.opacity = clampOpacity(cfg.opacity ?? 1);
    this.scale = clampScale(cfg.scale ?? 1);
    this.interactive = cfg.interactive ?? false;
    this.opaque = cfg.opaque ?? false;
    this.contentSize = { w: cfg.contentSize?.w ?? 0, h: cfg.contentSize?.h ?? 0 };
    this.props = cfg.props ?? {};
    for (const c of cfg.children ?? []) this.add(new UiNode(c));
  }

  add(child: UiNode): void {
    child.parent = this;
    this.children.push(child);
  }

  /** 从前序（绘制顺序）里取所有节点。 */
  *walk(): Generator<UiNode> {
    yield this;
    for (const c of this.children) yield* c.walk();
  }

  find(id: string): UiNode | undefined {
    for (const n of this.walk()) if (n.id === id) return n;
    return undefined;
  }

  /**
   * 内区（只扣 padding）。流式布局摆放子节点用它。
   * ★ 这里**不扣 margin**：margin 是"节点相对父容器"的外边距，作用于自身被摆放的位置，
   *   扣进内区会让它同时影响"自己占多大"和"子节点从哪开始"——两处都少一点，叠加起来偏得很隐蔽。
   */
  inner(rect: Rect): Rect {
    const l = this.padding.left;
    const t = this.padding.top;
    const r = this.padding.right;
    const b = this.padding.bottom;
    return new Rect(
      rect.x + l,
      rect.y + t,
      Math.max(0, rect.width - l - r),
      Math.max(0, rect.height - t - b),
    );
  }
}

export function buildUiTree(cfg: UiNodeConfig): UiNode {
  return new UiNode(cfg);
}

/** 布局结果：id → 绝对矩形。重名 id 会抛（重名意味着配置抄错了）。 */
export type UiLayoutResult = ReadonlyMap<string, Rect>;

/**
 * 布局选项。
 *
 * ★ `intrinsic` 是一个**注入口**，不是布局层的一部分：它回答"这个叶子的自然尺寸是多少"，
 *   而"自然尺寸"的定义要看控件（文本量算要字体、九宫格图片要看帧尺寸）。
 *   布局层只负责在**内区尺寸已经算好**的那一刻问一次，然后把答案当作 `contentSize`。
 *   这样布局保持无字体、无皮肤、无 GPU 依赖（可在 Node 里用假量算函数验接线），
 *   而真实量算留在 `intrinsic.ts`（见那里文件头的 ★★）。
 */
export interface LayoutOptions {
  readonly intrinsic?: (node: UiNode, innerW: number, innerH: number) => { readonly w: number; readonly h: number } | null;
}

/**
 * 摆一遍。`bounds` 是根节点的绝对矩形（通常是 `viewport.safeRect`）。
 *
 * 复杂度 O(节点数)：测量与摆放各自只走一次树。UI 树通常几百个节点，
 * 每帧跑一遍 < 0.05ms，所以**不做脏标记**也是安全的 —— 但控件层仍然会缓存
 * 文本排版（那一步是 O(字数)，不是 O(节点)）。
 */
export function layoutTree(root: UiNode, bounds: Rect, opts: LayoutOptions = {}): UiLayoutResult {
  root.rect = bounds;
  measure(root, bounds.width, bounds.height, opts);
  arrange(root, bounds, 1, 0, 0);
  const out = new Map<string, Rect>();
  for (const n of root.walk()) {
    if (n === root) continue;
    // 不可见节点不进结果：调用方拿到一个 Rect.zero 会当成"在左上角有一块 0×0 的东西"，
    // 而那比"查不到"更难查。
    if (!n.visible) continue;
    if (out.has(n.id)) {
      throw new Error(`UI 节点 id 重复：${n.id}（同一棵树里 id 必须唯一，否则命中测试会打到错的那个）`);
    }
    out.set(n.id, n.rect);
  }
  return out;
}

/** 测量：自顶向下给约束，自底向上回尺寸。结果写在 `node.measured`。 */
function measure(node: UiNode, availW: number, availH: number, opts: LayoutOptions): void {
  if (!node.visible) {
    node.measured = { w: 0, h: 0 };
    return;
  }
  const fixedW = node.size.w;
  const fixedH = node.size.h;
  const pctW = node.percent.w;
  const pctH = node.percent.h;

  // 有确定尺寸的子节点不需要再问父要空间，但**仍要把子节点测一遍**（它们的百分比要成立）。
  const innerW = fixedW ?? (pctW !== undefined ? availW * pctW : availW);
  const innerH = fixedH ?? (pctH !== undefined ? availH * pctH : availH);
  const padW = Math.max(0, innerW - node.padding.left - node.padding.right);
  const padH = Math.max(0, innerH - node.padding.top - node.padding.bottom);

  // ★ 自然尺寸（文本量算）在这里落地：**写回 `contentSize`**，而不是另开一条返回值。
  //   原因有两个：① 下游公式（`Math.max(contentW, node.contentSize.w)`）已经就在这儿，
  //   多一条并行路径等于让"文本撑开"和"内容撑开"两套规则打架；
  //   ② `contentSize` 是诊断能看见的东西（编辑器属性面板读它），
  //   如果量算结果只在函数栈里，排查"这个标签为什么是 0 宽"就只能断点。
  //   写回的前提是注入口能表态（文本控件 + 有字 + 字体存在）；不能表态时**保持原值**，
  //   于是配置里手写的 `contentSize` 仍然有效（向后兼容）。
  const nat = opts.intrinsic?.(node, padW, padH) ?? null;
  if (nat !== null) node.contentSize = { w: nat.w, h: nat.h };

  let contentW = 0;
  let contentH = 0;

  if (node.kind === UiLayoutKind.Row || node.kind === UiLayoutKind.Column) {
    // 流式：主轴先测"不 grow"的子节点，剩余空间等摆放时按 grow 分。
    // 这里只关心**内容尺寸**，grow 的份额在 arrange 里算（那里才知道真实剩余）。
    let mainTotal = 0;
    let crossMax = 0;
    let count = 0;
    for (const c of node.children) {
      if (!c.visible) continue;
      measure(c, padW, padH, opts);
      count++;
      const w = c.measured.w + c.margin.left + c.margin.right;
      const h = c.measured.h + c.margin.top + c.margin.bottom;
      if (node.kind === UiLayoutKind.Row) {
        mainTotal += w;
        crossMax = Math.max(crossMax, h);
      } else {
        mainTotal += h;
        crossMax = Math.max(crossMax, w);
      }
    }
    if (count > 0) mainTotal += node.gap * (count - 1);
    if (node.kind === UiLayoutKind.Row) {
      contentW = mainTotal;
      contentH = crossMax;
    } else {
      contentW = crossMax;
      contentH = mainTotal;
    }
  } else if (node.kind === UiLayoutKind.Grid) {
    const cols = node.columns;
    let cw = node.cell?.w ?? 0;
    let ch = node.cell?.h ?? 0;
    let maxCellW = 0;
    let maxCellH = 0;
    let n = 0;
    for (const c of node.children) {
      if (!c.visible) continue;
      // 格子尺寸未知时（没有 cell）用子节点的自然尺寸当格尺寸 —— 但那样每格可能不同，
      // 所以取所有可见子的最大值，保证网格对齐（背包格必须等大）。
      measure(c, padW, padH, opts);
      maxCellW = Math.max(maxCellW, c.measured.w + c.margin.left + c.margin.right);
      maxCellH = Math.max(maxCellH, c.measured.h + c.margin.top + c.margin.bottom);
      n++;
    }
    if (cw === 0) cw = maxCellW;
    if (ch === 0) ch = maxCellH;
    const rows = Math.ceil(n / cols);
    contentW = rows === 0 ? 0 : cols * cw + node.gap * (cols - 1);
    contentH = rows === 0 ? 0 : rows * ch + node.gap * (rows - 1);
    // 把最终格尺寸写回，arrange 直接用（避免两处各算一遍导致对不上）
    node.cell = { w: cw, h: ch };
  } else {
    // free：**内容尺寸为 0，不参与父的尺寸推导**。
    // ★ 为什么不做包围盒：free 的子节点按锚点定位，而"贴底/居中的子节点"
    //   的坐标取决于父容器的**最终**尺寸 —— 拿未定的父尺寸去反推内容尺寸，
    //   会得到一个等于 availH 的假尺寸（父多大它就报多大），进而把更上层撑开。
    //   所以 free 容器必须显式给 size 或 percent；根节点的 size 恒等于 bounds。
    //   子节点仍要测一遍：它们的 percent 与自身尺寸要成立。
    for (const c of node.children) {
      if (!c.visible) continue;
      measure(c, padW, padH, opts);
    }
    contentW = 0;
    contentH = 0;
  }

  const w = fixedW ?? (pctW !== undefined ? availW * pctW : Math.max(contentW, node.contentSize.w));
  const h = fixedH ?? (pctH !== undefined ? availH * pctH : Math.max(contentH, node.contentSize.h));
  node.measured = { w: clampSize(w), h: clampSize(h) };
}

/**
 * 尺寸夹取。负数/NaN 一律夹成 0 并**不静默**——NaN 尺寸的症状是
 * "整个子树消失"，而根因往往是一个除零的百分比。
 */
function clampSize(v: number): number {
  if (!Number.isFinite(v) || v < 0) return 0;
  return v;
}

/**
 * 不透明度夹到 0..1。
 *
 * ★ NaN 退回 1（"当作没有动画"）而不是 0：非有限值在这里只是**防御**，
 *   真正的拦截在写入侧（`applyUiTween` 对非有限值拒绝写入）。若这里退回 0，
 *   一次写坏就会让**整棵子树**消失 —— 那是全项目最难查的症状之一。
 */
function clampOpacity(v: number): number {
  if (!Number.isFinite(v)) return 1;
  return v < 0 ? 0 : v > 1 ? 1 : v;
}

/** 缩放夹到 >= 0（负缩放是镜像，UI 过渡不需要，且会让命中测试的矩形反向）。 */
function clampScale(v: number): number {
  if (!Number.isFinite(v)) return 1;
  return v < 0 ? 0 : v;
}

/** 锚点定位：父内区 + 锚点比例 − 自身枢轴 + 偏移 + margin。 */
function anchoredPos(node: UiNode, parentInner: Rect): { x: number; y: number } {
  const w = node.measured.w;
  const h = node.measured.h;
  const x =
    parentInner.x +
    node.margin.left +
    node.anchor.x * parentInner.width -
    node.pivot.x * w +
    node.offset.x;
  const y =
    parentInner.y +
    node.margin.top +
    node.anchor.y * parentInner.height -
    node.pivot.y * h +
    node.offset.y;
  return { x, y };
}

/** 摆放：把绝对矩形写进子节点。
 *
 * ★★ 缩放是**沿父链组合的仿射变换** `p → s·p + o`，不是"每个节点各自绕自己枢轴缩一下"。
 *
 *   为什么必须组合：一组 UI 弹出时，父容器 2 倍、里面的按钮应当既变大**也外移**。
 *   如果每个节点只缩自己那一块，子节点会保持原尺寸（因为它的 `measured` 没变），
 *   于是"盒子变大了但里面的东西没变" —— 看起来像布局错位，不像动画。
 *
 *   组合公式（两次缩放关于不同点的复合，仍是缩放）：
 *     子变换：`p → sc·p + P·(1−sc)`（P = 本节点枢轴，未缩放绝对坐标）
 *     再套父变换：`p → s'·p + o'`  ⇒  `s = s'·sc`，`o = s'·o_c + o'`
 *   于是只需要往下传 `(s, o)` 两个量。
 *
 * ★ 布局计算仍在**未缩放空间**里做（`inner` 用的是入参 `slot` 而不是缩放后的矩形）：
 *   否则子节点会先按父的缩放算一遍位置、再被继承的缩放乘第二遍。
 */
function arrange(node: UiNode, slot: Rect, sIn: number, oxIn: number, oyIn: number): void {
  if (!node.visible) return;
  let s = sIn;
  let ox = oxIn;
  let oy = oyIn;
  if (node.scale !== 1) {
    // 本节点枢轴在**未缩放**绝对坐标里的位置
    const px = slot.x + node.pivot.x * slot.width;
    const py = slot.y + node.pivot.y * slot.height;
    const offX = px * (1 - node.scale);
    const offY = py * (1 - node.scale);
    s = sIn * node.scale;
    ox = sIn * offX + oxIn;
    oy = sIn * offY + oyIn;
  }
  node.rect = s === 1 ? slot : new Rect(s * slot.x + ox, s * slot.y + oy, slot.width * s, slot.height * s);
  // ★ 内区用入参 `slot`（未缩放）：布局数学只在未缩放空间里成立一次
  const inner = node.inner(slot);

  if (node.kind === UiLayoutKind.Free) {
    for (const c of node.children) {
      if (!c.visible) continue;
      const p = anchoredPos(c, inner);
      arrange(c, new Rect(p.x, p.y, c.measured.w, c.measured.h), s, ox, oy);
    }
    return;
  }

  if (node.kind === UiLayoutKind.Row || node.kind === UiLayoutKind.Column) {
    const isRow = node.kind === UiLayoutKind.Row;
    const mainLen = isRow ? inner.width : inner.height;
    const visibles = node.children.filter((c) => c.visible);
    const gaps = node.gap * Math.max(0, visibles.length - 1);
    let used = 0;
    let growTotal = 0;
    for (const c of visibles) {
      const m = isRow
        ? c.measured.w + c.margin.left + c.margin.right
        : c.measured.h + c.margin.top + c.margin.bottom;
      used += m;
      growTotal += Math.max(0, c.grow);
    }
    const remain = Math.max(0, mainLen - used - gaps);
    let cursor = 0;
    for (const c of visibles) {
      const baseMain = isRow
        ? c.measured.w + c.margin.left + c.margin.right
        : c.measured.h + c.margin.top + c.margin.bottom;
      // grow 按比例分剩余空间；growTotal=0 时谁都不加，靠锚点对齐。
      const extra = growTotal > 0 ? (remain * Math.max(0, c.grow)) / growTotal : 0;
      const mainSize = baseMain + extra;
      const crossSize = isRow ? c.measured.h + c.margin.top + c.margin.bottom : c.measured.w + c.margin.left + c.margin.right;
      const x = isRow ? inner.x + cursor + c.margin.left : inner.x + c.margin.left;
      const y = isRow ? inner.y + c.margin.top : inner.y + cursor + c.margin.top;
      const w = isRow ? Math.max(0, mainSize - c.margin.left - c.margin.right) : Math.max(0, crossSize - c.margin.left - c.margin.right);
      const h = isRow ? Math.max(0, crossSize - c.margin.top - c.margin.bottom) : Math.max(0, mainSize - c.margin.top - c.margin.bottom);
      arrange(c, new Rect(x, y, w, h), s, ox, oy);
      cursor += mainSize + node.gap;
    }
    return;
  }

  // grid
  const cols = Math.max(1, node.columns);
  const cw = node.cell?.w ?? 0;
  const ch = node.cell?.h ?? 0;
  let i = 0;
  for (const c of node.children) {
    if (!c.visible) continue;
    const col = i % cols;
    const row = Math.floor(i / cols);
    const x = inner.x + col * (cw + node.gap) + c.margin.left;
    const y = inner.y + row * (ch + node.gap) + c.margin.top;
    arrange(c, new Rect(x, y, Math.max(0, cw - c.margin.left - c.margin.right), Math.max(0, ch - c.margin.top - c.margin.bottom)), s, ox, oy);
    i++;
  }
}

/**
 * 命中测试：这个点落在哪个最上层（后画）的节点上。
 *
 * ★ 倒序遍历 = 后画的先命中。UI 的"上层优先"不是靠 z 值，而是靠**绘制顺序**——
 *   用 z 值会让"加了一个子节点却忘了给 z"变成静默的点击穿透。
 *
 * ★ `opaque` 的语义必须在这里实现，不能只靠 `interactive`：
 *   模态遮罩是"看得见、挡住下面、自己不处理点击"的一层。只认 interactive 的话，
 *   点了遮罩会打到底下的按钮 —— 那是模态对话框最典型的失效方式。
 */
export function hitTest(root: UiNode, x: number, y: number): UiNode | null {
  const stack: UiNode[] = [];
  for (const n of root.walk()) if (n.visible) stack.push(n);
  for (let i = stack.length - 1; i >= 0; i--) {
    const n = stack[i]!;
    const r = n.rect;
    if (x < r.x || x > r.xMax || y < r.y || y > r.yMax) continue;
    if (n.interactive) return n;
    if (n.opaque) return null;
  }
  return null;
}

/** 命中链：从命中的节点一路向上到根（冒泡用）。 */
export function hitChain(node: UiNode | null): UiNode[] {
  const chain: UiNode[] = [];
  let cur = node;
  while (cur !== null) {
    chain.push(cur);
    cur = cur.parent;
  }
  return chain;
}
