/**
 * 浏览器宿主入口（L6）
 *
 * 这是"引擎真的能跑"的证据：注册真实后端 → 建世界 → 输入驱动 → 物理碰撞 → 渲染 → 存档。
 *
 * ★ 这个文件允许知道一切（具体后端、具体组件、具体玩法）—— 它是 **宿主**。
 *   内核不知道它的存在。所以这里出现 `webgl2Backend` / `domInputBackend` 是**正确**的；
 *   同样的 import 出现在 `core/**` 里就是架构崩了（arch 规则 4 会红）。
 *
 * 资产：启动时把 `web/assets/*.png` 走**完整导入链**烘焙成真图集 ——
 *   `fetch → 内存 fs → AssetImportPipeline（.meta/增量/依赖）→ PNG 解码 → shelf packing`。
 *   任一步失败（例如用 file:// 直接打开被 CORS 拦住）则降级到程序化图集，
 *   但 HUD 会显示 `atlas:assets×5` 还是 `atlas:procedural` —— **降级不静默**。
 *   静默降级的后果是"以为在测真资产，其实在测假贴图"，这正是本轮要消灭的盲区。
 *
 * ★ 装配顺序很重要（第一版写错过）：
 *   物理 → 渲染模块 → 世界模块 → bootGameApp(modules) → 摆世界 → run()
 *   模块的 init/start **必须交给 ModuleRegistry**，不能在 boot 之后手动调 ——
 *   手动调会绕过拓扑排序与失败回滚，而且很容易漏掉 stop/dispose。
 */

import { BackendRegistry } from "./platform/registry.ts";
import { registerNullBackends } from "./backends/index.ts";
import { createLuaScriptBackend } from "./backends/script-lua/runtime.ts";
import { webgl2Backend } from "./backends/gfx-webgl2/device.ts";
import { domInputBackend } from "./backends/input-dom/device.ts";
import { webAudioBackend } from "./backends/audio-webaudio/device.ts";
import { bootGameApp, type GameApp } from "./runtime/GameApp.ts";
import { RafTickSource } from "./runtime/tick-source.ts";
import { Services } from "./core/tokens.ts";
import { Component, type ComponentRegistry, FieldType, type ComponentSchema } from "./core/scene/component.ts";
import type { IModule, ModuleContext } from "./core/module/module.ts";
import type { FixedStepScheduler } from "./core/scheduler/scheduler.ts";
import type { InputSnapshot } from "./platform/input/device.ts";
import { createRenderModule } from "./extensions/render/render-module.ts";
import { Sprite, makeSprite } from "./extensions/render/sprite.ts";
import { SpatialHashWorld, makeSceneAccessor } from "./extensions/physics/physics.ts";
import { createScriptModule } from "./extensions/script/script-module.ts";
import { ScriptComponent } from "./extensions/script/script-component.ts";
import { saveScene, loadScene, sceneToJson, sceneFromJson } from "./core/scene/scene-io.ts";
import { stableHash } from "./core/serialization/schema.ts";
import { Logger, LogLevel } from "./foundation/log/logger.ts";
import { MemoryFileSystem } from "./backends/fs-memory/fs.ts";
import { AssetDatabase } from "./core/asset/asset.ts";
import { ImporterRegistry } from "./extensions/asset-import/importer.ts";
import { AssetImportPipeline } from "./extensions/asset-import/pipeline.ts";
import { textureImporter } from "./extensions/asset-import/importers/texture.ts";
import { atlasImporter } from "./extensions/asset-import/importers/atlas.ts";
import { textImporter } from "./extensions/asset-import/importers/text.ts";
import { ImportedTexture, createImportLoaders } from "./extensions/asset-import/loaders.ts";
import { decodePng } from "./extensions/asset-import/decode/png.ts";
import { buildAtlasFromSources, type AtlasSource } from "./extensions/render/atlas-from-assets.ts";
import type { AtlasData } from "./extensions/render/atlas.ts";

// ---------------------------------------------------------------- 组件

/**
 * 玩家控制器：WASD 移动。
 * ★ 用 `tick` 去重 poll：一帧可能跑多个固定步，poll 多次会吞掉"按下"边缘，
 *   表现为"按一下走两步"或"点一下没反应"。
 */
