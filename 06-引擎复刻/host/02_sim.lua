--[[
==============================================================================
 02_sim.lua —— 仿真层：TheSim / 时间 / 调度器

 关键决策：**直接加载 DST 真实的 scheduler.lua**，
 而不是自己写一个。理由：
   · scheduler.lua 只依赖 TheSim:ProfilerPush/ProfilerPop（已实测）
   · 它是 616 行已深度注释的文件（82 处机制标注），
     包含「绝对 tick 桶」「id 继承」「周期漂移防护」等真实设计
   · 复用真实实现 = 天然对齐行为，也顺带验证「原版文件可直接加载」
==============================================================================
]]

local Core = require("host.01_core")

local Sim = {}
Sim.__index = Sim

--=========================================================================
-- TheSim：真实引擎里这是 C++ 单例，管 tick 与时间
--=========================================================================
local TheSim = {}
Sim.TheSim = TheSim

TheSim.tick = 0
TheSim.time = 0
TheSim.TICK_TIME = 1 / 30      -- DST 默认 30 tick/秒
TheSim.paused = false

function TheSim:GetTick() return self.tick end
function TheSim:GetTickTime() return self.TICK_TIME end
function TheSim:GetTime() return self.time end
function TheSim:SetTickTime(t) self.TICK_TIME = t end
function TheSim:ProfilerPush() end   -- 真实引擎插桩；宿主空转
function TheSim:ProfilerPop() end
function TheSim:IsPaused() return self.paused end
function TheSim:SetPaused(p) self.paused = p end
function TheSim:Step() self.tick = self.tick + 1 end
function TheSim:GetRealTime() return os.clock() end
function TheSim:GetFPS() return 30 end

--=========================================================================
-- ★ 环境光颜色系列（C++ 渲染层 uniform）
--=========================================================================
--   实测症状：components/ambientlighting.lua:117/120 `TheSim:SetAmbientColour(...)`
--       ✘ attempt to call method 'SetAmbientColour' (a nil value)
--     ⇒ **ambientlighting 组件构造直接失败** ⇒ TheWorld 没有环境光照组件
--     ⇒ prefabs/moon_fissure.lua:49 崩，且所有 light watcher 都读不到环境亮度。
--
--   为什么是 no-op 而不是别的：这几个方法往渲染器的 uniform 里写颜色，
--   宿主是 headless 形态，**没有 uniform**。真正的环境光由浏览器播放器
--   那条链路（主机侧计算相位/季节颜色）负责，与这几个 C++ 调用无关。
--   Get 系列返回 0,0,0 —— 「未设置过环境光」的诚实取值。
--
--   ⚠️ 刻意**不**给 TheSim 挂万能代理：TheSim 上「缺方法就崩」这个特性
--     在过去多次帮我们抓出真缺口（FindEntities / AtlasContains …）。
--     代理会让这些缺口静默通过。所以这里逐个显式实现。
function TheSim:SetAmbientColour(r, g, b) end
function TheSim:SetVisualAmbientColour(r, g, b) end
function TheSim:GetAmbientColour() return 0, 0, 0 end
function TheSim:GetVisualAmbientColour() return 0, 0, 0 end

