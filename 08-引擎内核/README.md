# 08 · 引擎内核

分层、接口优先的 **2.5D 游戏引擎内核**，目标是《饥荒》风格
（斜俯视 + 组件化世界 + 确定性模拟 + Lua 脚本内容层），架构水准对标 Unity / Cocos。

> **完整设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**（分层、职责、接口、通信、扩展、路线）。
> 关键决策见 [docs/adr/](docs/adr/)（7 个 ADR）。

## 四条不变量（由测试守护，不靠纪律）

| 不变量 | 守护 |
|---|---|
| 依赖只能单向向下；后端只认接口 | `tests/arch/layers.test.ts`（7 条规则） |
| 内核不取环境随机 / 墙钟 | 同上，规则 3 —— 否则回放不可复现 |
| 每个后端都过同一套契约 | `tests/contract/gfx.contract.ts`（22 条 · 两图形后端）<br>`tests/contract/script.contract.ts`（14 条 · 两脚本后端） |
| **结构性修改只走命令队列** | `core/scene/scene.ts` 的 `enqueue` + `flush`（ADR-0004） |

## 快速开始

```bash
npm install
npm run check            # tsc（strict）+ 230 条判据
npm run sample:headless  # 最小宿主：150 tick / 5 秒 / 脚本驱动 + 存档

# 浏览器（真的能看见画面 + Lua 在跑）
npm run build:web        # esbuild → web/bundle.js（wasm 从 web/glue.wasm 取，不依赖 CDN）
npm run serve:web        # http://127.0.0.1:8123/
#   index.html    演示：WASD 移动 · H 砍树 · F5 存档 · F9 读档 · 浆果在漂（Lua 驱动）
#   selftest.html 端到端自检：13 条断言（画面/批处理/存档往返/Lua 跨边界）
```

`npm run sample:headless` 的输出（实测）：

```
[I][app] 平台就绪：headless gfx=null audio=null input=null fs=mem script=lua
[I][module] 模块启动完成：2 个（game.world, script.lua）
初始： {"nodes":6,"components":5,"pendingCommands":0,"stepsRun":0,"componentUpdates":0}
5 秒后： { tick: 150, time: 5, nodes: 6, components: 5, componentUpdates: 750, droppedSteps: 0 }
hero 位置： (10.00, 2.00)
树 0 的 ttl： 0.000 （5 秒后应为 0：已经烂完）
脚本节点位置： (1.387, 3.752) 半径=4.000（Lua 里用的是 4）
脚本： { backend: 'lua', modules: 1, calls: 150, errors: 0, dropped: 0 }
暂停期间 tick 不变： true (150 → 150)
模块： game.world=started, script.lua=started
已释放。
```

## 分层

```
L6 hosts       browser-entry · headless sample · (editor ⬜)
L5 backends    gfx-null ✅ · gfx-webgl2 ✅ · audio-null ✅ · audio-webaudio ✅
               input-null ✅ · input-dom ✅ · fs-memory ✅ · script-null ✅ · script-lua ✅
L4 extensions  render ✅ · physics ✅ · script ✅ · asset-import ✅ · (ai ⬜ · ui ⬜ · worldgen ⬜)
L3 runtime     GameApp · ITickSource
L2 core        Module · Scene/Node/Component · Scheduler · Asset · Schema
L1 platform    IGraphicsDevice · IAudioDevice · IInputDevice · IFileSystem · ITransport · IScriptRuntime
L0 foundation  Result · math · log · event · memory · time · random
```

依赖方向只能向下；`backends` **不许** import `core`（否则后端会开始依赖实现细节）。

## 加一个功能要改哪里

| 需求 | 改动 | 不用改 |
|---|---|---|
| 一个新组件（如"饥饿值"） | 1 个新文件（schema + 字段） | Scene / Component 基类 / 序列化 |
| 一个新子系统（如"物理"） | 1 个 `IModule` | GameApp / Scene / Scheduler |
| 一个新渲染后端 | 1 个目录 + 1 行注册 | `src/core/**` 全部 |
| 一种新脚本语言 | 1 个 `IScriptRuntime` 实现 | 内核 / 脚本模块 / 契约 |
| 一种新资产类型 | 1 个 `SourceImporter` + 1 个 `IAssetLoader` | AssetDatabase / 管线 |
| 一个存档新字段 | schema 加一行 + 一条 migration | 序列化器 |

## 当前状态

- ✅ L0–L3 完整；**9 个后端**（gfx/audio/input/fs/script 各 1–2 个实现）；**230 条判据全绿**（变异 7 组全被抓住）
- ✅ 2D 渲染管线（相机/精灵/批处理/确定性图集合成）· 2.5D 物理 · 确定性存档 · 跳时间结算
- ✅ 脚本层：`IScriptRuntime` + Lua 5.4（wasm）+ **Lua 5.1 兼容垫片** + **per-module `_ENV` 隔离**
  + 每 tick 串行调度 + 异常隔离 + 最小反射表
- ✅ 资产身份：`.meta` + `AssetId` + 依赖图 + 增量导入 + 产物加载器
- ✅ **PNG 像素解码**（纯 TS inflate，colorType 0/2/3/4/6 × 位深 1/2/4/8/16 × 5 种滤波；
  真实语料 3366/3367）
- ✅ 浏览器宿主能跑，且**画面用真实资产**：`web/assets/*.png` 走完整导入链烘焙成图集
  （WASD + 砍树 + 存读档 + HUD + Lua 驱动的浆果漂浮）
- ⬜ `fs-node` · CI · 跨宿主存档比对 · AI · 世界生成 · 编辑器 · 构建发布 ·
  Adam7/APNG/JPEG（明确不支持，见 §11.2）

未做的项与顺序见 [docs/ARCHITECTURE.md §11–§12](docs/ARCHITECTURE.md)，
本轮排班表见 [docs/PLAN-2026-10-22-阶段2.md](docs/PLAN-2026-10-22-阶段2.md)。
