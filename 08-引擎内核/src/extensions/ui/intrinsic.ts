/**
 * L4 · 「标签自撑开」：把文本量出来的尺寸喂回布局（ADR-0012 的第一个消费者）
 *
 * 在这之前，`UiNode.contentSize` 的注释写着"由控件层写入"，而**没有任何人写它**。
 * 症状很具体：一个 `widget: label` 而不给 `size` 的节点量出来是 0×0 ——
 * 文本照画（画的宽度从 `rect` 来，所以它其实溢出到了盒子外），但
 * 父容器的 row/column/grid 完全看不见它占多少位置，于是所有后续元素挤在一起。
 * 这就是"半条链"：能画，但布局不认。
 *
 * ★★ 为什么量算在**布局里**、而不是在画之前单独走一遍：
 *   换行宽度的唯一来源是**盒子的宽**，而盒子的宽是布局算出来的。
 *   在布局**之外**再量一遍，就得自己重新推一次"这个节点的可用宽是多少"——
 *   那是把 `measure()` 的约束传播抄第二份，两处迟早不一致，
 *   而症状是"文本有时会溢出边框一点点"（只在特定嵌套下出现）。
 *   所以布局层开一个**注入口**（`LayoutOptions.intrinsic`），在它已经算好内区尺寸的
 *   那一刻问一次"这个叶子的自然尺寸是多少"，量算本身留在这里（不污染布局的纯度）。
 *
 * ★★ 为什么换行宽在"没有显式宽"时是 0（不换行）而不是父容器的可用宽：
 *   那会把"收缩到内容"变成"填满一行"—— 一个没给宽度的标签会撑满整行，
 *   于是同一段文字在长面板里换行、在短面板里不换行，而作者什么都没写错。
 *   CSS 里这是 `width: auto` 与 `width: 100%` 的区别，默认必须是前者。
 *
 * ★★ 自撑开的节点**在按测量宽绘制时必然不换行**（结构性保证，不是巧合）：
 *   测量宽 = 单行宽 + 两侧内缩 + 内边距，而绘制时的换行宽 = 测量宽 − 内缩 − 内边距
 *   = 单行宽。刻意多出那一点余量，就是为了让"相等"不依赖浮点恰好相等。
 */

import { Rect } from "../../foundation/math/index.ts";
import type { FontRegistry } from "./font.ts";
import type { UiStateStore } from "./state.ts";
import type { TextStyle } from "./text-layout.ts";
import { UiWidget, type UiNode, type UiWidgetValue } from "./layout.ts";

/**
 * 按钮文字的两侧内缩（设计像素）。
 *
 * ★ 必须与绘制用**同一个常量**。各写一个 `4` 的话，改动只会落到其中一处，
 *   症状是"按钮文字贴右边框一点点"—— 而它只在自撑开的按钮上出现。
 */
export const BUTTON_TEXT_INSET = 4;

/** 某个控件类型是否有文本、以及文字两侧要内缩多少。`-1` = 不是文本控件。 */
export function textInsetOf(widget: UiWidgetValue): number {
  if (widget === UiWidget.Button) return BUTTON_TEXT_INSET;
  if (widget === UiWidget.Label) return 0;
  return -1;
}

/**
 * 默认字体：注册表里按 id 排序的第一个。
 * ★ 排序后再取是刻意的：注册顺序会影响画面（换个加载顺序换个字形），
 *   那种不确定性在"两台机器显示不一样"时几乎追不回来。
 */
export function defaultFontId(fonts: FontRegistry): string {
  const ids = fonts.ids();
  return ids.length === 0 ? "" : (ids[0] as string);
}

