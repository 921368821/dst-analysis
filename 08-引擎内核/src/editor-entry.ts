/**
 * 编辑器宿主入口（L6）：阶段 4 的最小闭环
 *
 * 这一页只做四件事，但它们就是"编辑器"这个词的全部含义：
 * **看得见世界（树）→ 选得中节点 → 改得动属性 → 跑得起来（PIE）**。
 *
 * ★ 三条边界，写在最前面，因为它们决定了这个文件能不能长大：
 *
 * ① **面板不直接改场景**。所有改动都走 `setField()`（`extensions/editor/property-model.ts`），
 *    于是"校验失败不写入""Int 不收 3.5"这些规则只有一份，
 *    不会出现"面板里改是错的、命令里改是对的"这种分叉。
 *
 * ② **PIE 不自己调 `scene.step`**。走 `pie.advance(dt)` 拿到"这一帧该跑几个 tick"，
 *    再逐个 `app.frame(fixedDt)` —— `frame` 是 `GameApp` 里唯一的帧入口，
 *    绕过去就等于把渲染、丢弃统计、事件全部漏掉（而画面上看不出来）。
 *
 * ③ **`window.__editor` 与 UI 走同一条代码路径**。它是给自动化判据用的命令面，
 *    不是"给测试用的后门"：如果它和按钮的路径不同，那判据证明的就不是用户看到的东西。
 *    这与 `__engine.nav` 同一条理由（批60）。
 *
 * 世界用生成计划现造（`generateWorld`），不读存档：编辑器打开就该看到一个世界，
 * 而不是先让人去"打开一个场景"——那是第二阶段才需要的东西。
 */

import { bootGameApp, type GameApp } from "./runtime/GameApp.ts";
import { BackendRegistry } from "./platform/registry.ts";
import { registerNullBackends } from "./backends/index.ts";
import { webgl2Backend } from "./backends/gfx-webgl2/device.ts";
import { domInputBackend } from "./backends/input-dom/device.ts";
import { webAudioBackend } from "./backends/audio-webaudio/device.ts";
import { Services } from "./core/tokens.ts";
import { Sprite, SPRITE_TYPE } from "./extensions/render/sprite.ts";
import { buildProceduralAtlas } from "./extensions/render/atlas.ts";
import { createRenderModule } from "./extensions/render/render-module.ts";
import { SpatialHashWorld, makeSceneAccessor } from "./extensions/physics/physics.ts";
import { createWorldModule } from "./extensions/physics/world-step-module.ts";
import { generateWorld } from "./extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "./extensions/worldgen/assemble.ts";
import { registerPlayerComponent, spawnPlayer } from "./extensions/worldgen/spawn.ts";
import { attachWorldVisuals } from "./extensions/render/world-visuals.ts";
import { registerInventoryComponents } from "./extensions/inventory/inventory.ts";
import type { IModule, ModuleContext } from "./core/module/module.ts";
import type { EngineError } from "./foundation/result.ts";
import { err, engineError, ok, type Result } from "./foundation/result.ts";
import type { NodeId } from "./core/scene/node.ts";
import { buildOutline, flattenOutline, type OutlineRow } from "./extensions/editor/outline.ts";
import { createSelection } from "./extensions/editor/selection.ts";
import {
  exportDocument,
  newDocument,
  openDocument,
  type OpenReport,
  type SessionDeps,
} from "./extensions/editor/session.ts";
import { fieldsOf, setField, type FieldChange } from "./extensions/editor/property-model.ts";
import { beginDrag, dragTarget, endDrag, pickAt, type DragState } from "./extensions/editor/gizmo.ts";
import { createPie } from "./extensions/editor/pie.ts";
import { createUndoStack, type EditorOp, type UndoOutcome } from "./extensions/editor/undo-stack.ts";
import { HttpFileSystem } from "./backends/fs-http/fs.ts";
import {
  EDIT_BAD_ASSET_LIST,
  catalogFromManifest,
  type AssetCatalog,
  type AssetEntry,
} from "./extensions/editor/asset-list.ts";
import {
  addSpriteNodeWithUndo,
  attachComponentWithUndo,
  createNodeWithUndo,
  deleteNodeWithUndo,
  detachComponentWithUndo,
  makeFieldOp,
  reparentWithUndo,
  topmostIds,
} from "./extensions/editor/undo-ops.ts";

const WORLD_SEED = 20261025;
const WORLD_W = 26;
const WORLD_H = 18;
const HZ = 30;
const FIXED_DT = 1 / HZ;

function need<T extends HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (el === null) throw new Error(`页面结构不完整：缺 #${id}`);
  return el as T;
}

const canvas = need<HTMLCanvasElement>("cv");
const treeEl = need<HTMLDivElement>("tree");
const propsEl = need<HTMLDivElement>("props");
const statusEl = need<HTMLSpanElement>("status");
const errEl = need<HTMLSpanElement>("err");
const tickEl = need<HTMLSpanElement>("tick");
const pieInfoEl = need<HTMLSpanElement>("pieinfo");
const btnPlay = need<HTMLButtonElement>("btn-play");
const btnPause = need<HTMLButtonElement>("btn-pause");
const btnStep = need<HTMLButtonElement>("btn-step");
const btnStep10 = need<HTMLButtonElement>("btn-step10");
const btnUndo = need<HTMLButtonElement>("btn-undo");
const btnRedo = need<HTMLButtonElement>("btn-redo");
const btnAdd = need<HTMLButtonElement>("btn-add");
const btnDel = need<HTMLButtonElement>("btn-del");
const histEl = need<HTMLSpanElement>("hist");
const btnSave = need<HTMLButtonElement>("btn-save");
const btnOpen = need<HTMLButtonElement>("btn-open");
const btnNew = need<HTMLButtonElement>("btn-new");
const docText = need<HTMLTextAreaElement>("doctext");
const docInfoEl = need<HTMLSpanElement>("docinfo");
const assetListEl = need<HTMLDivElement>("assetlist");
const assetCountEl = need<HTMLSpanElement>("assetcount");
const btnAssetAdd = need<HTMLButtonElement>("asset-add");

const dpr = Math.min(2, window.devicePixelRatio || 1);
// 首次位图尺寸：必须在 `createRenderModule` **之前**定好，它用这个值建初始视口。
canvas.width = Math.max(1, Math.floor((canvas.clientWidth || 640) * dpr));
canvas.height = Math.max(1, Math.floor((canvas.clientHeight || 420) * dpr));

const selection = createSelection();
const pie = createPie({ hz: HZ, maxStepTicks: 4 });
const history = createUndoStack();

let appRef: GameApp | null = null;
let heroId: NodeId = -1;
let booted = false;

// ---------------------------------------------------------------- 后端
const registry = new BackendRegistry();
registerNullBackends(registry);
registry.registerGfx(webgl2Backend, 100);
registry.registerInput(domInputBackend, 100);
registry.registerAudio(webAudioBackend, 100);

const physics = new SpatialHashWorld(
  makeSceneAccessor((id) => {
    const n = appRef?.scene.find(id);
    if (n === undefined) return undefined;
    return {
      id: n.id,
      worldPosition: () => n.worldPosition,
      setLocalPosition: (x: number, y: number) => n.setLocalPosition(x, y),
    };
  }),
  { maxIterations: 3 },
);

