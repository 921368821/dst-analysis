/**
 * 画布的**后备存储**尺寸（backing store = 物理像素）。
 *
 * ★ 为什么抽出来：这条公式原先在三个地方各写了一遍 ——
 *   `browser-entry.ts` 启动、`editor-entry.ts` 启动、`editor-entry.ts` 的
 *   `syncViewport()`（ResizeObserver 每次触发都算一次）。三份都在算
 *   「CSS 尺寸 × 像素比（上限 2）」，而**上限只写在两处有、第三处靠 `dpr` 变量间接继承**。
 *   改上限的人只改启动那两行，`syncViewport` 就会用旧上限把画布改回去 ——
 *   症状是"刚放大窗口时对、面板一撑高就不对"，没有任何断言会红。
 *
 * ★ 为什么上限是 2：4K 屏按 3 倍开会把填充率翻 2.25 倍，而观感提升在 2 倍之后
 *   基本看不出来 —— 这是"性能换画质"的一个已定档位，不是随手写的常数。
 *
 * ★ 为什么 `floor` 而不是 `round`：物理像素只能少不能多。少 1 像素看不出来，
 *   多 1 像素会让 WebGL 视口比 CSS 布局大一点，采样与命中都偏半个像素 ——
 *   而这类偏差在 dpr=1 的桌面上永远看不见（批141/批144 的教训）。
 */

/** 像素比上限。见上：2 是"性能与画质"的定档值，不是随手写的。 */
export const MAX_DPR = 2;

export interface BackingStore {
  /** 后备存储宽（物理像素，整数且 ≥ 1）。 */
  width: number;
  /** 后备存储高（物理像素，整数且 ≥ 1）。 */
  height: number;
  /** **钳过上限**的像素比 —— 宿主报 3 时这里是 2，调用方要拿它去设视口。 */
  dpr: number;
}

/**
 * CSS 尺寸 + 像素比 → 画布后备存储尺寸。
 *
 * 兜底规则（每一条都对应一个真实会遇到的输入）：
 * · `devicePixelRatio` 为 0 / NaN / 负数 → 当 1（浏览器在页面被 `display:none`
 *   或某些缩放状态下会报 0，那时按 1 画比按 0 画好）；
 * · `maxDpr` 非法 → 退回 `MAX_DPR`（调用方传错不该让整块画布变成 1 像素）；
 * · CSS 尺寸为 0 / NaN / 负数 → 给 **1 像素**而不是 0：`canvas.width = 0` 会让
 *   WebGL 上下文直接失效，而"暂时还没布局"是个正常状态，不该把渲染器打死。
 */
export function backingStoreSize(
  cssWidth: number,
  cssHeight: number,
  devicePixelRatio: number,
  maxDpr: number = MAX_DPR,
): BackingStore {
  const raw = Number.isFinite(devicePixelRatio) && devicePixelRatio > 0 ? devicePixelRatio : 1;
  const cap = Number.isFinite(maxDpr) && maxDpr > 0 ? maxDpr : MAX_DPR;
  const dpr = Math.min(cap, raw);
  const px = (n: number): number =>
    Number.isFinite(n) && n > 0 ? Math.max(1, Math.floor(n * dpr)) : 1;
  return { width: px(cssWidth), height: px(cssHeight), dpr };
}