/**
 * 某个节点的文本样式（**绘制与量算共用**）。
 *
 * `boxWidth` 是这一层算出来的可用宽（标签 = 盒子宽，按钮 = 盒子宽 − 2×内缩）。
 *
 * ★ 显式 `style.maxWidth` **优先于** `boxWidth`：作者写了换行宽就是他要的换行宽，
 *   按盒子宽无条件覆盖会让"我这个标题固定在 120px 换行"变成做不到的事。
 * ★ `null` 表示"给 0 宽"（不换行）：`layoutText` 里 `maxWidth <= 0` 就是自由排版。
 */
export function textStyleFor(node: UiNode, boxWidth: number): TextStyle {
  const p = node.props;
  const explicit = p.style?.maxWidth;
  const maxWidth = explicit !== undefined && explicit > 0 ? explicit : boxWidth;
  return {
    ...p.style,
    maxWidth,
    align: p.style?.align ?? (node.widget === UiWidget.Button ? "center" : "left"),
    color: p.textColor ?? p.style?.color,
  };
}

/**
 * 文字实际绘制的盒子：按钮两侧各内缩 `BUTTON_TEXT_INSET`，其余控件就是原矩形。
 * ★ 抽出来是为了让"量算时的宽"与"绘制时的宽"来自同一个函数（上面那段 ★★）。
 */
export function textBoxOf(node: UiNode, rect: Rect): Rect {
  const inset = textInsetOf(node.widget);
  if (inset <= 0) return rect;
  const w = Math.max(0, rect.width - inset * 2);
  return new Rect(rect.x + inset, rect.y, w, rect.height);
}

/** 布局层注入口的签名（`LayoutOptions.intrinsic`）。 */
export type IntrinsicMeasure = (
  node: UiNode,
  innerW: number,
  /** 内区高。当前没有消费者（高度由文本行数决定，与可用高无关）。 */
  innerH: number,
) => { readonly w: number; readonly h: number } | null;

/** 这个节点是否给了确定的宽（`size.w` 或 `percent.w`）。 */
function hasExplicitWidth(node: UiNode): boolean {
  return node.size.w !== undefined || node.percent.w !== undefined;
}

/**
 * 造一个量算函数：布局每遇到一个叶子就问它一次"这个叶子的自然尺寸"。
 *
 * 返回 `null` 的意思是**"这一层不表态"**，布局会退回原来的行为（用 `contentSize`）。
 * 三种情况返回 null，各自的理由都不同：
 *   · 不是文本控件 —— 自然尺寸的定义在别处（九宫格图片、进度条），不该由这里给；
 *   · 文本为空 —— 空文本的"自然宽度"是 0 而不是"整个盒子"，由布局按 0 处理即可；
 *   · 字体不存在 —— 量不出来就不要**假装**量出了 0（0 宽会让标签静默塌掉）。
 */
export function createIntrinsicMeasure(fonts: FontRegistry, store: UiStateStore): IntrinsicMeasure {
  return (node, innerW) => {
    const inset = textInsetOf(node.widget);
    if (inset < 0) return null;
    const text = node.props.text ?? "";
    if (text === "") return null;

    const pad = node.padding;
    // `innerW` 是**内区**宽（已扣 padding）；绘制时看到的盒子宽要把它加回来。
    const boxW = Math.max(0, innerW + pad.left + pad.right);
    const explicit = hasExplicitWidth(node);
    // 没有显式宽 ⇒ 不换行（见文件头 ★★）；有显式宽 ⇒ 在盒子宽内换行。
    const wrap = explicit ? Math.max(0, boxW - inset * 2) : 0;

    const fontId = node.props.fontId ?? defaultFontId(fonts);
    const layout = store.text(node.uid, fonts, fontId, text, textStyleFor(node, wrap));
    if (layout === null) return null;

    if (explicit) {
      // 宽由布局按 size/percent 决定；这里只补高度（要换行时高度才是新的信息）。
      return { w: boxW, h: layout.height + pad.top + pad.bottom };
    }
    return {
      w: layout.width + inset * 2 + pad.left + pad.right,
      h: layout.height + pad.top + pad.bottom,
    };
  };
}
