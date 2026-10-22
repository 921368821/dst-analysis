/**
 * 最小可运行宿主（headless）
 *
 * 这个文件的价值不是"演示 API"，而是**证明整条链真的接得上**：
 *   注册后端 → 建平台 → 装配模块 → 场景/组件 → 固定步进 → 诊断快照
 *
 * 它也是"编辑器宿主"/"服务端宿主"的模板：换掉注册的后端与模块列表，
 * 内核一行都不用改 —— 这正是分层的目的。
 *
 * 运行：npm run sample:headless
 */

import { BackendRegistry } from "../src/platform/registry.ts";
import { registerNullBackends } from "../src/backends/index.ts";
import { createLuaScriptBackend } from "../src/backends/script-lua/runtime.ts";
import { bootGameApp } from "../src/runtime/GameApp.ts";
import { createScriptModule } from "../src/extensions/script/script-module.ts";
import { ScriptComponent } from "../src/extensions/script/script-component.ts";
import {
  Component,
  ComponentRegistry,
  FieldType,
  type ComponentSchema,
} from "../src/core/scene/component.ts";
import type { IModule, ModuleContext } from "../src/core/module/module.ts";
import { Services } from "../src/core/tokens.ts";
import { ManualTickSource } from "../src/runtime/tick-source.ts";
import { ManualClock } from "../src/foundation/time/clock.ts";
import { LogLevel } from "../src/foundation/log/logger.ts";
import type { FixedStepScheduler } from "../src/core/scheduler/scheduler.ts";

// ---------------------------------------------------------------- 组件

/** 会腐烂的：每步减少 ttl，到 0 发事件（不直接删自己 —— 删是结构性修改，走命令）。 */
class Perishable extends Component {
  ttl = 5;
  readonly schema: ComponentSchema = {
    type: "demo.perishable",
    fields: { ttl: FieldType.Float },
  };
  override onUpdate(_tick: number, dt: number): void {
    if (this.ttl > 0) this.ttl = Math.max(0, this.ttl - dt);
  }
}

/** 沿 X 轴匀速走，到边界折返。 */
class Walker extends Component {
  speed = 2;
  dir = 1;
  distance = 0;
  readonly schema: ComponentSchema = {
    type: "demo.walker",
    fields: { speed: FieldType.Float, dir: FieldType.Int, distance: FieldType.Float },
  };
  override onUpdate(_tick: number, dt: number): void {
    const n = this.node;
    if (n === null) return;
    const step = this.speed * dt * this.dir;
    n.setLocalPosition(n.localPosition.x + step, n.localPosition.y);
    this.distance += Math.abs(step);
    if (n.localPosition.x > 10 && this.dir > 0) this.dir = -1;
    if (n.localPosition.x < -10 && this.dir < 0) this.dir = 1;
  }
}

// ---------------------------------------------------------------- 模块

/**
 * 世界步进模块。
 * ★ 它是"内核不含玩法"的证据：把 scheduler.onStep 接到 scene.step 这件事，
 *   是一个**模块**做的，不是 GameApp 做的。所以将来想做"多世界并行"或
 *   "回放时换一个步进器"，改的是模块，不是内核。
 */
function worldModule(onStep?: (tick: number, dt: number) => void): IModule {
  let off: (() => void) | null = null;
  let steps = 0;

  return {
    id: "game.world",
    deps: [],
    init(ctx: ModuleContext) {
      const scene = ctx.services.require(Services.Scene);
      const sched = ctx.services.require<FixedStepScheduler>(Services.Scheduler);

      off = sched.onStep((tick, dt) => {
        scene.step(tick, dt);
        // 脚本在世界步进之后跑（见 browser-entry 的同一条注释）
        onStep?.(tick, dt);
        steps++;
      });

      // 订阅结构性事件：这里只是记日志。真实项目里"掉落表/成就/音效"都挂这里。
      ctx.events.on("scene:node-destroyed", (p) => {
        ctx.log.channel("game").debug(`节点销毁 #${(p as { nodeId: number }).nodeId}`);
      });
      return;
    },
    stop() {
      off?.();
      off = null;
    },
    describe() {
      return `world：已步进 ${steps} 步`;
    },
  };
}

// ---------------------------------------------------------------- 脚本

/**
 * 脚本层的示例：让一个节点绕圆心走。
 * ★ 它故意**不**直接用 `setLocalPosition` 的 JS 版本 —— 同一件事走一遍 Lua，
 *   证明"脚本能改世界"，而不是"脚本能被调用"。
 */
const SAMPLE_LUA = `
local t = 0
function onUpdate(selfId, dt, tick)
  t = t + dt
  engine_set_pos(selfId, math.cos(t * 1.5) * 4, math.sin(t * 1.5) * 4)
  if tick > 0 and tick % 90 == 0 then
    engine_log("sample: tick " .. tostring(tick) .. " pos=" ..
      string.format("%.2f,%.2f", math.cos(t * 1.5) * 4, math.sin(t * 1.5) * 4))
  end
end
`;

// ---------------------------------------------------------------- main

