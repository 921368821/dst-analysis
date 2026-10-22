# 08 · 引擎内核

分层、接口优先的 **2.5D 游戏引擎内核**，目标是《饥荒》风格
（斜俯视 + 组件化世界 + 确定性模拟），架构水准对标 Unity / Cocos。

> **完整设计见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**（分层、职责、接口、通信、扩展、路线）。
> 关键决策见 [docs/adr/](docs/adr/)。

## 三条不变量（由测试守护，不靠纪律）

| 不变量 | 守护 |
|---|---|
| 依赖只能单向向下；后端只认接口 | `tests/arch/layers.test.ts`（6 条规则） |
| 内核不取环境随机 / 墙钟 | 同上，规则 3 —— 否则回放不可复现 |
| 每个后端都过同一套契约 | `tests/contract/gfx.contract.ts`（11 条） |

## 快速开始

```bash
npm install
npm run check          # tsc（strict）+ 61 条测试
npm run sample:headless  # 最小宿主：跑 150 tick / 5 秒 / 暂停不推进
```

`npm run sample:headless` 的输出（实测）：

```
[I][app] 平台就绪：headless gfx=null audio=null input=null fs=mem
[I][module] 模块启动完成：1 个（game.world）
初始： {"nodes":5,"components":4,"pendingCommands":0,"stepsRun":0,"componentUpdates":0}
5 秒后： { tick: 150, time: 5, nodes: 5, components: 4, componentUpdates: 600, droppedSteps: 0 }
hero 位置： (10.00, 2.00)
树 0 的 ttl： 0.000 （5 秒后应为 0：已经烂完）
暂停期间 tick 不变： true (150 → 150)
```

## 分层

```
L6 hosts       player-web · headless · editor            （组合根）
L5 backends    gfx-null ✅ · gfx-webgl2 ⬜ · audio-* · input-* · fs-*
L4 extensions  script ⬜ · physics ⬜ · ai ⬜ · ui ⬜      （饥荒风格能力落点）
L3 runtime     GameApp · ITickSource
L2 core        Module · Scene/Node/Component · Scheduler · Asset · Schema
L1 platform    IGraphicsDevice / IAudioDevice / IInputDevice / IFileSystem / ITransport
L0 foundation  Result · math · log · event · memory · time · random
```

依赖方向只能向下；`backends` **不许** import `core`（否则后端会开始依赖实现细节）。

## 加一个功能要改哪里

| 需求 | 改动 | 不用改 |
|---|---|---|
| 一个新组件（如"饥饿值"） | 1 个新文件（schema + 字段） | Scene / Component 基类 / 序列化 |
| 一个新子系统（如"物理"） | 1 个 `IModule` | GameApp / Scene / Scheduler |
| 一个新渲染后端 | 1 个目录 + 1 行注册 | `src/core/**` 全部 |
| 一种新资产类型 | 1 个 `IAssetLoader` | AssetDatabase |
| 一个存档新字段 | schema 加一行 + 一条 migration | 序列化器 |

## 当前状态

- ✅ L0 / L1 / L2 / L3 完整；四个 Null/内存后端；61 条测试全绿
- ⬜ `gfx-webgl2`（能看见画面）、`input-dom`、`audio-webaudio`
- ⬜ `LongUpdate`（跳时间结算）、脚本层（复用 153 万行 Lua 内容层）
- ⬜ 物理 · AI · 世界生成 · 编辑器 · 构建发布

未做的项与顺序见 [docs/ARCHITECTURE.md §11–§12](docs/ARCHITECTURE.md)。
