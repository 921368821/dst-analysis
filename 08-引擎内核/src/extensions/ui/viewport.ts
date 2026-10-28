/**
 * L4 · UI 视口：设计坐标 ↔ 屏幕像素
 *
 * 一句话：**UI 永远按「设计分辨率」摆放，屏幕差异只在最后一步换算里被吸收**。
 * 若这一层不存在，每个控件都会拿 `canvas.width` 去算位置 —— 于是同一套 UI
 * 在 16:9 上对、在 21:9 上偏、在刘海屏上被吃掉一条边，且没人能说清"正确"是哪种。
 *
 * ★★ 为什么只有三种模式，且**不做**「非等比拉伸」：
 *   · `fit`    整框可见，多出来的地方留黑边（scale = min），内容锁在设计框内
 *   · `fill`   铺满屏幕，设计区超出的部分被裁掉（scale = max）
 *   · `expand` 整框可见（scale = min），但**锚点参考区扩到整屏**
 *
 *   `fit` 与 `expand` 的差别不在缩放，而在**锚点贴哪条边**：
 *   超宽屏上用 `fit` 时，贴左上的血条贴着**设计框**左上（屏幕左上还有一段黑边）；
 *   用 `expand` 则贴着**屏幕**左上，黑边那块也被当成可用区域。
 *   这是"超宽屏 / 刘海屏"唯一需要的那条区分。
 *
 *   不做非等比拉伸是刻意的：Camera2D 只有单一 `zoom`，要做非等比就得给相机
 *   加第二个缩放轴，而那会让**所有**精灵的圆形变成椭圆 —— 一个为 UI 服务的开关
 *   污染整个 2.5D 渲染，代价远大于收益。需要非等比的场景（极窄竖屏）应该换一套
 *   设计分辨率，而不是把图形拉扁。
 *
 * ★ 本层不依赖 gfx / 浏览器：屏幕尺寸与 dpr 都由宿主推进来，所以 Node 里能跑判据。
 */

import { Rect } from "../../foundation/math/index.ts";
import { Camera2D } from "../render/camera.ts";

export const UiScaleMode = { Fit: "fit", Fill: "fill", Expand: "expand" } as const;
export type UiScaleModeValue = (typeof UiScaleMode)[keyof typeof UiScaleMode];

export interface Insets {
  readonly top: number;
  readonly right: number;
  readonly bottom: number;
  readonly left: number;
}

export const ZERO_INSETS: Insets = { top: 0, right: 0, bottom: 0, left: 0 };

export interface UiViewportConfig {
  readonly designWidth: number;
  readonly designHeight: number;
  readonly scaleMode?: UiScaleModeValue;
  /** 安全区（设计像素）。宿主从 CSS `env(safe-area-inset-*)` 或平台 API 读来。 */
  readonly safeArea?: Insets;
}

export class UiViewport {
  readonly designWidth: number;
  readonly designHeight: number;
  scaleMode: UiScaleModeValue;

  private cssW = 1;
  private cssH = 1;
  private dpr = 1;
  private scaleValue = 1;
  private safe: Insets = ZERO_INSETS;
  /** 复用同一个相机实例：每帧 new 一个会白白产生垃圾，而且外部持有的引用会失效。 */
  private readonly cam: Camera2D;

  constructor(cfg: UiViewportConfig) {
    if (!(cfg.designWidth > 0) || !(cfg.designHeight > 0)) {
      throw new RangeError(`设计分辨率必须 > 0：${cfg.designWidth}x${cfg.designHeight}`);
    }
    this.designWidth = cfg.designWidth;
    this.designHeight = cfg.designHeight;
    this.scaleMode = cfg.scaleMode ?? UiScaleMode.Expand;
    this.safe = cfg.safeArea ?? ZERO_INSETS;
    this.cam = new Camera2D({
      viewportWidth: 1,
      viewportHeight: 1,
      zoom: 1,
      // ★ 1 = 无俯视压缩。UI 是纯 2D，任何 tiltY 都会把字压扁。
      tiltY: 1,
      x: cfg.designWidth / 2,
      z: cfg.designHeight / 2,
    });
    this.apply();
  }

  /** 宿主每帧（或窗口变化时）推进来。尺寸非正时忽略（与 Camera2D.setViewport 一致）。 */
  setScreen(cssWidth: number, cssHeight: number, dpr = 1): void {
    if (!(cssWidth > 0) || !(cssHeight > 0)) return;
    if (!(dpr > 0) || !Number.isFinite(dpr)) return;
    this.cssW = cssWidth;
    this.cssH = cssHeight;
    this.dpr = dpr;
    this.apply();
  }

  setScaleMode(m: UiScaleModeValue): void {
    this.scaleMode = m;
    this.apply();
  }

  setSafeArea(insets: Insets): void {
    this.safe = insets;
  }

