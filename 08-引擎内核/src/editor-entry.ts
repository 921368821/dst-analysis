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
import { buildProceduralAtlas, type AtlasData } from "./extensions/render/atlas.ts";
import { createRenderModule, type RenderModuleHandle } from "./extensions/render/render-module.ts";
import { SpatialHashWorld, makeSceneAccessor } from "./extensions/physics/physics.ts";
import { createWorldModule } from "./extensions/physics/world-step-module.ts";
import { FIXED_UNITS, generateWorld } from "./extensions/worldgen/worldgen.ts";
import { assembleWorld, registerWorldComponents } from "./extensions/worldgen/assemble.ts";
import { registerPlayerComponents, spawnPlayer } from "./extensions/worldgen/spawn.ts";
import { attachWorldVisuals } from "./extensions/render/world-visuals.ts";
import { registerInventoryComponents } from "./extensions/inventory/inventory.ts";
import { registerHealthComponent } from "./extensions/combat/health.ts";
import { registerHungerComponent } from "./extensions/survival/hunger.ts";
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
import {
  createProject,
  createScene,
  currentSceneText,
  deleteScene,
  saveCurrent,
  sceneNames,
  switchScene,
  type Project,
  type SwitchReport,
} from "./extensions/editor/project.ts";
import {
  PROJECT_STORAGE_KEY,
  loadProject,
  saveProject,
  type ProjectStore,
} from "./extensions/editor/project-file.ts";
import { fieldsOf, setField, type FieldChange } from "./extensions/editor/property-model.ts";
import { beginDrag, dragTarget, endDrag, pickAt, type DragState } from "./extensions/editor/gizmo.ts";
import { createPie } from "./extensions/editor/pie.ts";
import {
  beginPlaySession,
  endPlaySession,
  type PlaySession,
  type PlayStopReport,
} from "./extensions/editor/play-session.ts";
// 批92：关卡流程（试玩里走进门 → 换场景）。这一层是纯模型，编辑器只负责
// "什么时候喂位置"和"跳完重画什么"。
import { PortalWatcher, collectPortals, registerPortalComponent } from "./extensions/flow/portal.ts";
import { SceneFlow, findPlayerId, type JumpReport } from "./extensions/flow/scene-flow.ts";
import { createControllerModule } from "./extensions/input/player-controller.ts";
import type { InputSnapshot } from "./platform/input/device.ts";
import { createUndoStack, type EditorOp, type UndoOutcome } from "./extensions/editor/undo-stack.ts";
import { HttpFileSystem } from "./backends/fs-http/fs.ts";
import { bakeAtlasFromImages, type BakeImage } from "./extensions/editor/asset-bake.ts";
import {
  EDIT_BAD_ASSET_LIST,
  catalogFromManifest,
  type AssetCatalog,
  type AssetEntry,
} from "./extensions/editor/asset-list.ts";
import {
  EDIT_NO_FRAME,
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
const pieNoteEl = need<HTMLSpanElement>("pienote");
const btnPlay = need<HTMLButtonElement>("btn-play");
const btnPause = need<HTMLButtonElement>("btn-pause");
const btnStop = need<HTMLButtonElement>("btn-stop");
const btnStep = need<HTMLButtonElement>("btn-step");
const btnStep10 = need<HTMLButtonElement>("btn-step10");
const btnPSave = need<HTMLButtonElement>("btn-psave");
const btnPLoad = need<HTMLButtonElement>("btn-pload");
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
const sceneListEl = need<HTMLDivElement>("scenelist");
const sceneCountEl = need<HTMLSpanElement>("scenecount");
const saveNoteEl = need<HTMLSpanElement>("savenote");
const btnSceneNew = need<HTMLButtonElement>("scene-new");
const btnSceneDel = need<HTMLButtonElement>("scene-del");

const dpr = Math.min(2, window.devicePixelRatio || 1);
// 首次位图尺寸：必须在 `createRenderModule` **之前**定好，它用这个值建初始视口。
canvas.width = Math.max(1, Math.floor((canvas.clientWidth || 640) * dpr));
canvas.height = Math.max(1, Math.floor((canvas.clientHeight || 420) * dpr));

const selection = createSelection();
const pie = createPie({ hz: HZ, maxStepTicks: 4 });
const history = createUndoStack();

/**
 * 当前这场试玩（`null` = 没在试玩）。
 *
 * ★ 它同时是三个东西的开关：① 播放/单步之前必须先有它（否则回滚没有基准）；
 *   ② 有它的时候字段改动**不进历史**（试玩改的不是文档，见 `play-session.ts`）；
 *   ③ 停播时按它判断"要不要重建整个场景"。
 *   三处用同一个东西，就不会出现"某处忘了先开会话"。
 */
let playSession: PlaySession | null = null;
/** 上一次停播的结论（面板上要说出来：回滚了没有、为什么）。 */
let lastStop: PlayStopReport | null = null;

/**
 * 试玩期间的场景流程（批92）。`null` = 没在试玩。
 *
 * ★ 它只在试玩里存在，因为**试玩中的跳转是沙盒的**：跳到另一个场景不改工程里任何槽位，
 *   停播时按会话快照回滚到进试玩那一刻。这正好复用了 `play-session.ts` 已有的保证，
 *   不需要为"跳转"再造一套回滚。
 */
let flow: SceneFlow | null = null;
/**
 * 走进门的边沿检测。**跨场景生存**（它是"这一次行走"的状态，不属于场景）——
 * 所以它建在模块级，每次进试玩 `reset()` 一次。
 */
const portalWatcher = new PortalWatcher();
/** 最近一次跳转/门出错的说明（面板上留痕：静默跳走会让人以为点了没反应）。 */
let flowNote = "";

let appRef: GameApp | null = null;
let heroId: NodeId = -1;
let booted = false;

/**
 * 工程（多场景）。**启动装完世界之后**才建（第一个槽位就是那份世界的导出，
 * 见 `createProject` 的注释）；在那之前它必须是 `null` —— 拿一个空工程顶着，
 * 会让"启动时看到的世界"和"工程里记的场景"从第一秒起就不是同一份。
 */
let project: Project | null = null;

/**
 * 存档介质：浏览器的 localStorage。
 *
 * ★ 这里**不 try/catch**：`saveProject` / `loadProject` 各自把异常翻译成
 *   `EDIT.PROJECT_STORE`。在这里兜一次的话，"写不进去"（配额满、隐私模式）就变成
 *   一次静默失败 —— 面板上照旧写着「已存」，人关掉页面才发现什么都没了。
 */
const projectStore: ProjectStore = {
  read: () => window.localStorage.getItem(PROJECT_STORAGE_KEY),
  write: (text) => {
    window.localStorage.setItem(PROJECT_STORAGE_KEY, text);
  },
};

/**
 * 把工程写进存档。
 *
 * ★ 顺序是「先把当前场景导出进槽位，再序列化」。反过来存的是**上一次**导出时的那一份
 *   —— 人刚才的改动全丢，而面板上"已保存"照样亮着，这是最难自己发现的一种丢数据。
 *
 * ★ 试玩期间**不写**：此刻世界被控制器跑过、被脚本临时改过，那些都不是文档。
 *   写下去的后果是"试玩跑了两步，把跑到的地方当成文档存了"。
 */
function persistProject(): void {
  const app = appRef;
  const p = project;
  if (app === null || p === null) return;
  if (playSession !== null) {
    saveNoteEl.textContent = "试玩中：不写存档";
    return;
  }
  const saved = saveCurrent(docDeps(app), p);
  if (!saved.ok) {
    saveNoteEl.textContent = `未存盘：${saved.error.code}`;
    return;
  }
  const w = saveProject(projectStore, p);
  if (!w.ok) {
    // 静默失败在这里是致命的：人以为一直在存，其实一条都没写进去。
    saveNoteEl.textContent = `未存盘：${w.error.code}`;
    errEl.textContent = `${w.error.code}：${w.error.message}`;
    return;
  }
  saveNoteEl.textContent = `已存 ${String(w.value.bytes)} 字节 · ${String(w.value.scenes)} 个场景`;
}

/**
 * 启动时把存档装回来（没有就来一个新工程）。
 *
 * ★ 调用时机钉死在「默认世界已经装好、工程还没建」那一刻，而且**恢复失败就退回新工程**：
 *   先建默认工程再恢复的话，第一次 `persistProject()` 会把默认世界写进存档 ——
 *   用户的几个场景就这么被一份新世界覆盖掉，而界面上一切正常。
 *
 * ★ 恢复成功但当前场景的内容与刚 boot 出来的世界**逐字节相同**时不装载：
 *   `openDocument` 会把整棵树换成新实例（撤销栈、选中集、`heroId` 指的东西全变），
 *   而内容一样 —— 与批88「停播时文本一样就不重建」是同一条规则。
 */
function adoptStoredProject(app: GameApp, freshText: string): Project {
  const fallback = createProject(app.scene.name, freshText);
  const r = loadProject(projectStore);
  if (!r.ok) {
    // 存档在，但坏 / 打不开。**不清档**：人还得靠它把东西抠出来。
    saveNoteEl.textContent = `存档读不出来（${r.error.code}）`;
    errEl.textContent = `${r.error.code}：${r.error.message} · 存档原样保留，未覆盖`;
    return fallback;
  }
  if (r.value === null) {
    saveNoteEl.textContent = "新工程（还没有存档）";
    return fallback;
  }
  const rp = r.value.project;
  const cur = rp.scenes.find((s) => s.name === rp.current);
  if (cur === undefined) {
    // 解析器已保证 `current` 在列表里。真破了就**响亮地抛**，不写一条返回兜底值的
    // 防御分支 —— 那种分支会把真正的守卫遮成假绿（批90 M414 的实测结果）。
    throw new Error(`工程不变量被破坏：current=${rp.current} 不在 ${String(rp.scenes.length)} 个场景里`);
  }
  if (cur.text !== freshText) {
    const opened = openDocument(docDeps(app), cur.text);
    if (!opened.ok) {
      saveNoteEl.textContent = `存档装不进去（${opened.error.code}）`;
      errEl.textContent = `${opened.error.code}：${opened.error.message} · 存档原样保留`;
      return fallback;
    }
  }
  saveNoteEl.textContent = `已恢复 ${String(r.value.bytes)} 字节 · ${String(rp.scenes.length)} 个场景`;
  return rp;
}

/**
 * 每个 `Node` **实例**一个只在本进程内有效的序号。
 *
 * ★ 为什么需要它：`nodeId` 是文档里的东西 —— 场景切走再切回来，id 一模一样，
 *   但那棵树上的 `Node` 已经被 `scene.clear()` 换成新实例了。于是"实例有没有被换掉"
 *   这件事**在 id 上看不出来**，而它恰恰是「切到同一份不该重建」这条保证的判据。
 *   没有它，判据只能验"节点数没变 / 名字没变"，那在重建之后照样成立 —— 假绿。
 *
 * ★ 用 `WeakMap`：节点被销毁之后序号跟着回收，不会因为反复开关场景而一直涨。
 */
const nodeSerials = new WeakMap<object, number>();
let nodeSerialNext = 1;

function serialOf(n: object): number {
  const had = nodeSerials.get(n);
  if (had !== undefined) return had;
  const s = nodeSerialNext++;
  nodeSerials.set(n, s);
  return s;
}

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

/**
 * 渲染模块**在 `main()` 里建**，不在这里。
 *
 * ★ 原因是批87：图集现在是"从 `web/assets` 烘出来的真图"，而烘图必须先把图读完
 *   （异步 HTTP）。而 `createRenderModule({atlas})` 会在 `init` 时按图集建页表、
 *   上传纹理 —— 图集晚到就等于页表是错的。
 *   所以顺序被钉死成：读清单 → 读图 → 烘图集 → 建渲染模块 → 启动。
 *   想"建完再换图集"就得有一条运行时换页的通道（纹理要重传、批次要重建），
 *   那是另一个量级的改动，而且失败时画面会停在一个半新半旧的状态。
 *
 * 于是这里留一个可空引用 + `requireRender()`：`syncViewport` / `canvasToWorld`
 * 这些都在启动之后才会被调到（拖拽、加资产、视口回调），拿不到就是启动没跑完。
 */
let renderMod: RenderModuleHandle | null = null;

function requireRender(): RenderModuleHandle {
  if (renderMod === null) throw new Error("编辑器还没启动完：渲染模块未创建");
  return renderMod;
}

function makeRenderModule(atlas: AtlasData): RenderModuleHandle {
  return createRenderModule({
    atlas,
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
}

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
  requireRender().resize(w, h);
}

/** 视口跟随。**必须在渲染模块建好之后**调（它在 `main()` 里调）。 */
function watchViewport(): void {
  syncViewport();
  if (typeof ResizeObserver !== "undefined") new ResizeObserver(syncViewport).observe(canvas);
  else window.addEventListener("resize", syncViewport);
}

// ---------------------------------------------------------------- 试玩：控制器
/**
 * 把输入喂给场景里带 `game.controller` 的节点（也就是玩家）。
 *
 * ★★ 没有这一段的时候，「试玩」只是一个会走字的时钟：世界纹丝不动。
 *   原因不是模块坏了，而是**没有任何东西驱动它** —— `createControllerModule`
 *   明确写着"模块不会被框架自动 update，由宿主在固定步回调里调"（与脚本模块同款），
 *   而编辑器这边一直没调，`driven` 就一直是 0。
 *
 * ★ 一个 tick 只 poll 一次，多调会吞掉"刚按下"的边缘事件（见模块自己的注释）；
 *   所以这里只在 `worldMod` 的 `onStep` 里调一次，别处一律读 `.snapshot`。
 */
const EMPTY_INPUT: InputSnapshot = {
  keysDown: new Set<string>(),
  keysPressed: new Set<string>(),
  keysReleased: new Set<string>(),
  pointer: { x: 0, y: 0, down: false, pressed: false, released: false, button: 0 },
  wheel: { dx: 0, dy: 0 },
  text: "",
};

const controllerMod = createControllerModule({
  poll: () => (appRef === null ? EMPTY_INPUT : appRef.platform.input.poll()),
  id: "editor.controller",
});

/**
 * 世界步进模块。`onStep` 是**唯一**驱动控制器的地方（见上面那段注释）。
 *
 * ★ 顺序：`scene.step` 先把所有组件的 `onUpdate` 跑一遍，控制器再由这里挪玩家 ——
 *   两者都在同一个 tick 内、且都在 `physics.resolve()` 之前，所以本 tick 挪出来的
 *   位置当 tick 就参与碰撞，不会拖到下一帧。
 */
const worldMod = createWorldModule(physics, {
  onStep: (tick, dt) => {
    controllerMod.update(tick, dt);
  },
});

// ---------------------------------------------------------------- 世界装配模块
/**
 * 当前图集里的帧名。**默认是程序化图集那 6 帧，启动时会被真实图集替换掉**（批87）。
 *
 * ★ 为什么留程序化兜底：编辑器打不开比"资产是假的"更糟。资产读不到（离线、
 *   静态服务器没起、清单坏了）时要退回到一张能画的世界，并且**在面板上留痕** ——
 *   静默回落会让人以为自己在看真资产。
 */
let atlasFrames: readonly string[] = [...buildProceduralAtlas().frames.keys()];
/** 这次实际用的是哪张图集（`assetInfo()` 会把它交出去，判据据此分辨真假）。 */
let atlasSource: "assets" | "procedural" = "procedural";
let atlasNote = "还没启动";

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
    registerPlayerComponents(scene.components);
    registerInventoryComponents(scene.components);
    // ★ 血 / 饱食在**编辑器**里也要能挂（批92 顺手补上的一处欠账）：
    //   批66/67 只在演示宿主里注册了这两个，于是编辑器里做出来的怪与玩家
    //   **没有血量、不会饿**，而面板上根本选不到这两个类型 ——
    //   "在编辑器里做的游戏能不能打"这个问题就永远没有答案。
    //   注册只让类型可用，不改变任何已有世界。
    registerHealthComponent(scene.components);
    registerHungerComponent(scene.components);
    // 批92：传送门组件必须进注册表，否则属性面板的「加组件」里看不到它（人就没法摆门），
    // 而且读档时 `flow.portal` 会被当成未知组件**静默跳过**（"我摆的门不见了"）。
    registerPortalComponent(scene.components);
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

// ---------------------------------------------------------------- 试玩会话（PIE）

/**
 * 开始试玩（幂等）。**播放与单步都必须先过这里** —— 单步也是让世界自己跑，
 * 也会把控制器推动过的位置写进场景，所以它同样需要一份回滚基准。
 *
 * ★ 快照拍在 `pie.play()` 之前：拍在后面的第一帧就已经跑过了，
 *   回滚回去的是"已经脏了"的世界（见 `play-session.ts` ①）。
 */
function beginPlay(): PlaySession | null {
  const app = appRef;
  if (app === null) return null;
  if (playSession === null) {
    playSession = beginPlaySession(app.scene);
    // 批92：试玩一开始就把流程层建起来，并把"我在哪扇门里"忘掉 ——
    // 上一次试玩结束时世界被回滚过，留着旧位置会让第一帧凭空触发一次跳转。
    flow = makeFlow(app);
    portalWatcher.reset();
    flowNote = "";
  }
  return playSession;
}

/**
 * 建流程层：场景来源是**工程槽位**（只读）。
 *
 * ★ `source` 每次调用都现读 `project`，不闭包捕获构造时那个对象：
 * 工程会在新建/删除场景时被改写，捕获旧引用会让"刚新建的场景"跳不过去。
 */
function makeFlow(app: GameApp): SceneFlow | null {
  if (project === null) return null;
  return new SceneFlow(
    {
      scene: app.scene,
      registry: app.scene.components,
      source: (name) => {
        const p = project;
        if (p === null) return null;
        return p.scenes.find((s) => s.name === name)?.text ?? null;
      },
    },
    project.current,
  );
}

/** 一次停播的结果（命令面与按钮共用）。 */
interface StopOutcome {
  readonly ok: boolean;
  readonly code?: string;
  readonly message?: string;
  /** 世界变了、已经回滚。`false` = 一个字节都没变，场景没被重建。 */
  readonly rolledBack?: boolean;
  /** 回滚重建出来的节点数。 */
  readonly made?: number;
  /** 这次试玩里改了几个字段（会被一起回滚）。 */
  readonly edits?: number;
}

/**
 * 停止试玩：先暂停时钟 → 再回滚 → 最后重画。
 *
 * ★ 顺序不能换：先回滚再暂停的话，回滚后的下一帧又会推进一次 tick，
 *   于是"刚回滚干净的世界"立刻又被控制器挪一下，下一次停播才发现还是脏的。
 */
function stopPlay(): StopOutcome {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  pie.pause();
  const s = playSession;
  if (s === null) {
    // 没在试玩时点"停止"不是错误：世界本来就没被改过，说清楚就行。
    pieNoteEl.textContent = "没在试玩";
    return { ok: true, rolledBack: false, made: 0, edits: 0 };
  }
  const r = endPlaySession(docDeps(app), s);
  playSession = null;
  // 批92：流程层跟着会话一起结束。回滚失败时也要清 —— 世界已经不可信，
  // 留着一个指向"半个世界"的流程层，下一次进试玩会从错误的位置开始。
  flow = null;
  portalWatcher.reset();
  flowNote = "";
  if (!r.ok) {
    // 回滚失败时**不清空 playSession 的结论**：面板必须留着"工作区不可信"这句话，
    // 否则人只会看到一条一闪而过的错误，然后接着在半个世界里编辑。
    //
    // ★ 这里用 `refreshAll` 而**不是** `afterHistoryChange`：后者会落盘，而这个时刻
    //   场景是"半个世界"（回滚中途失败）。把不可信的世界写进存档 = 把用户的文档换掉，
    //   比"这次没存上"糟糕得多 —— 下次打开就只剩这半份了。
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    refreshAll();
    return { ok: false, code: r.error.code, message: r.error.message, edits: s.edits };
  }
  lastStop = r.value;
  pieNoteEl.textContent = r.value.rolledBack
    ? `试玩结束：回滚 ${String(s.edits)} 处改动（重建 ${String(r.value.made)} 个节点）`
    : "试玩结束：世界没变，场景没有重建";
  errEl.textContent = "";
  if (r.value.skipped.length > 0) {
    errEl.textContent = `回滚时跳过 ${String(r.value.skipped.length)} 条：${r.value.skipped[0] ?? ""}`;
  }
  afterHistoryChange();
  return { ok: true, rolledBack: r.value.rolledBack, made: r.value.made, edits: s.edits };
}

// ---------------------------------------------------------------- 试玩中的跳转（批92）

/** 不在试玩中却想"跳场景"（那是编辑器的切换，规则不同：它要先保存）。 */
const EDIT_NOT_PLAYING = "EDIT.NOT_PLAYING";

interface PlayJumpOutcome {
  readonly ok: boolean;
  readonly kind?: "noop" | "jumped";
  readonly from?: string;
  readonly to?: string;
  readonly carried?: boolean;
  /**
   * 这一跳用的是**手里那份快照**（这个场景本局去过了）。
   *
   * ★ 必须报出来：`reused` 是"离开不重置"唯一能从外面看见的证据 ——
   *   只看画面的话，"从文档重建"与"从快照重建"在第一次跳进去时完全一样。
   */
  readonly reused?: boolean;
  readonly dropped?: readonly string[];
  readonly code?: string;
  readonly message?: string;
}

/**
 * 试玩中跳到工程里的另一个场景。
 *
 * ★★ 与"编辑器的切换场景"是**两件不同的事**，不许合并：
 *   - `doSceneSwitch` 会**先把当前场景写回槽位**，因为它改的是文档；
 *   - 这里**一个槽位都不写**（试玩是沙盒），停播时按会话快照回滚。
 *   合并的后果是"试玩里走过一扇门，工程里那份场景被改成了跑过两步的样子"。
 */
function doPlayJump(name: string): PlayJumpOutcome {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  if (playSession === null) {
    return {
      ok: false,
      code: EDIT_NOT_PLAYING,
      message: "不在试玩中：切场景请点场景面板（那条路会先保存当前场景）",
    };
  }
  const f = flow;
  if (f === null) return { ok: false, code: "EDIT.NOT_READY", message: "流程层没起来（工程还没就绪）" };

  const r = f.jump(name);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    flowNote = `跳转被拒：${r.error.code}`;
    docInfoEl.textContent = flowNote;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  // 落地 reseed：目标场景的落点上如果正好有一扇门，不许立刻弹回去（见 portal.ts ②）
  const portals = collectPortals(app.scene);
  if (r.value.landing !== null && portals.ok) {
    portalWatcher.reseed(r.value.landing.x, r.value.landing.z, portals.value);
  } else {
    portalWatcher.reset();
  }

  flowNote = describePlayJump(r.value);
  docInfoEl.textContent = flowNote;
  // ★ `heroId` 是"编辑器认为的玩家"，它必须跟着人跳过去：目标场景的玩家节点
  //   在文档里是另一个 id。不更新的话，所有按 heroId 取节点的命令（选中、gizmo 判据、
  //   `E.hero()`）在跳转之后都指向一个不存在的节点 —— 而画面上世界是好的。
  const np = findPlayerId(app.scene);
  if (np !== null) heroId = np;
  errEl.textContent =
    r.value.dropped.length > 0 ? `跳转丢下了：${r.value.dropped.join("；")}` : "";
  // 世界换了 ⇒ 树/属性/历史/场景面板都要重画（场景面板要标出"试玩现在在哪一份"）
  refreshTree();
  refreshProps();
  refreshHistory();
  refreshScenes();
  return {
    ok: true,
    kind: r.value.kind,
    from: r.value.from,
    to: r.value.to,
    carried: r.value.carried,
    reused: r.value.reused,
    dropped: r.value.dropped,
  };
}

function describePlayJump(r: JumpReport): string {
  if (r.kind === "noop") return `已经在「${r.to}」里（试玩中的跳转不改工程）`;
  const parts = [`试玩跳到「${r.to}」：${String(r.made)} 个节点`];
  parts.push(r.carried ? "背包/血量/饱食已带过去" : "没有可携带的状态");
  if (r.reused) parts.push("接着上一回走（这一关没重置）");
  if (r.clamped.length > 0) parts.push(`${String(r.clamped.length)} 项被上限夹住`);
  if (r.skipped.length > 0) parts.push(`${String(r.skipped.length)} 条被跳过`);
  return parts.join(" · ");
}

// ---------------------------------------------------------------- 试玩存档（批93）

/**
 * 试玩存档的存储键。**与工程键分开**：
 * 工程存的是"我设计了什么"（该一直留着），这一份存的是"我这一局走到哪儿了"
 * （随时可以覆盖、丢了不影响工程）。两者共用一个键的话，一次"存档进度"
 * 就会把用户的设计换成一次游戏的中间状态 —— 那是不可逆的。
 */
const PLAY_SAVE_KEY = "dst.editor.play.v1";

interface PlaySaveOutcome {
  readonly ok: boolean;
  readonly bytes?: number;
  readonly current?: string;
  readonly scenes?: readonly string[];
  readonly code?: string;
  readonly message?: string;
}

interface PlayLoadOutcome {
  readonly ok: boolean;
  readonly current?: string;
  readonly scenes?: number;
  readonly made?: number;
  readonly code?: string;
  readonly message?: string;
}

/** 把这一局存下来（只在试玩中；编辑器的文档请用「保存」）。 */
function doPlaySave(): PlaySaveOutcome {
  if (appRef === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  const f = flow;
  if (playSession === null || f === null) {
    return {
      ok: false,
      code: EDIT_NOT_PLAYING,
      message: "不在试玩中：进度是玩出来的，编辑文档请用左下角的「保存到文本」",
    };
  }
  let text: string;
  try {
    text = f.saveGame();
  } catch (e) {
    // 导出不该抛（同 `exportDocument` 的注释）；真抛了要说出来，不能静默留个空档
    return {
      ok: false,
      code: "EDIT.PLAY_SAVE_FAILED",
      message: `存档生成失败：${e instanceof Error ? e.message : String(e)}`,
    };
  }
  try {
    window.localStorage.setItem(PLAY_SAVE_KEY, text);
  } catch (e) {
    // ★ 写不进去（配额满 / 隐私模式）必须报错：面板上写着"已存"而实际没落盘，
    //   是这一整类功能里最伤人的失败（人关掉页面才发现）。
    return {
      ok: false,
      code: "EDIT.PLAY_SAVE_STORE",
      message: `存档写不进去（配额满或隐私模式？）：${e instanceof Error ? e.message : String(e)}`,
    };
  }
  let names: string[] = [];
  let current = f.sceneName;
  try {
    const o = JSON.parse(text) as { current?: unknown; scenes?: unknown };
    if (typeof o.current === "string") current = o.current;
    if (Array.isArray(o.scenes)) {
      names = o.scenes.map((s) => String((s as { name?: unknown }).name ?? ""));
    }
  } catch {
    // 刚由 `encodeGameSave` 生成的文本解析不了是不可能的；真发生了下一句 `text.length`
    // 仍然是对的，而"几份场景"退化成空数组 —— 不影响存档本身能不能读。
    names = [];
  }
  const note = `已存档：在「${current}」· ${String(names.length)} 份场景 · ${String(text.length)} 字节`;
  flowNote = note;
  docInfoEl.textContent = note;
  errEl.textContent = "";
  return { ok: true, bytes: text.length, current, scenes: names };
}

/** 读回上一次存的那一局。 */
function doPlayLoad(): PlayLoadOutcome {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  if (playSession === null) {
    return {
      ok: false,
      code: EDIT_NOT_PLAYING,
      message: "不在试玩中：先点「播放」再读档（读进来的是一局游戏，不是一份文档）",
    };
  }
  const f = flow;
  if (f === null) return { ok: false, code: "EDIT.NOT_READY", message: "流程层没起来（工程还没就绪）" };
  const text = window.localStorage.getItem(PLAY_SAVE_KEY);
  if (text === null || text.length === 0) {
    return { ok: false, code: "EDIT.NO_PLAY_SAVE", message: "还没有存档：先在试玩中点「存档」" };
  }

  const r = f.loadGame(text);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    flowNote = `读档被拒：${r.error.code}`;
    docInfoEl.textContent = flowNote;
    return { ok: false, code: r.error.code, message: r.error.message };
  }

  // 世界换了：跟跳转同一套收尾（heroId / 门 watcher / 三块面板）
  const np = findPlayerId(app.scene);
  if (np !== null) heroId = np;
  const portals = collectPortals(app.scene);
  const w = np === null ? undefined : app.scene.worldPositionOf(np);
  if (w !== undefined && portals.ok) {
    portalWatcher.reseed(Math.round(w.x * FIXED_UNITS), Math.round(w.y * FIXED_UNITS), portals.value);
  } else {
    portalWatcher.reset();
  }
  const note = `已读档：回到「${r.value.current}」· ${String(r.value.scenes)} 份场景 · ${String(r.value.made)} 个节点`;
  flowNote = note;
  docInfoEl.textContent = note;
  errEl.textContent = r.value.skipped.length > 0 ? `读档跳过 ${String(r.value.skipped.length)} 条：${r.value.skipped[0] ?? ""}` : "";
  refreshTree();
  refreshProps();
  refreshHistory();
  refreshScenes();
  return { ok: true, current: r.value.current, scenes: r.value.scenes, made: r.value.made };
}

/**
 * 每个逻辑步之后喂一次玩家位置：走进门就跳。
 *
 * ★ 为什么在 tick 循环里而不是每帧一次：门是**玩法事件**，判据要按 tick 复现。
 *   每帧一次的话，帧率不同触发时刻就不同（144Hz 与 60Hz 差一倍）。
 *
 * ★ 门写坏（没填 to / 半径非法）时**说一次就够**：错误行是给人看的，
 *   每 tick 刷一遍会把别的消息挤掉，而且看起来像"卡住了"。
 */
function autoPortal(): void {
  const app = appRef;
  const f = flow;
  if (app === null || f === null) return;
  const pid = findPlayerId(app.scene);
  if (pid === null) return;
  const w = app.scene.worldPositionOf(pid);
  if (w === undefined) return;
  const portals = collectPortals(app.scene);
  if (!portals.ok) {
    const line = `${portals.error.code}：${portals.error.message}`;
    if (flowNote !== line) {
      flowNote = line;
      errEl.textContent = line;
      docInfoEl.textContent = line;
    }
    return;
  }
  const hit = portalWatcher.enter(
    Math.round(w.x * FIXED_UNITS),
    Math.round(w.y * FIXED_UNITS),
    portals.value,
  );
  if (hit === null) return;
  doPlayJump(hit.portal.to);
}

// ---------------------------------------------------------------- 历史（撤销 / 重做）
/**
 * 改一个字段，并把这次改动记进历史。
 *
 * ★ 面板的输入框与命令面（自检页）**共用这一个入口**。分成两条路的话，
 *   自检验证的就不是用户点的那条代码 —— 那种判据最容易绿得毫无意义。
 *
 * ★★ 试玩期间**不进历史**。理由不是"省一条记录"，而是历史与文档必须指同一个世界：
 *   试玩改的值在停播时会被回滚（`play-session.ts` ②），历史里却留着
 *   "before → 试玩时的值"这一对，于是下一次撤销会把一个**已经不存在的变化**
 *   重放一遍 —— 人会看到"撤销把值改成了我没设过的数"。
 *   这条也顺带解释了为什么不在停播时清历史：历史记的是文档，试玩没改文档。
 */
function commitField(nodeId: NodeId, type: string, key: string, raw: unknown): Result<FieldChange, EngineError> {
  const app = appRef;
  if (app === null) return err(engineError("EDIT.NOT_READY", "编辑器还没启动"));
  const r = setField(app.scene, nodeId, type, key, raw);
  if (!r.ok) return r;
  if (playSession !== null) {
    if (r.value.changed) playSession.edits++;
    return r;
  }
  // 值没变就不进历史（见 `FieldChange.changed` 的注释：否则历史被空改动填满）
  if (r.value.changed) {
    history.push(makeFieldOp(app.scene, nodeId, type, key, r.value.before, r.value.after));
    refreshHistory();
    // ★ 属性面板的改动**不走** `afterHistoryChange`（那会重画面板，把正在输入的
    //   输入框换掉），所以这里必须自己落盘一次 —— 否则"在属性面板里改的东西"
    //   会是唯一存不进存档的一类改动。
    persistProject();
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
  // "保存到文本"之后场景内容没变，但人按了保存 ⇒ 顺手也把工程存一次
  // （存的是同一份内容，只是让存档与文本同步，不至于"我保存了但它没存"）。
  persistProject();
  return true;
}

function afterDocChange(): void {
  // 打开/新建/切场景都不进历史，所以这里不走 `afterHistoryChange` 的撤销收尾，
  // 但**必须**重画：树、面板、历史三处都变了。
  refreshAll();
  // 这三件事都改了"工程里的当前场景"，所以都要落盘。
  persistProject();
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

// ---------------------------------------------------------------- 工程（多场景）

/**
 * 试玩期间不许切场景。
 *
 * ★ 这不是"顺手加个限制"。`endPlaySession` 的回滚是 `loadDocument(s.text)` ——
 *   那句 `s.text` 是**进试玩那一刻的场景文档**。切走之后场景已经是另一份了，
 *   再停播就会把旧场景的文档装进新场景：人看到的是"我明明没动，这个场景被换了"，
 *   而且工程那边已经把新场景存好了 ⇒ 下次切走还会把旧文档写进新槽位。
 *   静默数据错乱比"切不动"糟糕得多，所以这里宁可拒绝。
 */
const EDIT_PLAYING = "EDIT.PLAYING";

function refreshScenes(): void {
  const p = project;
  if (p === null) return;
  sceneCountEl.textContent = `${String(p.scenes.length)} 个`;
  sceneListEl.textContent = "";
  // ★ 试玩中高亮的是「试玩现在所在的那一份」（`flow.sceneName`），不是工程在编辑的那一份：
  //   跳过去之后世界已经换成另一份，还高亮原来那行会让人以为跳失败了。
  const playing = playSession !== null && flow !== null;
  const active = playing && flow !== null ? flow.sceneName : p.current;
  for (const name of sceneNames(p)) {
    const row = document.createElement("div");
    // 当前项高亮：名字列表里"哪一行是正在编辑的"必须一眼看出来，
    // 否则点一下当前行会得到一句"已经在它上面"，而人以为按钮坏了。
    row.className = name === active ? "srow sel" : "srow";
    row.dataset.name = name;
    row.textContent = playing && name === active ? `${name} ▶` : name;
    // ★ 同一个手势两种语义，界面上必须说清楚是哪一种 —— 否则"试玩中点了一下场景行"
    //   会被理解成"切换文档"（那是停播之后的行为），而人不会有第二个线索。
    row.title = playing
      ? "试玩中：跳到这个场景（沙盒 —— 不改工程，停播回滚）"
      : "切换到这个场景（当前场景会先保存）";
    row.addEventListener("click", () => {
      // 同一个手势两种语义，因为上下文本来不同：试玩中点行 = **跳过去**（沙盒内，
      // 不改任何槽位）；不在试玩中 = 编辑器切换（那条路会先把当前场景写回槽位）。
      if (playSession !== null) doPlayJump(name);
      else doSceneSwitch(name);
    });
    sceneListEl.appendChild(row);
  }
  // 只剩一个时禁用删除（模型层还会再拒一次：按钮挡不住命令面）。
  btnSceneDel.disabled = p.scenes.length <= 1;
  btnSceneDel.title = p.scenes.length <= 1 ? "工程里至少得留一个场景" : "删掉当前场景";
}

function describeSwitch(r: SwitchReport): string {
  if (r.kind === "noop") return `已经在「${r.to}」上（没有重建任何节点）`;
  const parts = [`切到「${r.to}」：${String(r.made)} 个节点`];
  parts.push(r.savedFrom ? "切走前已保存原场景" : "原场景没有改动，未重写");
  if (r.droppedHistory > 0) parts.push(`清掉 ${String(r.droppedHistory)} 条历史`);
  if (r.droppedSelection > 0) parts.push(`清掉 ${String(r.droppedSelection)} 项选中`);
  if (r.skipped.length > 0) parts.push(`${String(r.skipped.length)} 条被跳过`);
  return parts.join(" · ");
}

/** 切完之后要重画的东西：树、面板、历史、场景列表，以及文本框里的"当前文档"。 */
function afterSceneSwitch(p: Project): void {
  docText.value = currentSceneText(p);
  afterDocChange();
  refreshScenes();
}

function doSceneSwitch(name: string): {
  ok: boolean;
  kind?: string;
  nodes?: number;
  savedFrom?: boolean;
  code?: string;
  message?: string;
} {
  const app = appRef;
  const p = project;
  if (app === null || p === null) return { ok: false, code: "EDIT.NOT_READY" };
  if (playSession !== null) {
    const msg = "试玩还没停：先点「停止」再切场景（否则回滚会把旧场景的文档装进新场景）";
    errEl.textContent = `${EDIT_PLAYING}：${msg}`;
    return { ok: false, code: EDIT_PLAYING, message: msg };
  }
  const r = switchScene(docDeps(app), p, name);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  // ★ noop 也必须把列表重画一遍：人点了当前那一行，界面上要留一句话
  //   （"已经在它上面"），否则看起来是点了没反应。
  if (r.value.kind === "switched") afterSceneSwitch(p);
  docInfoEl.textContent = describeSwitch(r.value);
  errEl.textContent = r.value.skipped.length > 0 ? `有 ${String(r.value.skipped.length)} 处被跳过（见控制台）` : "";
  if (r.value.skipped.length > 0) console.warn("切换场景时跳过：", r.value.skipped);
  refreshScenes();
  return { ok: true, kind: r.value.kind, nodes: r.value.made, savedFrom: r.value.savedFrom };
}

function doSceneNew(name?: string): { ok: boolean; name?: string; code?: string; message?: string } {
  const app = appRef;
  const p = project;
  if (app === null || p === null) return { ok: false, code: "EDIT.NOT_READY" };
  if (playSession !== null) {
    const msg = "试玩还没停：先点「停止」再新建场景";
    errEl.textContent = `${EDIT_PLAYING}：${msg}`;
    return { ok: false, code: EDIT_PLAYING, message: msg };
  }
  const r = createScene(docDeps(app), p, name);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  afterSceneSwitch(p);
  docInfoEl.textContent = `新建「${r.value.to}」（空场景）· ${r.value.savedFrom ? "原场景已保存" : "原场景没有改动"}`;
  errEl.textContent = "";
  return { ok: true, name: r.value.to };
}

function doSceneDelete(name?: string): { ok: boolean; name?: string; kind?: string; code?: string; message?: string } {
  const app = appRef;
  const p = project;
  if (app === null || p === null) return { ok: false, code: "EDIT.NOT_READY" };
  if (playSession !== null) {
    const msg = "试玩还没停：先点「停止」再删场景";
    errEl.textContent = `${EDIT_PLAYING}：${msg}`;
    return { ok: false, code: EDIT_PLAYING, message: msg };
  }
  const gone = name ?? p.current;
  const r = deleteScene(docDeps(app), p, name);
  if (!r.ok) {
    errEl.textContent = `${r.error.code}：${r.error.message}`;
    return { ok: false, code: r.error.code, message: r.error.message };
  }
  // 删的不是当前项时 `kind` 是 noop，场景一个字节都没动 ⇒ 不该重画树。
  if (r.value.kind === "switched") afterSceneSwitch(p);
  else refreshScenes();
  docInfoEl.textContent =
    r.value.kind === "switched"
      ? `删掉「${gone}」· 现在编辑「${r.value.to}」`
      : `删掉「${gone}」（不是当前场景，当前仍是「${r.value.to}」）`;
  errEl.textContent = "";
  return { ok: true, name: r.value.to, kind: r.value.kind };
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
  const c = requireRender().camera;
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
  // ★ 拖到画布（批89）：只有「有帧」的资产能拖 —— 与按钮同一个条件，
  //   而 `doAddAsset` 里还会再查一次（按钮/拖拽都是 UI 约束，命令面能绕过去）。
  if (e.inAtlas) {
    el.addEventListener("pointerdown", (ev) => {
      if (ev.button !== 0) return;
      pickAsset(e.path);
      // ★ 顺序：先 `pickAsset`（它会重建整列 DOM），再开拖 ——
      //   反过来的话刚设好的"拖动…"提示会被 `refreshAssets` 覆盖掉。
      beginAssetDrag(e.path, ev.clientX, ev.clientY);
      // 防止浏览器把拖动变成"拖选文字"：松手之后选区还在，下一次点行会变成改选区。
      ev.preventDefault();
    });
  }
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

/** "这次用哪张图集" —— 启动时定一次，之后只读。 */
interface AtlasChoice {
  readonly atlas: AtlasData;
  readonly frames: readonly string[];
  readonly source: "assets" | "procedural";
  readonly note: string;
}

/** 兜底：程序化图集 + 一句说明（说明会被显示出来，静默回落会让人以为在看真资产）。 */
function proceduralChoice(note: string): AtlasChoice {
  const p = buildProceduralAtlas();
  return { atlas: p, frames: [...p.frames.keys()], source: "procedural", note };
}

/**
 * 启动前把资产相关的事全做完：读清单 → 建目录 → 逐张读图 → 烘图集。
 *
 * ★ 为什么这一步在 `main()` 的最前面而不是 `bootGameApp` 之后：
 *   图集决定渲染模块的页表与纹理（见 `makeRenderModule` 的说明）。
 *
 * ★ 为什么清单要解析**两次**：烘图集需要 `name`/`kind`（只有目录知道），
 *   而 `inAtlas` 要等烘完才知道帧名。两次解析很便宜（14 项），
 *   比"先塞一个假帧表、之后再改"要诚实 —— 后者会让面板在中间态显示错的可加入数。
 */
async function prepareAssets(): Promise<AtlasChoice> {
  // ★ 两个 base，别合成一个：清单在 `web/assets-manifest.json`（页面同级），
  //   而清单里的路径是**相对 `web/assets/`** 的（`tree.png`）。
  //   合成一个 base 的后果是本批第一次跑自检时的那一幕：10 张图全都 404，
  //   烘焙空手而归、静默退回程序化图集，而画面上照样有树有石头 ——
  //   只有「可加入 0」这个数字对不上。
  const fs = new HttpFileSystem({ base: new URL("./", location.href) });
  const assetsFs = new HttpFileSystem({ base: new URL("./assets/", location.href) });
  const text = await fs.readText("assets-manifest.json");
  catalog = null;
  assetPicked = null;
  assetProblem = null;
  const fail = (why: string): AtlasChoice => {
    assetProblem = why;
    assetListEl.replaceChildren(mkAssetEmpty(`资产清单读不到：${why}`));
    assetCountEl.textContent = "—";
    btnAssetAdd.disabled = true;
    return proceduralChoice(why);
  };

  if (!text.ok) return fail(`${text.error.code} ${text.error.message}`);
  const bare = catalogFromManifest(text.value);
  if (!bare.ok) return fail(`${bare.error.code} ${bare.error.message}`);

  const textures = bare.value.entries.filter((e) => e.kind === "texture");
  const images: BakeImage[] = [];
  const io: string[] = [];
  for (const e of textures) {
    const r = await assetsFs.readBinary(e.path);
    if (!r.ok) {
      io.push(`${e.path}(${r.error.code})`);
      continue;
    }
    images.push({ name: e.name, bytes: r.value });
  }

  const baked = bakeAtlasFromImages(images);
  if (!baked.ok) {
    // 一张都没解出来：面板照样能看（全是「无帧」），但世界要退回程序化图集。
    // ★ 这里**必须**把原因写进 `assetProblem`：否则面板上 14 行全是「无帧」、
    //   没有任何一句话解释为什么 —— 与"清单里本来就没有位图"长得一模一样。
    const why =
      `${baked.error.code}：${baked.error.message}` +
      (io.length > 0 ? `（读不到：${io.join("、")}）` : "");
    assetProblem = why;
    catalog = bare.value;
    refreshAssets();
    return proceduralChoice(why);
  }

  const cat = catalogFromManifest(text.value, { frameNames: baked.value.frames });
  catalog = cat.ok ? cat.value : bare.value;
  refreshAssets();

  const note =
    `${String(baked.value.frames.length)} 帧（${String(images.length)} 张图` +
    (io.length > 0 ? `，${String(io.length)} 张读不到：${io.join("、")}` : "") +
    (baked.value.skipped.length > 0 ? `，跳过 ${String(baked.value.skipped.length)} 张` : "") +
    "）";
  return { atlas: baked.value.atlas, frames: baked.value.frames, source: "assets", note };
}

/** 视图中心对应的**根坐标系**位置。与 gizmo 用同一个换算式，不另算一套。 */
function viewCenterLocal(): { x: number; y: number } {
  const w = canvasToWorld(canvas.clientWidth / 2, canvas.clientHeight / 2);
  return { x: w.x, y: w.z };
}

/**
 * 把一个资产加成带精灵的节点（进历史，一条）。
 *
 * `at` 是**落点**（世界坐标 XZ）：拖到画布上就用指针那个点，点按钮就用视图中心。
 * ★ 语义差别不是"顺手"：点按钮时人没指定位置，落在中心最好找；拖动时人已经指定了位置，
 *   再落在中心就是"我明明拖到那儿，它跑到中间去了"。
 */
function doAddAsset(
  path: string | null,
  at?: { x: number; y: number },
): { ok: boolean; id?: number; code?: string; message?: string; at?: { x: number; y: number } } {
  const app = appRef;
  if (app === null) return { ok: false, code: "EDIT.NOT_READY", message: "编辑器还没启动" };
  const entry = path === null || catalog === null ? undefined : catalog.entries.find((e) => e.path === path);
  if (entry === undefined) {
    const msg = path === null ? "没有选中资产" : `清单里没有 ${path}`;
    errEl.textContent = msg;
    return { ok: false, code: EDIT_BAD_ASSET_LIST, message: msg };
  }
  // ★ 这里必须**自己**再查一次 `inAtlas`，不能只靠按钮禁用。
  //   「按钮 disabled」是 UI 约束，命令面（以及双击、键盘）都能绕过去；
  //   而绕过去之后 `hasFrame` 会因为**名字撞车**放行 —— `ui-font.fnt` 的名字
  //   正好等于烘进来的 `ui-font.png` 的帧名，于是会造出一个指向字体图的精灵。
  //   这条洞是批87 的页面自检咬出来的（"无帧被拒"那条返回了 ok:true）。
  if (!entry.inAtlas) {
    const msg = `${entry.path} 不能加进场景：它不是位图，或图集里没有帧 "${entry.name}"`;
    errEl.textContent = msg;
    return { ok: false, code: EDIT_NO_FRAME, message: msg };
  }
  const pos = at ?? viewCenterLocal();
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
  return { ok: true, id: r.value.nodeId, at: pos };
}

// ---------------------------------------------------------------- 拖资产到画布（批89）

/**
 * 把资产行拖到画布上 ⇒ 落在**指针所在的世界坐标**（而不是视图中心）。
 *
 * ★ 与场景树拖放（批85）同一套模型：`pointerdown` 在行上开拖、`document` 上收
 *   move/up、落点用坐标自己算。理由写在那一段注释里 —— 合成 `DragEvent` 在无头浏览器里
 *   基本做不出来，而"只有人能验的接线"是本仓库最不想要的东西。
 *
 * ★★ 这一批唯一真正的语义是**落点必须是指针**：
 *   点按钮落在视图中心是对的（人没指定位置），拖动再落中心就是
 *   「我明明拖到那儿，它跑到中间去了」。所以判据不能只验"多了一个节点"，
 *   必须验"它在那个世界点上"。
 */
let assetDrag: { path: string; fromX: number; fromY: number; armed: boolean } | null = null;

/** 判定"真的在拖"的位移阈值（CSS px）。 */
const ASSET_DRAG_SLOP = 4;

/** 客户端坐标 → 世界 XZ。返回 `null` = 不在画布范围内（松手在别处不算投放）。 */
function canvasDropPoint(clientX: number, clientY: number): { x: number; y: number } | null {
  const r = canvas.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) return null;
  const cx = clientX - r.left;
  const cy = clientY - r.top;
  if (cx < 0 || cy < 0 || cx >= r.width || cy >= r.height) return null;
  const w = canvasToWorld(cx, cy);
  return { x: w.x, y: w.z };
}

function beginAssetDrag(path: string, clientX: number, clientY: number): void {
  assetDrag = { path, fromX: clientX, fromY: clientY, armed: false };
}

function moveAssetDrag(clientX: number, clientY: number): void {
  const d = assetDrag;
  if (d === null) return;
  // ★ 位移阈值：没有它，单击与双击也会开一场"拖拽"，然后以"没落在画布上"收尾 ——
  //   双击加资产的那条路会被这句提示语盖掉，人看到的是"加了但报了个错"。
  if (!d.armed) {
    if (Math.hypot(clientX - d.fromX, clientY - d.fromY) < ASSET_DRAG_SLOP) return;
    d.armed = true;
    assetCountEl.textContent = `拖动 ${d.path} …… 松手落在指针处`;
  }
  // 高亮：不亮的话人不知道"这里能不能放"，只能试一次。
  canvas.classList.toggle("drop", canvasDropPoint(clientX, clientY) !== null);
}

/** 松手。`dropped` 区分"放上了画布"与"松在别处" —— 后者要说一句，否则像拖丢了。 */
function finishAssetDrag(
  clientX: number,
  clientY: number,
): { ok: boolean; id?: number; dropped: boolean; code?: string } {
  const d = assetDrag;
  if (d === null) return { ok: true, dropped: false };
  assetDrag = null;
  canvas.classList.remove("drop");
  // 没超过阈值 = 这只是一次点击，不是投放：一个字都不许改（别盖掉双击的提示）。
  if (!d.armed) return { ok: true, dropped: false };
  const at = canvasDropPoint(clientX, clientY);
  if (at === null) {
    assetCountEl.textContent = "没落在画布上：资产没有加进场景";
    return { ok: true, dropped: false };
  }
  const r = doAddAsset(d.path, at);
  // 把计数行恢复成条数（拖的时候被提示语占了）
  refreshAssets();
  return { ok: r.ok, id: r.id, dropped: true, code: r.code };
}

/** 接线（在 `main()` 里调一次）。监听器挂在 document 上，与场景树拖放同一个理由。 */
function bindAssetDrag(): void {
  document.addEventListener("pointermove", (e) => {
    moveAssetDrag(e.clientX, e.clientY);
  });
  document.addEventListener("pointerup", (e) => {
    if (assetDrag !== null) finishAssetDrag(e.clientX, e.clientY);
  });
  document.addEventListener("pointercancel", () => {
    if (assetDrag === null) return;
    assetDrag = null;
    canvas.classList.remove("drop");
    refreshAssets();
  });
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
  refreshAll();
  // ★ 这里是**所有真实改动**的汇聚点（新建 / 删除 / 换父 / 撤销 / 重做 / 挂组件…），
  //   所以自动保存挂在这里，而不是在每个动作后面各调一次 —— 那种写法一定会漏一处，
  //   而漏一处等于"这个动作存不进去"。
  //   唯一的例外是"回滚失败"：那时世界不可信，不写盘（见 `stopPlay` 里对 `refreshAll` 的使用）。
  persistProject();
}

/** 只重画，不落盘（世界不可信的时候用它）。 */
function refreshAll(): void {
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
    for (let i = 0; i < ticks; i++) {
      app.frame(FIXED_DT);
      // 每个逻辑步之后喂一次玩家位置（门是玩法事件，触发时刻按 tick 算 —— 见 autoPortal）
      if (playSession !== null) autoPortal();
    }
    // 每 0.5 秒刷一次树（每帧重建 DOM 在 500 节点上会掉到个位数帧率）
    if (now - uiClock > 500) {
      uiClock = now;
      refreshTree();
      // ★ 试玩中回显实时值。
      //   不回显的表现是：世界已经跑到别处去了，面板还停在"点选中那一刻"的数字上，
      //   于是"运行时改属性"看起来完全没用（改完值又跳回去 —— 其实是面板自己旧了）。
      //   闸门是 `propsFocused()`：正在框里打字时重建 DOM 会把焦点和光标一起清掉。
      if (playSession !== null && !propsFocused()) refreshProps();
      const st = pie.stats();
      tickEl.textContent = `tick ${String(app.scheduler.stats().tick)}`;
      pieInfoEl.textContent = st.playing ? "播放中" : st.pending > 0 ? `待跑 ${String(st.pending)}` : "暂停";
    }
  }
  requestAnimationFrame(loop);
}

/** 有人正在面板里输入吗（重建 DOM 会抢走焦点）。 */
function propsFocused(): boolean {
  const a = document.activeElement;
  return a !== null && propsEl.contains(a);
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
  /**
   * 某个节点的位置（XZ，`localPosition.y` 就是世界 Z —— 引擎是 2.5D，Y 是高度、不进这里）。
   *
   * ★ 存在的理由：试玩判据要回答"玩家**真的**挪了没有"。面板只暴露组件字段，
   *   位置不在里面，于是"按下方向键之后世界变了"这件事在命令面上根本读不到 ——
   *   读不到就只能去比截图，那种判据又慢又抖。
   */
  pos(id: number): { x: number; z: number } | null;
  /** 玩家节点 id（`-1` = 世界还没装配好）。 */
  hero(): number;
  setField(node: number, type: string, key: string, raw: unknown): { ok: boolean; code?: string; value?: unknown };
  step(n: number): number;
  play(): void;
  pause(): void;
  /** 结束试玩并回滚（`rolledBack` 为 false = 世界没变、场景没重建）。 */
  stop(): { ok: boolean; code?: string; message?: string; rolledBack?: boolean; made?: number; edits?: number };
  /**
   * 试玩会话的状态。`driven` 是控制器模块这一 tick 驱动到的节点数 ——
   * 它是「玩家到底有没有控制器」这件事**唯一**的接线判据。
   */
  playInfo(): {
    active: boolean;
    playing: boolean;
    edits: number;
    driven: number;
    lastStop: { rolledBack: boolean; made: number } | null;
  };
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
  /** 工程里的场景列表 + 当前项（顺序即列表顺序）。 */
  scenes(): { list: string[]; current: string };
  /**
   * 切到某个场景。`kind === "noop"` = 目标就是当前场景，**一个节点实例都没换**。
   *
   * 试玩期间会被拒（`EDIT.PLAYING`）—— 理由见 `EDIT_PLAYING` 的注释。
   */
  sceneSwitch(name: string): {
    ok: boolean;
    kind?: string;
    nodes?: number;
    savedFrom?: boolean;
    code?: string;
    message?: string;
  };
  /** 新建一个空场景并切过去；`name` 缺省时自动取一个没被占用的编号。 */
  sceneNew(name?: string): { ok: boolean; name?: string; code?: string; message?: string };
  /** 删一个场景（缺省 = 当前）。删当前时会先切到邻居；只剩一个时会被拒。 */
  sceneDelete(name?: string): { ok: boolean; name?: string; kind?: string; code?: string; message?: string };
  /**
   * **试玩中**跳到工程里的另一个场景（沙盒内，不改任何槽位）。
   *
   * ★ 与 `sceneSwitch` 是两件事：后者会先把当前场景写回槽位（它改的是文档）。
   *   不在试玩中调这里会被拒（`EDIT.NOT_PLAYING`）—— 那时候该走 `sceneSwitch`。
   */
  playJump(name: string): {
    ok: boolean;
    kind?: string;
    from?: string;
    to?: string;
    carried?: boolean;
    dropped?: readonly string[];
    code?: string;
    message?: string;
  };
  /** 试玩现在装的是哪一份场景（不在试玩中是 `null`）。 */
  playScene(): string | null;
  /**
   * **试玩中**存一份进度（当前场景 + 本局去过的每一份）。
   *
   * 与工程的 `saveInfo` / 槽位完全分开：那条路存的是设计，这条存的是这一局。
   */
  playSave(): PlaySaveOutcome;
  /** 读回上一次的进度（`playSave` 存的那一份）。 */
  playLoad(): PlayLoadOutcome;
  /** 存档媒介上那一份进度（字节数 / 当前场景 / 场景清单）；没存过时 `bytes = -1`。 */
  playSaveInfo(): {
    readonly bytes: number;
    readonly current: string | null;
    readonly scenes: readonly string[];
  };
  /**
   * 存档现状（面板上那句话 + 存档键里现在有多少字节，没存过是 -1）。
   *
   * ★ 判据不满足于"面板说了已存"：它必须能对着**存档媒介**核（`localStorage` 里
   *   到底有没有、多少字节），否则"存了"和"面板上写着存了"分不开。
   */
  saveInfo(): { note: string; storedBytes: number };
  /**
   * 节点**实例**的序号（`-1` = 节点不在）。
   *
   * ★ 这是「切到同一份场景不该重建」这条保证唯一的可观察形态：
   *   `nodeId` 写在文档里，切走再切回来 id 不变，但 `Node` 实例已经换了 ——
   *   只看 id / 名字 / 节点数，重建与不重建**完全一样**（那就是假绿）。
   */
  nodeSerial(id: number): number;
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
  /**
   * 面板标题与清单健康状况（条数 / 可加入数 / 出问题的原因 / 图集来源）。
   *
   * `atlasSource` 是这批最要紧的一个观测点：`"procedural"` 意味着资产没读进来、
   * 世界在用 6 帧假贴图 —— 而这在画面上**看不出来**（照样有树有石头）。
   */
  assetInfo(): {
    count: number;
    usable: number;
    title: string;
    problem: string | null;
    atlasSource: "assets" | "procedural";
    atlasNote: string;
    frames: number;
  };
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
    pos(id) {
      const n = app.scene.find(id);
      if (n === undefined) return null;
      return { x: n.localPosition.x, z: n.localPosition.y };
    },
    hero() {
      return heroId;
    },
    setField(node, type, key, raw) {
      const r = commitField(node, type, key, raw);
      if (!r.ok) return { ok: false, code: r.error.code };
      refreshProps();
      return { ok: true, value: r.value.after };
    },
    step(n) {
      // ★ 命令面这里是**直接推帧**，不经过 `pie.advance` —— 所以它也必须自己开会话，
      //   否则自检/命令面走的那条路是"能跑但停不下来"的，而按钮那条路是好的。
      beginPlay();
      const k = Math.max(0, Math.floor(n));
      for (let i = 0; i < k; i++) {
        app.frame(FIXED_DT);
        // 命令面这条路也要喂：否则"按键走过去进门"只有按钮那条路能触发
        if (playSession !== null) autoPortal();
      }
      return app.scheduler.stats().tick;
    },
    play() {
      if (beginPlay() !== null) pie.play();
    },
    pause() {
      pie.pause();
    },
    stop() {
      return stopPlay();
    },
    playInfo() {
      const st = pie.stats();
      return {
        active: playSession !== null,
        playing: st.playing,
        edits: playSession === null ? 0 : playSession.edits,
        // ★ 这条是"控制器真的挂上了没有"的接线判据：模块每 tick 都在驱动，
        //   但没有任何节点带 `game.controller` 时它恒为 0，而世界看起来只是"很安静"。
        driven: controllerMod.driven,
        lastStop:
          lastStop === null ? null : { rolledBack: lastStop.rolledBack, made: lastStop.made },
      };
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
    scenes() {
      const p = project;
      return p === null ? { list: [], current: "" } : { list: sceneNames(p), current: p.current };
    },
    sceneSwitch(name) {
      return doSceneSwitch(name);
    },
    sceneNew(name) {
      return doSceneNew(name);
    },
    sceneDelete(name) {
      return doSceneDelete(name);
    },
    playJump(name) {
      return doPlayJump(name);
    },
    playScene() {
      return flow === null ? null : flow.sceneName;
    },
    playSave() {
      return doPlaySave();
    },
    playLoad() {
      return doPlayLoad();
    },
    playSaveInfo() {
      // 与 `saveInfo` 同一个口径：字节数**问媒介**，不问我们自己的变量
      const text = window.localStorage.getItem(PLAY_SAVE_KEY);
      if (text === null) return { bytes: -1, current: null, scenes: [] };
      try {
        const o = JSON.parse(text) as { current?: unknown; scenes?: unknown };
        const scenes = Array.isArray(o.scenes)
          ? o.scenes.map((s) => String((s as { name?: unknown }).name ?? ""))
          : [];
        return { bytes: text.length, current: typeof o.current === "string" ? o.current : null, scenes };
      } catch {
        // 键在但内容不是 JSON（被手改过 / 别的版本写的）：如实报"读不出结构"，
        // 不假装没存过（`-1` 会让人以为"从没存过"，而去重新存一次覆盖掉线索）
        return { bytes: text.length, current: null, scenes: [] };
      }
    },
    saveInfo() {
      // ★ 字节数直接问存档媒介（不是问我们自己记的变量）：`-1` = 键不存在。
      //   问变量的话，"写失败但变量改了"这种实现会一路绿到底。
      let storedBytes = -1;
      try {
        const t = window.localStorage.getItem(PROJECT_STORAGE_KEY);
        storedBytes = t === null ? -1 : new TextEncoder().encode(t).length;
      } catch {
        storedBytes = -2;
      }
      return { note: saveNoteEl.textContent ?? "", storedBytes };
    },
    nodeSerial(id) {
      const n = app.scene.find(id);
      return n === undefined ? -1 : serialOf(n);
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
      const c = requireRender().camera;
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
      return {
        count,
        usable,
        title: assetCountEl.textContent ?? "",
        problem: assetProblem,
        atlasSource,
        atlasNote,
        frames: atlasFrames.length,
      };
    },
  };
  (window as unknown as { __editor?: EditorApi }).__editor = api;
}

// ---------------------------------------------------------------- 启动
async function main(): Promise<void> {
  planRef = generateWorld({ seed: WORLD_SEED, width: WORLD_W, height: WORLD_H, maxSitesPerCell: 1 });

  // ★ 顺序钉死：读清单 → 读图 → 烘图集 → 建渲染模块 → 启动。
  //   图集决定页表与纹理，所以它必须在渲染模块之前定好（见 `makeRenderModule`）。
  const choice = await prepareAssets();
  atlasFrames = choice.frames;
  atlasSource = choice.source;
  atlasNote = choice.note;
  const rm = makeRenderModule(choice.atlas);
  renderMod = rm;
  watchViewport();
  statusEl.textContent = `图集 ${choice.source === "assets" ? "资产" : "程序化"} · ${choice.note}`;

  const appR = await bootGameApp({
    platformId: "editor",
    interactive: true,
    registry,
    // `controllerMod` 必须在这个列表里：它的 `init` 要从 services 拿到 Scene
    // （拿不到就永远不会驱动任何节点），而它自己不会被框架 update —— 由 `worldMod`
    // 的 `onStep` 调（见上面那段注释）。
    modules: [worldMod, rm, worldgenMod, controllerMod],
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
  bindAssetDrag();

  // ★ 工程在**世界装好之后**才建：第一个槽位就是刚装上来的这个世界。
  //   先建工程再装世界的话，第一个槽位要么是空文档、要么得靠后面补一次导出 ——
  //   而"补一次"这种事,后面一定会有人忘。
  const t0 = exportDocument(docDeps(app));
  if (!t0.ok) {
    errEl.textContent = `工程初始化失败：${t0.error.code}：${t0.error.message}`;
    return;
  }
  // ★ 有存档就用存档（`adoptStoredProject` 内部保证：读不出来时不清档、退回新工程）。
  //   这一步必须在**任何一次 persistProject 之前** —— 反过来的话，第一次自动保存
  //   就把默认世界写进存档，用户的几个场景被一份新世界覆盖，界面上还一切正常。
  project = adoptStoredProject(app, t0.value);
  docText.value = currentSceneText(project);
  docInfoEl.textContent = `工程：${String(project.scenes.length)} 个场景 · 当前「${project.current}」`;
  refreshScenes();
  btnSceneNew.addEventListener("click", () => {
    doSceneNew();
  });
  btnSceneDel.addEventListener("click", () => {
    doSceneDelete();
  });

  // 清单与图集在 `main()` 开头就已经准备好（启动顺序见那里的说明）。
  btnAssetAdd.addEventListener("click", () => {
    doAddAsset(assetPicked);
  });
  // ★ 播放与单步都要先开会话（见 `beginPlay`）：漏了的话这些动作产生的改动
  //   会**没有回滚基准**，停播时只能干看着世界停在试玩后的样子。
  btnPlay.addEventListener("click", () => {
    if (beginPlay() !== null) pie.play();
  });
  btnPause.addEventListener("click", () => pie.pause());
  btnStop.addEventListener("click", () => void stopPlay());
  btnStep.addEventListener("click", () => {
    if (beginPlay() !== null) pie.step(1);
  });
  btnStep10.addEventListener("click", () => {
    if (beginPlay() !== null) pie.step(10);
  });
  btnPSave.addEventListener("click", () => {
    doPlaySave();
  });
  btnPLoad.addEventListener("click", () => {
    doPlayLoad();
  });
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
