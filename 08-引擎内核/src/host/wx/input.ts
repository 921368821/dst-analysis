/**
 * L6 · 小游戏（wx）宿主 · 触摸输入（触摸 → 逻辑键 + 指针）
 *
 * 小游戏里**没有键盘**，也没有鼠标，只有触摸。而引擎的输入模型是"逻辑键集合"
 * （`InputSnapshot.keysDown`，见 `platform/input/device.ts`）。所以这一层的全部工作是把
 * 「手指按在屏幕哪块」翻译成「哪些逻辑键被按下」。
 *
 * ★★ 设计上的三条硬决定（每条都有判据）：
 *
 *   ① **虚拟键位发的是既有的物理键码**（`KeyW` / `Space` / `KeyG` …），不是新发明的
 *      `Touch.Up` 之类。理由：`extensions/input/input-map.ts` 的映射表已经把动作绑在这些键上，
 *      发新码意味着映射表要分叉成"触屏一套、键鼠一套"—— 而手感一致性正是映射表存在的理由。
 *      于是小游戏里"能不能玩"退化成"适配层有没有吐出那几个键码"，与手柄那条完全同构。
 *
 *   ② **虚拟摇杆用圆不用矩形，且有死区**。方框的四个角离中心最远，按下去却没反应；
 *      死区则是因为手指按在触摸屏上一定会抖 —— 没有死区的结果是"明明没想走，角色一直在挪"。
 *      斜向必须**同时发两个键**（`KeyW` + `KeyD`），否则斜着走要靠"先按上再按右"凑出来。
 *
 *   ③ **触摸点要先换算到 canvas 像素**。`clientX/clientY` 是**逻辑点**（CSS 像素），
 *      而 `canvas.width/height` 是**物理像素**（= 逻辑 × pixelRatio）。少乘一个像素比，
 *      症状是"必须点到偏左上才有效"—— 而它在大分辨率手机上才明显，模拟器上一切正常。
 *
 * ★ 多指同时按：每个触点独立算命中，结果取**并集**（左手摇杆 + 右手攻击是标准握法）。
 *   而按钮之间取**第一个命中**：两个按钮重叠时同时触发两个动作，与"按一下砍树也存了档"
 *   是同一类错误（`input-map.ts` 的 group 就是为这个存在的）。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type {
  IInputDevice,
  InputCaps,
  InputSnapshot,
  RawInputEvent,
} from "../../platform/input/device.ts";
import { WX_ERR, type WxLike, type WxTouchEventLike, type WxTouchHandler, type WxTouchLike } from "./env.ts";

/** 屏幕上的矩形（canvas 像素）。 */
export interface PadRect {
  readonly x: number;
  readonly y: number;
  readonly w: number;
  readonly h: number;
}

export interface PadButton {
  /** 按下去发哪个逻辑键（必须是 `input-map.ts` 里已绑定的码）。 */
  readonly key: string;
  readonly rect: PadRect;
}

export interface VirtualPad {
  /** 摇杆区域（内切圆被当作有效区）。 */
  readonly dpad: PadRect;
  /**
   * 死区半径占摇杆半径的比例（0..1）。
   *
   * ★ 一个必须写下来的事实：**死区小于 `tan(22.5°) ≈ 0.414` 时它什么也不挡** ——
   *   半径 0.2 以内的点，两个轴的分量都不超过 0.2，本来就过不了扇区阈值。
   *   也就是说默认手感真正依赖的是扇区阈值，死区是给「想调大」留的口子
   *   （例如要求按到一半才动）。判据用 0.2 与 0.5 两档对同一个点做对照 ——
   *   只断言「中心没键」是没有分辨力的（第一版就是这么假绿的）。
   */
  readonly deadZone: number;
  /** 动作键，**顺序即优先级**（重叠时先命中的赢）。 */
  readonly buttons: readonly PadButton[];
}

/** 斜向判定阈值：`tan(22.5°)`。超过它就算有该轴分量 ⇒ 8 个扇区各 45°。 */
const DIAG = 0.41421356237309503;

/** 屏幕坐标 → canvas 像素（见文件头 ③）。 */
export interface PointSpace {
  readonly windowWidth: number;
  readonly windowHeight: number;
  readonly canvasWidth: number;
  readonly canvasHeight: number;
}

export function toCanvasPoint(
  touch: { readonly clientX: number; readonly clientY: number },
  space: PointSpace,
): { x: number; y: number } {
  const sx = space.windowWidth > 0 ? space.canvasWidth / space.windowWidth : 1;
  const sy = space.windowHeight > 0 ? space.canvasHeight / space.windowHeight : 1;
  return { x: touch.clientX * sx, y: touch.clientY * sy };
}

