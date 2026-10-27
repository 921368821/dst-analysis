/**
 * L6 · 演示宿主的 HUD / 背包面板（**引擎 UI**，不是 DOM）
 *
 * 这个文件只做三件事：把皮肤 json 变成 `UiSkin`、把节点树摆出来、
 * 把"每帧变的事实"写进节点 props。它不碰 GPU、不碰 DOM、不算游戏逻辑 ——
 * 于是它能在 Node 里被逐条断言（`tests/host/hud-ui.test.ts`）。
 *
 * ★★ 为什么"重建 DOM"和"改 props"是两件事，而这里只能做后者：
 *   DOM 版面板每次内容变化都 `innerHTML = ""` 再重建 —— 一帧重建六十次，
 *   而且会把"点击选中"立刻冲掉（鼠标点下去那一帧正好在重建，T355 修过一次）。
 *   UI 树是**常驻**的：行数按 `maxRows` 一次建满，之后只切 `visible` 和改 `text`。
 *   64 个节点常驻比每帧重建 8 个 DOM 节点便宜，而且没有"重建打到点击"的时序问题。
 *
 * ★★ 坐标来自**字体**，不是硬编码：行高取 `font.lineHeight`、行高取 `lineHeight + 4`。
 *   把 10 / 14 / 6 这些数字写死在两处，换字体（5×7 → 6×9）时必然有一处忘改，
 *   症状是"字被裁一半"或"行之间有一条缝" —— 而两者都不会报错。
 */

import { Color, type Rect } from "../foundation/math/index.ts";
import { engineError, err, ok, type EngineError, type Result } from "../foundation/result.ts";
import type { BitmapFont } from "../extensions/ui/font.ts";
import { createUiModule, type UiModuleHandle, type UiPageSource } from "../extensions/ui/ui-module.ts";
import {
  ANCHOR_BOTTOM_CENTER,
  ANCHOR_CENTER,
  ANCHOR_TOP_LEFT,
  UiLayoutKind,
  UiNode,
  UiWidget,
} from "../extensions/ui/layout.ts";
import type { UiSkin, UiSkinFrame } from "../extensions/ui/widgets.ts";
import type { UiEvent, UiPointer } from "../extensions/ui/events.ts";
import type { UiViewportConfig } from "../extensions/ui/viewport.ts";
import { bagEmptyLine, bagFooter, bagRows } from "./hud-model.ts";

/** `ui-skin.json` 的形状（由 `tools/make-ui-assets.mjs` 生成）。 */
export interface UiSkinJson {
  readonly image: string;
  readonly width: number;
  readonly height: number;
  readonly frames: readonly {
    readonly name: string;
    readonly x: number;
    readonly y: number;
    readonly w: number;
    readonly h: number;
    readonly slice: number;
  }[];
}

/** 皮肤页里的帧 + 九宫格边距（`slice` 不在 `UiSkinFrame` 里：它是**用法**不是**图**）。 */
export interface BuiltSkin {
  readonly skin: UiSkin;
  /** 帧名 → 边距（设计 px）。节点 props 的 `slice` 从这里取。 */
  readonly slice: ReadonlyMap<string, number>;
}

/**
 * json → `UiSkin`。
 *
 * ★ 为什么 UV 在这里算而不是让生成器直接写 UV：
 *   json 里存**像素矩形**（人看得懂、改得动、能用任何看图工具核对），
 *   UV 是"贴图尺寸"的函数 —— 存 UV 的话，换一张同帧不同尺寸的图集就要重导一次，
 *   而像素矩形不用。两者的换算只该有一处，就是这里。
 *
 * ★ 越界要报错，不能夹取：帧落在图外时画面是空白，
 *   而"空白"与"UI 没画"在屏幕上完全一样 —— 那类错误只能靠启动期的判据抓。
 */
