# 引擎架构设计（v0.1）

> 目标：一个**分层、接口优先、依赖方向被机器守护**的 2.5D 引擎内核，
> 架构水准对标 Unity / Cocos，最终演进为《饥荒》风格（2.5D 斜俯视 + 组件化世界 + 确定性模拟）的引擎。
>
> 本文档里的每一个接口都对应一个已编译通过的文件；每一条依赖规则都有一条会红的测试。
> **文档与代码不同源时，以代码为准，并且那是一个 bug。**

---

## 0. 一句话结论

这套架构的核心不是"功能多"，而是**三个可检验的不变量**：

| 不变量 | 机器守护 | 违反时的症状 |
|---|---|---|
| 依赖只能单向向下，后端只认接口 | `tests/arch/layers.test.ts` 规则 1/4 | 换后端要改多处；内核被实现细节污染 |
| 内核不取环境随机 / 墙钟 | 同上，规则 3 | 回放对不上、判据只能靠容差 |
| 每个后端都过同一套契约 | `tests/contract/gfx.contract.ts` | 本地全绿、真机黑屏 |

**"新增功能无需重构核心结构"的具体含义**（本文 §7 有完整的"改哪里"表）：
新增一个组件 = 一次 `register`；新增一个后端 = 一次 `register`；
新增一个子系统 = 一个新的 `IModule`。**三种情况都不用改 `src/core/**` 里的任何一行。**

---

## 1. 设计目标与约束

### 1.1 目标（按优先级）

1. **可维护**：任何一处改动的影响面可从依赖图推断；没有"必须记得同时改另一处"的隐式约定。
2. **可扩展**：新增能力落在**预定义的扩展点**上，而不是往内核里加分支。
3. **模块解耦**：模块之间只通过**接口 + 事件 + 命令**通信，没有全局单例、没有跨模块 `import` 具体实现。
4. **符合行业分层**：分层方式与 Unity（Player/Editor/Engine 三层 + 子系统）、Cocos（engine/gfx/creator）可类比，见 §9。

### 1.2 硬约束（决定了架构形态）

| 约束 | 影响 |
|---|---|
| 交付形态是 Web（浏览器直达） | 渲染后端是 WebGL2/WebGPU，不是 D3D；主循环由 rAF 驱动 |
| 目标玩法是《饥荒》风格 | 需要**确定性固定步长**、**大量实体**、**组件组合**、**强存档** |
| 单人 / 小队维护 | 必须"少量强接口 + 机器守护"，不能靠人记住规则 |
| 已有 153 万行 Lua 内容层（DST 注释源码） | 需要脚本绑定层（§5.4），且它必须是**可替换的接口**而不是硬编码 Lua |

### 1.3 明确不做（非目标，写下来避免反复讨论）

- **不做 3D 骨骼动画 / PBR 管线**：2.5D 用精灵 + 图集，3D 是另一个赛道（换赛道不是加一层）。
- **不做 ECS 双世界**：不提供"实体只是 id"的第二套世界模型（理由见 ADR-0001）。
- **不做引擎内 UI 绘制**：UI 是接口（`IUIHost`），DOM 实现与引擎内实现都必须能换。
- **不做 mod 系统 / 包管理 / Shader Graph**：这些是产品决策，不是内核。
- **不做多线程渲染**：Web 没有真多线程渲染；`ICommandList` 已为将来留出"并行录制"的语义空间。

---

## 2. 分层架构

### 2.1 分层图

```
┌──────────────────────────────────────────────────────────────────────────┐
│  L6  宿主 Hosts                                                          │
│      player-web · headless(判据/服务端) · editor(PIE) · wx                │
│      ★ 唯一允许"选具体后端 + 装配模块"的地方（组合根）                    │
└───────────────────────────┬──────────────────────────────────────────────┘
                            │ 依赖（可依赖全部）
┌───────────────────────────▼──────────────────────────────────────────────┐
│  L3  Runtime        组合根与帧驱动                                        │
│      GameApp（组合根） · ITickSource（rAF/interval/manual）               │
└───────────────────────────┬──────────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────────────┐
│  L2  Core           引擎内核（不含任何具体平台知识）                      │
│      ModuleRegistry · ServiceRegistry                                     │
│      Scene / Node / Component · FixedStepScheduler                        │
│      AssetDatabase(AssetId/依赖图/引用计数) · Schema(确定性序列化)        │
└───────────────────────────┬──────────────────────────────────────────────┘
                            │ 只依赖**接口**
┌───────────────────────────▼──────────────────────────────────────────────┐
│  L1  Platform       平台抽象层（**只有接口 + 描述符**，无实现）           │
│      IGraphicsDevice / ICommandList                                       │
│      IAudioDevice · IInputDevice · IFileSystem · ITransport               │
│      BackendRegistry（注册 + 按能力/优先级选择）                          │
└───────────────────────────┬──────────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────────────────┐
│  L0  Foundation     零依赖（除标准库）                                    │
│      Result · Vec2/Vec3/Rect/Color/Affine2 · Logger · EventBus            │
│      ObjectPool/DisposableBag · IClock · IRandom(可序列化)                │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  L4  Extensions     功能扩展（依赖 L0..L3 的**接口**）                    │
│      script(IScriptRuntime) · physics(IPhysicsWorld) · ai · ui · worldgen │
│      ← 这一层是"饥荒风格"能力的主要落点（§12）                            │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  L5  Backends       平台实现（**只依赖 L0/L1，禁止 import L2+**）         │
│      gfx-null(记录型) · gfx-webgl2 · audio-null · audio-webaudio          │
│      input-null · input-dom · fs-memory · fs-node · fs-http               │
│      input-injected (host-supplied device)                                │
└──────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│  L7  Tooling        离线工具（**只依赖 L0**，运行期不存在）               │
│      publish/pack-plan（微信分包规划 · Steam VDF 生成）                   │
│      ★ 引擎**不许 import 它**：打包逻辑漏进运行时代码 = 体积跟着进包      │
└──────────────────────────────────────────────────────────────────────────┘
```

### 2.2 依赖规则（可执行）

| 层 | 允许依赖 | 禁止依赖 | 为什么 |
|---|---|---|---|
| L0 Foundation | 标准库 | 任何 L1+ | 它是所有人的公共底座，依赖任何东西都会形成环 |
| L1 Platform | L0 | L2+ | 接口层一旦知道内核，抽象就漏了 |
| L2 Core | L0, L1（接口） | L5 后端 | 内核必须能在任何后端上跑（含"没有后端"的 headless） |
| L3 Runtime | L0–L2 | — | 组合根要能引用接口 |
| L4 Extensions | L0–L3 | — | 扩展可以依赖内核，但内核不知道扩展 |
| L5 Backends | L0, L1 | **L2+** | 后端只实现接口；知道内核就会开始依赖实现细节 |
| L6 Hosts | 全部 | — | 宿主是"知道一切"的那一层，这正是它的职责 |
| L7 Tooling | L0 | L1–L6 | 打包要在没有引擎、没有平台、没有 GPU 的空容器里跑得起来；碰了 runtime 就说明它有别的意图 |

**为什么 L5 不许依赖 L2**（这条最反直觉，值得单独说）：
后端只知道"我要创建一个 32 字节的顶点缓冲"，不该知道"这是精灵、那是树"。
一旦后端开始 import `Scene`，就会出现"WebGL2 后端里特判了某种组件"这种代码 ——
它无法测试、无法移植，而且会悄悄变成第二个真相来源。

**为什么 L1 不许出现平台类型**（`arch` 规则 2）：
`WebGL2RenderingContext`、`HTMLCanvasElement`、`document.`、`window.` 一个都不许出现。
判断标准：把 `src/platform/**` 原样拷到 Node 或原生宿主里，它必须还能编译。
这条规则让"换后端"从"重写一遍"变成"实现一个接口"。

### 2.3 层内的组织原则

- **一个概念一个文件**，文件名即概念名（`scheduler.ts` = 调度器，不是 `utils.ts`）。
  没有 `utils`/`helpers`/`common` —— 那种文件是"不知道放哪"的垃圾桶，最终会依赖所有东西。
- **同一层内允许互相依赖，但不允许环**。环靠 `tsc` + 人工审查；模块级环由
  `ModuleRegistry` 的拓扑排序在**启动时**拒绝（§5.1）。
- **接口与实现分开文件**：`platform/gfx/device.ts`（接口）与 `backends/gfx-webgl2/device.ts`（实现）。
  一个文件里既有接口又有实现时，读者会分不清"这是契约还是某个后端的细节"。

---

## 3. 模块职责

### 3.1 L0 Foundation

| 模块 | 职责 | 明确不做 | 文件 |
|---|---|---|---|
| `result` | `Result<T,E>` + `EngineError{code,message,detail}` | 不用异常做控制流 | `foundation/result.ts` |
| `math` | Vec2/Vec3/Rect/Color/Affine2 + `quantize` | 不做 SIMD 批处理（那是 gfx 层的事） | `foundation/math/*` |
| `log` | 通道化日志 + 限流 + 内存 sink | 不做结构化日志后端（sink 可换） | `foundation/log/logger.ts` |
| `event` | 类型化 `EventBus<TMap>`，同步分发 + 快照遍历 + 异常隔离 | 不做异步事件队列（确定性要求同步） | `foundation/event/event-bus.ts` |
| `memory` | `ObjectPool`、`DisposableBag`（**逆序释放**） | 不做 GC / 内存池分配器 | `foundation/memory/disposable.ts` |
| `time` | `IClock`（系统/手动）、`Stopwatch` | **不提供"游戏时间"**（那是 scheduler 的） | `foundation/time/clock.ts` |
| `random` | `IRandom` + XorShift128（状态可序列化） | 不做加密随机 | `foundation/random.ts` |

**为什么 `IClock` 与"游戏时间"必须是两个东西**：
墙钟会被暂停、会跳变、会被系统时间同步改；游戏时间是 `tick × fixedDt`，只前进不后退。
混在一起就会出现"暂停后恢复，角色瞬移"（累积的真实时间被一次性补跑）。
上一代引擎为此把"不许在模拟层调 `Date.now()`"写进文档，而**文档拦不住人** ——
所以现在是 `arch` 规则 3 在拦。

### 3.2 L1 Platform

| 接口 | 职责 | 关键语义 |
|---|---|---|
| `IGraphicsDevice` | 资源创建/销毁、帧边界、读回 | 句柄是**不透明整数**；创建失败返回 `Result`（可降级） |
| `ICommandList` | 一帧内的绘制命令录制 | 录制结束后再调用**必须被拒绝**（否则画进下一帧） |
| `IAudioDevice` | clip → voice → bus | `resume()` 是独立方法：自动播放策略是**契约**，不是意外 |
| `IInputDevice` | `poll()` 返回快照 + 原始事件流 | `pressed/released` 是"自上次 poll"的边缘，**不是每帧都真** |
| `IFileSystem` | 异步读写 + `scheme:` 前缀 | 异步签名从一开始就定（浏览器 IO 必然异步） |
| `ITransport` | 连接 / 收发 / RTT | `rttMs` 未知返回 **-1**，不许用 0 冒充"很快" |
| `BackendRegistry` | 注册 + 按 `priority/probe` 选择 | 全部不可用时返回**聚合原因**，不是"没有可用后端" |

**三条平台层原则**：

1. **句柄而不是对象**（ADR-0002）。`TextureHandle` 是 `number & {brand}`。
   调用方无法调后端私有方法，销毁后句柄整体失效（不会留下"半死对象"）。
2. **能力查询而不是 try/catch 探路**。用特性前查 `caps`，查不到走降级路径。
   "try 一下看会不会失败"在图形 API 上会产生大量日志噪声，而且掩盖真实错误。
3. **所有工厂的 `create` 都是同步的**（ADR-0003 的推论）。构造轻、初始化重；
   异步只在 `init()` 里。这样 `createPlatform` 保持同步，宿主构造期不需要 `await`。

### 3.3 L2 Core