/**
 * 默认键位布局（与分辨率成比例，短边为基准）。
 *
 * 左下摇杆、右下四个动作键（攻击 / 采摘 / 砍 / 背包）。键码刻意与键鼠一致：
 * `Space` = attack、`KeyG` = harvest、`KeyH` = chop、`Tab` = bag。
 */
export function makeDefaultPad(width: number, height: number): VirtualPad {
  const s = Math.min(width, height);
  const pad = 0.42 * s;
  const margin = 0.06 * s;
  const btn = 0.15 * s;
  const gap = 0.035 * s;
  const right = width - margin - btn;
  const bottom = height - margin - btn;
  const buttons: PadButton[] = [
    { key: "KeyH", rect: { x: right, y: bottom, w: btn, h: btn } },
    { key: "Space", rect: { x: right - btn - gap, y: bottom, w: btn, h: btn } },
    { key: "KeyG", rect: { x: right, y: bottom - btn - gap, w: btn, h: btn } },
    { key: "Tab", rect: { x: right - btn - gap, y: bottom - btn - gap, w: btn, h: btn } },
  ];
  return { dpad: { x: margin, y: height - margin - pad, w: pad, h: pad }, deadZone: 0.2, buttons };
}

/**
 * 一个触点在键位表上命中哪些键。
 *
 * 顺序稳定（先方向后按钮）—— 判据比的是集合，但日志里顺序一致更好读。
 */
export function hitTestPad(pad: VirtualPad, x: number, y: number): readonly string[] {
  const keys: string[] = [];
  const cx = pad.dpad.x + pad.dpad.w / 2;
  const cy = pad.dpad.y + pad.dpad.h / 2;
  const r = Math.min(pad.dpad.w, pad.dpad.h) / 2;
  if (r > 0) {
    const nx = (x - cx) / r;
    const ny = (y - cy) / r;
    const dist = Math.sqrt(nx * nx + ny * ny);
    if (dist <= 1 && dist > pad.deadZone) {
      if (nx > DIAG) keys.push("KeyD");
      else if (nx < -DIAG) keys.push("KeyA");
      if (ny > DIAG) keys.push("KeyS");
      else if (ny < -DIAG) keys.push("KeyW");
    }
  }
  for (const b of pad.buttons) {
    const r2 = b.rect;
    if (x >= r2.x && x < r2.x + r2.w && y >= r2.y && y < r2.y + r2.h) {
      // ★ 只取第一个命中（见文件头最后一段）。
      keys.push(b.key);
      break;
    }
  }
  return keys;
}

export interface WxInputOptions {
  readonly space: PointSpace;
  /** 不给就用 `makeDefaultPad(canvasWidth, canvasHeight)`。 */
  readonly pad?: VirtualPad;
}

const TOUCH_HANDLERS = [
  ["onTouchStart", "offTouchStart", "start"],
  ["onTouchMove", "offTouchMove", "move"],
  ["onTouchEnd", "offTouchEnd", "end"],
  ["onTouchCancel", "offTouchCancel", "cancel"],
] as const;

type Phase = "start" | "move" | "end" | "cancel";

export class WxInputDevice implements IInputDevice {
  readonly caps: InputCaps = {
    backend: "wx",
    pointer: true,
    touch: true,
    gamepad: false,
    textInput: false,
  };

  private readonly pad: VirtualPad;
  private readonly space: PointSpace;
  /** identifier → canvas 坐标（插入顺序就是"第一根手指"的顺序）。 */
  private readonly points = new Map<number, { x: number; y: number }>();
  private down = new Set<string>();
  private pressed = new Set<string>();
  private released = new Set<string>();
  private pointerDown = false;
  private pointerPressed = false;
  private pointerReleased = false;
  private px = 0;
  private py = 0;
  private readonly subs = new Set<(e: RawInputEvent) => void>();
  private readonly handlers: { phase: Phase; fn: WxTouchHandler; on?: string; off?: string }[] = [];
  private dead = false;

  constructor(
    private readonly wx: WxLike,
    options: WxInputOptions,
  ) {
    this.pad = options.pad ?? makeDefaultPad(options.space.canvasWidth, options.space.canvasHeight);
    this.space = options.space;
    for (const [on, off, phase] of TOUCH_HANDLERS) {
      const sub = (wx as unknown as Record<string, unknown>)[on];
      if (typeof sub !== "function") continue;
      const handle: WxTouchHandler = (ev) => {
        if (this.dead) return;
        this.feed(phase, ev);
      };
      (sub as (cb: WxTouchHandler) => void).call(wx, handle);
      const un = (wx as unknown as Record<string, unknown>)[off];
      this.handlers.push({
        phase,
        fn: handle,
        on,
        ...(typeof un === "function" ? { off } : {}),
      });
    }
  }

