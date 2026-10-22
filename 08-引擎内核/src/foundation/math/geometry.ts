/**
 * L0 · 矩形 / 颜色 / 二维仿射
 *
 * 都是不可变值对象。命名与语义**刻意对齐 Unity**（`Rect.xMin` / `Color.r`
 * 这些名字是行业习惯，改了只会增加阅读成本）。
 */

import { Vec2 } from "./vec.ts";

export class Rect {
  static readonly zero = new Rect(0, 0, 0, 0);

  constructor(
    readonly x: number,
    readonly y: number,
    readonly width: number,
    readonly height: number,
  ) {}

  get xMin(): number {
    return this.x;
  }
  get yMin(): number {
    return this.y;
  }
  get xMax(): number {
    return this.x + this.width;
  }
  get yMax(): number {
    return this.y + this.height;
  }

  get center(): Vec2 {
    return new Vec2(this.x + this.width / 2, this.y + this.height / 2);
  }

  contains(p: Vec2): boolean {
    return p.x >= this.xMin && p.x <= this.xMax && p.y >= this.yMin && p.y <= this.yMax;
  }

  /** 相交判定用 `<` 而非 `<=`：贴边不算重叠（与 SAT 的严格内部分离一致）。 */
  intersects(o: Rect): boolean {
    return this.xMin < o.xMax && this.xMax > o.xMin && this.yMin < o.yMax && this.yMax > o.yMin;
  }

  intersect(o: Rect): Rect {
    const x0 = Math.max(this.xMin, o.xMin);
    const y0 = Math.max(this.yMin, o.yMin);
    const x1 = Math.min(this.xMax, o.xMax);
    const y1 = Math.min(this.yMax, o.yMax);
    return new Rect(x0, y0, Math.max(0, x1 - x0), Math.max(0, y1 - y0));
  }

  expand(by: number): Rect {
    return new Rect(this.x - by, this.y - by, this.width + by * 2, this.height + by * 2);
  }
}

export class Color {
  static readonly white = new Color(1, 1, 1, 1);
  static readonly black = new Color(0, 0, 0, 1);
  static readonly transparent = new Color(0, 0, 0, 0);

  constructor(
    readonly r: number,
    readonly g: number,
    readonly b: number,
    readonly a: number = 1,
  ) {}

  /** `0xRRGGBBAA` → Color。资产文件里用得多。 */
  static fromRgba8(rgba: number): Color {
    return new Color(
      ((rgba >>> 24) & 0xff) / 255,
      ((rgba >>> 16) & 0xff) / 255,
      ((rgba >>> 8) & 0xff) / 255,
      (rgba & 0xff) / 255,
    );
  }

  toArray(): [number, number, number, number] {
    return [this.r, this.g, this.b, this.a];
  }
}

/**
 * 2D 仿射变换（平移 + 旋转 + 缩放），**列主序** 3×3 的左上 2×3 部分。
 *
 * 存 6 个数：`[m00, m01, m02, m10, m11, m12]`，即
 *   | m00 m01 m02 |   作用在 (x, y, 1)
 *   | m10 m11 m12 |
 * 与 WebGL 的 `uniformMatrix3fv`（9 元素列主序）转换在 gfx 层做 —— 这里保持
 * 2×3 的理由：2D 用不到第三行，多存 3 个数只增加出错面。
 */
export class Affine2 {
  static readonly identity = new Affine2(1, 0, 0, 0, 1, 0);

  constructor(
    readonly m00: number,
    readonly m01: number,
    readonly m02: number,
    readonly m10: number,
    readonly m11: number,
    readonly m12: number,
  ) {}

  static fromTrs(pos: Vec2, rotationRad: number, scale: Vec2): Affine2 {
    const c = Math.cos(rotationRad);
    const s = Math.sin(rotationRad);
    // 旋转 × 缩放
    return new Affine2(c * scale.x, -s * scale.y, pos.x, s * scale.x, c * scale.y, pos.y);
  }

  /** this ∘ o（先应用 o，再应用 this）—— 与父子变换的语义一致。 */
  multiply(o: Affine2): Affine2 {
    return new Affine2(
      this.m00 * o.m00 + this.m01 * o.m10,
      this.m00 * o.m01 + this.m01 * o.m11,
      this.m00 * o.m02 + this.m01 * o.m12 + this.m02,
      this.m10 * o.m00 + this.m11 * o.m10,
      this.m10 * o.m01 + this.m11 * o.m11,
      this.m10 * o.m02 + this.m11 * o.m12 + this.m12,
    );
  }

  transformPoint(p: Vec2): Vec2 {
    return new Vec2(
      this.m00 * p.x + this.m01 * p.y + this.m02,
      this.m10 * p.x + this.m11 * p.y + this.m12,
    );
  }

  /** 展开成 WebGL 需要的 9 元素列主序数组。 */
  toMat3Array(out?: Float32Array): Float32Array {
    const m = out ?? new Float32Array(9);
    m[0] = this.m00;
    m[1] = this.m10;
    m[2] = 0;
    m[3] = this.m01;
    m[4] = this.m11;
    m[5] = 0;
    m[6] = this.m02;
    m[7] = this.m12;
    m[8] = 1;
    return m;
  }

  equals(o: Affine2, eps = 1e-9): boolean {
    return (
      Math.abs(this.m00 - o.m00) <= eps &&
      Math.abs(this.m01 - o.m01) <= eps &&
      Math.abs(this.m02 - o.m02) <= eps &&
      Math.abs(this.m10 - o.m10) <= eps &&
      Math.abs(this.m11 - o.m11) <= eps &&
      Math.abs(this.m12 - o.m12) <= eps
    );
  }
}