class PlayerController extends Component {
  speed = 4.5;
  private lastTick = -1;
  private snap: InputSnapshot | null = null;
  static pollInput: (() => InputSnapshot) | null = null;

  readonly schema: ComponentSchema = {
    type: "game.player",
    fields: { speed: FieldType.Float },
  };

  override onUpdate(tick: number, dt: number): void {
    const poll = PlayerController.pollInput;
    if (poll === null) return;
    if (tick !== this.lastTick) {
      this.snap = poll();
      this.lastTick = tick;
    }
    const s = this.snap;
    if (s === null) return;

    let dx = 0;
    let dz = 0;
    if (s.keysDown.has("KeyA") || s.keysDown.has("ArrowLeft")) dx -= 1;
    if (s.keysDown.has("KeyD") || s.keysDown.has("ArrowRight")) dx += 1;
    if (s.keysDown.has("KeyW") || s.keysDown.has("ArrowUp")) dz += 1;
    if (s.keysDown.has("KeyS") || s.keysDown.has("ArrowDown")) dz -= 1;
    const len = Math.hypot(dx, dz);
    if (len === 0) return;
    const n = this.node;
    if (n === null) return;
    n.setLocalPosition(
      n.localPosition.x + (dx / len) * this.speed * dt,
      n.localPosition.y + (dz / len) * this.speed * dt,
    );
  }
}

/** 可被砍：砍到 0 就倒（演示组件数据随存档往返）。 */
class Workable extends Component {
  workleft = 3;
  readonly schema: ComponentSchema = {
    type: "game.workable",
    fields: { workleft: FieldType.Int },
  };
}

// ---------------------------------------------------------------- 世界模块

/**
 * 世界步进模块：`scene.step` + `physics.resolve`。
 * ★ 两者在**同一个回调**里，顺序写死。分成两个模块订阅会依赖"注册顺序"这种隐式约定，
 *   而那种约定在重构时会静默失效（物理先于移动解算 = 穿墙一帧）。
 */
function createWorldModule(
  physics: SpatialHashWorld,
  hooks: { onTick: (t: number) => void; onStep?: (tick: number, dt: number) => void },
): IModule {
  let off: (() => void) | null = null;
  return {
    id: "game.world",
    init(ctx: ModuleContext): void {
      const scene = ctx.services.require(Services.Scene);
      const sched = ctx.services.require<FixedStepScheduler>(Services.Scheduler);
      off = sched.onStep((tick, dt) => {
        scene.step(tick, dt);
        physics.resolve();
        // 脚本在"世界步进之后"跑：脚本读到的是本 tick 的确定状态
        //（若放在 step 之前，脚本看到的位置会晚一个 tick —— 操作手感会"黏"）
        hooks.onStep?.(tick, dt);
        hooks.onTick(tick);
      });
    },
    stop(): void {
      off?.();
      off = null;
    },
    describe(): string {
      return `世界：${physics.stats().bodies} 个物理体`;
    },
  };
}

// ---------------------------------------------------------------- 演示脚本

/**
 * 内联的 Lua 演示（Lua 5.4）。
 *
 * ★ 为什么脚本驱动的是"浆果漂浮"这种小事：它一次用到脚本层全部四件能力
 *   —— 查节点（`engine_nodes_named`）、读位置、写位置、写日志 ——
 *   而且**肉眼可见**。脚本层最容易的假完成是"能调通一个 return 1+1"，
 *   却在真实世界里什么都不做；这一条断言的是"脚本真的改变了世界"。
 *
 * ★ 只在首帧收集一次节点 id：`engine_nodes_named` 每个 tick 调一次是 O(N) 遍历，
 *   而节点集合在游戏里并不会每帧变 —— 把"每帧全表扫描"降成"一次扫描"。
 */
const LUA_DEMO = `
local beans = {}
local t = 0

local function collect()
  for i = 0, 13 do
    local ids = engine_nodes_named("berry" .. tostring(i))
    if #ids > 0 then
      beans[#beans + 1] = { id = ids[1] }
    end
  end
end

function onUpdate(selfId, dt, tick)
  t = t + dt
  if #beans == 0 then collect() end
  for i = 1, #beans do
    local b = beans[i]
    if b.z0 == nil then
      local p = engine_get_pos(b.id)
      if p ~= nil then
        b.x0 = p.x
        b.z0 = p.z
      end
    end
    if b.z0 ~= nil then
      engine_set_pos(b.id, b.x0, b.z0 + math.sin(t * 1.6 + i) * 0.18)
    end
  end
  if tick > 0 and tick % 60 == 0 then
    engine_log("demo: " .. tostring(#beans) .. " 个浆果在漂浮 (tick " .. tostring(tick) .. ")")
  end
end
`;

