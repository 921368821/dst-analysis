/**
 * L6 · 小游戏（wx）宿主 · 环境适配的最小面
 *
 * 这一层回答的是 `tools/pack.ts --strict-api` 报出来的那个问题：**小游戏里没有 dom**。
 * 清单写在 `src/publish/pack-plan.ts` 的 `FORBIDDEN_IN_MINIGAME` 里
 * （`document.` / `window.` / `XMLHttpRequest` / `localStorage` / `new Function` / `eval(`）。
 * 所以适配层的全部工作就是：**把那几件事换成 wx 的对应物**，而不是把引擎改写成小游戏专用。
 *
 * ★ 与 `input-dom` 同一条纪律：用**最小结构接口**（`WxLike`），不用 `wx` 的官方类型声明。
 *   理由有两个，都是实践里的：
 *   ① 官方类型声明需要装 `minigame-api-typings` 并且跟着它升版本，而这里只用到 **6 个方法**；
 *   ② 结构接口意味着判据可以传一个假的 `wx` 进来 —— 而这是**唯一**能在 CI 里跑的方式
 *      （真机验证要开发者工具，与 B1 同一条外部依赖）。
 *
 * ★ 这个文件里**不许**出现 `FORBIDDEN_IN_MINIGAME` 里的任何字符串。
 *   听起来是废话（适配层当然不该用 dom），但它是可判的：`tests/host/wx.test.ts` 会扫描
 *   `src/host/wx/*.ts` 的源码并断言零命中。这条自指的闸门挡的是"以后有人在本层顺手
 *   `window.setTimeout` 一下"——那种改动在任何判据里都不会红，只会在真机上白屏。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** 只用到的 canvas 能力。`getContext` 的返回值是 `unknown`，由后端自己收窄（与 `GL2Device` 一致）。 */
export interface WxCanvasLike {
  width: number;
  height: number;
  getContext(kind: string): unknown;
  requestAnimationFrame?(cb: () => void): number;
  cancelAnimationFrame?(id: number): void;
}

/** 触摸点（wx 的 `touches[]` 元素只要这两个字段）。 */
export interface WxTouchLike {
  readonly identifier: number;
  readonly clientX: number;
  readonly clientY: number;
}

export interface WxTouchEventLike {
  readonly touches?: readonly WxTouchLike[];
  readonly changedTouches?: readonly WxTouchLike[];
}

export type WxTouchHandler = (ev: WxTouchEventLike) => void;

export interface WxSystemInfoLike {
  readonly windowWidth: number;
  readonly windowHeight: number;
  readonly pixelRatio?: number;
}

/**
 * 只用到的 `wx` 能力。
 *
 * ★ 全都是**可选**的：真机上一定有，但判据要能造出"缺某一个"的假 wx 来验失败路径。
 *   把方法写成必需的，就等于把"缺失"这件事从类型里抹掉了 —— 而小游戏的老版本
 *   恰恰会有"这个 API 还没有"的情形。
 */
export interface WxLike {
  createCanvas?(): WxCanvasLike | null;
  getSystemInfoSync?(): WxSystemInfoLike;
  requestAnimationFrame?(cb: () => void): number;
  cancelAnimationFrame?(id: number): void;
  onTouchStart?(cb: WxTouchHandler): void;
  onTouchMove?(cb: WxTouchHandler): void;
  onTouchEnd?(cb: WxTouchHandler): void;
  onTouchCancel?(cb: WxTouchHandler): void;
  offTouchStart?(cb: WxTouchHandler): void;
  offTouchMove?(cb: WxTouchHandler): void;
  offTouchEnd?(cb: WxTouchHandler): void;
  offTouchCancel?(cb: WxTouchHandler): void;
  getFileSystemManager?(): unknown;
}

