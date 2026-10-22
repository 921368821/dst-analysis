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
│      player-web · headless(判据/服务端) · editor(PIE)                     │
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
| `FixedStepScheduler` | 固定步长、追帧上限、幂等 tick、暂停/缩放、alpha | **不做"游戏时间"以外的任何事** | `core/scheduler/scheduler.ts` |
| `AssetDatabase` | AssetId（GUID）、依赖图、引用计数、卸载反拓扑、并发去重 | 不做导入（那是 importer 的职责） | `core/asset/asset.ts` |
| `Schema` | 确定性编码（字段序 + 量化）+ 版本迁移链 | 不做二进制格式（先要可读可 diff） | `core/serialization/schema.ts` |

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

### 3.5 L4 Extensions（渲染 / 物理 / 存档）

| 模块 | 职责 | 关键取舍 | 文件 |
|---|---|---|---|
| `render/batch2d` | 精灵批处理：排序 + 顶点组装 | 排序键 `z↓ → order → atlas → nodeId`；**z 优先于纹理切换**（遮挡正确性不可牺牲） | `extensions/render/batch2d.ts` |
| `render/render-module` | 把 Sprite 组件变成每帧一次 draw | 相机跟随在**渲染阶段**做（用 alpha），不在 `onUpdate` 里做 | `extensions/render/render-module.ts` |
| `render/camera` | 正交 + 斜俯视投影（`tiltY`） | 投影在 CPU 做；逻辑坐标是**未压缩**的 XZ | `extensions/render/camera.ts` |
| `render/sprite` | 渲染数据组件 | **不存 GPU 句柄**，只存 `atlasId + frame`（句柄是进程内的，存进档就是灾难） | `extensions/render/sprite.ts` |
| `physics` | 2.5D 碰撞：空间哈希 + 推出 | 不做刚体积分（饥荒风格的正确选择：卡顿不会穿墙） | `extensions/physics/physics.ts` |
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
| `fs-memory` | ✅ 完成 | 判据 / PIE 预览 / 存档暂存 |
| `audio-null` | ✅ 完成 | 记录播放 + 可推进音频时钟；`resume()` 首次失败（模拟自动播放策略） |
| `input-null` | ✅ 完成 | 可编程输入（`press`/`movePointer`/`typeText`），边缘语义在此实现一次 |
| `gfx-webgl2` | ✅ 完成 | 只依赖 `GL2Like`（可在 Node 注入 fake）⇒ 同一套契约能在无 GPU 环境跑 |
| `audio-webaudio` | ✅ 完成 | 声部上限 + `onended` 回收 + `resume()` 可失败（自动播放策略） |
| `input-dom` | ✅ 完成 | `event.code`（不是 `key`，中文输入法下 `key` 会变 `"Process"`）+ 失焦清空 |
| `fs-node` | ⬜ 待实现 | 当前 Node 侧用 `fs-memory`（判据不需要落盘） |

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
stepTo(targetTick): number;   // 幂等：target ≤ 当前 则返回 0
stepOnce(): number;           // 单帧调试
resetTo(tick): void;          // 读档：不执行中间步
stats(): SchedulerStats;      // 含 droppedSteps（卡顿唯一可见的症状）
```

三条边界规则（每条都有测试）：**上限 + 记账**、**幂等**、**alpha 只给渲染用**。

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

### 5.4 脚本层通信（L4，待实现）

```ts
export interface IScriptRuntime {
  readonly id: string;                                  // 'lua' | 'js' | 'wasm'
  loadModule(name: string, source: string): Result<void, EngineError>;
  call(fn: string, args: readonly unknown[]): Result<unknown, EngineError>;
  /** 暴露给脚本的 API 面（反射表）。脚本只依赖这张表，不依赖实现。 */
  expose(name: string, value: unknown): void;
  dispose(): void;
}
```

**为什么脚本层必须是接口**：
已有 153 万行 Lua 内容层（DST 注释源码）要复用，但"引擎内核绑定 Lua"会让
"将来想支持 JS/DSL"变成重写。把 Lua 放在 `IScriptRuntime` 后面，
内核只认"C 风格调用 + 反射表"，换语言是换实现。

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
| **后端** | `IGraphicsDevice` / `IAudioDevice` / `IInputDevice` / `IFileSystem` | `registry.registerGfx(...)` | 只加一个新目录 + 一行注册 |
| **组件** | `Component` + `ComponentSchema` | `components.register(schema, factory)` | 只加一个新类 |
| **资产导入器** | `IAssetLoader` | `assets.registerLoader(l)` | 只加一个新类 |

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
| 渲染抽象 | RHI（多后端）+ SRP | `gfx::Device`（多后端） | `IGraphicsDevice`（多后端，当前 1 个实现） | **缺 WebGL2 实现** |
| 资产身份 | `.meta` + GUID | `.meta` + UUID | `AssetId`（GUID 风格）+ 依赖图 | 一致；**缺导入器与 .meta 落盘** |
| 脚本 | C#（Mono/IL2CPP） | TS（JSB 原生绑定） | `IScriptRuntime`（先接 Lua） | **未实现** |
| 序列化 | `[SerializeField]` + 反射 | 组件 `_serialize` | `ComponentSchema` 声明式 + 迁移链 | 一致（无反射，更快） |
| 编辑器 | Editor（独立进程 + PIE） | Creator（独立 + 预览） | 未开始（`src` 里没有编辑器代码） | **最大缺口** |
| 构建发布 | 多平台打包 | 多平台 + 小游戏 | 未开始 | **最大缺口** |
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

合计 **115 条 Node 判据 + 9 条浏览器自检**，全部在 `npm test` / 打开自检页里跑；
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

---

## 11. 当前状态

### 11.1 已完成

- L0 全部（result / math / log / event / memory / time / random）
- L1 全部接口（gfx / audio / input / fs / net）+ `BackendRegistry`
- L2 全部（module / services / scene / node / component / scheduler / asset / schema）
- L3 全部（GameApp / tick-source / snapshot）
- L5 后端：`gfx-null`（记录型）/ `gfx-webgl2` / `audio-null` / `audio-webaudio` /
  `input-null` / `input-dom` / `fs-memory`
- L4 扩展：2D 渲染管线（相机/精灵/程序化图集/批处理/渲染模块）、2.5D 物理、确定性存档、跳时间结算
- **115 条 Node 判据 + 9 条浏览器自检**，架构守护 7 条，后端契约 22 条（两后端）
- 最小宿主跑通（150 tick / 5 秒 / 600 次组件更新 / 暂停不动）
- 浏览器宿主跑通（`web/index.html`：WASD 移动、H 砍树、F5/F9 存读档、HUD 显示 draw call）

### 11.2 未完成（按优先级）

| 项 | 影响 | 预计落点 |
|---|---|---|
| `fs-node` 后端 | Node 侧落盘（存档到真实文件） | 阶段 2 |
| 脚本层 `IScriptRuntime` + Lua 绑定 | 复用 153 万行内容层 | 阶段 2 |
| sprite 图集来自真实资产（`.meta`+GUID+importer） | 现在是程序化生成 | 阶段 2 |
| `IPhysicsWorld`（2.5D：XZ + AABB/圆 + 空间哈希） | 目前只有"手工碰撞" | 阶段 3 |
| 编辑器（独立进程 + PIE） | 最大缺口 | 阶段 4 |
| 构建发布（manifest + 增量） | 第二大缺口 | 阶段 5 |

### 11.3 已知风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| **两套引擎并存** | 仓库里已有 `07-通用引擎`（Python+Lua+JS，32k 行，274 判据） | 明确 `08` 是内核重构目标；`07` 短期内作为**行为参照**与判据来源，不并行演进功能 |
| **内容层绑定** | 153 万行 Lua 来自 DST，`pack_atlas` 只解决贴图 | 阶段 2 先做 `IScriptRuntime` 的**最小可用**（加载 → 调用 → 异常隔离），再谈迁移 |
| **确定性与浮点** | JS 的 `Math` 跨平台基本一致，但 `Math.pow/exp` 等不保证 | 序列化层已量化；物理与 AI 避免超越函数（用查表/定点） |
| **单后端长期存在** | 只有一个后端时接口歧义不会被发现 | 契约测试 + Null 后端作为"第一实现"强制覆盖语义 |

---

## 12. 向《饥荒》风格引擎的演进路线

每阶段都有**可机器验证的出口判据**，且都**不修改内核结构**（只加文件 + 注册）。

### 阶段 1 · 能看见画面（渲染后端 + 输入）—— **本次已完成**

- `gfx-webgl2`：精灵批处理（`SPRITE_VERTEX_LAYOUT` 已定：pos.xy + uv.xy + color.rgba）、图集、深度排序（z 降序）
- `input-dom`：指针 + 键盘 + 边缘语义（与 `input-null` 同一套契约）
- 出口判据：`runGfxContract("webgl2", …)` 全绿 ✅；`readPixels` 在真实画布上返回非零 ✅；
  一次 draw call 提交 ≤ 1（同一图集的 100 个精灵必须合并）✅（`web/selftest.html` 断言）

### 阶段 2 · 内容可复用（脚本层 + 时间跳跃）

- `IScriptRuntime`（Lua via wasm 或 lupa 桥）+ 反射表（`expose`）
- `LongUpdate(elapsed)`：跳时间时按分段结算腐烂/计时器（不是跑 N 次 `OnUpdate`）
- 出口判据：同一份 Lua 脚本在 headless 与浏览器里产生**逐字节相同**的存档；
  跳 8 小时后腐烂进度与"连续跑 8 小时"的差 ≤ 1 个结算周期

### 阶段 3 · 世界像饥荒（物理 + AI + 世界生成）

- `IPhysicsWorld`：XZ 平面 + AABB/圆 + 空间哈希；`FindEntities(x,z,r)` 与饥荒同签名
- AI：行为树/状态机作为 `IModule`，决策吃 tick（不是 dt）
- `IWorldGenerator`：群系图 + 任务表 + 连通性校验 + **世界指纹**（同种子必须同指纹）
- 出口判据：2000 实体 30Hz 下 `step` < 8ms；同种子两次生成指纹相同；
  一次 `FindEntities` 的候选集与暴力枚举**完全一致**

### 阶段 4 · 能做游戏（编辑器 + PIE）

- 独立编辑器宿主（L6），通过 `IPlatform` 起一个**隔离的预览世界**
- 撤销/重做落在 §5.2 的命令队列上（命令可序列化 ⇒ 撤销是"反序应用状态"）
- 出口判据：编辑器世界里撤销一次导入 = 一次原子操作；PIE 崩溃不污染编辑器世界

### 阶段 5 · 能交付（构建发布）

- 资产清单（manifest）+ 增量构建 + 内容寻址（hash）
- 出口判据：删掉一个未引用资产后，构建产物**逐字节不变**；改动一个资产只重打一个包

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
│   ├── foundation/        L0  result · math · log · event · memory · time · random
│   ├── platform/          L1  gfx · audio · input · fs · registry · platform
│   ├── core/              L2  module · scene · scheduler · asset · serialization
│   ├── runtime/           L3  GameApp · tick-source
│   ├── script/            L4  IScriptRuntime（待实现）
│   ├── backends/          L5  gfx-null · gfx-webgl2 · audio-null · input-null · fs-memory
│   └── index.ts               对外 API 面（只导出接口/类型/工厂）
├── tests/
│   ├── arch/              架构守护（依赖规则）
│   ├── contract/          后端契约
│   └── core/              单元/集成
├── samples/headless.ts    最小宿主（整条链的证明）
└── docs/                  本文档 + ADR
```
