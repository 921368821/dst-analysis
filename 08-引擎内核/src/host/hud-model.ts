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
import type { TextRun } from "../extensions/ui/text-layout.ts";
import type { Color } from "../foundation/math/index.ts";

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
  /**
   * 决策树资产（批156）：`loaded` = 从 `.tree.json` 装上的棵数（**不含内置树**）；
   * `missing` = 场景里配了、但库里没有的树 id 个数。
   *
   * ★ 两个数必须都在：`loaded` 回答"我的树到底装了没"，`missing` 回答"有没有谁配错了 id"。
   *   只显示 `loaded` 的话，一个都装失败与一棵都没配看起来一样（都是 0）；
   *   只显示 `missing` 的话，0 既可能是"全都对"也可能是"根本没有树"。
   * ★ 与 `atlas` 同一条纪律：降级（缺树 ⇒ 退回内置树）在画面上**看起来完全正常**，
   *   所以它必须占 HUD 一格，而不是只留在日志里。
   */
  readonly ai: { readonly loaded: number; readonly missing: number };
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
/** 一行 HUD：`text` 给诊断面与降级路径认行用，`runs` 给 UI 面板分段上色用。 */
export interface HudRow {
  readonly text: string;
  readonly runs: readonly TextRun[];
}

/**
 * HUD 行的**配色**（可选）—— 与 `BagRowColors` 同一先例：分段在模型、颜色在调用方。
 *
 * ★ 只给「值」上色：标签（`fps `）与分隔符（` | `）不带 color、继承行自己的
 *   基色（hud-ui 里那档 dim）。反过来「给标签上色」会让三个标签在视觉上
 *   抢过值 —— 值才是每帧变的东西，也是人扫一眼要找的东西。
 */
export interface HudRowColors {
  readonly value?: Color;
}

/**
 * 三行 HUD 的**分段**形态。
 *
 * ★ `hudRows`（纯文本）从它派生，而不是两份各写一遍：字段文案只在这一处拼，
 *   「哪个字符是标签、哪个是值」是关于这句文案的**事实**，跟"值用什么颜色"
 *   一样属于分段 —— 拆成两处就会改一处漏一处（症状：值亮了但标签串也亮了）。
 *
 * ★ 分段切在**空格**上：`fps 60` → 「`fps `」（标签）+「`60`」（值）。
 *   标签保留尾空格 —— 拼回去必须逐字符等于原串，这是判据钉死的不变量。
 *   `atlas:assets*11` 切在冒号后；后端串（`webgl2/webaudio/...`）整段一段 ——
 *   它没有"标签: 值"结构，硬拆只会造出一个没有意义的段。
 */
export function hudRowRuns(f: HudFacts, colors?: HudRowColors): readonly [HudRow, HudRow, HudRow] {
  const r = (n: number): string => String(Math.round(n));
  const valueRun = (text: string): TextRun =>
    colors?.value === undefined ? { text } : { text, color: colors.value };
  /** 「标签 + 值」的标准字段：标签继承基色，值可上色。 */
  const field = (label: string, value: string): TextRun[] => [{ text: label }, valueRun(value)];
  const sep: TextRun = { text: " | " };
  /** 字段之间插分隔符；分隔符不带颜色（继承基色，比标签更退后一步是面板的事）。 */
  const join = (fields: TextRun[][]): TextRun[] =>
    fields.flatMap((seg, i) => (i === 0 ? seg : [sep, ...seg]));

  const world = f.world === null ? "-" : `${r(f.world.terrain)}/${r(f.world.sites)}`;
  const scriptValue =
    f.script === null ? "off" : `${r(f.script.calls)}c/${r(f.script.errors)}e${f.script.timeouts > 0 ? `/${r(f.script.timeouts)}to` : ""}`;
  const hungerValue = f.hunger === null ? "-" : `${r(f.hunger.value)}/${r(f.hunger.max)}`;

  const mk = (runs: TextRun[]): HudRow => ({ text: runs.map((s) => s.text).join(""), runs });
  return [
    mk(
      join([
        field("fps ", r(f.fps)),
        field("tick ", r(f.tick)),
        field("quad ", r(f.quads)),
        field("draw ", r(f.drawCalls)),
        field("cull ", r(f.culled)),
        field("nodes ", r(f.nodes)),
        field("bodies ", r(f.bodies)),
      ]),
    ),
    mk(
      join([
        field("atlas:", f.atlas),
        field("ai ", `${r(f.ai.loaded)}/${r(f.ai.missing)}`),
        field("world ", world),
        field("res ", `${r(f.resources.alive)}/${r(f.resources.spawned)}/${r(f.resources.released)}`),
        field("bag ", r(f.bagStacks)),
        field("fed ", hungerValue),
      ]),
    ),
    mk(
      join([
        [{ text: `${f.backends.gfx}/${f.backends.audio}/${f.backends.input}/${f.backends.script ?? "-"}` }],
        field("script ", scriptValue),
        field("drop ", r(f.droppedSteps)),
      ]),
    ),
  ];
}

