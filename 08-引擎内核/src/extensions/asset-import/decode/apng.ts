/**
 * L4 · 资产导入 · 解码 · APNG → 逐帧 RGBA8
 *
 * ★ 为什么 APNG 单独一个文件，而不是塞进 png.ts：
 *   PNG 与 APNG 共享的只有"块结构 + 单张扫描线解码"，这两件事都在 png.ts 里；
 *   APNG 多出来的是**一个状态机**：帧矩形、dispose_op、blend_op、前一帧快照。
 *   把状态机混进"一张图 → 一块像素"的函数里，会让 png.ts 的每条判据都得考虑帧。
 *   分开之后 png.ts 仍是"一个文件一张图"，APNG 是"多张图 + 画布操作"。
 *
 * ★ 三个容易错的地方，都在这里显式处理：
 *   ① **每帧是独立的 zlib 流**。IDAT（第一帧）与每个 fdAT 各自带自己的 zlib 头，
 *      不能把 fdAT 的字节拼到 IDAT 后面一起解 —— 那会得到"头一个流 + 垃圾"。
 *      fdAT 的前 4 字节是**序列号**，不是数据。
 *   ② **dispose 作用于"上一帧"**，而且 `PREVIOUS` 要恢复的是"上一帧绘制之前"的画布，
 *      所以每帧绘制前必须先存一份快照，而不是绘制后。
 *   ③ **blend=OVER 是非预乘 alpha 的 source-over**，不是简单覆盖。
 *      半透明像素叠加时，alpha 与颜色都要按公式重算；直接 copy 会让边缘出现黑边。
 *
 * ★ 循环次数 `num_plays`：0 表示无限循环（APNG 规范）。这里原样保留 0，
 *   不换成 Infinity —— 序列化时要能还原成 0。
 */

import type { EngineError, Result } from "../../../foundation/result.ts";
import { engineError, err, ok } from "../../../foundation/result.ts";
import type { Header } from "./png.ts";
import { PngErrorCode, decodeZlibImage, scanPng } from "./png.ts";

export const ApngDisposeOp = {
  /** 保留帧区域，下一帧可以在上面继续画。 */
  None: 0,
  /** 把帧区域清成全透明黑。 */
  Background: 1,
  /** 恢复成"本帧绘制之前"的画布。 */
  Previous: 2,
} as const;

export const ApngBlendOp = {
  /** 直接替换（含 alpha）。 */
  Source: 0,
  /** 标准 source-over 合成。 */
  Over: 1,
} as const;

export interface ApngRect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

export interface ApngFrame {
  readonly index: number;
  /** 该帧**绘制完成后的整幅画布**（RGBA8，画布大小，不是帧矩形）。 */
  readonly pixels: Uint8Array;
  /** 该帧在画布上的位置与大小。 */
  readonly rect: ApngRect;
  /** 显示时长（毫秒）。`delay_num/delay_den`，den=0 按 100 处理（APNG 规范）。 */
  readonly delayMs: number;
  readonly dispose: number;
  readonly blend: number;
}

export interface DecodedApng {
  readonly width: number;
  readonly height: number;
  /** acTL.num_plays；0 = 无限循环。 */
  readonly loopCount: number;
  readonly frames: readonly ApngFrame[];
}

export interface DecodeApngOptions {
  readonly maxBytes?: number;
  /** 帧数上限（防"声明一百万帧"的炸弹）。默认 4096。 */
  readonly maxFrames?: number;
  /** 只解前 N 帧（预览/缩略图用）。默认全部。 */
  readonly limit?: number;
}

const DEFAULT_MAX_BYTES = 256 * 1024 * 1024;
const DEFAULT_MAX_FRAMES = 4096;

function badApng(why: string, detail?: Record<string, unknown>): EngineError {
  return detail === undefined
    ? engineError(PngErrorCode.BadApng, why)
    : engineError(PngErrorCode.BadApng, why, detail);
}

function u32be(b: Uint8Array, at: number): number {
  return ((b[at]! << 24) | (b[at + 1]! << 16) | (b[at + 2]! << 8) | b[at + 3]!) >>> 0;
}

function u16be(b: Uint8Array, at: number): number {
  return (b[at]! << 8) | b[at + 1]!;
}

/** `fcTL` 的语义（APNG 规范 §5.3）。 */
interface FrameControl {
  readonly sequence: number;
  readonly rect: ApngRect;
  readonly delayNum: number;
  readonly delayDen: number;
  readonly dispose: number;
  readonly blend: number;
}

