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
 *  ④ 「在打字」是一个**双向**状态：`focusin` 进、`focusout` 出。只写进不写出，
 *     输入框一收起（焦点落回 body，不会再派发 focusin）键盘就永久失灵。
 *     同理，进入打字状态要清掉已按住的键 —— 那些键的 keyup 已经被输入框吃掉了。
 *
 * ★ 手柄（T362）也在这里合成成**逻辑键码**（`Gamepad0.A` / `Gamepad0.LStickLeft`）：
 *   映射表那一层就完全不需要知道 `navigator.getGamepads()` 长什么样，
 *   "换个手柄还能不能玩"于是退化成"后端有没有吐出那几个键码"——**这是可以在 headless 判的**。
 *   摇杆按死区折算成 4 个虚拟方向键（不是轴值）：因为 `InputSnapshot` 的模型是"按键集合"，
 *   把轴塞进去会让每个读输入的地方都要处理"连续值"，而那正是映射表想避免的分叉。
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

/** 手柄的结构接口（只取用得到的字段，与 W3C Gamepad 兼容）。 */
export interface GamepadLike {
  readonly connected?: boolean;
  readonly index?: number;
  readonly axes?: readonly number[];
  readonly buttons?: readonly { readonly pressed?: boolean; readonly value?: number }[];
}

export interface DomInputOptions {
  /** 键盘监听目标（通常是 window）。 */
  readonly keyboard?: DomEventTarget;
  /** 指针/滚轮监听目标（通常是 canvas）。 */
  readonly pointer?: DomEventTarget;
  /**
   * 手柄来源。缺省读 `navigator.getGamepads()`。
   * ★ 之所以做成**可注入**：手柄是硬件，CI 上没有。判据要能注入一个假手柄，
   *   验证"按下 A → 吐 `Gamepad0.A`"整条链，而不是"等哪天有人插上手柄看看"。
   */
  readonly gamepads?: () => readonly (GamepadLike | null | undefined)[];
  /** 摇杆死区（0..1）。缺省 0.35：太小会被漂移触发，太大推不动。 */
  readonly stickDeadzone?: number;
}

/** 标准布局的按键名（W3C "standard" mapping 的前 16 个）。 */
const PAD_BUTTONS = [
  "A", "B", "X", "Y", "LB", "RB", "LT", "RT",
  "Select", "Start", "L3", "R3",
  "DPadUp", "DPadDown", "DPadLeft", "DPadRight",
] as const;

/** 这些按键在用于游戏时应该 preventDefault，避免页面滚动。 */
const PREVENT = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Space", "Tab"]);