/**
 * 三行 HUD 的**纯文本**形态（诊断面与降级路径用）。从 `hudRowRuns` 派生 —— 见那里的 ★。
 */
export function hudRows(f: HudFacts): readonly [string, string, string] {
  const rows = hudRowRuns(f);
  return [rows[0].text, rows[1].text, rows[2].text];
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
  /**
   * 同一行的**分段**（富文本）：序号+物品名 / 计数 / 拖拽标记各一段。
   *
   * ★ 不变量：`runs.map(r => r.text).join("") === text`，而且是**构造上**成立的
   *   （`text` 就是这几段拼出来的，不是另写一遍）。
   *   反过来做（先拼 text、再拿正则切出 runs）会造出第二个真相：
   *   改一句文案就悄悄少了一段，症状是"计数不灰了"，而没有任何东西报错。
   *
   * ★ 分段放在**模型**层而不是面板层：哪几个字符是"计数"是关于这句文案的事实，
   *   而"计数用什么颜色"才是面板的决定。拆开之后，
   *   颜色改了不用动判据（判据断言的是"这一段存在且被标成计数"）。
   */
  readonly runs: readonly TextRun[];
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
 * 背包行的**配色**（可选）。
 *
 * ★ 只给"非主体部分"上色：序号与物品名永远用行自己的颜色（选中行还要跟着高亮变），
 *   所以那一段不带颜色、继承 `textColor`。把主体也写死成白色，
 *   选中行的高亮就永远不生效 —— 而那种错看起来像"选中没反应"。
 */
export interface BagRowColors {
  /** 计数（` x3`）。 */
  readonly count?: Color;
  /** 拖拽标记（`  (moving)`）。 */
  readonly mark?: Color;
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
  colors?: BagRowColors,
): BagRow[] {
  const sel = stacks.length === 0 ? 0 : Math.min(Math.max(0, selected), stacks.length - 1);
  const label = labelOf ?? ((kind: string) => kind.replace(/_/g, " "));
  const from = drag?.from ?? null;
  const to = drag?.to ?? null;
  const withColor = (text: string, c: Color | undefined): TextRun => (c === undefined ? { text } : { text, color: c });
  return stacks.map((s, i) => {
    // ★ `from` 优先于 `to`：刚按下还没动时两者相同，这一格既是"拿起来的"又是"要放回去的"。
    //   让它显示 `moving` 才是实话 —— 显示 `drop` 会让人以为已经在换位了。
    const mark: BagDragMark = from !== null && i === from ? "from" : to !== null && i === to ? "to" : null;
    // 标记**缀在行尾**，不缀在行首：行首是序号，序号错位会让"按数字键选集"看起来对不上。
    // 也不用箭头符号：`>` / `←` 这类字符在 5×7 的 ASCII 字形里未必有，
    // 缺字是静默的（画出来是空白），而英文单词一定在。
    const runs: TextRun[] = [
      // 序号与物品名连通的一段：中间没有可分段的地方，硬拆成两段只会多一个缓存键。
      { text: `${String(i + 1)}. ${label(s.kind)}` },
      withColor(` x${String(s.count)}`, colors?.count),
    ];
    if (mark !== null) runs.push(withColor(`  (${mark === "from" ? "moving" : "drop"})`, colors?.mark));
    return {
      index: i + 1,
      // ★ 由 runs 拼出来（而不是另拼一遍再切）：两处各写一遍是"改一句文案少一段样式"的入口。
      text: runs.map((r) => r.text).join(""),
      runs,
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
