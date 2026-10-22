/**
 * 脚本层端到端（阶段 2 的出口判据）
 *
 * 守的四件事，每一件都是"脚本层看起来能跑、实际不可用"的失败模式：
 *  ① **确定性**：同脚本 + 同种子 + 同步数 ⇒ 存档**逐字节相同**。
 *     脚本层如果是"能调通"的水平，这一条几乎必红（浮点累加顺序、表遍历顺序、
 *     队列乱序都会破坏它），而它恰恰是存档/回放/联机的地基。
 *  ② **数值正确**：脚本算出的位置与 JS 独立计算的值一致（1e-9）。
 *     "脚本跑了"和"脚本算对了"是两件事。
 *  ③ **队列可观测**：同步 pump 不让出事件循环时，丢弃必须计数（`droppedUpdates`），
 *     不许静默 —— 静默丢帧的表现是"世界比脚本快半秒"，玩家只觉得"操作黏"。
 *  ④ **drain 语义**：每帧 drain 后，调用次数与 tick 数精确相等（没有跳、没有重复）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { BackendRegistry } from "../../src/platform/registry.ts";
import { registerNullBackends } from "../../src/backends/index.ts";
import { createLuaScriptBackend } from "../../src/backends/script-lua/runtime.ts";
import { bootGameApp, type GameApp } from "../../src/runtime/GameApp.ts";
import { createScriptModule, type ScriptModuleHandle } from "../../src/extensions/script/script-module.ts";
import { ScriptComponent } from "../../src/extensions/script/script-component.ts";
import { ManualClock } from "../../src/foundation/time/clock.ts";
import { LogLevel, MemorySink } from "../../src/foundation/log/logger.ts";
import { saveScene, sceneToJson, sceneFromJson } from "../../src/core/scene/scene-io.ts";
import type { IModule, ModuleContext } from "../../src/core/module/module.ts";
import { Services } from "../../src/core/tokens.ts";
import type { FixedStepScheduler } from "../../src/core/scheduler/scheduler.ts";

/** 半径 4 的圆，角度只由 dt 累加决定（不读时钟、不读随机）。 */
const LUA_CIRCLE = `
local t = 0
function onUpdate(selfId, dt, tick)
  t = t + dt
  engine_set_pos(selfId, math.cos(t * 1.5) * 4, math.sin(t * 1.5) * 4)
end
`;

const DT = 1 / 30;

function worldModule(onStep: (tick: number, dt: number) => void): IModule {
  let off: (() => void) | null = null;
  return {
    id: "test.world",
    init(ctx: ModuleContext): void {
      const scene = ctx.services.require(Services.Scene);
      const sched = ctx.services.require<FixedStepScheduler>(Services.Scheduler);
      off = sched.onStep((tick, dt) => {
        scene.step(tick, dt);
        onStep(tick, dt);
      });
    },
    stop(): void {
      off?.();
      off = null;
    },
  };
}

interface Rig {
  readonly app: GameApp;
  readonly scriptMod: ScriptModuleHandle;
  readonly nodeId: number;
  readonly sink: MemorySink;
  /** 跑 n 帧；`drainEach` 为真时每帧排空脚本队列（真实宿主的做法）。 */
  run(n: number, drainEach: boolean): Promise<void>;
  saveJson(): string;
}

async function makeRig(): Promise<Rig> {
  const registry = new BackendRegistry();
  registerNullBackends(registry);
  // 真 Lua 后端优先（优先级 100 > null 的 0）
  registry.registerScript(createLuaScriptBackend(), 100);

  const sink = new MemorySink(2000);
  const scriptMod = createScriptModule({ callTimeoutMs: 200 });
  const appR = await bootGameApp({
    platformId: "headless",
    interactive: false,
    registry,
    modules: [worldModule((t, dt) => void scriptMod.update(t, dt)), scriptMod],
    seed: 7,
    fixedDt: DT,
    clock: new ManualClock(),
    logLevel: LogLevel.Warn,
    extraSinks: [sink],
  });
  if (!appR.ok) throw new Error(`启动失败：${appR.error.code} ${appR.error.message}`);
  const app = appR.value;

  const rt = scriptMod.runtime;
  if (rt === null) throw new Error("Lua 后端没起来");
  const lr = await rt.loadModule("circle", LUA_CIRCLE);
  if (!lr.ok) throw new Error(`脚本加载失败：${lr.error.code} ${lr.error.message}`);

  const n = app.scene.spawnAt("mover", 0, 0);
  if (!n.ok) throw new Error(n.error.message);
  app.scene.attach(n.value.id, () => {
    const c = new ScriptComponent();
    c.module = "circle";
    c.entry = "onUpdate";
    return c;
  });
  app.scene.flush();

  return {
    app,
    scriptMod,
    nodeId: n.value.id,
    sink,
    async run(frames: number, drainEach: boolean): Promise<void> {
      for (let i = 0; i < frames; i++) {
        app.frame(DT);
        if (drainEach) await scriptMod.drain();
      }
    },
    saveJson(): string {
      return sceneToJson(saveScene(app.scene));
    },
  };
}