const renderMod = createRenderModule({
  viewportWidth: canvas.width,
  viewportHeight: canvas.height,
  zoom: 24 * dpr,
  tiltY: 0.62,
  follow: () => {
    if (heroId < 0) return undefined;
    const n = appRef?.scene.find(heroId);
    if (n === undefined) return undefined;
    const p = n.worldPosition;
    return { x: p.x, z: p.y };
  },
});

/**
 * 位图尺寸跟着 CSS 尺寸走。
 *
 * ★ 只在启动时算一次是**不够**的，而且错了不容易捉：布局一变（属性面板多一行、
 *   文档区展开、窗口缩放），canvas 的 CSS 尺寸变了而位图没变 ⇒ 画面被拉伸，
 *   **点击位置也跟着偏**（相机按位图算投影，pointer 给的是 CSS px）。
 *   批84 的判据「画布中心 → 相机中心」先红后绿，就是这条的表征。
 *
 * ★ 改尺寸必须走 `renderMod.resize()`，不能直接设 `canvas.width/height` ——
 *   后端把尺寸缓存在 `device.size` 里（构造时读一次），绕过后端改 canvas
 *   会让它的视口与真实 backing store 脱节（画面压扁、`camera.vw/vh` 也跟着错）。
 *
 * ★ 用 `ResizeObserver` 而不是 `window.onresize`：后者只听窗口，而这次的原因
 *   恰恰是"窗口没动、只是面板撑高了"。
 */
function syncViewport(): void {
  const w = Math.max(1, Math.floor((canvas.clientWidth || 640) * dpr));
  const h = Math.max(1, Math.floor((canvas.clientHeight || 420) * dpr));
  if (canvas.width === w && canvas.height === h) return;
  renderMod.resize(w, h);
}
syncViewport();
if (typeof ResizeObserver !== "undefined") new ResizeObserver(syncViewport).observe(canvas);
else window.addEventListener("resize", syncViewport);

const worldMod = createWorldModule(physics, {});

// ---------------------------------------------------------------- 世界装配模块
const atlasFrames: readonly string[] = [...buildProceduralAtlas().frames.keys()];
let planRef: ReturnType<typeof generateWorld> | null = null;

const worldgenMod: IModule = {
  id: "editor.worldgen",
  init(ctx: ModuleContext): Result<void, EngineError> {
    const scene = ctx.services.require(Services.Scene);
    const p = planRef;
    if (p === null || !p.ok) {
      return err(engineError("EDITOR.NO_PLAN", "世界计划没有生成出来"));
    }
    registerWorldComponents(scene.components);
    registerPlayerComponent(scene.components);
    registerInventoryComponents(scene.components);
    if (!scene.components.has(SPRITE_TYPE)) {
      scene.components.register(new Sprite().schema, () => new Sprite());
    }
    const a = assembleWorld(p.value, scene);
    if (!a.ok) return a;
    const v = attachWorldVisuals(scene, atlasFrames);
    if (!v.ok) return v;
    const sp = spawnPlayer(scene, p.value);
    if (!sp.ok) return sp;
    heroId = sp.value.nodeId;
    return ok(undefined);
  },
  describe(): string {
    return "编辑器世界";
  },
};

// ---------------------------------------------------------------- UI：场景树
function refreshTree(): void {
  const app = appRef;
  if (app === null) return;
  const o = buildOutline(app.scene, { skipTypes: [] });
  const rows = flattenOutline(o.root);
  const box = document.createElement("div");
  for (const r of rows) {
    box.appendChild(treeRow(r));
  }
  treeEl.replaceChildren(box);
  statusEl.textContent = `${String(o.count)} 个节点${o.truncated ? "（已截断）" : ""} · 世界 ${String(WORLD_W)}×${String(WORLD_H)}`;
}

function treeRow(r: OutlineRow): HTMLElement {
  const el = document.createElement("div");
  el.className = `row${selection.has(r.node.id) ? " sel" : ""}`;
  el.style.paddingLeft = `${String(6 + r.depth * 10)}px`;
  el.dataset["id"] = String(r.node.id);
  const id = document.createElement("span");
  id.className = "id";
  id.textContent = `#${String(r.node.id)} `;
  el.append(id, document.createTextNode(r.node.name));
  el.addEventListener("click", () => {
    if (selection.toggle(r.node.id)) selection.select(r.node.id);
    refreshTree();
    refreshProps();
  });
  return el;
}

// ---------------------------------------------------------------- UI：属性面板
function refreshProps(): void {
  const app = appRef;
  const primary = selection.primary;
  if (app === null || primary === null) {
    propsEl.replaceChildren(mkEmpty("未选中"));
    return;
  }
  const node = app.scene.find(primary);
  if (node === undefined) {
    propsEl.replaceChildren(mkEmpty("选中的节点已不存在"));
    return;
  }
  const frag = document.createDocumentFragment();
  const h = document.createElement("h2");
  h.textContent = `${node.name}  #${String(node.id)}`;
  frag.appendChild(h);
  // ★ 「挂组件」放在字段上面：先有组件才有字段，人往下读的顺序要和因果一致。
  frag.appendChild(mkCompAdd(primary, node));
  if (node.components.length === 0) {
    const e = document.createElement("div");
    e.className = "empty";
    e.textContent = "这个节点没有组件";
    frag.appendChild(e);
  }
  for (const comp of node.components) {
    const t = document.createElement("h3");
    t.textContent = comp.type;
    const off = document.createElement("button");
    off.className = "comp-off";
    off.dataset["detach"] = comp.type;
    off.textContent = "卸下";
    // ★ 不传实例、只传类型：卸下是"这个节点上的这一类"，而实例归属由撤销层判断
    //   （它会比对"节点上那个还是不是历史记的那个"，不是就拒绝 —— 见 undo-ops）。
    off.addEventListener("click", () => {
      doDetachComp(comp.type);
    });
    t.appendChild(off);
    frag.appendChild(t);
    for (const f of fieldsOf(comp)) {
      frag.appendChild(propRow(primary, comp.type, f.key, f.control, f.value));
    }
  }
  propsEl.replaceChildren(frag);
}

/** 这个节点还能挂哪些类型（注册表里有、且它还没挂的）。 */
function availableTypes(node: { components: readonly { type: string }[] }): string[] {
  const app = appRef;
  if (app === null) return [];
  const has = new Set(node.components.map((c) => c.type));
  return app.scene.components.types().filter((t) => !has.has(t));
}

function mkCompAdd(nodeId: NodeId, node: { components: readonly { type: string }[] }): HTMLElement {
  const row = document.createElement("div");
  row.className = "comp-add";
  const types = availableTypes(node);
  const sel = document.createElement("select");
  sel.id = "comp-pick";
  for (const t of types) {
    const o = document.createElement("option");
    o.value = t;
    o.textContent = t;
    sel.appendChild(o);
  }
  const btn = document.createElement("button");
  btn.id = "btn-comp-add";
  btn.textContent = "挂上组件";
  // 全都挂满了 ⇒ 没有可选项。按钮置灰而不是"点了没反应"。
  btn.disabled = types.length === 0;
  btn.addEventListener("click", () => {
    if (sel.value !== "") doAttachComp(sel.value, nodeId);
  });
  row.append(sel, btn);
  return row;
}

function mkEmpty(text: string): HTMLElement {
  const d = document.createElement("div");
  d.className = "empty";
  d.textContent = text;
  return d;
}

