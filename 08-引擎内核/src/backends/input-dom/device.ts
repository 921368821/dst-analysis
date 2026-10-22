/**
 * L5 · DOM 输入后端
 *
 * 用**最小结构接口**（`DomEventTarget`）而不是 `HTMLElement`：
 * 这样 Node 里可以注入一个记录型 fake 验证"我们监听/派发了什么"，
 * 而浏览器路径完全不变（HTMLElement 结构兼容）。
 *
 * ★ 三条语义（与 `input-null` **逐条一致**，否则两个后端在判据里会分叉）：
 *  ① `pressed` / `released` = "自上次 poll 以来"的边缘；poll 之后清空。
 *  ② 窗口失焦（`blur`）必须**清空所有按下状态** —— 否则切走再切回来，
 *     "W" 会一直被认为按着（角色一直走）。这是一个非常常见的真实 bug。
 *  ③ 指针坐标**归一化到 CSS 像素的相对坐标**（`offsetX/offsetY`），
 *     不用 `clientX` —— 后者包含页面滚动，会让"点在哪"与"看到在哪"不一致。
 *
 * ★ 键用 `event.code`（物理键位，`KeyW`）而不是 `event.key`（字符，`w`/`W`）。
 *   用 `key` 的话，中文输入法激活时 `key` 会变成 `"Process"`，整个控制失效 ——
 *   这是中文环境下最容易漏的一条。
 */

import { ok, type EngineError, type Result } from "../../foundation/result.ts";
import type {
  IInputDevice,
  InputCaps,
  InputSnapshot,
  RawInputEvent,
} from "../../platform/input/device.ts";

/** 只要求我们真正用到的 DOM 能力。 */
export interface DomEventTarget {
  addEventListener(type: string, listener: (ev: DomEventLike) => void, opts?: unknown): void;
  removeEventListener(type: string, listener: (ev: DomEventLike) => void, opts?: unknown): void;
}

export interface DomEventLike {
  readonly code?: string;
  readonly key?: string;
  /** 相对目标的坐标（优先使用）。 */
  readonly offsetX?: number;
  readonly offsetY?: number;
  readonly clientX?: number;
  readonly clientY?: number;
  readonly deltaX?: number;
  readonly deltaY?: number;
  readonly button?: number;
  readonly data?: string;
  /** `textarea`/`input` 聚焦时，键盘事件不该驱动游戏。 */
  readonly target?: { readonly tagName?: string };
  preventDefault?(): void;
}

export interface DomInputOptions {
  /** 键盘监听目标（通常是 window）。 */
  readonly keyboard?: DomEventTarget;
  /** 指针/滚轮监听目标（通常是 canvas）。 */
  readonly pointer?: DomEventTarget;
}

/** 这些按键在用于游戏时应该 preventDefault，避免页面滚动。 */
const PREVENT = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space", "Tab"]);

export class DomInputDevice implements IInputDevice {
  readonly caps: InputCaps = {
    backend: "dom",
    pointer: true,
    touch: true,
    gamepad: false,
    textInput: true,
  };

  private readonly kb: DomEventTarget;
  private readonly ptr: DomEventTarget;
  private readonly down = new Set<string>();
  private readonly pressed = new Set<string>();
  private readonly released = new Set<string>();
  private px = 0;
  private py = 0;
  private pDown = false;
  private pPressed = false;
  private pReleased = false;
  private pButton = 0;
  private wdx = 0;
  private wdy = 0;
  private text = "";
  private readonly subs = new Set<(e: RawInputEvent) => void>();
  private readonly bound: Array<[DomEventTarget, string, (ev: DomEventLike) => void]> = [];
  /** 有输入框聚焦时，键盘不驱动游戏（编辑器输入场景名时不能同时让角色走）。 */
  private textFocus = false;

  constructor(opts: DomInputOptions) {
    if (opts.keyboard === undefined || opts.pointer === undefined) {
      throw new Error("DomInputDevice 需要 keyboard 与 pointer 两个监听目标");
    }
    this.kb = opts.keyboard;
    this.ptr = opts.pointer;
    this.bind();
  }

