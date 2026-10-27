/**
 * L4 · UI 的「跨帧状态表」（ADR-0012 的落点）
 *
 * UI 有两类必须跨帧记住的东西，而它们的**归属不同**：
 *
 *   · **派生态**（可直接重算）：一段文本排出来是几行、多宽、缺哪些字。
 *     它只由 (字体, 文本, 样式, 换行宽) 决定 ⇒ 可以缓存、可以随时丢弃重算。
 *   · **权威态**（不可重算）：滚动容器的偏移、正在跑的补间进度。
 *     它由**用户操作**或**时间**决定 ⇒ 丢了就是丢了（回到顶部、动画从头播）。
 *
 * ★★ 为什么两张表都放在这里，却不共用一条失效规则：
 *   把两者混成一个 `clear()` 是最容易写的，但它错在两个方向上：
 *     - 只清派生（该清的没清全）⇒ 换了字体之后滚动位置莫名回顶；
 *     - 全清（清过头）⇒ 换字体时用户正滚到一半的列表跳回顶部。
 *   所以这里有两个入口：`invalidateDerived()`（只丢派生）与 `reset()`（全丢）。
 *   **谁调用哪个，由"这件事会不会让用户的操作失去意义"决定，而不是由"哪个更方便"决定。**
 *
 * ★★ 为什么不把状态位挂在 `UiNode` 上：
 *   ① `UiNode` 是**可序列化的配置**（编辑器里要能存、能复制、能 diff）。
 *      把 `scrollY` 写进节点，存档里就会出现"上次滚到哪"—— 换分辨率/换界面之后
 *      那个数字毫无意义，而它会被当成配置一路带到下一个版本；
 *   ② 派生缓存挂在节点上会让"同一份配置实例化两次"共享缓存键，
 *      而键里含 `uid`（每实例唯一）正是为了让它们**不**共享；
 *   ③ 更要紧的是第 ③ 条：节点是数据的形状，而"记住多少"是**运行时的策略**
 *      （上限、淘汰、失效时机）。两者混在一处，改策略就得改数据结构。
 *
 * ★★ 键为什么是 `uid` 而不是 `id`：
 *   `id` 是配置字段，可以重名、可以改。改了 `id` 之后状态跟着走会串到**别人**身上
 *   （"改了个 id 结果列表滚到了另一块"）；`uid` 是构造时分配的单调整数，从不复用，
 *   所以"旧节点的状态绝不会被新节点读到"是**结构上**成立的，不靠清理纪律。
 */

import type { TextStyle, TextLayout } from "./text-layout.ts";
import { layoutText } from "./text-layout.ts";
import type { FontRegistry } from "./font.ts";

/** 一次文本排版的缓存条目。`key` 之外的字段不参与判定。 */
interface LayoutEntry {
  readonly key: string;
  readonly layout: TextLayout;
}

export interface UiStateStats {
  /** 失效代次。每次 `reset()`/`invalidateDerived()` 都 +1，用于诊断"到底谁清了"。 */
  readonly epoch: number;
  readonly layouts: number;
  readonly scrolls: number;
  readonly hits: number;
  readonly misses: number;
  readonly evictions: number;
}

/**
 * 排版缓存的上限。
 * ★ 定值而不是按比例：UI 文本几乎到不了这个量级；真到了说明有人在动态拼大量字符串，
 *   那更该质疑那件事而不是加大上限。超限时**整表清空**（而不是 LRU）——
 *   LRU 需要一个双向链表与每次读写的搬运，而收益只在"刚好在边界附近震荡"时出现。
 */
const MAX_LAYOUT_ENTRIES = 1024;

export class UiStateStore {
  private readonly layouts = new Map<number, LayoutEntry>();
  private readonly scrolls = new Map<number, number>();
  private version = 1;
  hits = 0;
  misses = 0;
  evictions = 0;

  /** 当前失效代次。诊断用：两次报错之间没变过，说明不是缓存导致的。 */
  get epoch(): number {
    return this.version;
  }

  get stats(): UiStateStats {
    return {
      epoch: this.version,
      layouts: this.layouts.size,
      scrolls: this.scrolls.size,
      hits: this.hits,
      misses: this.misses,
      evictions: this.evictions,
    };
  }