function displayValue(control: string, v: unknown): string {
  if (control === "vec2") {
    const o = v as { x?: number; y?: number };
    return `${String(o.x ?? 0)}, ${String(o.y ?? 0)}`;
  }
  if (control === "color") {
    const o = v as { r?: number; g?: number; b?: number; a?: number };
    const hex = (n: number): string => Math.round(Math.max(0, Math.min(1, n)) * 255).toString(16).padStart(2, "0");
    return `#${hex(o.r ?? 1)}${hex(o.g ?? 1)}${hex(o.b ?? 1)}${hex(o.a ?? 1)}`;
  }
  if (control === "tags") return Array.isArray(v) ? v.join(", ") : String(v);
  return String(v);
}

function propRow(
  nodeId: NodeId,
  type: string,
  key: string,
  control: string,
  value: unknown,
): HTMLElement {
  const row = document.createElement("div");
  row.className = "f";
  const label = document.createElement("label");
  label.textContent = key;
  label.title = `${type}.${key}`;
  const input = document.createElement("input");
  input.type = control === "checkbox" ? "checkbox" : "text";
  if (control === "checkbox") input.checked = value === true;
  else input.value = displayValue(control, value);
  const ty = document.createElement("span");
  ty.className = "ty";
  ty.textContent = control;

  const commit = (): void => {
    const raw = control === "checkbox" ? input.checked : input.value;
    const r = commitField(nodeId, type, key, raw);
    if (r.ok) {
      input.classList.remove("bad");
      errEl.textContent = "";
    } else {
      input.classList.add("bad");
      errEl.textContent = `${r.error.code}：${r.error.message}`;
    }
  };
  // ★ 为什么用 change 而不是 input：每敲一个字符就校验一次会出现
  //   "删掉 12 的 1 之后 2 通过校验并立刻写进去" —— 人还没打完，值已经变了。
  input.addEventListener("change", commit);
  row.append(label, input, ty);
  return row;
}

// ---------------------------------------------------------------- 历史（撤销 / 重做）

/**
 * 改一个字段，并把这次改动记进历史。
 *
 * ★ 面板的输入框与命令面（自检页）**共用这一个入口**。分成两条路的话，
 *   自检验证的就不是用户点的那条代码 —— 那种判据最容易绿得毫无意义。
 */
function commitField(nodeId: NodeId, type: string, key: string, raw: unknown): Result<FieldChange, EngineError> {
  const app = appRef;
  if (app === null) return err(engineError("EDIT.NOT_READY", "编辑器还没启动"));
  const r = setField(app.scene, nodeId, type, key, raw);
  if (!r.ok) return r;
  // 值没变就不进历史（见 `FieldChange.changed` 的注释：否则历史被空改动填满）
  if (r.value.changed) {
    history.push(makeFieldOp(app.scene, nodeId, type, key, r.value.before, r.value.after));
    refreshHistory();
  }
  return r;
}

// ---------------------------------------------------------------- 文档（保存 / 打开 / 新建）

function docDeps(app: GameApp): SessionDeps {
  // ★ 注册表从场景上取（它就是场景的组件注册表），不要再传一份 ——
  //   两份注册表会让"打开后组件能不能装配"取决于编辑器当时拿的是哪一份。
  return { scene: app.scene, registry: app.scene.components, history, selection };
}

function describeDoc(r: OpenReport): string {
  const parts = [`${String(r.made)} 个节点`];
  if (r.droppedHistory > 0) parts.push(`清掉 ${String(r.droppedHistory)} 条历史`);
  if (r.droppedSelection > 0) parts.push(`清掉 ${String(r.droppedSelection)} 项选中`);
  if (r.skipped.length > 0) parts.push(`${String(r.skipped.length)} 条被跳过`);
  return parts.join(" · ");
}

/** 导出的文本同时写进文本框（能看见、能选中、能贴到别处）。 */
function doSaveDoc(): boolean {
  const app = appRef;
  if (app === null) return false;
  const r = exportDocument(docDeps(app));
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return false;
  }
  docText.value = r.value;
  docInfoEl.textContent = `已导出 ${String(r.value.length)} 字节`;
  errEl.textContent = "";
  return true;
}

function afterDocChange(): void {
  // 打开/新建都不进历史，所以这里不走 `afterHistoryChange` 的撤销收尾，
  // 但**必须**重画：树、面板、历史三处都变了。
  refreshTree();
  refreshProps();
  refreshHistory();
}

function doOpenDoc(text?: string): { ok: boolean; made?: number; code?: string; message?: string } {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY" };
  const r = openDocument(docDeps(app), text ?? docText.value);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  docInfoEl.textContent = describeDoc(r.value);
  errEl.textContent = r.value.skipped.length > 0 ? `有 ${String(r.value.skipped.length)} 处被跳过（见控制台）` : "";
  if (r.value.skipped.length > 0) console.warn("打开文档时跳过：", r.value.skipped);
  afterDocChange();
  return { ok: true, made: r.value.made };
}

function doNewDoc(): { ok: boolean; made?: number; code?: string; message?: string } {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY" };
  const r = newDocument(docDeps(app));
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  docInfoEl.textContent = describeDoc(r.value);
  errEl.textContent = "";
  afterDocChange();
  return { ok: true, made: r.value.made };
}

function refreshHistory(): void {
  btnUndo.disabled = !history.canUndo;
  btnRedo.disabled = !history.canRedo;
  const h = history.history();
  const parts = [`历史 ${String(h.undo.length)} 步可撤销 · ${String(h.redo.length)} 步可重做`];
  if (h.dropped > 0) parts.push(`更早的 ${String(h.dropped)} 条已丢弃`);
  if (history.nextUndoLabel !== null) parts.push(`待撤销：${history.nextUndoLabel}`);
  if (history.nextRedoLabel !== null) parts.push(`待重做：${history.nextRedoLabel}`);
  histEl.textContent = parts.join(" · ");
}

/**
 * 挂一个组件（进历史）。`nodeId` 缺省用当前选中项。
 *
 * ★ 这里必须 `try/catch`：`onAttach` 抛出去的时候，组件**已经**被 push 进
 *   `node.components` 了（`Node.attach` 的顺序是「改归属 → push → onAttach」）。
 *   不管的话，节点上会留一个挂了一半、面板上看得见、又不在任何历史里的组件。
 *   所以失败时按类型把它卸掉，再报错。
 */
function doAttachComp(type: string, nodeId?: NodeId): { ok: boolean; code?: string; message?: string } {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  const id = nodeId ?? selection.primary;
  if (id === null) return { ok: false, code: "EDIT.BAD_NODE", message: "没有选中任何节点" };
  let r: ReturnType<typeof attachComponentWithUndo>;
  try {
    r = attachComponentWithUndo(app.scene, app.scene.components, id, type);
  } catch (e) {
    // 半个组件留在节点上了 —— 先清干净再说失败。
    app.scene.detach(id, type);
    app.scene.flush();
    const msg = `挂 ${type} 时组件自己抛了：${e instanceof Error ? e.message : String(e)}（已回滚）`;
    errEl.textContent = msg;
    afterHistoryChange();
    return { ok: false, code: "EDIT.BAD_COMP", message: msg };
  }
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  return commitOp(r.value.op);
}