// ---------------------------------------------------------------- 资产烘焙

/**
 * demo 用到的帧名。**顺序即图集排布顺序**（shelf packing 内部还会按高度重排，
 * 但这里是"按什么顺序读资产/查 id"，固定下来才能保证两次运行产出同一张图集）。
 */
const DEMO_FRAMES = ["ground", "tree", "rock", "berry", "player"] as const;

/** 烘焙期的资产根目录。**必须与 `pipeline.run()` / `createImportLoaders()` 用同一个**。 */
const ASSET_ROOT = "/assets";

interface BakedAtlas {
  readonly atlas: AtlasData;
  readonly label: string;
}

/**
 * 资产烘焙：`fetch PNG → 内存 fs → 导入管线 → 解码 → 合成图集`。
 *
 * ★ 这不是"给 demo 特供的捷径"，而是**编辑器里"导入资产"的同一份代码**
 *   （`AssetImportPipeline` + `SourceImporter` + `decodePng` + `buildAtlasFromSources`），
 *   只把两端的存储换成了内存与直接渲染。所以它验证的是整条链：
 *   文件真的被扫到 → 真的生成 `.meta` → 真的按 hash 增量 → 真的解码成 RGBA8
 *   → 真的上传给 GPU。
 *
 * ★ 为什么在 `bootGameApp` **之前**跑：
 *   图集是渲染模块 `init` 的输入，而 `init` 发生在 boot 里。所以烘焙必须先完成。
 *   这也符合现实：资产导入是**构建期**工作，不是每帧工作。
 *
 * ★ 失败就降级到程序化图集（`atlas.ts`），但**不静默**：
 *   返回值是 null 时，HUD 会显示 `atlas:procedural`，`__engine.atlasSource` 也会说明。
 *   静默降级的后果是"以为在测真资产，其实在测假贴图"—— 这正是本轮要消灭的盲区。
 */
async function bakeAtlasFromAssets(): Promise<BakedAtlas | null> {
  try {
    const fs = new MemoryFileSystem();
    const logger = new Logger(() => performance.now());
    logger.setLevel(LogLevel.Warn);
    const db = new AssetDatabase(fs, logger.channel("asset"));
    const importers = new ImporterRegistry();
    importers.register(textureImporter);
    importers.register(atlasImporter);
    importers.register(textImporter);
    const pipeline = new AssetImportPipeline(fs, db, importers, logger.channel("import"));
    // ★ 加载器要显式注册，root 必须与下面 run() 的参数一致（产物路径由 root 决定）。
    //   漏注册的症状是"导入报告完美、db.load 全 NO_LOADER" —— 中间层做完两头没接。
    for (const l of createImportLoaders({ root: ASSET_ROOT })) db.registerLoader(l);

    for (const name of DEMO_FRAMES) {
      const res = await fetch(new URL(`assets/${name}.png`, location.href), { cache: "no-cache" });
      if (!res.ok) return null;
      const w = await fs.writeBinary(`${ASSET_ROOT}/${name}.png`, new Uint8Array(await res.arrayBuffer()));
      if (!w.ok) return null;
    }

    const report = await pipeline.run(ASSET_ROOT);
    if (!report.ok) return null;

    const sources: AtlasSource[] = [];
    for (const name of DEMO_FRAMES) {
      const id = db.idAtPath(`${ASSET_ROOT}/${name}.png`);
      if (id === undefined) continue;
      const h = await db.load(id);
      if (!h.ok) continue;
      const asset = h.value.asset;
      try {
        if (asset instanceof ImportedTexture) {
          const dec = decodePng(asset.bytes);
          if (dec.ok) sources.push({ name, png: dec.value });
        }
      } finally {
        h.value.release();
      }
    }
    // 少一张就整体降级：缺帧的图集会让 sprite 指向不存在的帧，画面出现"凭空消失的树"，
    // 比直接用程序化图集更难排查。
    if (sources.length !== DEMO_FRAMES.length) return null;

    const built = buildAtlasFromSources(sources, { padding: 2 });
    if (!built.ok) return null;
    return { atlas: built.value, label: `assets×${sources.length}` };
  } catch {
    // file:// 直接打开（fetch 被 CORS 拦）/ 资产缺失 —— 都是预期内的降级路径
    return null;
  }
}