function readFcTL(bytes: Uint8Array, chunk: { dataStart: number; length: number }): Result<FrameControl, EngineError> {
  if (chunk.length !== 26) {
    return err(badApng(`fcTL 数据长度 ${chunk.length}（必须 26）`, { chunk: "fcTL" }));
  }
  const d = chunk.dataStart;
  const rect: ApngRect = {
    width: u32be(bytes, d + 4),
    height: u32be(bytes, d + 8),
    x: u32be(bytes, d + 12),
    y: u32be(bytes, d + 16),
  };
  const dispose = bytes[d + 24]!;
  const blend = bytes[d + 25]!;
  if (rect.width === 0 || rect.height === 0) {
    return err(
      badApng(`fcTL 帧尺寸必须非 0，实际 ${rect.width}×${rect.height}`, { chunk: "fcTL", offset: chunk.dataStart }),
    );
  }
  if (dispose > 2) {
    return err(
      badApng(`fcTL dispose_op=${dispose} 非法（允许 0/1/2）`, { chunk: "fcTL", dispose }),
    );
  }
  if (blend > 1) {
    return err(badApng(`fcTL blend_op=${blend} 非法（允许 0/1）`, { chunk: "fcTL", blend }));
  }
  return ok({
    sequence: u32be(bytes, d),
    rect,
    delayNum: u16be(bytes, d + 20),
    delayDen: u16be(bytes, d + 22),
    dispose,
    blend,
  });
}

/** delay 秒 = num / den；den = 0 视为 100（APNG 规范）。毫秒取整到 1ms。 */
function delayToMs(num: number, den: number): number {
  const d = den === 0 ? 100 : den;
  return Math.round((num * 1000) / d);
}

/**
 * 非预乘 alpha 的 source-over。
 * 公式取自 APNG 规范引用的 Porter-Duff "over"：
 *   Ao = As + Ad*(1-As)
 *   Co = (Cs*As + Cd*Ad*(1-As)) / Ao
 * 两边都是非预乘，所以要除回 Ao。Ao = 0 时直接给全透明黑。
 *
 * ★ 用浮点算再取整，而不是整数近似：整数近似（例如 `c = c1 + c2*(255-a1)/255`）
 *   在多次叠加后会累积偏差，逐帧比对的判据会因为最后几帧差 1 而红。
 */
function blendOver(
  dst: Uint8Array,
  o: number,
  src: Uint8Array,
  s: number,
): void {
  const sa = src[s + 3]! / 255;
  if (sa === 1) {
    dst[o] = src[s]!;
    dst[o + 1] = src[s + 1]!;
    dst[o + 2] = src[s + 2]!;
    dst[o + 3] = 255;
    return;
  }
  if (sa === 0) return;
  const da = dst[o + 3]! / 255;
  const oa = sa + da * (1 - sa);
  if (oa <= 0) {
    dst[o] = dst[o + 1] = dst[o + 2] = dst[o + 3] = 0;
    return;
  }
  dst[o] = Math.round((src[s]! * sa + dst[o]! * da * (1 - sa)) / oa);
  dst[o + 1] = Math.round((src[s + 1]! * sa + dst[o + 1]! * da * (1 - sa)) / oa);
  dst[o + 2] = Math.round((src[s + 2]! * sa + dst[o + 2]! * da * (1 - sa)) / oa);
  dst[o + 3] = Math.round(oa * 255);
}

/**
 * 解码 APNG → 每帧一张完整画布。
 *
 * 返回的 `frames[i].pixels` 是**合成后**的整幅图（不是帧矩形切片）：
 * 调用方拿它直接 `createTexture` 就能播，不需要知道 dispose/blend 是什么。
 * 代价是内存 = 帧数 × 画布，所以 `limit` 存在 —— 大动图应该按需解。
 */
