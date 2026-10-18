# 架构规范与设计约束

> 沉淀自《Don't Starve Together》Lua 代码树拆解。所有行号引用均已核实。

---

## 目录

1. [实体 / 组件 / 预制体三层职责边界](#1-实体--组件--预制体三层职责边界)
2. [生命周期时序](#2-生命周期时序)
3. [标签系统与空间查询](#3-标签系统与空间查询)
4. [事件系统使用规范](#4-事件系统使用规范)
5. [协程与定时任务的生命周期管理](#5-协程与定时任务的生命周期管理泄漏重灾区)
6. [服务端 / 客户端分离的代码规范](#6-服务端--客户端分离的代码规范)
7. [数据驱动的交互动词](#7-数据驱动的交互动词)
8. [关键反模式与正确写法对照](#8-关键反模式与正确写法对照)

---

## 1. 实体 / 组件 / 预制体三层职责边界

### 1.1 职责划分表

| 层 | 是什么 | 负责 | **不负责** | 规模参考 |
|---|---|---|---|---|
| **实体（Entity）** | 原生实体对象外面一层很薄的 Lua 包装 | 挂载点、标签集合、事件总线、组件表、任务表 | 任何玩法规则 | 425×425 世界约 3000 个 |
| **组件（Component）** | 普通的 `Class` 对象，存在 `inst.components[name]` | 全部状态与行为；生命周期回调；序列化 | 知道自己之外的组件存在（只通过调用） | 821 个 |
| **预制体（Prefab）** | 具名工厂函数 + 资源清单 | 创建壳、挂原生组件、打标签、挂行为组件 | 玩法逻辑、状态 | 1594 个 |
| **原生"底层组件"** | C++ 对象，通过 `inst.entity:AddXxx()` 添加 | Transform / AnimState / Physics / Network / SoundEmitter / Light / Map / Pathfinder | —— | 通过 `inst.Transform` 访问 |

### 1.2 三层的边界判据

**判断一段代码该放哪一层，问三个问题：**

1. **它描述的是"这个东西是什么"还是"这个东西怎么做"？**
   - 是"是什么" → 预制体（能拖到物品栏里、能被别的预制体引用）
   - 是"怎么做" → 组件

2. **它需要独立存读档吗？** 需要 → 组件（组件自己实现 `OnSave`/`OnLoad`）
3. **两个不相关的实体都需要这个行为吗？** 是 → 组件（绝不要用继承表达共享行为）

### 1.3 预制体的标准骨架

```lua
-- prefabs/twigs.lua —— 一个简单物品的完整骨架
local assets = { Asset("ANIM", "anim/twigs.zip"), Asset("SOUND", "sound/common.fsb") }
local prefabs = { "oceanfishingbobber_twig_projectile" }   -- deps：会生成的预制体，保证其资产常驻

local function fn()
    local inst = CreateEntity()             -- 实体壳，登记进 Ents[guid]

    inst.entity:AddTransform()              -- 原生底层组件
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)              -- Make* 打包辅助函数

    inst.AnimState:SetBank("twigs")         -- bank = 骨架集，build = 皮肤
    inst.AnimState:SetBuild("twigs")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("cattoy"); inst:AddTag("renewable"); inst:AddTag("twigs")

    inst.entity:SetPristine()               -- ★ 冻结"可同步状态"的快照

    if not TheWorld.ismastersim then
        return inst                          -- ★ 客户端到此为止
    end

    -- ===== 以下全部是服务端权威逻辑 =====
    inst:AddComponent("inventoryitem")
    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM
    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.ROUGHAGE
    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)   -- 一次性加 burnable + 配置
    MakeSmallPropagator(inst)
    return inst
end

return Prefab("twigs", fn, assets, prefabs)
```

**`deps` 字段常被忽略但很关键**：引擎只*加载*从 `global` 可达的预制体。把某个会生成的预制体列进 `deps`，才能保证它的资产常驻内存，否则运行到一半才发现资源没加载。

### 1.4 `Make*` 打包辅助函数

一次性添加并配置多个组件的可复用打包，定义在 `standardcomponents.lua` / `componentutil.lua`：

```lua
MakeInventoryPhysics(inst)          -- 物品碰撞
MakeSmallBurnable(inst, burntime)   -- burnable + 可燃配置
MakeSmallPropagator(inst)           -- 火势蔓延
MakeHauntableLaunchAndIgnite(inst)
MakeFeedableSmallLivestock(inst)
```

**约定：** `Make*` 函数只做"加组件 + 设默认值"，**不做任何有玩法副作用的初始化**（不消耗资源、不触发事件）。有副作用的初始化放到 `DoTaskInTime(0, OnInit)` 里延迟做。

### 1.5 `AddComponent` 的幂等与大小写

```lua
function EntityScript:AddComponent(name)
    local lower_name = string.lower(name)
    if self.lower_components_shadow[lower_name] ~= nil then ... return existing end   -- 幂等
    local cmp = LoadComponent(name)                    -- require("components/"..name)，带缓存
    self:ReplicateComponent(name)                      -- 若在白名单则创建客户端副本
    local loadedcmp = cmp(self)
    self.components[name] = loadedcmp
    local postinitfns = ModManager:GetPostInitFns("ComponentPostInit", name)
    for _, fn in ipairs(postinitfns) do fn(loadedcmp, self) end   -- 模组钩子
    self:RegisterComponentActions(name)
    return loadedcmp
end
```

**两个独立的表，必须都维护：**

| 表 | 用途 | 陷阱 |
|---|---|---|
| `lower_components_shadow` | 用小写去重，保证幂等 | —— |
| `self.components` | 用**原样**存储，key 就是**存档字段名** | `AddComponent("Health")` 会让存档里出现 `"Health"` 字段，旧存档读回时 key 不匹配而丢数据 |
| `REPLICATABLE_COMPONENTS` | 决定是否创建客户端副本 | 忘了加 → 服务端有 `health`，客户端没有 → **UI 永远显示满血** |

**规范：组件名一律小写；新增可复制组件必须同步登记进 `REPLICATABLE_COMPONENTS`（或调用 `AddReplicableComponent`）。**

---

## 2. 生命周期时序

### 2.1 完整时序图

```
SpawnPrefab(name)
  │
  ├─ TheSim:SpawnPrefab → 引擎回调 Lua 的 SpawnPrefabFromSim(name)
  │    ├─ prefab.fn(TheSim)                        ← 预制体工厂体在此运行
  │    │    ├─ CreateEntity()                      ← 登记进 Ents[guid]
  │    │    ├─ entity:AddTransform/AddNetwork/...
  │    │    ├─ AddTag(...)
  │    │    ├─ AddNetwork()  ← 必须早于 SetPristine()
  │    │    ├─ net_xxx(...) 声明全部网络字段
  │    │    ├─ entity:SetPristine()                ← 同步快照定格
  │    │    ├─ if not ismastersim then return end   ← 客户端在此返回
  │    │    └─ AddComponent(...)  ×N               ← 服务端权威组件
  │    │         └─ (每个组件) 可 StartUpdatingComponent / DoPeriodicTask
  │    ├─ 设置 prefab 名、皮肤
  │    ├─ ModManager:GetPostInitFns("PrefabPostInit", name)  ← 模组钩子
  │    └─ TheWorld:PushEvent("entity_spawned", inst)
  │
  ├─【运行期】OnEntitySleep(guid) / OnEntityWake(guid)
  │    ├─ PushEvent("entitysleep" / "entitywake")
  │    ├─ 启停脑：_DisableBrain_Internal  ← ★ 丢弃脑实例
  │    │            _EnableBrain_Internal  ← ★ 重新调用工厂函数
  │    ├─ 状态图与发射器冬眠/唤醒
  │    └─ 每个组件的 OnEntitySleep / OnEntityWake
  │
  ├─【存档】GetSaveRecord()
  │    ├─ 位置（站在平台上时用"平台 UID + 局部坐标"）
  │    ├─ isbadnumber(x/y/z)  ← ★ NaN/Inf 猎捕，生产环境打印、开发环境 error
  │    ├─ 坐标量化到 3 位小数：math.floor(x*1000+0.5)*0.001
  │    ├─ y == 0 时不写该字段（省体积）
  │    └─ GetPersistData() → 遍历组件，逐个 OnSave()，收集引用表
  │
  ├─【读档】SpawnSaveRecord(record, newents)
  │    ├─ SpawnPrefab(record.prefab, skinname, skin_id)
  │    ├─ ResolveSaveRecordPosition() ← 平台局部坐标 → 世界坐标
  │    ├─ Transform:SetPosition(...)
  │    ├─ newents[record.id] = {entity=inst, data=record.data}
  │    │   （没有 id 就用实体本身当 key）
  │    └─ SetPersistData(data, newents) ← 派发给每个组件的 OnLoad
  │
  ├─【读档第二趟】所有实体都存在之后
  │    └─ entity:LoadPostPass(newents, data) ← 把 GUID 换成真实实体引用
  │
  └─【销毁】inst:Remove()
       ├─ 从父实体/平台脱离
       ├─ OnRemoveEntity(GUID)
       │    ├─ KillThreadsWithID(guid)      ← ★ 杀掉该实体的一切任务
       │    ├─ 移除脑与状态图
       │    ├─ 从 UpdatingEnts 摘除
       │    ├─ CancelAllPendingTasks()
       │    ├─ PushEvent("onremove")
       │    ├─ StopWorldStateListeners()
       │    ├─ RemoveAllEventCallbacks()    ← ★ 双向解绑
       │    ├─ 每个组件的 OnRemoveEntity()  ← ⚠ 可能重入，见 §4.4
       │    └─ 递归移除子实体
       └─ entity:Retire()
```

### 2.2 存档：两趟加载的完整机制

**第一趟（`SpawnSaveRecord`）**：实例化所有实体，按 GUID 建索引，派发 `OnLoad`。
**第二趟（`LoadPostPass`）**：所有实体都存在之后，解析跨实体引用。

```lua
-- 典型模式
function SomeComponent:OnLoad(data, newents)
    self.target_guid = data.target        -- 先存 GUID
end
function SomeComponent:LoadPostPass(newents, data)
    local rec = newents[data.target]
    self.target = rec and rec.entity or nil
end
```

**引用表机制（精妙且值得抄）：** 一个实体只有在"被别人引用"或"自己引用了别人"时才会被写入 `record.id`。地上的草、石头没有 id，存档最小化。背包里的物品、跟随物才有 id。

```lua
if new_references ~= nil then
    references[v.GUID] = v                            -- 自身有引用 → 需要自己的 ID
    for k1, v1 in pairs(new_references) do
        references[v1] = v                             -- 被引用的实体也要 ID
    end
end
...
for k, v in pairs(references) do
    if saved_ents[k] ~= nil then saved_ents[k].id = k  -- ★ 只给真正被引用的实体写 id
    else print("Missing reference:", v, "->", k) end
end
```

**`newents` 用实体本身作 key 的设计很聪明**：没有 id 的实体也能被引用（引用时直接传实体），有 id 的则通过 `newents[saved.id]` 查到。

### 2.3 组件被删除后的兼容性

`SetPersistData` 里有一段专门处理"存档里有、但当前实体没有这个组件"：

```lua
if data and data.add_component_if_missing then
    for k, v in pairs(data) do
        if self.components[k] == nil and type(v) == "table" and v.add_component_if_missing then
            self:AddComponent(k)                    -- ← 自动补回被删的组件
        end
    end
end
```

**用法：** 组件的 `OnSave` 返回 `{ add_component_if_missing = true, ... }`。读档时若该组件已被删除，框架会自动补回，让它有机会执行 `OnLoad` 做数据迁移。这是"删组件"这类重构的安全网。

### 2.4 预制体重命名的迁移映射

```lua
-- gamelogic.lua:352-366
local replace = {
    ["farmplot2"]   = "fast_farmplot",
    ["farmplot3"]   = "fast_farmplot",
    ["sinkhole"]    = "cave_entrance",
    ["cave_stairs"] = "cave_entrance",
}
```

**规范：** 任何预制体改名/合并，都必须在这张表里留映射，否则老存档里的实体类型找不到对应工厂而静默消失。

---

## 3. 标签系统与空间查询

### 3.1 标签的基本约定

标签是引擎侧的**字符串标志**，用于快速空间查询与能力门禁。

```lua
inst:AddTag("cattoy")           -- 猫的玩具
inst:AddTag("renewable")        -- 可再生（资源点）
inst:AddTag("twigs")            -- 用于唯一化查找
inst:HasTag("player")           -- 能力门禁
```

**DST 的标签分类（按用途）：**

| 类别 | 例子 | 用途 |
|---|---|---|
| 能力门禁 | `player`、`hostile`、`heavy`、`canmove`、`reader` | 决定某能力是否可用 |
| 资源查询 | `twigs`、`rocks`、`silk` | `FindEntities` 的 must/cant 过滤 |
| 状态标记 | `NOCLICK`、`infiniteuses`、`FX`、`noshadow` | 渲染与交互 |
| **组件镜像** | `_health`（有 health 组件）、`__health`（预复制） | 客户端据此实例化 `<name>_replica.lua` |

**`_xxx` 组件标签的机制：** 在主模拟上添加可复制组件会给实体打上 `_<name>` 标签；客户端在反序列化标签之后读到这个标签，就实例化 `<name>_replica.lua`。**这是客户端知道"该给我挂什么副本"的唯一线索**——漏了这个标签，副本组件就不会被创建。

### 3.2 空间查询的正确用法

```lua
-- 引擎原生空间查询
TheSim:FindEntities(x, y, z, radius, mustTags, cantTags)
```

**三个必须知道的语义细节：**

| # | 细节 | 后果 |
|---|---|---|
| 1 | `radius` 是**球心距离**（三维），不是水平距离 | 悬崖下的生物会被悬崖顶的光环"挡住"——因为 `distsq` 包含了 y 差 |
| 2 | 大多数"10 单位"的语义实际是 `max_distsq` 平方比较 | 传 10 变成 `distsq <= 100` |
| 3 | 水平查询用 `GetTemperatureAtXZ(x, z)` 这种 XZ 平面查询 | 温度、湿度是水平语义；光环是球形语义 |

**规范：明确区分「水平半径」与「球形半径」，不要在一个系统里混用。** 如果你的光环应该穿透地形，就用水平距离。

**性能要点：** `FindEntities` 每帧在**每个实体**上调用就是 O(N×M)。425×425 世界 3000 个实体，单次全图查询不可接受。做法：
- 缩小半径（优先）
- 加空间网格 / 四叉树（首选）
- 降低频率（缓存一帧，或每 N 刻查一次）

**数量级参考：** 单帧的空间查询总返回实体数超过 **2000** 就需要考虑优化。

### 3.3 "重"不是数值，是标签

DST 没有负重属性。"重"（`heavy` 标签）的效果是：能力门禁（`heavylifting` 封锁动作）、强制 HANDS 槽空出、改变掉落物理。

**对你的设计启示：** 用标签表达"离散的能力开关"，用数值表达"连续的量"。不要为了"重"这个直觉引入一套负重系统。

---

## 4. 事件系统使用规范

### 4.1 核心原语

```lua
-- 订阅：双向记账
function EntityScript:ListenForEvent(event, fn, source)
    source = source or self                      -- 默认监听自己
    AddListener(source.event_listeners, event, self, fn)   -- 数据源记"谁在听我"
    AddListener(self.event_listening, event, source, fn)   -- 我记"我在听谁"
end

-- 派发：先快照再调用
function EntityScript:PushEvent_Internal(event, data, immediate)
    if self.event_listeners then
        local listeners = self.event_listeners[event]
        if listeners then
            local tocall = {}                     -- ★ 复制在前：处理器可能改动监听表
            for entity, fns in pairs(listeners) do
                for i, fn in ipairs(fns) do table.insert(tocall, fn) end
            end
            for i, fn in ipairs(tocall) do fn(self, data) end   -- 处理器签名 (source, data)
        end
    end
    if self.sg then ... self.sg:PushEvent(event, data) end       -- 转发给状态图
    if self.brain then self.brain:PushEvent(event, data) end     -- 转发给脑
end
```

### 4.2 "全局"事件总线就是世界实体

不存在全局单例总线。每个实体有自己的总线，游戏把**世界实体当作事实上的全局频道**：

```lua
TheWorld:PushEvent("playerentered", inst)              -- 服务端 + 客户端都触发
if TheWorld.ismastersim then
    TheWorld:PushEvent("ms_playerjoined", inst)         -- 仅服务端（ms_ = master sim）
end
```

**订阅方必须显式写出数据源：**

```lua
inst:ListenForEvent("ms_playerjoined", OnPlayerJoined, TheWorld)
inst:ListenForEvent("ms_playerleft",   OnPlayerLeft,   TheWorld)
```

**`ms_` 前缀约定（必须遵守）：**

| 前缀 | 语义 |
|---|---|
| 无前缀 | 服务端与客户端都会触发（`playerentered`、`death`、`onbuilt`） |
| `ms_` 前缀 | **仅主模拟触发**（`ms_playerjoined`、`ms_playerleft`、`ms_simunpaused`） |

**常见事件表：**

| 事件 | 推送源 | 含义 |
|---|---|---|
| `entity_spawned` | TheWorld | 任意预制体生成完毕 |
| `ms_playerspawn` | TheWorld | 玩家实体创建（服务端） |
| `ms_playerjoined` / `playerentered` | TheWorld | 已连接 / 进入网络视野 |
| `ms_playerleft` / `ms_playerdisconnected` / `ms_playerdespawn` | TheWorld | 离开 |
| `death` / `entity_death` | inst / TheWorld | 生命值归零 |
| `attacked` / `healthdelta` / `hungerdelta` | inst | 战斗 / 属性变化 |
| `onbuilt` | inst | 结构被建造者放置 |
| `entitysleep` / `entitywake` | inst | 活动区域切换 |
| `onremove` | inst | 实体正在销毁 |
| `enterlimbo` / `exitlimbo` | inst | 被移出/返回场景但未销毁 |
| `<name>dirty` | inst | 某个网络字段变化 → 客户端做出反应 |

### 4.3 世界状态订阅（比事件总线更轻量的观察者）

很多系统（光照、天黑、季节）只需要"某个世界状态变量变了叫我"，不需要完整的事件：

```lua
function EntityScript:WatchWorldState(var, fn)
    TheWorld.components.worldstate:AddWatcher(var, self, fn, self)
end
-- 组件侧可直接写（LoadComponent 注入了辅助函数）
self:WatchWorldState("isnight", self.OnNight)
```

**优势：** 比事件总线轻，不经过事件缓冲与状态图转发。底层保留两级：监听者实体 `inst` + `target`（通常是它上面的某个组件）。`RemoveWatcher` 支持 `fn == nil` 的粗粒度一锅端移除。

**选择规则：**

| 需求 | 用 |
|---|---|
| "发生了某事，带 payload" | 事件总线（`PushEvent`） |
| "某个状态值变了" | 世界状态订阅（`WatchWorldState`） |
| "某个数值变了，要重算派生值" | 属性 setter |
| "每个刻都要做" | `DoPeriodicTask` |
| "有序列的脚本" | `StartThread` + `Sleep` |

### 4.4 事件系统的四个陷阱

| # | 陷阱 | 后果 | 规避 |
|---|---|---|---|
| 1 | **`PushEvent` 未先快照监听表** | 处理器响应 `death` 时调 `inst:Remove()` → `RemoveAllEventCallbacks` 把 `event_listeners` 置 nil → 正在遍历的表行为未定义 | **必须先复制 `tocall`** |
| 2 | **处理器签名是 `(source, data)` 不是 `(data)`** | 回调里第一个参数被误当成 data | 统一写 `function OnAttacked(inst, data)`，且注意这个 `inst` 是**事件源**，不一定是自己 |
| 3 | **双向解绑必须成对** | Lua/C++ 的 GC 不会帮你断开双向引用；`PushEvent` 的 data 被闭包捕获 → 实体死了也被拖住不回收 | 订阅必走 `ListenForEvent`；销毁必走 `RemoveAllEventCallbacks`；在 `Remove` 里**断言无残留监听** |
| 4 | **`PushEvent` 与 `PushEventImmediate` 对状态图影响不同** | 前者缓冲到刻末统一处理，后者同步派发 | 需要"当前调用栈内完成状态转移"时（死亡时立刻进 corpse 态）才用 Immediate |

**关于陷阱 4 的补充**：状态图的事件是**刻末批处理**的：

```lua
-- stategraph.lua:148
function StateGraphWrangler:UpdateEvents()
    local evs = self.haveEvents
    self.haveEvents = {}                    -- ★ 换表法，不是迭代中删除
    for k, v in pairs(evs) do k:HandleEvents() end
end
```

**移植规范：** 状态机采用"事件入队 → 帧末统一 drain"，且**入队期间禁止修改队列容器**。用"换表法"（`local old = self.queue; self.queue = {}`）而不是边遍历边删。

### 4.5 `Remove()` 的重入风险

```lua
for k, v in pairs(self.components) do
    if v and type(v) == "table" and v.OnRemoveEntity then
        v:OnRemoveEntity()                  -- ⚠ 这里如果反过来调 inst:Remove() 就是重入
    end
end
```

某个组件的 `OnRemoveEntity` 里调 `inst:Remove()` → 重入。Lua 允许遍历中删 key，但会**跳过元素**。

**规范：** 实体销毁流程用一个 `is_removing` 标志位，重入时直接 return。

### 4.6 事件 vs 状态图 vs 脑：三套机制的时序差异

| | 事件总线 | 状态图 `sg:PushEvent` | 脑 `brain:PushEvent` |
|---|---|---|---|
| 实现 | 直接调监听者 | 塞进 `bufferedevents` 队列 | 查表直接调 `self.events[event](data)` |
| 时机 | **同步立即** | 更新循环之后统一 `HandleEvents` | **同步立即** |
| 注册 | `ListenForEvent` | `EventHandler` 对象进图或状态 | `brain:AddEventHandler` |
| 来源标记 | 有（source 实体） | 带上 `data.state = currentstate.name` | 无 |

**这个差异会导致难以复现的 Bug：** 脑的事件立即改变状态，状态图的事件排队到刻末。一个动作在"排队期间"被另一个事件取消，就是极难查的问题。

---

## 5. 协程与定时任务的生命周期管理（泄漏重灾区）

### 5.1 四种异步原语的对比

| 原语 | 底层 | 频率 | 适合 | 危险 |
|---|---|---|---|---|
| `DoTaskInTime(t, fn)` | `Periodic` limit=1 | 一次性 | 延迟初始化、延迟发包 | `Sleep(0)` 不是"立即" |
| `DoPeriodicTask(t, fn)` | `Periodic` limit=nil | 固定周期 | 数值衰减、状态轮询 | **回调里不可 yield** |
| `StartUpdatingComponent(c)` | 进 `UpdatingEnts` | 每模拟帧 | 平滑/连续逻辑 | 忘记 Stop → 永久每帧 |
| `StartThread(fn)` | 协程 `Task` | 自己控制 | 有序列的脚本、脑 | 忘记结束 → 泄漏 |

### 5.2 任务的归属机制

```lua
function EntityScript:DoTaskInTime(time, fn, ...)
    local periodic = scheduler:ExecuteInTime(time, fn, self.GUID, self, ...)  -- ★ id = GUID
    self.pendingtasks[periodic] = true
    periodic.onfinish = task_finish
    return periodic
end
```

**`self.GUID` 作为任务 id**，所以 `Remove()` 时调 `KillThreadsWithID(guid)` 就能取消该实体安排的一切任务。**这是"死亡即取消"变成自动行为的关键。**

**规范：所有异步任务一律通过实体发起，绝不在全局调度器上裸挂。**

### 5.3 调度器的数据结构与刻量化

```lua
-- Periodic 记录（scheduler.lua:45）
{ fn, period, limit, nexttick, arg, onfinish }
-- limit = 1 → 一次性；limit = nil → 永久

-- Scheduler 持有
tasks, running, waitingfortick, waking, hibernating
attime = { [tick] = { [periodic] = true } }   -- 绝对刻桶
```

**刻量化调度器的好处：**
- 确定性（时间是整数刻 → 存档友好、可回放）
- 便宜（定时器只在自己的触发刻产生开销）
- 绑定实体 GUID → 自动取消

**`Periodic` 以 table 为键存在 `attime[tick]` 里 → 遍历顺序不确定 → 同一刻到期的多个定时器执行顺序随机。** 有依赖关系的定时器（如"先扣血再检查死亡"）必须用不同的时间或显式串行化。

> ⚠ **移植警告：** 如果你的实现改用数组/向量，"意外地"变成确定性的插队顺序，这会**掩盖 bug**。等你修好依赖问题再享受确定性。

### 5.4 `Sleep()` 的两个陷阱

```lua
-- scheduler.lua:356
function Sleep(time)
    local desttick = math.ceil((GetSchedulerTime(schedule.isstatic) + time) / GetTickTime())
    if GetSchedulerTick(schedule.isstatic) < desttick then
        coroutine.yield(SLEEP, desttick)
    else
        coroutine.yield()          -- ★ 空 yield → 下一帧继续，不是"这一帧末尾"
    end
end
```

1. **`Sleep(0.001)` 会变成"下一帧"**，不是"立即继续"。
2. `OnTick` 里 `assert(k >= tick)` 会对所有等待中的协程断言 → **`Sleep` 到过去的刻会立刻触发断言失败**。时间回拨（服务器校时）会导致这个炸。

### 5.5 泄漏的具体路径

**路径 A：周期任务回调里 yield**

```lua
inst:DoPeriodicTask(1, function()
    self.count = self.count + 1
    if self.count % 10 == 0 then DoSomethingLong() end   -- ← 如果这里 yield 了
end)
```

后果：
1. **周期漂移**：任务在下一次 tick 恢复前不会再次运行 → 1 秒周期实际变成"至少 1 秒 + DoSomethingLong 的时长"
2. **协程泄漏**：此时调 `Cancel()`，协程还活着但被从列表里摘掉 → 永远不 resume 也永远不 dead

**路径 B：闭包持有已销毁实体**

```lua
local function OnSomething(inst, data)
    self.someEntityRef = data.inst        -- ← 捕获了一个可能已销毁的实体
end
inst:ListenForEvent("onremove", OnSomething)   -- 若注册在错误的源上，这个监听会一直活着
```

Lua 的 table 是强引用，GC 无法帮你判断"这个引用是否还有意义"。

**路径 C：`SourceModifierList` 的修饰器源实体销毁**

好消息是 DST 已经处理了：`SetModifier` 时若 `source` 是实体，会自动注册 `onremove` 监听：

```lua
if EntityScript.is_instance(source) then
    self._modifiers[source].onremove = function(source)
        self._modifiers[source] = nil
        self:RecalculateModifier()
    end
    self.inst:ListenForEvent("onremove", self._modifiers[source].onremove, source)
end
```

**你的实现必须照抄这个机制**，否则"装备的帽子被烧掉后，防御力永久 -20%"这类 bug 会成为常态。

**路径 D：`pendingtasks` 遍历时 `onfinish` 改表**

```lua
-- Remove() 里
for k in pairs(self.pendingtasks) do k:Cancel() end   -- Cancel() 触发 onfinish
-- task_finish 里：inst.pendingtasks[task] = nil     -- ★ 改表
```

Lua 的 `pairs` 对"当前 key 被置 nil"是安全的，但若 `onfinish` 往表里**新增** key 就会跳过。

**规范：先快照再取消。**

```lua
local pending = {}
for k in pairs(self.pendingtasks) do pending[#pending+1] = k end
self.pendingtasks = {}
for _, task in ipairs(pending) do task:Cancel() end
```

### 5.6 泄漏的检测方法

**在线检测（开发构建必备）：**

```lua
-- 每 N 刻打印活跃任务数
local n_tasks, n_coroutines = 0, 0
for _ in pairs(scheduler.attime) do
    for _ in pairs(scheduler.attime[_]) do n_tasks = n_tasks + 1 end
end
for _ in pairs(scheduler.running) do n_coroutines = n_coroutines + 1 end
if n_tasks > THRESHOLD or n_coroutines > THRESHOLD then
    print(string.format("[LEAK?][t=%d] tasks=%d coroutines=%d",
        TheSim:GetTick(), n_tasks, n_coroutines))
end
```

**数量级参考：**

| 指标 | 正常 | 需要优化 | 一定有问题 |
|---|---|---|---|
| 活跃定时器总数 | < 500 | 500–2000 | > 2000 |
| 活跃协程数 | < 200 | 200–800 | > 800 |
| 单实体定时器数 | 1–3 | 4–10 | > 10 |
| 单实体事件监听数 | 5–20 | 20–50 | > 50 |

**离线检测：** 反复"生成 1000 个实体 → 全部销毁 ×3 轮"，若任务数/协程数不回到基线，就是泄漏。

---

## 6. 服务端 / 客户端分离的代码规范

### 6.1 唯一的边界标记

```lua
inst.entity:SetPristine()                        -- ① 冻结同步快照
if not TheWorld.ismastersim then return inst end  -- ② 客户端到此为止
-- ③ 以下全部服务端
```

**`TheWorld.ismastersim` 是整个代码库里被检查最频繁的标志**，它守着所有权威逻辑。

### 6.2 副本（replica）组件

```lua
-- components/health_replica.lua
function Health:SetMax(max)                              -- 服务端路径
    if self.classified ~= nil then self.classified:SetValue("maxhealth", max) end
end
function Health:Max()
    if self.inst.components.health ~= nil then          -- 权威模拟
        return self.inst.components.health.maxhealth
    elseif self.classified ~= nil then                  -- 客户端读 netvar
        return self.classified.maxhealth:value()
    else return 100 end
end
```

**API 对称：** 游戏代码在客户端调 `inst.replica.health:GetPercent()`，在服务端调 `inst.components.health:GetPercent()`——概念上是同一套 API，两份实现。

**可复制组件白名单：**

```lua
local REPLICATABLE_COMPONENTS = {
    builder=true, combat=true, container=true, constructionsite=true, equippable=true,
    fishingrod=true, follower=true, health=true, hunger=true, inventory=true,
    inventoryitem=true, moisture=true, named=true, oceanfishingrod=true, rider=true,
    sanity=true, sheltered=true, stackable=true, writeable=true,
}
```

**规范：**
- 服务端**读** replica 是合法的（副本在双端都存在，读它不破坏权威性）
- 服务端**写** replica 会破坏同步 → 建议在框架层加断言报错

### 6.3 classified 实体模式

与其把*一切*复制在玩家身上，DST 生成一个**隐藏的伴生实体** `player_classified`，它**只复制给那一个玩家**：

```lua
inst.player_classified.Network:SetClassifiedTarget(inst)
```

承载该玩家所有的私密状态（生命百分比、理智值、体温、灵感、技能状态）。

**收益：** 隐私可控——你的理智值不会广播给所有人。代价是多一个实体的同步开销。

### 6.4 网络字段（netvar）规范

| 规范 | 理由 |
|---|---|
| `AddNetwork()` 必须在 `SetPristine()` 之前 | `SetPristine` 是拍同步快照的时刻 |
| **按数据大小选类型** | 7 状态枚举用 3 位 `net_tinybyte`，0–255 用 8 位 `net_byte`，字符串 ID 用 32 位哈希 |
| **脏事件监听器延迟到 0 刻注册** | 初始快照里的脏事件风暴会和监听器注册打架 |
| **值未变不产生流量** | `set(x)` 内部比较旧值，真变了才置脏 |
| **`set_local` 只用于"客户端本来就能自己算出来"的值** | `set_local` 会污染下一次 `set` 的脏判定 → 该字段带宽永久退化为"每次 set 都发" |
| **显式字段 ID 而非声明序号** | 声明顺序即 wire format 是隐式契约，单边启用模组会静默错位 |

**带宽选择的量级参考：**

| 数据形态 | 选型 | 每字段开销 |
|---|---|---|
| 2 状态 | `net_bool` | 1 bit |
| 3–7 取值 | `net_tinybyte` | 3 bit |
| 8–63 取值 | `net_smallbyte` | 6 bit |
| 0–255 | `net_byte` | 8 bit |
| 通用整数 | `net_int` | 32 bit |
| 字符串标识 | `net_hash` | 32 bit |
| 数组 | `net_bytearray` | **"expensive"，上限 31** |

**实体首次进入视野时发全量快照；此后只发脏字段，且仅发给对该实体可见的客户端。**

### 6.5 兴趣管理

DST 的兴趣管理是**单一中心点 + 单一半径**：每帧把本地玩家位置喂给引擎，实体进入半径就自动复制进来。

**适用边界：** 小规模生存游戏（≤8 人）+ 开放地形。**这是合理取舍，不是偷懒。**

**扩展到大地图/多人的分层方案：**

| 层 | 做法 |
|---|---|
| L1 空间网格 | 世界切成 cell，客户端订阅自己所在 cell + 8 邻域 |
| L2 静态分级 | 静态实体（建筑/地形）走独立低频通道，不参与动态剔除 |
| L3 显式订阅 | 关键实体（BOSS、任务目标）无视距离强制复制给所有人 |
| L4 优先级队列 | 带宽紧张时先丢 L4，再丢 L3，最后收缩 L1 半径 |

### 6.6 RPC 规范

**三条铁律：**

1. **只发意图，绝不让客户端改状态。** 客户端发送"它想要什么"（动作代码 + 点位），服务器校验并施加。
2. **每一条发往服务器的消息都要重新校验参数 + 限流。** 网络是敌对的，永远不要信任载荷。
3. **同一发送者的 RPC 在同一逻辑刻内最多执行一个。** 把客户端输入天然降采样到模拟频率。

**校验的写法（联合断言）：**

```lua
LeftClick = function(player, action, x, z, target, isreleased, ...)
    if not ( (action == nil and x == nil and ...)                    -- 全 nil
          or (checknumber(action) and checknumber(x) and checknumber(z)
              and optentity(target) and optbool(isreleased) and ...) ) -- 或全部合法
    then
        printinvalid("LeftClick", player)   -- 推送 invalidrpc 事件供反作弊模组用
        return
    end
    if IsPointInRange(player, x, z) then    -- 拒绝距离平方 > 4096 的点击
        playercontroller:OnRemoteLeftClick(...)
    end
end
```

**限流的两个常见缺口：**
- 全局上限可被模组无限抬高（每注册一个模组 RPC 就 +5，没有天花板）
- 告警只打一次

**规范：** 每模组独立配额 + 全局硬上限（不因模组数量而增长）。

---

## 7. 数据驱动的交互动词

交互动词（"PICK"、"CHOP"、"EAT"）**不是按实体硬编码的**。一张大表把 `actiontype → componentName → collector` 映射起来：

```lua
-- componentactions.lua:228（SCENE 动作）
book = function(inst, doer, actions)
    if doer:HasTag("reader") and not inst:HasTag("fire") then
        table.insert(actions, ACTIONS.READ)
    end
end,
```

**链路全景：**

```
客户端：光标指向目标
  → PlayerActionPicker:GetSceneActions(useitem, right)
      → useitem:CollectActions("SCENE", inst, actions, right)   ← ★ 核心
          EntityScript:CollectActions 遍历实体的每个组件
          collector = COMPONENT_ACTIONS[actiontype][组件名]
          collector(inst, ...) 往 actions 里 insert
      → + useitem.inherentsceneaction（网络同步来的固有效）
      → SortActionList(actions, useitem)   按距离/优先级排序
  → 若列表为空且目标可 examine → 降级为 ACTIONS.WALKTO

客户端：玩家按下操作键
  → PlayerController → inst:PushBufferedAction(...)
      → BufferedAction:Start   距离/时长校验 → 播放动作动画（走状态图）
      → 到达时 EntityScript:PerformBufferedAction()
            → 转向目标 → PushEvent("performaction") 
            → bufferedaction:Do()   ← ★ ACTIONS.XXX.fn 里是真正的玩法逻辑
            → 成功：invobject:OnUsedAsItem(action, doer, target)
```

**收益：** 增加一种新的可交互行为 = 加一个组件 + 一个收集器，而不是到处改输入/动词代码。

**硬上限：** `ACTION_COMPONENT_NAMES` 的长度上限是 **255**（`componentactions.lua:3084`），超过直接 assert 失败。这是硬上限不是性能提示。**建议改用位掩码/枚举。**

---

## 8. 关键反模式与正确写法对照

### 反模式 1：在 `OnRemoveEntity` 里漏清任务

```lua
-- ❌ 错误
local MyComponent = Class(function(self, inst)
    self.inst = inst
    self.updatetask = inst:DoPeriodicTask(1, function() self.tick() end)
end, nil, {})

function MyComponent:OnRemoveFromEntity()   -- ← 名字写错了，永远不会被调用
    self.updatetask:Cancel()
end
```

```lua
-- ✅ 正确
function MyComponent:OnRemoveEntity()        -- ← 正确的回调名
    if self.updatetask then self.updatetask:Cancel() end
    self.inst:RemoveEventCallback(...)       -- 顺手清掉可能注册了的事件
end
```

**回调名对照表：**

| 回调 | 何时调用 | 典型用途 |
|---|---|---|
| `OnUpdate(dt)` | 每模拟帧（需先 `StartUpdatingComponent`） | 平滑逻辑 |
| `LongUpdate(dt)` | 大时间跳跃后的追赶 | 离线补偿 |
| `OnSave()` | 存档 | 返回数据表 + 可选的引用列表 |
| `OnLoad(data, newents)` | 读档第一趟 | 恢复状态，存 GUID |
| `LoadPostPass(newents, data)` | 读档第二趟 | 把 GUID 换成实体 |
| `OnEntitySleep()` / `OnEntityWake()` | 进出活动区 | 启停 tick |
| `OnRemoveFromEntity()` | 组件被移除 | 轻量清理 |
| `OnRemoveEntity()` | 实体被销毁 | 完整清理 |

### 反模式 2：直接赋值绕过 setter

```lua
-- ❌ 错误：跳过网络同步、跳过死亡检测、跳过事件
self.currenthealth = 0
```

```lua
-- ✅ 正确：走唯一入口，七阶段有序管线
self:DoDelta(-self.currenthealth, nil, "script")
```

### 反模式 3：`pairs` 遍历中修改集合

```lua
-- ❌ 错误：处理器里 Remove 会把遍历中的表置 nil
function EntityScript:PushEvent_Internal(event, data, immediate)
    for entity, fns in pairs(self.event_listeners[event]) do   -- ← 直接遍历
        for i, fn in ipairs(fns) do fn(self, data) end
    end
end
```

```lua
-- ✅ 正确：先快照再调用
local tocall = {}
for entity, fns in pairs(listeners) do
    for i, fn in ipairs(fns) do table.insert(tocall, fn) end
end
for i, fn in ipairs(tocall) do fn(self, data) end
```

### 反模式 4：用 `pairs` 遍历会发事件的集合

```lua
-- ❌ 错误：哪件护甲先触发 armorbroke 是不确定的
for armor, amt in pairs(absorbers) do
    if amt > 0 then
        armor_damage[armor] = absorbed_damage * amt / total_absorption
        armor:OnBroken()          -- ← 事件触发顺序随机
    end
end
```

```lua
-- ✅ 正确：要发事件就用 ipairs 或显式排序
local ordered = {}
for armor, amt in pairs(absorbers) do ordered[#ordered+1] = {armor=armor, amt=amt} end
table.sort(ordered, function(a, b) return tostring(a.armor) < tostring(b.armor) end)  -- 确定性 tiebreaker
for _, item in ipairs(ordered) do ... end
```

**规则：**
- 纯聚合（max / sum / min）可以用 `pairs`（这些运算可交换）
- **任何"要发事件/要改外部状态"的遍历必须用 `ipairs` 或显式排序 + 确定性 tiebreaker**

### 反模式 5：在服务端写 replica

```lua
-- ❌ 错误：破坏同步
if TheWorld.ismastersim then
    inst.replica.health:SetMax(200)      -- ← 服务端写了只读镜像
end
```

```lua
-- ✅ 正确：服务端写权威组件，setter 自动同步
if TheWorld.ismastersim then
    inst.components.health:SetMax(200)   -- setter → replica → 客户端
end
```

### 反模式 6：Lua 的 `and/or` 三元陷阱

```lua
-- ❌ 错误：Lua 里 0 是 truthy，但 nil 不是
local dapperness = self.get_equippable_dappernessfn ~= nil
    and self.get_equippable_dappernessfn(self.inst, equippable)
    or equippable:GetDapperness(self.inst, self.no_moisture_penalty)
-- fn 返回 0 或 nil 时，会走 or 分支 → 用了错误的函数
```

```lua
-- ✅ 正确：显式写出意图
local item_dapperness = equippable:GetDapperness(owner, no_moisture_penalty)
if self.get_equippable_dappernessfn ~= nil then
    item_dapperness = self.get_equippable_dappernessfn(owner, equippable)
end
```

**推论：Lua/C# 里 `x and y or z` 只有在 y 保证非 nil/false 时才等价于三元运算符。** 涉及数值计算时一律写显式分支。

### 反模式 7：静默失败

```lua
-- ❌ 错误：只打 print，地图少东西玩家不会报错
if #points_x < math.floor(pos_needed) then
    print(self.id.." Didnt get enough points")
    return                    -- 整个节点的内容物丢失
end
```

```lua
-- ✅ 正确：留下可查询的痕迹，并在验收阶段作为警告输出
if #points_x < math.floor(pos_needed) then
    local w = self.stats.silent_drops[self.id] or 0
    self.stats.silent_drops[self.id] = w + 1
    self.stats.dropped_prefabs = self.stats.dropped_prefabs + (pos_needed - #points_x)
    Log.Warn("[worldgen] %s 丢弃 %d 个 %s", self.id, pos_needed - #points_x, self.id)
    return false    -- ★ 返回 false，让上层校验感知到
end
```

### 反模式 8：全局定时器

```lua
-- ❌ 错误：不受实体生命周期管理，实体销毁后仍在跑
scheduler.ExecutePeriodic(1, function() updateAllThorns() end)
```

```lua
-- ✅ 正确：归属到世界实体，Remove 时自动清理
TheWorld:DoPeriodicTask(1, function() updateAllThorns() end)
```

### 反模式 9：`FindEntities` 在每帧对每个实体调用

```lua
-- ❌ 错误：O(N×M)，3000 实体 × 全图查询
function MyComponent:OnUpdate(dt)
    for _, e in ipairs(TheSim:FindEntities(x, y, z, 1000, {"thorn"})) do ... end
end
```

```lua
-- ✅ 正确：降低频率 + 缩小半径 + 缓存
function MyComponent:OnUpdate(dt)
    self.querytick = (self.querytick or 0) + 1
    if self.querytick % 10 == 0 then        -- 每 10 刻一次而非每帧
        self.nearby = TheSim:FindEntities(x, y, z, 20, {"thorn"}, self.inst)
    end
    for _, e in ipairs(self.nearby or {}) do ... end
end
```

### 反模式 10：条件不满足与数据缺失走同一条路径

```lua
-- ❌ 错误：stagedata 为 nil（索引越界）时，用了 10 秒的默认时间，生长反而继续了
if time == nil then
    local stagedata = self:GetCurrentStageData()
    local timefn = stagedata ~= nil and stagedata.time or nil
    if timefn ~= nil then time = timefn(...) else time = FALLBACK_GROWTH_TIME end
end
if time == nil then return end   -- "条件不满足"才早退
```

```lua
-- ✅ 正确：用哨兵值区分三态
if time == nil then
    local stagedata = self:GetCurrentStageData()
    if stagedata == nil then
        Log.Error("阶段数据缺失：stage=%s", tostring(self.stage))  -- 数据缺失 → 显式报错
        return
    end
    time = stagedata.time(self.inst, self.stage, stagedata) or false   -- false = 条件不生长
end
if time == false then return end     -- 条件不满足
```

**规范：用 `nil`（缺失）/ `false`（条件不满足）/ 数字（时长）三态明确区分，绝不让"数据缺失"静默降级为默认值。**

---

## 附：模块边界的单向依赖规则

```
        ┌──────────────┐
        │   引擎层      │  时钟、网络、物理、渲染（Lua 不可改）
        └──────┬───────┘
               ↓
        ┌──────────────┐
        │   框架层      │  class / entity / scheduler / event / stategraph / behaviourtree
        └──────┬───────┘
               ↓
        ┌──────────────┐
        │   玩法层      │  components / prefabs / map / brains
        └──────┬───────┘
               ↓
        ┌──────────────┐
        │  模组层       │  只能通过钩子与白名单 API 访问上层
        └──────────────┘
```

**三条规则：**
1. 引擎层不依赖任何上层
2. 框架层不依赖玩法层（框架不知道什么是"饥饿"）
3. 玩法层之间允许**单向**依赖（components → prefabs 反向不允许）
4. 模组层只能通过**钩子**与**白名单 API**访问，不能直接改核心数据