export function buildSkin(json: UiSkinJson, page = 1): Result<BuiltSkin, EngineError> {
  if (json.width <= 0 || json.height <= 0) {
    return err(engineError("UI.SKIN_BAD_SIZE", `皮肤图尺寸非法：${String(json.width)}x${String(json.height)}`));
  }
  if (json.frames.length === 0) {
    return err(engineError("UI.SKIN_NO_FRAME", "皮肤里一帧都没有（面板/按钮全都会变成空白）"));
  }
  const frames = new Map<string, UiSkinFrame>();
  const slice = new Map<string, number>();
  const W = json.width;
  const H = json.height;
  for (const f of json.frames) {
    if (f.w <= 0 || f.h <= 0) {
      return err(engineError("UI.SKIN_BAD_FRAME", `帧 ${f.name} 的尺寸非法：${String(f.w)}x${String(f.h)}`));
    }
    if (f.x < 0 || f.y < 0 || f.x + f.w > W || f.y + f.h > H) {
      return err(
        engineError(
          "UI.SKIN_FRAME_OOB",
          `帧 ${f.name} 超出皮肤图（${String(f.x)},${String(f.y)} ${String(f.w)}x${String(f.h)} 不在 ${String(W)}x${String(H)} 内）`,
        ),
      );
    }
    if (frames.has(f.name)) {
      // 同名帧的后果是"改了 json 却没生效"，而两份数据都合法 —— 只能在这里拒。
      return err(engineError("UI.SKIN_DUP_FRAME", `帧名重复：${f.name}`));
    }
    frames.set(f.name, {
      page,
      u0: f.x / W,
      v0: f.y / H,
      u1: (f.x + f.w) / W,
      v1: (f.y + f.h) / H,
      width: f.w,
      height: f.h,
    });
    slice.set(f.name, Math.max(0, f.slice));
  }
  return ok({ skin: { frames }, slice });
}

/** 背包最多几行（与 `makeInventory` 的默认 `maxStacks` 一致；宿主可覆盖）。 */
export const DEFAULT_MAX_ROWS = 8;

/**
 * HUD 面板的几何。**导出的常量**，不是散在函数里的字面量：
 * 判据要问"这三行字放得进面板吗"，就必须拿到**同一个**宽度，
 * 否则判据里抄一份 640、实现里改成 320，两边谁都不会红（"抄一份常量"是典型的假绿来源）。
 */
export const HUD_LAYOUT = {
  /** 面板总宽（设计 px）。960 设计宽下留出两侧各 160 给世界。 */
  width: 640,
  /** 内边距（四边）。 */
  pad: 6,
  /** 行间距。 */
  gap: 2,
  /** 饱食度条高度。 */
  bar: 6,
} as const;

export interface HudUiOptions {
  readonly font: BitmapFont;
  /**
   * 中文位图字体（`ui-font-cjk`，16×16）。**可选**：读不到时背包行回到 `kind` 的 ASCII 形式。
   * ★ 它是"第二张字体"而不是"同一张字体的第二批字"：汉字要 16 格，
   *   塞进 5×7 的单元格里只会糊成一团（见 `tools/make-ui-assets.mjs` 文件头）。
   */
  readonly cjkFont?: BitmapFont;
  /** 物品名 → 显示文本。缺省 = `kind` 改下划线为空格（ASCII）。 */
  readonly labelOf?: (kind: string) => string;
  readonly skinJson: UiSkinJson;
  /** 字形图（页 0）/ 皮肤图（页 1）/ 中文字形图（页 2）的像素数据。 */
  readonly fontPage: UiPageSource;
  readonly skinPage: UiPageSource;
  readonly cjkPage?: UiPageSource;
  readonly viewport: UiViewportConfig;
  readonly dpr?: number;
  /** 背包最多几行；超出部分**不画**（背包本身会拒绝第 9 堆）。 */
  readonly maxRows?: number;
  /** 键位提示（从映射表生成，这里只拼接）。 */
  readonly hints: { readonly drop: string; readonly bag: string; readonly pick: string };
  /** 点了第 i 行（0 起）。**只在真的 click 时调**，不是每帧调。 */
  readonly onSelectRow: (index: number) => void;
  /**
   * 把第 `from` 行拖到了第 `to` 行（0 起）。
   *
   * ★ 只有「真的换了位置」才调：`from === to`（按下没动）与 `to === null`
   *   （拖到面板外）都不调。宿主拿到这个回调要做的只有一件事 ——
   *   改库存，然后下一帧 `setBag` 自然就对了。
   * ★ 回调里**不要再回调本层**：会让"拖一次"变成两次重排，
   *   而且重排发生在事件投递的中途，行节点的 props 会被换成新文案、
   *   旧的落点标记还挂在上面。
   */
  readonly onSwapRows?: (from: number, to: number) => void;
}