export function decodeApng(bytes: Uint8Array, opts?: DecodeApngOptions): Result<DecodedApng, EngineError> {
  const maxBytes = opts?.maxBytes ?? DEFAULT_MAX_BYTES;
  const maxFrames = opts?.maxFrames ?? DEFAULT_MAX_FRAMES;

  const scanned = scanPng(bytes);
  if (!scanned.ok) return err(scanned.error);
  const { header: h, palette, trns, chunks } = scanned.value;

  const actl = chunks.find((c) => c.type === "acTL");
  if (actl === undefined) {
    return err(
      badApng(
        "这不是 APNG：缺少 acTL 块。静态 PNG 请用 decodePng()（它便宜得多，不需要合成画布）。",
        { hint: "acTL" },
      ),
    );
  }
  if (actl.length !== 8) return err(badApng(`acTL 数据长度 ${actl.length}（必须 8）`));
  const frameCount = u32be(bytes, actl.dataStart);
  const loopCount = u32be(bytes, actl.dataStart + 4);
  if (frameCount === 0) return err(badApng("acTL.num_frames=0（动图至少要有一帧）"));
  if (frameCount > maxFrames) {
    return err(
      badApng(`APNG 声明 ${frameCount} 帧，超过 maxFrames=${maxFrames}（炸弹保护）`, { frameCount, maxFrames }),
    );
  }

  const bytesPerFrame = h.width * h.height * 4;
  if (bytesPerFrame * Math.min(frameCount, opts?.limit ?? frameCount) > maxBytes) {
    return err(
      badApng(
        `APNG ${h.width}×${h.height} × ${frameCount} 帧的合成画布需要 ` +
          `${bytesPerFrame * frameCount} 字节，超过 maxBytes=${maxBytes}`,
        { width: h.width, height: h.height, frameCount, maxBytes },
      ),
    );
  }

  const paletteBytes =
    palette === undefined ? undefined : bytes.subarray(palette.dataStart, palette.dataStart + palette.length);
  const trnsBytes = trns === undefined ? undefined : bytes.subarray(trns.dataStart, trns.dataStart + trns.length);

  const header: Header = h;

  /** 按文件顺序把 fcTL 与它后面的数据块配对。 */
  interface FrameSource {
    readonly control: FrameControl;
    /** 该帧的 zlib 数据块（IDAT 或 fdAT，可能多个）。 */
    readonly data: { dataStart: number; length: number; isFdat: boolean }[];
  }

  const firstIdatAt = chunks.findIndex((c) => c.type === "IDAT");
  const firstFctlAt = chunks.findIndex((c) => c.type === "fcTL");
  if (firstFctlAt < 0) return err(badApng("有 acTL 但没有任何 fcTL（帧控制）块"));
  // fcTL 出现在 IDAT 之前 ⇒ IDAT 就是第一帧；否则 IDAT 是"静态默认图"，不属于动画。
  const idatIsFirstFrame = firstFctlAt < firstIdatAt;

  const sources: FrameSource[] = [];
  let current: { control: FrameControl; data: FrameSource["data"] } | undefined;
  let expectedSequence = 0;

  const pushCurrent = (): void => {
    if (current !== undefined) sources.push({ control: current.control, data: current.data });
  };

  for (let i = 0; i < chunks.length; i++) {
    const c = chunks[i]!;
    if (c.type === "fcTL") {
      pushCurrent();
      const rc = readFcTL(bytes, c);
      if (!rc.ok) return err(rc.error);
      // 序列号必须从 0 开始连续递增，fcTL 与 fdAT 共用一个计数空间
      if (rc.value.sequence !== expectedSequence) {
        return err(
          badApng(
            `fcTL 序列号断裂：期望 ${expectedSequence}，实际 ${rc.value.sequence}（帧 ${sources.length}）`,
            { expected: expectedSequence, actual: rc.value.sequence },
          ),
        );
      }
      expectedSequence++;
      const fc = rc.value;
      if (fc.rect.x + fc.rect.width > h.width || fc.rect.y + fc.rect.height > h.height) {
        return err(
          badApng(
            `帧矩形越界：x=${fc.rect.x} y=${fc.rect.y} ${fc.rect.width}×${fc.rect.height}，画布 ${h.width}×${h.height}`,
            { rect: fc.rect },
          ),
        );
      }
      current = { control: fc, data: [] };
    } else if (c.type === "IDAT") {
      if (current !== undefined && idatIsFirstFrame && sources.length === 0) {
        current.data.push({ dataStart: c.dataStart, length: c.length, isFdat: false });
      }
      // 否则 IDAT 是默认图，不参与动画
    } else if (c.type === "fdAT") {
      if (c.length < 4) return err(badApng(`fdAT 数据长度 ${c.length}（至少要 4 字节序列号）`));
      const seq = u32be(bytes, c.dataStart);
      if (seq !== expectedSequence) {
        return err(
          badApng(`fdAT 序列号断裂：期望 ${expectedSequence}，实际 ${seq}`, { expected: expectedSequence, actual: seq }),
        );
      }
      expectedSequence++;
      if (current === undefined) return err(badApng("fdAT 出现在任何 fcTL 之前"));
      current.data.push({ dataStart: c.dataStart + 4, length: c.length - 4, isFdat: true });
    }
  }
  pushCurrent();

  if (sources.length !== frameCount) {
    return err(
      badApng(
        `acTL 声明 ${frameCount} 帧，实际找到 ${sources.length} 个 fcTL —— ` +
          `帧数与声明不符会让播放器静默截断，所以这里直接拒绝。`,
        { declared: frameCount, actual: sources.length },
      ),
    );
  }

  // 首帧约束：若 IDAT 属于动画，第一帧必须覆盖整个画布（APNG 规范 §5.3）
  const first = sources[0]!;
  if (idatIsFirstFrame) {
    const r = first.control.rect;
    if (r.x !== 0 || r.y !== 0 || r.width !== h.width || r.height !== h.height) {
      return err(
        badApng(
          `第一帧用 IDAT 时必须是整幅画布：帧矩形 (${r.x},${r.y}) ${r.width}×${r.height}，画布 ${h.width}×${h.height}`,
          { rect: r },
        ),
      );
    }
  }

  const canvas = new Uint8Array(bytesPerFrame); // 全透明黑，符合 APNG 初始状态
  let previous: Uint8Array | undefined;
  const frames: ApngFrame[] = [];
  const limit = opts?.limit ?? frameCount;

  /** 把帧矩形贴到画布上（blend=SOURCE 直接覆盖，blend=OVER 按 source-over）。 */
  const composite = (rect: ApngRect, src: Uint8Array, blend: number): void => {
    for (let row = 0; row < rect.height; row++) {
      const dy = rect.y + row;
      let s = row * rect.width * 4;
      let o = (dy * h.width + rect.x) * 4;
      if (blend === ApngBlendOp.Source) {
        canvas.set(src.subarray(s, s + rect.width * 4), o);
        continue;
      }
      for (let col = 0; col < rect.width; col++, s += 4, o += 4) blendOver(canvas, o, src, s);
    }
  };

  const disposeArea = (rect: ApngRect, op: number): void => {
    if (op === ApngDisposeOp.None) return;
    if (op === ApngDisposeOp.Background) {
      for (let row = 0; row < rect.height; row++) {
        const o = ((rect.y + row) * h.width + rect.x) * 4;
        canvas.fill(0, o, o + rect.width * 4);
      }
      return;
    }
    // Previous：恢复成"这一帧绘制之前"的画布
    if (previous !== undefined) canvas.set(previous, 0);
  };

  let pendingDispose: { rect: ApngRect; op: number } | undefined;

  for (let i = 0; i < sources.length; i++) {
    const src = sources[i]!;
    // ① 先处置上一帧（规范：帧 n 的显示结束后才应用 dispose）
    if (pendingDispose !== undefined) {
      disposeArea(pendingDispose.rect, pendingDispose.op);
      pendingDispose = undefined;
    }
    // ② 若本帧要 PREVIOUS，先存"绘制前"快照
    const needsSnapshot = src.control.dispose === ApngDisposeOp.Previous;
    if (needsSnapshot) previous = canvas.slice();

    // ③ 解帧数据（每帧独立 zlib 流）
    const data = src.data;
    if (data.length === 0) {
      return err(badApng(`第 ${i} 帧没有任何 IDAT/fdAT 数据`, { frame: i }));
    }
    let compressed = new Uint8Array(data.reduce((n, d) => n + d.length, 0));
    {
      let o = 0;
      for (const d of data) {
        compressed.set(bytes.subarray(d.dataStart, d.dataStart + d.length), o);
        o += d.length;
      }
    }
    const rect = src.control.rect;

    const decoded = decodeZlibImage(compressed, header, rect.width, rect.height, paletteBytes, trnsBytes, {
      maxBytes,
      label: `APNG 第 ${i} 帧（${rect.width}×${rect.height}）`,
    });
    if (!decoded.ok) return err(decoded.error);

    // ④ 合成
    composite(rect, decoded.value.pixels, src.control.blend);

    if (frames.length < limit) {
      frames.push({
        index: i,
        pixels: canvas.slice(),
        rect,
        delayMs: delayToMs(src.control.delayNum, src.control.delayDen),
        dispose: src.control.dispose,
        blend: src.control.blend,
      });
    }

    pendingDispose = { rect: src.control.rect, op: src.control.dispose };
  }

  // 最后一帧的 dispose 也要生效吗？不需要 —— 循环播放时下一轮从第 0 帧重新开始，
  // 而第 0 帧若是 IDAT（整幅、blend=SOURCE）会覆盖全部像素；若首帧是 fdAT 且带偏移，
  // dispose 才影响下一轮。这里按规范保留"最后一帧的 dispose 在循环时执行"的语义，
  // 因此不改画布 —— 帧快照已经产出，画布状态不再被使用。

  return ok({ width: h.width, height: h.height, loopCount, frames });
}
