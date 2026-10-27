/**
 * L4 · UI 控件绘制（节点 + 皮肤 + 字体 → 四边形）
 *
 * 这一层**不做布局、不碰 GPU**：输入是已摆好位置的节点树，输出是 `RenderItem`。
 * 好处是"控件长什么样"可以脱离渲染后端验证（数四边形、看 UV），
 * 而"像素对不对"留给浏览器自检 —— 两者不该混在一条判据里。
 *
 * ★★ 九宫格（9-slice）是 UI 的基础能力，不是优化：
 *   面板、按钮底、物品格边框都必须"角不拉伸、边单向拉伸、中间铺满"。
 *   缺了它只有两条路：为每种尺寸出一张图（美术成本爆炸），或整图拉伸
 *   （圆角变椭圆、描边粗细不均）。手绘风 UI 里圆角被拉歪是立刻能看出来的。
 *
 * ★★ 分批的隐含要求：**UI 的图与字最好打在同一张图集里**。
 *   分批维度只有一个（纹理页），而绘制顺序必须保持（后画的盖住先画的）。
 *   皮肤页与字体页分开时，每个「图 + 字」组合都要切一次页 ⇒ 每节点 2 段 draw。
 *   这不是 bug，是代价；控制方法是把字体页与皮肤页打同一张 UI 图集。
 *
 * ★★ 裁剪在 CPU 侧做，**不打断批**：
 *   教科书做法是给每个滚动容器套一次 GPU scissor，但那要求"按 scissor 变化切批" ——
 *   于是每滚一个列表就多两段 draw，而且嵌套滚动容器要在每层之间来回设/还原。
 *   这里改成把每个四边形**裁到裁剪框里**：矩形按交叠裁、UV 按同一比例裁。
 *   对轴对齐的四边形（UI 的全部）这两种做法**逐像素等价**，而批完全不被打断。
 *   ★ 前提是"四边形轴对齐且不旋转"—— 若以后加旋转，这条路必须重算（UV 与矩形不再是线性对应）。
 */

import { Rect } from "../../foundation/math/index.ts";
import type { RenderItem } from "../render/batch2d.ts";
import type { FontRegistry } from "./font.ts";
import type { UiStateStore } from "./state.ts";
import { defaultFontId, textBoxOf, textStyleFor } from "./intrinsic.ts";
import type { TextStyle } from "./text-layout.ts";
import { UiWidget, type UiNode, type UiProps } from "./layout.ts";

export interface Rgba {
  readonly r: number;
  readonly g: number;
  readonly b: number;
  readonly a: number;
}

/** 皮肤里的一个帧（UV 已归一化）。`width/height` 是**原始像素尺寸**，九宫格切片要用。 */
export interface UiSkinFrame {
  readonly page: number;
  readonly u0: number;
  readonly v0: number;
  readonly u1: number;
  readonly v1: number;
  readonly width: number;
  readonly height: number;
}

export interface UiSkin {
  readonly frames: ReadonlyMap<string, UiSkinFrame>;
}

/** UI 绘制层号。比世界的 0（地面）/1（实体）都大 —— 语义上就是"永远最前面"。 */
export const UI_LAYER = 2;

export interface UiDrawStats {
  readonly quads: number;
  readonly glyphs: number;
  readonly labels: number;
  /** 本帧缓存命中数（诊断"文本有没有被重排"）。 */
  readonly cacheHits: number;
  /**
   * 被裁剪框挡掉的四边形数。
   * ★ 必须有这个数：滚动容器的性能收益**全在这里**，而"画得对不对"看不出来它 ——
   *   少了它，一个"忘了把 clipRect 传下去"的实现会让 quad 数悄悄翻倍，
   *   帧率掉一半而画面完全正常。
   */
  readonly culled: number;
  /** 缺字码点（升序去重）。 */
  readonly missingGlyphs: readonly number[];
  /** 皮肤里找不到的帧名（去重升序）。 */
  readonly missingFrames: readonly string[];
}

export interface UiDrawResult {
  readonly quads: readonly RenderItem[];
  readonly stats: UiDrawStats;
}