export const WX_ERR = {
  /** 拿不到上屏 canvas。 */
  NO_CANVAS: "WX.NO_CANVAS",
  /** canvas 有，但 `getContext("webgl2")` 给 null。 */
  NO_WEBGL2: "WX.NO_WEBGL2",
  /** 一个可用的帧调度都没有（canvas 和 wx 上都没有 rAF）。 */
  NO_SCHEDULER: "WX.NO_SCHEDULER",
  /** 一个触摸订阅接口都没有 —— 没有输入源，游戏没法玩，早失败。 */
  NO_TOUCH: "WX.NO_TOUCH",
  /** 拿不到文件系统管理器。 */
  NO_FS: "WX.NO_FS",
  /** 视口尺寸不可用（0 或负数会静默算出 NaN 坐标）。 */
  BAD_VIEWPORT: "WX.BAD_VIEWPORT",
} as const;

/**
 * 取上屏 canvas。
 *
 * ★ 为什么失败要报错而不是自己造一个：小游戏里 `createCanvas()` 的**第一次调用**返回的
 *   才是上屏 canvas，之后再调用得到的是离屏 canvas。自己兜底造一个的结果是
 *   "游戏在跑、画面不在屏幕上"—— 一个没有任何地方会报错的失败。
 */
export function acquireCanvas(wx: WxLike): Result<WxCanvasLike, EngineError> {
  if (typeof wx.createCanvas !== "function") {
    return err(engineError(WX_ERR.NO_CANVAS, "当前 wx 没有 createCanvas —— 不是小游戏环境"));
  }
  const canvas = wx.createCanvas();
  if (canvas === null || canvas === undefined || typeof canvas.getContext !== "function") {
    return err(engineError(WX_ERR.NO_CANVAS, "createCanvas 没有返回可用的 canvas"));
  }
  return ok(canvas);
}

/**
 * 探一下 WebGL2。
 *
 * ★ 单独一个函数而不是塞进 `acquireCanvas`：**canvas 拿到与能不能上 GPU 是两件事**。
 *   小游戏老版本可能只给 WebGL1；那时 canvas 是好的，而图形后端该退到 `gfx-null`
 *   （或将来补一个 WebGL1 后端）。把两件事合成一次失败，会让"画面不动"变成"整个宿主起不来"。
 */
export function probeWebgl2(canvas: WxCanvasLike): Result<unknown, EngineError> {
  const gl = canvas.getContext("webgl2");
  if (gl === null || gl === undefined) {
    return err(engineError(WX_ERR.NO_WEBGL2, "canvas.getContext(\"webgl2\") 返回空"));
  }
  return ok(gl);
}

/** 视口：窗口的逻辑尺寸 + 像素比（canvas 的 `width/height` 是物理像素）。 */
export interface WxViewport {
  readonly width: number;
  readonly height: number;
  readonly pixelRatio: number;
}

/**
 * 读视口。
 *
 * ★ 没有 `getSystemInfoSync` 时退回 canvas 尺寸并**把 pixelRatio 记为 1**：
 *   这个 1 是"不知道"，不是"等于 1"。写成 0 会让缩放比变成 Infinity（坐标全 NaN），
 *   写成猜的 2 会让所有触摸点偏移一倍。1 至少让"逻辑尺寸 = 物理尺寸"这个假设
 *   显式地站在这里，将来真机上一眼能看出哪里不对。
 */
export function readViewport(
  wx: WxLike,
  canvas: WxCanvasLike,
): Result<WxViewport, EngineError> {
  const info = typeof wx.getSystemInfoSync === "function" ? wx.getSystemInfoSync() : null;
  const width = info === null ? canvas.width : info.windowWidth;
  const height = info === null ? canvas.height : info.windowHeight;
  const ratio = info?.pixelRatio;
  const pixelRatio = ratio === undefined || !Number.isFinite(ratio) || ratio <= 0 ? 1 : ratio;
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    return err(
      engineError(WX_ERR.BAD_VIEWPORT, `视口尺寸不可用：${String(width)}×${String(height)}`),
    );
  }
  return ok({ width, height, pixelRatio });
}
