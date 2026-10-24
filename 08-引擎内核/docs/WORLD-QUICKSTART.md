# 世界子系统 · 从零跑到"看得见"

这份文档回答一个具体问题：**手上有这套引擎，怎么在十分钟内让一个世界跑起来并且有画面。**
它只写已验证过的路径 —— 下面每一段都能在 `tests/extensions/world-e2e.test.ts` 或
`tests/extensions/world-soak.test.ts` 里找到对应的可运行代码。

> 状态说明：这条链在 **Node 侧**已验证（生成 → 装配 → 任务表 → 可见化 → 出生 → 存档往返 →
> 采集闭环），**浏览器 demo 也已经接上**（2026-10-23 批46）：`npm run build:web && npm run serve:web`
> 打开就是这个世界，HUD 上有"世界 N 块 / 资源 活·刷·采"，按 **G** 采集。
> 已知缺陷：只有**高度 96 px 的图集帧**能画出来（`terrain` / `tree` / `photo`），
> ~~矮帧（`player` / `berry` / `rock`）在浏览器里不可见~~ —— **已修（T330）**：
> 根因是 `batch2d` 里的 UV 多翻了一次（`texImage2D` 收 `ArrayBufferView` 时，
> 数据第一行就落在 `v=0`）。症状按帧高分布：帧高 ≤ 图集高一半的整帧消失。
> 现在 8 帧全部可见，判据钉在「顶点覆盖的贴图行 == 帧占的行」上
> （`tests/core/render.test.ts`，M169 原样回放这个错误）。

---

## 1. 生成一份世界计划

```ts
import { generateWorld } from "./extensions/worldgen/worldgen.ts";

const g = generateWorld({ seed: 7, width: 32, height: 24, maxSitesPerCell: 0 });
if (!g.ok) throw new Error(`生成失败：${g.error.code} ${g.error.message}`);
const plan = g.value; // 纯数据：kinds / heights / sites / spawn …
```

`plan` 是**纯数据**（可 JSON 化、可进内容指纹），不含任何引擎对象 ——
所以它能进存档、能在编辑器里画、能跨机器比对。

参数上最容易踩的一处：`maxSitesPerCell = 2` 会让计划几乎铺满每一格可通行格
（seed 7 / 32×24 有 882 个投放点），于是**再生资源一个都刷不出来**（去重生效，不是 bug）。

## 2. 装配成真实场景

```ts
import { Scene } from "./core/scene/scene.ts";
import { ComponentRegistry } from "./core/scene/component.ts";
import { assembleWorld, registerWorldComponents } from "./extensions/worldgen/assemble.ts";

const reg = new ComponentRegistry();
registerWorldComponents(reg);          // world.terrain / world.site
const scene = new Scene("world", reg);
const a = assembleWorld(plan, scene);  // 失败时**不留半个世界**
if (!a.ok) throw new Error(a.error.code);
```

装配同时建了**反查**：哪一格属于哪块地形、有没有漏格或重叠。校验器能报红并给出位置，
所以"地图有一块空洞"这类错误不会等到画面上才发现。

## 3. 让资源自己长出来

```ts
import { WORLD_TASK_SCHEMA } from "./extensions/worldgen/tasks.ts";
import {
  createWorldTaskModule, registerResourceComponent,
} from "./extensions/worldgen/task-module.ts";

registerResourceComponent(reg);        // world.resource（与 registerWorldComponents 一起注册）

const mod = createWorldTaskModule({
  tasks: {
    schema: WORLD_TASK_SCHEMA,
    tasks: [{ id: "regen", periodTicks: 10, phase: 0, picksPerRun: 3, biomes: ["grass"] }],
  },
  plan,
  scene,
  maxResources: 64,                    // 上限按**活着**的资源算
});
mod.init(ctx);   // ctx 需要 services / log / events / random；或先注册 Services.Scene
mod.start?.();
mod.update(10, 1 / 30);                // 按 tick 走，dt 不参与决定
```

