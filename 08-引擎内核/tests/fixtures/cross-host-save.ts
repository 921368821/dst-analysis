/**
 * 跨宿主存档的**同一份语料**（Node 与浏览器各跑一遍，字节必须完全相同）。
 *
 * ★ 这个文件补的是哪一块：
 *   `tests/backends/save-cross-host.test.ts` 证的是"同一份存档过三个**后端**之后字节不变"，
 *   但三个后端都在**同一个进程**里 —— 它证明不了"浏览器里存的档，桌面端打得开"。
 *   而后者是玩家真会做的事，也是我们自己调试时最常做的事（`localStorage` 里那份存档
 *   要能拿到 Node 里复现 bug）。
 *
 * ★ 为什么语料要放在**一个文件**里给两个宿主用：
 *   两边各写一份"造世界"的代码，比的就不是"宿主",而是"两份代码"——
 *   差异永远出在语料里，永远不会出在引擎里，判据于是永远绿得没意义。
 *   一个文件、两个宿主，**唯一变量就是宿主**。
 *
 * ★ 语料里刻意放了四类"容易随宿主漂"的东西：
 *   ① 中文名（UTF-8 编码路径）；
 *   ② 浮点（`Schema` 的量化路径 —— 不同引擎的 `Number#toString` 实现细节不同）；
 *   ③ 大量节点（几百个，覆盖排序 / 遍历序 —— `Map` 插入序在两边都一致才有意义）；
 *   ④ 会变的世界状态（采集 / 再生 / 背包溢出成两堆）：不只有静态装配结果。
 *
 * ★ 不允许出现的东西：`Math.random`、`Date.now`、`performance.now`、`toLocaleString`。
 *   它们一旦出现，"两边字节相同"就变成了运气。`bornTick` 一律来自 `mod.update` 的
 *   显式 tick 计数，不来自时钟。
 */

import { ComponentRegistry } from "../../src/core/scene/component.ts";
import { Scene } from "../../src/core/scene/scene.ts";
import { saveScene, sceneToJson } from "../../src/core/scene/scene-io.ts";
import type { ModuleContext } from "../../src/core/module/module.ts";
import { ServiceRegistry } from "../../src/core/module/services.ts";
import { EventBus } from "../../src/foundation/event/event-bus.ts";
import { Logger } from "../../src/foundation/log/logger.ts";
import { XorShift128 } from "../../src/foundation/random.ts";
import type { IPlatform } from "../../src/platform/platform.ts";
import { generateWorld } from "../../src/extensions/worldgen/worldgen.ts";
import { SITE_TYPE, type SiteMarker, assembleWorld, registerWorldComponents } from "../../src/extensions/worldgen/assemble.ts";
import { WORLD_TASK_SCHEMA } from "../../src/extensions/worldgen/tasks.ts";
import { RESOURCE_TYPE, createWorldTaskModule, registerResourceComponent } from "../../src/extensions/worldgen/task-module.ts";
import { registerPlayerComponent, spawnPlayer } from "../../src/extensions/worldgen/spawn.ts";
import { harvestAt } from "../../src/extensions/worldgen/harvest.ts";
import { addItem, makeInventory, registerInventoryComponents, stacksOf } from "../../src/extensions/inventory/inventory.ts";
import { Sprite } from "../../src/extensions/render/sprite.ts";
import { buildProceduralAtlas } from "../../src/extensions/render/atlas.ts";
import { attachWorldVisuals } from "../../src/extensions/render/world-visuals.ts";

/** 语料种子。**改这个数字等于换一份语料** —— 两边必须同时改（它们本来就是同一份代码）。 */
export const CROSS_HOST_SEED = 20261024;

const FD = 1 / 30;

export interface CrossHostSave {
  /** 存档文本（UTF-8 字节就是比对对象）。 */
  readonly json: string;
  /** 节点数（防"两边都空"的假绿）。 */
  readonly nodes: number;
  /** 资源节点数（再生出来的那些）。 */
  readonly resources: number;
  /** 背包堆数（应当 ≥ 3：芦苇 1 堆 + 树枝 2 堆）。 */
  readonly stacks: number;
  /** 采集释放的格子数。 */
  readonly released: number;
}

function makeRegistry(): ComponentRegistry {
  const reg = new ComponentRegistry();
  registerWorldComponents(reg);
  registerResourceComponent(reg);
  registerPlayerComponent(reg);
  // ★ 背包组件也要注册：否则 `game.inventory` / `game.item` 在存档里**静默丢失**，
  //   而"跨宿主比对"会拿两份都没有背包的存档比 —— 绿，但少了要验的东西。
  registerInventoryComponents(reg);
  reg.register(new Sprite().schema, () => new Sprite());
  return reg;
}

function makeCtx(): ModuleContext {
  return {
    log: new Logger(() => 0),
    events: new EventBus<Record<string, unknown>>(),
    services: new ServiceRegistry(),
    platform: {} as IPlatform,
    random: new XorShift128(CROSS_HOST_SEED),
    module: () => undefined,
  };
}

/**
 * 造出"这一局"并存档。**纯函数式**：同输入必得同输出，与宿主无关。
 *
 * @throws 任何一步失败 —— 语料造不出来是**测试设施坏了**，不是"业务失败"，
 *         静默返回空存档会让跨宿主比对变成"两份空文件相同"的假绿。
 */