/**
 * 一次编辑器操作的收尾：压历史 → 清错误行 → 重画三处。
 *
 * ★ 抽出来不只是为了少两行：挂、卸、换父如果各写一份，三处**必须**都调 `history.push`，
 *   而漏掉任何一处都只表现为「撤销按钮没亮」，看起来像撤销栈坏了。
 *   共用一份之后，变异校验只要打这一行就能同时覆盖三个方向。
 */
function commitOp(op: EditorOp): { ok: boolean; code?: string; message?: string } {
  const pushed = history.push(op);
  if (!pushed.ok) {
    errEl.textContent = `${pushed.error.code}：${pushed.error.message}`;
    return { ok: false, code: pushed.error.code, message: pushed.error.message };
  }
  errEl.textContent = "";
  afterHistoryChange();
  return { ok: true };
}

/** 卸一个组件（进历史）。实例不会丢：撤销就是把它原样挂回去。 */
function doDetachComp(type: string, nodeId?: NodeId): { ok: boolean; code?: string; message?: string } {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  const id = nodeId ?? selection.primary;
  if (id === null) return { ok: false, code: "EDIT.BAD_NODE", message: "没有选中任何节点" };
  const r = detachComponentWithUndo(app.scene, id, type);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  return commitOp(r.value.op);
}

// ---------------------------------------------------------------- 画布拖拽（gizmo）

/** 拖拽时是否吸附到格。0 = 自由拖。 */
const DRAG_SNAP = 0;

let dragRef: DragState | null = null;

/**
 * 画布内坐标（CSS px，左上为 0）→ 世界 XZ。
 *
 * ★★ 缩放比**从相机视口反推**，不要假设它等于 `dpr`。理由有两条，都是实测来的：
 *
 *   ① 相机是按**位图**尺寸算投影的（`camera.vw/vh` 来自后端的 drawable 尺寸），
 *      而 pointer 给的是 CSS px，所以两者之间要除一个比例 —— 那个比例是
 *      `位图 / CSS`，它与 `dpr` 相等**只在位图已经跟 CSS 同步时**成立；
 *   ② `ResizeObserver` 的回调是**异步**的（可能晚一帧）。布局一变（属性面板多一行、
 *      文档区展开），就会有一小段时间"CSS 已变、位图未变"。此时用 `dpr` 换算会偏，
 *      而用 `camera.vw / clientWidth` 换算**永远准** —— 因为它是从同一个视口反推的。
 *
 *   批84 的判据「画布中心 → 相机中心」先红后绿（同一份代码两次不同结果），
 *   就是这条时序问题的表征；改成反推之后连跑多次稳定。
 */
function canvasToWorld(cssX: number, cssY: number): { x: number; z: number } {
  const c = renderMod.camera;
  const cw = canvas.clientWidth;
  const ch = canvas.clientHeight;
  const sx = cw > 0 ? c.vw / cw : dpr;
  const sy = ch > 0 ? c.vh / ch : dpr;
  return c.unproject(cssX * sx, cssY * sy);
}

function dragBeginWorld(wx: number, wz: number): { ok: boolean; node?: number; code?: string; message?: string } {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  // ★ 播放中拒绝拖拽：移动系统每帧都会按导航改位置，拖完立刻被改回去 ——
  //   人看到的是「拖了但没动」，比明确拒绝更让人困惑。
  if (pie.isPlaying) {
    const msg = "播放中不能拖拽（先点暂停）—— 否则移动系统每帧都会把位置改回去";
    errEl.textContent = msg;
    return { ok: false, code: "EDIT.BAD_DRAG", message: msg };
  }
  const id = pickAt(app.scene, wx, wz);
  if (id === undefined) {
    return { ok: false, code: "EDIT.BAD_DRAG", message: "这个位置没有节点" };
  }
  const r = beginDrag(app.scene, id, wx, wz);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  dragRef = r.value;
  // 点中就选中：否则拖完一个节点，属性面板还停在别人身上。
  selection.select(id);
  errEl.textContent = "";
  refreshTree();
  refreshProps();
  return { ok: true, node: id };
}

function dragMoveWorld(wx: number, wz: number): { ok: boolean; x?: number; y?: number } {
  const app = appRef;
  if (app === null || dragRef === null) return { ok: false };
  const t = dragTarget(dragRef, wx, wz, DRAG_SNAP);
  const n = app.scene.find(dragRef.nodeId);
  if (n === undefined) return { ok: false };
  // 拖拽期间**只改场景、不压历史**：一帧一条的话，按一次撤销只退一个像素。
  n.setLocalPosition(t.x, t.y);
  return { ok: true, x: t.x, y: t.y };
}

function dragEndNow(): { ok: boolean; moved?: boolean; label?: string; code?: string; message?: string } {
  const app = appRef;
  const st = dragRef;
  dragRef = null;
  if (app === null || st === null) {
    return { ok: false, code: "EDIT.BAD_DRAG", message: "没有正在进行的拖拽" };
  }
  const n = app.scene.find(st.nodeId);
  const r = endDrag(app.scene, st, n?.localPosition.x ?? st.fromX, n?.localPosition.y ?? st.fromY);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    afterHistoryChange();
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  // 原地松手 ⇒ 没有 op ⇒ 不压历史（否则撤销按钮亮了，按一次什么都没发生）。
  if (r.value === undefined) {
    afterHistoryChange();
    return { ok: true, moved: false };
  }
  const pushed = history.push(r.value);
  if (!pushed.ok) {
    errEl.textContent = `${pushed.error.code}：${pushed.error.message}`;
    afterHistoryChange();
    return { ok: false, code: pushed.error.code, message: pushed.error.message };
  }
  errEl.textContent = "";
  afterHistoryChange();
  return { ok: true, moved: true, label: r.value.label };
}

/** 把 pointer 事件接到拖拽上（真实鼠标走这条路；判据走 `dragXxxWorld`，同一套内部函数）。 */
function bindCanvasDrag(): void {
  const at = (e: PointerEvent): { x: number; z: number } => {
    const rect = canvas.getBoundingClientRect();
    return canvasToWorld(e.clientX - rect.left, e.clientY - rect.top);
  };
  canvas.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    const w = at(e);
    const r = dragBeginWorld(w.x, w.z);
    if (r.ok) {
      // 捕获指针：鼠标拖出画布再松手也能收到 pointerup，否则会永远停在"拖拽中"。
      canvas.setPointerCapture(e.pointerId);
      e.preventDefault();
    }
  });
  canvas.addEventListener("pointermove", (e) => {
    if (dragRef === null) return;
    const w = at(e);
    dragMoveWorld(w.x, w.z);
  });
  const finish = (e: PointerEvent): void => {
    if (dragRef === null) return;
    if (canvas.hasPointerCapture(e.pointerId)) canvas.releasePointerCapture(e.pointerId);
    dragEndNow();
  };
  canvas.addEventListener("pointerup", finish);
  // `pointercancel` 也要收尾：系统手势打断时不收的话，下一次 pointerdown 会被
  // 上一轮的 dragRef 抢走（两个节点一起动）。
  canvas.addEventListener("pointercancel", finish);
}

// ---------------------------------------------------------------- 场景树拖放换父