/**
 * 文本排版缓存已迁到 `state.ts`（ADR-0012：跨帧状态统一由状态表持有）。
 *
 * ★ 为什么必须**只有一份**：布局层的"自撑开"要先量一次文本、绘制层还要再量一次，
 *   两份缓存意味着同一段文本被排两遍（O(字数)，每帧），而且要各自处理失效。
 *   更糟的是它们会**性格不同**：布局那份在改字号之后失效了、绘制那份没失效，
 *   于是"盒子按新字号撑开、字还是旧字号那么大"—— 看起来像布局算错。
 */
export { UiStateStore } from "./state.ts";

/**
 * 一个节点的**有效**不透明度：沿父链连乘。
 *
 * ★ 为什么连乘而不是取父节点的最终值：`UiNode.opacity` 存的是**自身**值
 *   （理由见那里的注释）。父断言"整块面板 0.5"、子断言"这个字 0.5"时，
 *   视觉上应当是 0.25 —— 取最终值会让子的 0.5 静默覆盖父的 0.5。
 *
 * ★ 为什么每次都重算（O(深度)）：过渡动画期间几乎每个节点每帧都在变，
 *   缓存要么每帧全废（等于没缓存），要么就得维护"哪些后代受影响"的脏标记 ——
 *   那是 UI 树里最容易写错的机制之一。树深通常 < 10，重算比维护便宜。
 */
function alphaOf(node: UiNode): number {
  let a = 1;
  for (let cur: UiNode | null = node; cur !== null; cur = cur.parent) {
    a *= cur.opacity;
  }
  return a;
}

