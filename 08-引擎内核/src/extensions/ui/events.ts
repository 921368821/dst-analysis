/**
 * L4 · UI 事件（指针 → 命中 → 冒泡）
 *
 * 这一层不依赖任何输入后端：指针状态由宿主推进来（`{x, y, down}`，设计坐标）。
 * 于是"点一下按钮会不会触发"可以在 Node 里用三行断言证明，
 * 而不是"开浏览器点一下看看"。
 *
 * ★★ 三条必须实现的语义，缺任何一条都会让 UI "看起来能用但用起来别扭"：
 *
 *   ① **捕获（capture）**：按下的那一刻锁定目标，直到抬起。
 *      不锁定的话，"在按钮上按下、拖到按钮外、松手"会去找**松手位置**的节点 ——
 *      于是点击落到了别的按钮上，或者什么都没发生。拖拽类控件（滑条/背包拖物）
 *      更是必须靠它：拖到哪儿都算同一个控件在拖。
 *
 *   ② **click 的判定是「同目标 + 位移小于阈值」**。
 *      只判同目标，会把"按住拖动 200 像素再松手"也算成点击；
 *      只判同位置，会让手抖 2 像素的人点不动按钮。两者都要。
 *
 *   ③ **冒泡到根，且可被 `stopPropagation` 截断**。
 *      没有冒泡，每个控件都要自己写"如果我不处理就交给父级"，那是必然的漏项。
 *
 * ★ 悬停（enter/leave）按**逐帧比较**产生，不按"每移动一次"产生：
 *   指针停住不动但屏幕滚动（UI 内容变化）时，悬停目标也可能变，逐帧比较才不漏。
 */

import { hitChain, hitTest, type UiNode } from "./layout.ts";

export type UiEventType =
  | "pointerdown"
  | "pointerup"
  | "click"
  | "pointerenter"
  | "pointerleave"
  | "pointermove";

export interface UiPointer {
  /** 设计坐标（不是屏幕像素）。宿主用 `viewport.screenToDesign()` 换。 */
  readonly x: number;
  readonly y: number;
  readonly down: boolean;
}

export class UiEvent {
  readonly type: UiEventType;
  /** 事件产生的原始目标（不随冒泡变化）。 */
  readonly target: UiNode;
  /** 当前冒泡到的节点（投递时才有意义）。 */
  currentTarget: UiNode;
  readonly x: number;
  readonly y: number;
  private stopped = false;

  constructor(type: UiEventType, target: UiNode, x: number, y: number) {
    this.type = type;
    this.target = target;
    this.currentTarget = target;
    this.x = x;
    this.y = y;
  }

  stopPropagation(): void {
    this.stopped = true;
  }

  get propagationStopped(): boolean {
    return this.stopped;
  }
}

export type UiEventSink = (ev: UiEvent) => void;

export interface UiInputRouterOptions {
  /** 按下到抬起的位移超过它就不算 click（设计 px）。默认 8。 */
  readonly dragThreshold?: number;
}

export class UiInputRouter {
  private readonly root: UiNode;
  private readonly dragThreshold: number;
  private lastDown = false;
  private lastX = Number.NaN;
  private lastY = Number.NaN;
  private downTarget: UiNode | null = null;
  private downX = 0;
  private downY = 0;
  private hover: UiNode | null = null;
  /** 最近一次命中的节点（诊断与测试用）。 */
  hit: UiNode | null = null;

  constructor(root: UiNode, opts: UiInputRouterOptions = {}) {
    this.root = root;
    this.dragThreshold = opts.dragThreshold ?? 8;
  }

  get hovered(): UiNode | null {
    return this.hover;
  }

  /** 正在被捕获的目标（按下未抬起）。 */
  get captured(): UiNode | null {
    return this.downTarget;
  }

  /**
   * 推进一帧。返回本帧产生的事件（已冒泡投递到 `sink`，若提供）。
   * ★ 返回值是给判据用的：断言"这一刻产生了 click"不需要监听器。
   */
  update(p: UiPointer, sink?: UiEventSink): UiEvent[] {
    const events: UiEvent[] = [];
    const hit = hitTest(this.root, p.x, p.y);
    this.hit = hit;

    const push = (type: UiEventType, target: UiNode): void => {
      events.push(new UiEvent(type, target, p.x, p.y));
    };

    // ---- 悬停变化（逐帧比较，见文件头）
    if (hit !== this.hover) {
      const prev = this.hover;
      this.hover = hit;
      if (prev !== null) push("pointerleave", prev);
      if (hit !== null) push("pointerenter", hit);
    }

    // ---- 移动
    const moved = !(p.x === this.lastX && p.y === this.lastY);
    if (moved && hit !== null) push("pointermove", hit);

    // ---- 按下（边沿）
    if (p.down && !this.lastDown) {
      this.downTarget = hit;
      this.downX = p.x;
      this.downY = p.y;
      if (hit !== null) push("pointerdown", hit);
    }

    // ---- 抬起（边沿）：投给**捕获目标**，不是当前命中
    if (!p.down && this.lastDown) {
      const target = this.downTarget;
      if (target !== null) {
        push("pointerup", target);
        const chain = hit === null ? [] : hitChain(hit);
        const sameTarget = chain.includes(target);
        const dx = p.x - this.downX;
        const dy = p.y - this.downY;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (sameTarget && dist <= this.dragThreshold) push("click", target);
      }
      this.downTarget = null;
    }

    this.lastDown = p.down;
    this.lastX = p.x;
    this.lastY = p.y;

    if (sink !== undefined) {
      for (const ev of events) bubble(ev, sink);
    }
    return events;
  }

  /** 强制释放捕获（例如页面失焦）。不发事件 —— 失焦不是用户的点击意图。 */
  release(): void {
    this.downTarget = null;
    this.lastDown = false;
  }
}

/** 从目标沿父链向上投递，遇到 `stopPropagation` 停。 */
export function bubble(ev: UiEvent, sink: UiEventSink): void {
  let cur: UiNode | null = ev.target;
  while (cur !== null) {
    if (ev.propagationStopped) return;
    ev.currentTarget = cur;
    sink(ev);
    cur = cur.parent;
  }
}
