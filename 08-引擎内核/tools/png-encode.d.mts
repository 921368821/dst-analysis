/**
 * 工具层类型声明：`tools/png-encode.mjs` 供测试直接使用。
 *
 * 为什么让测试依赖 tools 里的编码器：Adam7 的正确性必须覆盖**所有尺寸的 pass 组合**
 * （某个 pass 宽度为 0、sub-byte 行末补位、1×1 只有 pass 1），
 * 逐个写死 fixtures 会让仓库里堆几百个几十字节的 PNG，而矩阵化生成更清楚。
 * 这个 mjs 只依赖 node:zlib，是仓库内的纯工具，不是第三方包。
 */

export interface EncodePngSpec {
  readonly width: number;
  readonly height: number;
  readonly colorType: number;
  readonly bitDepth: number;
  readonly samples: readonly number[];
  readonly interlace?: number;
  readonly filter?: number;
  readonly palette?: readonly number[];
  readonly trns?: readonly number[];
  readonly idatCount?: number;
}

export interface ApngFrameSpec {
  readonly rect: { readonly x: number; readonly y: number; readonly width: number; readonly height: number };
  readonly rgba: Uint8Array;
  readonly delayNum: number;
  readonly delayDen: number;
  readonly dispose: number;
  readonly blend: number;
}

export interface EncodeApngSpec {
  readonly width: number;
  readonly height: number;
  readonly loopCount: number;
  readonly frames: readonly ApngFrameSpec[];
  readonly idatFirstFrame?: boolean;
}

export function encodePng(spec: EncodePngSpec): Buffer;
export function encodeApng(spec: EncodeApngSpec): Buffer;
export const SIGNATURE: Buffer;
