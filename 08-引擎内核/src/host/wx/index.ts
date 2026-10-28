/**
 * L6 · 小游戏（wx）宿主 · 组装
 *
 * 把四件事凑成一个宿主：**canvas**（上屏）、**视口**（逻辑尺寸 + 像素比）、
 * **帧源**（`ITickSource`）、**输入**（触摸）、**文件系统**（存档位）。
 * 就是 `tools/pack.ts --strict-api` 报出来的那个"需要一个小游戏适配层"的全部内容。
 *
 * ★ 这里**不装图形后端**，而且不是遗漏：`tests/arch/layers.test.ts` 的规则 4 规定
 *   「只有组合根可以 import 具体后端」，而 `src/host/` 是 L6 宿主层、不是组合根。
 *   于是 `GL2Device` 由**入口层**（`src/wx-entry.ts` 之类，root 层）用
 *   `probeWebgl2(canvas)` 的结果去 new —— 本层只负责把 `canvas` 交出去。
 *   这不是为了过闸门而绕路：图形后端要不要用、用哪一个（WebGL2 / null）本来就是
 *   "这次在哪跑"的决定，属于入口，不属于适配层。
 *
 * ★ **不留半个宿主**：任何一步失败就整体返回错误，不做"能用的先用着"。
 *   半截宿主的症状是"游戏起来了但按不动/存不了"，而排查要从五个方向各查一遍；
 *   整体失败至少让人一眼看到是 `WX.NO_TOUCH` 还是 `WX.NO_FS`。
 */

import { ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { IFileSystem } from "../../platform/fs/fs.ts";
import type { IInputDevice } from "../../platform/input/device.ts";
import type { ITickSource } from "../../runtime/tick-source.ts";
import {
  acquireCanvas,
  readViewport,
  type WxCanvasLike,
  type WxLike,
  type WxViewport,
} from "./env.ts";
import { createWxFileSystem, type WxFsOptions } from "./fs.ts";
import { createWxInput, type VirtualPad } from "./input.ts";
import { pickRaf, WxTickSource } from "./tick.ts";

export interface WxHostOptions {
  /** 虚拟键位（不给就按画布尺寸生成默认布局）。 */
  readonly pad?: VirtualPad;
  /** 存档根（默认 `wxfile://usr`）。 */
  readonly root?: string;
  /** 单调毫秒时钟（帧源的 dt 用它算；默认 `Date.now`）。 */
  readonly now?: () => number;
}

export interface WxHost {
  readonly canvas: WxCanvasLike;
  readonly viewport: WxViewport;
  readonly input: IInputDevice;
  readonly fs: IFileSystem;
  /** 交给 `GameApp` 当帧源（它只认 `ITickSource`，见 `runtime/tick-source.ts`）。 */
  readonly tick: ITickSource;
}

export function createWxHost(
  wx: WxLike,
  options: WxHostOptions = {},
): Result<WxHost, EngineError> {
  const canvas = acquireCanvas(wx);
  if (!canvas.ok) return canvas;

  const viewport = readViewport(wx, canvas.value);
  if (!viewport.ok) return viewport;

  const raf = pickRaf(wx, canvas.value);
  if (!raf.ok) return raf;

  const now = options.now ?? (() => Date.now());
  const tick = new WxTickSource(raf.value, now);

  const fsOptions: WxFsOptions = options.root === undefined ? {} : { root: options.root };
  const fs = createWxFileSystem(wx, fsOptions);
  if (!fs.ok) return fs;

  const input = createWxInput(wx, {
    space: {
      windowWidth: viewport.value.width,
      windowHeight: viewport.value.height,
      canvasWidth: canvas.value.width,
      canvasHeight: canvas.value.height,
    },
    ...(options.pad === undefined ? {} : { pad: options.pad }),
  });
  if (!input.ok) return input;

  return ok({
    canvas: canvas.value,
    viewport: viewport.value,
    input: input.value,
    fs: fs.value,
    tick,
  });
}