  /** 绘制像素尺寸（= CSS 像素 × dpr）。`makeCamera` 用它设 viewport。 */
  get pixelWidth(): number {
    return this.cssW * this.dpr;
  }
  get pixelHeight(): number {
    return this.cssH * this.dpr;
  }

  /** 一个设计像素对应多少**绘制**像素。 */
  get scale(): number {
    return this.scaleValue;
  }

  /** 设计框本身（恒为原点起始）。 */
  get designRect(): Rect {
    return new Rect(0, 0, this.designWidth, this.designHeight);
  }

  /**
   * 屏幕在设计坐标系里覆盖的范围。
   * `fit` 时比设计框**大**（每边留黑边），`fill`/`expand` 时可能比设计框小（裁边）。
   */
  get screenRect(): Rect {
    const w = this.cssW / this.scaleValue;
    const h = this.cssH / this.scaleValue;
    return new Rect((this.designWidth - w) / 2, (this.designHeight - h) / 2, w, h);
  }

  /**
   * **锚点参考矩形**：`anchor` 为 0/0.5/1 时贴的是这条边。
   *
   * · `fit` / `fill` 贴**设计框**（内容不越界，这是"设计分辨率"的语义）
   * · `expand`       贴**屏幕范围**（多出来的区域也算可用，HUD 贴屏幕边）
   *
   * ★ 只有 `expand` 的参考区比设计框**大**（因为它用 min 缩放，另一个轴必然多出来），
   *   所以"贴屏幕左上的血条在超宽屏上不会被裁出屏幕"这条只有它成立。
   */
  get anchorRect(): Rect {
    if (this.scaleMode === UiScaleMode.Expand) return this.screenRect;
    return this.designRect;
  }

  /** 锚点参考矩形扣掉安全区。刘海屏上的可点区域用它。 */
  get safeRect(): Rect {
    const r = this.anchorRect;
    const top = Math.min(this.safe.top, r.height / 2);
    const bottom = Math.min(this.safe.bottom, r.height / 2 - top);
    const left = Math.min(this.safe.left, r.width / 2);
    const right = Math.min(this.safe.right, r.width / 2 - left);
    return new Rect(r.x + left, r.y + top, r.width - left - right, r.height - top - bottom);
  }

  /** CSS 像素 → 设计坐标。 */
  screenToDesign(px: number, py: number): { x: number; y: number } {
    return {
      x: this.designWidth / 2 + (px - this.cssW / 2) / this.scaleValue,
      y: this.designHeight / 2 + (py - this.cssH / 2) / this.scaleValue,
    };
  }

  /** 设计坐标 → CSS 像素。 */
  designToScreen(x: number, y: number): { x: number; y: number } {
    return {
      x: this.cssW / 2 + (x - this.designWidth / 2) * this.scaleValue,
      y: this.cssH / 2 + (y - this.designHeight / 2) * this.scaleValue,
    };
  }

  /**
   * 与 2.5D 场景**共用**的相机对象（`Camera2D` 只是一条投影函数，谁都能拿一个）。
   * UI 相机的世界单位 = 设计像素，所以 `zoom = scale`、`tiltY = 1`。
   */
  get camera(): Camera2D {
    return this.cam;
  }

  private apply(): void {
    const pw = this.pixelWidth;
    const ph = this.pixelHeight;
    const sx = pw / this.designWidth;
    const sy = ph / this.designHeight;
    // ★ 缩放只由模式决定：fill 铺满（max），fit / expand 保证整框可见（min）。
    //   expand 与 fit 的差别**不在缩放**，而在锚点参考矩形（见 `anchorRect`）。
    this.scaleValue =
      this.scaleMode === UiScaleMode.Fill ? Math.max(sx, sy) : Math.min(sx, sy);
    if (!(this.scaleValue > 0) || !Number.isFinite(this.scaleValue)) this.scaleValue = 1;
    this.cam.setViewport(pw, ph);
    this.cam.zoom = this.scaleValue;
    this.cam.tiltY = 1;
    // ★ UI 的设计坐标是**屏幕式**的（y 向下增长：Rect 左上原点、Column 往下堆），
    //   而相机默认的 z 轴向上。不打开这个开关，整棵界面会被**上下镜像**画出来：
    //   顶部 HUD 跑到屏幕底、底部提示条跑到顶部、列表行倒序 ——
    //   而四边形数/字形数/颜色/UV 全对，只有位置反了（批115 像素判据抓到）。
    this.cam.yDown = true;
    // 相机看设计框中心：于是设计坐标 (0,0) 在 fit 下落在黑边内侧，
    // 在 fill 下落在屏幕外 —— 这正好与 anchorRect 的语义对应。
    this.cam.moveTo(this.designWidth / 2, this.designHeight / 2);
  }
}