test("确定性：同脚本同步数，两个独立实例的存档逐字节相同", async () => {
  const a = await makeRig();
  const b = await makeRig();
  await a.run(90, true);
  await b.run(90, true);

  const ja = a.saveJson();
  const jb = b.saveJson();
  assert.equal(ja.length, jb.length, "存档长度不同说明世界状态已经不同");
  assert.equal(ja, jb, "脚本层不可复现：同一脚本两个实例跑出了不同存档");

  // 顺便证明这份存档是**有内容**的（不是靠"两个都是空串"通过）
  // 存档不写 __root__，所以这里正好 1 个节点（mover）
  const back = sceneFromJson(ja);
  assert.ok(back.ok);
  assert.equal(back.value.nodes.length, 1);
  assert.equal(back.value.nodes[0]?.name, "mover");

  await a.app.dispose();
  await b.app.dispose();
});

test("数值正确：脚本算出的位置等于 JS 独立计算的值（1e-9）", async () => {
  const r = await makeRig();
  const frames = 45;
  await r.run(frames, true);

  // JS 侧独立算：t 累加 n 次 DT，位置 = (cos(t*1.5)*4, sin(t*1.5)*4)
  let t = 0;
  for (let i = 0; i < frames; i++) t += DT;
  const ex = Math.cos(t * 1.5) * 4;
  const ez = Math.sin(t * 1.5) * 4;

  const p = r.app.scene.find(r.nodeId)?.worldPosition;
  assert.ok(p !== undefined, "节点不该消失");
  assert.ok(Math.abs(p.x - ex) < 1e-9, `x 偏差 ${Math.abs(p.x - ex)}（Lua=${p.x} JS=${ex}）`);
  assert.ok(Math.abs(p.y - ez) < 1e-9, `z 偏差 ${Math.abs(p.y - ez)}（Lua=${p.y} JS=${ez}）`);
  // 半径也必须对（这条防"两个坐标都错了同样的量"同时通过上面的断言）
  assert.ok(Math.abs(Math.hypot(p.x, p.y) - 4) < 1e-9);

  await r.app.dispose();
});

test("队列可观测：同步 pump 不让出事件循环时，丢弃被计数（不静默）", async () => {
  const r = await makeRig();
  await r.run(40, false); // 不 drain：队列会打满
  assert.ok(
    r.scriptMod.droppedUpdates > 0,
    `40 帧不 drain 却没记录丢弃 —— 队列上限失效（静默丢帧）`,
  );
  // 丢弃必须留下日志（MemorySink 是宿主能看到的唯一证据）
  const warned = r.sink.records().filter((x) => x.message.includes("脚本落后于世界"));
  assert.ok(warned.length > 0, "丢弃必须记日志");
  await r.app.dispose();
});

test("drain 语义：每帧排空后调用次数与 tick 数精确相等（不跳不重）", async () => {
  const r = await makeRig();
  const frames = 60;
  await r.run(frames, true);

  const s = r.scriptMod.runtime?.stats();
  assert.ok(s !== undefined);
  assert.equal(r.scriptMod.droppedUpdates, 0, "每帧 drain 就不该丢");
  // 1 个组件 × 每 tick 一次
  assert.equal(s.calls, frames, `calls=${s.calls}，期望 ${frames}（每 tick 一次）`);
  assert.equal(s.errors, 0);
  assert.equal(r.app.scheduler.tick, frames);

  await r.app.dispose();
});