/**
 * 拖放换父（批85）。拖一行到另一行上 ⇒ 前者成为后者的子节点。
 *
 * ★ 为什么用 pointer 事件而不是 HTML5 拖放（`draggable` + `dragstart`/`drop`）：
 *   ① 那一套要合成出**可信**的 `DragEvent` 才会走 `drop`，无头浏览器里基本做不出来 ——
 *      于是"拖拽接线"这块就只能人工点，而本仓库最不想要的就是只有人能验的接线；
 *   ② pointer 与画布拖拽（gizmo）是同一套模型，落点用 `elementFromPoint` 自己算，
 *      "拖到了哪一行上"因此变成可断言的事实。
 *
 * ★ 监听器挂在 `document` 上、不用 `setPointerCapture`：
 *   capture 对**合成事件**会抛（没有活动指针），而真实指针被系统手势抢走时也会丢 ——
 *   两条都不影响逻辑，因为我们自己按坐标找落点。挂在 document 上的另一个好处是：
 *   真实鼠标与判据里的合成事件走**完全同一条**代码路径。
 */
let treeDragSrc: NodeId | null = null;
let treeDropEl: HTMLElement | null = null;

function rowAt(x: number, y: number): HTMLElement | null {
  const el = document.elementFromPoint(x, y);
  const row = el === null ? null : el.closest(".row");
  return row instanceof HTMLElement ? row : null;
}

function rowOf(target: EventTarget | null): HTMLElement | null {
  if (!(target instanceof Element)) return null;
  const row = target.closest(".row");
  return row instanceof HTMLElement ? row : null;
}

function clearTreeDragMarks(): void {
  treeEl.querySelectorAll(".row.dragging, .row.drop").forEach((el) => {
    el.classList.remove("dragging", "drop");
  });
  treeDropEl = null;
}

function beginTreeDrag(id: NodeId): void {
  treeDragSrc = id;
  const el = treeEl.querySelector(`.row[data-id="${String(id)}"]`);
  if (el instanceof HTMLElement) el.classList.add("dragging");
}

function moveTreeDrag(x: number, y: number): void {
  if (treeDragSrc === null) return;
  const over = rowAt(x, y);
  if (over === treeDropEl) return;
  if (treeDropEl !== null) treeDropEl.classList.remove("drop");
  treeDropEl = over;
  if (over !== null) over.classList.add("drop");
}

/** 换父（进历史）。`newParent = null` 表示挂回场景根。 */
function doReparent(nodeId: NodeId, newParent: NodeId | null): { ok: boolean; code?: string; message?: string } {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  const r = reparentWithUndo(app.scene, nodeId, newParent);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    // 失败也要重画：拖拽过程里 `.dragging` / `.drop` 是直接加在 DOM 上的，
    // 而失败路径不走 `commitOp` ⇒ 不重画就留着一个"看起来还挂着"的高亮。
    afterHistoryChange();
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  return commitOp(r.value.op);
}

/**
 * 松手。
 *
 * ★ 「拖回自己身上」与「拖到树的空白处」都算**取消**，不是失败：
 *   这两种都是人在中途改主意，报一行红字只会让人以为操作坏了。
 *   代价是判据不能靠错误码来验"拒绝" —— 所以那条判据验的是
 *   「历史没涨、父子关系没变」，而不是「返回了错误」。
 */
function finishTreeDrag(x: number, y: number): { ok: boolean; changed?: boolean; code?: string; message?: string } {
  const src = treeDragSrc;
  treeDragSrc = null;
  const over = rowAt(x, y);
  clearTreeDragMarks();
  if (src === null) return { ok: false, code: "EDIT.BAD_DRAG", message: "没有正在进行的拖拽" };
  if (over === null) return { ok: true, changed: false };
  const dst = Number(over.dataset["id"]);
  if (!Number.isFinite(dst) || dst === src) return { ok: true, changed: false };
  const r = doReparent(src, dst);
  return { ...r, changed: r.ok };
}

/** 把 pointer 事件接到场景树上（真实鼠标走这条路；判据用合成事件，同一套内部函数）。 */
function bindTreeDrag(): void {
  treeEl.addEventListener("pointerdown", (e) => {
    if (e.button !== 0) return;
    const row = rowOf(e.target);
    if (row === null) return;
    const id = Number(row.dataset["id"]);
    if (!Number.isFinite(id)) return;
    beginTreeDrag(id);
    // 防止浏览器把拖动变成"拖选文字"：那会选中一堆行内文本，松手后选区还在。
    e.preventDefault();
  });
  document.addEventListener("pointermove", (e) => {
    moveTreeDrag(e.clientX, e.clientY);
  });
  document.addEventListener("pointerup", (e) => {
    finishTreeDrag(e.clientX, e.clientY);
  });
  // 系统手势打断（或鼠标被拽出窗口）时清干净，否则下一轮 pointerdown 会被上一轮的源抢走。
  document.addEventListener("pointercancel", () => {
    treeDragSrc = null;
    clearTreeDragMarks();
  });
}

// ---------------------------------------------------------------- 资产面板（批86）

/**
 * 资产清单与面板。
 *
 * ★ **清单是唯一来源**：浏览器端的资源后端是 `HttpFileSystem`，它的
 *   `canList = false`（HTTP 没有「列出目录」这个操作），所以页面**没法**自己
 *   去列 `web/assets`。代价是清单会过期 —— 于是 `tests/extensions/editor-assets.test.ts`
 *   里有一条拿真磁盘**双向**对账（加了 png 忘了写清单就红）。
 *
 * ★ 读清单走 `HttpFileSystem` 而不是裸 `fetch`：404 → `FS.NOT_FOUND`、路径归一、
 *   前缀校验都在那一层，与 Node 侧的失败形状一致。宿主里各写一份 fetch 的后果是
 *   "资产读不到"在浏览器和 Node 下长得不一样。
 *
 * ★ **读不到要看得见**：面板里写一行字，而不是留一个空列表 ——
 *   空列表的含义是"这个工程里没有资产"，那是完全不同的一件事。
 */
let catalog: AssetCatalog | null = null;
let assetPicked: string | null = null;
/** 清单的问题（读不到 / 坏了）。面板与 `assetInfo()` 都从这里取，不各存一份。 */
let assetProblem: string | null = null;

function mkAssetEmpty(text: string): HTMLElement {
  const el = document.createElement("div");
  el.className = "empty";
  el.textContent = text;
  return el;
}

function assetUsable(path: string | null): boolean {
  if (path === null || catalog === null) return false;
  const e = catalog.entries.find((x) => x.path === path);
  return e !== undefined && e.inAtlas;
}

function assetRow(e: AssetEntry): HTMLElement {
  const el = document.createElement("div");
  el.className = `arow${e.inAtlas ? "" : " noframe"}${e.path === assetPicked ? " sel" : ""}`;
  el.dataset["path"] = e.path;
  const k = document.createElement("span");
  k.className = "k";
  k.textContent = e.kind;
  const p = document.createElement("span");
  p.className = "p";
  p.textContent = e.path;
  el.append(k, p);
  if (!e.inAtlas) {
    const nof = document.createElement("span");
    nof.className = "nof";
    nof.textContent = "无帧";
    nof.title = "图集里没有同名帧（编辑器还没接图片导入）—— 加进场景也画不出来";
    el.appendChild(nof);
  }
  el.addEventListener("click", () => {
    pickAsset(e.path);
  });
  // 双击直接加入：与场景树双击换父相反，这里的双击是"最常用那个动作"的快捷方式。
  el.addEventListener("dblclick", () => {
    pickAsset(e.path);
    doAddAsset(e.path);
  });
  return el;
}

