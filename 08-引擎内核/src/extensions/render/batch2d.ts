/**
 * L4 · 2D 精灵批处理
 *
 * 做两件事：**排序**（决定谁盖住谁）与**组装顶点**（把 N 个精灵塞进一个 buffer）。
 *
 * ★★ 排序键的优先级是有理由的，不要随意交换：
 *
 *   1. **z 降序**（远的先画）—— 遮挡正确性优先。z 是"离镜头多远"，
 *      2.5D 里它就是位置的性质，所以这条永远不能被"为了减少纹理切换"而牺牲。
 *   2. `order` 升序 —— 同 z 的手动微调（一排树里谁在前面）。
 *   3. `atlas` 升序 —— **同 z 内**把同图集的排在一起（减少切换，且不破坏遮挡）。
 *   4. `nodeId` 升序 —— 最终 tiebreak。**必须有**：没有它，同 z 同 order 的两个
 *      精灵的顺序取决于数组顺序，而数组顺序取决于创建顺序 ⇒ 画面会"闪"
 *      （上一代引擎在帧序上踩过同一个坑，那次是"远的挡住近的"，更难查）。
 *
 *   注意：跨 z 的纹理切换**不做**优化。因为"先画完所有 A 图再画 B 图"
 *   会让 B 图里 z 更小的精灵盖住 A 图里 z 更大的 —— 那是**错**。
 *   正确性优先于 draw call 数量，这是 2D 引擎最常被搞反的一条。
 *
 * ★ UV 的 v 轴翻转：图集像素数组是 PNG 风格（原点左上），
 *   而 GL 的纹理坐标 v=0 在**底部**。所以生成 UV 时要 `1 - v`。
 *   写死在这里的理由：它是"像素数组约定"与"GL 约定"之间的唯一转换点，
 *   放到别处就会有两处各翻一次（= 不翻）。
 */

import type { Camera2D } from "./camera.ts";

export interface RenderItem {
  readonly nodeId: number;
  readonly x: number;
  readonly z: number;
  readonly w: number;
  readonly h: number;
  readonly u0: number;
  readonly v0: number;
  readonly u1: number;
  readonly v1: number;
  readonly r: number;
  readonly g: number;
  readonly b: number;
  readonly a: number;
  readonly order: number;
  /** 0 = 底边贴地，0.5 = 中心。 */
  readonly pivotY: number;
  /** 图集槽位（渲染模块分配，同槽位 = 同一张纹理）。 */
  readonly atlas: number;
}

export interface BatchBuildResult {
  readonly quadCount: number;
  readonly vertexCount: number;
  readonly indexCount: number;
  /** 本次需要几次 draw（受 maxQuads 与纹理切换限制）。 */
  readonly drawCalls: number;
  /** 实际提交的图集槽位顺序（诊断：纹理切换次数）。 */
  readonly atlasSwitches: number;
}

const FLOATS_PER_VERTEX = 8;

export class SpriteBatch {
  readonly maxQuads: number;
  readonly vertices: Float32Array;
  readonly indices: Uint16Array;
  /** 排好序之后的 items（判据可以直接读它验证顺序）。 */
  items: RenderItem[] = [];

  constructor(maxQuads = 4096) {
    if (!(maxQuads > 0)) throw new RangeError("maxQuads 必须 > 0");
    // Uint16 索引上限 65536 个顶点 = 16384 个 quad
    if (maxQuads * 4 > 65536) {
      throw new RangeError(`maxQuads=${maxQuads} 超过 Uint16 索引上限（最多 16384）`);
    }
    this.maxQuads = maxQuads;
    this.vertices = new Float32Array(maxQuads * 4 * FLOATS_PER_VERTEX);
    this.indices = new Uint16Array(maxQuads * 6);
    // 索引只建一次：每个 quad 的两个三角形，顶点序固定
    for (let q = 0; q < maxQuads; q++) {
      const v = q * 4;
      const i = q * 6;
      this.indices[i] = v;
      this.indices[i + 1] = v + 1;
      this.indices[i + 2] = v + 2;
      this.indices[i + 3] = v;
      this.indices[i + 4] = v + 2;
      this.indices[i + 5] = v + 3;
    }
  }

  /**
   * 排序（原地）。规则见文件头。
   * ★ 用**显式比较函数**而不是 `Array.sort` 的默认行为：默认会把数字转字符串，
   *   而 `[10, 9]` 会排成 `[10, 9]`（字符串 "10" < "9"）—— 这类 bug 极难发现。
   */
  static sort(items: RenderItem[]): void {
    items.sort((a, b) => {
      if (a.z !== b.z) return b.z - a.z; // 远的先画
      if (a.order !== b.order) return a.order - b.order;
      if (a.atlas !== b.atlas) return a.atlas - b.atlas;
      return a.nodeId - b.nodeId;
    });
  }

  /**
   * 组装顶点。返回实际写入的 quad 数（可能被 `maxQuads` 截断）。
   * ★ 截断必须**被报告**：调用方据此决定要不要再开一批。
   *   静默截断的症状是"东西画到某个数量就不见了"，而且只在实体多的场景出现。
   */
  build(items: readonly RenderItem[], cam: Camera2D): BatchBuildResult {
    const sorted = [...items];
    SpriteBatch.sort(sorted);
    this.items = sorted;

    const n = Math.min(sorted.length, this.maxQuads);
    let atlasSwitches = 0;
    let lastAtlas = -1;

    for (let q = 0; q < n; q++) {
      const it = sorted[q]!;
      if (it.atlas !== lastAtlas) {
        atlasSwitches++;
        lastAtlas = it.atlas;
      }
      const c = cam.project(it.x, it.z);
      const e = cam.extents(it.w, it.h);
      // pivot：0 = 底边，所以中心要往上抬半个高度
      const cy = c.y + (0.5 - it.pivotY) * 2 * e.halfH;
      const x0 = c.x - e.halfW;
      const x1 = c.x + e.halfW;
      const y0 = cy - e.halfH;
      const y1 = cy + e.halfH;

      // ★ v 轴翻转（见文件头）：像素数组原点在左上，GL 的 v=0 在底部
      const va = 1 - it.v0; // 图集顶部
      const vb = 1 - it.v1; // 图集底部

      const base = q * 4 * FLOATS_PER_VERTEX;
      // 左下
      writeVert(this.vertices, base, x0, y0, it.u0, vb, it);
      // 右下
      writeVert(this.vertices, base + FLOATS_PER_VERTEX, x1, y0, it.u1, vb, it);
      // 右上
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 2, x1, y1, it.u1, va, it);
      // 左上
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 3, x0, y1, it.u0, va, it);
    }

    return {
      quadCount: n,
      vertexCount: n * 4,
      indexCount: n * 6,
      drawCalls: n === 0 ? 0 : 1,
      atlasSwitches,
    };
  }

  /** 零拷贝视图：只把前 `quadCount` 个顶点交给 GPU（避免每帧上传满 buffer）。 */
  vertexView(quadCount: number): Float32Array {
    return this.vertices.subarray(0, quadCount * 4 * FLOATS_PER_VERTEX);
  }

  indexView(quadCount: number): Uint16Array {
    return this.indices.subarray(0, quadCount * 6);
  }
}

function writeVert(
  out: Float32Array,
  at: number,
  x: number,
  y: number,
  u: number,
  v: number,
  it: RenderItem,
): void {
  out[at] = x;
  out[at + 1] = y;
  out[at + 2] = u;
  out[at + 3] = v;
  out[at + 4] = it.r;
  out[at + 5] = it.g;
  out[at + 6] = it.b;
  out[at + 7] = it.a;
}