/** 把一整棵树画成一串四边形（前序：父先、子后、兄弟按数组顺序）。 */
export function buildUiQuads(root: UiNode, fonts: FontRegistry, skin: UiSkin, store: UiStateStore): UiDrawResult {
  const quads: RenderItem[] = [];
  let order = 0;
  let glyphs = 0;
  let labels = 0;
  let culled = 0;
  const missingGlyphs = new Set<number>();
  const missingFrames = new Set<string>();

  const emit = (
    rect: Rect,
    page: number,
    uv: { u0: number; v0: number; u1: number; v1: number },
    tint: Rgba | undefined,
    ord: number,
    alpha: number,
    clip: Rect | null,
  ): void => {
    if (rect.width <= 0 || rect.height <= 0) return;
    // ★ 有效不透明度在**画的时候**乘（`alphaOf` 沿父链连乘），节点上存的是"自身"值。
    //   存最终值的话，动画每改一次父节点就得遍历子树重算 —— 谁也不该为读一个数付出遍历。
    const a = (tint?.a ?? 1) * alpha;
    if (a <= 0) return; // 全透明不必入批（否则白白占一次顶点/绘制）
    // ★ 裁到祖先给的框里。**不是整块丢弃**：滚到一半的行要露出下面几条字的**一部分**，
    //   整块丢会让列表在边界上缺一整行，看起来像"最后一行渲染坏了"。
    //   裁矩形同时按比例裁 UV，取的是这半个矩形**对应的那半个贴图** ——
    //   与 GPU scissor 的结果逐像素一致，但不需要打断批（见文件头 ★★）。
    let r = rect;
    let u0 = uv.u0;
    let v0 = uv.v0;
    let u1 = uv.u1;
    let v1 = uv.v1;
    if (clip !== null) {
      const x0 = Math.max(rect.x, clip.x);
      const x1 = Math.min(rect.xMax, clip.xMax);
      const y0 = Math.max(rect.y, clip.y);
      const y1 = Math.min(rect.yMax, clip.yMax);
      if (x1 <= x0 || y1 <= y0) {
        culled++;
        return;
      }
      if (x0 !== rect.x || x1 !== rect.xMax || y0 !== rect.y || y1 !== rect.yMax) {
        const kx = (u1 - u0) / rect.width;
        const ky = (v1 - v0) / rect.height;
        u0 = u0 + (x0 - rect.x) * kx;
        u1 = u0 + (x1 - x0) * kx;
        v0 = v0 + (y0 - rect.y) * ky;
        v1 = v0 + (y1 - y0) * ky;
        r = new Rect(x0, y0, x1 - x0, y1 - y0);
      }
    }
    quads.push({
      nodeId: order,
      // ★ UI 用 z=0 恒定：排序第一键 layer 恒为 UI_LAYER，绘制顺序全靠 order。
      //   给 UI 编假的 z 会让"同 order 的兄弟"按 z 乱序 —— 那是最难查的一类重叠。
      x: r.x,
      z: r.y,
      w: r.width,
      h: r.height,
      u0,
      v0,
      u1,
      v1,
      r: tint?.r ?? 1,
      g: tint?.g ?? 1,
      b: tint?.b ?? 1,
      a,
      order: ord,
      layer: UI_LAYER,
      pivotX: 0,
      pivotY: 0,
      atlas: page,
    });
  };

  const drawFrame = (
    rect: Rect,
    frameName: string | undefined,
    slice: number,
    tint: Rgba | undefined,
    ord: number,
    alpha: number,
    clip: Rect | null,
  ): void => {
    if (frameName === undefined) return;
    const f = skin.frames.get(frameName);
    if (f === undefined) {
      // 帧名不存在不静默跳过：「某块 UI 不显示」必须能查到是谁。
      missingFrames.add(frameName);
      return;
    }
    if (slice > 0) {
      for (const q of nineSlice(rect, f, slice)) emit(q.rect, f.page, q.uv, tint, ord, alpha, clip);
    } else {
      emit(rect, f.page, { u0: f.u0, v0: f.v0, u1: f.u1, v1: f.v1 }, tint, ord, alpha, clip);
    }
  };

  const emitText = (
    node: UiNode,
    p: UiProps,
    box: Rect,
    style: TextStyle,
    ord: number,
    alpha: number,
    clip: Rect | null,
  ): void => {
    const text = p.text ?? "";
    if (text === "") return;
    const layout = store.text(node.uid, fonts, p.fontId ?? defaultFontId(fonts), text, style);
    if (layout === null) return;
    labels++;
    const y = box.y + (box.height - layout.height) / 2;
    for (const g of layout.quads) {
      glyphs++;
      emit(new Rect(box.x + g.x, y + g.y, g.w, g.h), g.page, g, { r: g.r, g: g.g, b: g.b, a: g.a }, ord, alpha, clip);
    }
    for (const m of layout.missing) missingGlyphs.add(m);
  };

  // ★ 用 `walkVisible`（而不是 `walk` + 逐个看 `visible`）：隐藏一个容器时，
  //   它的子树必须一起消失 —— 逐个判只挡住容器自己，子节点会带着**上一次布局的旧矩形**
  //   继续画出来。实测症状：关掉一个面板，quads 数一点没变（见 `walkVisible` 的注释）。
  for (const node of root.walkVisible()) {
    if (!node.visible) continue;
    if (node.widget === UiWidget.Group || node.widget === UiWidget.Spacer) continue;
    // ★★ CPU 侧裁剪的第一道：**整块在裁剪框外就不要走排版**。
    //   只省顶点是不够的 —— 标签的排版是 O(字数)，一个 200 行的日志面板滚到末尾时，
    //   前面 190 行的文本排版全都会被算一遍再全部丢掉。那一步才是这里真正的成本。
    if (!intersectsClip(node.rect, node.clipRect)) {
      culled++;
      continue;
    }
    const ord = order++;
    const p: UiProps = node.props;
    // ★ 沿父链连乘：父节点淡到 0.5、子节点 0.5 ⇒ 子节点实际 0.25。
    //   Group/Spacer 不画东西但也可能带 opacity（它们是"容器"），
    //   所以这个值必须在 `continue` **之前**算好。
    const alpha = alphaOf(node);
    const clip = node.clipRect;

    if (node.widget === UiWidget.Panel) {
      drawFrame(node.rect, p.frame, p.slice ?? 0, p.tint, ord, alpha, clip);
      continue;
    }

    if (node.widget === UiWidget.Image) {
      drawFrame(node.rect, p.frame, 0, p.tint, ord, alpha, clip);
      continue;
    }

    if (node.widget === UiWidget.Button) {
      drawFrame(node.rect, p.frame, p.slice ?? 0, p.tint, ord, alpha, clip);
      // ★ 按钮不自己记"按下"状态：状态由调用方改 props 表达。
      //   控件偷偷持有交互状态，会让"两个地方都能设置它"变成必然的漂移源。
      // ★ 内缩与换行宽都来自 `intrinsic.ts` 的共用函数：量算那一侧算的是同一个数。
      //   各写一个 4 的话，改动只会落到一处，症状是"按钮文字贴右边框一点点"。
      const inner = textBoxOf(node, node.rect);
      emitText(node, p, inner, textStyleFor(node, inner.width), ord, alpha, clip);
      continue;
    }

    if (node.widget === UiWidget.Progress) {
      drawFrame(node.rect, p.frame, p.slice ?? 0, p.tint, ord, alpha, clip);
      const v = Math.max(0, Math.min(1, p.value ?? 0));
      const f = p.frame === undefined ? undefined : skin.frames.get(p.frame);
      if (v > 0 && f !== undefined) {
        const r = new Rect(node.rect.x, node.rect.y, node.rect.width * v, node.rect.height);
        // ★ 填充按比例**裁切 UV**，而不是缩放整张图：
        //   缩放会把描边一起拉细，进度 20% 时看起来像"另一张图"。
        const u1 = f.u0 + (f.u1 - f.u0) * v;
        emit(r, f.page, { u0: f.u0, v0: f.v0, u1, v1: f.v1 }, p.activeTint ?? { r: 0.5, g: 0.85, b: 0.4, a: 1 }, ord, alpha, clip);
      }
      continue;
    }

    if (node.widget === UiWidget.Label) {
      emitText(node, p, node.rect, textStyleFor(node, node.rect.width), ord, alpha, clip);
    }
  }

  return {
    quads,
    stats: {
      quads: quads.length,
      glyphs,
      labels,
      cacheHits: store.hits,
      culled,
      missingGlyphs: Array.from(missingGlyphs).sort((a, b) => a - b),
      missingFrames: Array.from(missingFrames).sort(),
    },
  };
}