function refreshAssets(): void {
  const cat = catalog;
  if (cat === null) return;
  const frag = document.createDocumentFragment();
  for (const e of cat.entries) frag.appendChild(assetRow(e));
  if (cat.entries.length === 0) frag.appendChild(mkAssetEmpty("清单里没有可用资产"));
  assetListEl.replaceChildren(frag);
  const usable = cat.entries.filter((e) => e.inAtlas).length;
  assetCountEl.textContent = `${String(cat.entries.length)} 个 · ${String(usable)} 可加入`;
  btnAssetAdd.disabled = !assetUsable(assetPicked);
}

/** 选中清单里的一项。返回「它能不能加入场景」（按钮的可用状态就是它）。 */
function pickAsset(path: string | null): boolean {
  assetPicked = path;
  refreshAssets();
  return assetUsable(path);
}

/** 读清单并建目录。启动时调一次；失败不抛（面板上留痕）。 */
async function loadAssets(): Promise<void> {
  const fs = new HttpFileSystem({ base: new URL("./", location.href) });
  const text = await fs.readText("assets-manifest.json");
  catalog = null;
  assetPicked = null;
  if (!text.ok) {
    assetProblem = `${text.error.code}：${text.error.message}`;
    assetListEl.replaceChildren(mkAssetEmpty(`资产清单读不到（${text.error.code}）`));
    assetCountEl.textContent = "—";
    btnAssetAdd.disabled = true;
    return;
  }
  // 帧名取自编辑器实际挂的那张图集（`atlasFrames`），不是另抄一份 ——
  // 抄一份的后果是「面板说有帧」而渲染说没有，两边各自都"对"。
  const cat = catalogFromManifest(text.value, { frameNames: atlasFrames });
  if (!cat.ok) {
    assetProblem = `${cat.error.code}：${cat.error.message}`;
    assetListEl.replaceChildren(mkAssetEmpty(`资产清单坏了（${cat.error.code}）`));
    assetCountEl.textContent = "—";
    btnAssetAdd.disabled = true;
    return;
  }
  assetProblem = null;
  catalog = cat.value;
  refreshAssets();
}

/** 视图中心对应的**根坐标系**位置。与 gizmo 用同一个换算式，不另算一套。 */
function viewCenterLocal(): { x: number; y: number } {
  const w = canvasToWorld(canvas.clientWidth / 2, canvas.clientHeight / 2);
  return { x: w.x, y: w.z };
}

/** 把一个资产加成带精灵的节点（进历史，一条）。 */
function doAddAsset(path: string | null): { ok: boolean; id?: number; code?: string; message?: string } {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  const entry = path === null || catalog === null ? undefined : catalog.entries.find((e) => e.path === path);
  if (entry === undefined) {
    const msg = path === null ? "没有选中资产" : `清单里没有 ${path}`;
    errEl.textContent = msg;
    return { ok: false, code: EDIT_BAD_ASSET_LIST, message: msg };
  }
  const pos = viewCenterLocal();
  const r = addSpriteNodeWithUndo(app.scene, app.scene.components, {
    name: entry.name,
    frame: entry.name,
    position: pos,
    hasFrame: (f) => atlasFrames.includes(f),
  });
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  // 加进来就选中：否则「加入场景」之后属性面板还停在别人身上，
  // 而视图中心可能正好叠着另一个 —— 人根本找不到刚加的那个。
  selection.select(r.value.nodeId);
  const out = commitOp(r.value.op);
  if (!out.ok) return out;
  return { ok: true, id: r.value.nodeId };
}

/** 历史动过之后统一收尾：选中项可能要 prune（子树被删/被恢复），树与面板都要重画。 */
function afterHistoryChange(): void {
  const app = appRef;
  if (app !== null) {
    const gone = selection.prune((id) => app.scene.find(id) !== undefined);
    if (gone.length > 0) {
      errEl.textContent = `选中项已不存在：${gone.map((id) => `#${String(id)}`).join("、")}`;
    }
  }
  refreshTree();
  refreshProps();
  refreshHistory();
}

function reportOutcome(out: UndoOutcome, verb: string): void {
  if (out.kind === "failed") {
    errEl.textContent = `${verb}「${out.label}」失败 ${out.error.code}：${out.error.message}`;
  } else if (out.kind === "done") {
    errEl.textContent = "";
  }
}

function doUndo(): UndoOutcome {
  const out = history.undo();
  reportOutcome(out, "撤销");
  afterHistoryChange();
  return out;
}

function doRedo(): UndoOutcome {
  const out = history.redo();
  reportOutcome(out, "重做");
  afterHistoryChange();
  return out;
}

function addNode(name?: string): Result<NodeId, EngineError> {
  const app = appRef;
  if (app === null) return err(engineError("EDIT.NOT_READY", "编辑器还没启动"));
  // 挂在当前选中项下面（没选中就挂根）—— 这是人点「新建」时的预期
  const parent = selection.primary;
  const label = name ?? `新节点 ${String(app.scene.stats().nodes)}`;
  const r = createNodeWithUndo(app.scene, label, parent);
  if (!r.ok) return r;
  history.push(r.value.op);
  selection.select(r.value.nodeId);
  afterHistoryChange();
  return ok(r.value.nodeId);
}

/**
 * 删除选中（可能是多个）。
 *
 * ★ 多选用一个**批量**：撤销一次全部回来。逐个压历史的话，删 5 个要按 5 次撤销，
 *   而且中途按一次撤销会让世界停在「删了一半」的状态 —— 那不是任何人心里的模型。
 */
function deleteSelected(): Result<number, EngineError> {
  const app = appRef;
  if (app === null) return err(engineError("EDIT.NOT_READY", "编辑器还没启动"));
  const all = selection.ids();
  if (all.length === 0) return err(engineError("EDIT.BAD_NODE", "没有选中任何节点"));
  // 去掉「祖先也被选中」的子孙：删父已经把它们一起删了，再删一次会失败并整批回滚
  const ids = topmostIds(app.scene, all);
  const began = history.beginBatch(`删除选中 ${String(ids.length)} 个`);
  if (!began.ok) return began;
  for (const id of ids) {
    const r = deleteNodeWithUndo(app.scene, id);
    if (!r.ok) {
      const rb = history.rollbackBatch();
      afterHistoryChange();
      return err(
        engineError(
          r.error.code,
          `删除 #${String(id)} 失败：${r.error.message}` +
            (rb.kind === "failed" ? `；回滚也失败：${rb.error.message}` : "（已回滚到删除前）"),
        ),
      );
    }
    history.push(r.value.op);
  }
  const c = history.commitBatch();
  if (!c.ok) return c;
  selection.clear();
  afterHistoryChange();
  return ok(ids.length);
}

// ---------------------------------------------------------------- 帧循环
let last = performance.now();
let uiClock = 0;

function loop(now: number): void {
  const dt = Math.max(0, (now - last) / 1000);
  last = now;
  const app = appRef;
  if (app !== null) {
    const ticks = pie.advance(dt);
    for (let i = 0; i < ticks; i++) app.frame(FIXED_DT);
    // 每 0.5 秒刷一次树（每帧重建 DOM 在 500 节点上会掉到个位数帧率）
    if (now - uiClock > 500) {
      uiClock = now;
      refreshTree();
      const st = pie.stats();
      tickEl.textContent = `tick ${String(app.scheduler.stats().tick)}`;
      pieInfoEl.textContent = st.playing ? "播放中" : st.pending > 0 ? `待跑 ${String(st.pending)}` : "暂停";
    }
  }
  requestAnimationFrame(loop);
}

