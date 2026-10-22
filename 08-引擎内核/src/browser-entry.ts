/**
 * 浏览器宿主入口（L6）
 *
 * 这是"引擎真的能跑"的证据：注册真实后端 → 建世界 → 输入驱动 → 物理碰撞 → 渲染 → 存档。
 *
 * ★ 这个文件允许知道一切（具体后端、具体组件、具体玩法）—— 它是 **宿主**。
 *   内核不知道它的存在。所以这里出现 `webgl2Backend` / `domInputBackend` 是**正确**的；
 *   同样的 import 出现在 `core/**` 里就是架构崩了（arch 规则 4 会红）。
 *
 * 零外部资产：图集程序化生成（`atlas.ts`），所以打开 index.html 就能跑。
 *
 * ★ 装配顺序很重要（第一版写错过）：
 *   物理 → 渲染模块 → 世界模块 → bootGameApp(modules) → 摆世界 → run()
 *   模块的 init/start **必须交给 ModuleRegistry**，不能在 boot 之后手动调 ——
 *   手动调会绕过拓扑排序与失败回滚，而且很容易漏掉 stop/dispose。
 */

import { BackendRegistry } from "./platform/registry.ts";
import { registerNullBackends } from "./backends/index.ts";
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
import { saveScene, loadScene, sceneToJson, sceneFromJson } from "./core/scene/scene-io.ts";
import { stableHash } from "./core/serialization/schema.ts";

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
function createWorldModule(physics: SpatialHashWorld, hooks: { onTick: (t: number) => void }): IModule {
  let off: (() => void) | null = null;
  return {
    id: "game.world",
    init(ctx: ModuleContext): void {
      const scene = ctx.services.require(Services.Scene);
      const sched = ctx.services.require<FixedStepScheduler>(Services.Scheduler);
      off = sched.onStep((tick, dt) => {
        scene.step(tick, dt);
        physics.resolve();
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

  // ---- 渲染模块（follow 闭包读 heroId，世界建好后才有效）
  const renderMod = createRenderModule({
    viewportWidth: canvas.width,
    viewportHeight: canvas.height,
    zoom: 26 * dpr,
    tiltY: 0.62,
    follow: () => {
      if (heroId < 0) return undefined;
      const n = appRef?.scene.find(heroId);
      if (n === undefined) return undefined;
      // 2.5D：世界的 z 就是 Node 的 y（Node 只有二维局部坐标）
      const p = n.worldPosition;
      return { x: p.x, z: p.y };
    },
  });

  const worldMod = createWorldModule(physics, { onTick: (t) => (hudTick = t) });

  const appR = await bootGameApp({
    platformId: "web",
    interactive: true,
    registry,
    modules: [worldMod, renderMod],
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
    hud!.textContent =
      `fps ${fps.toFixed(0)} · tick ${hudTick} · quad ${lf.quads} · draw ${lf.drawCalls} · ` +
      `culled ${lf.culled} · nodes ${st.scene.nodes} · bodies ${physics.stats().bodies} · ` +
      `${st.backends.gfx}/${st.backends.audio}/${st.backends.input} · dropped ${st.droppedSteps}`;
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
    save: doSave,
    load: doLoad,
    heroId,
    snapshot: () => app.snapshot(),
    lastFrame: () => renderMod.lastFrame,
  };
}

void main();
