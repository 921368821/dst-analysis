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
import { createPie } from "./extensions/editor/pie.ts";
import { createUndoStack, type EditorOp, type UndoOutcome } from "./extensions/editor/undo-stack.ts";
import {
  attachComponentWithUndo,
  createNodeWithUndo,
  deleteNodeWithUndo,
  detachComponentWithUndo,
  makeFieldOp,
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

const dpr = Math.min(2, window.devicePixelRatio || 1);
canvas.width = Math.floor((canvas.clientWidth || 640) * dpr);
canvas.height = Math.floor((canvas.clientHeight || 420) * dpr);

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
  return commitCompOp(r.value.op);
}

/**
 * 一次组件操作的收尾：压历史 → 清错误行 → 重画三处。
 *
 * ★ 抽出来不只是为了少两行：挂与卸如果各写一份，两处**必须**都调 `history.push`，
 *   而漏掉任何一处都只表现为「撤销按钮没亮」，看起来像撤销栈坏了。
 *   共用一份之后，变异校验只要打这一行就能同时覆盖两个方向。
 */
function commitCompOp(op: EditorOp): { ok: boolean; code?: string; message?: string } {
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
  return commitCompOp(r.value.op);
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