// ---------------------------------------------------------------- 命令面（UI 与自检共用）
interface EditorApi {
  ready(): boolean;
  stats(): {
    nodes: number;
    truncated: boolean;
    tick: number;
    playing: boolean;
    selected: number[];
    primary: number | null;
  };
  outline(): Array<{ id: number; name: string; depth: number; types: string[] }>;
  select(id: number): boolean;
  panel(): {
    node: number;
    groups: Array<{
      type: string;
      fields: Array<{ key: string; type: string; control: string; value: unknown }>;
    }>;
  } | null;
  setField(node: number, type: string, key: string, raw: unknown): { ok: boolean; code?: string; value?: unknown };
  step(n: number): number;
  play(): void;
  pause(): void;
  pie(): { tick: number; playing: boolean; pending: number; clampedFrames: number };
  /** 撤销一步。`kind` 区分「本来就没历史」和「反向执行失败」。 */
  undo(): { kind: string; label?: string; code?: string; message?: string };
  redo(): { kind: string; label?: string; code?: string; message?: string };
  history(): {
    undo: string[];
    redo: string[];
    dropped: number;
    canUndo: boolean;
    canRedo: boolean;
  };
  addNode(name?: string): { ok: boolean; id?: number; code?: string };
  deleteSelected(): { ok: boolean; deleted?: number; code?: string; message?: string };
  /** 导出当前场景到文本框，并返回文本（判据直接用返回值，不去读 DOM）。 */
  docSave(): { ok: boolean; text?: string; code?: string; message?: string };
  /** 打开一份文档文本（省参数时读文本框）。失败时场景应原样还在。 */
  docOpen(text?: string): { ok: boolean; made?: number; code?: string; message?: string };
  /** 新建空场景（只留根）。 */
  docNew(): { ok: boolean; made?: number; code?: string; message?: string };
  /** 文本框里的当前内容（判据用来验「保存真的写进去了」）。 */
  docText(): string;
  /** 选中节点（缺省）上还能挂哪些组件类型：注册表减去已挂的。 */
  compAvailable(node?: number): string[];
  /** 挂一个组件（进历史）。`node` 缺省 = 当前选中项。 */
  compAttach(type: string, node?: number): { ok: boolean; code?: string; message?: string };
  /** 卸一个组件（进历史；实例留着给撤销用）。 */
  compDetach(type: string, node?: number): { ok: boolean; code?: string; message?: string };
  /** 节点上某类型的组件**个数**（`get` 只返回第一个，数不了重复）。 */
  compCount(type: string, node?: number): number;
  /** 节点的世界坐标（判据要它来算"该拖多少"）。`null` = 节点不在。 */
  nodeWorld(id: number): { x: number; y: number } | null;
  /** 节点的局部坐标（拖拽改的是这个）。 */
  nodeLocal(id: number): { x: number; y: number } | null;
  /** 相机状态（判据用来验屏幕↔世界的换算：给画布中心应得相机中心）。 */
  camInfo(): { x: number; z: number; zoom: number; tiltY: number; vw: number; vh: number };
  /** 画布内坐标（CSS px，左上为 0）→ 世界 XZ。 */
  screenToWorld(cssX: number, cssY: number): { x: number; z: number };
  /** 在世界点按下开始拖（点中即选中）。 */
  dragBegin(wx: number, wz: number): { ok: boolean; node?: number; code?: string; message?: string };
  /** 拖到世界点（只改场景，不压历史）。 */
  dragMove(wx: number, wz: number): { ok: boolean; x?: number; y?: number };
  /** 松手：位移非 0 才压一条历史。 */
  dragEnd(): { ok: boolean; moved?: boolean; label?: string; code?: string; message?: string };
  /** 换父（进历史）；`to = null` = 挂回场景根。世界位置会被保住。 */
  reparent(from: number, to: number | null): { ok: boolean; code?: string; message?: string };
  /** 节点当前的父（`null` = 挂在场景根下；`undefined` = 节点不存在）。 */
  parentOf(id: number): number | null | undefined;
  /** 资产清单（清单读不到时为空数组 —— 原因看 `assetInfo().problem`）。 */
  assets(): Array<{ path: string; name: string; kind: string; inAtlas: boolean }>;
  /** 资产面板里当前选中的路径（没选 = `null`）。 */
  assetPicked(): string | null;
  /** 选中清单里的一项；返回「它能不能加入场景」（按钮可用状态就是它）。 */
  assetPick(path: string | null): boolean;
  /** 把一个资产加成场景里的节点（进历史，一条）。 */
  assetAdd(path: string | null): { ok: boolean; id?: number; code?: string; message?: string };
  /** 面板标题与清单健康状况（条数 / 可加入数 / 出问题的原因）。 */
  assetInfo(): { count: number; usable: number; title: string; problem: string | null };
}

