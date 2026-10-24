/**
 * L1 · 图形接口 · 描述符与句柄
 *
 * ★★ 这一层的三条硬规则（整个引擎的可移植性都压在这里）：
 *
 * ① **句柄是不透明的整数，不是对象**。
 *    调用方拿到 `TextureHandle = 7`，而不是一个 JS 对象。为什么：
 *      - 后端可以自由选择"真对象 / 索引 / wasm 里的裸指针"；
 *      - 调用方**无法**绕过设备去调后端的私有方法（一旦能调，抽象就漏了）；
 *      - 销毁后句柄可以整体失效（设备维护代际号），不会留下"半死对象"——
 *        上一代引擎的"删父后子实体 `_parent` 悬空"就是对象引用没被收走的典型。
 *    代价：多一次查表。相对于一次 draw call，可忽略。
 *
 * ② **创建返回 Result，不是抛异常**。
 *    着色器编译失败、纹理超限、显存不足都是**预期内**的运行时状况。
 *    上层要能降级（换低精度纹理 / 退回纯色块 / 关掉某个特效），而不是整块崩掉。
 *
 * ③ **接口里不出现任何 WebGL/DOM 类型**。
 *    `WebGL2RenderingContext`、`HTMLCanvasElement` 一个都不许出现在这里。
 *    判断标准很简单：把这份文件原样拷到 Node/原生/wasm 宿主里，它必须还能编译。
 *    （机器守护：`tests/arch/no-platform-leak.test.ts` 检查 L1 的 import 与类型引用。）
 */

import type { Color, Rect } from "../../foundation/math/index.ts";
import type { EngineError, Result } from "../../foundation/result.ts";

// ------------------------------------------------------------------ 句柄

declare const gfxBrand: unique symbol;
type Branded<T extends string> = number & { readonly [gfxBrand]: T };

export type BufferHandle = Branded<"Buffer">;
export type TextureHandle = Branded<"Texture">;
export type ShaderHandle = Branded<"Shader">;
export type PipelineHandle = Branded<"Pipeline">;
export type RenderTargetHandle = Branded<"RenderTarget">;

/** 0 号句柄在任何后端里都表示"无效"。设备创建出的句柄从 1 开始。 */
export const INVALID_HANDLE = 0 as Branded<"invalid">;

export type HandleKind = "buffer" | "texture" | "shader" | "pipeline" | "target";

// ------------------------------------------------------------------ 能力

/**
 * 设备能力。**上层只能依赖这里声明的东西**。
 * 想用某个特性前先查 caps，查不到就走降级路径 —— 不许 try/catch 探路。
 */
export interface DeviceCaps {
  readonly backend: string;
  readonly version: string;
  readonly maxTextureSize: number;
  readonly maxTextureUnits: number;
  /** 单次 draw 能提交的最大顶点数（批处理切分要用）。 */
  readonly maxVerticesPerDraw: number;
  readonly instancing: boolean;
  readonly floatTextures: boolean;
  /** 是否支持从渲染目标读回像素（离屏截图 / golden image 判据）。 */
  readonly readback: boolean;
  /** 是否支持 sRGB 纹理（否则颜色管线要自己做 gamma）。 */
  readonly srgbTextures: boolean;
}

// ------------------------------------------------------------------ 描述符

export const BufferUsage = {
  Vertex: 1,
  Index: 2,
  Uniform: 3,
} as const;
export type BufferUsageValue = (typeof BufferUsage)[keyof typeof BufferUsage];

export interface BufferDesc {
  readonly usage: BufferUsageValue;
  readonly byteLength: number;
  /** `true` 表示每帧整体重写（动态顶点缓冲）；`false` 表示一次上传不再变。 */
  readonly dynamic: boolean;
  readonly label?: string;
}

export const PixelFormat = {
  RGBA8: "rgba8",
  RGB8: "rgb8",
  R8: "r8",
  /**
   * 16 位无符号归一化，每通道 0..65535（8 字节/像素）。
   * 进 GPU 的类型是 `UNSIGNED_SHORT` + 归一化采样：片元里拿到的仍是 0..1 的 float，
   * 只是**中间精度**不再被 8 位截断（渐变/法线/高度图不会出带状色块）。
   *
   * ★ 字节序边界：`Uint16Array` 的内存布局是宿主字节序；WebGL 的
   *   `UNSIGNED_SHORT` 纹理同样按宿主字节序解释，所以「值数组 → texImage2D」
   *   不需要交换字节。反过来说，**不能**把 PNG 里的大端原始字节直接塞进来。
   */
  RGBA16: "rgba16",
  /** 半精度浮点（8 字节/像素）。上传时需要真正的 half 字节流，不能直传 Float32Array。 */
  RGBA16F: "rgba16f",
} as const;
export type PixelFormatValue = (typeof PixelFormat)[keyof typeof PixelFormat];

