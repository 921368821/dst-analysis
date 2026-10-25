/**
 * L4 · UI 过渡：把补间的采样值写进 `UiNode`
 *
 * 这一层是 `tween.player` 与 `ui` 两个模块之间的**唯一**接缝，职责只有两条：
 *   ① 把属性名翻译成 `UiNode` 上的字段；
 *   ② 按属性各自的**值域**收口（`opacity` 只能 0..1、`scale` 不能为负）。
 *
 * ★★ 为什么这一层必须单独存在（而不是让补间直接写节点）：
 *   值域是**语义**，不是通用规则。补间只知道"0 → 100 之间某个数"；
 *   UI 才知道"1.4 倍缩放是放大、-0.2 不透明度是没有意义"。
 *   把钳位写进补间层，第二类目标（相机缩放允许任意正数、音量有别的范围）
 *   就得跟着改补间层 —— 那正是"通用层被具体需求污染"的起点。
 *
 * ★ 为什么未知属性**不抛异常、只记账**：
 *   过渡的目标是界面节点，而界面会被关掉。一条指向已销毁节点的轨道
 *   （或前端写错的属性名）不该让整帧 UI 崩掉 —— 但也绝不该静默：
 *   调用方从返回值能看到 `unknown` 的条数，宿主可以把它打进诊断面板。
 *   "抛异常"与"完全不管"之间，需要一个可观测的中间态。
 */

import type { TrackSample } from "../tween/tween-player.ts";
import type { UiNode } from "./layout.ts";

/** UI 侧认识的补间属性名（补间层只当成不透明字符串）。 */
export const UI_TWEEN_PROP = {
  Opacity: "opacity",
  Scale: "scale",
  OffsetX: "offsetX",
  OffsetY: "offsetY",
} as const;
export type UiTweenProp = (typeof UI_TWEEN_PROP)[keyof typeof UI_TWEEN_PROP];

const KNOWN: ReadonlySet<string> = new Set(Object.values(UI_TWEEN_PROP));

/**
 * 写一个属性。返回 `true` = 真的写进去了。
 *
 * ★ 非有限值**不写**（返回 false）：NaN 一旦落进 `opacity`，那一整棵子树会消失，
 *   而在几十个节点里找"谁被写坏了"要花掉一整天。挡在写入点是唯一便宜的位置。
 * ★ `offset` 是整体对象（`UiPoint` 的字段是 readonly），所以这里**换一个新对象**，
 *   而不是改 `node.offset.x` —— 后者在 strict 下编译不过，也说明这个类型本来就不该被就地改。
 */
export function applyUiTween(node: UiNode, prop: string, value: number): boolean {
  if (!Number.isFinite(value)) return false;
  switch (prop) {
    case UI_TWEEN_PROP.Opacity:
      node.opacity = value < 0 ? 0 : value > 1 ? 1 : value;
      return true;
    case UI_TWEEN_PROP.Scale:
      node.scale = value < 0 ? 0 : value;
      return true;
    case UI_TWEEN_PROP.OffsetX:
      node.offset = { x: value, y: node.offset.y };
      return true;
    case UI_TWEEN_PROP.OffsetY:
      node.offset = { x: node.offset.x, y: value };
      return true;
    default:
      return false;
  }
}

/** 属性名是否是 UI 认识的（配置期自检用，避免把拼错的属性名留到运行时）。 */
export function isUiTweenProp(prop: string): boolean {
  return KNOWN.has(prop);
}

export interface UiTransitionResult {
  /** 真的写进节点的条数。 */
  readonly applied: number;
  /** 本步值**变了**的条数（宿主据此决定要不要 `invalidate()`）。 */
  readonly changed: number;
  /** 属性名不认识（拼错 / 未来属性）的条数。 */
  readonly unknownProp: number;
  /** 目标节点找不到（界面已关闭 / id 写错）的条数。 */
  readonly missingNode: number;
}

/**
 * 把一批采样写进 UI 树。
 *
 * `index` 是"id → 节点"的查询函数（UI 模块里就是 `root.find(id)`；
 * 判据里可以给一个 `Map`，不必造整棵树 —— 这是它能被 Node 判据逐条覆盖的原因）。
 *
 * ★ `changed` 只统计"值真的变了"的：静止的过渡每帧都写一遍同样的值，
 *   若据此标脏，整棵 UI 会每帧重排 + 文本缓存全废（症状是"UI 一直卡但看不出在动")。
 */
export function applyUiSamples(
  samples: readonly TrackSample[],
  index: (id: string) => UiNode | undefined,
): UiTransitionResult {
  let applied = 0;
  let changed = 0;
  let unknownProp = 0;
  let missingNode = 0;
  for (const s of samples) {
    const node = index(s.targetId);
    if (node === undefined) {
      missingNode++;
      continue;
    }
    if (!applyUiTween(node, s.prop, s.value)) {
      unknownProp++;
      continue;
    }
    applied++;
    if (s.changed) changed++;
  }
  return { applied, changed, unknownProp, missingNode };
}
