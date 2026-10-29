/**
 * L5 · 注入式输入设备
 *
 * 用途只有一句话：**宿主已经量好了输入，平台别再自己去猜一个**。
 *
 * 这条通道此前是不存在的，而它的缺失造成了两个具体后果：
 *
 *   ① 小游戏（`src/host/wx/`）已经把触摸翻译成了逻辑键（`createWxInput`），
 *      但 `createPlatform` 只会从注册表里 probe 一个输入后端 —— 而小游戏里
 *      既没有 DOM 也没有键盘，`input-dom` 的 probe 必然为 false，
 *      于是"触摸已经能用了"这件事在平台层根本接不上。
 *   ② 判据要验"玩家按了 W 之后世界真的动了"，只能走 `input-null` 的编程接口；
 *      那条路造出来的设备与真实宿主**不是同一个对象**，于是"宿主注入了没有"
 *      永远验不到（`GameAppOptions` 有 `fs` 没有 `input`，缺的就是这一块）。
 *
 * ★★ 三条语义，都是刻意的：
 *
 *   **1. 不包装、不复制。** 返回的就是宿主那个实例。包一层代理看起来更"干净"，
 *      但 `pressed` / `released` 是"自上次 poll 以来的边缘"（见 `input/device.ts`
 *      文件头）—— 代理与真身各 poll 一次，边缘就会被清两次，症状是"按下没反应"
 *      与"一次点击触发两次"交替出现，而且只在某些帧率下。
 *
 *   **2. 注入即交出所有权。** 平台关闭时会 `destroy()` 输入设备。宿主若打算在
 *      游戏结束后继续用同一个设备（编辑器切场景就是这种），必须自己再造一个 ——
 *      而不是希望平台"别销毁我的东西"。含糊的所有权比多造一个对象贵得多。
 *
 *   **3. 缺设备时**probe** 为 false、create 报 `INPUT.NO_DEVICE`**，不静默退回 null。
 *      静默退回的症状是"游戏起来了，但按什么都没反应"—— 与"输入还没接好"
 *      在画面上完全一样，而后者才是真实原因。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { IInputDevice } from "../../platform/input/device.ts";

/** 注册名。宿主用 `prefer.input = INJECTED_INPUT_ID` 显式选中它。 */
export const INJECTED_INPUT_ID = "injected";

export interface InjectedInputOptions {
  /** 宿主已经建好的设备（触摸 / 手柄 / 判据的可编程设备）。 */
  readonly device?: IInputDevice;
}

/**
 * 优先级给 100：与 `webgl2Backend` / `domInputBackend` 同档。
 *
 * ★ 但这**不会**让浏览器宿主突然改用注入 —— 它的 `probe` 要求显式给 `device`，
 *   而浏览器入口不传。优先级只决定"同时可用时选谁"，"可不可用"仍然由 probe 回答。
 */
export const injectedInputBackend = {
  id: INJECTED_INPUT_ID,
  priority: 100,
  probe(options?: unknown): boolean {
    // ★ `null` 与 `undefined` 一样算"没给"：调用方从可选字段里读出来常常是 null，
    //   放过去的话 `create` 会 return ok(null) —— 之后 `input.poll()` 才炸，
    //   而那时候栈里已经看不到是谁注入的了。
    return (options as InjectedInputOptions | undefined)?.device != null;
  },
  create(options?: unknown): Result<IInputDevice, EngineError> {
    const device = (options as InjectedInputOptions | undefined)?.device;
    if (device === undefined || device === null) {
      return err(
        engineError("INPUT.NO_DEVICE", "注入式输入后端需要 options.device（宿主已经建好的输入设备）"),
      );
    }
    // 原样交出（见文件头第 1、2 条）：不包装、不复制、所有权转移给平台。
    return ok(device);
  },
};