★★ 两个语义必须分清：**逐 tick 推进 ≠ 跳时间**。
调度器每秒回调 30 次是真的模拟了 30 步；一次 `update(1000, ·)` 是跳到 tick 1000，
漏掉的批次由 `missed` 报出。把这两条混为一谈，就会误判成"离线 8 小时回来地图被刷满"。

## 4. 让它画出来

```ts
import { attachWorldVisuals } from "./extensions/render/world-visuals.ts";
import { buildProceduralAtlas } from "./extensions/render/atlas.ts";

const atlas = buildProceduralAtlas();
const frames = [...atlas.frames.keys()];          // 换真资产时把这里的名字换掉即可
const v = attachWorldVisuals(scene, frames);      // 缺帧 ⇒ 报错，且不动场景
if (!v.ok) throw new Error(v.error.code);
```

三件事由这一个调用负责：地形块（矩形，`pivotX = 0`）、投放点、再生资源。
缺帧是**错误**不是警告 —— 渲染模块自己会 `warn` + 跳过（那是它对坏资产的正确态度），
于是一类东西静默消失而退出码是 0。所以桥的这一层把它升级成错误。

## 5. 放一个玩家，并且让他能"采"

```ts
import { spawnPlayer } from "./extensions/worldgen/spawn.ts";
import { harvestAt } from "./extensions/worldgen/harvest.ts";

spawnPlayer(scene, plan);              // 位置 = 格子中心（定点恒等式）；重复出生会报错

const h = harvestAt(scene, cell, { onRelease: (c) => mod.releaseCell(c) });
if (!h.ok) console.log(h.error.code);  // HARVEST.NOTHING / HARVEST.BAD_CELL
```

★★ `onRelease` 这一句**不能省**。采集改的是两块状态：场景里的节点要被销毁，
去重索引里的名额要被还回去。少做第二件，现场表现是"这片林子砍空了就再也不长了"，
而画面上完全看不出是索引的问题。

## 6. 浏览器 demo 是怎么接的（已完成，可当参考）

`src/browser-entry.ts` 里的顺序是硬约束，不是风格：

1. **boot 之前**生成计划（`generateWorld` 是纯数据，不需要 Scene）；
2. `bootGameApp` 的模块列表里放一个 `world.worldgen`：它的 `init` 负责
   `registerWorldComponents` / `registerResourceComponent` / `registerPlayerComponent`
   → `assembleWorld`（**要求空场景**）→ `attachWorldVisuals`（缺帧是错误）→ `spawnPlayer`；
3. 任务模块**包一层**再进模块表，把 `deps` 指到 `world.worldgen` —— 否则两个"无依赖"
   模块谁先 init 就成了注册顺序的隐式约定，而组件是 worldgen 注册的；
4. 主循环里把 `mod.update(tick, dt)` 挂到 `FixedStepScheduler.onStep`
   （模块不会被框架自动 update，脚本模块也是宿主手动调）；
5. 宿主自己的摆件放在**最后** —— 它们只是"世界里的装饰"。

自检页现在有 18 条，其中 4 条专门验这条链（世界装配完成 / 地形块数合理 /
地形与资源都挂了精灵 / 玩家是落地的那一个 / 采集两块状态一起变）。
另外 `node tools/browser-shot.mjs` 会拍一张图 —— 有些错误只有眼睛能发现。

---

## 常见现象与原因

| 现象 | 原因 |
|---|---|
| 地表是空白，树和石头浮在空中 | 只调了 `attachWorldVisuals` 之前的一半，或图集里没有 `terrain` 帧 |
| 相邻地形块之间"裂开" | 地形 `pivotX` 被写成 0.5（矩形应该用 0） |
| 相邻地形块之间"错色"（海发绿） | 地形基色用了草绿而不是中性灰 —— 灰度帧是**乘子**，不是颜色 |
| 砍完的树还在画面上 | `harvestAt` 之后没 `flush`，或根本没销毁节点 |
| 砍空的林子再也不长 | `onRelease` 没接上（名额没释放） |
| 越玩越荒 | 上限按累计 `spawned` 算而不是按 `alive` |
| 读档后资源叠了两层 | 索引在资源已存在之前就建了（`ensureIndex` 必须在首次使用时扫全场景） |