-- ★ FindEntities：温度组件（temperature.lua:350）等用它查范围内的实体。
--   真实引擎按标签过滤且用空间索引；宿主没有空间索引，就**线性扫全部存活实体**
--   —— 实体规模是几十个，线性扫描完全够用，而且返回的是**真实结果**。
--   ⚠️ 早前这里一律返回空表，于是「附近有没有玩家/热源/敌人」全线走「没有」分支，
--      行为树里的 FindClosestPlayer / IsNearPlayer 类判断全是假的。
--   标签语义与引擎一致：
--     musttags      全部必须命中
--     canttags      一个都不能命中
--     mustoneoftags 至少命中一个
--     第 8 参 fn    额外谓词 fn(inst) -> bool
function TheSim:FindEntities(x, y, z, radius, musttags, canttags, mustoneoftags, fn)
    local out = {}
    x, y, z = x or 0, y or 0, z or 0
    local r2 = (radius or 0) * (radius or 0)
    for _, inst in pairs(Core.Spawned) do
        if inst:IsValid() then
            local hit = true
            local tr = rawget(inst, "Transform")
            if tr ~= nil and type(tr.GetWorldPosition) == "function" then
                local ix, iy, iz = tr:GetWorldPosition()
                local dx, dz = (ix or 0) - x, (iz or 0) - z
                if dx * dx + dz * dz > r2 then hit = false end
            elseif radius and radius > 0 then
                hit = false   -- 没有位置的实体（世界等）不参与范围查询
            end
            if hit and musttags ~= nil then
                for _, t in ipairs(musttags) do
                    if not inst:HasTag(t) then hit = false break end
                end
            end
            if hit and canttags ~= nil then
                for _, t in ipairs(canttags) do
                    if inst:HasTag(t) then hit = false break end
                end
            end
            if hit and mustoneoftags ~= nil then
                local any = false
                for _, t in ipairs(mustoneoftags) do
                    if inst:HasTag(t) then any = true break end
                end
                if not any then hit = false end
            end
            if hit and fn ~= nil then
                local ok, r = pcall(fn, inst)
                if not ok or not r then hit = false end
            end
            if hit then out[#out + 1] = inst end
        end
    end
    return out
end

-- ★★ FindFirstEntityWithTag(tag) —— 按标签找**第一个**实体，找不到返回 nil。
--
--   实测症状（可达性抽样，`prefabs/fruitfly.lua:111`）：
--       if not TheSim:FindFirstEntityWithTag("friendlyfruitfly") then
--       ✘ attempt to call method 'FindFirstEntityWithTag' (a nil value)
--     ⇒ lordfruitfly 生成不出来。
--
--   影响面比 1 个大（全库调用点）：
--       components/beargerspawner.lua:128   "bearger_blocker"
--       components/crabkingspawner.lua:21   "crabking_spawner"
--       components/deerclopsspawner.lua:168 "deerclops"
--       components/farming_manager.lua:220/600  "lordfruitfly"
--       …这些生成器都用它做「已经有一个了就不再生成」的**去重判断**。
--       缺了它这些生成器在**第一次**就崩（而不是语义变松）。
--
--   语义对齐：真实引擎在 C++ 实体表里找；宿主线性扫 `Core.Spawned`
--   （与 TheSim:FindEntities 同一取舍，见上面的说明）。
--   ★ 只返回**一个**，不保证顺序与引擎一致 —— 但调用点全部是「存在性判断」，
--     不依赖顺序（已逐个确认）。
function TheSim:FindFirstEntityWithTag(tag)
    for _, inst in pairs(Core.Spawned) do
        if type(inst) == "table" and type(inst.HasTag) == "function"
            and inst:HasTag(tag) then
            return inst
        end
    end
    return nil
end

--- 用「注册过的标签集合」查实体（components/map.lua:55 的可走平台查询走这条）。
--   tagset 就是 RegisterFindTags 的返回值。
function TheSim:FindEntities_Registered(x, y, z, radius, tagset)
    local must, cant = nil, nil    if type(tagset) == "table" then
        must, cant = tagset.must, tagset.cant
    end
    return TheSim:FindEntities(x, y, z, radius, must, cant)
end

function TheSim:GetEntitiesAtPoint(x, y, z, radius)
    return TheSim:FindEntities(x, y, z, radius)
end

-- ★ CountEntities：与 FindEntities 同参，但**只返回数量**。
--   components/sheltered.lua:77 用它数「头顶有没有遮挡物」：
--       TheSim:CountEntities(x, y, z, 2, musttags, canttags) > 0
--   缺了它 sheltered 每 tick 抛一次异常（实测 2550 次），庇护所判定全线失效。
function TheSim:CountEntities(x, y, z, radius, musttags, canttags, mustoneoftags, fn)
    return #TheSim:FindEntities(x, y, z, radius, musttags, canttags, mustoneoftags, fn)
end
function TheSim:GetClosestEntityToPoint(x, y, z, radius, tags)
    local best, bestd
    for _, inst in ipairs(TheSim:FindEntities(x, y, z, radius, tags)) do
        local ix, iy, iz = inst.Transform:GetWorldPosition()
        local dx, dz = (ix or 0) - x, (iz or 0) - z
        local d = dx * dx + dz * dz
        if bestd == nil or d < bestd then best, bestd = inst, d end
    end
    return best
end

-- ★ HasPlayerSkeletons：player_common.lua:2895 直接把返回值赋给状态图
--   的 mem.nocorpse，缺失会 nil-index。
function TheSim:HasPlayerSkeletons() return false end

-- ★ RegisterFindTags：gelblob.lua:106 在**顶层**调用它：
--     TheSim:RegisterFindTags(tags, excludetags)
--   真实引擎返回一个「已注册的标签集合」句柄，供 FindEntities_Registered 复用。
--   宿主返回 { must = tags, cant = excludetags }，两个函数就能对上号。
--   缺了会让整个 prefab 加载失败。
function TheSim:RegisterFindTags(tags, excludetags)
    return { must = tags, cant = excludetags, fn = nil }
end
function TheSim:HasPlayerGhosts() return false end

-- scheduler.lua 需要的全局函数
GetTickTime = function() return TheSim.TICK_TIME end
GetTime = function() return TheSim.time end
GetSchedulerTick = function() return TheSim.tick end
GetSchedulerTime = function() return TheSim.time end

--=========================================================================
-- 世界（TheWorld 的宿主侧投影）
--=========================================================================
-- ★ TheWorld 必须是**真实体**（EntityScript），不能是光表。
--   组件（worldsettings.lua:13、worldstate.lua:212）的构造函数第一件事就是
--   `world:ListenForEvent(...)` —— 光表没有这个方法，实例化直接崩，
--   于是 worldstate / worldsettings 一直被记成缺口。
--   真引擎里 TheWorld 就是一个 EntityScript（prefabs/world.lua 建的）。
local World = Core.NewEntity("world")
Sim.World = World

World.time = 0
World.tick = 0
World.ismastersim = true       -- 宿主只有一个进程，既是服务端也是权威
World.ismastershard = true

-- ★★ 袖珍维度容器表（对应 prefabs/world.lua:385-393）
--
--   原版两个函数：
--       local function CreatePocketDimensionContainer(world, name)
--           world.PocketDimensionContainers[name] = containerinst end
--       local function GetPocketDimensionContainer(world, name)
--           return world.PocketDimensionContainers[name] end
--
--   为什么这个必须有：至少有 4 个预制体**无条件**调它
--       hats.lua:7509 / chester.lua:383 / magician_chest.lua:120
--       / rabbitkinghorn_chest.lua:74
--       inst.components.container_proxy:SetMaster(
--           TheWorld:GetPocketDimensionContainer("shadow"))
--   而 `hats.lua:7509` 那条在 `hats.lua` 里 —— 本宿主**加载过 hats.lua**
--   （83 个帽子），所以一走到那条分支就
--       attempt to call method 'GetPocketDimensionContainer' (a nil value)
--   ⇒ 那顶帽子**生成不出来**。实测症状：`SpawnPrefab("tophat_container")` 返回 nil。
World.PocketDimensionContainers = {}
function World:CreatePocketDimensionContainer(name, containerinst)
    self.PocketDimensionContainers[name] = containerinst
    return containerinst
end
function World:GetPocketDimensionContainer(name)
    return self.PocketDimensionContainers[name]
end

-- ★★ SetPocketDimensionContainer —— precludes「枚举法又漏一个」。
--
--   原版 `prefabs/world.lua:385-393` 三个函数是一组：
--       CreatePocketDimensionContainer / GetPocketDimensionContainer /
--       **SetPocketDimensionContainer**
--   宿主之前只补了前两个（起因是 `hats.lua:7509` 报 Get 为 nil），
--   **Set 一直没补** —— 因为它没有出现在当时那个报错链上。
--
--   实测症状（可达性抽样，出现在两个预制体上）：
--       prefabs/pocketdimensioncontainers.lua:67
--           TheWorld:SetPocketDimensionContainer(def.name, inst)
--       ✘ attempt to call method 'SetPocketDimensionContainer' (a nil value)
--     ⇒ shadow_container / rabbitkinghorn_container 生成不出来。
--
--   ★ 语义：原版就是 `world.PocketDimensionContainers[name] = containerinst`
--     （与 Create 的差别只是**不返回**）。注意 `pocketdimensioncontainers.lua`
--     是先调 Set 再 return inst，而 `Create` 是构造器路径 —— 两个入口写同一张表，
--     所以这里必须写同一张 `World.PocketDimensionContainers`，不能另建一份。
function World:SetPocketDimensionContainer(name, containerinst)
    self.PocketDimensionContainers[name] = containerinst
end
-- ★★★ World.state —— 必须**实时镜像** worldstate 组件，不能是静态表
--
-- 真实引擎里 `TheWorld.state` 由 **C++ 侧**把 worldstate 的 netvar 镜像出来，
-- 所以 Lua 代码一律「只读」它：全库到处是
--     `TheWorld.state.isday`（sleeper.lua:117/124、cozy_bunnyman.lua:209/218、
--      cozy_bunnymanbrain.lua:127 …）
--     `TheWorld.state.season`（mood.lua:111 甚至用它拼键名 `season.."length"`）
--     `_world.state.iswinter`（sharkboimanager.lua:141）、`isacidraining` 等
-- 而 Lua 侧**没有任何地方写它** —— 因为写的是 worldstate 组件的 `self.data`
-- （worldstate.lua:25 `SetVariable` → `self.data[var] = val`）。
--
-- 宿主此前把它做成了一张静态表，于是 `state.phase` 永远停在初始的 `"day"`：
-- 即使 clock 组件内部真的在推进（实测 GetTimeUntilPhase 从 300 递减到 280）、
-- 即使 `phasechanged` 事件真的按 300/420/480 s 的节奏发出，
-- 读 `TheWorld.state` 的那一大片代码看到的仍是死值。
--
-- 修法：用 __index 做实时镜像（等价于 C++ 的那层镜像），
-- 硬编码值降级为「worldstate 还没算出这个键时的兜底」。
local STATE_DEFAULTS = {
    isday = false,
    iscaveday = false,
    iscave = false,
    iswinter = false,
    issummer = false,
    season = "autumn",
    cycles = 0,
    phase = "day",
    temperature = 20,
    moonlight = 0.2,
    isnewmoon = false,
    isfullmoon = false,
    precipitation = "none",
    snowlevel = 0,
    pop = 0,
    wetness = 0,
    moistureceil = 100,
}
World.state = setmetatable({}, {
    __index = function(_, k)
        local ws = World.components and World.components.worldstate
        if ws ~= nil and type(ws.data) == "table" then
            local v = ws.data[k]
            if v ~= nil then return v end
        end
        return STATE_DEFAULTS[k]
    end,
    -- 允许外部显式覆写（调试用）；写入后 rawget 命中，不再走镜像
    __newindex = function(t, k, v) rawset(t, k, v) end,
})

function World:GetTime() return self.time end
function World:GetTick() return self.tick end
function World:IsCave() return self.state.iscave end
function World:HasTag() return false end

-- ★★★ World:PushEvent —— 曾经只做「世界状态广播」，**漏掉了事件派发**（真 bug）
--
-- 原实现：
--     function World:PushEvent(evt, data)
--         if self._watchers and self._watchers[evt] then ... end   -- 只有这一段
--     end
-- 这是**直接定义在 World 表上的字段**，会遮蔽 Core.EntityMeta:PushEvent，
-- 于是 `TheWorld:ListenForEvent(evt, fn)` 注册的回调**永远不会被调用**。
--
-- 后果（全部静默，不报错）：
--   · `worldstate.lua:212-214` 监听 `clocktick` / `phasechanged` / `cycleschanged`
--     —— 收不到 ⇒ `TheWorld.state.phase` 永远是初始值 `day`，
--        即使 clock 组件内部真的在推进（实测 `GetTimeUntilPhase` 从 300 递减到 280）
--   · `weather.lua:785` / `ambientlighting.lua:272` / `colourcube.lua:453` /
--     `caveweather.lua:522` / `oceancolor.lua:12` 全部监听 `TheWorld`
--   （`entityscript.lua:1317` 的 PushEvent_Internal 就是「派发监听器 + 转发状态图」，
--     真实引擎里 TheWorld 与普通实体走的是**同一条** PushEvent 路径。）
--
-- 修法：通用派发照做（委托 EntityMeta），世界状态广播作为**附加**保留
-- （宿主 `EntityMeta:WatchWorldState` 会走 `Core.World.Watch` 登记到这里）。
function World:PushEvent(evt, data)
    -- ① 监听器 + 状态图（与普通实体完全一致）
    Core.EntityMeta.PushEvent(self, evt, data)
    -- ② 世界状态广播（宿主侧为 WatchWorldState 提供的通道）
    if self._watchers and self._watchers[evt] then
        for inst, fn in pairs(self._watchers[evt]) do
            if inst:IsValid() then fn(inst, data) end
        end
    end
end
World._watchers = {}

-- ★ 世界拓扑：真实引擎由 C++ 生成（把地图切成地块节点并记录连通关系）。
--   宿主没有拓扑生成器，给一张**空拓扑**而不是 nil ——
--   因为原版大量写法是 `TheWorld.topology.nodes[i]`，
--   如果 topology 本身是 nil 就会「索引 nil」而不是「拿到 nil 节点」。
--   空表让这些代码自然走「没有节点」分支（areaaware / desolationspawner /
--   components/map.lua 的 FindNodeAtPoint 系都一样）。
World.topology = { nodes = {}, ids = {}, node_types = {} }

--- 宿主侧支持 WatchWorldState：实体在世界事件表里登记
function World.Watch(inst, state, fn)
    World._watchers[state] = World._watchers[state] or {}
    World._watchers[state][inst] = fn
end
function World.StopWatch(inst, state)
    if World._watchers[state] then World._watchers[state][inst] = nil end
end

-- ★★★ World:WatchWorldState / StopWatchingWorldState / StopAllWatchingWorldStates
--
--   P41 农业链路实测出来的缺口：`farming_manager.lua:626` 在**构造末尾**调
--       self:WatchWorldState("season", OnSeasonChange)
--   （`self` 是组件，经 `01_core.lua:1021` 的 ComponentWatchWorldState 包装后
--     落到 `inst:WatchWorldState`，而 inst 是 **World**。）
--   宿主的 `Core.EntityMeta` 上有这两个方法，但 **World 不是 EntityScript** ——
--   它是一张普通表 + 若干显式方法（见上面 PushEvent / HasTag / IsCave）。
--   于是 `World.WatchWorldState` 是 nil：
--       farming_manager.lua:626 attempt to call method 'WatchWorldState' (a nil value)
--
--   ★ 后果是**整条农业链路死掉，而且症状极隐蔽**：
--     构造在 626 行抛错 ⇒ `WORLD_COMPONENTS` 那边记一条「构造失败」⇒
--     `World.components.farming_manager` **永远是 nil**。
--     但 `ListenForEvent("onterraform", ...)` 在 623 行就注册好了，
--     监听器照样会被调用 ⇒ 崩溃点跑到 `OnTerraform` 里去：
--         farming_manager.lua:155 attempt to index upvalue '_nutrientgrid' (a nil value)
--         farming_manager.lua:181 attempt to index field 'undertile' (a nil value)
--     这两个报错**都不是真正的病因** —— 病在 626 行。教训：
--     「组件构造失败的报错点」与「真实缺失的接口」可能隔了几百行。
--
--   语义对齐原版 `entityscript.lua:3115-3130`（两步）：
--     ① 记进 `self.worldstatewatching[var]`（供 StopAllWatchingWorldStates 批量清）
--     ② 通知 worldstate 组件建分发索引
--   宿主第 ② 步走的是自己的 `_watchers` 通道（就是上面 `World.Watch`）——
--   它与原版 `worldstate:AddWatcher` **是同一个语义位置**，因为宿主的状态广播
--   就是 `World:PushEvent` 里的那一段（见本文件 ②）。不要两边都登记，否则
--   同一个回调会被调用两次。
function World:WatchWorldState(state, fn)
    self.worldstatewatching = self.worldstatewatching or {}
    local list = self.worldstatewatching[state]
    if list == nil then
        list = {}
        self.worldstatewatching[state] = list
    end
    list[#list + 1] = fn
    World.Watch(self, state, fn)
end

function World:StopWatchingWorldState(state, fn)
    local list = self.worldstatewatching and self.worldstatewatching[state]
    if list ~= nil and fn ~= nil then
        for i = #list, 1, -1 do
            if list[i] == fn then table.remove(list, i) end
        end
    end
    -- 宿主 `_watchers` 是「每 inst 每状态一个 fn」（见 World.Watch），
    -- 所以这里只能整体注销 —— 与原版 `RemoveWatcher(var, inst)` 的批量语义一致。
    World.StopWatch(self, state)
end

function World:StopAllWatchingWorldStates()
    if self.worldstatewatching == nil then return end
    for state in pairs(self.worldstatewatching) do
        World.StopWatch(self, state)
    end
    self.worldstatewatching = nil
end

-- ★★ World:IsValid —— `World:PushEvent` 的第 ② 段（状态广播）里有
--   `if inst:IsValid() then fn(inst, data) end`。而当 `WatchWorldState` 把
--   **World 自己**登记成 watcher 之后，那一行就会对 World 调 IsValid。
--   宿主 World 没有这个方法 ⇒ 一推带 watcher 的状态事件就崩。
World.IsValid = function(self) return self._invalid ~= true end

Core.World = World

--=========================================================================
-- 加载真实 DST scheduler.lua
--=========================================================================
-- ★ SRC 一律取 Core.SourceDir（由 host/00_paths.lua 解析），不再各写一份字面量
local SRC = Core.SourceDir

local function load_real_scheduler()
    -- scheduler.lua 是标准 Lua 模块：require("class") 后定义 Scheduler
    local chunk, err = loadfile(SRC .. "/scheduler.lua")
    if not chunk then
        error("无法加载真实 scheduler.lua: " .. tostring(err))
    end
    local ok, mod = pcall(chunk, "scheduler.lua")
    if not ok then
        error("执行 scheduler.lua 失败: " .. tostring(mod))
    end
    -- 真实 scheduler 返回 Scheduler 类；也可能设置全局
    return mod
end

Sim.SchedulerClass = load_real_scheduler()

-- ★ 更新泵（组件 OnUpdate + BrainManager），由 05_bootstrap 注入。
--   见 host/13_update.lua 与 Sim.Step 里的调用点。
Sim.Pump = nil

--=========================================================================
-- 世界主循环
--=========================================================================
function Sim.Step(dt)
    dt = dt or TheSim.TICK_TIME
    TheSim.tick = TheSim.tick + 1
    TheSim.time = TheSim.time + dt
    World.tick = TheSim.tick
    World.time = TheSim.time

    -- ★ 必须先取快照再遍历：回调里可能 Remove() 实体
    --   （Core.Spawned[k] = nil），边遍历边删会报 "invalid key to 'next'"
    local snapshot = {}
    for guid, inst in pairs(Core.Spawned) do
        snapshot[#snapshot + 1] = inst
    end

    -- ★ proxy 跟随（Transform:SetFromProxy，见 00_stubs.lua 的说明）
    --   纯特效实体（cane_ancient_fx / brokentool / bishop_charge …）不自己算位置，
    --   而是每帧抓被跟随者的坐标。原版由 C++ 的 Transform proxy 做，
    --   宿主在这一趟里等价实现：**先同步位置，再跑其他逻辑**，
    --   这样同一 tick 内特效就和被跟随者对齐。
    for _, inst in ipairs(snapshot) do
        local tr = rawget(inst, "Transform")
        local pg = tr ~= nil and rawget(tr, "_proxyguid")
        if pg ~= nil then
            local tgt = Core.Spawned[pg]
            if tgt ~= nil and tgt.Transform ~= nil then
                local px, py, pz = tgt.Transform:GetWorldPosition()
                tr._x, tr._y, tr._z = px, py, pz
                -- 朝向也跟着（特效通常要跟被跟随者同向）
                local r = tgt.Transform:GetRotation()
                if r ~= nil then tr._rot = r end
            end
        end
    end

    -- ★★★ C6（2026-10-18 P44）：父实体坐标跟随
    --
    --   真实引擎里 `entity:SetParent(p)` 之后，子实体的世界坐标由 C++ 每帧
    --   重算成「父坐标 + 本地偏移」。宿主原先只维护指针（01_core 的 SetParent
    --   只写 `_parent` / `_parententity`），**一个坐标都不跟**。
    --
    --   后果不是「差一点」：所有 `*_classified` 镜像实体（约 140 个）全停在
    --   出生点 (0,0)，于是 `act_targets` 每次查询都要扫这批原点死重量，
    --   「扫描量占比」这类判据也因此失真（见 C6 的原始描述）。
    --
    --   判据边界（很重要，否则会覆盖掉真正该保留的位置）：
    --     · 有 `Transform:SetFromProxy` 的实体走 proxy 段，这里跳过；
    --     · **显式摆过位置**的实体（`_explicit_pos`）不动 —— 那些是
    --       「摆在世界里某处」的东西，父坐标不该覆盖它；
    --     · 其余（从没摆过）才跟随父坐标。
    --   ⚠️ 不做「父坐标 + 本地偏移」的完整变换：宿主没有 local offset 概念，
    --      而 classified 这类镜像实体的语义就是「和父完全同位」。
    --      真要做偏移，得先有 Transform 的父子变换矩阵，那是另一件事。
    local function parent_of(inst)
        local pe = rawget(inst, "_parententity")
        if pe == nil then return nil end
        return rawget(pe, "_inst")
    end
    for _, inst in ipairs(snapshot) do
        local tr = rawget(inst, "Transform")
        if tr ~= nil and rawget(tr, "_proxyguid") == nil
           and rawget(tr, "_explicit_pos") ~= true then
            local pinst = parent_of(inst)
            local ptr = pinst ~= nil and rawget(pinst, "Transform") or nil
            if ptr ~= nil and type(ptr.GetWorldPosition) == "function" then
                local px, py, pz = ptr:GetWorldPosition()
                if px ~= nil then
                    tr._x, tr._y, tr._z = px, py or 0, pz or 0
                end
            end
        end
    end

    for _, inst in ipairs(snapshot) do
        if inst:IsValid() then
            -- ★ 首次见到实体时启动它的状态图。
            --   StateGraphInstance:Start（stategraph.lua:694）会先
            --   `SGManager:AddInstance(self, hibernate)` 把它纳入调度，
            --   之后 SGManager.Update 才会驱动它。
            local sg = rawget(inst, "sg")
            if not inst._sgstarted and type(sg) == "table"
                and type(sg.Start) == "function"
                and type(sg.Update) == "function" then
                inst._sgstarted = true
                -- ★ 必须把「当前是否休眠」传进去。
                --   原版 entityscript.lua:404-408：
                --       if self.brainfn or self.sg then
                --           local asleep = self:IsAsleep()
                --           ...
                --           if self.sg then self.sg:Start(asleep) end
                --       end
                --   宿主此前调 `sg.Start` **不传参** ⇒ hibernate 恒为 nil
                --   ⇒ 状态图永远进 `updaters`（热桶），从不进 `hibernaters`。
                --   而 StateGraphWrangler:Update 只遍历 updaters ——
                --   所以休眠实体**省了组件更新，却没省状态图更新**。
                local oks, es = pcall(sg.Start, sg, inst:IsAsleep())
                if not oks then Core.NoteStub("sg.Start", "stategraph-start") end
            end

            -- ★ 推进 AnimState 的真实动画帧。
            --   宿主没有渲染循环，所以由仿真循环代劳 —— 这样
            --   「状态机切了动画 → 动画自己翻页」这条链路才完整。
            local as = inst.AnimState
            if type(as) == "table" and type(as._tick) == "function" then
                pcall(as._tick, as, dt)
            end

            -- ★★ 物理位移积分（host/11_physics.lua）
            --   真实引擎里这是 C++ 每帧做的事：把 Physics 的 motor velocity
            --   变成位置变化。缺了它 locomotor 的一切距离判断都停在原地。
            local ph = rawget(inst, "Physics")
            if type(ph) == "table" and type(ph._integrate) == "function" then
                -- ★★ pcall 的返回值**必须看**：原来直接 `pcall(...)` 把错误丢了，
                --   于是「设了速度却不动」这类问题表现为毫无日志（今天为此查了很久）。
                --   ⇒ 计数 + 记首条错误消息，让坏积分**可见**。
                local ok, err = pcall(ph._integrate, ph, dt)
                if not ok then
                    Sim.PhysicsErrors = (Sim.PhysicsErrors or 0) + 1
                    if Sim.PhysicsErrorFirst == nil then
                        Sim.PhysicsErrorFirst = tostring(err)
                    end
                end
            end

            -- 同理，任务表也要快照（任务可能取消别的任务）
            local tasks = {}
            for id, t in pairs(inst._tasks) do tasks[#tasks + 1] = t end
            for _, t in ipairs(tasks) do
                if inst._tasks[t.id] ~= t then
                    -- 已被取消，跳过
                elseif World.time >= t.time then
                    if t.periodic then
                        t.time = World.time + t.delay
                    else
                        inst._tasks[t.id] = nil
                    end
                    t.fn(inst, unpack(t.args or {}))
                end
            end
        end
    end

    -- ★★ 真实调度器（update.lua:224 的第 1 步 `RunScheduler(i)`）
    --   `EntityScript:StartThread` 委托给全局 `StartThread`（真实 scheduler.lua:387），
    --   它把协程登记进 `scheduler`。**只有每 tick 调 RunScheduler，那些线程才会推进**，
    --   线程里的 `Sleep(t)` / `Yield()` 才有语义。
    --   不调的话：线程创建后永远停在第一帧，且第一次 Sleep 就抛
    --   `scheduler.lua:358: attempt to index local 'schedule' (a nil value)`。
    if type(RunScheduler) == "function" then
        local ok, err = pcall(RunScheduler, TheSim.tick)
        if not ok then Core.NoteStub("RunScheduler", "scheduler") end
    end

    -- ★★ 静态调度器（update.lua:185 `RunStaticScheduler(i)`）—— 之前**漏了**
    --
    --   真实 scheduler.lua 提供**两个独立的驱动入口**：
    --       RunScheduler(tick)         → scheduler:OnTick + scheduler:Run
    --       RunStaticScheduler(tick)   → staticScheduler:OnTick + staticScheduler:Run
    --   （scheduler.lua:582 与 :596），原版 update.lua 两处都调：
    --       :185  RunStaticScheduler(i)     ← 在最前面，与「常规」那段分开
    --       :247  RunScheduler(i)
    --
    --   宿主此前只调了 RunScheduler —— 于是 `staticScheduler` **从来没有被推进过**。
    --   后果：所有走静态调度器的机制全是死的，其中就有我们刚实现的
    --   `EntityScript:DoStaticTaskInTime`（entityscript.lua:3775
    --   `staticScheduler:ExecuteInTime(...)`）—— 任务能登记、永远不执行，
    --   `pendingtasks` 也永远摘不掉。
    --   真实调用点：inventory_replica.lua:26（下一帧再开背包，等分类实体就位）、
    --   dryingrack.lua:312、clientpickupsoundsuppressor.lua:23。
    if type(RunStaticScheduler) == "function" then
        local ok, err = pcall(RunStaticScheduler, TheSim.tick)
        if not ok then Core.NoteStub("RunStaticScheduler", "scheduler") end
    end

    -- ★★ 组件更新泵（host/13_update.lua）—— 对应 update.lua:255-268
    --   「for ent in UpdatingEnts: for cmp in ent.updatecomponents: cmp:OnUpdate(dt)」
    --   顺序与真实引擎一致：调度器/任务 → 组件 → 状态图 → 大脑。
    local Pump = Sim.Pump
    if Pump ~= nil then
        Pump.StepComponents(dt)
    end

    -- ★ 驱动真实 SGManager（stategraph.lua:11 `SGManager = StateGraphWrangler()`）。
    --   它按 current_tick 分桶管理实例：updaters / hibernaters / tickwaiters，
    --   实现「实体不活跃就休眠、到点自动唤醒」。
    --   ★ Update(current_tick) 吃的是 **tick 号**（整数），不是秒。
    --   ★ UpdateEvents() 必须在所有实例 Update 之后调 —— 这就是原版的
    --   「刻末批处理事件」（bug-patterns H3），与事件总线的立即派发
    --   是两条不同时间线。
    if SGManager then
        -- ★★ 错误必须**记下来**，不能只记一次「有个桩」。
        --   原先这两处 pcall 只 `Core.NoteStub(...)`，错误信息**整个丢掉** ——
        --   于是「每帧都报 SGManager.Update 桩」这种症状完全无法定位
        --   （实测扩大生物种类后 x6739 次，连是哪个实例、什么错都不知道）。
        --   现在按脑错误（13_update.lua 的 LastBrainError）的同款做法，
        --   存前 3 条完整错误 + 计数，并暴露成 Core.SGErrors 供探针读取。
        Core.SGErrors = Core.SGErrors or {}
        Core.SGErrorCount = Core.SGErrorCount or 0
        if type(SGManager.Update) == "function" then
            -- ★ 必须把 SGManager 自己作为 self 传进去。
            --   `pcall(SGManager.Update, tick)` 会让 tick 变成 self，
            --   于是 self.tickwaiters 报错被 pcall 静默吞掉 —— 状态图永不更新。
            local ok, err = pcall(SGManager.Update, SGManager, TheSim.tick)
            if not ok then
                Core.SGErrorCount = Core.SGErrorCount + 1
                if #Core.SGErrors < 3 then
                    Core.SGErrors[#Core.SGErrors + 1] = tostring(err)
                end
                Core.NoteStub("SGManager.Update", "sgmanager")
            end
        end
        if type(SGManager.UpdateEvents) == "function" then
            local ok2, err2 = pcall(SGManager.UpdateEvents, SGManager)
            if not ok2 then
                Core.SGErrorCount = Core.SGErrorCount + 1
                if #Core.SGErrors < 3 then
                    Core.SGErrors[#Core.SGErrors + 1] = "UpdateEvents: " .. tostring(err2)
                end
                Core.NoteStub("SGManager.UpdateEvents", "sgmanager")
            end
        end
    end

    -- ★★ 实体休眠：远离「活动中心」的实体进入休眠，停止组件更新。
    --   真实引擎由 C++ 按玩家距离做，宿主在这趟里等价实现（见 13_update.lua）。
    --   默认 30 tick 一次 —— 距离变化是慢变量，每 tick 算 90 次纯属浪费。
    if Pump ~= nil and Pump.UpdateSleepStates ~= nil
        and TheSim.tick % 30 == 0 and Sim.SleepCenter ~= nil then
        local cx, cz, sr = Sim.SleepCenter()
        if cx ~= nil then Pump.UpdateSleepStates(cx, cz, sr) end
    end

    -- ★★ 大脑更新（brain.lua:106 `BrainWrangler:Update(current_tick)`）
    --   对应 update.lua:291-293 的 `BrainManager:Update(i)`。
    --   没有它，BehaviourTree 永不 Update ⇒ 生物永不决策（此前正是如此）。
    if Pump ~= nil then
        Pump.StepBrains(TheSim.tick)
    end
end

function Sim.Run(ticks, dt)
    ticks = ticks or 100
    for _ = 1, ticks do Sim.Step(dt) end
end

return Sim
