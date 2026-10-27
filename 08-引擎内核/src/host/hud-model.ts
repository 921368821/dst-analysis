/**
 * L6 · 演示宿主的 HUD / 背包文案模型
 *
 * 为什么文案要抽成一个**纯函数**，不直接写在 `browser-entry.ts` 里拼：
 *
 * ★★ 因为引擎的位图字体只有 ASCII（5×7 手绘，见 `tools/make-ui-assets.mjs`）。
 *   HUD 里一旦出现一个中文字，它不会报错、不会崩、也不会变红 ——
 *   它会**静默变成空白**（`missingAdvance` 还占着宽度，于是"那里有个空档"）。
 *   这种错误只有两种抓法：截图比对人眼看，或者把文案交给判据。
 *   前者不可自动化，所以文案必须待在一个**Node 里能跑**的地方，
 *   由判据拿真字体逐字查一遍（`tests/host/hud-model.test.ts`）。
 *
 * ★ 抽出来还有第二个好处：这里是唯一知道"哪些是玩家该看的"的地方，
 *   `browser-entry.ts` 只负责把事实（tick/fps/背包格）填进来。
 *   上一版把两件事混在 1729 行里，结果是"改一句 HUD 文案"要读半页代码。
 *
 * ★ 取值口径（都不是随手写的）：
 *   · `null` 表示"这个东西不存在"，与 `0` 严格区分：
 *     `script off`（没接脚本）和 `script 0c`（接了但没调用）是两种状态；
 *   · 数字一律四舍五入到整数：HUD 是给人扫一眼的，`59.73` 反而更难读；
 *   · 分隔符用 ` | ` 而不是 `·`：`·` 是 U+00B7，5×7 字体里没有它。
 */

import type { BitmapFont } from "../extensions/ui/font.ts";

/** HUD 需要的**全部事实**。加一个字段 = 改一处格式化 + 一条判据。 */
export interface HudFacts {
  readonly fps: number;
  readonly tick: number;
  readonly quads: number;
  readonly drawCalls: number;
  readonly culled: number;
  readonly nodes: number;
  readonly bodies: number;
  /** 图集来源标签（`assets*11` / `procedural`）—— 降级必须**看得见**。 */
  readonly atlas: string;
  /** `null` = 世界没装配。`terrain` = 地形块数，`sites` = 投放点数。 */
  readonly world: { readonly terrain: number; readonly sites: number } | null;
  /** 再生资源的三个计数：活着的 / 累计刷出的 / 被采走的。 */
  readonly resources: { readonly alive: number; readonly spawned: number; readonly released: number };
  /** 背包里**有东西的**堆叠数。 */
  readonly bagStacks: number;
  /** `null` = 没有饱食组件（不是 0 —— 0 是"饿死了"）。 */
  readonly hunger: { readonly value: number; readonly max: number } | null;
  readonly backends: {
    readonly gfx: string;
    readonly audio: string;
    readonly input: string;
    readonly script: string | null;
  };
  /** `null` = 脚本模块没起来。 */
  readonly script: { readonly calls: number; readonly errors: number; readonly timeouts: number } | null;
  readonly droppedSteps: number;
}

/**
 * HUD 的**行**（当前是 3 行）。
 *
 * ★ 为什么要分行，而不是像上一版那样拼成一行：
 *   一行 15 个字段 ≈ 190 个字符，5×7 字体每字前进 6px ⇒ 约 1140px。
 *   设计分辨率是 960 宽 —— 一行**必然溢出**，而溢出的部分是静默的
 *   （文字画到屏幕外，`missingGlyphs` 是空的、`quads` 照样在涨）。
 *   "塞不下"不是排版问题，是**这条信息本来就该分层**：每帧变的（帧率/规模）、
 *   世界状态的（图集/地形/资源/背包/饱食）、出问题才看的（后端/脚本/丢帧）。
 *
 * ★ 行的划分就是"什么时候会去看它"的划分，不是按字段类型分的。
 */
export function hudRows(f: HudFacts): readonly [string, string, string] {
  const r = (n: number): string => String(Math.round(n));
  const world = f.world === null ? "world -" : `world ${r(f.world.terrain)}/${r(f.world.sites)}`;
  const script =
    f.script === null
      ? "script off"
      : `script ${r(f.script.calls)}c/${r(f.script.errors)}e${f.script.timeouts > 0 ? `/${r(f.script.timeouts)}to` : ""}`;
  const hunger = f.hunger === null ? "fed -" : `fed ${r(f.hunger.value)}/${r(f.hunger.max)}`;
  return [
    [
      `fps ${r(f.fps)}`,
      `tick ${r(f.tick)}`,
      `quad ${r(f.quads)}`,
      `draw ${r(f.drawCalls)}`,
      `cull ${r(f.culled)}`,
      `nodes ${r(f.nodes)}`,
      `bodies ${r(f.bodies)}`,
    ].join(" | "),
    [
      `atlas:${f.atlas}`,
      world,
      `res ${r(f.resources.alive)}/${r(f.resources.spawned)}/${r(f.resources.released)}`,
      `bag ${r(f.bagStacks)}`,
      hunger,
    ].join(" | "),
    [
      `${f.backends.gfx}/${f.backends.audio}/${f.backends.input}/${f.backends.script ?? "-"}`,
      script,
      `drop ${r(f.droppedSteps)}`,
    ].join(" | "),
  ];
}