export interface HudUiHandle {
  readonly module: UiModuleHandle;
  readonly built: BuiltSkin;
  /** HUD 三行的节点 id（判据拿它查布局矩形）。 */
  readonly hudRowIds: readonly string[];
  /**
   * 每帧推一次事实。**只改 props，不重建树**；
   * 内容没变（签名相同）时连 `invalidate()` 都不调 —— 否则每帧全量重排。
   */
  setHud(rows: readonly string[], hunger: number | null): void;
  /** 背包内容（`null` = 关闭）。行数/选中/文本都没变时什么也不做。 */
  setBag(stacks: readonly { readonly kind: string; readonly count: number }[] | null, selected: number): void;
  /**
   * 一行提示（`null` = 收起）。
   *
   * ★ 生命周期**不在这里**：本层没有时钟，也不该有（它只把状态映射成节点）。
   *   宿主在 2 秒后调 `setToast(null)` —— 那条 `setTimeout` 本来就在宿主里，
   *   搬进来只会让"提示什么时候消失"变成需要注入时钟才能验的东西。
   * ★ 文案没变时什么都不做：toast 每帧被宿主推一次（存档提示之类），
   *   每次 `invalidate()` 都会让整棵树重排一次，而重排是 O(节点数 + 字数)。
   */
  setToast(text: string | null): void;
  /** 当前提示文案（"" = 没有）。判据读它，而不是去 parse 节点。 */
  readonly toastText: string;
  /**
   * 推一帧指针（**画布相对 CSS 像素**，与 DOM 事件里拿到的一致）。
   *
   * ★ 滚轮量也收 CSS 像素，**在这里**换成设计像素 —— 与坐标走同一个换算。
   *   若让调用方自己换，两处各写一遍 `1/scale`，改动只会落到一处，
   *   症状是"滚一格跳半页"或"滚半天不动"，而且只在高分屏/非 1080p 上出现。
   * ★ DOM 的 `deltaMode`（像素 / 行 / 页）折算成 CSS 像素是**输入后端**的事：
   *   它知道行高与视口高，本层不知道。这里只做"CSS px → 设计 px"这一步。
   */
  pointer(cssX: number, cssY: number, down: boolean, wheelYCss?: number, wheelXCss?: number): UiEvent[];
  /** 背包面板当前的行文本（**画在屏幕上的那份**，不是重新算一遍）。 */
  readonly bagRowTexts: readonly string[];
  readonly bagOpen: boolean;
}