/** 矩形与裁剪框是否有交叠（`clip === null` = 不裁、恒真）。 */
export function intersectsClip(rect: Rect, clip: Rect | null): boolean {
  if (clip === null) return true;
  return rect.x < clip.xMax && rect.xMax > clip.x && rect.y < clip.yMax && rect.yMax > clip.y;
}

interface SliceQuad {
  readonly rect: Rect;
  readonly uv: { u0: number; v0: number; u1: number; v1: number };
}

/**
 * 九宫格切分。返回 9 块（源或目标过小时退化成更少块，但**总是覆盖整个目标矩形**）。
 *
 * ★ 边距必须**四向夹取**：`slice` 超过源帧的一半会切出负宽度的中间块；
 *   超过目标的一半会让左右角重叠。两种都表现为"边框糊成一团"，
 *   而且只在特定尺寸出现 —— 所以这里夹取，并保证退化后仍然画全。
 */
export function nineSlice(rect: Rect, f: UiSkinFrame, slice: number): SliceQuad[] {
  const b = Math.max(0, Math.min(slice, f.width / 2, f.height / 2, rect.width / 2, rect.height / 2));
  if (b <= 0) {
    return [{ rect, uv: { u0: f.u0, v0: f.v0, u1: f.u1, v1: f.v1 } }];
  }
  // ★ 边距换算到 UV 要**乘帧在整图里占的比例**：`b / f.width` 是"占帧宽的几分之几"，
  //   而 UV 的步长是相对**整张图**的。少乘 `(u1-u0)` 会让帧只占图集一角时
  //   切片点落到帧外 —— 边角采到邻居图案，而尺寸全对。
  const sv = (b / f.height) * (f.v1 - f.v0);
  const su = (b / f.width) * (f.u1 - f.u0);

  const ux = [f.u0, f.u0 + su, f.u1 - su, f.u1];
  const vy = [f.v0, f.v0 + sv, f.v1 - sv, f.v1];
  const dx = [rect.x, rect.x + b, rect.xMax - b, rect.xMax];
  const dy = [rect.y, rect.y + b, rect.yMax - b, rect.yMax];

  const out: SliceQuad[] = [];
  for (let r = 0; r < 3; r++) {
    for (let c = 0; c < 3; c++) {
      const w = dx[c + 1]! - dx[c]!;
      const h = dy[r + 1]! - dy[r]!;
      if (w <= 0 || h <= 0) continue;
      out.push({
        rect: new Rect(dx[c]!, dy[r]!, w, h),
        uv: { u0: ux[c]!, v0: vy[r]!, u1: ux[c + 1]!, v1: vy[r + 1]! },
      });
    }
  }
  return out;
}