  private bind(): void {
    const onKeyDown = (ev: DomEventLike): void => {
      if (this.isTyping(ev)) {
        // 输入框里打字：不驱动游戏，但要收集文本
        if (ev.key !== undefined && ev.key.length === 1) {
          this.text += ev.key;
          this.emit({ kind: "text", value: ev.key });
        }
        return;
      }
      const code = ev.code ?? "";
      if (code === "") return;
      if (!this.down.has(code)) {
        this.down.add(code);
        this.pressed.add(code);
      }
      if (PREVENT.has(code)) ev.preventDefault?.();
      this.emit({ kind: "key", code, down: true });
    };

    const onKeyUp = (ev: DomEventLike): void => {
      const code = ev.code ?? "";
      if (code === "" || !this.down.delete(code)) return;
      this.released.add(code);
      this.emit({ kind: "key", code, down: false });
    };

    const onBlur = (): void => {
      // ★ 失焦必须清空：否则"切窗口回来角色一直往前跑"
      this.down.clear();
      this.pressed.clear();
      this.released.clear();
      this.pDown = false;
      this.textFocus = false;
      this.emit({ kind: "blur" });
    };

    const onFocusIn = (ev: DomEventLike): void => {
      this.textFocus = this.isTyping(ev);
    };

    const onPointerDown = (ev: DomEventLike): void => {
      this.updatePointer(ev);
      this.pDown = true;
      this.pPressed = true;
      this.pButton = ev.button ?? 0;
      this.emit({ kind: "pointer", x: this.px, y: this.py, down: true });
      (ev.target as { setPointerCapture?: (id: number) => void } | undefined)?.setPointerCapture?.(0);
    };

    const onPointerUp = (ev: DomEventLike): void => {
      this.updatePointer(ev);
      if (!this.pDown) return;
      this.pDown = false;
      this.pReleased = true;
      this.emit({ kind: "pointer", x: this.px, y: this.py, down: false });
    };

    const onPointerMove = (ev: DomEventLike): void => {
      this.updatePointer(ev);
    };

    const onWheel = (ev: DomEventLike): void => {
      this.wdx += ev.deltaX ?? 0;
      this.wdy += ev.deltaY ?? 0;
      this.emit({ kind: "wheel", x: ev.deltaX ?? 0, y: ev.deltaY ?? 0 });
    };

    this.add(this.kb, "keydown", onKeyDown);
    this.add(this.kb, "keyup", onKeyUp);
    this.add(this.kb, "blur", onBlur);
    this.add(this.kb, "focusin", onFocusIn);
    this.add(this.ptr, "pointerdown", onPointerDown);
    this.add(this.ptr, "pointerup", onPointerUp);
    this.add(this.ptr, "pointermove", onPointerMove);
    this.add(this.ptr, "wheel", onWheel);
  }

  private add(target: DomEventTarget, type: string, fn: (ev: DomEventLike) => void): void {
    target.addEventListener(type, fn, { passive: false });
    this.bound.push([target, type, fn]);
  }

  private isTyping(ev: DomEventLike): boolean {
    const tag = ev.target?.tagName?.toUpperCase();
    return tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || this.textFocus;
  }

  private updatePointer(ev: DomEventLike): void {
    if (ev.offsetX !== undefined) {
      this.px = ev.offsetX;
      this.py = ev.offsetY ?? 0;
    } else {
      this.px = ev.clientX ?? this.px;
      this.py = ev.clientY ?? this.py;
    }
  }

  poll(): InputSnapshot {
    const snap: InputSnapshot = {
      keysDown: new Set(this.down),
      keysPressed: new Set(this.pressed),
      keysReleased: new Set(this.released),
      pointer: {
        x: this.px,
        y: this.py,
        down: this.pDown,
        pressed: this.pPressed,
        released: this.pReleased,
        button: this.pButton,
      },
      wheel: { dx: this.wdx, dy: this.wdy },
      text: this.text,
    };
    this.pressed.clear();
    this.released.clear();
    this.pPressed = false;
    this.pReleased = false;
    this.wdx = 0;
    this.wdy = 0;
    this.text = "";
    return snap;
  }

  subscribe(fn: (e: RawInputEvent) => void): () => void {
    this.subs.add(fn);
    return () => this.subs.delete(fn);
  }

  setFocusTarget(target: unknown): void {
    void target;
  }

  reset(): void {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.pDown = false;
    this.pPressed = false;
    this.pReleased = false;
  }

  destroy(): void {
    for (const [t, type, fn] of this.bound) t.removeEventListener(type, fn);
    this.bound.length = 0;
    this.subs.clear();
    this.reset();
  }

  private emit(e: RawInputEvent): void {
    for (const f of this.subs) f(e);
  }
}

export const domInputBackend = {
  id: "dom",
  priority: 100,
  probe(options?: unknown): boolean {
    const o = (options ?? {}) as DomInputOptions;
    return typeof o.keyboard?.addEventListener === "function";
  },
  create(options?: unknown): Result<IInputDevice, EngineError> {
    const o = (options ?? {}) as DomInputOptions;
    if (typeof o.keyboard?.addEventListener !== "function") {
      return {
        ok: false,
        error: { code: "INPUT.NO_DOM", message: "没有可用的 DOM 监听目标（keyboard/pointer）" },
      };
    }
    try {
      return ok(new DomInputDevice(o));
    } catch (e) {
      return {
        ok: false,
        error: { code: "INPUT.INIT_FAILED", message: e instanceof Error ? e.message : String(e) },
      };
    }
  },
};