function installApi(app: GameApp): void {
  const api: EditorApi = {
    ready: () => booted && appRef !== null,
    stats() {
      const o = buildOutline(app.scene);
      const s = selection.snapshot();
      return {
        nodes: o.count,
        truncated: o.truncated,
        tick: app.scheduler.stats().tick,
        playing: pie.isPlaying,
        selected: [...s.ids],
        primary: s.primary,
      };
    },
    outline() {
      return flattenOutline(buildOutline(app.scene).root).map((r) => ({
        id: r.node.id,
        name: r.node.name,
        depth: r.depth,
        types: [...r.node.types],
      }));
    },
    select(id: number) {
      const n = app.scene.find(id);
      if (n === undefined) return false;
      selection.select(n.id);
      refreshTree();
      refreshProps();
      return true;
    },
    panel() {
      const primary = selection.primary;
      if (primary === null) return null;
      const node = app.scene.find(primary);
      if (node === undefined) return null;
      return {
        node: node.id,
        groups: node.components.map((c) => ({
          type: c.type,
          fields: fieldsOf(c).map((f) => ({ key: f.key, type: f.type, control: f.control, value: f.value })),
        })),
      };
    },
    setField(node, type, key, raw) {
      const r = commitField(node, type, key, raw);
      if (!r.ok) return { ok: false, code: r.error.code };
      refreshProps();
      return { ok: true, value: r.value.after };
    },
    step(n) {
      const k = Math.max(0, Math.floor(n));
      for (let i = 0; i < k; i++) app.frame(FIXED_DT);
      return app.scheduler.stats().tick;
    },
    play() {
      pie.play();
    },
    pause() {
      pie.pause();
    },
    pie() {
      const s = pie.stats();
      return { tick: s.tick, playing: s.playing, pending: s.pending, clampedFrames: s.clampedFrames };
    },
    undo() {
      const out = doUndo();
      if (out.kind === "failed") {
        return { kind: out.kind, label: out.label, code: out.error.code, message: out.error.message };
      }
      return out.kind === "done" ? { kind: out.kind, label: out.label } : { kind: out.kind };
    },
    redo() {
      const out = doRedo();
      if (out.kind === "failed") {
        return { kind: out.kind, label: out.label, code: out.error.code, message: out.error.message };
      }
      return out.kind === "done" ? { kind: out.kind, label: out.label } : { kind: out.kind };
    },
    history() {
      const h = history.history();
      return {
        undo: [...h.undo],
        redo: [...h.redo],
        dropped: h.dropped,
        canUndo: history.canUndo,
        canRedo: history.canRedo,
      };
    },
    addNode(name?: string) {
      const r = addNode(name);
      if (!r.ok) return { ok: false, code: r.error.code };
      return { ok: true, id: r.value };
    },
    deleteSelected() {
      const r = deleteSelected();
      if (!r.ok) return { ok: false, code: r.error.code, message: r.error.message };
      return { ok: true, deleted: r.value };
    },
    docSave() {
      const app = appRef;
      if (app === null) return { ok: false, code: "EDIT.NOT_READY" };
      const r = exportDocument(docDeps(app));
      if (!r.ok) return { ok: false, code: r.error.code, message: r.error.message };
      docText.value = r.value;
      docInfoEl.textContent = `已导出 ${String(r.value.length)} 字节`;
      errEl.textContent = "";
      return { ok: true, text: r.value };
    },
    docOpen(text?: string) {
      return doOpenDoc(text);
    },
    docNew() {
      return doNewDoc();
    },
    docText() {
      return docText.value;
    },
    compAvailable(node) {
      const id = node ?? selection.primary;
      if (id === null) return [];
      const n = app.scene.find(id);
      return n === undefined ? [] : availableTypes(n);
    },
    compAttach(type, node) {
      return doAttachComp(type, node as NodeId | undefined);
    },
    compDetach(type, node) {
      return doDetachComp(type, node as NodeId | undefined);
    },
    compCount(type, node) {
      const id = node ?? selection.primary;
      if (id === null) return -1;
      const n = app.scene.find(id);
      if (n === undefined) return -1;
      return n.components.filter((c) => c.type === type).length;
    },
    nodeWorld(id) {
      const n = app.scene.find(id);
      if (n === undefined) return null;
      const p = n.worldPosition;
      return { x: p.x, y: p.y };
    },
    nodeLocal(id) {
      const n = app.scene.find(id);
      if (n === undefined) return null;
      return { x: n.localPosition.x, y: n.localPosition.y };
    },
    camInfo() {
      const c = renderMod.camera;
      return { x: c.x, z: c.z, zoom: c.zoom, tiltY: c.tiltY, vw: c.vw, vh: c.vh };
    },
    screenToWorld(cssX, cssY) {
      return canvasToWorld(cssX, cssY);
    },
    dragBegin(wx, wz) {
      return dragBeginWorld(wx, wz);
    },
    dragMove(wx, wz) {
      return dragMoveWorld(wx, wz);
    },
    dragEnd() {
      return dragEndNow();
    },
    reparent(from, to) {
      return doReparent(from, to);
    },
    parentOf(id) {
      const n = app.scene.find(id);
      // ★ 三种情况必须区分：根下是 `null`、父是某个 id、节点不在是 `undefined`。
      //   把"节点不在"也返回 `null` 的话，判据里"拖放没生效"和"挂回了根"就分不开 ——
      //   那正是本仓库反复踩的那类假绿。
      if (n === undefined) return undefined;
      const p = n.parent;
      return p === null || p.id === app.scene.rootId ? null : p.id;
    },
    assets() {
      const cat = catalog;
      if (cat === null) return [];
      // 拷一份普通对象：判据拿到的是**当时的**快照，不是活的引用。
      return cat.entries.map((e) => ({ path: e.path, name: e.name, kind: e.kind, inAtlas: e.inAtlas }));
    },
    assetPicked() {
      return assetPicked;
    },
    assetPick(path) {
      return pickAsset(path);
    },
    assetAdd(path) {
      return doAddAsset(path);
    },
    assetInfo() {
      const cat = catalog;
      const count = cat === null ? 0 : cat.entries.length;
      const usable = cat === null ? 0 : cat.entries.filter((e) => e.inAtlas).length;
      return { count, usable, title: assetCountEl.textContent ?? "", problem: assetProblem };
    },
  };
  (window as unknown as { __editor?: EditorApi }).__editor = api;
}

// ---------------------------------------------------------------- 启动
async function main(): Promise<void> {
  planRef = generateWorld({ seed: WORLD_SEED, width: WORLD_W, height: WORLD_H, maxSitesPerCell: 1 });

  const appR = await bootGameApp({
    platformId: "editor",
    interactive: true,
    registry,
    modules: [worldMod, renderMod, worldgenMod],
    seed: WORLD_SEED,
    fixedDt: FIXED_DT,
    backendOptions: {
      gfx: { canvas },
      input: { keyboard: window, pointer: canvas },
      audio: {},
    },
  });
  if (!appR.ok) {
    errEl.textContent = `启动失败 ${appR.error.code}：${appR.error.message}`;
    return;
  }
  const app = appR.value;
  appRef = app;

  // ★ 不要在这里再调 `app.start()`：`bootGameApp` 内部已经启动过模块
  //   （再调一次得到的是 `APP.ALREADY_RUNNING`，而截图的人会以为"启动失败"）。
  booted = true;
  installApi(app);
  refreshTree();
  refreshProps();
  tickEl.textContent = `tick ${String(app.scheduler.stats().tick)}`;

  bindCanvasDrag();
  bindTreeDrag();
  // 资产清单是异步的（一次 HTTP）：先画空态，读到再刷新。
  void loadAssets();
  btnAssetAdd.addEventListener("click", () => {
    doAddAsset(assetPicked);
  });
  btnPlay.addEventListener("click", () => pie.play());
  btnPause.addEventListener("click", () => pie.pause());
  btnStep.addEventListener("click", () => pie.step(1));
  btnStep10.addEventListener("click", () => pie.step(10));
  btnUndo.addEventListener("click", () => void doUndo());
  btnRedo.addEventListener("click", () => void doRedo());
  btnAdd.addEventListener("click", () => void addNode());
  btnSave.addEventListener("click", () => {
    doSaveDoc();
  });
  btnOpen.addEventListener("click", () => {
    doOpenDoc();
  });
  btnNew.addEventListener("click", () => {
    doNewDoc();
  });
  btnDel.addEventListener("click", () => void deleteSelected());

  // 快捷键：Ctrl/Cmd+Z 撤销、Ctrl/Cmd+Shift+Z 或 Ctrl+Y 重做、Delete 删选中。
  // ★ 用 `key.toLowerCase()` 判断字母：大写锁定时 `key` 是 "Z" 而不是 "z"，
  //   只比小写会让人「开了大写锁之后撤销失效」，而这是最难联想到快捷键 bug 的场景。
  window.addEventListener("keydown", (e) => {
    const mod = e.ctrlKey || e.metaKey;
    const k = e.key.toLowerCase();
    if (mod && k === "z") {
      e.preventDefault();
      if (e.shiftKey) void doRedo();
      else void doUndo();
      return;
    }
    if (mod && k === "y") {
      e.preventDefault();
      void doRedo();
      return;
    }
    if (!mod && (e.key === "Delete" || e.key === "Backspace")) {
      // 焦点在输入框里时不许删节点 —— 否则人想删一个字符，整棵树少了一个节点
      const t = e.target as HTMLElement | null;
      if (t !== null && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
      e.preventDefault();
      void deleteSelected();
    }
  });

  refreshHistory();
  requestAnimationFrame(loop);
}

void main();
