/**
 * L1 · 输入设备接口
 *
 * 采用 **快照 + 边缘检测** 模型（Unity 的 `GetKeyDown` 语义），而不是纯事件流。
 * 理由：游戏逻辑是"每 tick 读一次状态"，事件流会让逻辑层不得不自己维护状态机；
 * 而 UI/编辑器需要"这一帧按下的是哪个具体按键序列"，那也由事件流补充。
 *
 * ★ 一个必须固定下来的语义：**pressed/released 是"自上次 poll 以来"的边缘**。
 *   因为模拟是固定步长、渲染是可变帧率，如果一帧里跑了 3 个 tick，
 *   边缘只应在**第一个** tick 可见（否则一次点击会被处理 3 次 —— 上一代引擎
 *   的"一次砍树砍三下"就是这么来的）。这条由 runtime 的 `InputRouter` 保证。
 */

import type { EngineError, Result } from "../../foundation/result.ts";

export interface InputCaps {
  readonly backend: string;
  readonly pointer: boolean;
  readonly touch: boolean;
  readonly gamepad: boolean;
  readonly textInput: boolean;
}

export interface PointerState {
  readonly x: number;
  readonly y: number;
  readonly down: boolean;
  readonly pressed: boolean;
  readonly released: boolean;
  readonly button: number;
}

export interface WheelState {
  readonly dx: number;
  readonly dy: number;
}

export interface InputSnapshot {
  /** 当前按下的逻辑键（`KeyA` / `ArrowUp` / `Gamepad0.A` …）。 */
  readonly keysDown: ReadonlySet<string>;
  /** 自上次 poll 以来新按下 / 松开。 */
  readonly keysPressed: ReadonlySet<string>;
  readonly keysReleased: ReadonlySet<string>;
  readonly pointer: PointerState;
  readonly wheel: WheelState;
  /** 自上次 poll 以来的输入文本（IME 提交结果、按键字符）。 */
  readonly text: string;
}

export interface RawInputEvent {
  readonly kind: "key" | "pointer" | "wheel" | "text" | "blur";
  readonly code?: string;
  readonly x?: number;
  readonly y?: number;
  readonly down?: boolean;
  readonly value?: string;
}

export interface IInputDevice {
  readonly caps: InputCaps;
  /** 每帧调一次，返回并推进边缘状态。 */
  poll(): InputSnapshot;
  /** 原始事件流（UI/编辑器用）。返回退订函数。 */
  subscribe(fn: (e: RawInputEvent) => void): () => void;
  /** 让某个元素获得/放弃焦点（编辑器与 PIE 隔离用）。 */
  setFocusTarget(target: unknown): void;
  /** 窗口失焦时清空所有按下状态，避免"键卡住"。 */
  reset(): void;
  destroy(): void;
}

export interface InputBackendFactory {
  readonly id: string;
  probe(options?: unknown): boolean;
  create(options?: unknown): Result<IInputDevice, EngineError>;
}
