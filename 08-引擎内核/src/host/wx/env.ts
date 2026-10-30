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
  /**
   * 安全区（**CSS 像素**，与 `windowWidth/windowHeight` 同一坐标系）。
   *
   * ★ 可选：老基础库没有这个字段。缺省表示**宿主没报**，不是"安全区是零" ——
   *   消费端据此按 0 处理（宁可少留边，也不替设备猜一个边距）。
   */
  readonly safeArea?: {
    readonly left: number;
    readonly right: number;
    readonly top: number;
    readonly bottom: number;
  };
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
  /**
   * 一行提示（小游戏的原生 toast）。
   *
   * ★ 它不是"装饰"：小游戏**没有** HUD 的 DOM 兜底路径，而提示条（"捡到 3 个木头"
   *   / "背包已满"）是玩家唯一能看到的反馈通道之一。缺了它，装配那边只能静默 ——
   *   静默的后果是"按了没反应"，而那与"按键没接上"在画面上完全一样。
   */
  showToast?(opts: { title: string; icon?: "none" | "success" | "error"; duration?: number }): void;
  /** 需要用户确认的弹窗（启动失败时用：让人知道是坏了，而不是"还没加载完"）。 */
  showModal?(opts: { title?: string; content: string; showCancel?: boolean }): void;
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
  /**
   * `main()` 被调了第二次。
   * ★ 单独一个码：真机正常路径只会调一次，能触发它的只有热重载 / 双入口 / 假宿主。
   *   两次都"成功"的结果是**两条 rAF 循环**（跑两倍速、或一帧推两次），日志一句不响。
   */
  ALREADY_STARTED: "WX.ALREADY_STARTED",
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
  /** 四边安全区（**CSS 像素**）。`undefined` = 宿主没报（老基础库或非真机）。 */
  readonly safeArea?: { readonly top: number; readonly right: number; readonly bottom: number; readonly left: number };
}

/**
 * `getSystemInfoSync().safeArea` → 四边 inset（CSS 像素）。
 *
 * ★ 两个坐标要分清：wx 给的是**可用矩形的四条边**（`left/top/right/bottom` 是边的位置），
 *   而布局要的是"离屏幕边有多远"（inset）。右边与下边因此要**减**：
 *   `inset.right = 窗口宽 − safeArea.right`。直接把它当 inset 用会让刘海屏右边
 *   多出一整块宽度（看起来像"右边被吃掉"）。
 * ★ 四个数缺一个就返回 `undefined`，不拿 0 去补：补出来的值会让安全区"看起来验过了"。
 */
function readSafeInsets(
  sa:
    | { readonly left: number; readonly right: number; readonly top: number; readonly bottom: number }
    | undefined,
  width: number,
  height: number,
): { readonly top: number; readonly right: number; readonly bottom: number; readonly left: number } | undefined {
  if (sa === undefined) return undefined;
  const all = [sa.left, sa.top, sa.right, sa.bottom];
  if (!all.every((n) => Number.isFinite(n))) return undefined;
  const clamp = (n: number): number => (n > 0 ? n : 0);
  return {
    top: clamp(sa.top),
    right: clamp(width - sa.right),
    bottom: clamp(height - sa.bottom),
    left: clamp(sa.left),
  };
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
  return ok({
    width,
    height,
    pixelRatio,
    ...(info === null
      ? {}
      : ((): { safeArea?: WxViewport["safeArea"] } => {
          const safeArea = readSafeInsets(info.safeArea, width, height);
          return safeArea === undefined ? {} : { safeArea };
        })()),
  });
}
