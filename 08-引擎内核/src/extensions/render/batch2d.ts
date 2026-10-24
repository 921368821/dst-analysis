/**
 * L4 · 2D 精灵批处理
 *
 * 做两件事：**排序**（决定谁盖住谁）与**组装顶点**（把 N 个精灵塞进一个 buffer）。
 *
 * ★★ 排序键的优先级是有理由的，不要随意交换：
 *
 *   0. **layer 升序**（背景先画）—— 分层高于深度。0 = 地面，1 = 实体。
 *      这不是 draw call 优化：地面之间不重叠、实体永远该盖住地面，而 z 是
 *      "格子坐标"（地形取矩形左上角、实体取格子中心），两类混排必然交错 ——
 *      不分层的话一块地形会盖住站在它上面的角色，draw 也会被 z 序打散成几十段。
 *      跨层的纹理切换因此**允许**，跨 z 的不允许（见下）。
 *   1. **z 降序**（远的先画）—— 遮挡正确性优先。z 是"离镜头多远"，
 *      2.5D 里它就是位置的性质，所以这条永远不能被"为了减少纹理切换"而牺牲。
 *   2. `order` 升序 —— 同 z 的手动微调（一排树里谁在前面）。
 *   3. `atlas` 升序 —— **同 z 内**把同图集的排在一起（减少切换，且不破坏遮挡）。
 *   4. `nodeId` 升序 —— 最终 tiebreak。**必须有**：没有它，同 z 同 order 的两个
 *      精灵的顺序取决于数组顺序，而数组顺序取决于创建顺序 ⇒ 画面会"闪"
 *      （上一代引擎在帧序上踩过同一个坑，那次是"远的挡住近的"，更难查）。
 *
 *   注意：跨 z 的纹理切换**不做**优化。因为"先画完所有 A 图再画 B 图"
 *   会让 B 图里 z 更小的精灵盖住 A 图里 z 更大的 —— 那是**错**的。
 *   正确性优先于 draw call 数量，这是 2D 引擎最常被搞反的一条。
 *
 * ★★ UV 的 v 轴**不翻转**（T330 的根因，一行错、全世界矮帧消失）：
 *
 *   正确的事实链：图集像素数组是行主序、第一行是图片顶部（PNG 约定）；
 *   `texImage2D` 收 `ArrayBufferView` 时，**数组的第一行就是纹理的 v=0 那一行**
 *   （WebGL 规范：源数据的第一个像素落在纹理坐标原点）。
 *   两条合起来 ⇒ **v 就是"行号 / 高度"**，天然与像素数组同向，不需要任何转换。
 *
 *   错的版本（这里长期写着）把"GL 的 v=0 在底部"当成了"v=0 是图片底部"——
 *   这两句不是一回事：v=0 是**纹理空间的底**，但数据的第一行（图片顶）被放在那儿。
 *   于是 `1 - v` 把每一帧镜像到图集的另一半去采样。它的坏形状取决于帧高：
 *   · 帧高 = 图集高（v 占满 0..1）⇒ 镜像到自身，看不出来；
 *   · 帧高 96 / 图集高 128 ⇒ 只有 2/3 采样落在内容上（地形是均匀噪声，看不出来）；
 *   · 帧高 ≤ 图集高的一半 ⇒ 采样区间整个落到空白 padding，**帧彻底消失**。
 *   同一张图集里有的帧能画、有的画不出来，就是这么来的（不是资产问题）。
 *
 *   ★ 这条曲线说明为什么它藏了那么久：错的不是"翻转"，是**翻转的依据**；
 *   而它只在"帧高 < 图集高一半"时才有肉眼可见的症状。写死在这里仍然对 ——
 *   它是"像素数组约定"与"纹理约定"之间的唯一转换点，只是转换系数是**恒等**。
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
  /**
   * 绘制层：0 = 背景（地面），1 = 实体。排序键的**第一**优先级（高于 z）。
   * 缺省当 1（旧内容 / 手搓的 RenderItem 不能因此掉到地形背后）。
   */
  readonly layer?: number;
  /** 0 = 底边贴地，0.5 = 中心。 */
  readonly pivotY: number;
  /** 0 = 左边界贴住节点 x，0.5 = 水平居中。矩形（地形）用 0。 */
  readonly pivotX: number;
  /** 图集槽位（渲染模块分配，同槽位 = 同一张纹理）。 */
  readonly atlas: number;
  /** 沿宽重复贴图次数（默认 1 = 不重复；T288）。只能是正整数。 */
  readonly tileX?: number;
  /** 沿高重复贴图次数（默认 1 = 不重复；T288）。只能是正整数。 */
  readonly tileY?: number;
}

