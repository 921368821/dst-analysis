/**
 * L0 · 二维 / 三维向量
 *
 * 设计取舍（写在这里，避免后人以为是没优化）：
 * - **不可变**：所有运算返回新实例。2.5D 引擎的数学开销集中在"每帧几百个精灵的
 *   矩阵合成"，那部分是 typed array 直写（见 `gfx` 层的批量提交），不走这里。
 *   用不可变换来"没有别名 bug"——上一代代码里 `e.x = e.x` 这种就地修改
 *   让"撤销移动"写出过错误的 before 值。
 * - 不用 `Float32Array` 单例的 builder 模式：那需要调用方管理生命周期，
 *   在脚本层（Lua/JS 双向）特别容易泄漏。
 */

export class Vec2 {
  static readonly zero = new Vec2(0, 0);
  static readonly one = new Vec2(1, 1);
  static readonly up = new Vec2(0, 1);
  static readonly right = new Vec2(1, 0);

  constructor(
    readonly x: number,
    readonly y: number,
  ) {}

  add(v: Vec2): Vec2 {
    return new Vec2(this.x + v.x, this.y + v.y);
  }

  sub(v: Vec2): Vec2 {
    return new Vec2(this.x - v.x, this.y - v.y);
  }

  scale(s: number): Vec2 {
    return new Vec2(this.x * s, this.y * s);
  }

  dot(v: Vec2): number {
    return this.x * v.x + this.y * v.y;
  }

  /** 二维叉积（标量），用于判定左右与三角形朝向。 */
  cross(v: Vec2): number {
    return this.x * v.y - this.y * v.x;
  }

  get lengthSq(): number {
    return this.x * this.x + this.y * this.y;
  }

  get length(): number {
    return Math.sqrt(this.lengthSq);
  }

  /** 零向量归一化返回零向量，不产生 NaN。 */
  normalized(): Vec2 {
    const l = this.length;
    return l > 0 ? new Vec2(this.x / l, this.y / l) : Vec2.zero;
  }

  equals(v: Vec2, eps = 0): boolean {
    return Math.abs(this.x - v.x) <= eps && Math.abs(this.y - v.y) <= eps;
  }

  toString(): string {
    return `(${this.x}, ${this.y})`;
  }
}

export class Vec3 {
  static readonly zero = new Vec3(0, 0, 0);
  static readonly one = new Vec3(1, 1, 1);

  constructor(
    readonly x: number,
    readonly y: number,
    readonly z: number,
  ) {}

  add(v: Vec3): Vec3 {
    return new Vec3(this.x + v.x, this.y + v.y, this.z + v.z);
  }

  sub(v: Vec3): Vec3 {
    return new Vec3(this.x - v.x, this.y - v.y, this.z - v.z);
  }

  scale(s: number): Vec3 {
    return new Vec3(this.x * s, this.y * s, this.z * s);
  }

  dot(v: Vec3): number {
    return this.x * v.x + this.y * v.y + this.z * v.z;
  }

  cross(v: Vec3): Vec3 {
    return new Vec3(
      this.y * v.z - this.z * v.y,
      this.z * v.x - this.x * v.z,
      this.x * v.y - this.y * v.x,
    );
  }

  get lengthSq(): number {
    return this.x * this.x + this.y * this.y + this.z * this.z;
  }

  get length(): number {
    return Math.sqrt(this.lengthSq);
  }

  normalized(): Vec3 {
    const l = this.length;
    return l > 0 ? new Vec3(this.x / l, this.y / l, this.z / l) : Vec3.zero;
  }

  /** 取 XZ 平面（2.5D 里"地面"就是 XZ）。 */
  toXZ(): Vec2 {
    return new Vec2(this.x, this.z);
  }

  toString(): string {
    return `(${this.x}, ${this.y}, ${this.z})`;
  }
}