export function createHudUi(opts: HudUiOptions): Result<HudUiHandle, EngineError> {
  const builtR = buildSkin(opts.skinJson, 1);
  if (!builtR.ok) return builtR;
  const built = builtR.value;

  const font = opts.font;
  const lineH = Math.max(1, font.lineHeight);
  const pad = HUD_LAYOUT.pad;
  const gap = HUD_LAYOUT.gap;
  const rowH = lineH + 4;
  // 中文字体在就按它算行高：18 高的字放进 14 高的行里，上下各溢出 2px，
  // 而溢出是**静默**的（画出来就是被切掉一点，判据和日志都不会说话）。
  const cjk = opts.cjkFont;
  const cjkRowH = cjk === undefined ? rowH : Math.max(1, cjk.lineHeight) + 4;
  const bagRowFontId = cjk?.id;
  const maxRows = Math.max(1, opts.maxRows ?? DEFAULT_MAX_ROWS);
  const hudW = HUD_LAYOUT.width;
  const bagW = 268;
  const innerW = bagW - pad * 2;
  /** 标题 1 行 + 行区 + 底栏 2 行（底栏文案会折成两行，见 `bagFooter`）。 */
  const bagH = pad * 2 + lineH + gap + maxRows * cjkRowH + (maxRows - 1) * gap + gap + lineH * 2;
  /** HUD：3 行文本 + 一条饱食度条。 */
  const hudH = pad * 2 + lineH * 3 + gap * 3 + HUD_LAYOUT.bar;

  const white = new Color(1, 1, 1, 1);
  const dim = new Color(0.72, 0.76, 0.82, 1);
  const selTint = new Color(0.42, 0.38, 0.22, 1);
  const rowTint = new Color(0.26, 0.28, 0.34, 0.85);
  const barTint = new Color(0.55, 0.86, 0.45, 1);

  const sliceOf = (name: string): number => built.slice.get(name) ?? 0;

  // ---- HUD：左上角三行 + 一条饱食度条
  const hudRowNodes = [0, 1, 2].map(
    (i) =>
      new UiNode({
        id: `hud.row${String(i)}`,
        widget: UiWidget.Label,
        size: { w: hudW - pad * 2, h: lineH },
        props: { text: "", style: { color: dim } },
      }),
  );
  const fedBar = new UiNode({
    id: "hud.fed",
    widget: UiWidget.Progress,
    size: { w: hudW - pad * 2, h: HUD_LAYOUT.bar },
    props: { frame: "bar", slice: 0, value: 1, activeTint: barTint },
    visible: false,
  });
  const hudPanel = new UiNode({
    id: "hud.panel",
    widget: UiWidget.Panel,
    kind: UiLayoutKind.Column,
    anchor: ANCHOR_TOP_LEFT,
    offset: { x: 8, y: 8 },
    size: { w: hudW, h: hudH },
    padding: { top: pad, right: pad, bottom: pad, left: pad },
    gap,
    props: { frame: "panel", slice: sliceOf("panel"), tint: new Color(1, 1, 1, 0.55) },
  });
  // ★ 用 `add()` 而不是配置里的 `children`：`children` 收的是 `UiNodeConfig`（纯数据），
  //   这里手里已经是**节点实例**（行节点要留着改 props）。两条路都能建树，
  //   混用会得到"改的是 A、画的是 B"——那类问题看起来像"改了没生效"。
  for (const c of [...hudRowNodes, fedBar]) hudPanel.add(c);

  // ---- 背包：常驻 8 行（`visible` 切换），不重建树
  const bagRowsNodes = Array.from({ length: maxRows }, (_, i) => {
    const n = new UiNode({
      id: `bag.row${String(i)}`,
      widget: UiWidget.Button,
      size: { w: innerW, h: cjkRowH },
      interactive: true,
      opaque: true,
      visible: false,
      props: {
        frame: "slot",
        slice: sliceOf("slot"),
        text: "",
        tint: rowTint,
        style: { align: "left", color: white },
        // 行数按行高算出来之后，字体的选择就只剩这一处：没有中文字体时不写这个键，
        // 落到"注册表里第一个字体"（= 5×7），与这批之前完全一样。
        ...(bagRowFontId === undefined ? {} : { fontId: bagRowFontId }),
      },
    });
    return n;
  });
  const bagEmpty = new UiNode({
    id: "bag.empty",
    widget: UiWidget.Label,
    size: { w: innerW, h: rowH },
    visible: false,
    props: { text: bagEmptyLine(opts.hints.pick), style: { color: dim } },
  });
  const bagFoot = new UiNode({
    id: "bag.foot",
    widget: UiWidget.Label,
    size: { w: innerW, h: lineH * 2 },
    props: { text: bagFooter(opts.hints), style: { color: dim } },
  });
  const bagPanel = new UiNode({
    id: "bag.panel",
    widget: UiWidget.Panel,
    kind: UiLayoutKind.Column,
    anchor: ANCHOR_CENTER,
    pivot: ANCHOR_CENTER,
    size: { w: bagW, h: bagH },
    padding: { top: pad, right: pad, bottom: pad, left: pad },
    gap,
    visible: false,
    // ★ `opaque`：面板底色上的一次点击**不该**穿透到背后的东西。
    //   现在面板后面没有可点的节点（HUD 是显示层），但这条语义必须现在就对 ——
    //   等哪天世界里有了"点地面移动"，漏掉它就会变成"点背包面板把角色派出去了"。
    opaque: true,
    props: { frame: "panel", slice: sliceOf("panel"), tint: new Color(1, 1, 1, 0.92) },
  });
  bagPanel.add(bagEmpty);
  for (const n of bagRowsNodes) bagPanel.add(n);
  bagPanel.add(bagFoot);

  // ---- toast：屏幕底部中央一行提示
  //
  // ★ 这是宿主最后一块**手写 DOM**（`web/index.html` 的 `#toast`）。搬进 UI 树之后
  //   "提示"与"游戏内文字"用同一张位图字体、同一个 pass、同一套九宫格边框 ——
  //   在此之前它们在字体、抗锯齿、边框圆角、缩放四件事上全都不一样。
  //
  // ★ 宽度取定值而不是跟着文本走：toast 出现在**屏幕中央底部**，宽度随文本变会让
  //   它每次弹出都左右抖一下（居中对齐时左边与右边同时移动）。定宽 + 单行 + 省略号
  //   是提示条该有的行为：短提示居中，长提示被截断而不是换行把面板撑高。
  const toastW = Math.min(HUD_LAYOUT.width, 560);
  const toastH = cjkRowH + pad * 2;
  const toastLine = new UiNode({
    id: "toast.line",
    widget: UiWidget.Label,
    size: { w: toastW - pad * 2, h: cjkRowH },
    // free 容器里子节点靠 offset 定位（父的内区 + offset）
    offset: { x: pad, y: pad },
    props: {
      text: "",
      style: { align: "center", color: white, maxLines: 1, ellipsis: "…" },
      ...(bagRowFontId === undefined ? {} : { fontId: bagRowFontId }),
    },
  });
  const toastPanel = new UiNode({
    id: "toast.panel",
    widget: UiWidget.Panel,
    anchor: ANCHOR_BOTTOM_CENTER,
    pivot: ANCHOR_BOTTOM_CENTER,
    // 从屏幕底边往上抬 28：避开最下面那行键位提示
    offset: { x: 0, y: -28 },
    size: { w: toastW, h: toastH },
    visible: false,
    // ★ **不吃点击也不挡下层**：提示条正好压在屏幕中下部，而那里是玩家点世界的地方。
    //   `opaque=true` 会让底部一条 24px 高的区域静默失效 —— 玩家只会觉得"这里点不动"。
    opaque: false,
    interactive: false,
    props: { frame: "panel", slice: sliceOf("panel"), tint: new Color(1, 1, 1, 0.92) },
  });
  toastPanel.add(toastLine);

  const root = new UiNode({ id: "ui.root" });
  root.add(hudPanel);
  root.add(bagPanel);
  // ★ 最后 add：绘制顺序 = children 顺序，提示必须在最上层（背包开着时也要看得见）
  root.add(toastPanel);

  /**
   * 从事件目标往上找**背包行**的下标（不是行内节点则 `null`）。
   *
   * ★ 用「沿父链找」而不是 `ev.target.id` 直接匹配：行现在是叶子节点，
   *   但哪天给它加个图标子节点，`target` 就变成那个子节点了 ——
   *   直接匹配会静默失效（拖拽整个不工作，而没有任何报错）。
   */
  const rowIndexOf = (node: UiNode | null): number | null => {
    let cur = node;
    while (cur !== null) {
      const m = /^bag\.row(\d+)$/.exec(cur.id);
      if (m !== null) return Number(m[1]);
      cur = cur.parent;
    }
    return null;
  };

  /**
   * 只认目标本身的 click：冒泡会把同一件事投给每一层祖先。
   *
   * ★★ 拖拽换位在这一层做，而且**归 UI 管**：它需要的东西（按下捕获、位移阈值、
   *   逐帧命中）全在 `UiInputRouter` 里，宿主只有"指针在哪、按着没有"两个数。
   *   放到宿主去写，就得再实现一遍捕获与阈值 —— 两份实现必然漂移成
   *   "点一下算拖"或"拖动被当成点击"。
   * ★ 落点状态 `drag*` 只在这里改，`renderBag()` 是唯一的出口：
   *   跳过一次重排，标记就会留在屏幕上，而"拖完还亮着"看起来像卡住了。
   */
  const onEvent = (ev: UiEvent): void => {
    const row = rowIndexOf(ev.target);
    // 只在冒泡到**行节点本身**时处理一次（行是叶子，等于第一次投递；行有子节点时也不重复）
    if (row !== null && ev.currentTarget.id === `bag.row${String(row)}`) {
      if (ev.type === "pointerdown") {
        dragFrom = row;
        dragTo = row;
        renderBag();
        return;
      }
      if (ev.type === "pointermove") {
        if (dragFrom !== null && dragTo !== row) {
          dragTo = row;
          renderBag();
        }
        return;
      }
      if (ev.type === "pointerleave") {
        // 离开某一行 ⇒ 它不再是落点。**不清 `dragFrom`**：手还按着，拖出去再拖回来照常。
        if (dragFrom !== null && dragTo === row) {
          dragTo = null;
          renderBag();
        }
        return;
      }
    }
    if (ev.type === "pointerup") {
      if (ev.currentTarget !== ev.target) return;
      if (dragFrom === null) return;
      const from = dragFrom;
      const to = dragTo;
      dragFrom = null;
      dragTo = null;
      renderBag();
      if (to !== null && to !== from) opts.onSwapRows?.(from, to);
      return;
    }
    if (ev.type !== "click") return;
    if (ev.currentTarget !== ev.target) return;
    if (row === null) return;
    opts.onSelectRow(row);
  };

  const module = createUiModule({
    id: "ui.hud",
    viewport: opts.viewport,
    skin: built.skin,
    // 页号是**全局下标**：0=5×7 字形、1=皮肤、2=中文字形（`.fnt` 里写的就是这三个号）
    pageSources: cjk === undefined ? [opts.fontPage, opts.skinPage] : [opts.fontPage, opts.skinPage, opts.cjkPage!],
    fonts: cjk === undefined ? [font] : [font, cjk],
    root,
    dpr: opts.dpr ?? 1,
    onEvent,
  });

  let hudSig = "";
  let bagSig = "";
  let bagOpenState = false;
  let bagTexts: readonly string[] = [];
  let toastText = "";
  /** 背包当前内容与选中（拖拽重排要重新算行文案，不能只靠 `setBag` 的入参）。 */
  let bagStacks: readonly { readonly kind: string; readonly count: number }[] = [];
  let bagSel = 0;
  /** 拖拽状态（见 `BagDragState`）。只在 `onEvent` 里改。 */
  let dragFrom: number | null = null;
  let dragTo: number | null = null;

  /**
   * 按当前内容 + 选中 + 拖拽状态把行画出来。
   *
   * ★ 签名里带上 `drag` 标记（`#from` / `#to`）：不带的话「拖到隔壁那行」会算出
   *   与上一帧相同的签名，直接 return —— 落点标记永远不出现，而拖拽本身是好的。
   */
  function renderBag(): void {
    const open = bagOpenState;
    if (!open) {
      const closed = "#closed";
      if (closed === bagSig) return;
      bagSig = closed;
      bagPanel.visible = false;
      bagTexts = [];
      module.invalidate();
      return;
    }
    const rows = bagRows(bagStacks, bagSel, opts.labelOf, { from: dragFrom, to: dragTo });
    const sig = rows.map((r) => `${r.text}#${r.selected ? 1 : 0}`).join("|");
    if (sig === bagSig) return;
    bagSig = sig;
    bagPanel.visible = true;
    const shown = Math.min(rows.length, maxRows);
    for (let i = 0; i < maxRows; i++) {
      const n = bagRowsNodes[i]!;
      const r = i < shown ? rows[i] : undefined;
      n.visible = r !== undefined;
      if (r === undefined) continue;
      n.props = {
        ...n.props,
        text: r.text,
        tint: r.selected ? selTint : rowTint,
        textColor: white,
      };
    }
    bagEmpty.visible = rows.length === 0;
    bagTexts = rows.map((r) => r.text);
    module.invalidate();
  }

  const api: HudUiHandle = {
    module,
    built,
    hudRowIds: hudRowNodes.map((n) => n.id),

    get bagRowTexts(): readonly string[] {
      return bagTexts;
    },
    get bagOpen(): boolean {
      return bagOpenState;
    },

    setHud(rows: readonly string[], hunger: number | null): void {
      const text0 = rows[0] ?? "";
      const text1 = rows[1] ?? "";
      const text2 = rows[2] ?? "";
      // 签名 = 三行文本 + 有无饱食条 + 条的值（取两位小数，避免每帧浮点抖动重排）
      const sig = `${text0}\u0001${text1}\u0001${text2}\u0001${hunger === null ? "-" : hunger.toFixed(2)}`;
      if (sig === hudSig) return;
      hudSig = sig;
      const texts = [text0, text1, text2];
      hudRowNodes.forEach((n, i) => {
        n.props = { ...n.props, text: texts[i] ?? "" };
      });
      fedBar.visible = hunger !== null;
      fedBar.props = { ...fedBar.props, value: hunger === null ? 0 : Math.max(0, Math.min(1, hunger)) };
      module.invalidate();
    },

    setBag(stacks, selected): void {
      const open = stacks !== null;
      bagOpenState = open;
      bagStacks = stacks ?? [];
      bagSel = selected;
      // 关面板时拖拽状态必须一起清：下次打开还留着 `dragFrom=2` 的话，
      // 第一帧就会画出一个"正被拖着的第 3 行"，而没人按着鼠标。
      if (!open) {
        dragFrom = null;
        dragTo = null;
      }
      renderBag();
    },

    setToast(text: string | null): void {
      const next = text ?? "";
      if (next === toastText) return;
      toastText = next;
      toastPanel.visible = next !== "";
      toastLine.props = { ...toastLine.props, text: next };
      module.invalidate();
    },

    get toastText(): string {
      return toastText;
    },

    pointer(cssX: number, cssY: number, down: boolean, wheelYCss = 0, wheelXCss = 0): UiEvent[] {
      const p = module.viewport.screenToDesign(cssX, cssY);
      // 与位置同一个除数（`screenToDesign` 里也是除 `scale`）：两处用同一个约定，
      // 否则"滚一格"和"移动一格"会不一致，而那种不一致只在某些分辨率下看得出来。
      const k = module.viewport.scale > 0 ? 1 / module.viewport.scale : 1;
      const ptr: UiPointer = { x: p.x, y: p.y, down, wheelY: wheelYCss * k, wheelX: wheelXCss * k };
      return module.pointer(ptr);
    },
  };
  return ok(api);
}

/** 某个节点现在在设计坐标里的矩形（判据用：点击坐标要打在真实矩形上）。 */
export function rectOfId(handle: HudUiHandle, id: string): Rect | undefined {
  return handle.module.layout.get(id);
}