/** 一段**连续同槽位**的 quad（一次 draw 的最小单位）。 */
export interface BatchRun {
  readonly atlas: number;
  /** 在排好序的 items 里的起始下标。 */
  readonly start: number;
  /** 这一段有多少个 quad。 */
  readonly count: number;
}

export interface BatchBuildResult {
  readonly quadCount: number;
  readonly vertexCount: number;
  readonly indexCount: number;
  /** 本次需要几次 draw（= 连续同槽位的段数，另受 maxQuads 限制）。 */
  readonly drawCalls: number;
  /** 实际提交的图集槽位顺序（诊断：纹理切换次数）。 */
  readonly atlasSwitches: number;
  /**
   * 连续同槽位的段（T288 多页之后才有意义）。
   *
   * ★ 为什么要暴露段而不是只给次数：调用方要按段**绑定不同纹理**再 draw。
   *   只给次数的话，调用方只能自己重算一遍分段 —— 而那正是"两边各算一遍、
   *   哪天对不上"的经典形状（本项目在输入映射上刚踩过）。
   */
  readonly runs: readonly BatchRun[];
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
   * ★ `?? 1`：缺 layer 的 RenderItem 当实体。0 是背景，把旧数据默认成背景
   *   会让所有东西一夜之间消失在地形后面 —— 与 Sprite 的默认值同思路。
   */
  static sort(items: RenderItem[]): void {
    items.sort((a, b) => {
      const la = a.layer ?? 1;
      const lb = b.layer ?? 1;
      if (la !== lb) return la - lb; // 背景先画
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
    // 分段用可变数组累积，返回时按只读类型交出去（避免在循环里反复改写只读对象）
    const runsMut: Array<{ atlas: number; start: number; count: number }> = [];

    for (let q = 0; q < n; q++) {
      const it = sorted[q]!;
      if (it.atlas !== lastAtlas) {
        atlasSwitches++;
        lastAtlas = it.atlas;
        // ★ 只在"换槽位"时开新段。同槽位被 z 序打散时会出现多段同槽位 ——
        //   那是正确的代价（见文件头：正确性优先于 draw call 数量）。
        runsMut.push({ atlas: it.atlas, start: q, count: 1 });
      } else {
        const prev = runsMut[runsMut.length - 1];
        if (prev === undefined) throw new Error("batch2d 内部错误：第一段没建起来");
        prev.count++;
      }
      const c = cam.project(it.x, it.z);
      const e = cam.extents(it.w, it.h);
      // pivot：0 = 底边 / 左边界，所以中心要往上抬半个高度、往右移半个宽度。
      // ★ 两轴的符号必须同向：`0.5 - pivot` 为正 ⇒ 中心上/右移。
      //   写成 (pivot - 0.5) 会让 pivotY=0（脚踩地面）变成"陷进地里一整格"，
      //   而这种错法在 pivot=0.5 的内容上完全看不出来（对称中心不动）。
      const cy = c.y + (0.5 - it.pivotY) * 2 * e.halfH;
      const cx = c.x + (0.5 - it.pivotX) * 2 * e.halfW;
      const x0 = cx - e.halfW;
      const x1 = cx + e.halfW;
      const y0 = cy - e.halfH;
      const y1 = cy + e.halfH;

      // ★ T288 平铺：UV 沿帧的宽/高**重复** tileX/tileY 次。
      //   帧矩形 [u0,u1] 是这一页里的位置；重复意味着"再往右/往下接同样的宽度"。
      //   注意是**加**不是乘：u0 是帧的左边界（瓦片页上恒为 0），
      //   直接 `u0 * tileX` 会把帧起点也放大，那是另一种错（画面整体偏移一帧）。
      const tileX = Math.max(1, Math.floor(it.tileX ?? 1));
      const tileY = Math.max(1, Math.floor(it.tileY ?? 1));
      const ua = it.u0;
      const ub = it.u0 + (it.u1 - it.u0) * tileX;
      const va = it.v0;
      const vb = it.v0 + (it.v1 - it.v0) * tileY;

      // ★ v 轴恒等映射（见文件头 T330）：像素数组第一行 = 纹理 v=0 那一行。
      //   帧的顶边 `va` 给四边形的上两个顶点，底边 `vb` 给下两个顶点。
      const base = q * 4 * FLOATS_PER_VERTEX;
      // 左下
      writeVert(this.vertices, base, x0, y0, ua, vb, it);
      // 右下
      writeVert(this.vertices, base + FLOATS_PER_VERTEX, x1, y0, ub, vb, it);
      // 右上
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 2, x1, y1, ub, va, it);
      // 左上
      writeVert(this.vertices, base + FLOATS_PER_VERTEX * 3, x0, y1, ua, va, it);
    }

    return {
      quadCount: n,
      vertexCount: n * 4,
      indexCount: n * 6,
      drawCalls: runsMut.length,
      atlasSwitches,
      runs: runsMut,
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
