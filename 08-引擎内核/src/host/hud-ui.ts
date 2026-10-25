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
  readonly skinJson: UiSkinJson;
  /** 字形图（页 0）与皮肤图（页 1）的像素数据。 */
  readonly fontPage: UiPageSource;
  readonly skinPage: UiPageSource;
  readonly viewport: UiViewportConfig;
  readonly dpr?: number;
  /** 背包最多几行；超出部分**不画**（背包本身会拒绝第 9 堆）。 */
  readonly maxRows?: number;
  /** 键位提示（从映射表生成，这里只拼接）。 */
  readonly hints: { readonly drop: string; readonly bag: string; readonly pick: string };
  /** 点了第 i 行（0 起）。**只在真的 click 时调**，不是每帧调。 */
  readonly onSelectRow: (index: number) => void;
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
  /** CSS 像素坐标 → 设计坐标 → 路由。返回本帧事件（判据用）。 */
  pointer(cssX: number, cssY: number, down: boolean): UiEvent[];
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
  const maxRows = Math.max(1, opts.maxRows ?? DEFAULT_MAX_ROWS);
  const hudW = HUD_LAYOUT.width;
  const bagW = 268;
  const innerW = bagW - pad * 2;
  /** 标题 1 行 + 行区 + 底栏 2 行（底栏文案会折成两行，见 `bagFooter`）。 */
  const bagH = pad * 2 + lineH + gap + maxRows * rowH + (maxRows - 1) * gap + gap + lineH * 2;
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
      size: { w: innerW, h: rowH },
      interactive: true,
      opaque: true,
      visible: false,
      props: { frame: "slot", slice: sliceOf("slot"), text: "", tint: rowTint, style: { align: "left", color: white } },
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

  const root = new UiNode({ id: "ui.root" });
  root.add(hudPanel);
  root.add(bagPanel);

  /** 只认目标本身的 click：冒泡会把同一件事投给每一层祖先。 */
  const onEvent = (ev: UiEvent): void => {
    if (ev.type !== "click") return;
    if (ev.currentTarget !== ev.target) return;
    const m = /^bag\.row(\d+)$/.exec(ev.target.id);
    if (m === null) return;
    opts.onSelectRow(Number(m[1]));
  };

  const module = createUiModule({
    id: "ui.hud",
    viewport: opts.viewport,
    skin: built.skin,
    pageSources: [opts.fontPage, opts.skinPage],
    fonts: [font],
    root,
    dpr: opts.dpr ?? 1,
    onEvent,
  });

  let hudSig = "";
  let bagSig = "";
  let bagOpenState = false;
  let bagTexts: readonly string[] = [];

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
      const list = stacks ?? [];
      const rows = bagRows(list, selected);
      const sig = open ? `${rows.map((r) => `${r.text}#${r.selected ? 1 : 0}`).join("|")}` : "#closed";
      if (sig === bagSig) return;
      bagSig = sig;
      bagOpenState = open;
      bagPanel.visible = open;
      if (!open) {
        bagTexts = [];
        module.invalidate();
        return;
      }
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
    },

    pointer(cssX: number, cssY: number, down: boolean): UiEvent[] {
      const p = module.viewport.screenToDesign(cssX, cssY);
      const ptr: UiPointer = { x: p.x, y: p.y, down };
      return module.pointer(ptr);
    },
  };
  return ok(api);
}

/** 某个节点现在在设计坐标里的矩形（判据用：点击坐标要打在真实矩形上）。 */
export function rectOfId(handle: HudUiHandle, id: string): Rect | undefined {
  return handle.module.layout.get(id);
}