// ---------------------------------------------------------------- main

export async function main(): Promise<void> {
  const canvas = document.getElementById("cv") as HTMLCanvasElement | null;
  const hud = document.getElementById("hud");
  const toastEl = document.getElementById("toast");
  if (canvas === null || hud === null || toastEl === null) {
    throw new Error("页面结构不完整：需要 #cv / #hud / #toast");
  }

  const dpr = Math.min(2, window.devicePixelRatio || 1);
  canvas.width = Math.floor((canvas.clientWidth || 960) * dpr);
  canvas.height = Math.floor((canvas.clientHeight || 600) * dpr);

  const registry = new BackendRegistry();
  registerNullBackends(registry); // 兜底：真实后端 probe 失败时自动降级
  registry.registerGfx(webgl2Backend, 100);
  registry.registerInput(domInputBackend, 100);
  registry.registerAudio(webAudioBackend, 100);
  // 脚本后端：wasm 从**本目录**取（`web/glue.wasm`），不依赖 unpkg ——
  // 否则"离线能不能跑"就变成了对 CDN 的依赖。
  registry.registerScript(createLuaScriptBackend({ wasmPath: new URL("glue.wasm", location.href).href }), 100);

  // ---- 先建物理（位置访问器是惰性的：step 时才读 app）
  let appRef: GameApp | null = null;
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
    { cellSize: 4, maxIterations: 3 },
  );

  let heroId = -1;
  let hudTick = 0;

  // ---- 资产烘焙（必须在渲染模块之前：图集是渲染 init 的输入）
  const baked = await bakeAtlasFromAssets();
  const atlasLabel = baked === null ? "procedural" : baked.label;

  // ---- 渲染模块（follow 闭包读 heroId，世界建好后才有效）
  const renderMod = createRenderModule({
    viewportWidth: canvas.width,
    viewportHeight: canvas.height,
    zoom: 26 * dpr,
    tiltY: 0.62,
    atlas: baked?.atlas,
    follow: () => {
      if (heroId < 0) return undefined;
      const n = appRef?.scene.find(heroId);
      if (n === undefined) return undefined;
      // 2.5D：世界的 z 就是 Node 的 y（Node 只有二维局部坐标）
      const p = n.worldPosition;
      return { x: p.x, z: p.y };
    },
  });

  // 脚本模块：单次调用 16ms 预算（≈半个 tick）。不设预算的死循环会挂住整个页面。
  const scriptMod = createScriptModule({ callTimeoutMs: 16 });

  const worldMod = createWorldModule(physics, {
    onTick: (t) => (hudTick = t),
    onStep: (tick, dt) => {
      // 不 await：宿主在同步的 onStep 里。ScriptModule 内部有串行队列，
      // 保证 tick N+1 不会插到 tick N 的 Lua 调用中间。
      void scriptMod.update(tick, dt);
    },
  });

  const appR = await bootGameApp({
    platformId: "web",
    interactive: true,
    registry,
    modules: [worldMod, renderMod, scriptMod],
    seed: 20261022,
    fixedDt: 1 / 30,
    tickSource: new RafTickSource(() => performance.now()),
    backendOptions: {
      gfx: { canvas },
      input: { keyboard: window, pointer: canvas },
      audio: {},
    },
  });

  if (!appR.ok) {
    document.body.innerHTML =
      `<pre style="color:#f66;padding:16px;font:13px ui-monospace">启动失败：${appR.error.code}\n` +
      `${appR.error.message}\n\n${JSON.stringify(appR.error.detail ?? {}, null, 2)}</pre>`;
    return;
  }
  const app = appR.value;
  appRef = app;
  PlayerController.pollInput = () => app.platform.input.poll();

  // ---- 脚本：加载演示模块
  // ★ 只 loadModule 是**不会执行**的：ScriptModule 遍历的是 `game.script` 组件，
  //   所以下面还要给 hero 挂一个（见 "挂脚本组件"）。这是"脚本加载了但没跑"
  //   最常见的原因，因此在两处都写清楚。
  const scriptRuntime = scriptMod.runtime;
  if (scriptRuntime === null) {
    app.log.channel("host").warn("平台没有脚本运行时：演示脚本不会执行");
  } else {
    const lr = await scriptRuntime.loadModule("demo", LUA_DEMO);
    if (!lr.ok) app.log.channel("host").error(`演示脚本加载失败：${lr.error.code} ${lr.error.message}`);
  }

  // ---- 组件注册（新增组件 = 一次 register，不改内核）
  const reg: ComponentRegistry = app.components;
  reg.register(new Sprite().schema, () => new Sprite());
  reg.register({ type: "game.player", fields: { speed: FieldType.Float } }, () => new PlayerController());
  reg.register({ type: "game.workable", fields: { workleft: FieldType.Int } }, () => new Workable());

  // ---- 摆世界
  const scene = app.scene;
  const rnd = app.random;

  // 地面（视觉底，不参与物理）
  for (let gz = -8; gz <= 8; gz++) {
    for (let gx = -14; gx <= 14; gx++) {
      const r = scene.spawnAt(`ground_${gx}_${gz}`, gx * 2, gz * 2);
      if (!r.ok) continue;
      const s = makeSprite("ground", 2.05, 2.05);
      s.pivotY = 0.5;
      s.r = 0.62 + rnd.range(0, 0.06);
      s.g = 0.72 + rnd.range(0, 0.06);
      s.b = 0.66;
      s.order = -100;
      scene.attach(r.value.id, () => s);
    }
  }

  const obstacleIds: number[] = [];
  for (let i = 0; i < 70; i++) {
    const isTree = i % 3 !== 0;
    const x = rnd.range(-26, 26);
    const z = rnd.range(-16, 16);
    const r = scene.spawnAt(isTree ? `tree${i}` : `rock${i}`, x, z);
    if (!r.ok) continue;
    const node = r.value;
    const s = makeSprite(isTree ? "tree" : "rock", isTree ? 2 : 1.6, isTree ? 3 : 1.4);
    s.pivotY = 0; // 底边贴地（脚踩地面）
    scene.attach(node.id, () => s);
    if (isTree) scene.attach(node.id, () => new Workable());
    obstacleIds.push(node.id);
    physics.add({ nodeId: node.id, radius: isTree ? 0.55 : 0.7, isStatic: true });
  }

  for (let i = 0; i < 14; i++) {
    const r = scene.spawnAt(`berry${i}`, rnd.range(-24, 24), rnd.range(-14, 14));
    if (!r.ok) continue;
    const s = makeSprite("berry", 0.8, 0.8);
    s.pivotY = 0;
    scene.attach(r.value.id, () => s);
  }

  const hero = scene.spawnAt("hero", 0, 0);
  if (!hero.ok) throw new Error(hero.error.message);
  heroId = hero.value.id;
  const heroSprite = makeSprite("player", 1.1, 1.7);
  heroSprite.pivotY = 0;
  scene.attach(heroId, () => heroSprite);
  scene.attach(heroId, () => new PlayerController());
  // 挂脚本组件（ScriptModule 只驱动挂了 `game.script` 的节点）
  scene.attach(heroId, () => {
    const c = new ScriptComponent();
    c.module = "demo";
    c.entry = "onUpdate";
    return c;
  });
  physics.add({ nodeId: heroId, radius: 0.45, isStatic: false });
  scene.flush();

  // ---- 存档（localStorage）
  const SAVE_KEY = "engine08.save.v1";
  let toastTimer = 0;
  function toast(msg: string): void {
    toastEl!.textContent = msg;
    toastEl!.style.opacity = "1";
    if (toastTimer !== 0) clearTimeout(toastTimer);
    toastTimer = window.setTimeout(() => {
      toastEl!.style.opacity = "0";
    }, 2000);
  }

  function doSave(): void {
    const json = sceneToJson(saveScene(scene));
    localStorage.setItem(SAVE_KEY, json);
    toast(`已存档：${json.length} 字节 · hash ${stableHash(json)}`);
  }

  function doLoad(): void {
    const json = localStorage.getItem(SAVE_KEY);
    if (json === null) {
      toast("还没有存档（先按 F5）");
      return;
    }
    const snap = sceneFromJson(json);
    if (!snap.ok) {
      toast("存档损坏：" + snap.error.message);
      return;
    }
    const r = loadScene(scene, snap.value, reg);
    if (!r.ok) {
      toast("读档失败：" + r.error.message);
      return;
    }
    // 物理登记表重建（节点 id 不变，但 body 已被 clear）
    physics.clear();
    for (const id of obstacleIds) {
      if (scene.find(id) !== undefined) physics.add({ nodeId: id, radius: 0.6, isStatic: true });
    }
    if (scene.find(heroId) !== undefined) physics.add({ nodeId: heroId, radius: 0.45, isStatic: false });
    const extra = r.value.skipped.length > 0 ? `，跳过 ${r.value.skipped.length} 项` : "";
    toast(`已读档：${r.value.made} 个节点${extra}`);
  }

  function chopNearest(): void {
    const heroNode = scene.find(heroId);
    if (heroNode === undefined) return;
    const hp = heroNode.worldPosition;
    for (const id of physics.query(hp.x, hp.y, 2.4)) {
      if (id === heroId) continue;
      const w = scene.find(id)?.get<Workable>("game.workable");
      if (w === undefined) continue;
      w.workleft -= 1;
      if (w.workleft <= 0) {
        scene.destroy(id);
        physics.remove(id);
        toast("砍倒了一棵树");
      } else {
        toast(`砍了一下，还剩 ${w.workleft}`);
      }
      return;
    }
    toast("附近没有可砍的东西");
  }

  // ---- HUD（每帧一次；字段都是"可解释的事实"，不是装饰）
  let fps = 0;
  let frames = 0;
  let lastFpsAt = performance.now();
  app.services.require(Services.Frame).onRender((info) => {
    frames++;
    const now = performance.now();
    if (now - lastFpsAt > 500) {
      fps = frames / ((now - lastFpsAt) / 1000);
      frames = 0;
      lastFpsAt = now;
    }
    const lf = renderMod.lastFrame;
    const st = app.snapshot();
    const sc = scriptMod.runtime?.stats();
    const scriptTxt =
      sc === undefined ? "script off" : `script ${sc.calls}call/${sc.errors}err${sc.timeouts > 0 ? `/${sc.timeouts}to` : ""}`;
    hud!.textContent =
      `fps ${fps.toFixed(0)} · tick ${hudTick} · quad ${lf.quads} · draw ${lf.drawCalls} · ` +
      `culled ${lf.culled} · nodes ${st.scene.nodes} · bodies ${physics.stats().bodies} · ` +
      `atlas:${atlasLabel} · ` +
      `${st.backends.gfx}/${st.backends.audio}/${st.backends.input}/${st.backends.script ?? "-"} · ` +
      `${scriptTxt} · dropped ${st.droppedSteps}`;
    void info;
  });

  // ---- 输入
  window.addEventListener("keydown", (ev) => {
    if (ev.code === "F5") {
      ev.preventDefault();
      doSave();
    } else if (ev.code === "F9") {
      ev.preventDefault();
      doLoad();
    } else if (ev.code === "KeyR") {
      location.reload();
    } else if (ev.code === "KeyH") {
      chopNearest();
    }
  });

  // 首次真实手势时解锁音频（浏览器要求）
  window.addEventListener(
    "pointerdown",
    () => {
      void app.platform.audio.resume();
    },
    { once: true },
  );

  const runR = app.run();
  if (!runR.ok) {
    app.log.channel("host").error(`帧循环启动失败：${runR.error.message}`);
    toast("帧循环启动失败：" + runR.error.message);
  } else {
    toast("WASD 移动 · H 砍树 · F5 存档 · F9 读档 · R 重载");
  }

  // 供浏览器端到端判据读取（自动化时用；不影响正常游玩）
  (globalThis as { __engine?: unknown }).__engine = {
    app,
    renderMod,
    physics,
    scene,
    scriptMod,
    save: doSave,
    load: doLoad,
    heroId,
    /** 图集真实来源：`assets×5` 表示走完了导入链；`procedural` 表示降级了。 */
    atlasSource: atlasLabel,
    snapshot: () => app.snapshot(),
    lastFrame: () => renderMod.lastFrame,
  };
}

void main();