  /**
   * 取一段文本的排版结果（派生缓存）。
   *
   * ★ 返回 `null` 表示**字体不存在**，而不是"空排版"：
   *   空排版会让调用方以为"这段文本就是 0 宽"，于是标签静默塌成 0×0；
   *   返回 null 时调用方必须自己决定是跳过还是回退 —— 那是一个明确的决定。
   *
   * ★ 键里**必须**含字体 id、文本、样式三样（原有的 `cacheKey` 规则）：
   *   只按节点缓存 ⇒ 改了文案没换节点会显示旧文本；
   *   只按文本缓存 ⇒ 两种字号互相污染。
   */
  text(
    uid: number,
    fonts: FontRegistry,
    fontId: string,
    text: string,
    style: TextStyle,
  ): TextLayout | null {
    const font = fonts.get(fontId);
    if (font === undefined) return null;
    const key = layoutCacheKey(fontId, text, style);
    const hit = this.layouts.get(uid);
    if (hit !== undefined && hit.key === key) {
      this.hits++;
      return hit.layout;
    }
    this.misses++;
    const layout = layoutText(font, text, style);
    if (this.layouts.size >= MAX_LAYOUT_ENTRIES) {
      this.evictions += this.layouts.size;
      this.layouts.clear();
    }
    this.layouts.set(uid, { key, layout });
    return layout;
  }

  /** 丢掉一个节点的派生缓存（改了一个节点的文案后想立刻重算时用）。 */
  forget(uid: number): void {
    if (this.layouts.delete(uid)) this.evictions++;
  }

  /**
   * 只丢派生缓存（字体热重载、UI 图集换页）。
   * ★ **不动滚动位置**：换一张字体不该让用户正在看的列表回顶。
   */
  invalidateDerived(): void {
    this.layouts.clear();
    this.version++;
  }

  /**
   * 全丢（换界面、回滚、dispose）。
   * ★ 回滚必须走这里：上一份世界里的滚动位置与文本量算都不该被这一份世界读到。
   *   `epoch` +1 让**任何持有旧代次的东西**（哪怕它绕过了本表）能自查出过期。
   */
  reset(): void {
    this.layouts.clear();
    this.scrolls.clear();
    this.version++;
  }

  /** 滚动偏移（设计像素，正值向下）。未滚过 = 0。 */
  scrollOf(uid: number): number {
    return this.scrolls.get(uid) ?? 0;
  }

  /**
   * 写滚动偏移。
   *
   * ★ 非有限数**拒绝写入**（保持原值）而不是夹成 0：夹成 0 会把"算出来是 NaN"
   *   表现成"滚回顶部"，而那是最容易被当成"用户手滑"的症状。
   * ★ 负值夹到 0；上界由调用方按内容高度算（那一层才知道内容多高）。
   */
  setScroll(uid: number, value: number): void {
    if (!Number.isFinite(value)) return;
    this.scrolls.set(uid, value < 0 ? 0 : value);
  }

  /** 丢一个节点的全部状态（节点被移除时）。 */
  drop(uid: number): void {
    this.layouts.delete(uid);
    this.scrolls.delete(uid);
  }
}

/**
 * 缓存键。
 *
 * ★ 颜色也进键：`layoutText` 把颜色**烘进**每个字形四边形（`TextQuad.r/g/b/a`），
 *   所以"换了文字颜色"是一次真正的重新排版，而不是可以复用的采样。
 *   （这也意味着：只改颜色而文本没变时缓存不命中 —— 但那一次重排是必要的，不是浪费。）
 */
function layoutCacheKey(fontId: string, text: string, style: TextStyle): string {
  const c = style.color;
  return [
    fontId,
    text,
    style.scale ?? 1,
    style.align ?? "left",
    style.lineSpacing ?? 0,
    style.letterSpacing ?? 0,
    style.maxWidth ?? 0,
    style.maxLines ?? 0,
    style.ellipsis ?? "",
    c === undefined ? "-" : `${c.r},${c.g},${c.b},${c.a}`,
  ].join("\u0001");
}