  /** 是否有任何触摸订阅 —— 一个都没有时游戏没法玩，构造期就该失败（见 `createWxInput`）。 */
  static hasTouch(wx: WxLike): boolean {
    return TOUCH_HANDLERS.some(([on]) => typeof (wx as unknown as Record<string, unknown>)[on] === "function");
  }

  private feed(phase: Phase, ev: WxTouchEventLike): void {
    const all = ev.touches;
    if (Array.isArray(all)) {
      // ★ 有全量列表就以它为准重建（`touches` 是"当前还按着的"，天然不会漂移；
      //   而且 end/cancel 时也**不需要**再看 changedTouches —— 已经不在列表里了）。
      this.points.clear();
      for (const t of all) this.addPoint(t);
    } else {
      // ★ 老版本可能只给 changedTouches：那时只能按增量改。
      for (const t of ev.changedTouches ?? []) {
        if (phase === "end" || phase === "cancel") this.points.delete(t.identifier);
        else this.addPoint(t);
      }
    }
    this.recompute();
  }

  private addPoint(t: WxTouchLike): void {
    this.points.set(t.identifier, toCanvasPoint(t, this.space));
  }

  /** 由当前触点集合重算 keysDown，并推进边缘与指针。 */
  private recompute(): void {
    const next = new Set<string>();
    for (const p of this.points.values()) {
      for (const k of hitTestPad(this.pad, p.x, p.y)) next.add(k);
    }
    for (const k of next) if (!this.down.has(k)) this.pressed.add(k);
    for (const k of this.down) if (!next.has(k)) this.released.add(k);
    this.down = next;

    const first = this.points.values().next();
    const wasDown = this.pointerDown;
    if (first.done === true) {
      this.pointerDown = false;
      if (wasDown) {
        this.pointerReleased = true;
        this.emit({ kind: "pointer", x: this.px, y: this.py, down: false });
      }
    } else {
      this.px = first.value.x;
      this.py = first.value.y;
      this.pointerDown = true;
      if (!wasDown) this.pointerPressed = true;
      this.emit({ kind: "pointer", x: this.px, y: this.py, down: true });
    }
  }

  private emit(e: RawInputEvent): void {
    for (const fn of this.subs) fn(e);
  }

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
      wheel: { dx: 0, dy: 0 },
      text: "",
    };
    // ★ 与 `input-null` / `input-dom` 同一条语义：边缘只在**一次** poll 里可见。
    this.pressed.clear();
    this.released.clear();
    this.pointerPressed = false;
    this.pointerReleased = false;
    return snap;
  }

  subscribe(fn: (e: RawInputEvent) => void): () => void {
    this.subs.add(fn);
    return () => {
      this.subs.delete(fn);
    };
  }

  /** 小游戏只有一个屏幕，不存在"切焦点"；留着是为了满足接口。 */
  setFocusTarget(_target: unknown): void {}

  /** 与 `input-dom` 的 blur 同一纪律：清空所有按下状态（否则"键卡住"）。 */
  reset(): void {
    this.points.clear();
    this.down.clear();
    this.pressed.clear();
    this.released.clear();
    this.pointerDown = false;
    this.pointerPressed = false;
    this.pointerReleased = false;
  }

  /** 取消订阅。没给 `off*` 的版本靠 `dead` 标记挡住后续回调（不能靠"应该不会再来"）。 */
  destroy(): void {
    this.dead = true;
    for (const h of this.handlers) {
      if (h.on === undefined || h.off === undefined) continue;
      const un = (this.wx as unknown as Record<string, unknown>)[h.off];
      if (typeof un === "function") (un as (cb: WxTouchHandler) => void).call(this.wx, h.fn);
    }
    this.handlers.length = 0;
    this.subs.clear();
    this.reset();
  }
}

export function createWxInput(
  wx: WxLike,
  options: WxInputOptions,
): Result<WxInputDevice, EngineError> {
  if (!WxInputDevice.hasTouch(wx)) {
    return err(engineError(WX_ERR.NO_TOUCH, "当前 wx 一个 onTouch* 都没有 —— 没有输入源"));
  }
  return ok(new WxInputDevice(wx, options));
}