| 模块 | 职责 | 明确不做 | 文件 |
|---|---|---|---|
| `ModuleRegistry` | 拓扑排序启动、逆序释放、失败回滚、状态快照 | 不做热插拔（要热插拔先 `stop`） | `core/module/module.ts` |
| `ServiceRegistry` | 按 token 提供服务（推而非拉） | **不是全局单例**（每个宿主一个） | `core/module/services.ts` |
| `Scene` | 节点树 + 按类型索引的组件 + 确定性步进入口 + 命令队列 | 不做渲染、不做物理 | `core/scene/scene.ts` |
| `Node` | 变换层级（局部 TRS + 惰性世界变换 + 版本缓存） | 不做"节点即实体"的额外语义 | `core/scene/node.ts` |
| `Component` | 生命周期四段 + schema 声明式序列化 | 不做反射式自动注册（显式 `register`） | `core/scene/component.ts` |
| `FixedStepScheduler` | 固定步长、追帧上限、幂等 tick、暂停/缩放/**冻结**、alpha | **不做"游戏时间"以外的任何事** | `core/scheduler/scheduler.ts` |
| `AssetDatabase` | AssetId（GUID）、依赖图、引用计数、卸载反拓扑、并发去重 | 不做导入（那是 importer 的职责） | `core/asset/asset.ts` |
| `Schema` | 确定性编码（字段序 + 量化）+ 版本迁移链 | 不做二进制格式（先要可读可 diff） | `core/serialization/schema.ts` |

**关于存档头的版本闸门**（2026-10-23 修）：版本号写在哪个键上属于**格式本身**，
场景存档用 `format`、`Schema` 默认用 `__v`。原先 `sceneFromJson` 只 `JSON.parse` + 查字段存在，
版本闸门只写在 `loadScene` 里，于是出现两种**安静**的错误：
`format:0` 的旧档被当成当前版本读进来（组件按今天的字段解释旧数据）；
`format:99` 的新档也读进来，直到加载才炸（而编辑器列表、存档预览只解析不加载）。
现在：`Schema` 增加 `versionKey`（场景声明 `format`），`sceneFromJson` 直接走 `SCENE_SCHEMA.decode`
（解析 + 迁移一步完成），错误码翻译回 `SCENE.*`；版本号必须是 ≥1 的整数
（`format:1.5` 以前同时躲过 `>` 与 `<` 两个比较，原样放行）；
`Schema` 构造时校验**迁移链条数**必须等于 `version-1` —— 以前只校验"编号连续"，
一条迁移都没有时那个循环一次都不跑，"升到 v2 却忘了写迁移"能一路构造成功。
判据 10 条 + 变异 M61–M64。

**关于 `Scene` 与 ECS 的关系**（ADR-0001）：
采用"Node + Component"的世界模型，但组件存储是**按类型集中的数组**（`byType: Map<string, Component[]>`），
所以"遍历所有可腐烂物"是 `componentsOf("game.perishable")` 的一次数组遍历，而不是"遍历全部节点再过滤"。
这就是 ECS 的性能收益，但**不付出 ECS 的认知代价**（脚本/编辑器仍能持有"这个实体"的引用）。

**关于 `Scene.step` 的顺序**（这是确定性的关键之一）：

```
step(tick, dt):
  1. flush()                     ← 执行上一步积累的结构性命令
  2. for type of typeOrder:      ← 按**组件类型的注册序**，不是节点序
       for c of byType[type]:    ← 快照长度，本步内新增组件不参与
         if enabled && activeInHierarchy: c.onUpdate(tick, dt)
  3. flush()                     ← 更新期投递的"销毁自己"在本步生效
```

为什么按类型而不是按节点：节点的添加顺序取决于加载顺序（将来可能并行），
而类型的注册顺序是**代码里写死的常量**。可确定性优先于"直觉上的层级顺序"。

### 3.4 L3 Runtime

| 模块 | 职责 |
|---|---|
| `GameApp` | **组合根**：建平台 → 建基础设施 → 提供内核对象 → 装配模块 → 提供 `frame()` |
| `ITickSource` | 帧驱动抽象（`Raf` / `Interval` / `Manual`） |
| `AppSnapshot` | 诊断快照（healthz / 编辑器状态栏 / 判据共用**同一份**） |

`GameApp` 的职责清单只有四件，多一件都算越界（它不实现世界步进、渲染、输入路由、玩法）。
"世界步进"由 `game.world` 模块订阅 `scheduler.onStep` 完成 —— 见 `samples/headless.ts`。
这样将来要做"多世界并行"或"回放时替换步进器"，改的是模块，不是内核。

### 3.5 L4 Extensions（渲染 / 物理 / 脚本 / 资产 / 存档）

| 模块 | 职责 | 关键取舍 | 文件 |
|---|---|---|---|
| `render/batch2d` | 精灵批处理：排序 + 顶点组装 | 排序键 `layer↑ → z↓ → order → atlas → nodeId`；**层与 z 都优先于纹理切换**（遮挡正确性不可牺牲；跨层允许切换，因为层的优先级高于 z —— 地面永远先画） | `extensions/render/batch2d.ts` |
| `render/render-module` | 把 Sprite 组件变成每帧一次 draw | 相机跟随在**渲染阶段**做（用 alpha），不在 `onUpdate` 里做；多页时分段提交（每段绑自己的纹理 + `firstIndex`） | `extensions/render/render-module.ts` |
| `render/camera` | 正交 + 斜俯视投影（`tiltY`） | 投影在 CPU 做；逻辑坐标是**未压缩**的 XZ | `extensions/render/camera.ts` |
| `render/sprite` | 渲染数据组件 | **不存 GPU 句柄**，只存 `atlasId + frame`（句柄是进程内的，存进档就是灾难） | `extensions/render/sprite.ts` |
| `physics` | 2.5D 碰撞：空间哈希 + 推出 + **连续碰撞扫掠** | 不做刚体积分（饥荒风格的正确选择：卡顿不会穿墙）。扫掠是**纯函数**（`sweep.ts`），世界只负责筛候选 —— 于是"一拍跨过薄墙"有解，而推挤仍由 `resolve()` 负责（[ADR-0013](adr/0013-continuous-collision.md)） | `extensions/physics/physics.ts` · `extensions/physics/sweep.ts` |
| `script/script-module` | 每 tick 驱动 `game.script` 组件调 Lua | 内部**串行队列**（上限 4，满了丢弃 + 计数）；异常隔离到单脚本；同名 `loadModule` = **热重载**（先编译后替换 / 执行期出错不换 / 每次造新 env，判据 `script-hot-reload.test.ts`） | `extensions/script/script-module.ts` |
| `asset-import` | `.meta` 身份 + 导入器 + 增量管线 + 产物加载器 | 身份来自 `.meta`；增量 = hash + importerVersion + 依赖仍活着 | `extensions/asset-import/*` |
| `asset-import/decode` | 位图解码：PNG（inflate + 反滤波 + 调色板 + Adam7 + APNG）/ JPEG（DCT + 熵解码）/ 按魔数分发 | **纯 TS、同步**：不用 `DecompressionStream`、不用 `createImageBitmap`（跨环境字节级一致 + 错误可诊断）。代价是自己养一份 | `extensions/asset-import/decode/*` |
| `render/atlas-from-assets` | 多张贴图 → 一张确定性图集 | 排序 **高度降序 → 名字升序**（`<` 而非 `localeCompare`）；空白填全透明；padding 只做帧间 | `extensions/render/atlas-from-assets.ts` |
| `scene-io`（在 core） | 确定性存档 | 三遍装配（建节点 → 设父子 → 挂组件）；组件按 type 升序 | `core/scene/scene-io.ts` |

**渲染阶段为什么是独立阶段而不是事件**（`core/frame-host.ts`）：
事件是"发生了什么，谁关心谁订阅"；渲染是"每帧必须执行的一步"。
用事件的话，"没人订阅"与"渲染器都注销了"无法区分，画面会静默变黑。

**跳时间（`LongUpdate` 语义）**：`Scene.fastForward(elapsed)` 让实现了 `IFastForwardable`
的组件按解析式结算，并**报告** `skipped` 数量 —— 没实现该接口的组件（AI、状态机）
在跳过时段里"什么都没发生"，这必须是可见事实。

### 3.6 L5 Backends

| 后端 | 状态 | 说明 |
|---|---|---|
| `gfx-null` | ✅ 完成 | **记录型**：完整实现契约，记录每次 draw/clear/上传，供 headless 判据断言 |
| `fs-http` | ✅ 完成 | **只读**（不实现 `IFileSystem`，类型上就写不了）：静态资源当文件系统，路径归一 + 前缀核对 + 状态码映射（404/403/5xx/断网）+ `canList=false` 时 `list` 报 `FS.NOT_SUPPORTED`；判据：与 mem/node **同一套 11 条只读契约** + 8 条 HTTP 特有（HEAD 不支持、缺 Content-Length、500、断网） |
| `fs-storage` | ✅ 完成 | 浏览器存档（`localStorage`）：普通**可写**后端，二进制走 base64（膨胀 4/3，配额按字符算）、目录用索引键维护（索引坏了从文件路径**自愈重建**）、写满报 `FS.NO_SPACE`；判据：与 mem/node **同一套 26 条契约** + 7 条 storage 特有（base64 全长度往返、前缀隔离、配额、记录损坏、索引自愈） |
| `fs-memory` | ✅ 完成 | 判据 / PIE 预览 / 存档暂存 |
| `audio-null` | ✅ 完成 | 记录播放 + 可推进音频时钟；`resume()` 首次失败（模拟自动播放策略） |
| `input-null` | ✅ 完成 | 可编程输入（`press`/`movePointer`/`typeText`），边缘语义在此实现一次 |
| `gfx-webgl2` | ✅ 完成 | 只依赖 `GL2Like`（可在 Node 注入 fake）⇒ 同一套契约能在无 GPU 环境跑 |
| `audio-webaudio` | ✅ 完成 | 声部上限 + `onended` 回收 + `resume()` 可失败（自动播放策略） |
| `input-dom` | ✅ 完成 | `event.code`（不是 `key`，中文输入法下 `key` 会变 `"Process"`）+ 失焦清空 |
| `fs-node` | ✅ 完成 | root 沙箱（拒绝 `..`，realpath 越界判定）+ 原子写（临时文件 → fsync → rename，Windows 的 EPERM 重试）+ 虚拟路径不外泄；判据：与 `fs-memory` 同一套 15 条契约 + 子进程重启读档 |

**"Null 后端"为什么是一等公民**（而不是测试夹具）：
它让"引擎能不能在没有 GPU 的环境里完整跑一遍世界"成为**架构保证**而不是运气。
上一代引擎的 274 条判据里，凡是要渲染的都只能测"数据对不对"，
因为没有一个"能接受全部渲染调用但不真的画"的后端 —— 于是渲染层的错误只能靠肉眼。

---

## 4. 核心接口定义

### 4.1 图形设备（最复杂的一个，作为范例）

```ts
// src/platform/gfx/device.ts
export interface IGraphicsDevice {
  readonly caps: DeviceCaps;                    // 能力：先查再降级
  readonly stats: GfxStats;                     // 每帧 drawCall/顶点/纹理切换（判据可断言）
  get size(): { width: number; height: number };

  createBuffer(desc: BufferDesc): Result<BufferHandle, EngineError>;
  updateBuffer(h: BufferHandle, data: ArrayBufferView, byteOffset?: number): Result<void, EngineError>;
  destroyBuffer(h: BufferHandle): void;

  createTexture(desc: TextureDesc, data?: ArrayBufferView | null): Result<TextureHandle, EngineError>;
  updateTexture(h: TextureHandle, region: Rect, data: ArrayBufferView): Result<void, EngineError>;
  destroyTexture(h: TextureHandle): void;

  createShader(desc: ShaderDesc): Result<ShaderHandle, EngineError>;
  createPipeline(desc: PipelineDesc): Result<PipelineHandle, EngineError>;
  createRenderTarget(desc: RenderTargetDesc): Result<RenderTargetHandle, EngineError>;

  beginFrame(target: RenderTargetHandle | null): ICommandList;
  endFrame(): void;
  readPixels(target: RenderTargetHandle | null, rect: Rect): Result<Uint8Array, EngineError>;

  resize(w: number, h: number): void;
  destroy(): void;
}
```

**读法（这四项决定了它是不是"标准"接口）**：

| 设计 | 为什么这样 | 不这样的后果 |
|---|---|---|
| 资源用 `Handle`（branded number） | 后端可选"对象/索引/裸指针"；销毁后整体失效 | 对象引用会让"用已释放资源"变成偶发崩溃 |
| 创建返回 `Result` | 显存不足/超限是**预期内**，上层要降级 | 抛异常 ⇒ 降级路径写在 catch 里 ⇒ 没人写 |
| `caps` 显式声明能力 | 单一代码路径覆盖多后端 | `if (isWebGL2)` 分支扩散到业务代码 |
| `stats` 是接口的一部分 | "批处理生效了没有"必须能断言 | 只能靠肉眼和"感觉挺快" |

完整接口清单与签名见源码（每个都有语义注释）：
`platform/gfx/*`、`platform/audio/device.ts`、`platform/input/device.ts`、`platform/fs/fs.ts`。

### 4.2 模块（扩展的第一入口）

```ts
// src/core/module/module.ts
export type ModuleHookResult = void | Result<void, EngineError> | Promise<void | Result<void, EngineError>>;

export interface IModule {
  readonly id: string;                       // `域.名`，全局唯一
  readonly deps?: readonly string[];         // 硬依赖：缺一个就不启动
  readonly optionalDeps?: readonly string[]; // 软依赖：有就用，没有降级
  init(ctx: ModuleContext): ModuleHookResult;
  start?(): ModuleHookResult;
  stop?(): void;
  dispose?(): void;
  describe?(): string;                       // 诊断：编辑器/healthz 展示
}

export interface ModuleContext {
  readonly log: Logger;
  readonly events: EventBus<Record<string, unknown>>;
  readonly services: ServiceRegistry;        // 取 Scene / Scheduler / Assets
  readonly platform: IPlatform;
  readonly random: IRandom;                  // 世界级随机（可序列化状态）
  readonly module: <T extends IModule>(id: string) => T | undefined;
}
```

**`ModuleHookResult` 允许 `void` 是一个刻意的决定**：
如果强制每个 `init` 都写 `return ok(undefined)`，两周之后所有人都会复制粘贴，
而不再思考"这里会不会失败"。**只有在真会失败时才返回 `Result`，失败才有信息量。**

### 4.3 服务 token（解耦的落点）

```ts
// src/core/module/services.ts
export interface ServiceToken<T> { readonly key: string; /* 编译期携带 T */ }
export function defineService<T>(key: string): ServiceToken<T>;

services.provide(Services.Scene, scene, "core");
const scene = ctx.services.require(Services.Scene);   // 缺了会抛，并列出已提供的服务
const audio = ctx.services.get(Services.Audio);       // 软依赖：可能 undefined
```

**"推"与"拉"的区别不是风格问题**：
单例是"拉"——任何模块 `import` 就能拿，依赖关系不出现在任何签名里 ⇒ 依赖图不可见、不可测、不可替换。
token 是"推"——宿主显式 `provide`，模块显式 `require`，依赖关系是**数据**，可以被检查。

### 4.4 场景与组件

```ts
// 组件：字段声明式（schema 是唯一来源，save/load 由基类生成）
export abstract class Component {
  node: Node | null;
  enabled: boolean;
  abstract readonly schema: ComponentSchema;   // { type, fields, defaults? }

  onAttach(): void; onDetach(): void;
  onEnable(): void; onDisable(): void;
  onUpdate(tick: number, dt: number): void;    // dt 是**固定步长**，不是真实帧间隔

  save(): Record<string, unknown>;             // 按 schema 顺序 → 字节确定
  load(data): { missing: string[] };           // 缺字段用零值，但**报告**
}
```

**生命周期边沿**（`onEnable` 只在 false→true 触发一次，不是每帧）由 `Scene` 统一管理，
组件实现者不需要自己记 `lastEnabled` —— 这是"把易错的事收进框架"的例子。

### 4.5 调度器

```ts
export interface SchedulerConfig {
  readonly fixedDt: number;              // 1/30（饥荒风格默认）
  readonly maxStepsPerFrame?: number;    // 5：防止死亡螺旋
  readonly maxFrameDt?: number;          // 0.25s：切标签页回来不跑 18000 步
  readonly timeScale?: number;
}
advance(realDtSec): number;   // 返回本帧步数；超出预算的部分**丢弃并记账**
stepTo(targetTick): number;   // 幂等：target ≤ 当前 则返回 0（旁路冻结，见 ADR-0011 ④）
stepOnce(): number;           // 单帧调试
resetTo(tick): void;          // 读档：不执行中间步；**连冻结一起清**（瞬态不跨存档）
freeze(ticks): void;          // 顿帧：冻 ticks 个逻辑步（批73，与 paused/timeScale 平级）
stats(): SchedulerStats;      // 含 droppedSteps（卡顿唯一可见的症状）/ frozen / freezeTicks
```

三条边界规则（每条都有测试）：**上限 + 记账**、**幂等**、**alpha 只给渲染用**。

**三条时间通道，互不混用**（批73 起）：`paused` 是用户的意图、`timeScale` 是玩法刻度、
`freeze` 是特效的意图（hitstop）。冻结不能借 `paused`（到期会解除用户的暂停），
也不能借 `timeScale`（那只是变慢、tick 照走）。时长按**逻辑步**指定、按**真实时间**
消耗 ⇒ 帧率无关。详见 `docs/adr/0011-hitstop.md`。

---

## 5. 模块间通信

### 5.1 三种方式，必须分清

| 方式 | 语义 | 用在哪 | 禁止 |
|---|---|---|---|
| **直接调用** | 同步、同层或向下 | 热路径（变换求值、渲染提交） | 跨层反向调用 |
| **事件** `EventBus` | "发生了某事"，发布/订阅 | 解耦通知（音效、成就、埋点） | 载荷携带可变引用；在回调里改世界 |
| **命令队列** `Scene.enqueue/spawn/...` | 结构性修改，帧边界统一执行 | 增删节点/组件、切场景 | 在遍历中直接改结构 |

### 5.2 为什么结构性修改必须排队

`onUpdate` 里遍历 `byType[type]` 的数组时增删组件，会让遍历跳过元素或重复执行。
上一代引擎的对策是"遍历前先取快照"——那只是把问题挪到别处（快照里的已删组件仍会被调）。

这里的对策是**命令队列 + 两次 flush**：

```
step:
  flush()                 ← 上一步积累的命令（含"销毁自己"）
  for type: for c: onUpdate()
  flush()                 ← 本步 update 里投递的命令，立即生效
```

好处不止"安全"：**命令是可记录的**，所以"可重放 / 可撤销 / 可确定性"都有了落点
（这是下一个能力——编辑器撤销与回放——的前提，而不是额外工作）。

### 5.3 事件表的组织

所有引擎事件集中声明在 `core/tokens.ts` 的 `EngineEvents` 接口里（一张表 = 一份文档 + 一处静态检查）。
命名约定 `域:动作`，载荷只放**不可变值或 id**。

典型事件：`scene:node-spawned`、`scene:component-attached`、`scheduler:steps-dropped`、`asset:load-failed`。
其中 `scheduler:steps-dropped` **必须有人订阅并记录** —— 否则"丢时间"是静默的
（`GameApp` 默认把它接到 `warn` 日志上）。

### 5.4 脚本层通信（L4，已实现）

```ts
// L1 · platform/script/runtime.ts
export type ScriptValue = null | boolean | number | string
  | readonly ScriptValue[] | { readonly [key: string]: ScriptValue };

