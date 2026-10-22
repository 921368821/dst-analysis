/**
 * L5 · Null 输入设备（可编程）
 *
 * 它让"输入 → 逻辑"这条链在 headless 完全可测：判据直接 `press('KeyW')` /
 * `movePointer(10,20)` / `pump()` 就能造出任意输入序列。
 *
 * ★ 边缘语义在这里实现一次，所有上层共享：
 *   `keysPressed` = "自上次 poll 以来新按下的"。
 *   这个定义听起来琐碎，但它是"一次点击被处理 N 次"（上一代引擎"砍一刀砍三下"）
 *   的根因。定义写在这里 + 契约测试，就不需要在每个消费者那里各写一遍。
 */

import { ok, type EngineError, type Result } from "../../foundation/result.ts";
import type {
  IInputDevice,
  InputCaps,
  InputSnapshot,
  RawInputEvent,
} from "../../platform/input/device.ts";

export class NullInputDevice implements IInputDevice {
  readonly caps: InputCaps = {
    backend: "null",
    pointer: true,
    touch: false,
    gamepad: false,
    textInput: true,
  };

  private down = new Set<string>();
  private pressed = new Set<string>();
  private released = new Set<string>();
  private pointerDown = false;
  private pointerPressed = false;
  private pointerReleased = false;
  private px = 0;
  private py = 0;
  private wheelX = 0;
  private wheelY = 0;
  private text = "";
  private readonly subs = new Set<(e: RawInputEvent) => void>();

  poll(): InputSnapshot {
    const snap: InputSnapshot = {
      keysDown: new Set(this.down),
      keysPressed: new Set(this.pressed),
      keysReleased: new Set(this.released),
      pointer: {
        x: this.px,
        y: this.py,
        down: this.pointerDown,
        pressed: this.pointerPressed,
        released: this.pointerReleased,
        button: 0,
      },
      wheel: { dx: this.wheelX, dy: this.wheelY },
      text: this.text,
    };
    // 推进边缘：poll 之后清空
    this.pressed.clear();
    this.released.clear();
    this.pointerPressed = false;
    this.pointerReleased = false;
    this.wheelX = 0;
    this.wheelY = 0;
    this.text = "";
    return snap;
  }

  subscribe(fn: (e: RawInputEvent) => void): () => void {
    this.subs.add(fn);
    return () => this.subs.delete(fn);
  }

  setFocusTarget(_target: unknown): void {}

  reset(): void {
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.pointerDown = false;
    this.pointerPressed = false;
    this.pointerReleased = false;
  }

  destroy(): void {
    this.subs.clear();
    this.reset();
  }

  // ---- 编程接口（判据/编辑器用）
  keyDown(code: string): void {
    if (!this.down.has(code)) {
      this.down.add(code);
      this.pressed.add(code);
    }
    this.emit({ kind: "key", code, down: true });
  }

  keyUp(code: string): void {
    if (this.down.delete(code)) {
      this.released.add(code);
    }
    this.emit({ kind: "key", code, down: false });
  }

  movePointer(x: number, y: number): void {
    this.px = x;
    this.py = y;
    this.emit({ kind: "pointer", x, y });
  }

  pointerDownAt(x: number, y: number): void {
    this.px = x;
    this.py = y;
    this.pointerDown = true;
    this.pointerPressed = true;
    this.emit({ kind: "pointer", x, y, down: true });
  }

  pointerUpAt(x: number, y: number): void {
    this.px = x;
    this.py = y;
    this.pointerDown = false;
    this.pointerReleased = true;
    this.emit({ kind: "pointer", x, y, down: false });
  }

  wheel(dx: number, dy: number): void {
    this.wheelX += dx;
    this.wheelY += dy;
    this.emit({ kind: "wheel", x: dx, y: dy });
  }

  typeText(s: string): void {
    this.text += s;
    this.emit({ kind: "text", value: s });
  }

  private emit(e: RawInputEvent): void {
    for (const f of this.subs) f(e);
  }
}

export const nullInputBackend = {
  id: "null",
  priority: 0,
  probe(_options?: unknown): boolean {
    return true;
  },
  create(_options?: unknown): Result<IInputDevice, EngineError> {
    return ok(new NullInputDevice());
  },
};