/**
 * 每像素字节数。**全仓库唯一一份映射**，所有后端都从这里取。
 *
 * ★ 为什么必须共享：这个仓库被"两份 FNV 实现各自漂移"坑过一次
 *   （见 `foundation/hash.ts` 文件头）。格式→字节数 是同一形状的东西：
 *   两份映射单看都没错，只在某个格式上分叉，而"格式/长度错了"在真后端上的
 *   表现是**静默错图**，不是报错。所以这里宁可让后端多一次函数调用。
 *
 * ★ 未知值抛错，不回落 4：回落会让"新加了格式却忘了登记"变成"按 RGBA8 上传"——
 *   那正是 webgl2 的 `glFormat()` 曾把 `RGBA16F` 静默当 RGBA8 的缺陷形状。
 *   类型上 `PixelFormatValue` 已穷尽，这里只拦运行时（外部字符串）穿透。
 */
export function bytesPerPixel(format: PixelFormatValue): number {
  switch (format) {
    case PixelFormat.RGBA8:
      return 4;
    case PixelFormat.RGB8:
      return 3;
    case PixelFormat.R8:
      return 1;
    case PixelFormat.RGBA16:
      return 8;
    case PixelFormat.RGBA16F:
      return 8;
    default:
      throw new Error(`未知 PixelFormat：${String(format)}（bytesPerPixel 没有默认值，不猜）`);
  }
}

export const TextureFilter = { Nearest: "nearest", Linear: "linear" } as const;
export type TextureFilterValue = (typeof TextureFilter)[keyof typeof TextureFilter];

export const TextureWrap = { Clamp: "clamp", Repeat: "repeat" } as const;
export type TextureWrapValue = (typeof TextureWrap)[keyof typeof TextureWrap];

export interface TextureDesc {
  readonly width: number;
  readonly height: number;
  readonly format?: PixelFormatValue;
  readonly filter?: TextureFilterValue;
  readonly wrap?: TextureWrapValue;
  readonly mipmaps?: boolean;
  /** 渲染目标纹理：不能被采样以外的方式写入。 */
  readonly renderTarget?: boolean;
  readonly label?: string;
}

/**
 * 顶点布局。**由引擎声明，而非后端约定**：
 * 2.5D 精灵的统一顶点格式是 `pos.xy + uv.xy + color.rgba`（8 个 float = 32 字节）。
 * 以后加"逐顶点光照值"就改这里，一处改、所有后端跟着改。
 */
export interface VertexAttribute {
  readonly name: string;
  readonly components: 1 | 2 | 3 | 4;
}
export interface VertexLayout {
  readonly attributes: readonly VertexAttribute[];
}

/** 引擎内唯一的标准精灵顶点布局。 */
export const SPRITE_VERTEX_LAYOUT: VertexLayout = {
  attributes: [
    { name: "a_position", components: 2 },
    { name: "a_uv", components: 2 },
    { name: "a_color", components: 4 },
  ],
};

export const FLOATS_PER_SPRITE_VERTEX = 8;

export interface ShaderDesc {
  /** 源码字符串。后端负责把它变成它自己的形式（GLSL/WGSL/SPIR-V）。 */
  readonly vertex: string;
  readonly fragment: string;
  readonly label?: string;
}

export const BlendMode = { None: 0, Alpha: 1, Additive: 2, Premultiplied: 3 } as const;
export type BlendModeValue = (typeof BlendMode)[keyof typeof BlendMode];

export const Topology = { Triangles: 0, TriangleStrip: 1 } as const;
export type TopologyValue = (typeof Topology)[keyof typeof Topology];

export interface PipelineDesc {
  readonly shader: ShaderHandle;
  readonly layout?: VertexLayout;
  readonly blend?: BlendModeValue;
  readonly topology?: TopologyValue;
  readonly label?: string;
}

export interface RenderTargetDesc {
  readonly color: TextureHandle;
  readonly label?: string;
}

export const ClearFlags = { Color: 1, Depth: 2, Stencil: 4 } as const;

/** 一次 draw 需要的全部状态（引擎侧填好，后端只管提交）。 */
export interface DrawBatch {
  readonly vertices: BufferHandle;
  readonly indices: BufferHandle | null;
  readonly vertexCount: number;
  /** 有索引时是索引个数，否则等于 vertexCount。 */
  readonly indexCount: number;
  readonly instanceCount?: number;
  readonly firstIndex?: number;
}

// ------------------------------------------------------------------ 统计

/**
 * 每帧统计。**是接口的一部分，不是可选调试附属品** ——
 * 性能判据要断言 draw call 数、批次数、纹理切换次数，否则"批处理生效了没有"
 * 只能靠肉眼。上一代引擎就是"看起来挺快"，但没人知道到底几个 draw call。
 */
export interface GfxStats {
  readonly frameIndex: number;
  readonly drawCalls: number;
  readonly verticesSubmitted: number;
  readonly textureBindings: number;
  readonly pipelineSwitches: number;
  readonly bytesUploaded: number;
}

export type UniformValue = number | readonly number[] | Float32Array;
export type UniformKind = "int" | "float";

export type GfxResult<T> = Result<T, EngineError>;
export type { Rect, Color };