export interface IScriptRuntime {
  readonly id: string;                 // 'lua' | 'null'
  readonly caps: {
    readonly language: string;         // 'lua'
    readonly version: string | null;   // '5.4'
    readonly interruptible: boolean;   // 能打断死循环
    readonly hostCalls: boolean;       // 能暴露宿主函数
    readonly executes: boolean;        // 能不能真执行（null 后端为 false）
  };
  loadModule(name: string, source: string): Promise<Result<void, EngineError>>;
  unloadModule(name: string): Promise<Result<void, EngineError>>;
  hasModule(name: string): boolean;
  listModules(): readonly string[];
  call(fn: string, args?: readonly ScriptValue[], opts?: { timeoutMs?: number })
    : Promise<Result<ScriptValue, EngineError>>;
  expose(name: string, fn: HostFunction): Result<void, EngineError>;
  exposed(): readonly string[];
  ready(): Promise<Result<void, EngineError>>;
  stats(): { modules: number; calls: number; errors: number; timeouts: number };
  dispose(): void;
}
```

四条语义（决策依据见 ADR-0006）：

| 语义 | 落地 | 为什么 |
|---|---|---|
| **只传值** | `assertScriptValue` 在跨界前校验；对象一律 `expose()` 成函数 | 异常隔离与 Worker 隔离的前提；传引用会让脚本持有已销毁节点 |
| **全异步** | 方法返回 `Promise<Result>`；`create()` 同步、初始化在 `ready()` | 浏览器 WASM 加载必然异步；定成同步后接 Worker 要改所有调用方 |
| **失败走 Result** | `SCRIPT.NO_FUNCTION` / `CALL_FAILED` / `TIMEOUT` / `LOAD_FAILED` / `BAD_VALUE` / `DISPOSED` | 调用方按 code 分支；脚本 `error()` 是可预期失败，不是运行时崩溃 |
| **每 tick 串行** | `ScriptModule` 内部队列（上限 4，满了丢弃 + 计数 + 日志） | 宿主在同步 `onStep` 里驱动；不排队会让两个 tick 交替改同一个全局变量 |

**两个实现**：

- `backends/script-lua`（wasmoon / Lua 5.4）：真执行。
  死循环用 `debug.sethook` 的计数钩子 + `os.clock()` deadline 打断（打断后 state 仍可用）。
- `backends/script-null`：`executes: false`，`call` 一律 `NOT_SUPPORTED`。
  **不假装执行** —— 脚本的产物是世界状态，假执行没有可见产物，只会制造静默 bug。

**`ScriptModule`（L4）** 驱动方式：每 tick 遍历 `game.script` 组件，调 `module.entry`
（默认 `onUpdate`），参数 `(nodeId, dt, tick)`。暴露的最小 API：

```
engine_log / engine_spawn / engine_destroy / engine_count
engine_get_pos / engine_set_pos / engine_set_scale
engine_nodes_named / engine_tick
```

结构性修改（spawn/destroy）走 `Scene` 的命令队列（ADR-0004），脚本调用期间不改树。

**为什么脚本层必须是接口**：
已有 153 万行 Lua 内容层（DST 注释源码）要复用，但"引擎内核绑定 Lua"会让
"将来想支持 JS/DSL"变成重写。把 Lua 放在 `IScriptRuntime` 后面，
内核只认"C 风格调用 + 反射表"，换语言是换实现。

**Lua 5.1 兼容层**（`backends/script-lua/compat-lua51.ts`，300 行 Lua 源码常量）：
wasmoon 是 5.4，DST 内容层是 5.1。垫片补齐 `unpack` / `loadstring` / `setfenv` /
`getfenv` / `module()` / `package.seeall` / `math.pow|mod|ldexp|frexp|log10` /
`table.getn` / `string.gfind` / `arg`，并接管 `require`（只认 `package.loaded` 与
`package.preload`，**不去读文件系统** —— wasm 里没有 `io`，假装有会得到"require 永远失败"）。

| 垫片 | 5.4 实现 | 关键坑 |
|---|---|---|
| `setfenv(f, t)` | `debug.upvaluejoin(f, i, holder, 1)` | **不能用 `debug.setupvalue`**：它改的是 chunk 内**共享**的 `_ENV` upvalue 对象，会把兄弟闭包和调用者一起换掉（实测：`tostring` 立刻变 nil）。`upvaluejoin` 给目标函数一个**私有** upvalue，符合 5.1 的"函数级环境"语义 |
| `getfenv(f)` | `debug.getupvalue(f, 1)` → 取**第二个**返回值 | `getupvalue` 返回 `(name, value)`；只取第一个会拿到名字，症状是"执行后有效 env 永远是 nil" |
| `module(name, ...)` | 建表 + `package.loaded` 登记 + 对调用者 `setfenv` | chunk 顶层调 `module()` 会改掉 **chunk 自己的** env ⇒ 收集命名空间必须在**执行后**重新取有效 env，且同时收"加载时给的 env"与"有效 env"两张表的键 |
| `require(name)` | `package.loaded` → `package.preload` → 明确报错 | 5.1 的 `module.name` 约定由此闭环 |

未支持 `setfenv(level, env)`：内容层真实用法为 **0 处**
（`grep -rn "setfenv\s*(\s*[0-9]" --include="*.lua"` 只命中注释），
且 `06-引擎复刻/host/compat52.lua` 做了同样的取舍 —— 这是无证据支持必要性的取舍，不是省事。

**per-module `_ENV` 隔离**：每个模块一张独立 env 表（`__index = _G`）。
模块内 `x = 1` 写进自己的表，`math` / `string` / `engine_log` 经 `__index` 落到 `_G`。
函数名解析顺序：`<module>.<entry>`（最长前缀匹配）→ 最近加载模块的裸名 → `_G`。
同名重载会**丢弃旧 env**（复用旧表会让热重载后残留上一版的全局）。

**`module()` 往真 `_G` 写的表怎么收尾**：5.1 语义下 `module("a.b")` 会在 `_G` 里建表，
这正是"全局"的本义，不能隔离掉。但**卸载时必须摘掉**，否则下一次加载同名模块会复用那张脏表
（旧字段还在 ⇒"改了代码没生效"）。做法：建表时记录"父表 + 键 + 表本身"，卸载时按**身份**
（`parent[key] == 记录的表`）摘除；中间容器只在**变空**时摘（否则会把别人同名模块的表一起删掉），
当时非空的容器转入待办、随其他模块卸载再补刀。判据三条 + M58/M59/M60。

**残留边界**（诚实标注）：`setfenv` 对 C 函数是空操作（5.4 的 C 函数没有 `_ENV` upvalue）。

---

### 5.5 资产管线（L4，已实现）

```
源文件 + .meta          导入器              产物                  加载器
assets/grass.png   →  textureImporter  →  library/imported/  →  ImportedTexture
assets/grass.png.meta   （PNG 头解析）       <id>.json             （元数据 + 原始字节）
```

三层各管一件事（决策依据见 ADR-0007）：

| 层 | 负责 | 不负责 |
|---|---|---|
| `.meta` sidecar | **身份**（`AssetId` + type + settings） | 内容、依赖 |
| `SourceImporter` | 内容 → 产物（含 `dependencies` 解析） | 身份、注册 |
| `AssetImportPipeline` | 扫描 / 增量 / 注册 / 清理幽灵 | 解码像素、挂 GPU |
| `IAssetLoader` | 产物 → 运行时对象 | 导入、重导 |

增量判定是三元组：`sourceHash` + `importerVersion` + **依赖仍然活着**。
少了第三项的症状是"删了一张贴图，构建全绿，运行到加载才崩"。

**像素解码**（`extensions/asset-import/decode/`，L4）：

| 文件 | 职责 | 取舍 |
|---|---|---|
| `inflate.ts` | 纯 TS 的 zlib/deflate：stored / fixed Huffman / dynamic Huffman，校验 adler32 | **不用 `DecompressionStream`**：需要同步、跨 Node/浏览器字节级一致、错误可诊断（`invalid block type 3 at byte 1234`）。代价是自己养一份 ~200 行 |
| `png.ts` | colorType 0/2/3/4/6 × bitDepth 1/2/4/8/16，`PLTE`/`tRNS`，5 种反滤波，**Adam7 七个 pass**，逐块 CRC | 产出 RGBA8（`keep16` 另给 RGBA16），可直接 `createTexture` |
| `apng.ts` | `acTL`/`fcTL`/`fdAT`，帧矩形 + `dispose_op` + `blend_op` | 产出**合成后的整幅帧**：调用方不需要知道 dispose/blend 是什么 |
| `jpeg/`（14 个文件） | **13 个 SOF**（基线/扩展/渐进/无损/差分 × Huffman/算术）；DCT 类 8/12 位、无损类 2..16；分层 DHP+EXP+差分帧；QM 算术 + DPCM 预测器；任意 h/v 采样 + 三角上采样；DRI/RST；1/3/4 分量；EXIF 方向 | 自写 IDCT 与 QM 状态机，**同步**且无第三方依赖；判据（支持的过程/精度）只有 `checkProcessSupport()` 一份，导入器调用它而不是另写一张表 |
| `image.ts` | `sniffImageFormat` + `decodeImage`：按**文件头魔数**分发到 PNG/JPEG | 调用方不再写 `if (magic)`；新增格式只改这一处，不会"某个入口静默变黑图" |
| `../render/atlas-from-apng.ts` | 帧 → sprite sheet（帧名零填充，字典序 == 播放序） | 动图退化成"按帧矩形切 UV"，不改渲染模块 |

**Adam7 隔行**：七个 pass 各自独立反滤波（pass 之间不共享 up 邻居），
sub-byte 位深在每个 pass 内**重新按位打包**（`ceil(passW * bitsPerPixel / 8)`）。
工程内 3423 张 PNG 里隔行仍只有我们自己造的 18 张 —— 所以正确性不靠真实语料，
而靠**双实现金标**：语料由 `tools/png-encode.mjs`（过滤式分 pass，与解码器的生成式不同源）
生成，再交给 **pngjs 7** 与 **Pillow 13** 分别解码，两者逐字节一致才固化成
`tests/fixtures/png/*.rgba`。详见 [ADR-0008](adr/0008-png-full-format-support.md)。

**APNG**：每帧是独立 zlib 流（`fdAT` 前 4 字节是序列号，不是数据）；
dispose 作用于**上一帧**且 `PREVIOUS` 要在绘制前存快照；`OVER` 是 Porter-Duff
source-over（`Ao = As + Ad(1-As)`），不是覆盖。金标用 Pillow 逐帧解矩形 PNG +
`Image.alpha_composite` 合成 —— Pillow 的 APNG 内建读取对半透明 `OVER` 会把 alpha
二次相乘（`paste` + mask 语义），不能当金标，这个口径差记在 ADR-0008。

**16 位**：`pixels` 恒为 RGBA8（`round(v/257)`，与 pngjs 同口径），`keep16: true` 另给
`pixels16` 全精度，恒满足 `pixels[i] === round(pixels16[i]/257)`。

16 位**能进 GPU**（2026-10-22 补齐）：`PixelFormat.RGBA16` + `bytesPerPixel()`（格式→字节数
**只此一处**，避免双份映射漂移）→ 图集 `precision: "auto"|8|16`（auto = 任一源带 `pixels16`
就整张 16 位，8 位源上转 `v*257`）→ `render-module` 按 `atlas.format` 选上传路径
→ WebGL2 用 `RGBA16 / UNSIGNED_SHORT(0x1403)`，null 后端用 `textureFormat()` 断言。
`format === "rgba16"` 却给不出 `pixels16` ⇒ `init` 直接失败（`RENDER.BAD_ATLAS`），
不允许"降采样后假装成功"。代价：16 位图集同时持两份像素 = 12 字节/像素。

**JPEG**：熵编码段**先按 RST 切分**再逐区间建位读取器 —— 单一位流 +"读着遇到标记就跳过"
是这类解码器最常见的错源（缓冲里预读了几位、标记位置对不上，于是错位一位、整幅变噪点，
而且**不抛错**）。渐进式 AC 精修写成显式状态机（0/1/2/3/4），EOBRUN 必须按
"包含当前块"计数（`(1<<run) + receive(run)`，块尾统一减一）—— 写成 `(1<<run)-1`
时 `run=0` 会得到 0，本块剩余非零系数的修正位一个都不读，位流从此错位。
截断检测用**结构性判据**（熵数据是否以 EOI 收尾），不是数"补了多少个 0 位"：
位读取器会预读，完整的 `restart-prog-420` 因 24 个区间各多读十几位而补 470 位，
而截到 90% 的文件只补 246 位 —— 用补位数当阈值两个方向都会判错。
详见 [ADR-0009](adr/0009-jpeg-decoder.md)。

**动画时间轴**（`render/animation.ts` + `render/sprite-animator.ts` + `render/anim-module.ts`）：
`AnimationClip` 是**共享只读数据**（数组冻结），`sampleClip` 是纯函数，
播放进度 `timeMs` 存在 `SpriteAnimator` **组件**上（每实体一份，可存档）。
图集**不持计时器** —— 否则同一素材在两个世界播放会互相干扰：这是这层的唯一硬约束。
零时长帧按"累积起点"跳过（不除零），`loopOverride` 放实例上（同一素材可"只播一次"）。

真实语料结果：3422 / 3423 解码成功；唯一失败的是 `_out/_cmp_pair.png`（源文件本身只有一半扫描线），
解码器**拒绝返回半张图** —— 这正是它该有的行为。

**图集合成**（`extensions/render/atlas-from-assets.ts`）：

- 确定性 shelf packing：高度降序 → 名字升序（用 `<` 而非 `localeCompare`，后者依赖 locale）
- 输出尺寸向上取整到 2 的幂；空白填**全透明**（填黑会在精灵边缘留下黑边）
- padding 只做**帧间**、不做外边距（否则单帧的 UV 永远不是 0,0,1,1）
- `maxSize` 超限报 `ASSET.ATLAS_TOO_LARGE` 并点名帧（2048² 拼成 8192² 会直接 OOM）

**为什么不用 `createImageBitmap`**：颜色空间与预乘 alpha 会与导入期解码不一致。
两条路径同时存在 ⇒ "编辑器里对、游戏里偏色"。只保留一条，浏览器也走同一份解码器。

**闭环如何被验证**：`tests/core/asset-gpu-roundtrip.test.ts` 把四段接成一根链条 ——
磁盘真文件 → 导入管线 → `db.load` → `decodeImage` → 合成图集 → `createTexture`，
然后比对 **null 后端收到的字节摘要**与"解码 + 合成产出的 RGBA8 摘要"。
两条反例（改一个字节摘要必变 / 程序化图集摘要与资产图集不同）保证它不会假绿。
`web/assets/` 现在是 **5 PNG + 1 JPEG**，所以这条链同时覆盖两种格式 —— 全 PNG 的清单
只能证明 PNG 通路在跑。另外单独一条判据断言"JPEG 帧在图集里的区域不是全黑"
（只有帧表没有像素时摘要判据照样绿）。


---

## 6. 生命周期

### 6.1 启动

```
GameApp.create(options)
  ├─ 建 Logger / MemorySink / EventBus / ServiceRegistry
  ├─ createPlatform({ registry, prefer?, allow? })
  │    ├─ registry.create('gfx')   → probe → priority 最高的可用后端
  │    ├─ registry.create('audio'|'input'|'fs')
  │    └─ 任一失败 ⇒ 已建的后端**逆序 destroy**，返回聚合错误
  └─ 提供 Services.Scene / Scheduler / Assets，注册模块（不启动）

app.start()
  └─ ModuleRegistry.start()
       ├─ topoSort()：缺依赖 / 有环 ⇒ **启动前**就拒绝（不是跑到一半才发现）
       ├─ 按拓扑序 init（失败 ⇒ 已 init 的**逆序回滚**）
       └─ 按拓扑序 start
```

**"失败回滚"是必须的**：一个缺了渲染模块的引擎看起来在跑，实际是黑屏 ——
比直接报错难查十倍。所以代价是"启动要么完整成功，要么完全回到原点"。

### 6.2 每帧

```
ITickSource.frame(realDt)
  └─ GameApp.frame(realDt)
       ├─ scheduler.advance(realDt) → N 个固定步
       │    └─ 每步：step 回调 → world 模块 → scene.step(tick, dt)
       │         （scene.step 内部两次 flush，见 §5.2）
       ├─ 丢步则发 scheduler:steps-dropped
       └─ 发 frame:end（诊断/埋点）
```

**模拟与渲染解耦**：模拟固定步长，渲染按帧率，用 `scheduler.alpha` 插值。
所以 30Hz 的模拟在 60/144Hz 屏幕上不抖，也不会因为渲染慢而改变世界演进。

### 6.3 停止与释放

```
app.dispose()
  ├─ stopRun()（先停帧源：不许在释放过程中还在推进世界）
  ├─ ModuleRegistry.dispose()：**逆序** stop → dispose，单个失败不阻断其余但会上抛
  └─ DisposableBag.dispose()：逆序释放 platform / services / log sink
```

逆序的理由：资源有依赖方向（纹理依赖设备、管线依赖着色器、模块依赖服务）。
正序释放会释放"还在被用的东西"，症状是**随机的空指针**——最难查的一类。

---

## 7. 扩展机制

### 7.1 四类扩展点

| 扩展点 | 接口 | 注册方式 | 加一个需要改哪里 |
|---|---|---|---|
| **子系统** | `IModule` | `options.modules.push(m)` | 只加一个新文件 |
| **后端** | `IGraphicsDevice` / `IAudioDevice` / `IInputDevice` / `IFileSystem` / `IScriptRuntime` | `registry.registerGfx(...)` / `registerScript(...)` | 只加一个新目录 + 一行注册 |
| **组件** | `Component` + `ComponentSchema` | `components.register(schema, factory)` | 只加一个新类 |
| **资产源导入器** | `SourceImporter` | `importers.register(i)` | 只加一个新类 |
| **资产加载器** | `IAssetLoader` | `assets.registerLoader(l)` | 只加一个新类 |

### 7.2 "新增功能要改哪里"（可扩展性的可检验形式）

| 需求 | 改动 | **不需要改** |
|---|---|---|
| 加一个"饥饿值"组件 | 1 个新文件（schema + 字段） | Scene / Component 基类 / 序列化 |
| 加一个"物理"子系统 | 1 个 `IModule` + 1 个 `IPhysicsWorld` 接口 | GameApp / Scene / Scheduler |
| 换个渲染后端到 WebGPU | 1 个新目录 + 1 行注册 | core/** 全部 |
| 加一种资产类型（如 `anim`） | 1 个 `IAssetLoader` | AssetDatabase |
| 加一个存档字段 | 组件 schema 加一行 + 一条 migration | 序列化器 |
| 加一个"暂停时也要跑"的子系统 | 模块内部自己订阅 `ITickSource` 而不订阅 `scheduler` | Scheduler / Scene |

最后一条值得解释：**"暂停"是模拟层的概念，不是引擎的全局开关**。
UI 动画、音频、录像在暂停时仍应活动 —— 所以它们是不同的消费方，各自选择订阅谁。
如果 `GameApp` 提供一个全局 `paused` 标志并且所有模块都读它，那么"暂停时 UI 要动"
就得在每处特判，那就是耦合。

### 7.3 扩展点必须遵守的规则

1. **只能依赖接口**（L4 不许 import L5 的具体实现，`arch` 规则 4 会红）。
2. **不许改内核**（如果为了加功能必须改 `src/core/**`，说明扩展点设计错了 —— 这应当是设计评审的硬门槛）。
3. **新后端必须过契约测试**（`runGfxContract("webgl2", …)` 一行接入）。
4. **新模块必须声明 `deps`**（不声明等于"我不在乎顺序"，而实际上几乎总在乎）。

---

## 8. 确定性设计（饥荒风格的命门）

《饥荒》风格的核心承诺是"**同一个种子 ⇒ 同一个世界**"。四条机制：

| 机制 | 实现 | 违反的症状 |
|---|---|---|
| 时间唯一真相 = 整数 tick | `FixedStepScheduler`，`time = tick × fixedDt` | 回放不同步、物理穿墙 |
| 所有随机走注入的 `IRandom` | `XorShift128`，状态可序列化 | 同种子不同世界（上一代真实踩过） |
| 结构性修改有序 | `Scene` 命令队列，帧边界 flush | 遍历期改表 ⇒ 跳过/重复 |
| 序列化字节确定 | `Schema`：字段序 + 量化 + NaN 标记 | "存档能读"但两份不同 |

**机器守护**：`arch` 规则 3 禁止 `Math.random()` / `Date.now()` / `performance.now()`
出现在 `core/**` 与 `runtime/**`。这不是风格洁癖 —— 上一代引擎的"同种子不同世界"
就是一句 `math.random()` 造成的，而它**不报错**，只是让所有判据只能靠容差。

**缺口（诚实标注）**：`LongUpdate`（跳时间时一次性结算）尚未实现，
所以"存档 → 离线 8 小时 → 读档"这段会**不结算**腐烂与计时器。
这是饥荒风格必须补的下一块（§12 阶段 2）。

---

## 9. 与 Unity / Cocos 的对照

| 能力 | Unity | Cocos Creator | 本项目 | 差距 |
|---|---|---|---|---|
| 世界模型 | GameObject + Component | Node + Component | **Node + Component**（组件按类型集中存储） | 一致 |
| 变换层级 | Transform（父子 + 世界/局部） | Node（父子 + TRS） | `Node`（局部 TRS + 惰性世界变换 + 版本缓存） | 无脏标记传播到兄弟；够用 |
| 主循环 | PlayerLoop（可变步长 + FixedUpdate） | 固定步长 director | **固定步长 + 追帧上限 + 幂等 tick** | 一致（且多了幂等保护） |
| 渲染抽象 | RHI（多后端）+ SRP | `gfx::Device`（多后端） | `IGraphicsDevice`（多后端，2 个实现：null / WebGL2） | 缺 WebGPU；SRP 级管线自定义未做 |
| 资产身份 | `.meta` + GUID | `.meta` + UUID | `AssetId` + `.meta` sidecar + 依赖图 + 增量导入 | 一致（缺按类型导入设置 UI） |
| 脚本 | C#（Mono/IL2CPP） | TS（JSB 原生绑定） | `IScriptRuntime` + Lua 5.4（wasm）+ 最小反射表 | **语言版本是 5.4，DST 内容层是 5.1**；无调试器 |
| 序列化 | `[SerializeField]` + 反射 | 组件 `_serialize` | `ComponentSchema` 声明式 + 迁移链 | 一致（无反射，更快） |
| 编辑器 | Editor（独立进程 + PIE） | Creator（独立 + 预览） | `extensions/editor/` + `web/editor.html`（批63–91：场景树 / 属性 / 撤销 / 多场景 / 工程落盘 / PIE，103 条自检） | 缺资源导入向导与内置调试器 |
| 构建发布 | 多平台打包 | 多平台 + 小游戏 | 微信分包（4MB 三重预算）+ Steam VDF 生成 + `--strict-api` 闸门（批79/128）；小游戏产物 `format: iife` | **最大缺口**：Steam 真上传要凭据（B1）、微信上传要 appid/私钥 |
| 确定性回放 | 需额外工程 | 不支持 | 架构已为此设计（tick/随机/命令） | **本项目更强** |
| 判据与守护 | 无统一判据 | 无 | 61 条 + 6 条架构规则 + 后端契约 | **本项目更强** |

### 9.1 刻意不同的三处（不是缺陷，是取舍）

1. **不做 ECS 双世界**（ADR-0001）：Unity 的 DOTS 与 GameObject 是两套并行模型，
   代价是"这个实体在哪套里"成为每个新功能的第一个问题。我们只做一套，但要它的性能收益。
2. **不做反射**：Unity 的 `[SerializeField]` 靠反射，启动慢且 AOT 受限。
   我们用显式 `schema`（声明式，无反射），代价是"加字段要写两处"（字段 + schema），
   收益是"序列化顺序确定 + 编辑器能生成控件 + 没有反射的启动开销"。
3. **确定性是一等公民**：Unity/Cocos 都不保证跨平台确定性（浮点、物理、随机）。
   我们把它当作硬约束，因为目标玩法（饥荒风格）需要"同种子同世界"与"可回放判据"。

---

## 10. 工程质量如何被保证

### 10.1 四层测试

| 层 | 内容 | 数量 | 文件 |
|---|---|---|---|
| **架构守护** | 依赖方向、平台泄漏、环境随机、组合根唯一性、目录分类 | 7 | `tests/arch/layers.test.ts` |
| **后端契约** | 同一套用例跑**两个**后端（null + webgl2/fake） | 22 | `tests/contract/gfx.contract.ts` |
| **WebGL2 专属** | 顶点属性布局、状态缓存、program 状态重放、编译失败、帧外提交 | 9 | `tests/contract/webgl2.test.ts` |
| **单元/集成** | 调度器 9 · 场景 8 · 模块 7 · 资产 9 · 序列化 10 · 渲染 13 · 物理 12 · 存档 13 | 81 | `tests/core/*.test.ts` |
| **最小宿主** | 整条链（平台→模块→场景→步进→诊断） | 1 | `samples/headless.ts` |
| **浏览器自检** | 真实浏览器里 9 条端到端断言（画面/批处理/存档往返） | 9 | `web/selftest.html` |

本表只统计 **L0–L3 核心子集**，行内数字相加为 **120 条 Node 判据 + 9 条浏览器自检**；
含扩展解码器（PNG/JPEG/资产导入）与文件系统的全量是 2475 条 <!-- n:tests -->，全部在 `npm test` / 打开自检页里跑；
`npm run check` 额外跑 `tsc`（strict + noUncheckedIndexedAccess）。

### 10.2 为什么"架构守护"比多写功能更重要

因为**架构不会因为一次错误就崩，它会因为一百次"这次特殊"而崩**。
`arch` 规则 1 的全部实现就是一张"层允许依赖哪些层"的表 + 一次 import 扫描 ——
30 行代码，但它让"半年后还能说清谁依赖谁"成为可能。

同理，契约测试的价值在于：**接口的歧义会在写第二个后端时暴露，而那时已经在线上**。
所以第一个后端（Null）就必须过全部契约。

### 10.3 测试里刻意保留的"反向用例"

每条正向断言旁边都有一条"如果实现写错会怎样"：
- 越界上传**必须失败**（真后端会静默画错）
- 循环依赖**必须点名环**（不是栈溢出）
- `init` 失败**必须回滚**（不留半启动）
- 已销毁句柄**必须失败**（不许写进别人的槽位）
- 录制结束后提交**必须被拒**（否则画面滞后一帧）

这些用例在本轮开发中**真的抓到了一个缺陷**：依赖环的错误被包装成"依赖失败"，
导致调用方无法区分"缺资源"与"依赖图成环"（处置完全不同）。修法是让根因错误**透传**。

### 10.4 15 道闸门 <!-- n:steps --> 与"闸门定义在哪"

一条命令：`node tools/ci.mjs`（`npm run ci`；`--fast` 跳过三个慢步骤）。

★ 下表**与 `node tools/ci.mjs --list` 逐行对应**，编号就是执行顺序。
`tools/docs-check.mjs` 会核对标题里的步数（`n:steps`），所以这张表不能悄悄多一行或少一行。

| # | 闸门 | 挡住什么 | 为什么必须自动化 |
|---|---|---|---|
| 1 | 类型检查 `tsc`（strict + `noUncheckedIndexedAccess`） | 类型层的不可能状态 | 人眼看不见"这里可能是 undefined" |
| 2 | 判据（全量，2475 条 <!-- n:tests -->） | 行为退化 | 上一代引擎的判据从未被一次跑完过 |
| 3 | 物理性能闸门（**独占**跑） | 解算耗时退化 | 并行跑时测到的是"机器多忙"，不是"代码多慢"（阈值仍是 8ms，一个字没动） |
| 4 | 覆盖率闸门 | "新代码没有任何判据走过" | 百分比能被平凡代码堆出来，所以守的是**未覆盖行清单**不许变多 |
| 5 | 文档对账 | 判据数、变异数、后端数、步数写成过期值；**缺口清单里点名了已经在 CI 里跑的工具**（= 把做完的事记成待办） | **实测：这一批一次喊出 14 处漂移，人眼一处都没发现**。批97 起还管「清单对账」：`§六` 的缺口行若点名了某个 `tools/` 路径，而那个工具**已经在 CI 里跑**，就要人说清是"做完了没划掉"还是"点名点错了工具"（`tools/gap-check.mjs`，带合成的过期行做反向自检）。**批102 起还管阻塞清单**：`docs/BLOCKERS-*.md` 的每条数据行必须单行、点名的路径必须存在、状态落在 ✅/⛔/🔜/❌ 四种里，且**每条 ✅ 必须给一条逐字可核的证据**（行内一句「…」要能在它引用的文件里原样找到 —— 判据被删或文件改名就红）。`tools/blockers-check.mjs` + 12 条判据（含反向自检与接线判据） |
| 6 | 拒绝路径审计 | 写了却永远不生效的 `fail()` | "这条检查从没被触发过" = 等于没写 |
| 7 | PNG 语料校验 | 解码器在真实语料上退化 | 自造样本只能证明"能解我造的样本" |
| 8 | JPEG ffmpeg 金标 `--check` | 与参考解码器逐像素的偏差 | "看着像"不是判据，**逐像素**才是；金标存在文件里才能被 diff。**三分退出码**：0 一致 / 1 真漂移 / 2 异构构建（见下） |
| 9 | JPEG 金标三分自检（4 种情形） | 第 8 步把"构建不同"当万能免罪符 | 没有它，真把编码器改坏了、恰好又在异构构建上跑，一样被放过去 |
| 10 | 浏览器包构建 | 打包/`--experimental-transform-types` 在浏览器目标上失效 | Node 里跑得通不等于能进浏览器 |
| 11 | 小游戏包构建 + 结构断言（`tools/wx-check.mjs`） | 产物只在真机上炸的那几件事：被打成 ESM（`Unexpected token 'export'`）、混进 `require("node:fs")`、构建成空壳、每次构建字节不同 | `tools/build-wx.mjs` 的 `platform: "neutral"` 全部价值是「node 依赖在**构建期**就爆」，而构建期只在有人手跑时发生 ⇒ 没有这一步，那条设置保护的是一条没人走的路。覆盖 15 秒的整轮里它占 0.6 秒 |
| 12 | 浏览器端自检（无头 CDP 驱动，56 条 <!-- n:browser -->） | 页面级问题（DOM 缺节点、`fetch` 绑定、GL 拒绝） | Node 判据只能证明"我们发了什么调用"，不能证明浏览器接受；**缺浏览器时标 ⊘ 跳过，不算通过** |
| 13 | 编辑器页自检（无头 CDP，103 条 <!-- n:editor -->） | 编辑器坏而运行时好（或反过来） | 与第 12 步分开，红的时候要一眼看出该谁修 |
| 14 | 跨宿主存档比对 | Node 与浏览器写出的存档字节不同 | 存档要能在两个宿主之间迁，字节不同就悄悄迁移失败 |
| 15 | 变异校验（815 组 <!-- n:mutants -->） | **判据本身失效**（改坏了还是绿的） | 这是唯一能证明"判据有牙齿"的手段 |

★ 第 8 步的**适用域**（2026-10-25 实测，写清楚免得下次又当 bug 查）：
金标是**某个具体 ffmpeg 构建**的产物 —— 本机生成它的是 `7.1-essentials_build-www.gyan.dev`。
CI 上 `pip install imageio-ffmpeg` 装的是 Linux 构建，对 12 位灰度（`gray12-*`）解出的**字节**
与之不同（5 例漂移，`gray8-*` 与 `rgb48` 全部逐字节一致），但**两边与源都差 ≤ 容差**、语义一致。
所以跨构建时退出码 2（环境不适用）并打印逐样本最大差；**只有当差值超出该例容差时才判 1**。
判据本身（`tests/extensions/jpeg-ffmpeg-gold.test.ts`）不依赖 ffmpeg，读的是入库金标，覆盖不受影响。

★ **跨进程读档**不是独立步骤，它跑在第 2 步的判据里（`save-cross-host` / 子进程读档用例）。
单列出来的话会让人以为"CI 有 11 步"，而 `--list` 说是 10 步 —— 两个数打架时以脚本为准。

★ 步骤定义在 `tools/ci.mjs` 里，`.github/workflows/ci.yml` 只负责调用它。
理由：写在 YAML 里的步骤只能在 GitHub 上验证，本地就是一段没人执行的配置 ——
一旦挂了只能看日志猜。"CI 挂了能本地复现"比"CI 看起来专业"重要。

★ 矩阵跑 **Windows + Linux**：本仓库今天就被一条平台差异咬过 ——
`fs.rename` 到正被打开的目标在 Windows 上返回 `EPERM`，POSIX 允许覆盖。
单 OS 的 CI 会把这种差异留到用户机器上。

---

## 11. 当前状态

### 11.1 已完成

- L0 全部（result / math / log / event / memory / time / random）
- L1 全部接口（gfx / audio / input / fs / net / **script**）+ `BackendRegistry`
- L2 全部（module / services / scene / node / component / scheduler / asset / schema）
- L3 全部（GameApp / tick-source / snapshot）
- L5 后端：`gfx-null`（记录型）/ `gfx-webgl2` / `audio-null` / `audio-webaudio` /
  `input-null` / `input-dom` / **`input-injected`（宿主已量好的设备，批128）** /
  `fs-memory` / **`fs-node`（真实盘 + 沙箱 + 原子写）** /
  **`script-null` / `script-lua`（Lua 5.4 via wasmoon）**
- L4 扩展：2D 渲染管线（相机/精灵/程序化图集/批处理/渲染模块）、2.5D 物理、
  **脚本模块（每 tick 串行驱动 + 异常隔离 + 最小反射表）**、
  **资产导入（`.meta` 身份 + 增量 + 依赖 + 产物加载器）**、确定性存档、跳时间结算、
  **世界生成（整数噪声 → 群系 → 架桥修复 → 指纹 + 连通性校验，见 §11.4）**、
  **AI 行为树 + `IModule` 接线（纯数据树 + 注册表行为 + tick 计数 + 异常隔离，见 §11.5）**、
  **构建发布（闭包 + 内容寻址分包 + 可复现 manifest，见 §11.6；纯函数，尚无 CLI）**、
  **UI 与位图字体（BMFont 解析 / 纯函数排版 / 三模式视口 / 锚点+流式布局 / 九宫格控件 / 捕获+冒泡，
  与 2.5D 世界共用一次 pass，见 §11.7）**
- 内容层四块（本轮补齐）：
  **Lua 5.1 兼容垫片**（`unpack`/`loadstring`/`setfenv`/`module()`/`math.*` 等，见 §5.4）、
  **per-module `_ENV` 隔离**、
  **PNG 全格式解码**（纯 TS inflate + 5 种反滤波 + 调色板 + **Adam7** + **APNG** + **16 位全精度**，
  真实语料 3422/3423，隔行/16 位/APNG 由 pngjs + Pillow 双实现金标闭环）、
  **JPEG 全格式解码**（13 个 SOF：基线/扩展/渐进/无损/差分 × Huffman/算术 · DCT 类 8/12 位
  · 无损类 2..16 位 · 分层 DHP+EXP+差分帧 · 任意采样 + 三角上采样 · DRI/RST · 灰度/YCbCr/RGB/CMYK/YCCK
  · EXIF 方向 · 截断标记；金标＝Pillow 容差 17 例 + 1420 例网格扫描 + 算术/哈夫曼各 6 例（我们编码→libjpeg 解码）
  + liblj92 无损 3 例逐样本相等，见 ADR-0009）、
  **16 位进 GPU**（`PixelFormat.RGBA16` + 图集 `precision` + WebGL2 `RGBA16/UNSIGNED_SHORT`）、
  **动画时间轴**（`AnimationClip` 只读数据 + 组件持时间 + 纯采样，图集不持计时器）、
  **真实资产上屏**（导入 → 解码 → 确定性图集合成 → `createTexture`，浏览器读 `web/assets/` 5 PNG + 1 JPEG）
- **2475 条 Node 判据** <!-- n:tests -->（161 个测试文件 <!-- n:files -->）+ 56 条浏览器自检 <!-- n:browser -->，架构守护 7 条，
  后端契约 22 条（两图形后端）+ 14 条（两脚本后端）
- 变异验证 **815 组** <!-- n:mutants -->（异常隔离 / id 空间 / 增量 hash / env 隔离 / Paeth / 像素上传 / 5.1 unpack /
  Adam7 pass 表 / pass 宽度 / APNG blend / APNG dispose / 16 位取整 / APNG 帧数校验 /
  渐进 AC 精修 EOBRUN / 重启区间 DC 复位 / 三角上采样 / 截断标记 / EXIF 旋转 /
  QM 的 Switch_MPS / 双线性单侧钳位 / 无损差分取模 / DC 类别上限 / 精度规则 / EXP 位置 /
  12 位电平位移 / 分层相位取模 / 算术编码初值随 Pt / 无损预测器 / 原子写 / 真实路径越界 / `..` 拒绝 …，
  完整清单见 `tools/mutation-check.py`），全部被抓住
- 最小宿主跑通（150 tick / 5 秒 / 750 次组件更新 / 脚本调用 150 次 / 半径误差 0）
- 浏览器宿主跑通（`web/index.html`：WASD 移动、H 砍树、F5/F9 存读档、**Lua 驱动浆果漂浮**、HUD 显示脚本统计）
- 小游戏宿主跑通（批128：`host/demo-game.ts` + `src/wx-entry.ts`）—— 同一份装配换四件套，假 wx 在 Node 里装出一整局（`platformId === "wx"`、推两帧 `tick > 0`、触摸真的让玩家动了、存档落到 `wxfile://usr/saves/slot1.json`；UI 读不到则 `DEMO.NO_VISIBLE_HUD` 起不来），产物 `node tools/pack.ts --platform wechat --strict-api` 退出码 0 —— **批129 起这条结论由 CI 第 11 步守着**（`tools/wx-check.mjs`：构建两次验逐字节可复现 + IIFE / 零 ESM / 零 node 内置 + 打包扫描；在此之前它只是「我手跑过一次」）。**真机只剩一层**：帧源 / 触摸 / 文件系统行为像不像（与 B1 同源）

### 11.2 未完成（按优先级）

| 项 | 影响 | 预计落点 |
|---|---|---|
| ~~`fs-node` 后端~~ | ✅ 已支持（2026-10-23）：沙箱 + 原子写 + 跨进程读档判据；契约与 `fs-memory` 同源 | 已完成 |
| 逐字节存档的**跨宿主自动化**比对 | headless 侧已两条实例互证；浏览器侧仍需手工导出（无浏览器自动化能力） | 阶段 2.5 |
| ~~Adam7 隔行 PNG~~ | ✅ 已支持（2026-10-22）：七个 pass 独立反滤波、sub-byte 按 pass 重新打包；外部金标见 ADR-0008 | 已完成 |
| ~~APNG（动态帧）~~ | ✅ 已支持（2026-10-22）：`decodeApng` 输出合成后的整幅帧 + 时长 + 循环；`buildAtlasFromApng` 拼成 sprite sheet | 已完成 |
| ~~16 位色深~~ | ✅ 解码已支持（2026-10-22）：`pixels` 用 `round(v/257)` 降采样，`keep16` 给全精度 `pixels16` | 已完成 |
| ~~16 位进 GPU~~ | ✅ 已支持（2026-10-22）：`PixelFormat.RGBA16` + 图集 `precision` + 后端按格式上传；16 位图集 12 字节/像素 | 已完成 |
| ~~JPEG~~ | ✅ 已支持（2026-10-22）：SOF0/1/2、任意采样、重启、灰度/YCbCr/RGB/CMYK/YCCK、EXIF；见 ADR-0009 | 已完成 |
| ~~JPEG 的 12 bit / 算术编码 / 无损 / 分层~~ | ✅ 已支持（2026-10-23）：13 个 SOF 全实现、DCT 类 8/12 位、无损 2..16 位、分层合成；证据等级（哪些有外部金标、哪些只有自洽回环）逐项写在 ADR-0009 ⑥ | 已完成 |
| JPEG 分层与 SOF11 的**外部**验证 | 没有第三方实现能做（libjpeg 移除 `hier_code`、`lossless+arith` 直接 NOTIMPL），只有自洽回环 + 结构判据；这是本模块最大的证据缺口 | 无法消除，已在 ADR-0009 里标明 |
| JPEG 分层参考帧上采样的**相位** | 规范给了"双线性"和示意图，没给可执行的取整规则；本实现取 3:1 权重 + 边界钳位，编码器用同规则独立实现 | 记录为实现选择，不冒充规范结论 |
| JPEG 色度上采样的"多实现差异" | 我们与 libjpeg 的三角滤波同族但不是同一个实现，单通道差 max≤6（实测 ≤3 居多） | 记录在 manifest 的容差里，不假装逐字节一致 |
| ~~`unloadModule` 清不掉 `module()` 写进 `_G` 的表~~ | ✅ 已修（2026-10-23）：`module()` 记录"我新建了哪几张表"，卸载时按**身份**（`parent[key] == 记录的表`）摘除；容器只在变空时摘，别人接管过的键不动。三条判据 + M58/M59/M60 | 已完成 |
| 按类型的导入设置（过滤/打包参数） | `settings` 恒为 `{}` | 阶段 4（编辑器） |
| ~~`IPhysicsWorld`（2.5D：XZ + AABB/圆 + 空间哈希）~~ | ✅ 已支持：`query` 与暴力枚举完全一致（含漏格/密集堆叠/静态体）；**性能闸门已补**（2026-10-23）：2000 实体 / 现实布局 median **0.29ms** < 8ms，且带"空转判据"与"退化配置必须更慢"两条分辨力判据。★ 这条闸门加进来当天就抓出两处 O(n²)：`maxRadiusNearby()` 在内层循环里每体每迭代扫全场、`reindex()` 每次遍历所有格找 id —— 修掉后 2.77ms → 0.74ms → **0.29ms**（2026-10-24 格宽自动定之后）。
★ 但"修好了"当时**没有判据**：三处加起来只值 ~2ms，而预算 8ms，退回去依然全绿。批47 换成**工作量计数**
（`stats().bodyScans / maxRangeScans / cellScans`）后立刻抓到第一处根本没修干净 ——
`maxRadiusNearby()` 的注释写着 O(1)，代码仍是全场 `for`，缓存 `maxRange` 一直维护、**没有任何地方读它**。**密集布局 11ms 超预算的账已在批53（T338）还清**：根因不是「推挤对数」，而是**格宽默认值 4 与实体尺寸无关**（半径 0.3 的实体被塞进「每格 40 个」的粗桶，一次查询要白扫上百个候选）。改成「格宽 = 2 × 全场最大 range」之后密集布局 **4.97ms**；推挤工作量本身仍是密度的性质（5853 次/步、每步都有未解重叠），如实记在 `tests/core/physics-perf.test.ts` 文件头 | 已完成 |
| ~~连续碰撞（CCD）~~ | ✅ 已支持（批100，[ADR-0013](adr/0013-continuous-collision.md)）：`physics/sweep.ts` 是**纯函数**扫掠（精确解 = 放大盒四条边 ∪ 四个角圆；起点已重叠 ⇒ `t = 0` 且这一拍不动；滑动只去掉法向分量、路程恒 ≤ 原长），`IPhysicsWorld.sweepMove` 只回答不改位置、只扫静态体，`ai/move` 的 `sweep` 接线把每拍夹在接触点前（挡住不推进游标、不宣布到达）。26 + 3 条判据、15 组变异。**批124 补上「动态障碍」这一侧**：生物与玩家都长**动态体**（`isStatic: false`），而**动态体不进扫掠** —— 它们是会走开的，扫掠只回答「会不会跨过一去不回的东西」；静态体也**不每帧重插**（位置增量重分格已覆盖）。两个只在实操里才暴露的前提：① 生物体是**每拍维护**的不变量（`syncBodies`，读档 `physics.clear()` 之后要能自己补回来）；② **装饰摆件必须同时进导航**（`NavGrid.blockCells`，只封不解封、且要作废连通分量标号），否则怪会正对着树心顶、净位移 0 | 已完成 |
| ~~`IWorldGenerator`（群系图 + 连通性校验 + 世界指纹）~~ | ✅ 已支持（2026-10-23）：整数噪声 + 架桥修复 + 规范化指纹 + 连通性校验（含"能报红"的反向判据）；**装配成真实场景**（可反查、可存档往返）；**世界任务表**（tick 驱动、跳时间不爆刷）已接进模块系统并真正 spawn 实体。见 §11.4 | 已完成 |
| ~~AI（行为树 + 模块接线）~~ | ✅ 已支持（2026-10-23）：纯数据树 + 注册表行为 + tick 计数 + 真 `FixedStepScheduler` 驱动 + 异常隔离，见 §11.5；状态机未做（不打算另做一套） | 已完成 |
| 编辑器（独立进程 + PIE） | 最大缺口 | 阶段 4 |
| ~~构建发布核心（闭包 + 内容寻址分包 + manifest）~~ | ✅ 已支持（2026-10-23）：两条出口判据都成了判据，见 §11.6；**CLI / 落盘 / 与导入管线接线未做** | 核心完成，工程化待做 |

### 11.3 已知风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| **两套引擎并存** | 仓库里已有 `07-通用引擎`（Python+Lua+JS，32k 行，274 判据） | 明确 `08` 是内核重构目标；`07` 短期内作为**行为参照**与判据来源，不并行演进功能 |
| **内容层绑定** | 153 万行 Lua 来自 DST（Lua 5.1），而 wasmoon 是 **5.4** | 已做 5.1 兼容垫片（§5.4）：`setfenv`/`module()`/`unpack`/`math.*` 均可用。**残留风险**是"垫片覆盖不到的 5.1 行为"——比如 `module()` 写进 `_G` 的表清不掉、`setfenv(level)` 未支持（内容层用法为 0）。真跑内容层时按报错逐条补，不在没有样本前预先实现 |
| **确定性与浮点** | JS 的 `Math` 跨平台基本一致，但 `Math.pow/exp` 等不保证 | 序列化层已量化；物理与 AI 避免超越函数（用查表/定点） |
| **单后端长期存在** | 只有一个后端时接口歧义不会被发现 | 契约测试 + Null 后端作为"第一实现"强制覆盖语义 |

---

### 11.4 世界生成（`src/extensions/worldgen/`）

阶段 3 的第三条出口判据。两个文件 + 一个 L0 工具：

| 文件 | 职责 | 为什么单独拆出来 |
|---|---|---|
| `foundation/canonical.ts`（**L0**） | 规范化序列化 + 内容指纹 | 指纹能不能比，全看这里。混在生成器里就没法单独验"键序/浮点/静默降级"这几种漂移。★ 起初放在 `worldgen/` 下，做阶段 5 的发布清单 hash 时发现**它跟世界无关**，于是提到 L0 —— 两份副本才是真正要避免的 |
| `worldgen.ts` | 整数噪声 → 群系 → 架桥修复 → 投放点 | 生成逻辑 |
| `validate.ts` | 连通性、投放点位置、分量统计 | **校验必须能验"别人给的计划"**，塞进生成器就只是自证 |

**四条承重设计**：

1. **坐标一律定点整数**（`FIXED_UNITS = 256`，2 的幂）。浮点一旦进指纹，格式化差异就会变成
   幽灵漂移；`canonical.ts` 遇到非整数/非有限值**直接报错**，不四舍五入 ——
   四舍五入会把"我引入了浮点"这件事藏起来。
2. **噪声全程整数运算**：双线性插值的每一项都是"整数 × 整数"，除以 `G*G` 用 `Math.floor`。
   于是"同种子同世界"在**位级别**成立，不只是"大概一样"。
3. **`cliff` 故意不可通行**：不做这个，地图永远是整块陆地，连通性校验永远绿 ——
   一条永远绿的校验等于没有校验。判据里用 `repair:false` 主动造出"到不了的陆地"，
   校验器必须报出来（M80 专门钉这条：桥只计数不改地形 ⇒ 判据红）。
4. **投放点 id = `格子下标 * maxSites + 序号`**，不是全局自增。
   全局自增的失败模式是"中途加一个格子，后面所有 id 平移，存档里的引用全部指错东西"
   （上一代引擎在节点 id 上踩过，见 `random.ts` 文件头）。

#### 装配：`WorldPlan` → 真实 `Scene`（`assemble.ts`）

`WorldPlan` 是纯数据，不能 `step`、不能存档、不会被渲染。`assemble.ts` 补上"最后一公里"，
并让"同种子 ⇒ 同世界"这句承诺**从数据层延伸到场景层**：

| 决定 | 理由 |
|---|---|
| 地形**贪心合并成矩形**，不逐格建节点 | 64×64 就是 4096 个节点 + 4096 次组件虚调用；群系成片，合并后通常只剩几十~几百块。合并规则写死（行优先扫描、先向右扩到边界再向下扩、向下只检查这 w 列）⇒ 仍然确定 |
| 坐标换算 `x / 256` | 256 是 2 的幂 ⇒ 二进制浮点里**无舍入**，`node.localPosition.x * 256 === site.x` 是恒等式。判据用 `===` 断言（换成 `/1000` 立刻红） |
| 节点 id **自动分配**，`site.id` 记在组件 `siteId` 里 | 节点 id 是**运行期身份**（装配顺序决定），`siteId` 是**内容身份**（跨存档/跨地图稳定）。混用会丢局部性；而且 `spawn(id)` 会把分配水位顶到 `id+1`，装配完一张大地图后新节点 id 会跳到七位数 |
| 组件挂载走 `scene.attach` + `flush` | `byType` 索引只在 flush 里建立。直接 `node.attach()` 会得到"节点上有组件但 `componentsOf` 查不到"的场景，**只在查询时**暴露 |
| 装配前重算指纹比对 | 别人给的计划（存档/编辑器手改/旧 schema）必须能被识别，否则会被"忠实"装配成错世界 |
| 拒绝非空场景 | 两个世界的 `siteId` 空间重叠，"这棵树属于哪个世界"说不清 |
| 返回 `rasterizeTerrain()` 反查 | 合并算法的三种错误（漏格/重叠/越界）画面上都看不出来：重叠会被后画的盖住，越界会被裁掉。所以三者**各自独立计数** |

★ 抓到自己的一条假判据：`sceneComponents()` 第一版用 `area.passable ? kind : "ocean"` 拼网格，
再交给 `findComponents()`（它内部又查一次群系表）。于是"passable 写死成 true"被**抹平**了 ——
海格标成可通行，`findComponents` 又按群系表判回不可通行，分量数一点没变，判据全绿。
现在改成直接用布尔栅格做 BFS：输入只有场景字段、输出只有分量数，中间没有第三条路；
另有一条交叉判据断言它与 `findComponents(plan.kinds)` 给出同一个数（两份实现漂移时先红这条）。

#### 出生点（`pickSpawn`）："能不能玩"的最后一环

规则三条，全部写死：**只在主分量里选** → 取"到最近不可通行格或地图边缘的四连通步数"最大的格 →
**平局取格子下标最小**。

| 决定 | 理由 |
|---|---|
| 只在主分量里 | 出生在走不到主大陆的小岛上，这局白开 —— 而地图看起来完全正常 |
| 用"离不可通行格的步数"而不是"离地图中心" | 岛形地图的中心经常正好是悬崖或海；"宽敞"才是玩家能感知的性质。多源 BFS 一次算完，O(格子数) |
| 平局规则写死 | 全可通行地图上"最宽敞"的格子是一整片。不指定平局规则，结果就取决于遍历顺序 —— 而这种失效**只在某些种子上出现** |
| 地图边缘也算源 | 一次不可通行格都没有的手改地图（编辑器里画一片草地）会让距离全是 `-1`，选出来的会是"第一格"。把出界也算一步之后，"离边缘多远"是同一条规则的推论，没有特例分支 |

★ 这条判据被变异逼着改了一次：真实种子的地图上"最宽敞的格"几乎总在主分量里，
所以"出生点必须在主分量内"**抓不住**"不限主分量"的实现（M127 第一次跑就是假绿）。
要让它有分辨力，必须构造"非主分量更宽敞"的形状（环 276 格 / 方块岛 81 格：
环是主分量但余量只有 2，岛不是主分量却余量 4）。**判据的分辨力要靠输入的形状来保证，
不是靠断言的措辞。**

#### 出生落地（`spawn.ts`）：把"哪一格"变成"站在那儿"

`pickSpawn` 是纯函数（只回答"哪一格最适合开局"），落地是场景侧的事 —— 分开放的理由是
**选错格**与**落地错位**是两种失效，判据长得完全不一样。

| 决定 | 理由 |
|---|---|
| 坐标取**格子中心**（`cx*256+128`） | 与资源投放同一套定点约定：256 是 2 的幂，`(cx+0.5)*256` 在二进制浮点里无舍入，于是 `position.x*256 === cx*256+128` 是**恒等式**。用左上角的话玩家永远贴着格子左边站，看起来像"差半步" |
| 重复出生报 `SPAWN.ALREADY_SPAWNED` | 两套玩家叠在一起 = 两个控制器抢同一个位置，而两边的判据各自都绿 |
| 组件没注册就报错，不建节点 | 否则会出现"其它系统都找得到他、画面上没有他"的玩家 |
| 先 `spawnAt` 再挂组件、最后一次 `flush` | 与任务模块同一条纪律：`spawn` 只是入队，`byId` 索引要 `flush` 之后才成立 |

**出口判据**：定点恒等式（位置 = 格子中心）/ 出生格 = `pickSpawn` 的结果 / 出生格可通行 /
`render.sprite` + `world.player` 两样都在 / 重复出生报错且不多节点 / 缺组件报错且不留节点 /
两张独立场景的 id 与出生格相同 —— 7 条，M146–M149 各钉一边。

#### 全链路：十一批拼接起来跑，抓到一个"两段各自都对"的缺陷

各段都有判据，但它们**从来没有在一条链上一次跑过**。补上之后立刻抓到一处：

> 装配完的世界能算内容指纹；**一挂上视觉就算不出来了** —— `render.sprite` 的
> `r/g/b` 是 0..1 浮点（群系着色就有 `0.55`），内容指纹要求"同值同串"，于是
> `CANON.NOT_INTEGER`。两段各自都只验自己那一半，谁都没错。

修法不是把浮点量化（那会让每次改配色都改内容 id），而是让指纹**排除 `render.*`**：

| 决定 | 理由 |
|---|---|
| 指纹排除呈现层 | 世界指纹回答"这一局的世界长什么样"，换美术风格不该让内容 id 全失效 |
| 同时钉一条反向判据 | 改 `world.site.kind` 必须让指纹变 —— 否则"排除 render"可能排除过头 |
| 全链路判据单独存在 | 两次独立装配指纹相同 / 存档往返指纹不变 / 读档后可见化**纯跳过** / 跳时间只刷 1 批 |

★ "读档后可见化纯跳过"这条第一次写就差了 1（514 vs 515）：`skipped` 只数可视化桥
**管的**节点，而玩家也是 `render.sprite` —— 差的那一个正是玩家。判据把这件事写清楚了
（`before === managed + 1`），而不是把数字改到能过。

#### 存档往返：一个"两处各自选精度"的真 bug

给装配补存档往返判据时，`sceneDigest()` 立刻报 `CANON.NOT_INTEGER`。查下去是：

| 环节 | 用的精度 |
|---|---|
| 世界坐标 | `FIXED_UNITS = 256` ⇒ `1/256 = 0.00390625`（**8 位十进制小数**） |
| 存档量化 `q()` | `Math.round(v * 1000) / 1000`（**3 位**） |

于是装配出来的 `7.26953125` 存成 `7.27`，反推 `7.27 × 256 = 1861.12`（原本 1861）。
症状隐蔽到极点：挪了 1/2000 格，肉眼看不出、手感看不出，**只有内容指纹或逐字节比对才看得见**。
这和"UV 翻转写到两处 = 一次都没翻"是同一类错误：**同一个精度约定出现在两个地方，就一定对不上**。

修法选 **1e-9**（9 位）：

| 候选 | 结论 |
|---|---|
| 十进制 6 位 | 装不下 8 位，还是错 |
| 2 的幂（1/65536） | 对定点精确，但 `1.387` 会变成 `1.3870086669921875` —— 存档立刻不可读 |
| 不量化（写原值） | 精确，但把 `9.999999999999984`（累加出来的）与 `7.7e-15`（5 秒后剩的）写进存档，逐字节比对变脆 |
| **1e-9** | ✅ 能精确表示 1/256（留 1 位余量）；粗于 double 的 ulp ⇒ 把 ulp 级噪声收干净；十进制量化不给十进制值留尾巴 |

★ 这条量化有一个**跨层约束**：只对 `FIXED_UNITS ≤ 512` 的定点精确（`1/1024` 是 10 位小数）。
分层规则不许 L2 依赖 L4，所以这个约束**没法用类型表达**，由
`tests/extensions/assemble-io.test.ts` 里的一条守卫判据钉住 —— 谁把定点单位改大，那条先红。

#### 世界任务表（`tasks.ts`）

世界生成是一次性的；世界里长期发生的是"每隔一段时间做一件事"（资源再生、季节切换、群系回填）。
这张表就是那个"每隔一段时间"。**四条承重决定**：

| 决定 | 理由 |
|---|---|
| 表是**纯数据**（`{id, periodTicks, phase, biomes, picksPerRun}`） | 允许写函数就存档不了、比对不了、编辑器改不了 —— 而这三件事正是任务表唯一需要的。判据直接断言整表能过 `canonicalize`，塞函数报 `CANON.UNSUPPORTED` |
| 只吃 **tick**，不吃秒/墙钟 | 秒随帧率变，墙钟让"暂停"和"回档"产生分歧 |
| ★ 一次推进里**每个任务最多跑一次**，漏掉的次数由 `missed` 报出 | 若按"补齐"写，跳 1000 tick 会让 `period=10` 的任务连跑 100 次（每次 spawn/写存档/发事件）—— 离线 8 小时回来地图直接刷满。判据跑两遍同样的时间跨度，`stats().runs` 必须是 100 vs 1 |
| 随机由 **(任务 id, 首次到期 tick)** 派生 | 连续流会让结果依赖"表里的位置"和"别的任务跑了几次"，插一个任务就改变所有其它任务的产出 |

★ 抓到自己的一条设计错误（写变异时才发现的）：第一版把 `run`（第几次执行）也混进 seed。
两个问题：① 它让"同一 tick 的产出"依赖**执行历史** —— 读档重建实例后 `run` 从 1 重新数，
同一个 tick 会刷到另一批格子，可重放性当场失效；② `firstTick` 严格单调递增，`run` 在它之外
不带来任何新信息——**删掉 `run` 也无法被任何判据抓住**。一条抓不住对应变异的判据等于没写，
反过来说：一个无法被区分的设计元素也不该留在关键路径上。`run` 因此降级为纯诊断字段。

#### 任务模块（`task-module.ts`）：把触发落到场景里

`tasks.ts` 只回答"什么时候该做"；这一层回答"做出来的东西在场景里长什么样"。
三个只在**多轮之后**才暴露的错误，各有一条判据：

| 错误 | 为什么难发现 | 对策 |
|---|---|---|
| **同格叠刷** | 叠在同一位置的精灵只显示最上面那个，画面上完全看不出，只有 `countOf` 一路涨 | 去重按**格子**（不是按任务），索引在首次使用时**懒建** |
| **跨组件重复** | 计划自带的 `world.site` 与再生的 `world.resource` 是两种组件，只看一种就会盖在已有的资源上 | 去重集合里两种都扫（判据 M122 钉它） |
| **只增不减** | 世界里没有"资源被采走"的模拟，任务表于是成了一条单调增长曲线 | 全局上限 + `skippedCap` 如实计数（不静默丢弃） |

★★ 一条必须说清的语义区分：**逐 tick 推进 ≠ 跳时间**。

| 路径 | 发生什么 | 刷几批 |
|---|---|---|
| `scheduler.advance(33 秒)` 逐 tick 回调 | **真的模拟了 1000 步** | 100 批（正确！） |
| 一次 `update(1000, ·)` | 跳到 tick 1000，漏掉的由 `missed` 报出 | 1 批 |

把这两条混为一谈，就会得出"离线 8 小时回来地图被刷满"是 bug 的结论 ——
可它其实是**宿主选错了推进方式**。判据里两条都跑，把区分钉死。

★ 另一个真实发现：`maxSitesPerCell = 2` 时计划几乎铺满每一格可通行格
（seed 7 / 32×24 有 882 个投放点），于是再生**一个都不刷**。那是对的（去重生效），
但"跑到了没刷"必须与"没跑到"区分开 —— 所以有一条判据专门验
`fires === 1 && spawned === 0 && skippedExisting === 4`。

#### 采集闭环（`harvest.ts`）：一次操作要改**两块**状态

在它之前世界里只有"长出来"，没有"被拿走"，所以任务表是一条单调增长曲线，
只靠一个全局上限兜底。而"资源采不走"在画面上**完全看不出来** —— 资源就一直在那儿。

★★ 采集必须同时改两块状态，只做一半就是两类静默 bug：

| 只做了一半 | 现场表现 | 谁能发现 |
|---|---|---|
| 只销毁节点、不释放名额 | 这片林子砍空之后**再也不长**（那一格永远被去重索引判定为"已占用"） | 只有闭环判据（M152）；只验"节点没了"的判据完全无感 |
| 只释放名额、不销毁节点 | 树**砍不掉**，砍完数量不减 | 只有"组件/节点真的消失"那一条（M151） |

所以 `harvestAt` 收一个 `onRelease` 回调而不是自己持有索引：世界的名额归 `task-module` 管，
采集不该知道去重索引的内部结构。**测试两条都验**，宿主两条都接。

| 决定 | 理由 |
|---|---|
| 回调在**销毁并 flush 之后**才调 | 销毁是不可逆的，任何校验必须在它之前；而"没真的摘掉节点"时不该释放名额 |
| 先找再生资源，再找计划投放点 | 存档可以伪造出"同格两种都有"，此时摘"后长出来的那个"；两种都摘会一次调用删两个节点 |
| 格子下标先校验 `Number.isInteger(v) && v >= 0` | 否则 `-1` / `1.5` 会落进"这一格没东西"，调用方听到的是"本来就空"，永远查不出是自己坐标算错（M153） |
| 上限按 **`alive`** 而不是累计 `spawned` | 按累计数算的世界"越玩越荒"：采走也不腾名额。`stats()` 同时给 `spawned` / `alive` / `released` 三个数，判据才分得清"刷过"与"还在" |
| `releaseCell` 返回 `boolean` | "这一格本来没占用"是正常情况，不是错误；但 `alive` 不许减成负数 |
| **见底才销毁**（`count` 归 0），不是采一次就销毁 | 批122 起一个节点是一**堆**（`ResourceMarker.count`）。没见底就销毁的症状是剩下的一起消失、名额提前还回去（再生会在同一格再长一个）；一直不销毁的症状是那格永远采不光。两个方向都得同时读 `left` / 节点数 / 名额才分辨得出 |
| `amount` 是**这一次的上限**，不是这一格的产量 | 产量在节点**出生那一刻**由 `WorldTaskModuleOptions.yieldOf` 冻进 `count` —— 采摘时再查表的话，改一次配置会把地上**已有**的资源一起改掉（玩家昨天看到的那棵树今天变成 3 个木头），而只验“新长出来的”判据全绿 |

★★ **`count` 的默认值只能写在类初始化器里**（`ResourceMarker.count = 1`），不能写进 `schema.defaults`，更不能靠类型零值：`Component.load` 的顺序是「实例已有值 → `schema.defaults` → 零值」，而零值 0 在采摘语义里是一个**空堆** —— 既采不动、也不会被销毁（见上表第一行），于是「打开旧档 ⇒ 所有资源都变成采不动的装饰」。这类错误只在打开旧档时出现，新写的判据一条都不会红；所以它由一条端到端判据钉住：真存档 → 删掉 `count` 字段 → 读回来是 1 **且采得动**。

#### 采集的下游：物品与背包（`src/extensions/inventory/`）

`harvestAt` 只回答"这东西没了"。**"玩家得到了什么"不能塞进世界生成** ——
世界要能脱离玩家单独生成、被多个玩家共用、被存档回滚；一旦它认识背包，
"生成一个世界"就会要求"有个玩家"。

| 决定 | 理由 |
|---|---|
| **一个堆叠 = 一个节点 + 一个 `game.item` 组件** | 一张节点上每种组件只能挂一个，所以"若干堆叠"要么塞进一个字符串字段（存档不可读、编辑器不可见），要么就是子节点。选子节点：每堆是一等公民，能单独销毁 |
| 加物品**先合并再新建** | 否则砍 100 次树得到 100 堆"1 个木头"，`maxStacks` 第 9 次就报满 —— 而玩家只捡了一种东西 |
| 取到 0 就**销毁节点** | 与采集的"名额释放"同一个道理：空壳占着名额，现场表现是"背包满了但里面没东西" |
| 组合层（`harvest-into.ts`）单独一个文件 | 让 worldgen 依赖 inventory 会把"世界"绑死在"玩家"上 |

★★ 顺序是硬约束：**先看（`peekResourceAt`）→ 再进包 → 最后摘**。
反过来时背包满了会把资源摘下来又丢不掉 —— 画面上树倒了、所有计数自洽、
玩家什么都没拿到。这类"东西凭空消失"没有任何异常可看，只能靠一条反向判据守住（M166）。

#### 可见化桥（`src/extensions/render/world-visuals.ts`）：从"有数据"到"画得出"

装配与任务模块造出来的是**逻辑**节点：有位置、有组件、能查询，但渲染模块只认 `render.sprite`。
这个文件是两者之间唯一的桥。**放在 render 而不是 worldgen**，因为方向是"渲染认识世界数据"，
反过来的话世界生成就要依赖一套图形术语 —— 而生成必须能在无渲染环境里跑（指纹、批量出图、判据）。

三个静默失效，各钉一条判据：

| 失效 | 为什么不会被任何东西发现 | 对策 |
|---|---|---|
| **缺帧** | 渲染模块对不存在的帧名是 `warn` + 跳过（那是对的，它不该为一个坏资产停掉整帧）⇒ 画面少一类东西，退出码 0 | 入口把"缺帧"**升级成错误**，并列出"哪个帧被哪些种类用到"；检查在**动场景之前**做，报错时不留半个场景 |
| **不幂等** | 同一节点两个 Sprite，半透明贴图颜色深一倍，看起来像"贴图颜色不对"；组件数只是静默翻倍 | 按**节点**判断是否已有 Sprite（不是 `countOf > 0`），跳过的计入 `skipped` |
| **幂等写成"有一个就全跳过"** | `countOf(SPRITE_TYPE) > 0` 读起来完全像是在检查"挂过没有"；而且"跑两次不重复挂"这条判据**抓不住它**（第二次确实全跳过） | 专门一条判据造"存档里已有一半可视化"的场景：`skipped === 2` 且其余照挂（M132） |

★ 版本漂移的一个小坑：旧存档里可能带着本版本不认识的 `SiteKind`，此时 `SITE_FRAMES[kind]`
是 `undefined`。直接拿它当 Map 的键，报错会变成「undefined（被 site:ancient_tree 用到）」——
缺的是**映射**不是帧，拿到日志的人会去翻图集。所以显式用「未映射的种类」占位（M137）。

#### 地形可见化：`pivotX` 与"灰度底 + 群系色"

地形节点是**矩形**（w×h 格），位置是矩形左上角的格子坐标。而精灵原先只有 `pivotY`，
永远以节点位置为**水平中心** —— 一块 8×5 的地形要么整体右移半块，要么就得把节点位置改成
矩形中心（那会破坏「地形节点位置 = 格子坐标」，连带破坏反查与存档往返）。所以：

| 决定 | 理由 |
|---|---|
| 加 `Sprite.pivotX`（默认 0.5） | 与 `pivotY` 对称。默认值 0.5 = 与"只有 pivotY"时的行为完全一致，旧内容显示不变 |
| 地形用 `pivotX = 0, pivotY = 0` | 矩形左上角 = 节点位置，恰好覆盖 `[cx, cx+w) × [cz, cz+h)`。用 0.5 会让相邻块之间出缝，而缝隙在 2.5D 斜视角下看起来像地表裂开 |
| 一帧**中性灰** + 顶点色 | 一张灰度图 × 8 个群系色 = 8 种地貌。底色若是草绿，海会变成"绿 × 蓝 = 墨绿"—— 而这种错法看起来还挺自然，没人会想到是基色错了 |
| 灰度亮度取 ~0.8（不是 0.5） | 它是**乘子**：0.5 的基色会把草色压成夜里；0.8 时 `0.8 × 群系色 ≈ 群系色`，调色板写什么就看起来是什么 |
| 一块矩形 = **一个**精灵 | 合并后的块通常几十~几百个。按格平铺是 4096 个节点，且需要材质级 UV 重复参数（不是 `Sprite` 该管的字段）—— 代价是噪点被拉伸，照实记在 backlog |

★★ 这一批还逼出两处"判据看不见的错法"，都值得单独记：

1. **搬运丢字段**：`Sprite → RenderItem` 原来是 `renderFrame` 里的一段对象字面量。
   漏掉 `pivotX` 时，组件判据绿（组件上是对的）、batch 判据绿（batch 支持 pivotX）、
   画面却错位。修法不是放松标准，而是把搬运抽成 `spriteToRenderItem`，让**中间那一行可测**。
   变异 M139 就是先"没被抓住"、抽出函数后才被抓住的。
2. **schema 演化把旧档压坏**：`Component.load` 原先对缺字段填**类型零值** ——
   旧存档里没有 `pivotX`，读回来是 `0`，所有已有精灵右移半格，而新存档完全正常。
   改成「缺字段**保留实例上的值**（类初始化器就是出生默认值）→ `schema.defaults` → 零值」。
   这类错误只在"用户打开旧档"时出现，也就是**永远不会在开发机上出现**（M143 / M144 各钉一边）。

**出口判据与状态**：

| 判据 | 状态 |
|---|---|
| 同种子两次生成指纹相同（含架桥记录），且与事后独立重算一致 | ✅ 4 条 |
| 不同种子 / 不同尺寸给出不同指纹 | ✅ 2 条 |
| 键序、浮点、`null`、`undefined`、类实例、超安全整数 一律报错并给路径 | ✅ 9 条 |
| `repair=true` 不存在到不了的陆地 | ✅ 8 个种子 |
| `repair=false` 能造出不可达陆地，**且校验器报红并给出位置** | ✅ 反向判据 |
| 群系成片（孤立可通行格 < 5%） | ✅ |
| 投放点在可通行格、不越界、id 落在本格号段 | ✅ 3 条 |
| 装配后地形**覆盖完全、无重叠**，逐格群系与计划相同 | ✅ 30 条（含棋盘/单色两块极端形状） |
| 装配结果可反查：漏格 / 重叠 / 越界 **各自**计数并能报红 | ✅ 反向判据 3 条 |
| 同计划装配两次：节点 id / 名字 / 层级 / 位置 / 组件数据全同 | ✅ `sceneDigest` 一条断言 |
| 计划被改过（指纹不符 / 长度不符 / 群系名未知）⇒ 拒绝装配且不动场景 | ✅ 3 条 |
| 非空场景 / 组件未注册 ⇒ 拒绝且不留半个世界 | ✅ 2 条 |
| 存 → 读 → 再存：内容指纹相同、逐字节相同、定点坐标逐点精确 | ✅ 11 条 |
| 存档被改坏（漏一行 / 越界）⇒ 反查报出漏格或越界 | ✅ 反向判据 2 条 |
| 任务表：周期与相位命中、tick 不许倒退 | ✅ 28 条 |
| ★ 任务表：跳时间**每个任务只跑一次**且 `missed` 如实报出（100 vs 1） | ✅ 反向判据 |
| 任务表：纯数据可序列化、重名/越界/未知群系报错、选格过 `isPassable` | ✅ |
| AI（行为树 + 模块接线） | ✅ 42 条，见 §11.5 |
| 2000 实体 30Hz 解算 < 8ms（现实 **0.29ms** / 密集 **4.97ms**；加闸门时是 2.77ms / 11ms） | ✅ 4 条（空转判据 / 单桶必须更慢 / 密集也进预算 / 显式粗格必须更慢） |
| ★ 闸门自己抓出的三处"与全场体数成正比"的开销：`maxRadiusNearby` 每体重算、`reindex` 全格扫描、`resolve` 遍历静态体 | ✅ 已修（2.77ms → 0.74ms） |
| ★★ 这三处**用"次数"守住**（毫秒抓不住：0.74→2.7 仍在 8ms 预算内） | ✅ 7 条（M160–M162） |
| ★★ 计数第一天就抓到一处真缺陷：`maxRadiusNearby()` 注释写 O(1)、代码是全场 for，缓存 `maxRange` **从没被读过** | ✅ 已修（解算期间全场扫描 6000 次 → 0） |
| 密集布局（每格 4 个、数学上解不开）**4.97ms < 8ms**；剩下的是推挤对数本身（5853 次/步） | ✅ 已进预算（T338：格宽跟实体尺寸 + 每对每轮只处理一次） |
| 任务表接进模块系统：真 `FixedStepScheduler` 驱动 + 真正 spawn 实体（去重 / 上限 / 生命周期） | ✅ 17 条 |
| 出生点：在主分量内、余量最大、平局取最小下标、全海图报 `WORLD.NO_SPAWN` | ✅ 8 条（含"环 vs 岛"构造图） |
| 出生落地：位置 = 格子中心（定点恒等式）、可通行、两样组件都在、重复出生报错 | ✅ 7 条（M146–M149） |
| 全链路：两次独立装配指纹相同 / 存档往返指纹不变 / 读档后可见化纯跳过 | ✅ 6 条（M150） |
| ★ 内容指纹排除 `render.*`（呈现不影响世界 id），改世界内容必须改指纹 | ✅ 双向判据 |
| 逐 tick 推进与跳时间推进的语义区分（100 批 vs 1 批） | ✅ 两条对照判据 |
| 可见化：投放点与再生资源都挂上 `render.sprite`，帧名来自 `SITE_FRAMES` | ✅ 14 条 |
| ★ 缺帧 ⇒ 报错且**不动场景**；未映射种类报「未映射」而不是 `undefined` | ✅ 反向判据 2 条 |
| ★ 幂等按**节点**判断（存档里已有一半可视化时，其余照挂） | ✅ 反向判据（M132 只有它能抓） |
| `SITE_FRAMES` 的每个值都在**真**程序化图集里（换图集时的闸门） | ✅ 2 条 |
| 地形进渲染：每块尺寸 = w×h、锚点 (0,0)、颜色 = `BIOME_TINT[kind]` | ✅ 5 条（含"块数远小于格数"） |
| 地形帧缺失 ⇒ 报错且不动场景 | ✅ 反向判据 |
| ★ 搬运不丢字段（`spriteToRenderItem`，M139 没抽出函数前抓不住） | ✅ 1 条 |
| ★ 旧存档缺 `pivotX` ⇒ 读到 0.5（不是 0）且缺字段被报出 | ✅ 2 条（M143 / M144） |
| 地形的噪点被拉伸（一块矩形一个精灵，没有 UV 重复） | ⬜ 已知粗糙处，记在 backlog |
| 采集：节点被销毁 + 名额被释放（两块状态同时变） | ✅ 9 条（M151 / M152 各钉一半） |
| ★ 上限按 `alive` 算：采走之后原来被上限挡住的那批又能刷 | ✅ 反向判据（M155） |
| `releaseCell` 在没占用的格子上返回 `false` 且 `alive` 不变 | ✅ 1 条（M157） |
| 采集报错（空地 / 非法下标）时**场景一点都没动** | ✅ 反向判据 2 条 |
| 背包：同种物品**合并**成一堆、取到 0 **销毁节点**（空壳不许占名额） | ✅ 11 条（M164 / M165） |
| ★★ 采集 → 背包的顺序是**先看 → 再进包 → 最后摘**：背包满时报 FULL 且资源还在原地 | ✅ 反向判据（M166） |
| ★ 长跑 300 轮「刷 → 全采」：节点数**回到基线**、`alive` 归零、`spawned === released`、用过的格子全空 | ✅ 4 条（M158 只有它抓得住：destroy 排了命令但没 flush） |
| 不采集 500 轮：`alive` 停在 `maxResources`、节点数 = 基线 + 上限、`skippedCap > 0` | ✅ 1 条 |
| 同一格连采 100 次：只成功 1 次，账目与节点数不再变 | ✅ 1 条 |
| 同 seed 同操作序列两次运行：账目与节点数逐字相同（采集路径无不确定性） | ✅ 1 条 |
| ★ 索引格数 `occupied` 与 `alive` 对账（两套状态同步改） | ✅ 3 条（`stats().occupied` 读的是索引本身，不是用账目推账目） |
| ★ 资源**已在场景里**才建索引（读档路径）：一格都不该被盖上去 | ✅ 1 条（M159 第一次跑没被抓住 —— 既有判据里没有这条路径） |


### 11.5 AI 行为树（`src/extensions/ai/behavior.ts`）

阶段 3 的最后一条。单文件，两个决定撑起全部判据：

| 决定 | 理由 | 判据怎么验 |
|---|---|---|
| **树是纯数据**（`kind/id/op/children/ticks`），行为靠 `op` 名在注册表里查 | 树要能存档、能由编辑器导出、能进世界指纹 —— **函数不能序列化**。与物理的 `PositionAccessor`、脚本的反射表是同一个取舍 | 树 JSON 往返后行为一致；`step` 5 次后树的 JSON 快照逐字节不变 |
| **决策吃 tick，不吃 dt** | dt 会让"同种子同世界"在 AI 上失效（丢一帧就换个决定）；饥荒式玩法不需要亚 tick 精度 | 把 `tick` 跳成 0/1000/100000，`wait(3)` 仍恰好需要 3 次 `step` |

**最容易写错的一处：记忆必须挂在 agent 上，不能挂在树上。**
挂在节点对象上时，两个共用同一棵树的 agent 会互相踩，而且**只有多个 agent 同时存在时才暴露** ——
单 agent 的判据永远抓不到。所以判据里必有一条"同一棵树、两个 agent、互不干扰"（M83 钉这条）。

**`running` 是唯一带记忆的状态。** `success`/`failure` 都会清掉记忆 ⇒ 下一轮从头开始。
于是"承诺"有了精确定义：**只有还在 running 的动作会被续上**，已成功/失败的分支不会反复执行。
验法不是读代码，而是数 `do` 被调用了几次。

**构造期校验**（坏树在构造时报，不等跑到那一支才炸）：未注册的 `op`、重复 `id`、
子节点数不对、`ticks` 非非负整数、深度 > 64（数据里藏环时表现为 `AI.TOO_DEEP` 而不是栈溢出）。

| 出口判据 | 状态 |
|---|---|
| sequence / selector 的短路语义（失败/成功后不再往下跑） | ✅ 5 条 |
| `running` 的记忆与续跑（用调用次数验，不看内部字段） | ✅ 3 条 |
| `wait` 吃 tick 不吃 dt、`wait(0)` 当场成功、一轮结束会重来 | ✅ 5 条 |
| 两个 agent 共用一棵树互不干扰 / `reset` 清记忆 | ✅ 2 条 |
| 树是纯数据（JSON 往返、`step` 不改树） | ✅ 2 条 |
| 构造期五类坏树各自报对码 | ✅ 6 条 |
| **`IModule` 接线 + 真调度器驱动**（`ai-module.ts`） | ✅ 5 条 —— 用真的 `FixedStepScheduler` 驱动，验证"每步恰好一次 / 暂停不动 / dt 乱跳不影响决策 / 驱动顺序 = spawn 顺序" |
| 异常隔离（一个 agent 的 op 抛异常不拖垮整个 tick） | ✅ 2 条 —— 计数 + `reset()` 后从根重来（M95/M96 钉住） |
| 状态机（另一种 AI 形态，与行为树并存） | ⬜ 未做 —— 行为树已够用，暂不新增实现 |

### 11.6 构建发布（`src/extensions/build/publish.ts`）

阶段 5 的第一条，也是**唯一一条先把出口判据写死再实现**的地方：两条判据直接决定实现形态，
不是"参考了一下"。

| 出口判据 | 逼出来的设计 |
|---|---|
| ① 删掉一个**未被引用**的资产后，产物**逐字节不变** | 产物只含**入口闭包**，绝不是"目录里有什么就打什么"。反过来也保护了"往目录里丢草稿不会让线上包变" |
| ② 改动一个资产只重打**一个**包 | 按内容分片 + **包名 = 内容 hash**。改一个资产只让含它的包换名，其余包名不变 ⇒ CDN 缓存不失效 |

**四个"不做就会静默出错"的细节**：

1. **包内每条资产带 framing**（`[u32 idLen][id][u32 dataLen][data]`）。
   直接拼接有歧义：`{x:"ab",y:"c"}` 与 `{x:"a",y:"bc"}` 拼出来都是 `abc`，
   于是两个**不同**的资产集合得到**相同**的包名 —— 内容寻址当场失去意义（M91 钉这条）。
2. **manifest 里没有时间戳/构建号**。有了它们"同输入同产物"永久不成立，
   而**可复现构建**是"这条产物确实是这份源码打出来的"的唯一证据。要追溯就打 git commit。
3. **缺依赖报错，不静默跳过**（`BUILD.DEP_MISSING`）。跳过会产出一个"少了东西但能上线"的包，
   错误推迟到玩家手里才暴露。
4. **manifest 自身 hash 走 `canonicalize`**。这份数据的键序恰好是写死的，所以用
   `JSON.stringify` 今天看起来一样 —— 但一旦有人从 Map 重建对象，指纹就随键序漂（M92 钉这条）。

**落盘层**（`tools/build-assets.mjs`）：CLI 只做"读目录 → 调 `buildPublish` → 写目录"，
不含任何构建逻辑（逻辑在纯函数里，已被判据覆盖）。输出目录只有 `manifest.txt` 与 `<hash>.pack`，
**没有时间戳、没有构建号**。11 条判据在**磁盘层**把两条出口判据重验了一遍
（比文件名集合与每个文件的字节），并额外钉住三件事：

- 重复构建到同一目录**不留旧包**（先把输出目录清空 —— 残留的旧包会让"产物没变"变成假象，M99）；
- `.meta` **不进产物**（它是导入期输入；打进包会让"改导入设置"也改变玩家要下载的字节，M101）；
- `.meta` 解析失败**报错**，不当成"没依赖"混过去。

**已知缺口（不掩饰）**：

- 与真实资产库的接线仍没做：CLI 的 `--src` 是普通目录，`.meta` 里的 `dependencies`
  按**相对路径**理解（与 `AssetMeta` 的 `AssetId` 不同）。导入管线实际产出的资产还没喂进来。
- 压缩（gzip/brotli）、按类型分包、资源去重都没做。
- 没有"增量发布"：每次都全量重建。判据只证明"改一个资产只重打一个包"，
  没证明"只上传一个包"（那需要远端状态）。

### 11.7 UI 与位图字体（`src/extensions/ui/` 13 文件 4936 行 + `src/host/` 2 文件 1035 行，批116 实测）

起因是一次自检发现的反常：这个引擎**一处文本渲染都没有**
（`grep -rn "fillText\|BitmapFont\|drawText" src/` 0 命中），而宿主的 HUD 与背包面板是**手写 DOM**。
于是"游戏里的界面"从来不是引擎画的 —— 换宿主（Node / 编辑器预览 / 未来原生）界面就整体消失，
而且 DOM 面板和世界渲染**无法共享一次合成**（一个在 canvas 外，一个在 canvas 里）。
这一节记的是六层怎么切、以及三条被误解会静默出错的约定。

**分层与依赖方向**（每层都能在 Node 里单测，因为**底下四层完全不碰 GPU**）：

| 层 | 文件 | 职责 | 依赖 |
|---|---|---|---|
| 字体 | `font.ts` | BMFont 文本格式解析 + `FontRegistry` | 无 |
| 双向 | `bidi.ts` | UAX #9：`embeddingLevels` / `reorderLine` / M1 镜像查询（纯函数） | 无（数据表 `bidi-tables.ts` 由 UCD 生成） |
| 排版 | `text-layout.ts` | `layoutText(font, text, style)` → quads/宽高/行数/截断；`direction` 一开即按段落过 bidi，行级重排 + 镜像 | 字体／双向 |
| 视口 | `viewport.ts` | 设计坐标 ↔ 屏幕像素；`fit`/`fill`/`expand` | `Camera2D`（core） |
| 布局 | `layout.ts` | 锚点 + Row/Column/Grid 流式 + 命中链（+ 自然尺寸注入口） | 视口（只读数） |
| 自撑开 | `intrinsic.ts` | 文本量算 → `contentSize`；绘制与量算**共用**换行宽 | 字体/排版/布局 |
| 状态 | `state.ts` | 跨帧状态表：派生（文本量算）与权威（滚动偏移）分开失效 | 排版（只取类型） |
| 控件 | `widgets.ts` | 九宫格 + 7 种控件 → `RenderItem[]` | 字体/排版/布局/状态 |
| 事件 | `events.ts` | 指针 → 捕获/click/冒泡 | 布局（命中） |
| 接线 | `ui-module.ts` | `IModule`：建 pipeline、挂 overlay、脏标记重排 | 以上 + gfx |

**① 与 2.5D 世界集成：共用一次 pass，只换一个相机。**

渲染模块上加了 `setOverlay(fn)` 钩子，在 `cmd.finish()` **之前**调用。所以 UI 与世界的
`draw` 落在**同一个 pass、同一个 `SpriteBatch`** 里，区别只有两个：
用的是 `UiViewport` 里那个**纯 2D `Camera2D`**（`zoom = scale`、`tiltY = 1`），以及
`layer = UI_LAYER`。于是"UI 盖住世界"不靠调 z 值，而靠**同 pass 内后画** ——
这同时消掉了一个必然会踩的坑：另开一个 pass 就要 `clear`，而 `clear` 会把世界擦掉；
不 `clear` 又会在下一帧留下上一帧的残影。`overlay` 抛出的异常被吞进日志（UI 画崩不该让整帧丢）。

**② 位图字体：`xadvance` 不是 `width`。**

BMFont 里 `xadvance` 是**下一个字起点**与当前字起点的距离，`width` 是**墨迹矩形**宽。等宽字体里
前者含字间距、后者不含；用 `width` 当前进量会让宽度从第二个字开始系统性偏小（而首字对得上，
所以"看起来只是间距怪"）。同理 `yoffset` 是**相对基线**、向上为负，不是相对行顶。
UV 用**恒等映射**（`u0 = x/scaleW, v0 = y/scaleH`），与 T330 那条教训一致：
`texImage2D` 收像素数组时第一行就落在 `v = 0`，再"翻一次"就是镜像（`§11.1` 里那次一整天的排查）。
10 个错误码（`UI.FONT_*`）覆盖缺 `common` / 坏 `scale` / 重复字形 / 越界 / 坏 `xadvance`，
**不做容错兜底** —— 字体坏了要在加载期炸，不是在屏幕上缺几个字。

**③ 排版：量出来的宽度必须与画出来的宽度同源。**

没有独立的 `measure()` 函数，宽度是排完 quads 之后量出来的。否则"量"与"画"是两条代码路径，
迟早分叉（分叉的表现是文字溢出边框，而两条路径各自的判据都绿）。
断行规则：英文在空格后可断、中文在汉字后可断（`U+2E80–9FFF` / `F900–FAFF` / `3000–303F` / `FF00–FFEF`），
超长无断点则**硬断**，且**每行至少留一个字**（否则零宽字符或空行会让循环不前进）。
省略号裁字是"先按行裁到能塞下 `…` 为止"，不是"先裁再补 `…`"。

**④ 坐标与缩放：三模式的区别只在锚点贴谁。**

| 模式 | `scale` | 锚点参考矩形 | 用途 |
|---|---|---|---|
| `fit` | `min` | 设计框 | 保证整块设计框可见（会留边） |
| `fill` | `max` | 设计框 | 填满屏幕（会裁掉边缘） |
| `expand` | `min` | **屏幕** | 屏幕更大的地方，锚在边缘的控件要跟着贴边 |

`expand` 若也贴设计框，"扩展"这件事根本不存在（屏幕范围永远小于设计框或相等）。
第一版就是这么写错的，是判据 `expand.anchorRect.width > 960` 把它红出来的 ——
**判据写的是"扩展应该发生"，不是"代码现在做了什么"**，这条区别就是判据与镜像的分界。
另外 `scale` 的定义是**绘制像素 / 设计像素**（含 dpr），不是 CSS 像素比；
`safeRect` 双向夹取，安全区超过屏幕一半时**不产生负尺寸**。

**⑤ 事件：按下锁定，click 要"同目标且没怎么动"。**

按下时把目标锁进 `downTarget`，抬起投给它而**不是**当前命中点 —— 否则手指从按钮上滑出去再回来，
就永远点不中（这是移动端最常见的"按钮失灵"）。`click` 的判定是
**同一目标 且 位移 ≤ `dragThreshold`（默认 8）**；只看"抬起了"会把拖动误判成点击。
冒泡沿父链向上、遇 `stopPropagation` 停。`opaque` 与 `interactive` 是两个语义：
`opaque` 可见且**挡住点击**（模态遮罩就靠它：遮罩本身不接收点击，但下面谁都收不到），
`interactive` 才是接收。

**⑥ 可复用性 / 扩展性：新增一个控件要改哪里。**

对照 §7.2 的判据，答案是"一个 switch 分支 + 一个 skin 字段"：
`UiWidget` 加一个成员 → `widgets.ts` 的绘制分支 → `skin` 里加帧名。
**不需要改**字体、排版、视口、布局、事件任何一层 —— 它们只认 `Rect` 和 `UiNode`，
不认"按钮"或"进度条"。这是这套分层唯一值得声称的可复用性，也是它的边界：
滚动容器、拖拽、输入框这类**需要跨帧状态**的控件，得先在 `UiNode` 上开状态位，
不能靠"每帧重建 quads"糊过去。

**⑧ 跨帧状态位：派生与权威分开（批99，[ADR-0012](adr/0012-ui-crossframe-state.md)）。**

四个缺口（富文本/避头尾/RTL、滚动容器、标签自撑开、补间属性轨道）卡在同一个前置决定上
（批105 之后只剩富文本/避头尾/RTL 一件；滚动容器的上限、夹取与写回都在布局层，输入在路由层）。
决定本身只有三条：

- **状态不进 `UiNode`、不进存档**，放 `UiStateStore`，键是 `uid`（构造时分配、从不复用）
  —— 于是"旧节点的状态被新节点读到"在结构上不可能，不靠清理纪律。
- **两类状态的失效时机不同**：派生（文本量算）可以随时丢，权威（滚动偏移）丢了就是丢了。
  所以有两个入口 —— `invalidateDerived()`（字体热重载用）与 `reset()`（换界面/回滚用），
  而不是一个 `clear()`。清得少的表现是"换字体后列表回顶"，清得多的表现是
  "热重载字体时用户正看的列表跳到顶部"，两种都像随机抖动。
- **自然尺寸由布局注入口问一次**（`LayoutOptions.intrinsic`），答案写回 `contentSize`。
  不在布局之外再走一遍：那要把 `measure()` 的约束传播抄第二份，两份迟早不一致，
  症状是"文本有时溢出边框一点点"，只在特定嵌套深度出现。

由此得到一条结构性不变量：**自撑开的节点在按测量宽绘制时必然不换行** ——
测量宽 = 单行宽 + 两侧内缩 + 内边距，绘制时的换行宽又减掉同样的量，刻意多出的余量
让"相等"不依赖浮点恰好相等。

**⑦ 宿主迁移：HUD 与背包从手写 DOM 搬到 UI 树（批71）。**

"引擎能画 UI"和"游戏在用引擎的 UI"是两件事。批69 结束时是前者：`extensions/ui` 六层齐了、
判据全绿，而 `browser-entry.ts` 里的 HUD 仍然是 `hud.textContent = ...`、背包面板仍然
每帧重建 `<div>`。这一步把后者接上，顺手暴露了三个只有"真用起来"才会碰到的问题：

- **字体资产是硬前置**。仓库里没有任何 `.fnt`，所以先有 `tools/make-ui-assets.mjs`：
  96 个**手写位图表**（ASCII 32..126 + `…`）→ 5×7 字形、128×46 图集、`ui-skin.png` 4 帧，
  产出 `.fnt` + 两张 PNG + 一份 json。选位图表而不是"渲染系统字体"，理由是**可复现**：
  Linux runner 上多半没有中文/等宽字体，`fillText` 会静默产出另一张图，那次构建的判据就全是假的。
  `--check` 模式比对磁盘产物与生成器，不一致直接退出码 1。
- **`createUiModule` 发生在 `bootGameApp` 之前**，那时 `platform.gfx` 还不存在、拿不到 `TextureHandle`。
  于是给 `UiModuleOptions` 加了 `pageSources`（**数据**，不是句柄）：模块在自己的 `init` 里建纹理并持有，
  `dispose` 时销毁；给 `pages`（现成句柄）时归宿主所有。两条同时给报 `UI.PAGE_AMBIGUOUS` ——
  "该由谁销毁"猜错的后果是**换 UI 图集把世界的纹理一起带走**，而错误在很久以后才发生。
- **UI 的资产与世界图集必须分开**。世界的 10 张帧合成一张图集（页 0），UI 需要**两页**
  （字形页 0 + 皮肤页 1）。把字体塞进世界图集会让 BMFont 的 UV 全部错位 —— 那些 UV 相对
  **字体图自己**算。所以 `UI_FILES` 显式列出来、走**同一条导入管线**（`.fnt`/`.json` → `textImporter`，
  两张 PNG → `textureImporter`），但单独组装成 `BakedUi`。

宿主侧因此多出一个分层：**L6 `src/host/`**（宿主是用引擎的那一侧，但它必须能被 Node 判据覆盖，
所以不能再堆在 1967 行的 `browser-entry.ts` 里）。`LAYER_BY_DIR` 里登记 `host → L6-host`，
且**其余各层的 `ALLOWED` 里都没有它** —— 引擎 import 宿主会直接红。

| 文件 | 内容 | 为什么在这儿 |
|---|---|---|
| `host/hud-model.ts` | `hudRows` / `bagRows` / `bagFooter` / `missingGlyphsIn` | 全是**纯函数**：文案能喂给判据逐字查字体画不画得出来 |
| `host/hud-ui.ts` | `buildSkin`（json→`UiSkin`）+ `createHudUi`（节点树 + `setHud`/`setBag`） | 只建对象、不 `init`，所以整棵树的形状与 props 在 Node 里就能验 |
| `host/demo-game.ts` | `buildDemoGame(env)`：整段 demo 装配（约 3000 行）+ 依赖面 `DemoHostEnv` / `DemoSurface`（含 HUD 缺失时的降级语义表） | 装配是「用引擎的那一侧」，但**不是**「某个平台的那一侧」—— 它必须同时被浏览器与假 wx 装上。**不许 import 具体后端**（规则 4）⇒ 注册表由入口交进来；一切宿主能力（HUD 文本 / toast / 浮字 / 键盘 / 输入法 / 重载）收进 `DemoSurface`。两个世界同时存在时模块级单例会互相覆盖，所以 `assetFs`/`assetKind` 这类都收成**每次构建一份** |
| `host/wx/` | `env.ts`（canvas / 视口 / webgl2 探测）、`tick.ts`（`ITickSource` 的 wx 实现）、`fs.ts`（`IFileSystem` 覆盖 `wx.getFileSystemManager()`）、`input.ts`（触摸 → 逻辑键）、`index.ts`（`createWxHost` 组装） | 小游戏适配层（批121）：**只换「从哪拿」**，帧/存档/输入的语义一条不重写。住 L6 才能 import L3 的 `ITickSource`，又不会被引擎层反向依赖。**图形后端不在这里** —— 规则 4 只允许组合根 import 具体后端；入口（批128）注册 `webgl2Backend` 并交 `backendOptions.gfx = { canvas }`，由 `createPlatform` 去 probe + create（入口自己 `new GL2Device` 会把「探测失败」这条正常路径变成异常路径） |

小游戏适配层（`host/wx/`）也住 L6，理由与 HUD 那两件不完全一样：HUD 是「纯函数好判」，而它是「**必须能向下 import**」—— 帧源要 `ITickSource`（L3）、文件系统要实现 `IFileSystem`（L1）。放到 `src/platform/` 会让 L1 反向依赖 L3；放到 `src/backends/` 又会让它够不着 L3。L6 是唯一同时满足「向下可见」与「引擎看不见它」的位置。

**入口只做「换四件套」，装配住 `host/demo-game.ts`（批128）。** 批121 之后 C20 看起来只剩「接线」，
实测相反：装配整段长在 `browser-entry.ts` 里、与 DOM 缠死（`document.` / `window.` / `localStorage` /
隐藏 `<input>` 二十余处），换宿主不是接线而是重写。抽出来之后边界是**一份列得完的依赖面**
（registry / canvas / viewport / assets / saves / tick / now / setTimer / clearTimer / reload /
scriptWasm / platformId / platform / surface / extraSinks），两个入口各自只回答「这些从哪来」——
`browser-entry.ts` 因此只剩约 300 行，13 秒自检回路一点没变慢。

★★ 这一批最贵的一课在 `strict` 上，值得单独写下来：**参数跨三层，就要有一层判据去验它到了尽头。**
`PlatformRequest.strict`（「输入/存档/图形不许退回 null」）在入口写成 `strict: ["gfx","input","fs"]`，
路径是 `wx-entry` → `DemoHostEnv.platform` → `GameAppOptions` → `createPlatform`。
第三个箭头断了：`GameAppOptions` 里没有这个字段，而装配是 `...(env.platform ?? {})` 展开进去的 ——
**对象展开不做多余属性检查**，于是它被静默丢掉，平台一次都没收到过。
症状正是「说了不留半个宿主，实则照样悄悄退回 null 后端」：没有 GL 的宿主起得来、tick 在走、
存档能写、屏幕上什么都没有，而所有子系统判据全绿。补上字段 + 一条 no-GL 判据
（默认 `gfx: "webgl2"` 在没有 GL 的环境里**必须启动失败**）才算钉住。
附带一条语义澄清：`allowFallbackToNull: false` 只过滤**回退兜底**那一轮，`prefer: "null"` 是「点名要它」，
不受 `strict` 影响 —— 所以 `gfx: "null"` 时**不需要**把 gfx 从 `strict` 里摘掉（第一版写了那个条件，
被变异证明等价于没写）。

**同一条链上还有一处「顺序」问题（批129）：播报不能依赖「已经走到哪一步了」。**
`surface`（toast / modal）是在 `createWxHost` **之后**才建好的，而 `WX.NO_TOUCH` / `WX.NO_FS`
恰恰抛在那之前 —— 异常冒到启动壳的 `void main()`，而真机上「未处理的 promise 拒绝」
通常什么都不发生（没画面、没弹窗、帧循环没起来），与「还在加载」在屏幕上一模一样。
所以播报抽成只拿 `wx` 一个参数的 `reportFatal`，`surface.fatal` 与 `main` 的 catch 共用它，
`main` 接住之后**不再重抛**（人已看见弹窗、日志里有全文，再抛只是多一条没有观众的记录）。
判据 `tests/host/wx-entry.test.ts` 同时读两个观测量：弹窗（玩家看见的）与日志（开发者看见的）。

**L7 是后补的一层，补它的原因很具体**：批79 把平台分包写进 `src/publish/` 之后，
架构判据的「未分类顶层目录」当场红了 —— 它没登记层，就会被当成 `root`（可以 import 任何东西）。
而 `publish` 的**真实性质**是两条都要守住：
① 它只该依赖 `L0`（一份纯数据 + `Result`）—— 打包发生在 CI 的空容器里，那里没有引擎；
② **引擎不许 import 它** —— 「打包脚本的逻辑漏进运行时」这类腐化不会报错，
只会让体积跟着进包，而且改一处要发两个版本。所以 `ALLOWED["L7-tool"] = ["L0-foundation", "L7-tool"]`，
其余各层的白名单里都没有它。

**⑧ HUD 一行装不下 —— 这不是排版问题，是信息分层问题。**

15 个字段拼一行约 190 字符，5×7 字体每字前进 6px ⇒ 约 1140px，而设计分辨率是 960 宽。
**溢出是静默的**：`missingGlyphs` 是空的、`quads` 照样在涨，只是最后几个字段画到了屏幕外。
所以 `hudRows()` 把它切成三行，切法就是"什么时候会去看它"（每帧变的 / 世界状态的 / 出问题才看的），
并且有一条判据拿**真字体**量每一行的排版宽度 ≤ `HUD_LAYOUT.width - pad*2`
（宽度取自实现导出的常量 —— 判据里抄一份 640 的话，实现改成 320 时两边谁都不会红）。

**⑨ 两张字体：5×7 手写 + 16×16 中文（批101）。缺字永远是"静默变空白"。**

HUD 里的每个字符都可能变成空白（`xadvance` 照旧推进，于是那里留个空档）。
这种错只有两种抓法：截图给人看，或者把文案交给判据 —— 于是：

- HUD / 背包面板的文案全部收进 `host/hud-model.ts`，由判据拿**真字体**逐字查；
- 物品名走**注入的 `labelOf`**：宿主读到中文字体就传 `ITEM_LABEL`（`1. 浆果 x3`），
  读不到就不传（退回 `1. berry x3`）。**默认值是 ASCII**，因为空白是静默的，
  而"字体一定在"是不该有的假设；
- 两条不同的字体不是"一张字体的两批字"：汉字要 16×16 的格，塞不进 5×7；
  而把 ASCII 换成 Unifont 的 8×16 会让 HUD 三行突然高 60%（见 [ADR-0014](adr/0014-vendored-font-asset.md)）；
- `bagFooter` 的分隔符仍用 ` | ` 而不是 `·`：`·` 是 U+00B7，**GB2312 里没有它** ——
  字符集是按国标声明的，不是"Unicode 全都有"；
- `missingGlyphsIn` 这个守门函数**自己也有一条判据**（喂中文必须报出 ≥2 个码点）——
  它对任何输入都返回空数组的话，所有"文案全绿"的结论都是假绿。

`.fnt` 里的页号是**字体局部**的（恒为 0），落到全局图集的第几页由宿主给
（`parseBmFont({ pageBase: 2 })`）。两层编号之间必须显式换算：中文那份要是把 0 原样落表，
它的四边形会去采样 5×7 那张图 —— 画面上是乱纹，而 UV、宽度、排版全都"看起来对"。

**⑩ "同一个 pass"怎么被证明：数 `frameIndex`。**

`GfxStats.frameIndex` 每次 `endFrame` 加一，宿主侧另有 `renderFrames`（每次 `onRender` 加一）。
自检页取两个时间点，断言 **ΔframeIndex === ΔrenderFrames** 且**世界的 quad 与 UI 的 quad 同时 > 0**。
UI 若自己 `beginFrame/endFrame`，一帧会加 2 —— 顶点数、draw call 数、纹理切换数全都看不出来，
这是这条集成约定**唯一**能从外部观测到的证据。

**判据与变异**：引擎侧 82 条（排版 16 / 布局 17 / 模块 16 / 字体 12 / 视口 10 / 事件 11）
+ UI 资产 8 条（`tests/extensions/ui-assets.test.ts`：每个字形在图集里至少有一个不透明像素、
基线语义、`xadvance = width + 1`、`--check` 与磁盘产物一致）
+ 中文字形资产 15 条（`tests/extensions/ui-cjk-font.test.ts`：字符集 → 字形的双向覆盖、
**手抄金标逐位比对**（镜像/翻转/错列必死）、墨迹总量守恒（两个字形叠一格会少像素）、
货架不重叠、基线与行高、半角/全角前进量、CJK 按字断行、坏 BDF 的错误码）+ 中文接线 2 条
+ 宿主 17 条（`tests/host/`：皮肤 json→UV、越界报错、行数/选中/开合、点击回调、HUD 行宽）。
14 组变异（M279–M292）分别钉：UV 恒等映射、`xadvance` 用法、九宫格 UV 占比、进度条裁 UV、
click 的同目标判定、`opaque` 阻断、`expand` 用 `min`、overlay 在 `finish` 之前、
HUD 文案混入非 ASCII、背包行不切 `visible`、选中不换底色、皮肤帧落错页、HUD 面板做窄、
**面板行的点击回调没接上**（最后这条只能用浏览器判据抓：Node 侧回调是好用的，
坏的是"UI 模块有没有把它接成事件接收器"）。

**已知缺口（写进文件尾，不藏）**：

- 排版：避头尾（行首不留 `，。）`）、RTL、富文本（同行混字号/颜色）；
- 控件：拖拽换位、输入框、过渡动画（滚动容器批105 已交付）；
- ~~**字体只有 ASCII**~~ ✅ **已消除（批101）**：`ui-font-cjk.{png,fnt}` 由 GNU Unifont
  18.0.01（OFL-1.1）子集化生成，7540 个字形（GB2312 全集 6763 汉字 + 682 符号 + ASCII），
  背包行的物品名已经是中文。~~`toast` 还是 DOM~~ ✅ **已消除（批106）**：提示条变成
  `toast.panel` + `toast.line`（底中锚点、定宽单行、超长按比例截断），计时留在宿主
  （UI 层没有时钟）；`web/index.html` 的 `#toast` 只剩"资产建不起来"的降级通路；
- **UI 两页的代价**：皮肤页与字形页分开 ⇒ 每个"图 + 字"组合都要切一次页，
  当前 HUD+背包是 15 段 draw（世界只要 2 段）。控制方法只有一个：把字体页与皮肤页打同一张图集；
- ~~控件层不写 `contentSize`~~ ✅ **已消除（批99）**：布局在算好内区尺寸那一刻问一次
  `LayoutOptions.intrinsic`，答案写回 `contentSize`（见 [ADR-0012](adr/0012-ui-crossframe-state.md)）。


---

## 12. 向《饥荒》风格引擎的演进路线

每阶段都有**可机器验证的出口判据**，且都**不修改内核结构**（只加文件 + 注册）。

### 阶段 1 · 能看见画面（渲染后端 + 输入）—— **本次已完成**

- `gfx-webgl2`：精灵批处理（`SPRITE_VERTEX_LAYOUT` 已定：pos.xy + uv.xy + color.rgba）、图集、深度排序（z 降序）
- `input-dom`：指针 + 键盘 + 边缘语义（与 `input-null` 同一套契约）
- 出口判据：`runGfxContract("webgl2", …)` 全绿 ✅；`readPixels` 在真实画布上返回非零 ✅；
  一次 draw call 提交 ≤ 1（同一图集的 100 个精灵必须合并）✅（`web/selftest.html` 断言）

### 阶段 2 · 内容可复用（脚本层 + 资产身份 + 真资产上屏）—— **已完成**

- `IScriptRuntime`（Lua 5.4 via wasmoon）+ 反射表（`expose`）+ 串行队列 + 异常隔离 ✅
- **Lua 5.1 兼容垫片** + **per-module `_ENV` 隔离** ✅（`notes`：§5.4）
- `.meta` 身份 + 源导入器 + 增量管线 + 产物加载器 ✅
- **PNG 像素解码**（`inflate.ts` + `png.ts`）+ **确定性图集合成** ✅
- **浏览器改为读真实资产**：`fetch web/assets/*.png` → 导入管线 → 解码 → 合成 → 上传；
  失败才降级到程序化图集，且 HUD 显示 `atlas:assets*5` / `atlas:procedural`（降级不静默）✅
- `LongUpdate(elapsed)`：跳时间时按分段结算腐烂/计时器（不是跑 N 次 `OnUpdate`）✅（阶段 1 已做）

**出口判据**：

| 判据 | 状态 |
|---|---|
| 同一份 Lua 脚本在**两个独立 headless 实例**里产生**逐字节相同**存档 | ✅（`script-e2e`；红了两次，暴露"节点 id 全局自增"） |
| 脚本算出的位置与 JS 独立计算一致（1e-9） | ✅ |
| 跳 8 小时后腐烂进度与"连续跑 8 小时"的差 ≤ 1 个结算周期 | ✅（阶段 1） |
| **解码出的 RGBA8 与 GPU 实际收到的字节逐字节一致** | ✅（`asset-gpu-roundtrip`，含 2 条反例防假绿） |
| 真实语料 3423 个 PNG 结构校验 / 3422 个完整解码 | ✅（`tools/verify-png-corpus.mjs --all`） |
| 隔行/16 位/APNG 的外部金标（pngjs + Pillow 双实现） | ✅（`make-png-fixtures.mjs` → `verify-fixtures-pillow.py`） |
| 5.1 风格脚本（`module()` + `setfenv` + `unpack`）能加载并调用 | ✅（`script-lua51`，12 条） |
| 模块间同名全局互不可见 + 重载丢弃旧 env | ✅（`script-env`，7 条） |
| headless ↔ **浏览器**逐字节存档 | **✗ 未自动化** —— 浏览器侧只断言到"Lua 算得对 + 跨界日志可见 + 图集来自资产"，逐字节比对需手工导出。**这条不算达成**，见 §11.2 |

### 阶段 3 · 世界能跑（物理 + 世界生成 + AI）—— **主体已完成，AI 未做**

★ 这个标题此前**缺失**：本节条目直接接在阶段 2 的出口判据表后面，
读起来像"阶段 2 的一部分"。老实说这类缺失比数字写错更难发现 ——
没有人会觉得"阶段 2 里怎么在讲物理"。补标题时顺手核对了条目状态。

- ✅ `IPhysicsWorld`：XZ 平面 + AABB/圆 + 空间哈希；`findEntities(x,z,r)` 与饥荒 `FindEntities` 同签名；
  **连续碰撞（批100）**：`sweepCircleVsBox`/`sweepCircleVsCircle` 纯函数（精确解 = 放大盒四边 ∪ 四角圆）+ `sweepMove` 只回答不改位置
- ✅ `IWorldGenerator`：群系图 + 连通性校验 + **世界指纹**（见 §11.4）；任务表仍待做
- ✅ AI：行为树 + `IModule` 接线 + 真调度器驱动 + 异常隔离（`src/extensions/ai/`，见 §11.5）
- 出口判据：`findEntities` / `query` 候选集与暴力枚举**完全一致** ✅；同种子两次生成指纹相同 ✅；
  **2000 实体 30Hz 下 `step` < 8ms —— 未测**（本机没有这条闸门，性能数字一律不写进文档）

### 阶段 4 · 能做游戏（编辑器 + PIE）

- 独立编辑器宿主（L6），通过 `IPlatform` 起一个**隔离的预览世界**
- 撤销/重做落在 §5.2 的命令队列上（命令可序列化 ⇒ 撤销是"反序应用状态"）
- 出口判据：编辑器世界里撤销一次导入 = 一次原子操作；PIE 崩溃不污染编辑器世界

### 阶段 5 · 能交付（构建发布）—— **核心已完成，工程化未做**

- ✅ 资产清单（manifest）+ 内容寻址（hash）+ 闭包分包（`src/extensions/build/publish.ts`，见 §11.6）
- 出口判据，两条都成了判据：
  - ✅ 删掉一个未引用资产后，构建产物**逐字节不变**
  - ✅ 改动一个资产只重打**一个**包（断言的是"只有一个包换名"，不是"包变了"——
    打成一个大包也能让"包变了"成立，那种实现下改一个字节整包失效）
- ✅ CLI 与落盘：`tools/build-assets.mjs`，11 条判据在磁盘层重验两条出口判据
- ⬜ 与导入管线接线：CLI 的 `.meta` 依赖按相对路径理解，导入产物还没喂进来

---

## 附录 A · 关键决策记录（ADR）

| 编号 | 决策 | 一句话理由 |
|---|---|---|
| [ADR-0001](adr/0001-world-model-node-component.md) | 不做 ECS 双世界，用 Node+Component + 类型集中存储 | 一套世界模型，但保住 ECS 的遍历收益 |
| [ADR-0002](adr/0002-handles-not-objects.md) | GPU 资源用不透明句柄，不用对象引用 | 销毁后整体失效，不留"半死对象" |
| [ADR-0003](adr/0003-result-not-exceptions.md) | 可预期失败用 `Result`，不抛异常 | 抛异常会让降级路径写进 catch，而没人写 |
| [ADR-0004](adr/0004-structural-changes-via-commands.md) | 结构性修改走命令队列 | 遍历期改表必然出错，且命令可重放 |
| [ADR-0005](adr/0005-backends-depend-only-on-interfaces.md) | 后端只依赖 L0/L1，禁止 import 内核 | 否则后端会开始依赖实现细节，无法移植 |

## 附录 B · 目录结构

```
08-引擎内核/
├── src/
│   ├── foundation/        L0  result · math · log · event · memory · time · random · **hash**
│   ├── platform/          L1  gfx · audio · input · fs · script · registry · platform
│   ├── core/              L2  module · scene · scheduler · asset · serialization
│   ├── runtime/           L3  GameApp · tick-source
│   ├── extensions/        L4  render（含 atlas-from-assets · atlas-from-apng）· physics · script
│   │                          asset-import（含 decode/inflate · png · apng · jpeg · image）
│   ├── backends/          L5  gfx-null · gfx-webgl2 · audio-null · audio-webaudio
│   │                          input-null · input-dom · input-injected · fs-memory · fs-node · script-null · script-lua
│   ├── host/              L6  demo-game（装配工厂）· hud-model · hud-ui · wx/（小游戏适配层）
│   ├── browser-entry.ts   L6  浏览器宿主（薄壳：把浏览器翻译成 DemoHostEnv）
│   ├── wx-entry.ts        L6  小游戏宿主（同一份装配，换四件套）
│   ├── wx-boot.ts             小游戏启动壳（esbuild 入口，只调 main()）
│   └── index.ts               对外 API 面（只导出接口/类型/工厂）
├── tests/                 161 个文件 <!-- n:files --> / 2475 条判据 <!-- n:tests -->（arch · contract · core · backends · extensions）
│   └── fixtures/png/      外部金标语料（隔行/16 位/APNG，pngjs + Pillow 双实现产出）
│   └── fixtures/jpeg/     外部金标语料（**54 例** <!-- n:jpeggold -->，三份清单按案例名去重：Pillow 解 17 + 算术 6
│                          + CMYK/YCCK 4 + "我们编码→libjpeg 解" 6 + liblj92 无损 8..16 位 9 + ffmpeg 12，
│                          manifest 里逐例记录 maxAbs/meanAbs/sha256 与来源）
├── samples/headless.ts    最小宿主（整条链的证明）
├── web/                   浏览器宿主（index.html / selftest.html / bundle.js / glue.wasm）
│   └── assets/            5 张真 PNG（五种滤波 × RGBA/RGB）+ 1 张真 JPEG，走完整导入链后上屏
├── tools/                 serve · mutation-check · make-demo-assets · make-demo-jpeg · verify-png-corpus
│                          png-encode · make-png-fixtures · verify-fixtures-pillow · scan-png-features
│                          make-jpeg-fixtures
└── docs/                  本文档 + 9 个 ADR + 两份任务计划 + PROGRESS.md
```