async function main(): Promise<void> {
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  // 真 Lua 后端（Node 下 wasmoon 自己定位包内 glue.wasm，不需要给 wasmPath）
  registry.registerScript(createLuaScriptBackend(), 100);

  const clock = new ManualClock();
  const tick = new ManualTickSource();

  const scriptMod = createScriptModule({ callTimeoutMs: 20 });

  const appR = await bootGameApp({
    platformId: "headless",
    interactive: false,
    registry,
    modules: [worldModule((t, dt) => void scriptMod.update(t, dt)), scriptMod],
    seed: 20261022,
    fixedDt: 1 / 30,
    clock,
    tickSource: tick,
    logLevel: LogLevel.Info,
  });

  if (!appR.ok) {
    console.error("启动失败：", appR.error.code, appR.error.message);
    if (appR.error.detail) console.error("细节：", JSON.stringify(appR.error.detail, null, 2));
    process.exitCode = 1;
    return;
  }
  const app = appR.value;

  // 注册组件类型（新增组件 = 一次 register，不改内核）
  const reg: ComponentRegistry = app.components;
  reg.register({ type: "demo.perishable", fields: { ttl: FieldType.Float } }, () => new Perishable());
  reg.register(
    { type: "demo.walker", fields: { speed: FieldType.Float, dir: FieldType.Int, distance: FieldType.Float } },
    () => new Walker(),
  );

  // 摆一个世界：3 棵树 + 1 个走动的角色
  // ★ 记住 id 而不是事后猜："root 的 id 是 1"这种假设会在任何改动后失效，
  //   而猜错的症状是拿到 undefined 却看起来"跑成功了"（第一版就这么写的）。
  const treeIds: number[] = [];
  for (let i = 0; i < 3; i++) {
    const r = app.scene.spawnAt(`tree${i}`, i * 3 - 3, 0);
    if (!r.ok) throw new Error(r.error.message);
    treeIds.push(r.value.id);
    app.scene.attach(r.value.id, () => new Perishable());
  }
  const hero = app.scene.spawnAt("hero", 0, 2);
  if (!hero.ok) throw new Error(hero.error.message);
  app.scene.attach(hero.value.id, () => new Walker());

  // 脚本驱动的节点（位置由 Lua 决定）
  const scriptedNode = app.scene.spawnAt("scripted", 4, 0);
  if (!scriptedNode.ok) throw new Error(scriptedNode.error.message);
  app.scene.attach(scriptedNode.value.id, () => {
    const c = new ScriptComponent();
    c.module = "sample";
    c.entry = "onUpdate";
    return c;
  });
  app.scene.flush();

  // 加载脚本模块（必须在 boot 之后：ScriptModule.init 里已 await runtime.ready()）
  const rt = scriptMod.runtime;
  if (rt === null) throw new Error("脚本运行时没起来：headless 应该能用 Lua 后端");
  {
    const lr = await rt.loadModule("sample", SAMPLE_LUA);
    if (!lr.ok) throw new Error(`脚本加载失败：${lr.error.code} ${lr.error.message}`);
  }

  console.log("初始：", JSON.stringify(app.scene.stats()));

  // 跑 300 帧（每帧 1/60 秒真实时间 ⇒ 5 秒游戏时间）
  tick.start((dt) => {
    clock.advance(dt * 1000);
    app.frame(dt);
  });
  for (let i = 0; i < 300; i++) {
    tick.pump(1 / 60);
    // ★ 每帧排空脚本队列：同步 for 循环不会让出事件循环，脚本的异步调用
    //   会一直堆在队列里，到上限后开始丢 tick。这不是脚本慢，是宿主没让出。
    await scriptMod.drain();
  }

  const snap = app.snapshot();
  console.log("5 秒后：", {
    tick: snap.tick,
    time: Number(snap.time.toFixed(3)),
    nodes: snap.scene.nodes,
    components: snap.scene.components,
    componentUpdates: snap.scene.componentUpdates,
    droppedSteps: snap.droppedSteps,
    backends: snap.backends,
  });

  const heroNode = app.scene.find(hero.value.id);
  const hp = heroNode?.worldPosition;
  console.log("hero 位置：", hp === undefined ? "(丢失)" : `(${hp.x.toFixed(2)}, ${hp.y.toFixed(2)})`);
  const ttl = app.scene.find(treeIds[0] ?? -1)?.get<Perishable>("demo.perishable")?.ttl;
  console.log("树 0 的 ttl：", ttl?.toFixed(3), "（5 秒后应为 0：已经烂完）");

  // 脚本驱动的结果：位置必须由 Lua 算出来（半径 4 的圆上）
  const sp = app.scene.find(scriptedNode.value.id)?.worldPosition;
  const radius = sp === undefined ? -1 : Math.hypot(sp.x, sp.y);
  console.log("脚本节点位置：", sp === undefined ? "(丢失)" : `(${sp.x.toFixed(3)}, ${sp.y.toFixed(3)})`,
    `半径=${radius.toFixed(3)}（Lua 里用的是 4）`);
  const ss = rt.stats();
  console.log("脚本：", {
    backend: rt.id,
    modules: ss.modules,
    calls: ss.calls,
    errors: ss.errors,
    dropped: scriptMod.droppedUpdates,
  });

  // 暂停 2 秒，tick 必须不动
  const before = app.scheduler.tick;
  app.paused = true;
  for (let i = 0; i < 120; i++) tick.pump(1 / 60);
  const during = app.scheduler.tick;
  app.paused = false;
  console.log("暂停期间 tick 不变：", before === during, `(${before} → ${during})`);

  console.log("模块：", snap.modules.map((m) => `${m.id}=${m.state}`).join(", "));
  console.log("事件统计：", snap.eventStats);

  await app.dispose();
  console.log("已释放。");
}

void main();
