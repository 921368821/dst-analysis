# 模组开发接口约定

> 这份文档定义**第三方扩展者可以碰什么、不可以碰什么、怎么碰**。
> 素材来自对 DST 模组系统的完整拆解：`modindex.lua`（清单与依赖）、`mods.lua`（加载与钩子）、`modutil.lua`（API 门面）、`networkclientrpc.lua`（模组 RPC）。
> 标注「DST 的缺口」的条目是原版设计里**明确不完善**的地方——你的实现应该在这些点上做得更好。

---

## 目录

1. [扩展点的设计原则](#1-扩展点的设计原则)
2. [模组清单文件（manifest）](#2-模组清单文件manifest)
3. [生命周期钩子清单](#3-生命周期钩子清单)
4. [依赖声明与加载顺序](#4-依赖声明与加载顺序)
5. [模组间通信](#5-模组间通信)
6. [安全扩展流程：注册新内容](#6-安全扩展流程注册新内容)
7. [沙箱与资源隔离](#7-沙箱与资源隔离)
8. [兼容性策略](#8-兼容性策略)
9. [模组调试方法](#9-模组调试方法)
10. [常见模组错误与后果对照表](#10-常见模组错误与后果对照表)
11. [发版检查清单](#11-发版检查清单)

---

## 1. 扩展点的设计原则

### 1.1 唯一的黄金法则

> **不改任何原版代码，只在既有钩子点插入回调。**

**为什么这是硬约束：**

| 扩展方式 | 后果 |
|---|---|
| 改原版代码 | 上游更新必然冲突；冲突解决要么丢功能要么丢修复 |
| **插入钩子回调** | 上游更新后钩子位置只要还在，模组零改动继续工作 |

DST 的 1594 个预制体、821 个组件里，没有一行是"为了某个模组而加的"，但功能扩展性远超同类作品——**全部靠 `PrefabPostInit` / `ComponentPostInit` / `StategraphPostInit` 这套延迟钩子**。

### 1.2 钩子的两种形态

**这是扩展点设计里最重要的一个区分。**

| 形态 | 钩子名 | 提供什么 | 什么时候用 |
|---|---|---|---|
| **函数型**（fn） | `GetPostInitFns(type, id)` | 一个**要执行的函数** | 你的行为需要读引擎内部状态才能做决策 |
| **数据型**（data） | `GetPostInitData(type, id)` | 一个**要贡献的对象** | 你只是想往引擎的表里加一条配置 |

**实现上的区别（照抄 `stategraph.lua:288-319`）：**

```lua
-- 数据型：引擎把你的对象并入自己的表
for k, modhandlers in pairs(ModManager:GetPostInitData("StategraphActionHandler", self.name)) do
    for i, v in ipairs(modhandlers) do
        assert(v:is_a(ActionHandler), "Non-action handler added in mod actionhandler table!")
        self.actionhandlers[v.action] = v
    end
end

-- 函数型：引擎调用你的函数
local modfns = ModManager:GetPostInitFns("StategraphPostInit", self.name)
for i, modfn in ipairs(modfns) do modfn(self) end
```

**规范：需要引擎内部状态的钩子用 fn；只需要贡献数据的钩子用 data。** 用错了会导致时机不对——data 型钩子的执行点在"对象构建完成后"，那时你的对象已经被合并进引擎的表了，再想改已经晚了。

### 1.3 「通用钩子 + 过滤条件」= 专用钩子

**绝大多数"专用钩子"都是糖。** DST 里**没有** `PlayerPostInit` 这个钩子，它是这样定义的（`modutil.lua:586-590`）：

```lua
env.AddPlayerPostInit = function(fn)
    env.AddPrefabPostInitAny(function(inst)
        if inst and inst:HasTag("player") then fn(inst) end
    end)
end
```

**推广这条规则：** 你的 API 里每加一个专用钩子，都要问一句"它是不是通用钩子 + 一个过滤条件"。如果是，就不要新增钩子——**新增钩子意味着新增一条需要长期维护的兼容承诺。**

### 1.4 钩子的注册与执行时机

**注册不是执行。** 这句话是整个钩子系统的关键。

```lua
-- modutil.lua:592：注册只是 table.insert，一行都不执行
env.AddPrefabPostInit = function(prefab, fn)
    if env.postinitfns.PrefabPostInit[prefab] == nil then
        env.postinitfns.PrefabPostInit[prefab] = {}
    end
    table.insert(env.postinitfns.PrefabPostInit[prefab], fn)
end
```

**为什么必须延迟：** 模组加载时，被扩展的对象**还不存在**。`rock` 这个预制体此刻只是一张工厂函数，还没有实例化。延迟到"引擎确切地造出这个对象之后"才回调，才可能改它。

**规范：注册钩子的代码必须是纯数据操作，不能有副作用。** 副作用全部放在回调里。

---

## 2. 模组清单文件（manifest）

### 2.1 四阶段加载流程

DST 的 `modinfo.lua` 加载（`modindex.lua:511` `LoadModInfo` → `InitializeModInfo`）分四阶段。**你的实现应该照抄这个分阶段结构**，因为每一阶段处理不同类型的问题。

```
阶段 1  沙箱执行 manifest 文件（拿到一张纯数据的表）
   │     ↓ 注意：连 print 都没有暴露——manifest 应该是纯声明式的，不该有副作用
   │
阶段 2  API 版本闸门（双向，见 §8.1）
   │     ↓
   │
阶段 3  必填字段校验（分「硬失败」与「仅警告」两级，见 §2.3）
   │     ↓
   │
阶段 4  默认值兜底 + `*_specified` 影子标记（见 §2.4）
```

### 2.2 清单字段表

| 字段 | 类型 | 必填 | 缺失后果 | 说明 |
|---|---|---|---|---|
| `name` | string | **硬失败** | 模组无法在 UI 里显示 | 用户可见名 |
| `description` | string | **硬失败** | — | 多行文本 |
| `author` | string | **硬失败** | — | 支持 `{GAME}, {KLEI}, {PLAYER}` 占位符 |
| `version` | string | **硬失败** | — | 建议 `major.minor.patch` 三段 |
| `api_version` | number | **硬失败** | — | 见 §8.1 双向闸门 |
| `dst_compatible` | bool | 仅警告 | 打印"未声明是否兼容联机版" | 缺失时只警告 |
| `dont_starve_compatible` | bool | 仅警告 | 兼容单机的老模组 | 缺失时默认 `true` + `*_specified = false` |
| `reign_of_giants_compatible` | bool | 仅警告 | 同上，老字段 | 缺失时默认 `true` + 影子标记 |
| `configuration_options` | table | 不检查 | — | **完全可以没有**，不要因此报错 |
| `priority` | number/string | 否 | 0 | 降序排列；容忍字符串 `"10"` |
| `mod_dependencies` | table | 否 | 依赖缺失则禁用本模组 | 见 §4.1 |
| `client_only_mod` | bool | 否 | — | 纯客户端，不参与同步 |
| `all_clients_require_mod` | bool | 否 | 与 `client_only_mod` **互斥** | 两者同时声明会警告 |
| `forcemanifest` | bool | 否 | 创意工坊模组默认开 | 本地模组默认关 |
| `server_only_mod` | bool | 否 | — | ⚠ 见 §8.3 的限制 |

**校验的两级严重性**（照抄 `modindex.lua:628` 的 `checkinfo` 表的分级处理）：

```lua
local checkinfo = { "name", "description", "author", "version", "api_version",
                    "dont_starve_compatible", "reign_of_giants_compatible",
                    "configuration_options", "dst_compatible" }
local missing = {}
for i, v in ipairs(checkinfo) do
    if env[v] == nil then
        if v == "dont_starve_compatible" then
            -- 只警告但仍加载
        elseif v == "configuration_options" then
            -- 什么都不做：没有配置项完全正常
        else
            table.insert(missing, v)
        end
    end
end
if #missing > 0 then
    Log.Error("Error loading modinfo.lua. These fields are required: " .. table.concat(missing, ", "))
    env.failed = true
end
```

**两级分层的价值：** 真正必填的缺失 → 硬失败（用户必须改）；只是"建议声明"的缺失 → 只警告（不破坏已有的模组）。**这直接决定了有多少老模组能继续跑。**

### 2.3 互斥标志检测

**DST 会检测互斥组合并警告**（`modindex.lua:671-673`）：

```lua
if env.client_only_mod and env.all_clients_require_mod then
    Log.Warn("modinfo.lua: %s specifies client_only_mod and all_clients_require_mod. " ..
             "These flags are mutually exclusive.", modname)
end
```

**规范：任何一对语义冲突的布尔标志，都要在加载期检测并警告。** 冲突时的默认行为要有明确的文档（DST 选择"不改变行为，只警告"，这是保守正确的选择）。

### 2.4 `*_specified` 影子标记

**这是一个值得学的细节**（`modindex.lua:665-677`）：

```lua
if env.dont_starve_compatible == nil then
    env.dont_starve_compatible = true
    env.dont_starve_compatible_specified = false    -- ★ 影子标记
end
```

**它让游戏知道"这个值是我猜的，不是模组作者声明的"。** 价值在于将来可以据此给出更谨慎的兼容行为——比如将来加入单机专属 API 时，对"没声明 `dont_starve_compatible` 的模组"给出更严格的检查。

**规范：所有"缺省兜底"的字段都要配一个 `*_specified` 影子标记**，区分「用户明确设了 false」和「没设，默认为 true」。这两者在做兼容性决策时完全不同。

### 2.5 manifest 的沙箱

```lua
-- modindex.lua:593：极小的 env
local env = {
    folder_name  = modname,
    locale       = LOC.GetLocaleCode(),
    ChooseTranslationTable = function(tbl)
        return tbl[LOC.GetLocaleCode()] or tbl[1]
    end,
    -- ★ 注意：连 print 都没有暴露
}
```

**规范：manifest 在极简沙箱里执行，连 `print` / `io` / `os` 都不给。** 理由是 manifest 应该是纯声明式的——任何副作用都属于"这段代码不该出现在 manifest 里"的信号，应该移到 `modmain.lua`。

---

## 3. 生命周期钩子清单

### 3.1 九类钩子的时机与用法

**这是模组作者最需要的一张表。** 每一行都注明：调用时机、签名、以及**正确用法**与**常见误用**。

| # | 钩子 | 调用时机 | 签名 | 正确用法 | 常见误用 |
|---|---|---|---|---|---|
| 1 | `GamePostInit` | `SetPostEnv` 里（`mods.lua:772/784`） | `fn()` | 只注册全局钩子，不碰实体 | 在这里就 SpawnPrefab |
| 2 | `SimPostInit` | **世界完全加载之后**（`mods.lua:845-854`） | `fn(wilson)` | 跑只在有世界时才跑的一次性逻辑 | 当作"游戏开始"钩子用（此时世界可能有多个） |
| 3 | `PrefabPostInit[prefab]` | `prefab.fn(TheSim)` 之后（`mainfunctions.lua:368-381`） | `fn(inst)` | 改属性、加组件、改初始状态 | 在这里做"等一会再做的事" |
| 4 | `PrefabPostInitAny` | 每次生成后无条件（`mainfunctions.lua:383-385`） | `fn(inst)` | 做通用判定（配合标签） | 忘了过滤 → 对 3000 个实体全跑一遍 |
| 5 | `ComponentPostInit[comp]` | `AddComponent` 末尾（`entityscript.lua:637-641`） | `fn(component, entity)` | 改组件默认参数、加属性 setter | 假定组件的 `OnSave` 已跑过 |
| 6 | `StategraphState/Event/ActionHandler` | `StateGraph` 构造时（`stategraph.lua:288/301/309`） | 贡献**对象**（data 型） | 加新状态、新动作处理器 | 用函数型钩子代替数据型（时机不对） |
| 7 | `StategraphPostInit[sg]` | 状态图构建后（`stategraph.lua:319`） | `fn(sg)` | 改现有状态、加状态标签 | 在这里加 `onenter` 却不知道原状态已经进入过了 |
| 8 | `RoomPreInit[room]` | **每次调用** `Story:GetRoom` 都跑（`storygen.lua:99`） | `fn(room)` | 改房间数据表 | 假设只跑一次（见 §3.3 的性能注记） |
| 9 | `LevelPreInit` / `LevelPreInitAny` | 关卡预设生成时 | `fn(level)` | 改关卡配置 | — |

### 3.2 钩子的执行顺序（必须对外声明）

**DST 的实际规则：** `GetPostInitFns` 遍历 `self.enabledmods`，而 `enabledmods` 是按 priority 排好序后依次插入的 → **高 priority 模组的钩子先执行** → **后加载的覆盖先加载的**。

**⚠ 这个规则本身没有对外声明过**，模组作者会写出无法诊断的 bug（两个模组都改同一个属性，效果与预期相反，且在不同机器上表现不同）。

**你的实现必须把它写进文档，并且建议的语义是：**

> **priority 高 = 后执行 = 覆盖别人**（符合"高优先级模组理应赢"的直觉）

如果采用这个语义，排序需要改成升序，或者在文档里明确写"高 priority 先执行，因此它会被后加载的覆盖"——**两种都可以，但必须写出来**。

### 3.3 「每次调用」的钩子不是免费的

**`RoomPreInit` 是一个性能陷阱。** `Story:GetRoom` 每次调用都跑一遍 `ModManager:GetPostInitFns("RoomPreInit", roomname)`（`storygen.lua:99`）。而且 `GetRoom` 内部会 `deepcopy(Rooms.GetRoomByName(roomname))`（`storygen.lua:107`）——**每调用一次就深拷贝一份房间数据表**。

**量级：一个 131 任务 × 8 房间的世界会跑约 1000 次模组钩子查询**，加上 1000 次深拷贝。模组多的时候这本身就是可观开销。

**规范：给「每次调用」类钩子加一个注册期的一次性处理路径。** 比如模组在 `GamePostInit` 时就把改好的房间表注册进引擎的覆盖表，而不是在每次 `GetRoom` 时重新计算。

### 3.4 钩子的错误隔离

**每个钩子调用都必须独立隔离**（照抄 `mods.lua:192-206` 的 `runmodfn`）：

```lua
local runmodfn = function(fn, mod, modtype)
    return function(...)
        if fn then
            local status, r = xpcall(function() return fn(unpack(arg)) end, debug.traceback)
            if not status then
                Log.Error("error calling %s in mod %s:\n%s", modtype, ModInfoname(mod.modname), r or "")
                ModManager:RemoveBadMod(mod.modname, r)
                ModManager:DisplayBadMods()      -- 带错误对话框
            else
                return r
            end
        end
    end
end
```

**一条模组钩子抛错 → 整个模组被禁用 + 弹出错误界面，其他模组不受影响。这是模组生态能长期运转的关键工程投入。**

**必须配套的两件事：**

| 事项 | 做法 | 不做的后果 |
|---|---|---|
| **错误对话框** | 构造一个带「退出游戏 / 禁用所有模组 / 访问论坛」三个按钮的界面 | 玩家看到一个 Lua 堆栈就不知道该怎么办 |
| **依赖者连带禁用** | 禁用 A 时，把依赖 A 的 B、C、D 也禁用 | A 没了但 B 还在跑，B 调用 A 的 API 就崩 |

### 3.5 钩子的正确用法清单

**给模组作者的 checklist：**

```
□ 我的 hook 函数在极端情况下会不会报错？（收到 nil 的 inst、缺组件的实体）
□ 我的 hook 会不会对所有实体都跑？（PrefabPostInitAny 必须过滤）
□ 我有没有在 hook 里修改正在被遍历的集合？
□ 我有没有在 hook 里假设"这是第一次被调用"？（RoomPreInit 是每次调用）
□ 我有没有在 hook 里做长耗时操作？（会阻塞生成/加载）
□ 我的 hook 出错时，禁用我这个模组会不会连带影响别人的数据？
□ 我有没有假设某个钩子的执行顺序？
```

---

## 4. 依赖声明与加载顺序

### 4.1 多版本候选依赖

**DST 的 `mod_dependencies` 语法不是"依赖某个模组"，而是"依赖某个模组的候选版本列表"**（`modindex.lua:571-589`）：

```lua
if info.mod_dependencies and not info.client_only_mod then
    local dependencies = {}
    self.savedata.known_mods[modname].dependencies = dependencies
    for i, v in ipairs(info.mod_dependencies) do
        -- 如果某个版本已经启用，优先用它
        local enabledmod = FindEnabledMod(self, v)
        if enabledmod then
            table.insert(dependencies, {enabledmod})
        else
            local mods = BuildModPriorityList(self, v, IsWorkshopMod(modname))
            if #mods == 0 then
                Log.Warn("no valid dependent mod found for mod "..modname)
                self:DisableBecauseBad(modname)      -- ★ 依赖缺失 → 连带禁用本模组
            end
            table.insert(dependencies, mods)
        end
    end
end
```

**这解决的真实问题是：** "用户装了 2.0 但依赖方要求 1.5"。**不硬失败，而是给出一个有序候选集让 UI 去提示。**

`BuildModPriorityList`（`modindex.lua:492-508`）的排序规则：**本地已启用的版本排最前，创意工坊版本排中间/末尾。**

**规范：依赖声明应该是一个候选集，而不是一个精确版本。** 硬性版本约束只在 API 版本这类地方用（见 §8.1）。

### 4.2 递归解析与环检测

`modindex.lua:1143-1167` 的 `GetModDependencies` 用一个廉价但有效的环检测：**把当前 modname 先塞进结果集**。

```lua
local deps = rec_deps or {}
--add our modname to the deps to prevent circular dependency loops
deps[modname] = true
for i, mods_dep in ipairs(dependencies) do
    if not IsModAlreadyDepended(deps, mods_dep) then
        deps[mods_dep[1]] = true
        new_deps[mods_dep[1]] = true
    end
end
if recursive then
    for _modname in pairs(new_deps) do self:GetModDependencies(_modname, recursive, deps) end
end
if rec_deps == nil then
    deps[modname] = nil          -- 顶层调用时把自己摘掉
    return table.getkeys(deps)
end
```

**⚠ DST 的缺口：** 这种检测**不会报出「哪里成环」，只会静默截断**。用户看到的是"依赖没生效"而不是"你的依赖图有环"。

**你的实现应该做一次 DFS 并记录路径：**

```
依赖图存在环：A → B → C → A
建议的截断点：按 priority 最低的那个节点
警告文案："mod A 的依赖图存在环：A→B→C→A，已按 priority 截断（A 的 priority 最低）"
```

### 4.3 拓扑排序 ≠ priority 排序

**⚠ 这是 DST 最明显的缺口：** DST **没有拓扑排序**，只有 priority 排序。这会导致"priority 低的 B 依赖 priority 高的 A，但 B 先加载了"→ B 的 `modmain` 执行时 A 的 API 还不存在。

| 环节 | DST 现状 | 建议实现 | 理由 |
|---|---|---|---|
| 依赖排序 | 无拓扑排序，只有 priority | **加拓扑排序** | priority 是"提示"，依赖是"硬约束"，两者混用会加载失败 |
| 环检测 | 静默截断 | **记录路径并警告** | 让模组作者能诊断 |

**规范：加载顺序 = 拓扑序（同层内按 priority 降序 + 名字稳定排序）。** 这两个键都必须有：拓扑保证依赖正确，priority + 稳定排序保证可复现。

### 4.4 反向依赖用引用计数

**不能用布尔标记**——多个模组可能依赖同一个 X，禁用其中一个不该让 X 的计数归零。

```lua
-- modindex.lua:1199-1225
function ModIndex:IsModDependedOn(modname)
    return (self.mod_dependencies.server_dependency_list[modname] or 0) > 0
end
function ModIndex:AddModDependency(modname, nosubscribe)
    if IsWorkshopMod(modname) and not KnownModIndex:DoesModExistAnyVersion(modname) then
        if nosubscribe then return end
        TheSim:SubscribeToMod(modname)      -- 缺依赖时自动订阅下载
    end
    self.mod_dependencies.server_dependency_list[modname]
        = (self.mod_dependencies.server_dependency_list[modname] or 0) + 1
end
```

`IsModDependedOn` 是"**不能禁用这个模组**"的守卫。

**规范：**
1. 反向依赖用引用计数，不用布尔。
2. 缺依赖时**自动订阅/下载**（如果来源支持）。
3. 依赖缺失导致本模组不可用时，**连带禁用**本模组。
4. `GetModDependenciesEnabled()` 用来在准备启动时检查"所有依赖是否都启用了"。

### 4.5 加载顺序的完整流程

照抄 `mods.lua:470` 的 `LoadMods` 序列：

```
1. 专用服务器 → LoadServerModsFile()
2. 前端上下文 → ClearAllTempModFlags() + DisableAllServerMods()
3. KnownModIndex:UpdateModInfo() → LoadModOverides() → ApplyEnabledOverrides()
4. moddirs = KnownModIndex:GetModsToLoad(worldgen)
5. 对每个 moddir：加载配置 → CreateEnvironment → env.modinfo = initenv → 收集
6. ApplyConfigOptionOverride()
7. 排序（★ 建议：拓扑 + priority + 稳定 tiebreaker）
8. kleiregistermods(self.mods)          ← 一次性向引擎注册所有 Prefab/Asset
9. 逐个：
   扩展 package.path / package.assetpath
   → InitializeModMain(modworldgenmain.lua)
   → InitializeModMain(modmain.lua)
```

**第 8 步值得注意：一次性批量注册，而不是逐个注册。** 这样引擎能并行加载资产，也便于在真正执行任何代码之前就把「哪些预制体存在」确定下来。

---

## 5. 模组间通信

### 5.1 三条通道

| 通道 | 紧度 | 有无加载顺序保证 | 适用 | 推荐度 |
|---|---|---|---|---|
| **① 共享全局命名空间** | 最松 | **无** | 纯粹的数据共享（配置常量） | ⚠ 只读共享可以 |
| **② 钩子协作** | 中 | 隐式（priority） | 两个模组改同一对象的不同方面 | ✅ 推荐 |
| **③ 模组 RPC** | 最紧 | 显式命名空间 | 需要跨模组调用/通信的场景 | ✅ 推荐 |

### 5.2 通道①：共享全局（谨慎使用）

模组通过 `GLOBAL` 表通信：`GLOBAL.MyModSharedState = ...`。

**因为所有模组共享同一个 `_G`，这在技术上可行，但没有任何加载顺序保证**（谁先初始化取决于 priority）。**这在实践中被大量使用，也是"两个模组互相污染"类 bug 的根源。**

**规范：**
- ✅ 只**写一次**常量（`GLOBAL.MyMod.VERSION = "1.0"`），只**读**别人的值。
- ❌ 不要在 `PrefabPostInit` 里改 `GLOBAL.SomeOtherModConfig`——那是在别人初始化之前/之后改别人的私有状态。
- ✅ 更安全的做法：暴露一个 API 表而不是散落的全局变量：
  ```lua
  GLOBAL.MyModAPI = {
      version = "1.0",
      get_damage = function(inst) return inst.components.mycomponent:GetDamage() end,
  }
  ```

### 5.3 通道②：钩子协作

一个模组注册 `AddPrefabPostInit("rock", fn)` 改属性，另一个模组也注册同样的钩子，两者的执行顺序由 priority 决定。**没有显式的"依赖"关系，只有隐式的时序契约。**

**规范：写钩子时永远假设"别人的钩子可能在你之前或之后执行"。** 具体做法：
- **只加不删**：用"追加"而不是"替换"。
- **读-改-写**时基于当前值：`local v = inst.components.health.maxhealth; inst.components.health:SetMax(v * 1.5)` 而不是硬编码 `SetMax(150)`。
- 需要"严格在别人之后"时，在 `mod_dependencies` 里声明依赖——**依赖关系会保证拓扑顺序**（见 §4.3）。

### 5.4 通道③：模组 RPC

```lua
-- networkclientrpc.lua:1834
function AddModRPCHandler(namespace, name, fn)
    if MOD_RPC[namespace] == nil then
        MOD_RPC[namespace] = {}
        MOD_RPC_HANDLERS[namespace] = {}
        setmetadata(MOD_RPC[namespace])
        setmetadata(MOD_RPC_HANDLERS[namespace])
    end
    table.insert(MOD_RPC_HANDLERS[namespace], fn)
    MOD_RPC[namespace][name] = { namespace = namespace, id = #MOD_RPC_HANDLERS[namespace] }
    setmetadata(MOD_RPC[namespace][name])
    RPC_QUEUE_RATE_LIMIT = RPC_QUEUE_RATE_LIMIT + RPC_QUEUE_RATE_LIMIT_PER_MOD
end
```

**三个值得照抄的设计：**

| 设计 | 代码 | 价值 |
|---|---|---|
| **大小写不敏感** | `setmetadata` 给表挂了 `__index_lower` / `__newindex_lower` | `MOD_RPC["MyMod"]["RequestHeal"]` 与 `MOD_RPC["mymod"]["requestheal"]` 是同一个条目。**极大降低心智负担** |
| **不占用内建槽位** | 内建 RPC 只有 127 个可用槽位（`networkclientrpc.lua:1386`），模组走独立空间 | 加模组不会耗尽内建槽位 |
| **自动订阅下载** | 见 §4.4 | 依赖链上缺哪个自动补哪个 |

**大小写不敏感的具体实现**（`networkclientrpc.lua:1804-1814`）：

```lua
local function __index_lower(t, k)  return rawget(t, string.lower(k)) end
local function __newindex_lower(t, k, v) rawset(t, string.lower(k), v) end
local function setmetadata(tab)
    setmetatable(tab, { __index = __index_lower, __newindex = __newindex_lower })
end
```

### 5.5 通道③的两个缺口（你的实现必须修）

| 缺口 | 代码 | 后果 | 修法 |
|---|---|---|---|
| **命名空间可被劫持** | `MOD_RPC[namespace][name] = {...}` 是无条件赋值 | 模组 A 可以劫持模组 B 的 RPC，后注册者覆盖先注册者 | `if MOD_RPC[ns][name] then error("RPC already registered") end`；namespace 强制为 `modname..":"..namespace` |
| **全局限流可被无限抬高** | `RPC_QUEUE_RATE_LIMIT = RPC_QUEUE_RATE_LIMIT + RPC_QUEUE_RATE_LIMIT_PER_MOD` **无上限** | 一个模组注册上万个 RPC 就能把限流抬到天上，让真正的攻击流量畅通无阻 | 每模组独立配额 + **全局硬上限**（不因模组数量而增长） |

**限流的两个其他细节必须照抄：**

```lua
-- ① 归零后清表，防内存泄漏
local limit = (RPC_Queue_Limiter[sender] or 1) - 1
if limit == 0 then
    RPC_Queue_Limiter[sender] = nil      -- ★ 不清的话伪造 sender 能撑爆这张表
    RPC_Queue_Warned[sender] = nil
end

-- ② 每刻重置时间线，实现"同刻重入保护"
function TickRPCQueue()
    RPC_Timeline = {}
    RPC_Client_Timeline = nil
    RPC_Shard_Timeline = {}
end
```

**限流的告警只打一次**（`RPC_Queue_Warned[sender]`）——否则一个持续攻击的客户端能把控制台刷爆。但这意味着**日志本身不会告诉你"攻击持续了多久"**；生产环境应把这张表接入监控而非只看日志。

### 5.6 通道选择建议

```
需要跨模组共享一个常量？        → ①，但用 API 表而不是散落的全局变量
需要两个模组改同一个对象的属性？→ ②，用读-改-写而不是硬编码
需要 A 模组主动通知 B 模组做事？→ ③，走模组 RPC + 显式依赖声明
需要访问对方的内部状态？        → ❌ 不该做。应该让对方暴露 API
```

---

## 6. 安全扩展流程：注册新内容

### 6.1 注册新物品 / 预制体

**流程：**

```
第 1 步  在 modmain.lua 里定义预制体工厂函数
         local assets = { Asset("ANIM", "anim/myitem.zip"), Asset("ATLAS", "images/inventoryimages.xml") }
         local prefabs = { "myitem_fx" }          -- ★ deps：会生成的预制体

         local function fn()
             local inst = CreateEntity()
             inst.entity:AddTransform()
             inst.entity:AddAnimState()
             inst.entity:AddNetwork()            -- ★ 必须在 SetPristine 之前
             inst.AnimState:SetBank("myitem")    -- ★ 必须在 SetPristine 之前
             inst.AnimState:SetBuild("myitem")
             inst.entity:SetPristine()          -- ★ 同步快照定格
             if not TheWorld.ismastersim then return inst end   -- ★ 客户端到此为止

             inst:AddComponent("inventoryitem")
             inst:AddComponent("stackable")
             inst:AddComponent("perishable")     -- ★ 可复制组件必须已登记
             inst:AddTag("myitem")
             return inst
         end
         return Prefab("myitem", fn, assets, prefabs)

第 2 步  在 modmain.lua 里注册全局查找表
         GLOBAL.MyItem = { fn = fn, assets = assets, prefabs = prefabs }

第 3 步  ★ 关键：重载 ALL_CRAFTABLES / 配方表
         AddRecipe2("mycraft", { Ingredient("twigs", 4) }, TECH.SCIENCE_ONE, {pfx="myitem/anim_common", product="myitem", numtorandom=1 })

第 4 步  资源文件放在模组根目录，引擎按 assetpath 搜索路径解析
```

**四个必须遵守的顺序约束（这些是框架硬约束，不是风格建议）：**

| # | 约束 | 违反后果 |
|---|---|---|
| 1 | `AddNetwork()` 在 `SetPristine()` **之前** | 客户端拿不到网络实体 |
| 2 | `AddComponent("locomotor")` 在 `SetStateGraph()` **之前** | 状态图构造时会查询它，找不到 |
| 3 | 所有 `netvar` 声明在 `SetPristine()` **之前** | 客户端没有这些字段 |
| 4 | 组件名一律小写 | 存档字段名不兼容（见 `bug-patterns.md` C3） |

**第 3 步是最容易漏的一步：** 很多模组作者注册了预制体但忘了把配方加进全局表，结果物品存在但做不出来。

### 6.2 注册新的交互动作

**不要写 switch。用收集器模式**（`componentactions.lua`）：

```lua
-- 贡献一个收集器函数：往 actions 里插入可选动词
GLOBAL.COMPONENT_ACTIONS.SCENE.mycomponent = function(inst, doer, actions)
    if doer:HasTag("player") and inst:HasTag("mycomponent") then
        table.insert(actions, MYACTIONS.MYUSE)
    end
end
```

**⚠ 硬上限：`ACTION_COMPONENT_NAMES` 的长度上限是 255**（`componentactions.lua:3084`），超过直接 assert 失败。**这是硬上限不是性能提示。** 你的实现应该改用位掩码/枚举而不是双层查表。

**动词本身的定义**（动作路由集中在一张表，`ACTIONS.XXX.fn` 里是真正的玩法逻辑）：

```lua
GLOBAL.ACTIONS.MYUSE = {
    name   = "myuse",
    order  = 100,
    dest   = "doer",
    fridget   = 1.0,      -- 冻结时间（朝向目标的过程）
    acttimeout = 0.8,     -- 到达后多久执行
    condition = function(inst, doer, pos) ... end,   -- ★ 见 §6.5
    fn = function(ba) ... end,                         -- 真正的逻辑
}
```

### 6.3 注册新状态图状态

**两种粒度：**

```lua
-- ① 贡献一个新状态对象（data 型钩子）
GLOBAL.StategraphState["mylootstate"] = State{
    name = "mylootstate",
    onenter = function(self, inst)
        inst:DoTaskInTime(0.5, function() inst.sg:GoToState("idle") end)
    end,
    tags = { "busy" },     -- ★ 状态标签是状态图与外部世界的唯一契约
}

-- ② 修改一个已存在的状态图（fn 型钩子）
AddStategraphPostInit("SGwilson", function(sg)
    sg.states["mycustom"].onexit = function(self, inst) ... end
end)
```

**规范：状态标签是状态图与外部世界之间的**唯一**契约。** 别的系统只通过标签提问（`inst:HasTag("busy")` = 不能被打断、`sg:HasStateTag("attack")` = 正在攻击）。**新加一个状态不需要改任何外部代码，只要挂对标签。**

**新增状态时必须挂的标签：**

| 标签 | 含义 | 不挂的后果 |
|---|---|---|
| `busy` | 正在做事，不能被打断 | 玩家的操作会打断它 |
| `doing` / `working` | 可被打断的工作 | — |
| `attack` | 正在攻击 | 其他系统判断"是否在战斗中"会出错 |
| `noattack` | 不能攻击 | — |
| `moving` | 在移动 | 影响移动预测 |
| `pausepredict` | 暂停客户端预测 | 客户端会预测错 |

### 6.4 注册新配方

```lua
AddRecipe2("myrecipe", { Ingredient("twigs", 4), Ingredient("rocks", 1) },
           TECH.SCIENCE_ONE,
           { pfx="myitem/anim_common", product="mycraft", numtorandom=1 })
```

**注意 `recipe.lua` 里的一个加载期 assert：** 对角色材料为 5 的倍数有校验（科技点数必须是 5 的倍数）。这是**注册期断言**（不是运行期），做对了能省掉后面所有的排查。

### 6.5 「condition 为假时静默什么都不做」的陷阱

**这是模组作者最容易犯的错。** `StartAction`（`stategraph.lua:430`）：

```lua
if handler then
    if not handler.condition or handler.condition(self.inst) then
        ...
    end
    -- ★ 如果 condition 为假，这里什么都不做，直接返回 nil
end
```

返回 nil 的含义是"这个动作没被接受"，但调用方（locomotor）**已经走到了目标位置**。**结果：玩家/AI 会走到某个东西面前，然后什么也不做地站一会儿。**

**规范：模组注册的动作如果带 `condition`，必须在 UI/提示上让玩家知道"为什么现在不能做"。** 否则玩家只会觉得游戏卡了。

**配套的 `ClearBufferedAction()`：** 被受击打断的状态必须在 `onexit` 里调 `inst:ClearBufferedAction()`。DST 只在 `hit` 状态里做了这件事，**其它可打断状态没做**。如果你新增了一个"可以被打断的挖掘状态"而忘了加，**玩家受击后挖掘动画会继续跑完并产出资源**——这是玩家最容易发现的 bug 类型。

### 6.6 修改现有组件属性

```lua
-- 推荐：读-改-写，基于当前值
AddPrefabPostInit("rock", function(inst)
    local h = inst.components.health
    h:SetMax(h:GetMax() * 1.5)           -- ★ 不硬编码绝对值
    h:SetCurrent(h:GetMax())             -- ★ 同步设置当前值，否则血条显示不一致
end)
```

**三条规则：**

| 规则 | 理由 |
|---|---|
| **不硬编码绝对值** | 另一个模组已经改过这个值，你的覆盖会让它失效 |
| **改 max 后同步改 current** | 否则会出现"血条显示 50/200 但实际 50/100"的错乱 |
| **走 setter 不走裸赋值** | 裸赋值跳过网络同步、跳过死亡检测、跳过事件（见 `SKILL.md` 约束 3） |

### 6.7 拦截器返回值可能是 nil

**这是 AI 卡住的一个已知原因。** 模组的拦截器（`redirect`、`deltamodifierfn`、`condition` 等函数指针型钩子）如果返回 nil，原版的语义是"条件为假就什么都不做"——**不是"用默认值"**。

**规范：拦截器返回 nil 时，要显式决定"跳过"还是"用默认值"，并在文档里写清楚。** 对"减伤"这类叠加型拦截器，惯例是返回 `0`（表示"我不改变"）而不是 `nil`。

---

## 7. 沙箱与资源隔离

### 7.1 DST 沙箱的能力边界

**必须理解这一点，否则会误以为"沙箱 = 安全"。** DST 用 Lua 5.1 的 `setfenv`：

```lua
-- util.lua:786
function RunInEnvironment(fn, fnenv)
    setfenv(fn, fnenv)
    return xpcall(fn, debug.traceback)
end
function RunInSandbox(untrusted_code)
    if untrusted_code:byte(1) == 27 then return nil, "binary bytecode prohibited" end
    local untrusted_function, message = loadstring(untrusted_code)
    if not untrusted_function then return nil, message end
    return RunInEnvironment(untrusted_function, env)
end
```

| 能做到 | 做不到 |
|---|---|
| 隐藏全局量（模组看不到 `_G`，只有白名单） | **阻止 `GLOBAL` 逃生舱**——`env.GLOBAL = _G` 是明文给的（`mods.lua:328`） |
| 限制模组能 `require` 什么 | 阻止无限循环（`RunInSandboxSafeCatchInfiniteLoops` 用 `debug.sethook` 做了，但和调试器冲突且默认路径没启用） |
| 捕获错误（xpcall） | 阻止 `debug.getregistry()` / `debug.setupvalue`（若未隐藏 `debug`，但 DST 也没给） |
| 阻止二进制字节码 | —— |

**结论：DST 的 `env` 是「API 规约」而不是「安全边界」。** `GLOBAL = _G` 这一行就决定了模组可以做任何事。Klei 的立场是"模组代码来自创意工坊，用户自愿安装"，安全靠审核与用户信任。

### 7.2 你的实现应该怎么选

| 方案 | 隔离强度 | 兼容性 | 成本 |
|---|---|---|---|
| `setfenv` 白名单（DST 现状） | 弱（有逃生舱） | 高（Lua 5.1 模组零改动） | 极低 |
| **白名单 + 移除 `GLOBAL` 逃生舱** | **中** | 高（改一行模组代码） | **极低** |
| 独立 Lua state（per-mod） | 强（内存/CPU 隔离） | 高（需处理跨 state 调用） | 中 |
| WASM 沙箱 | 强（可 seccomp） | 中（需重新编译模组） | 高 |

**推荐：至少做到「白名单 + 无 `GLOBAL` 逃生舱 + 独立的 per-mod 限流配额」这三条。** 成本极低，但堵住了原版最大的两个缺口。

**如果必须保留 `GLOBAL`**，至少加一层**写保护代理**：

```lua
local readonly = function(real_table, declared_keys)
    return setmetatable({}, {
        __index = function(_, k)
            if k == "STRINGS" then return wrap_readonly(real_table.STRINGS) end
            error(("模组不可通过 GLOBAL 访问未声明的字段 '%s'"):format(tostring(k)))
        end,
    })
end
```

### 7.3 指令配额

**DST 最严重的一个缺口：一个模组写 `while true do end` 就能挂起整个服务器。**

`util.lua:817` 的 `RunInSandboxSafeCatchInfiniteLoops` 存在但**默认不用**——`InitializeModMain` 走的是普通 `RunInEnvironment`。而且它需要 `debug.sethook`，与调试器冲突（注释明写）。

**你的实现必须做：**

```lua
local function RunInSandboxWithQuota(code, env, maxops)
    local fn, err = loadstring(code)
    if not fn then return nil, err end
    local co = coroutine.create(fn)
    setfenv(co, env)

    local ops = 0
    debug.sethook(function()
        ops = ops + 1000
        if ops > maxops then
            error(("mod exceeded CPU quota (%d ops)"):format(maxops), 0)
        end
    end, "", 1000)

    local ok, result = coroutine.resume(co)
    debug.sethook()
    if not ok then return nil, result end
    return result
end
```

**注意 `debug.sethook` 与调试器冲突**——需要在挂调试器时降级：挂调试器的用户反正能自己中断，让他受益于调试器。

### 7.4 资源搜索路径与覆盖顺序

```lua
-- mods.lua:563-586
for i, mod in ipairs(self.mods) do
    -- ① 脚本路径前插
    package.path = MODS_ROOT..mod.modname.."\\scripts\\?.lua;"..package.path
    -- ② 资源路径前插 + manifest
    table.insert(package.assetpath, { path = MODS_ROOT..mod.modname.."\\", manifest = manifest })
    self:InitializeModMain(mod.modname, mod, "modworldgenmain.lua")
    if not self.worldgen then
        self:InitializeModMain(mod.modname, mod, "modmain.lua")
    end
end
```

**三个关键点，其中两个是隐式的坑：**

| # | 事实 | 坑 |
|---|---|---|
| 1 | `package.path` **前插** | **后加载的模组排在前面**。所以 `require("common")` 找到的是哪个模组的文件，取决于 priority 顺序。**这是个隐式的模块冲突面**——两个模组都有 `scripts/common.lua` 就会互相踩 |
| 2 | `package.assetpath` 前插，但 `resolvefilepath` 用 `ipairs_reverse` **倒序搜索** | 所以 priority **低**的模组资源优先（先被搜到）。**这与直觉相反** |
| 3 | `modworldgenmain.lua` 总是执行，`modmain.lua` 只在非 worldgen 时执行 | 世界生成进程只需要知道模组提供了哪些自定义项（角色、地形、预设），不需要完整初始化 |

**规范：**
- **资源覆盖顺序必须显式声明**，不要沿用 DST 的隐式倒序。如果决定用"高 priority 覆盖低 priority"，就在搜索路径的排序上明确实现它。
- **脚本路径建议不前插**，改为让 `require` 走"模组名 + 文件名"的形式（`require("mymod/common")`），从根本上消除同名冲突。
- `modworldgenmain.lua` 与 `modmain.lua` 的分离值得保留——它解决了"世界生成时某些全局量未定义"的一整类问题。

---

## 8. 兼容性策略

### 8.1 API 版本的双向闸门

**这是 DST 最值得抄的一个版本策略**（`modindex.lua:620-627`）：

```lua
if info.failed then
    ...
elseif env.api_version == nil or env.api_version < MOD_API_VERSION then
    -- ★ 太旧：警告但仍加载（向后兼容）
    modinfo_message = modinfo_message.."Old API! (mod: "..tostring(env.api_version)..
                                " game: "..MOD_API_VERSION..") "
elseif env.api_version > MOD_API_VERSION then
    -- ★ 太新：硬失败
    local old = "api_version for "..modname.." is in the future, please set to the current version. ..."
    Log.Error("Error loading mod: "..ModInfoname(modname).."!\n "..old.."\n")
    env.failed = true
end
```

| 情况 | 处理 | 理由 |
|---|---|---|
| `api_version` 更旧 | **警告但加载** | 老模组尽量跑——不破坏用户已经装的东西 |
| `api_version` 缺失 | 同上（警告 + 加载） | 缺失大概率是老模组 |
| `api_version` 更高 | **硬失败** | 新模组直接拒——避免用不存在的 API 静默出错 |

**再加一条生产环境的具体做法：** 硬失败时**给出一个具体的修复动作**——"你的模组是为游戏版本 X 开发的，请在模组页面选择兼容版本 Y"，而不是"版本不兼容"。

### 8.2 向后兼容的具体做法

**三条必须遵守的规则：**

| # | 规则 | 做法 |
|---|---|---|
| 1 | **函数指针型 API 只加不改** | `redirectfn`、`deltamodifierfn`、`condition` 这类参数只接受函数，不接受"模块路径 + 函数名"字符串——否则模块被移动/重命名，所有模组静默失效 |
| 2 | **API 表只增不减** | `GLOBAL.MyModAPI` 里新增字段是安全的；删除或改语义会破坏所有引用它的模组 |
| 3 | **废弃要分两阶段** | 标记 `@deprecated` → 至少两个 API 版本后才移除 → 移除时在启动日志里明确列出"以下模组仍在使用已移除的 API：X、Y" |

**新增 API 的成本提示：** 每加一个 API 都是一条**永久的兼容承诺**。所以 §1.3 的"通用钩子 + 过滤条件"规则如此重要——加一个糖化的专用钩子比加一个真 API 便宜得多。

### 8.3 联机兼容性的特殊限制

**这是模组作者必须知道的几个硬限制：**

| 限制 | 原因 | 后果 |
|---|---|---|
| **用了写 netvar 的模组必须是全员安装** | netvar 要求两侧声明一致 | `all_clients_require_mod` |
| **用了读 netvar 的模组可以做服务器专属**（理论上） | 客户端不发就行 | DST 没区分这两种（见下） |
| **`set_local` 过的字段带宽永久抬高** | 客户端调用过 `set_local` 后，服务器的每次 `set` 都会变成脏 | 见 `bug-patterns.md` B2 |

**⚠ DST 的缺口：** netvar 的限制是"两侧声明必须一致"，所以它**无法区分**「只读 netvar」和「写 netvar」，导致 `all_clients_require_mod` 被用得极其保守。

**你的实现应该做这个区分：**

| netvar 类型 | 是否要求全员安装 | 理由 |
|---|---|---|
| **只读 netvar**（客户端从不写，只读服务端下发的值） | **不需要** | 客户端没有这个字段声明也不影响，因为客户端不读它 |
| **写 netvar**（客户端可能写） | **必须全员** | 两侧声明必须一致，否则 wire format 错位 |

这样服务器专属模组的空间会大很多（UI 美化、服务端管理工具等）。

### 8.4 跨版本存档兼容

**模组涉及存档时的三条规则：**

| # | 规则 | 做法 |
|---|---|---|
| 1 | **字段重命名 = 三件事一起做** | ① 改代码 ② 在迁移表加映射 ③ 保留旧预制体名作为兼容壳 |
| 2 | **组件被删了但数据要迁移** | `OnSave` 返回 `{ add_component_if_missing = true, ... }`，读档时框架会自动补回组件让它执行 `OnLoad` 迁移 |
| 3 | **卸载模组后读它的存档** | 实体会因为找不到预制体而消失（**这在"存档是文本格式"的前提下可接受**——玩家/其他模组可以手工删掉那些记录） |

**第 3 条只有文本格式存档才成立。** 如果你的存档是二进制（体积小 3–5 倍、加载快），就必须额外维护一份"已删除实体清单"并在读档时跳过——**这是一个真实的取舍，要提前决定并写进设计文档。**

### 8.5 版本号策略

**`api_version` 与模组自己的 `version` 是两回事，别混：**

| 字段 | 谁定义 | 语义 | 什么时候该改 |
|---|---|---|---|
| `api_version` | **游戏开发者** | 这个模组需要哪一版的游戏 API | 你用到了新 API |
| `version` | **模组作者** | 模组自己的版本（`major.minor.patch`） | 任何改动 |

**规范：`api_version` 是"我能跑的最低游戏版本"，是单向前兼容的；`version` 是"我自己的迭代号"。**

---

## 9. 模组调试方法

### 9.1 只加载一个模组

**排查"两个模组打架"的第一步永远是隔离。** 命令行参数或启动配置里指定模组列表：

```lua
-- 开发期：跳过所有模组，只加载白名单里的
function ModWrangler:LoadMods()
    local only = _G.ONLY_MODS    -- "mymod" 或 "mymod,othermod" 或 nil
    if only then
        local keep = {}
        for name in only:gmatch("[^,]+") do keep[name] = true end
        self.mods = {}
        for _, m in ipairs(AllMods) do
            if keep[m.modname] then self.mods[#self.mods+1] = m end
        end
    end
    ...
end
```

### 9.2 追踪钩子执行

**打印所有钩子的执行顺序与耗时**：

```lua
-- 包装 GetPostInitFns 的回放，加计时与来源标注
local function TracedPostInitFns(type, id, fns)
    local t0 = os.clock()
    for _, fn in ipairs(fns) do fn() end
    Log.Debug("[hook] %s%s: %d 个回调, %.3fms",
        type, id and ("["..id.."]") or "", #fns, (os.clock()-t0)*1000)
end
```

**这能回答两个问题：** 哪些钩子被调得最多（性能）、哪些钩子的回调顺序影响了行为（正确性）。

**`PrefabPostInitAny` 一定要单独统计：**

```lua
local n_any = 0
AddPrefabPostInitAny(function(inst) n_any = n_any + 1 end)
-- 每 60 刻：Log.Info("[hook] PrefabPostInitAny 已执行 %d 次（活跃实体 %d）", n_any, table.getn(AwakeEnts))
```

**如果 `n_any` 的增长速度接近实体生成速率，说明这个钩子没有做任何过滤——它对每个生成的实体都跑一遍。**

### 9.3 检测「这个 mod 是不是罪魁」

**CPU 归因到模组。** 逐个模组开关测：

```
for mod in AllMods:
    开启 only mod，跑 60 秒
    记录：平均帧时间、活跃协程数、事件广播次数
对比 baseline（无模组）
```

**更快的做法：统计模组注册的资源。**

```lua
for name, mod in pairs(self.mods) do
    local n_postinit, n_rpc, n_req = 0, 0, 0
    for t, tab in pairs(mod.postinitfns or {}) do
        if type(tab) == "table" then
            for _, arr in pairs(tab) do
                if type(arr) == "table" then
                    for _, f in ipairs(arr) do n_postinit = n_postinit + 1 end
                else n_postinit = n_postinit + 1 end
            end
        end
    end
    print(("%-30s hooks=%-5d rpcs=%-3d priority=%s"):format(
        name, n_postinit, count_rpc(mod), tostring(mod.modinfo.priority)))
end
```

**钩子数量异常多的模组就是重点排查对象。**

### 9.4 沙箱内的调试设施

**给模组作者的调试 API（应该在白名单里）：**

| API | 用途 |
|---|---|
| `print` / `Log.Warn` | 基础日志，**分级** |
| `debugstack(level, index, key)` | 打印调用栈——排查钩子问题时最有用 |
| `TheSim:GetTick()` | 游戏刻号——排查时序问题 |
| `TheWorld.ismastersim` | 判断自己跑在哪一侧 |
| `GLOBAL`（或受限替代品） | 访问 API 表 |

**注意 `debugstack` 应该是 debug 构建才提供的**——它在生产环境有性能成本，且会泄露内部结构。

### 9.5 常见模组问题的快速定位

| 症状 | 首查 |
|---|---|
| 模组加载时报 "Old API" | `api_version` 声明太低；确认是否真的用到了新 API |
| 加载时报 "api_version is in the future" | 模组是为更新的游戏版本写的；换兼容版本 |
| 必填字段缺失 | `modinfo.lua` 里少了 `name`/`author`/`version`/`api_version` 之一 |
| 两个模组互相影响 | 打印两者的 `priority` 与加载顺序（§5.3）；检查 RPC 命名空间冲突 |
| 物品做不出来 | 忘了第 3 步——重载 `ALL_CRAFTABLES` / 配方表 |
| 物品在物品栏里没有图标 | 忘了 `Asset("ATLAS", ...)`，或 atlas 文件里没有那个条目 |
| 联机时别人的屏幕上没有这个物品 | `SetPristine()` 之后才 `AddNetwork()`；或组件没加可复制白名单 |
| 单独装正常，两个一起装就崩 | 依赖没声明（§4.3 的拓扑排序缺口） |
| 自己的 `require` 加载到了别人的文件 | `package.path` 前插的隐式冲突（§7.4） |
| 服务器 CPU 100% 无响应 | 死循环——加指令配额（§7.3） |
| 某个动作点了没反应，人物走过去站着不动 | `condition` 返回假（§6.5） |
| 受击后动作还继续跑完并产出 | 忘了 `ClearBufferedAction()`（§6.5） |

---

## 10. 常见模组错误与后果对照表

**按后果严重度排序。前 6 条属于"会破坏别人的东西"，后 10 条属于"自己的功能不对"。**

| # | 错误 | 后果 | 严重度 | 修法 |
|---|---|---|---|---|
| 1 | **写 `GLOBAL._G` 或直接改核心全局表** | 本体游戏状态被破坏，堆栈完全看不出是谁干的 | **致命** | 只读核心数据；要扩展就注册钩子 |
| 2 | **死循环 / 每帧全局扫描** | 服务器 CPU 100% 无响应，重启才恢复 | **致命** | 加指令配额；每帧逻辑改成事件驱动 |
| 3 | **劫持别人的 RPC 命名空间** | 那个模组的功能莫名触发/失效 | **致命** | 加所有权校验：`if exists then error() end` |
| 4 | **改 `STATEGRAPH` 结构或加大量状态** | 状态图构建期变慢；甚至因为超过某个上限而崩溃 | 高 | 优先用生成器（`commonstates`）而不是手写 |
| 5 | **注册新组件但没加可复制白名单** | 服务端正常，客户端永远显示默认值 | 高 | `AddReplicableComponent(name)` |
| 6 | **在 `PrefabPostInitAny` 里不过滤就做重活** | 3000 个实体 × 每个重活 = 全局卡顿 | 高 | 第一个判断就是过滤（`inst:HasTag(...)`） |
| 7 | **`AddNetwork()` 放在 `SetPristine()` 之后** | 客户端拿不到网络实体 | 中 | 顺序是硬约束 |
| 8 | **`AddComponent("locomotor")` 在 `SetStateGraph()` 之后** | 状态图构造时查询不到，行为异常 | 中 | locomotor 必须最先 |
| 9 | **组件名含大写字母** | 存档字段名不兼容，老存档丢数据 | 中 | 一律小写 |
| 10 | **裸赋值组件字段绕过 setter** | 跳过网络同步、死亡检测、事件广播 | 中 | 走 `DoDelta` / `SetXxx` |
| 11 | **`priority` 写成字符串且排序不稳定** | 不同机器上加载顺序不同，行为不一致 | 中 | 提供稳定的二级排序键（名字） |
| 12 | **`require` 一个别处也叫同名的文件** | 加载到别的模组的模块 | 中 | 用 `require("模组名/文件名")` 的命名空间形式 |
| 13 | **拦截器返回 nil 而不是 0** | "条件为假就什么都不做"，动作静默失效 | 中 | 叠加型拦截器返回 0 |
| 14 | **在可打断状态里忘了 `ClearBufferedAction()`** | 受击后动作继续跑完并产出资源 | 中 | `onexit` 里调 |
| 15 | **新状态没挂 `busy` 标签** | 玩家的操作会打断它 | 中 | 状态标签是唯一契约 |
| 16 | **在钩子里假设"只被调用一次"** | 多次调用导致状态累积（如 `RoomPreInit`） | 中 | 钩子做成幂等的 |
| 17 | **改 `maxhealth` 但没同步 `currenthealth`** | 血条显示 `50/200` 但实际 `50/100` | 低 | 改 max 后同步改 current |
| 18 | **资源文件路径写死绝对路径** | 换个安装位置就找不到 | 低 | 用 assetpath 相对路径 |
| 19 | **在 manifest 里做副作用操作** | 沙箱里连 `print` 都没有，直接报错 | 低 | manifest 是纯声明式的 |
| 20 | **定义了 `manifest` 但没加 `configuration_options`** | 功能不可配置 | 低 | 补 `configuration_options` |

**第 1、2、3 条的共同点：它们不是"你的模组坏了"，而是"别人的东西坏了"。** 这三条值得在沙箱层面就拦住（见 §7.2、§7.3、§5.5），而不只是靠文档提醒。

---

## 11. 发版检查清单

**平台侧（你在做模组系统）**

- [ ] 清单在极简沙箱里执行（连 `print` 都不给）
- [ ] 必填字段校验分「硬失败」与「仅警告」两级
- [ ] 所有缺省兜底字段配了 `*_specified` 影子标记
- [ ] 互斥标志组合会检测并警告
- [ ] API 版本双向闸门：太旧警告仍加载，太新硬失败（附可操作的修复提示）
- [ ] 依赖是**拓扑排序**而非仅 priority；环检测**记录路径**
- [ ] 优先级相同时有**稳定的二级排序键**（跨机器一致）
- [ ] 反向依赖用引用计数，不是布尔标记
- [ ] 依赖缺失自动订阅/下载；导致本模组不可用时连带禁用
- [ ] 沙箱**无 `GLOBAL` 逃生舱**（或至少有写保护代理）
- [ ] **每模组 CPU 指令配额**（防死循环）
- [ ] 模组 RPC 命名空间**所有权校验** + **强制加模组名前缀**
- [ ] RPC 限流：每模组独立配额 + **全局硬上限**；limiter 表每刻清空
- [ ] 资源覆盖顺序**显式声明**（不沿用隐式倒序）
- [ ] 每个钩子独立错误隔离 + 错误对话框 + **依赖者连带禁用**
- [ ] 区分「只读 netvar」与「写 netvar」，前者可做服务器专属
- [ ] 加载耗时 / 失败原因 → 遥测
- [ ] 新增可复制组件用**显式注册制**而非全局白名单

**模组作者侧**

- [ ] `api_version` 声明准确（用到了新 API 就提版本）
- [ ] `mod_dependencies` 声明了所有需要的模组（靠 priority 排序碰巧能跑是不行的）
- [ ] 改动是**读-改-写**而不是硬编码绝对值
- [ ] 所有异步任务通过实体发起（不用全局调度器裸挂）
- [ ] 所有事件订阅走封装 API（双向记账）
- [ ] 清理回调用正确的名字（`OnRemoveEntity`，不是 `OnRemoveFromEntity`）
- [ ] 需要跨状态的数据用 `sg.mem` 不是 `sg.statemem`
- [ ] 遍历要发事件的集合用 `ipairs` 或显式排序 + 确定性 tiebreaker
- [ ] 钩子对极端输入不报错（nil 的 inst、缺组件的实体）
- [ ] 改动的字段有版本迁移计划（重命名 = 三件事一起做）
- [ ] 在单机 / 联机 / 有模组 / 无模组四种环境下都测过

---

## 附：三页纸速查

**我要加一个新内容**
```
1. 写预制体工厂函数（遵守四个顺序约束：AddNetwork → netvar → SetPristine → ismastersim 闸门）
2. 在 modmain.lua 里注册到全局查找表
3. ★ 重载配方表 / 配方 / 状态图表（最容易漏的一步）
4. 资源放模组根目录
5. 验证：单机 + 联机（客户端能看到吗？动作能用吗？）
```

**我改了别人的东西**
```
1. 用钩子，不用改原版代码
2. 用读-改-写，不用硬编码
3. 改 max 后同步改 current
4. 走 setter，不用裸赋值
5. 声明依赖（不靠 priority 碰运气）
```

**我的模组坏了**
```
1. 只加载一个模组复现（§9.1）
2. 看 `error calling <hook> in mod <name>` 日志定位是哪个钩子
3. 打印钩子执行顺序与耗时（§9.2）
4. 如果单独正常、一起崩 → 依赖或 RPC 冲突（§8.3）
5. 如果联机才坏 → 检查 AddNetwork 顺序和可复制白名单
```