export function buildCrossHostSave(): CrossHostSave {
  const scene = new Scene("跨宿主存档", makeRegistry());

  const g = generateWorld({ seed: CROSS_HOST_SEED, width: 28, height: 20, maxSitesPerCell: 1 });
  if (!g.ok) throw new Error(`生成失败：${g.error.code} ${g.error.message}`);

  const a = assembleWorld(g.value, scene);
  if (!a.ok) throw new Error(`装配失败：${a.error.code} ${a.error.message}`);

  const mod = createWorldTaskModule({
    tasks: {
      schema: WORLD_TASK_SCHEMA,
      // 再生参数是**手调过的**：`maxSitesPerCell: 1` 时地图已铺满，再生会被"这格已经有了"全部跳过
      // （首次跑出来 `spawned: 0`），所以先采掉一片、再让它填回来 —— 见下面 harvest 那一段。
      tasks: [{ id: "regen", periodTicks: 5, phase: 3, picksPerRun: 20, biomes: ["grass", "forest"] }],
    },
    plan: g.value,
    scene,
  });
  // ★ `init` 的返回类型是 `void | Result | Promise<...>`（模块可以异步起）。
  //   语料要求**同步**：异步起来的话"跑了几 tick"就取决于微任务时序，两边不一定一致。
  const init: unknown = mod.init(makeCtx());
  if (init instanceof Promise) throw new Error("任务模块 init 返回了 Promise —— 跨宿主语料只接受同步初始化");
  if (init !== undefined && init !== null) {
    const ir = init as { ok: boolean; error?: { code: string; message: string } };
    if (!ir.ok) throw new Error(`任务模块 init 失败：${ir.error?.code ?? "?"} ${ir.error?.message ?? ""}`);
  }
  mod.start?.();

  const vis = attachWorldVisuals(scene, [...buildProceduralAtlas().frames.keys()]);
  if (!vis.ok) throw new Error(`可见化失败：${vis.error.code} ${vis.error.message}`);

  const spawn = spawnPlayer(scene, g.value);
  if (!spawn.ok) throw new Error(`出生失败：${spawn.error.code} ${spawn.error.message}`);
  const heroId = spawn.value.nodeId;

  // ---- 让世界"动过"，而且是**两种来源都动**：
  //   ① 采掉一片**计划投放点**（`SiteMarker`）：格子顺序按 cell 升序取前 40 个，
  //      不依赖 `componentsOf` 的遍历序（那取决于节点插入序，虽然两边一致，但没必要赌）；
  //   ② 再把 tick 推到 25，让再生模块把其中几格**填成 `ResourceMarker`** ——
  //      这一步同时验了"计划的资源"与"后长出来的资源"两种组件都能进存档。
  const siteCells = [...scene.componentsOf<SiteMarker>(SITE_TYPE)]
    .map((s) => s.cell)
    .sort((x, y) => x - y);
  if (siteCells.length < 40) throw new Error(`投放点太少（${String(siteCells.length)} 个），语料不达标`);
  let released = 0;
  for (const cell of siteCells.slice(0, 40)) {
    const h = harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) });
    if (!h.ok) throw new Error(`采集第 ${String(cell)} 格失败：${h.error.code} ${h.error.message}`);
    released++;
  }
  // ★ tick 必须**显式递增**（5,10,15,20,25），不能靠 dt 累加：累加会引入浮点累加次序，
  //   而这正是跨宿主最容易漂的地方 —— 判据不该在"怎么算 tick"上翻船。
  for (let t = 5; t <= 25; t += 5) mod.update(t, FD);

  // ---- 背包：3 芦苇（1 堆）+ 45 树枝（40 + 5，两堆）——溢出成新堆这条路径也进存档
  const inv = makeInventory(scene, heroId);
  if (!inv.ok) throw new Error(`挂背包失败：${inv.error.code} ${inv.error.message}`);
  for (const [kind, n] of [["reed", 3], ["twig", 45]] as const) {
    const r = addItem(scene, heroId, kind, n);
    if (!r.ok) throw new Error(`装 ${kind}×${String(n)} 失败：${r.error.code} ${r.error.message}`);
  }

  const snap = saveScene(scene);
  const json = sceneToJson(snap);
  return {
    json,
    nodes: snap.nodes.length,
    resources: scene.countOf(RESOURCE_TYPE),
    stacks: stacksOf(scene, heroId).length,
    released,
  };
}

/**
 * 字节落地的**唯一**口径：UTF-8 编码。
 *
 * ★ 为什么不比字符串：V8 的字符串比较是"码元相等"，它会**盖住**编码层的差异
 *   （比如某个宿主把字符串按 UTF-16 落盘、或 BOM 写在了前面）。
 *   存档的承诺是"逐字节相同"，那就必须在字节层比。
 */
export function crossHostBytes(json: string): Uint8Array {
  return new TextEncoder().encode(json);
}

/** 手写 base64（不依赖 `Buffer`，浏览器与 Node 都能跑 —— 同一份实现两个宿主各一份就白比了）。 */
export function bytesToBase64(bytes: Uint8Array): string {
  const TABLE = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  let out = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i]!;
    const b1 = i + 1 < bytes.length ? bytes[i + 1]! : 0;
    const b2 = i + 2 < bytes.length ? bytes[i + 2]! : 0;
    out += TABLE[b0 >> 2]!;
    out += TABLE[((b0 & 3) << 4) | (b1 >> 4)]!;
    out += i + 1 < bytes.length ? TABLE[((b1 & 15) << 2) | (b2 >> 6)]! : "=";
    out += i + 2 < bytes.length ? TABLE[b2 & 63]! : "=";
  }
  return out;
}
