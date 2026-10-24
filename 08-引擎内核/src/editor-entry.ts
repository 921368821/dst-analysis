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
import { fieldsOf, setField } from "./extensions/editor/property-model.ts";
import { createPie } from "./extensions/editor/pie.ts";

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

const dpr = Math.min(2, window.devicePixelRatio || 1);
canvas.width = Math.floor((canvas.clientWidth || 640) * dpr);
canvas.height = Math.floor((canvas.clientHeight || 420) * dpr);

const selection = createSelection();
const pie = createPie({ hz: HZ, maxStepTicks: 4 });

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
  if (node.components.length === 0) {
    const e = document.createElement("div");
    e.className = "empty";
    e.textContent = "这个节点没有组件";
    frag.appendChild(e);
  }
  for (const comp of node.components) {
    const t = document.createElement("h3");
    t.textContent = comp.type;
    frag.appendChild(t);
    for (const f of fieldsOf(comp)) {
      frag.appendChild(propRow(primary, comp.type, f.key, f.control, f.value));
    }
  }
  propsEl.replaceChildren(frag);
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
    const r = setField(appRef!.scene, nodeId, type, key, raw);
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
      const r = setField(app.scene, node, type, key, raw);
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

  requestAnimationFrame(loop);
}

void main();
