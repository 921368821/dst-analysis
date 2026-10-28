/**
 * L4 · 2.5D 正交相机
 *
 * 「2.5D 斜俯视」在这里被定义为**一个投影函数**，而不是一堆特判：
 *
 *   屏幕 x = (世界 x - 相机 x) × zoom
 *   屏幕 y = (世界 z - 相机 z) × zoom × tiltY
 *
 * `tiltY` 是"俯视角度的压缩比"：1.0 = 正俯视（纯 2D），0.5~0.65 = 常见斜俯视。
 * 饥荒大约在 0.6 左右。压缩只作用于**视觉**，不作用于逻辑坐标 ——
 * 所以碰撞、AI 距离都在**未压缩的 XZ 平面**上算（这也解释了为什么
 * 「看起来很近」和「实际上很近」在 2.5D 里不是一回事，判据只能用逻辑坐标）。
 *
 * ★ 为什么投影在 CPU 侧做（而不是传一个 mat3 给着色器）：
 *   2D 只需要 2×3 仿射，CPU 一次性算完比每顶点一次 mat3 乘更快；
 *   而深度排序（z 降序）本来就必须在 CPU 做，投影跟着算没有额外成本。
 *   代价是"着色器极简"—— 换后端时最难移植的矩阵约定不存在。
 */

import { Color } from "../../foundation/math/index.ts";

export interface CameraConfig {
  readonly viewportWidth: number;
  readonly viewportHeight: number;
  /** 缩放：1 = 世界单位映射到（垂直半屏 / tiltY）。 */
  readonly zoom?: number;
  /** 斜俯视压缩比（0.3~1.0）。逻辑不受影响。 */
  readonly tiltY?: number;
  readonly x?: number;
  readonly z?: number;
  readonly clearColor?: Color;
}

export class Camera2D {
  vw: number;
  vh: number;
  zoom: number;
  tiltY: number;
  x: number;
  z: number;
  clearColor: Color;
  /**
   * y 轴方向：`false`（默认）= 世界约定，**z 越大越靠上**；
   * `true` = 界面约定，**y 越大越靠下**（屏幕坐标，左上原点）。
   *
   * ★ 为什么需要它（批115 抓到的真缺陷）：UI 的设计坐标是**屏幕式**的
   *   （`Rect` 从左上角起、Column 从 `inner.y` 往下累加），而 `project` 的
   *   世界约定是 z 向上。UI 把设计 y 当 z 传进来，于是整棵树被**上下镜像**：
   *   布局在顶部的 HUD 画到了屏幕底部、贴在底部的提示条画到了顶部、
   *   背包的行从下往上排。四边形数、字形数、颜色、UV 全对，只是位置反了 ——
   *   `layout` 层的判据看不到（它们读的是布局矩形），只有像素级判据能抓。
   *
   * ★ 不把 `tiltY` 设成负数来"顺便翻转"：`tiltY` 同时进 `extents`，
   *   负值会把 quad 的高也翻成负的（UV 与角落的对应关系跟着反）⇒ 字变倒影。
   *   方向必须是投影**单独**的一条，不能借用缩放。
   *
   * ★ 拾取（`unproject`）跟着同一个开关走：输入与渲染必须用同一套 y 语义，
   *   否则"看到的位置"和"点到的东西"会差一个镜像 —— 那是最难查的一类错位。
   */
  yDown = false;
  /** 每世界单位有多少像素（x 方向）。UI 命中测试、像素对齐用。 */
  private _pxPerUnit = 1;

  constructor(cfg: CameraConfig) {
    if (!(cfg.viewportWidth > 0) || !(cfg.viewportHeight > 0)) {
      throw new RangeError(`视口尺寸必须 > 0：${cfg.viewportWidth}x${cfg.viewportHeight}`);
    }
    this.vw = cfg.viewportWidth;
    this.vh = cfg.viewportHeight;
    this.zoom = cfg.zoom ?? 32;
    this.tiltY = cfg.tiltY ?? 0.62;
    this.x = cfg.x ?? 0;
    this.z = cfg.z ?? 0;
    this.clearColor = cfg.clearColor ?? new Color(0.07, 0.08, 0.1, 1);
    this.recompute();
  }

  private recompute(): void {
    // zoom 的语义是"一世界单位 = zoom 像素"
    this._pxPerUnit = this.zoom;
  }

  get pxPerUnit(): number {
    return this._pxPerUnit;
  }

  setViewport(w: number, h: number): void {
    if (!(w > 0) || !(h > 0)) return;
    this.vw = w;
    this.vh = h;
  }

  /** 立刻移到（无平滑）。平滑跟随属于"控制器"的职责，不属于相机。 */
  moveTo(x: number, z: number): void {
    this.x = x;
    this.z = z;
  }

  /** 世界 (x,z) → 裁剪空间 (-1..1)。`yDown` 时 y 取反（见字段说明）。 */
  project(wx: number, wz: number): { x: number; y: number } {
    const sx = ((wx - this.x) * this.zoom) / (this.vw / 2);
    const sy = ((wz - this.z) * this.zoom * this.tiltY) / (this.vh / 2);
    return { x: sx, y: this.yDown ? -sy : sy };
  }

  /** 世界尺寸 → 裁剪空间半宽/半高（精灵用）。 */
  extents(worldW: number, worldH: number): { halfW: number; halfH: number } {
    return {
      halfW: (worldW * this.zoom) / this.vw,
      halfH: (worldH * this.zoom * this.tiltY) / this.vh,
    };
  }

  /** 屏幕像素 → 世界 XZ（拾取/点选用）。与 `project` 共用 `yDown` 语义。 */
  unproject(px: number, py: number): { x: number; z: number } {
    const nx = (px / this.vw) * 2 - 1;
    const ny = 1 - (py / this.vh) * 2;
    return {
      x: this.x + (nx * this.vw) / 2 / this.zoom,
      z: this.z + ((this.yDown ? -ny : ny) * this.vh) / 2 / (this.zoom * this.tiltY),
    };
  }

  /** 当前可见的世界矩形（裁剪用，也是"哪些实体该画"的粗筛）。 */
  visibleRect(): { xMin: number; xMax: number; zMin: number; zMax: number } {
    const halfW = this.vw / 2 / this.zoom;
    const halfH = this.vh / 2 / (this.zoom * this.tiltY);
    return {
      xMin: this.x - halfW,
      xMax: this.x + halfW,
      zMin: this.z - halfH,
      zMax: this.z + halfH,
    };
  }
}