export class DomInputDevice implements IInputDevice {
  readonly caps: InputCaps = {
    backend: "dom",
    pointer: true,
    touch: true,
    // 构造时按环境改（有 `navigator.getGamepads` 才是 true）—— 写死 true 就是假能力声明
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
  private readonly gamepads: (() => readonly (GamepadLike | null | undefined)[]) | null;
  private readonly deadzone: number;
  /** 上一次 poll 时手柄按下的键码（用来算"刚按下 / 刚松开"的边缘）。 */
  private padDown = new Set<string>();
  private readonly bound: Array<[DomEventTarget, string, (ev: DomEventLike) => void]> = [];
  /** 有输入框聚焦时，键盘不驱动游戏（编辑器输入场景名时不能同时让角色走）。 */
  private textFocus = false;

  constructor(opts: DomInputOptions) {
    if (opts.keyboard === undefined || opts.pointer === undefined) {
      throw new Error("DomInputDevice 需要 keyboard 与 pointer 两个监听目标");
    }
    this.kb = opts.keyboard;
    this.ptr = opts.pointer;
    this.gamepads = opts.gamepads ?? defaultGamepads();
    this.deadzone = opts.stickDeadzone ?? 0.35;
    this.caps = { ...this.caps, gamepad: this.gamepads !== null };
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
      const next = this.isTyping(ev);
      // ★ 进入打字状态要把**已经按住**的键清掉：否则「按住 W 时按 /」会让角色
      //   一边打字一边继续走 —— 那些键的 keyup 会被输入框吃掉，游戏这一侧永远等不到。
      //   与 `onBlur` 同一套清理、同一条理由。
      if (next && !this.textFocus) {
        this.down.clear();
        this.pressed.clear();
        this.released.clear();
      }
      this.textFocus = next;
    };

    /**
     * 焦点**离开**时把「在打字」这个状态清掉。
     *
     * ★★ 这条是批112 的浏览器自检逼出来的真 bug（`focusout` 之前没人管）：
     *   `textFocus` 原来只在 `focusin` 里赋值。而输入框收起（命令行按 Esc / 回车）
     *   时浏览器把焦点交回 `body`，**不会再派发 focusin** ⇒ `textFocus` 永远是
     *   `true` ⇒ 之后每一个按键都被当成"在输入框里打字"吞掉。
     *   症状：「在命令行里打完一条命令，收起之后 WASD 再也不动了」（除非点到
     *   别的可聚焦元素）。它躲过了所有 Node 判据 —— 那些都不经过焦点。
     */
    const onFocusOut = (): void => {
      this.textFocus = false;
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
    this.add(this.kb, "focusout", onFocusOut);
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
    // ---- 手柄：先采一次，再与上一次的集合做差（键盘的边缘由事件驱动，手柄只能靠轮询）
    const padNow = this.samplePads();
    const padPressed: string[] = [];
    const padReleased: string[] = [];
    for (const k of padNow) if (!this.padDown.has(k)) padPressed.push(k);
    for (const k of this.padDown) if (!padNow.has(k)) padReleased.push(k);
    this.padDown = padNow;

    const down = new Set(this.down);
    const pressedSet = new Set(this.pressed);
    const releasedSet = new Set(this.released);
    for (const k of padNow) down.add(k);
    for (const k of padPressed) pressedSet.add(k);
    for (const k of padReleased) releasedSet.add(k);

    const snap: InputSnapshot = {
      keysDown: down,
      keysPressed: pressedSet,
      keysReleased: releasedSet,
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

  /**
   * 读一次手柄，返回"当前按下的逻辑键码"。
   *
   * ★ 只读 `standard` 布局的前 16 个键与两个轴。非标准手柄（`mapping !== "standard"`）
   *   的键位因厂商而异 —— 假装能读会让"这个手柄不能用"变成"按 A 触发了 B"。
   *   这里不判断 mapping（结构接口里没有），但**名字按标准布局给**，
   *   文档里写明"非标准手柄需要在宿主侧做映射表"。
   */
  private samplePads(): Set<string> {
    const out = new Set<string>();
    if (this.gamepads === null) return out;
    const pads = this.gamepads();
    for (const pad of pads) {
      if (pad === null || pad === undefined || pad.connected === false) continue;
      const prefix = `Gamepad${pad.index ?? 0}.`;
      const btns = pad.buttons ?? [];
      for (let i = 0; i < PAD_BUTTONS.length && i < btns.length; i++) {
        const b = btns[i];
        if (b === undefined) continue;
        // `pressed` 与 `value` 都算：扳机键在多数浏览器上只有 value，pressed 要过阈值才 true
        if (b.pressed === true || (b.value ?? 0) > 0.5) out.add(prefix + PAD_BUTTONS[i]!);
      }
      const ax = pad.axes ?? [];
      const lx = ax[0] ?? 0;
      const ly = ax[1] ?? 0;
      if (lx < -this.deadzone) out.add(prefix + "LStickLeft");
      if (lx > this.deadzone) out.add(prefix + "LStickRight");
      // W3C：摇杆向上是**负值**。写反的症状是"上下颠倒"，而且只在真手柄上出现。
      if (ly < -this.deadzone) out.add(prefix + "LStickUp");
      if (ly > this.deadzone) out.add(prefix + "LStickDown");
    }
    return out;
  }

  reset(): void {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.padDown = new Set<string>();
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

/** 环境里有没有手柄 API。没有就返回 null（caps.gamepad 随之为 false）。 */
function defaultGamepads(): (() => readonly (GamepadLike | null | undefined)[]) | null {
  const nav = (globalThis as { navigator?: { getGamepads?: () => readonly (GamepadLike | null)[] } }).navigator;
  if (typeof nav?.getGamepads !== "function") return null;
  return () => nav.getGamepads!();
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