/**
 * 一行 HUD（把三行拼起来）。
 *
 * ★ 保留它不是为了兼容：诊断面（`__engine.hudText()`）与降级路径（UI 资产缺失时
 *   退回 DOM 一行）都需要**一整句**。而它与 `hudRows` 必须同源 ——
 *   判据里有一条直接断言 `hudRows(f).join(" | ") === hudLine(f)`，
 *   两份格式化逻辑分叉时会立刻红，而不是等到"某个字段在 UI 里消失"。
 *
 * 字段顺序按"看的时候最想先看到什么"排：帧率 → 世界规模 → 资源 → 玩家 → 后端。
 * 后端放在末尾是因为它**只在出问题时才看**。
 */
export function hudLine(f: HudFacts): string {
  return hudRows(f).join(" | ");
}

/** 背包面板的一行。`text` 已经在**数据侧**拼好（面板只负责摆放）。 */
export interface BagRow {
  /** 1 起的序号（与"数字键选集"对应，索引 0 是第 1 堆）。 */
  readonly index: number;
  readonly text: string;
  readonly selected: boolean;
  /**
   * 拖拽标记。`null` = 没在拖或与它无关。
   *
   * ★ 单独给一个字段而不是让宿主去解析 `text` 里的后缀：
   *   "哪一行是落点"是**结构**，从文案里 regex 出来就有了第二个真相，
   *   改一句文案就会把它弄坏（而且坏得静默 —— 拖拽照常工作，只是高亮没了）。
   */
  readonly drag: BagDragMark;
}

/** 拖拽标记：`from` = 被拿起来的那格，`to` = 松手会落到的格。 */
export type BagDragMark = "from" | "to" | null;

/**
 * 拖拽状态（下标都是**背包行下标**，从 0 起）。
 *
 * ★ `to === null` 表示指针不在任何格子上（拖到面板外、拖到缝里）。
 *   它与 `to === from` 是两种不同的状态：前者松手不换位，后者松手等于放回原处。
 *   合成一个"没变"会让"拖出去再拖回来"的分支无处落地。
 */
export interface BagDragState {
  readonly from: number | null;
  readonly to: number | null;
}

/**
 * 背包面板的行。
 *
 * ★ 物品名走 `labelOf`（宿主注入）。**默认实现是 `kind` 的 ASCII 形式**，
 *   而不是中文：中文标签需要中文字形，而字形是**可选资产**（`ui-font-cjk` 读不到时
 *   UI 只有 5×7 的 ASCII）。于是"有没有中文字体"这件事在**一个地方**决定 ——
 *   宿主读到了就传 `ITEM_LABEL`，读不到就不传，行文本自然退回英文。
 *
 * ★★ 上一版的注释写着"中文标签会变成一片空白，等有没有 CJK 字体这件事解决"：
 *   现在解决了（批101）。但**默认值仍然是 ASCII** —— 因为空白是静默的，
 *   而这里不能假设字体一定在。判据那边用真字体逐字查（见 `tests/host/hud-model.test.ts`）。
 */
export function bagRows(
  stacks: readonly { readonly kind: string; readonly count: number }[],
  selected: number,
  labelOf?: (kind: string) => string,
  drag?: BagDragState,
): BagRow[] {
  const sel = stacks.length === 0 ? 0 : Math.min(Math.max(0, selected), stacks.length - 1);
  const label = labelOf ?? ((kind: string) => kind.replace(/_/g, " "));
  const from = drag?.from ?? null;
  const to = drag?.to ?? null;
  return stacks.map((s, i) => {
    // ★ `from` 优先于 `to`：刚按下还没动时两者相同，这一格既是"拿起来的"又是"要放回去的"。
    //   让它显示 `moving` 才是实话 —— 显示 `drop` 会让人以为已经在换位了。
    const mark: BagDragMark = from !== null && i === from ? "from" : to !== null && i === to ? "to" : null;
    const base = `${String(i + 1)}. ${label(s.kind)} x${String(s.count)}`;
    return {
      index: i + 1,
      // 标记**缀在行尾**，不缀在行首：行首是序号，序号错位会让"按数字键选集"看起来对不上。
      // 也不用箭头符号：`>` / `←` 这类字符在 5×7 的 ASCII 字形里未必有，
      // 缺字是静默的（画出来是空白），而英文单词一定在。
      text: mark === null ? base : `${base}  (${mark === "from" ? "moving" : "drop"})`,
      selected: i === sel,
      drag: mark,
    };
  });
}

/** 背包面板底栏（键位由映射表生成，这里只拼接）。 */
export function bagFooter(hints: {
  readonly drop: string;
  readonly bag: string;
}): string {
  return `click row to select | ${hints.drop} drop 1 | shift+${hints.drop} drop all | ${hints.bag} close`;
}

/** 背包里什么都没有时的那句。与 `bagRows` 分开：它有自己的一条判据。 */
export function bagEmptyLine(pickKey: string): string {
  return `empty - press ${pickKey} to pick something up`;
}

/**
 * 这段文本里有几个字符**字体画不出来**。
 *
 * 这是这个文件里唯一真正"守门"的函数：调用方（判据）拿真字体跑一遍所有文案，
 * 返回空数组才算过。放在这里而不是判据里，是因为**宿主自己也该用它** ——
 * 运行时若出现缺字，`UiDrawStats.missingGlyphs` 会报出来，
 * 那时能立刻用同一个函数定位到是哪句话、哪个字。
 */
export function missingGlyphsIn(text: string, font: BitmapFont): number[] {
  const out: number[] = [];
  for (const ch of text) {
    const code = ch.codePointAt(0);
    if (code === undefined) continue;
    if (code === 0x20 || code === 0x0a) continue; // 空格与换行不是字形
    if (!font.glyphs.has(code)) out.push(code);
  }
  return out;
}
