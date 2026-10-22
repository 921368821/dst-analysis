--[[
==============================================================================
 01_core.lua —— 引擎契约核心（实体 / 组件 / 标签 / 事件 / 预制体）

 目标：忠实复刻 DST 引擎对 Lua 暴露的「对象契约」，
       让 DST 原版 prefab 脚本不改一行跑起来。

 复刻依据：120 个已深度注释的核心文件。

 设计原则：
   1) 只实现「Lua 层能观察到的契约」，不模仿 C++ 内部实现
   2) 能复用真实 DST 文件就复用（class.lua / scheduler.lua 低耦合）
   3) C++ 组件桩由 00_stubs.lua 表驱动生成，一次覆盖全部方法面
   4) 每个未实现的接口都记入 Gaps，最终输出精确缺口清单

 ★ 与 03-参考架构 的区别
   03-参考架构 是「教学级最小实现」，讲清楚架构
   本文件是「契约级实现」，目标是让真实 prefab 跑起来
==============================================================================
]]

local Stubs = require("host.00_stubs")
local Paths = require("host.00_paths")

local Core = {}
Core.__index = Core

--- DST 源码根目录（真实文件只读）
-- ★ 不再硬编码：由 `host/00_paths.lua` 统一解析（环境变量 DST_SRC 优先，
--   否则按本文件位置 / cwd 推断）。原来这串字面量在 01_core / 02_sim / 04_loader
--   里各有一份，迁移工作区时漏改一处不会报错，只会「模块静默缺失」。
Core.SourceDir = Paths.SourceDir()

--=========================================================================
-- 全局注册表
--=========================================================================
Core.Prefabs = {}          -- name -> {fn, assets, prefabs}
Core.Spawned = {}          -- guid -> inst
Core.NextGUID = 1
Core.World = nil           -- 由 02_sim.lua 填充
Core.Gaps = {}             -- 记录「原版需要但宿主未实现」的接口
Core.GapCount = {}

--- 记录一次契约缺口（同一接口只登记一次，但累计次数）
function Core.NoteGap(api, context)
    if not Core.Gaps[api] then
        Core.Gaps[api] = { api = api, contexts = {} }
    end
    table.insert(Core.Gaps[api].contexts, context or "?")
    Core.GapCount[api] = (Core.GapCount[api] or 0) + 1
    return nil
end

--- 记录一次「契约内桩调用」——方法我们知道存在、也实现了桩，
--- 但没有真实语义（如 AnimState:OverrideSymbol 只返回 nil）。
--- 与 NoteGap 分开统计，避免把「已知接口」误报成「未知缺口」。
Core.StubCalls = {}
Core.StubCount = {}

function Core.NoteStub(api, context)
    if not Core.StubCalls[api] then
        Core.StubCalls[api] = { api = api, contexts = {} }
    end
    table.insert(Core.StubCalls[api].contexts, context or "stub")
    Core.StubCount[api] = (Core.StubCount[api] or 0) + 1
    return nil
end

--- 输出缺口清单
-- 分两类报告，避免混淆：
--   · 契约外接口（真缺口）—— 需要补实现
--   · 契约内桩调用（已知接口）—— 已有桩，缺真实语义
function Core.DumpGaps()
    local function sorted(map, count)
        local keys = {}
        -- ★ map 可能是 nil：`Core.MissingBuilds` 是**惰性创建**的
        --   （只在 OnMissing 里首次创建），所以「一个缺失 build 都没有」时
        --   它压根不存在 ⇒ `pairs(nil)` 直接抛
        --   `bad argument #1 to 'pairs' (table expected, got nil)`。
        --   而那恰恰是**最该安静通过**的情况。
        if map == nil then return keys end
        for k in pairs(map) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            return (count[a] or 0) > (count[b] or 0)
        end)
        return keys
    end

    print("")
    print("════ 契约缺口清单 ════")

    local gapKeys = sorted(Core.Gaps, Core.GapCount)
    if #gapKeys == 0 then
        print("  【真缺口】无 —— 原版脚本用到的接口宿主全部知道")
    else
        print(string.format("  【真缺口】%d 个（契约外接口，需补实现）：", #gapKeys))
        for i, k in ipairs(gapKeys) do
            if i > 25 then
                print(string.format("    ... 另有 %d 个", #gapKeys - 25))
                break
            end
            local ctx = {}
            for j = 1, math.min(2, #Core.Gaps[k].contexts) do
                ctx[#ctx + 1] = Core.Gaps[k].contexts[j]
            end
            print(string.format("    %2d. %-40s x%-4d [%s]",
                i, k, Core.GapCount[k], table.concat(ctx, ",")))
        end
    end

    local stubKeys = sorted(Core.StubCalls, Core.StubCount)
    print("")
    if #stubKeys == 0 then
        print("  【桩调用】无")
    else
        print(string.format("  【桩调用】%d 个（契约内已知接口，已有桩实现、缺真实语义）：",
            #stubKeys))
        for i, k in ipairs(stubKeys) do
            if i > 20 then
                print(string.format("    ... 另有 %d 个", #stubKeys - 20))
                break
            end
            print(string.format("    %2d. %-40s x%d", i, k, Core.StubCount[k]))
        end
    end

    -- ★ 第三类单列：**动画 build 没导出数据**（不是「方法缺语义」）
    --   典型来源：加载 hats.lua 后原版会给 wilson 登记二十多个 player_* 动作 build
    --   （player_actions_farming / player_oar / player_boat_* …），本场景一个都用不到。
    --   混进桩调用会把真正要补语义的项淹掉，所以必须分开报。
    local mbKeys = sorted(Core.MissingBuilds, Core.MissingBuildCount)
    if #mbKeys > 0 then
        print("")
        print(string.format(
            "  【缺 build 数据】%d 个（这些 build 未导出 anim_data；本场景用不到的不必补）：",
            #mbKeys))
        for i, k in ipairs(mbKeys) do
            if i > 8 then
                print(string.format("    ... 另有 %d 个", #mbKeys - 8))
                break
            end
            print(string.format("    %2d. %-40s x%d", i, k, Core.MissingBuildCount[k]))
        end
    end
end

--- 生成一个「什么都能接」的桩对象：任何方法调用都记录缺口并返回 nil
function Core.MakeStub(name)
    local seen = {}
    return setmetatable({}, {
        __index = function(_, k)
            if type(k) ~= "string" or k:match("^__") then return nil end
            if seen[k] then return nil end
            seen[k] = true
            return function(...)
                Core.NoteGap(name .. ":" .. k, "stub")
                return nil
            end
        end,
        __tostring = function() return "[stub " .. name .. "]" end,
    })
end

--=========================================================================
-- 实体句柄（inst.entity）—— 真实引擎里这是 C++ Entity
--=========================================================================
--- LightWatcher 组件桩（带兜底 __index，避免连锁式补方法）
--
-- ★ 为什么必须显式实现 GetTimeInLight / GetTimeInDark
--   真实 LightWatcher 是 C++ 组件，对外给出的核心量是「在光里待了多久 /
--   在黑暗里待了多久（秒）」。调用方拿它做**数值比较**：
--     components/wisecracker.lua:522
--         elseif self.inlight and self.inst.LightWatcher:GetTimeInDark() >= 0.5 then
--   如果桩返回 nil，`nil >= 0.5` 直接抛「attempt to compare number with nil」，
--   于是 wisecracker 的 OnUpdate 每 tick 崩一次（实测 2550 次），
--   整个「会话/独白」链路失效。
--
--   宿主世界恒为白天（TheWorld.state.isday 永远 true，没有昼夜/光照求解器），
--   所以对宿主而言正确的投影就是：**一直在光里**。
--   于是 GetTimeInDark 恒 0、GetTimeInLight 取「世界已经过了多久」。
-- ★★★ C3（2026-10-18 P44）：光照的**唯一真源**
--
--   修之前有两个互相矛盾的恒定值，而且都在同一个宿主里：
--       LightWatcher:IsInLight()  恒 **true**   （与 GetLightLevel 恒 1 自洽）
--       EntityScript:IsInLight()  恒 **false**
--   两处都被真实脚本调用：
--       behaviours/avoidlight.lua:47   self.inst.LightWatcher:IsInLight()
--       components/wisecracker.lua:522 LightWatcher:GetTimeInDark() >= 0.5
--       entityscript 侧的 self:IsInLight() 也有调用点
--   ⇒ 同一个问题「它在光里吗」得到两个相反答案，
--     而且**两个都不随昼夜变**。这不是“宿主没做光照”，是“宿主说了两句相反的话”。
--
--   真源选的是已有的世界状态（`TheWorld.state.phase`）——
--   06 的 world.lua 真的挂了 clock 组件（清单在 `host/30_worldmount.lua`，含 clock），
--   phase 会在 day/dusk/night 之间推进，所以这不是又一个假值。
--   没有真光照图的情况下，「环境亮度」就是阶段的单调函数 ——
--   它不能告诉你“火堆旁边多亮”，但它**能**告诉你“现在是不是晚上”，
--   而「夜里在户外就是黑的」正是这些 behaviour 真正依赖的那一半。
local function ambient_light_level()
    local w = _G.TheWorld
    local st = w and w.state
    local phase = (st and st.phase) or "day"
    if phase == "night" then return 0 end
    if phase == "dusk" then return 0.5 end
    return 1
end

-- ★ 对外可用（判据与有关系的组件都能问同一个问题）
Core.AmbientLightLevel = ambient_light_level

local function make_lightwatcher()  -- 见上方注释
    local lw = { _active = false, _thresh = 0.2, _darkthresh = 0.2 }
    lw._born = (_G.TheSim and _G.TheSim:GetTime()) or 0
    -- ★ 在光/在暗的**累计秒数**：倏性结算（无需外部每帧调 OnUpdate）。
    --   之前 GetTimeInDark 恒 0、GetTimeInLight 恒等于“开局至今” ——
    --   而 wisecracker.lua:522 就靠 `GetTimeInDark() >= 0.5` 决定每天的对话。
    --   恒 0 等于那条永远不成立。
    lw._light_accum = 0
    lw._dark_accum = 0
    lw._settled_at = lw._born
    local function settle(self)
        local now = (_G.TheSim and _G.TheSim:GetTime()) or 0
        local dt = now - (self._settled_at or now)
        if dt > 0 then
            -- ★ 用**当前**亮度把这一段计入对应缯：
            --   中间若跳变过，会算到最近一次状态上（范围只有一次查询间隔）。
            --   要精确到每一帧就得每帧调 OnUpdate，那不是本判据要解决的问题。
            if self:IsInLight() then
                self._light_accum = (self._light_accum or 0) + dt
            else
                self._dark_accum = (self._dark_accum or 0) + dt
            end
        end
        self._settled_at = now
    end
    lw.GetTimeInLight = function(self)
        settle(self)
        return self._light_accum or 0
    end
    lw.GetTimeInDark = function(self)
        settle(self)
        return self._dark_accum or 0
    end
    -- ★ 闽值真的参与判定（之前 SetLightThresh 只存不用）
    lw.GetLightLevel = function(self) return ambient_light_level() end
    -- ★★ 补上 `GetLightValue`（C++ 側的平滑光照值）。
    --   它是 **sanity 系统唯一的环境感知入口**：
    --     components/sanity.lua:1282
    --       local lightval = ... or self.inst.LightWatcher:GetLightValue()
    --       (lightval > 0.6 and NIGHT_LIGHT) or (lightval < 0.1 and NIGHT_DARK) or NIGHT_DIM
    --   宿主之前**根本没有这个方法** ⇒ 落到泛化桩返回 nil
    --   ⇒ `nil > 0.6` 抛错 ⇒ sanity 的 Recalc 整段中断。
    --   这就是「理智不下降」的真正原因之一：不是调参不对，是它每帧都在那一行爆掉。
    lw.GetLightValue = function(self) return ambient_light_level() end
    lw.IsInLight = function(self)
        local th = self._lightthresh or self._thresh or 0.2
        return ambient_light_level() >= th
    end
    lw.IsInDark = function(self)
        local th = self._darkthresh or self._thresh or 0.2
        return ambient_light_level() <= th
    end
    lw.SetLightRadius = function(self, r) self._radius = r end
    -- ★ 光照阈值三兄弟（creepyeyes.lua:54-55、flower_cave.lua:289-290 等在调）。
    --   真实语义：决定实体何时算「进入光/进入暗」，驱动 IsInLight / IsInDark 的翻转。
    --   宿主的 TheWorld 没有光照场（IsInLight 恒真、GetLightLevel 恒 1），
    --   所以阈值**存下来但不参与判定** —— 记下来是为了不静默吞掉调用，
    --   将来接光照时直接可用。
    lw.SetLightThresh = function(self, v) self._lightthresh = v end
    lw.SetDarkThresh = function(self, v) self._darkthresh = v end
    lw.SetMinLightThresh = function(self, v) self._minlightthresh = v end
    lw.GetLightThresh = function(self) return self._lightthresh or self._thresh end
    lw.GetDarkThresh = function(self) return self._darkthresh or self._thresh end
    lw.GetMinLightThresh = function(self) return self._minlightthresh or self._thresh end
    lw.OnUpdate = function() end
    return setmetatable(lw, {
        __index = function(t, k)
            if type(k) ~= "string" or k:match("^_") then return nil end
            local f = function(...)
                Core.NoteStub("LightWatcher:" .. k, "lightwatcher-fallback")
                return nil
            end
            rawset(t, k, f)
            return f
        end,
    })
end
local function make_entity_handle(inst)
    local h = {}
    local added = {}   -- 记录已挂载的 C++ 组件，供外部断言检查

    -- ══════════════════════════════════════════════════════════════════
    -- ★★★ 通用「C++ 子对象」代理工厂
    -- ══════════════════════════════════════════════════════════════════
    -- 真实引擎里 `inst.entity:AddXxx()` 会创建一个 C++ 侧子对象并**同时**挂到
    -- EntityScript 侧（如 `AddGroundCreep()` → `inst.GroundCreepEntity`），
    -- 之后 Lua 侧链式调用它的方法。
    --
    -- 宿主不可能把每个子对象的每个方法都实现一遍 —— 而且**枚举法今天已两次
    -- 证明会漏**（`SetMaxParticles` vs `SetMaxNumParticles`；
    --   `master_postinit` vs `projectile_postinit` 等 4 种 `*_postinit`）。
    -- 所以统一用一个**元表代理**：任何方法名都接得住、可链式、并记调用次数。
    --
    -- ★ 怎么发现这 12 个缺失的：静态扫「游戏代码里所有 `entity:AddXxx(`」
    --   （27 种）与「宿主实现了哪些」（19 种）做差 —— **不靠猜名字**。
    local function proxy_child(name)
        local rec = { _name = name, _calls = {} }
        return setmetatable(rec, {
            __index = function(t, k)
                if type(k) ~= "string" then return nil end
                local f = rawget(t, k)
                if f ~= nil then return f end
                local m = function(self, ...)
                    self._calls[k] = (self._calls[k] or 0) + 1
                    return self
                end
                rawset(t, k, m)
                return m
            end,
        })
    end
    h._proxy_child = proxy_child

    -- 一批「C++ 子对象」：宿主无渲染/无网络，给代理即可。
    -- 调用点分布（静态扫描结果）：
    --   AddGroundCreepEntity  5 文件（dropperweb / spiderden / bedazzlement …）
    --   AddClientSleepable    5 文件（itemmimic_revealed / wanderer 系 …）
    --   AddLabel              3 文件（dummytarget …）
    --   AddWaveComponent      3 文件（forest / wavey 系）
    --   AddServerNonSleepable / AddShardClient / AddShardNetwork /
    --   AddPathfinder / AddMap / AddMiniMap / AddUITransform / AddDebugRender
    --   —— 各 1 个文件
    local CHILD_PROXIES = {
        AddGroundCreepEntity = "GroundCreepEntity",
        AddClientSleepable   = "ClientSleepable",
        AddServerNonSleepable = "ServerNonSleepable",
        AddLabel             = "Label",
        AddWaveComponent     = "WaveComponent",
        AddDebugRender       = "DebugRender",
        AddMap               = "Map",
        AddMiniMap           = "MiniMap",
        AddUITransform       = "UITransform",
        AddPathfinder        = "Pathfinder",
        AddShardClient       = "ShardClient",
        AddShardNetwork      = "ShardNetwork",
    }
    for meth, field in pairs(CHILD_PROXIES) do
        local f = field
        h[meth] = function(self)
            if inst[f] == nil then inst[f] = proxy_child(f) end
            return inst[f]
        end
    end

    function h:AddTransform()
        inst.Transform = Stubs.Make("Transform", inst, Core.NoteGap, Core.NoteStub)
        return inst.Transform
    end
    function h:AddAnimState()
        inst.AnimState = Stubs.Make("AnimState", inst, Core.NoteGap, Core.NoteStub)
        return inst.AnimState
    end
    function h:AddLight()
        inst.Light = Stubs.Make("Light", inst, Core.NoteGap, Core.NoteStub)
        return inst.Light
    end
    function h:AddSoundEmitter()
        inst.SoundEmitter = Stubs.Make("SoundEmitter", inst, Core.NoteGap, Core.NoteStub)
        return inst.SoundEmitter
    end
    function h:AddMiniMapEntity()
        inst.MiniMapEntity = Stubs.Make("MiniMapEntity", inst, Core.NoteGap, Core.NoteStub)
        return inst.MiniMapEntity
    end
    function h:AddNetwork()
        inst.Network = Stubs.Make("Network", inst, Core.NoteGap, Core.NoteStub)
        inst._hasnetwork = true
        return inst.Network
    end
    function h:AddPhysics()
        inst.Physics = Stubs.Make("Physics", inst, Core.NoteGap, Core.NoteStub)
        return inst.Physics
    end
    --- burnable.lua:527 `fx.entity:AddFollower()` + `fx.Follower:FollowSymbol(...)`
    --- 真实引擎的跟随组件：让特效跟着实体的某个符号（动画锚点）走。
    --- 宿主只记录「跟随目标与符号名」，不做真实的位置插值。
    function h:AddFollower()
        inst.Follower = inst.Follower or {
            _target = nil, _symbol = nil, _offset = nil,
            FollowSymbol = function(self, guid, symbol, x, y, z, layered)
                self._target = guid
                self._symbol = symbol
                self._offset = { x or 0, y or 0, z or 0 }
            end,
            StopFollowing = function(self) self._target = nil end,
        }
        return inst.Follower
    end
    -- ★★ PhysicsWaker：真实引擎里 `inst.entity:AddPhysicsWaker()` 创建的是
    --   一个 C++ 对象，并且**同时**在 EntityScript 侧出现 `inst.PhysicsWaker`
    --   （`prefabs/boat.lua:531-532`：
    --        inst.entity:AddPhysicsWaker()
    --        inst.PhysicsWaker:SetTimeBetweenWakeTests(...)
    --    `components/boatdrifter.lua:44/48` 也直接用 `self.inst.PhysicsWaker`）。
    --
    --   原实现**返回的是 inst.Physics** —— 既不是 PhysicsWaker、也没设
    --   `inst.PhysicsWaker` ⇒ boat 系列预制体必然在 532 行崩
    --   （300 抽样里 2 个；boat / boat_ancient / boat_otterden 全挂）。
    function h:AddPhysicsWaker()
        if not inst.Physics then
            inst.Physics = Stubs.Make("Physics", inst, Core.NoteGap, Core.NoteStub)
        end
        if inst.PhysicsWaker == nil then
            local w = { _interval = nil, _running = false, _radius = nil }
            function w:SetTimeBetweenWakeTests(t) self._interval = t end
            function w:GetTimeBetweenWakeTests() return self._interval end
            function w:StartWakeTests() self._running = true end
            function w:StopWakeTests() self._running = false end
            function w:IsWakeTesting() return self._running end
            function w:SetMaxPhysicsRadius(r) self._radius = r end
            function w:GetMaxPhysicsRadius() return self._radius end
            inst.PhysicsWaker = w
            -- main.lua:476 还把 PhysicsWaker 当**全局静态**用：
            --   PhysicsWaker.SetMaxPhysicsRadius(MAX_PHYSICS_RADIUS)
            local G = rawget(_G, "PhysicsWaker")
            if type(G) == "table" and type(G.Register) == "function" then
                G.Register(w)        -- 顺便继承全局已设的上限值
            end
        end
        return inst.PhysicsWaker
    end
    -- ★★ AddVFXEffect()：真实引擎返回一个 C++ 特效对象，之后**链式**调用。
    --
    --   证据：`prefabs/rain.lua:101-105`、`prefabs/eyeflame.lua:130-134`：
    --       local effect = inst.entity:AddVFXEffect()
    --       effect:InitEmitters(1)
    --       effect:SetRenderResources(0, TEXTURE, SHADER)
    --       effect:SetRotationStatus(0, true)
    --       effect:SetMaxNumParticles(0, 5)
    --       ...
    --   宿主原先**没有这个方法**（句柄对未知方法返回 nil）⇒
    --       `local effect = ...` 拿到 nil ⇒ 下一行崩 ⇒ rain / eyeflame 生成不出来。
    --
    --   ★★★ 用**元表代理**而不是逐个枚举方法名。
    --   我从 DST 源码里提取过完整方法集（30 个：AddParticle /
    --   SetMaxNumParticles / SetColourEnvelope / SetSpawnVectors / …），
    --   但**枚举法有个已知的失败模式**——今天已经因为「猜方法名/字段名」
    --   错过 7 次（`cookable`/`cooker`、`C.items`、`finiteuses.uses`、
    --   `H:TakeDamage`、`SetMaxParticles`/`SetMaxNumParticles`…）。
    --   代理法从根上避免这类错误：**任何名字都接得住**。
    --   调过的名字记进 `_calls`（可观测），需要时能看清单。
    function h:AddVFXEffect()
        if inst.VFXEffect == nil then
            local rec = { _calls = {} }
            inst.VFXEffect = setmetatable(rec, {
                __index = function(t, k)
                    if type(k) ~= "string" then return nil end
                    local f = rawget(t, k)
                    if f ~= nil then return f end
                    local m = function(self, ...)
                        self._calls[k] = (self._calls[k] or 0) + 1
                        return self          -- 可链式
                    end
                    rawset(t, k, m)
                    return m
                end,
            })
            -- 明确有返回值的几个（链式代理会让调用方拿到 self，这里给出更准的语义）
            inst.VFXEffect.IsEnabled = function() return false end
            inst.VFXEffect.GetNumEmitters = function() return 0 end
        end
        return inst.VFXEffect
    end
    -- ★★ AddGroundCreep()：真实引擎创建 `inst.GroundCreepEntity`（地面蔓延体），
    --   之后 Lua 侧链式调它的方法：
    --       `components/bedazzlement.lua:26/52`  self.inst.GroundCreepEntity:SetRadius(...)
    --       `prefabs/dropperweb.lua:92`          inst.GroundCreepEntity:SetRadius(5)
    --   宿主原先是个**空函数** ⇒ `inst.GroundCreepEntity` 恒 nil
    --       ⇒ `attempt to index field 'GroundCreepEntity' (a nil value)`
    --   实测：1000 抽样里 **4 个**栽在这条上（最大单一类别）。
    --
    --   ★ 用**元表代理**（与 AddVFXEffect 同一做法）——任何方法名都接得住，
    --     不必枚举。今天已两次证明「枚举法会漏」。
    function h:AddGroundCreep()
        if inst.GroundCreepEntity == nil then
            local rec = { _calls = {} }
            inst.GroundCreepEntity = setmetatable(rec, {
                __index = function(t, k)
                    if type(k) ~= "string" then return nil end
                    local f = rawget(t, k)
                    if f ~= nil then return f end
                    local m = function(self, ...)
                        self._calls[k] = (self._calls[k] or 0) + 1
                        return self
                    end
                    rawset(t, k, m)
                    return m
                end,
            })
        end
        return inst.GroundCreepEntity
    end
    function h:AddImageWidget() end
    function h:AddTextWidget() end
    function h:AddImage() end
    -- ★★★ AddShadowManager / AddRoadManager / AddEnvelopeManager / AddPostProcessor
    --   —— 与 AddVFXEffect 同属「C++ 渲染层子对象」，宿主四个都没有。
    --
    --   实测症状（reachability.lua 抽样，3 个预制体）：
    --       prefabs/pollen.lua:21                  EnvelopeManager:AddColourEnvelope(...)
    --       prefabs/nightsword_sharp_fx.lua:32     EnvelopeManager:AddColourEnvelope(...)
    --       prefabs/lunar_goop_cloud_fx.lua:22     EnvelopeManager:AddColourEnvelope(...)
    --       ✘ attempt to index global 'EnvelopeManager' (a nil value)
    --     ⇒ pollen / nightsword_sharp_fx / lunar_grazer(=cloud) 三个预制体
    --       工厂全灭，而且 `pollen` 是 **weather.lua:400 在服务端主动 spawn 的**。
    --
    --   用法面小得出奇（全库计数，不是印象）：
    --       EnvelopeManager:AddColourEnvelope  93 次
    --       EnvelopeManager:AddVector          83 次
    --       返回值被保存的                **0 次**
    --   ⇒ 只需「接得住这两个方法名」即可，无需实现信封语义。
    --
    --   ★ 用**代理法**（与 AddVFXEffect / AddGroundCreep 同一做法）。
    --     本工程已两次实证「枚举法会漏」（SetMaxParticles vs SetMaxNumParticles、
    --     `*_postinit` 变体），代理法从根上避免。
    --
    --   诚实边界：宿主是 **headless 服务端形态**，没有后处理管线 ⇒
    --     信封被**登记**（`_calls` 可见）但**不产生任何视觉效果**。
    --     这不影响任何逻辑量；视觉效果由浏览器播放器那条完全不同的链路负责。
    local function chain_proxy(get, set, seed)
        return function()
            local p = get()
            if p == nil then
                local rec = seed and seed() or { _calls = {} }
                p = setmetatable(rec, {
                    __index = function(t, k)
                        if type(k) ~= "string" then return nil end
                        local f = rawget(t, k)
                        if f ~= nil then return f end
                        -- ★ 链式：返回 self，让 `a:B():C()` 不炸
                        local m = function(self, ...)
                            self._calls[k] = (self._calls[k] or 0) + 1
                            return self
                        end
                        rawset(t, k, m)
                        return m
                    end,
                })
                set(p)
            end
            return p
        end
    end

    h.AddShadowManager = chain_proxy(
        function() return inst.ShadowManager end,
        function(v) inst.ShadowManager = v end,
        -- SetTexture 之后没有返回值语义，但保险起见给个 self 链
        function() return { _calls = {} } end)

    h.AddRoadManager = chain_proxy(
        function() return inst.RoadManager end,
        function(v) inst.RoadManager = v end)

    h.AddEnvelopeManager = chain_proxy(
        function() return inst.EnvelopeManager end,
        function(v) inst.EnvelopeManager = v end)

    h.AddPostProcessor = chain_proxy(
        function() return inst.PostProcessor end,
        function(v) inst.PostProcessor = v end)

    function h:AddDynamicShadow()
        added.dynamicshadow = true
        inst._hasdynamicshadow = true
        inst.DynamicShadow = inst.DynamicShadow or {
            _enabled = true,
            _width = 1, _height = 1,
            SetEnabled = function(self, on) self._enabled = on end,
            Enable = function(self) self._enabled = true end,
            Disable = function(self) self._enabled = false end,
            -- pigman.lua:588 `inst.DynamicShadow:SetSize(1.5, .75)`
            SetSize = function(self, w, h)
                self._width, self._height = w or 1, h or 1
            end,
            GetSize = function(self) return self._width, self._height end,
        }
        return inst.DynamicShadow
    end
    function h:Remove() inst._removed = true end
    -- ★★ SetParent 的语义修正（2026-10-14）
    --
    -- 原实现 `inst._parent = parent` 把**实体句柄**存进了 `_parent`，
    -- 而 DST 的 Lua 层里 `child._parent` 是**父实体的 EntityScript**。证据：
    --   player_classified.lua:817（真实加载的那份）
    --       inst._parent.components.playervision:SetGhostVision(...)
    --   player_classified.lua:814
    --       inst._parent.replica.inventory ~= nil
    -- 这两处都把 `_parent` 当 EntityScript 用（要访问 `.components` / `.replica`）。
    --
    -- 症状（接线 staticScheduler 后才暴露，见 Sim.Step 里的 RunStaticScheduler）：
    --   "player_classified.lua:817: attempt to index field 'components'
    --    (a function value)"
    -- —— `components` 是「函数」，因为 `_parent` 是实体句柄，取它的未知字段
    -- 会命中句柄的兜底 __index（返回一个记录缺口的函数）。
    --
    -- 真实引擎里 entity:SetParent(inst2.entity) 由 C++ 同时维护两侧指针，
    -- 所以两边各存各的：Lua 侧 `_parent` = EntityScript，
    -- C++ 侧 `entity:GetParent()` = 实体句柄。这里照做。
    -- ★★★ 父子关系：`_parent` 与 `GetParent()` 都是**父实体的 EntityScript**
    --
    -- 决定性证据（原版 classified 预制体里成片出现）：
    --     container_classified.lua:69      inst._parent = inst.entity:GetParent()
    --     constructionsite_classified.lua:36 inst._parent = inst.entity:GetParent()
    --     attunable_classified.lua:8        inst._parent = inst.entity:GetParent()
    --     container_opener.lua:8            inst._parent = inst.entity:GetParent()
    -- 而这些 `_parent` 随后都被当 EntityScript 用（要访问 .components / .replica），
    -- 例如 player_classified.lua:817（真实加载的那份）
    --     inst._parent.components.playervision:SetGhostVision(...)
    --
    -- ⇒ 所以 `entity:GetParent()` 返回的必须是**父实体的 EntityScript**，
    --    而不是实体句柄。Klei 的 C++ 就是这么做的（push 父实体的 Lua 表）。
    --
    -- 症状（接线 staticScheduler 后暴露）：
    --   "player_classified.lua:817: attempt to index field 'components'
    --    (a function value)"
    -- —— `components` 是「函数」，因为 `_parent` 拿到的是实体句柄，
    --    读它的未知字段会命中句柄的兜底 __index（返回一个记录缺口的函数）。
    --
    -- 语义分工（两边各存各的）：
    --   inst._parent        = 父 EntityScript   ← `entity:GetParent()` 的返回值
    --   inst._parententity  = 父实体句柄        ← 引擎内部指针，Lua 侧一般不用
    h._inst = inst
    function h:SetParent(parent)
        -- parent 是**实体句柄**（DST 里恒为 `entity:SetParent(inst2.entity)`；
        -- 解除时传 nil，见 entityscript.lua:892）。
        if parent == nil then
            inst._parent = nil
            inst._parententity = nil
        else
            inst._parententity = parent
            -- 句柄 → EntityScript。取不到就留 nil（宁可 nil，
            -- 也不要塞一个「读未知字段会返回函数」的句柄 —— 那正是上面的崩溃根因）。
            inst._parent = rawget(parent, "_inst")
        end
    end
    function h:GetParent() return inst._parent end
    function h:GetParentEntity() return inst._parententity end
    function h:SetPristine() inst._pristine = true end
    function h:IsPristine() return inst._pristine end
    function h:SetAwake() inst._asleep = false end
    function h:SetSleep() inst._asleep = true end
    function h:IsAwake() return not inst._asleep end
    function h:GetName() return inst._name end
    function h:HasTag(t) return inst:HasTag(t) end
    function h:AddTag(t) return inst:AddTag(t) end
    function h:RemoveTag(t) return inst:RemoveTag(t) end
    function h:NumTags() return inst:NumTags() end
    function h:SetCanSleep() end
    function h:SetCanSleepInPocket() end
    function h:AddSound() end
    function h:RemoveSound() end

    -- ★ player_common.lua:2422 等玩家专用
    function h:AddLightWatcher()
        added.lightwatcher = true
        -- LightWatcherComponent：真实引擎用它监听光照变化以做眼睛适应
        inst.LightWatcher = make_lightwatcher()
        return inst.LightWatcher
    end
    function h:EnableMovementPrediction(on) inst._movpred = on end
    function h:FrustumCheck(x, y, z, angle) return true end
    -- simutil.lua 的 FindClosestPlayerInRange 会筛 `v.entity:IsVisible()`
    function h:IsVisible() return true end
    function h:IsValid() return true end
    function h:IsShadow() return false end

    -- ★ 真实引擎的 `EntityScript:IsAsleep()` 是 `not self.entity:IsAwake()`
    --   （entityscript.lua:1730）。而 brain.lua:137 的更新泵会调
    --   `k.inst.entity:IsValid()`、`k.inst:IsAsleep()` 决定要不要跑这个脑。
    --   缺了 IsAwake 会被实体句柄的兜底 __index 吞成 nil 函数返回值，
    --   于是「永远在睡」→ 脑子永远不跑。
    function h:IsAwake() return not inst._asleep end
    function h:IsAsleep() return inst._asleep == true end

    -- ★ entityscript.lua:783 / :789 的真实实现就是 `self.entity:Hide(false)` /
    --   `self.entity:Show(false)`（false = 不隐藏阴影）。
    --   旧实现只转发给 AnimState，实体本身（碰撞盒、光源、小地图点）没被隐藏。
    --   调用点：fishable.lua:71（收鱼时藏鱼）、blinkstaff.lua:84（瞬移施法者）。
    -- 顺带把 AnimState 也切掉：实体隐藏时贴图自然不该画，两者语义一致。
    function h:Hide(hideshadow)
        inst._entityhidden = true
        inst._hideshadow = hideshadow
        if inst.AnimState then inst.AnimState:Hide() end
    end
    function h:Show(hideshadow)
        inst._entityhidden = nil
        inst._hideshadow = hideshadow
        if inst.AnimState then inst.AnimState:Show() end
    end
    function h:IsShown() return inst._entityhidden ~= true end

    -- ★ entityscript.lua:874 ForceOutOfLimbo 的落地端：
    --   `self.entity:SetInLimbo(self:IsInLimbo() and not self.forcedoutoflimbo or false)`
    -- limbo = 「实体已从活跃世界摘除，但对象还在」。宿主无场景图，
    -- 但 13_update.lua:13_update 的更新泵会按 IsInLimbo 跳过它 —— 这个语义是真的。
    -- ⚠️ 必须真的把 _inlimbo 写回去：否则 ForceOutOfLimbo 那行三态真值表
    --    算出来的参数无处落地，整套 limbo 逻辑就是空转。
    function h:SetInLimbo(v)
        inst._inlimbo = v and true or false
    end

    -- minimap.lua / MapExplorer 相关：宿主无小地图，只登记是谁在探索
    function h:AddMapExplorer(explorer) inst._mapexplorers = inst._mapexplorers or {}; inst._mapexplorers[#inst._mapexplorers + 1] = explorer end
    function h:RemoveMapExplorer(explorer) inst._mapexplorers = nil end

    -- ★ 兜底 __index：玩家（player_common 2986 行）会碰到大量实体句柄方法，
    --   逐个补会被「连锁式缺一个」拖死。这里让未知方法可调用并**记录为桩调用**，
    --   缺口清单可查，不静默吞掉。
    return setmetatable(h, {
        __index = function(t, k)
            if type(k) ~= "string" or k:match("^_") then return nil end
            local f = function(...)
                Core.NoteStub("entity:" .. k, "entity-handle-fallback")
                return nil
            end
            rawset(t, k, f)
            return f
        end,
    })
end

--=========================================================================
-- 实体脚本对象（inst）—— 对应 entityscript.lua 的 EntityScript
--=========================================================================

Core.EntityMeta = {}
Core.EntityMeta.__index = Core.EntityMeta

--=========================================================================
-- ★★★ 状态图实例的**方法清单只在这里维护一份**
--
--   背景（这是「枚举法会漏」的第 N 次实证）：
--     兜底 sg 的方法表原先散在**三处**，各自手写一份：
--        ① Core.DefaultSG（本文件）              —— 19 个方法
--        ② SetStateGraph 的降级分支（06_entityscript） —— 12 个方法
--        ③ _G.StateGraphInstance 的补丁（05_bootstrap）—— 17 个方法
--     三份**全部漏了 `HasState`**，而真实原版 `stategraph.lua:1976`
--     是有它的。
--
--   实测症状（reachability.lua 抽样 300 个预制体，4 个 `*corpse` 失败）：
--       componentutil.lua:942 `ent.sg and ent.sg:HasState("electrocute")`
--       ✘ attempt to call method 'HasState' (a nil value)
--     ⇒ corpses.lua:188 `GetCombatFxSize` 崩 ⇒ `*corpse` 工厂全灭。
--
--   为什么必须查**定义表**而不是当前状态：
--     原版 `StateGraphInstance:HasState` 读的是 `self.sg.states[name]`
--     —— 即「这个状态图**定义里**有没有这个状态」（能力查询），
--     与 `HasStateTag`（**当前**状态有没有这个标签）是两件事。
--     ⇒ 兜底实现必须保持这个语义，不能一律 return false。
--
--   防复发：tools/audit_sg_methods.py 从真实 stategraph.lua 静态提取
--   `function StateGraphInstance:NAME(` 全集，与本清单做差；
--   tests.lua 里也有一条断言直接比对（数字不对就红）。
--=========================================================================
Core.SG_METHODS = {
    HasAnyStateTag  = function() return false end,
    HasStateTag     = function() return false end,
    -- ★ 查定义表，不是当前状态（stategraph.lua:1976-1979）
    HasState        = function(self, statename)
        return self.sg ~= nil and self.sg.states ~= nil
               and self.sg.states[statename] ~= nil
    end,
    IsCurrentState  = function() return false end,
    GetCurrentState = function() return nil end,
    IsPlaying       = function() return true end,
    IsPlayingState  = function() return false end,
    GetPlaying      = function() return true end,
    GetTimeScale    = function() return 1 end,
    SetTimeScale    = function() end,
    SetEnabled      = function() end,
    SetPlaying      = function() end,
    PlayAnimation   = function() end,
    PushAnimation   = function() end,
    GetTransition   = function() return nil end,
    go_to           = function() end,
    AnimDone        = function() return false end,
    GetPreviousState= function() return nil end,
    GetTimeInState  = function() return 0 end,
    SetTimeout      = function() end,
    IsListeningForEvent = function() return false end,
    PushEvent       = function() end,
    StartAction     = function() return false end,
    StopAction      = function() end,
    PreviewAction   = function() return true end,
    Restart          = function() end,
}

--- 把「兜底方法」补进一张状态图对象（已有同名函数则不覆盖）
-- ★ opts.only_missing 默认 true：真实 StateGraphInstance 上已经存在的方法
--   一律不动 —— 补丁绝不能盖掉真实实现。
function Core.ApplySGMethods(t, opts)
    if type(t) ~= "table" then return t end
    local only_missing = (opts == nil) or (opts.only_missing ~= false)
    for name, fn in pairs(Core.SG_METHODS) do
        if not only_missing or rawget(t, name) == nil then
            t[name] = fn
        end
    end
    return t
end

--- 构造一个「空状态图」实例。
-- 真实 SG 加载常失败（stategraph.lua:188 的断言：SGwilson 有 28601 行，
-- 部分状态过不了宿主校验），所以实体必须有一个可用的兜底 sg。
function Core.DefaultSG(name)
    return Core.ApplySGMethods({
        _name = name or "_default", _current = nil,
        mem = {},
    }, { only_missing = false })
end

-- ★ EntityMeta 的元表：`inst.sg` 被真实代码置空/替换成不完整对象时，
--   访问会自动补一个可用的兜底 sg。实测 slipperyfeet.lua:118 会读到
--   一个「存在但缺 HasAnyStateTag」的 sg，只在构造时兜底不够。
setmetatable(Core.EntityMeta, {
    __index = function(t, k)
        if k == "sg" then
            -- ★ 不只兜底 nil：真实代码可能把 inst.sg 设成**字符串**
            --   （SG 名字）或残缺对象，那两种情况调用 HasAnyStateTag 都会得到
            --   "attempt to call method ... (a nil value)"。
            --   所以只要当前值不是表，就换成可用的兜底 sg。
            local cur = rawget(t, "sg")
            if type(cur) == "table" and type(cur.HasAnyStateTag) == "function" then
                return cur
            end
            local sg = Core.DefaultSG(type(cur) == "string" and cur or nil)
            rawset(t, "sg", sg)
            return sg
        end
        return nil
    end,
})

-- ★ 前向声明：`NewEntity` 要用 `make_replica`，而它的定义在文件后段。
--   （Lua 的 local 作用域是词法的 —— 不声明的话在 NewEntity 里看不到它，
--     实测报 `attempt to call global 'make_replica' (a nil value)`。）
local make_replica

function Core.NewEntity(name)
    local inst = setmetatable({}, Core.EntityMeta)

    inst._name = name or ("entity_" .. Core.NextGUID)
    inst._guid = Core.NextGUID
    Core.NextGUID = Core.NextGUID + 1

    -- ★ 真实引擎的实体有 GUID 字段，netvar 声明大量依赖它
    --   （net_bool(inst.GUID, "name", "event") 共 884 处调用）。
    --   漏了它会让 netvar 的 guid 参数变成 nil，注册表全乱。
    inst.GUID = inst._guid

    -- ★★★ knownlocations 是**引擎默认组件**，不是 prefab 自己加的。
    --
    --   证据（全库计数，不是印象）：
    --       `AddComponent("knownlocations")`  出现 **122** 次
    --       而 `components.knownlocations` 被读 **460** 次
    --   ⇒ 有 338 处读取的实体**自己没加过它** ⇒ 只能是引擎挂的
    --     （`components/knownlocations.lua` 的构造只做 `self.locations = {}`，
    --       没有任何 SetUp 前置，符合「引擎级默认组件」的形态）。
    --
    --   实测症状（300 抽样里 2 个）：
    --       `brains/caveventmitebrain.lua:81`
    --         self.inst.components.knownlocations:RememberLocation("home", ...)
    --       而 `prefabs/cave_vent_mite.lua` **没有** add 它
    --       ⇒ `attempt to index field 'knownlocations' (a nil value)`
    --       同型：`brains/alterguardian_phase2brain.lua:44`
    --
    -- ★ spawntime：`GetTimeAlive`（entityscript.lua:435-437）要用
    --   `GetTime() - self.spawntime`，漏了它恒等于「存活 0 秒」。
    inst.spawntime = (GetTime ~= nil and GetTime()) or 0

    inst._tags = {}
    inst._components = {}
    inst._listeners = {}
    inst._tasks = {}
    inst._taskid = 0
    inst._removed = false
    inst._asleep = false
    inst._pristine = false
    inst.persists = true
    inst._eventcount = 0

    inst.entity = make_entity_handle(inst)
    inst.components = {}

    -- ★★★ `replica` 必须**在这里建**（entityscript.lua:244），不能惰性创建。
    --
    --   惰性创建（只在 AddComponent 里 `if self.replica == nil then ...`）
    --   有一个致命缺口：**没有任何组件的实体永远没有 replica**。
    --   而 `FindEntity`（simutil.lua:37）会把这些实体也当候选目标，
    --   战斗代码随后访问 `target.replica.combat`
    --       → `combat_replica.lua:302: attempt to index field 'replica' (a nil value)`
    --   实测：hound.lua:182 → FindEntity → IsValidTarget 这条链就是这么崩的。
    --
    --   ★ 这一条**曾经修过**，但在 2026-10-15 我误把本文件截断、
    --     又用一份更早的备份恢复时**丢掉了** —— 属于「恢复不完整」造成的回退。
    --     （丢的东西靠二分与「文件 mtime + 该有的修复清单」比对才找回来。）
    inst.replica = make_replica(inst)

    -- ★★★ knownlocations 是**引擎默认组件**（C++ 侧给每个实体挂）。
    --
    --   证据（全库计数，不是印象）：
    --       `AddComponent("knownlocations")`  出现 **122** 次
    --       而 `components.knownlocations` 被读 **460** 次
    --   ⇒ 有 338 处读取的实体**自己没加过它** ⇒ 只能是引擎挂的
    --     （该组件构造只做 `self.locations = {}`，无任何 SetUp 前置，
    --       形态上就是「引擎级默认组件」）。
    --
    --   实测症状（300 抽样里 2 个）：
    --       `brains/caveventmitebrain.lua:81`
    --         self.inst.components.knownlocations:RememberLocation("home", ...)
    --       而 `prefabs/cave_vent_mite.lua` **没有** add 它
    --       ⇒ `attempt to index field 'knownlocations' (a nil value)`
    --       同型：`brains/alterguardian_phase2brain.lua:44`
    --
    --   这里只**读**类并实例化，失败不阻断（记进缺口清单）。
    do
        local cls = Core.LoadRealComponent("knownlocations")
        if cls ~= nil then
            local okc, c = pcall(cls, inst)
            if okc and c ~= nil then
                inst.components.knownlocations = c
                inst.lower_components_shadow = inst.lower_components_shadow or {}
                inst.lower_components_shadow.knownlocations = true
            end
        end
    end

    -- ★ inst.Network 惰性可用：age.lua:5 等组件构造期直接读 inst.Network，
    --   而原版 prefab 是调用 entity:AddNetwork() 之后才有。
    --   做成惰表，两种顺序都能工作。
    inst.Network = setmetatable({}, {
        __index = function() return function() end end,
    })

    -- ★ 默认 sg 对象：真实引擎里 inst.sg 在 SetStateGraph 之前是 nil，
    --   但组件（如 slipperyfeet.lua:118 的 OnNewState）可能在设置状态图
    --   **之前**就被 Start_ 调用并读 inst.sg。
    --   给一个「永远为空集」的默认实例，任何路径访问都不会 nil-index。
    inst.sg = Core.DefaultSG()

    -- ★ inst.Map / inst.Pathfinder：childspawner.lua:506 等会直接读
    --   `self.inst.Map:IsPointNearHole(...)`。真实引擎里它们是世界实体
    --   的组件、但预制体代码习惯通过自己的 inst 访问 —— 这里指向世界代理。
    inst.Map = Core.World and Core.World.Map
    inst.Pathfinder = Core.World and Core.World.Pathfinder

    Core.Spawned[inst._guid] = inst
    return inst
end

-- ---------- 生命周期 ----------
function Core.EntityMeta:IsValid() return not self._removed end
function Core.EntityMeta:IsInLimbo() return self._inlimbo == true end
-- ★★★ C2（2026-10-22）：删除父实体前，必须先把**子实体摘下来**。
--
-- 实测（修复前）：A、B 两棵树，`B.entity:SetParent(A.entity)` 之后 `A:Remove()`，
-- B 的 `_parent` **仍然指向已删除的 A** —— 悬空引用。
-- 之后任何 `inst._parent.components.xxx` 都会去读一个"半死"的对象：
-- 有时是 nil 报错，有时是读到残留字段（**静默错**），取决于 Remove 之后哪些字段还留着。
--
-- 语义选择（与 DST 不同，写在这里免得后人以为是 bug）：
--   DST 的 C++ 侧删父会连带删子（实体树递归销毁）。我们**只摘不删**：
--   子实体保留在原位、`_parent` 置 nil。理由：宿主没有真正的实体树，
--   而"删容器连带删光里面的东西"在编辑器里是灾难（删一个箱子=删掉里面全部战利品）。
--   摘下来至少是**可解释的状态**：东西还在原地，只是不再属于谁。
--   ⇒ 如果将来要做"DESTROY"语义，那是另一个决定，得配自己的判据，不能顺手改这里。
--
-- 为什么不做"子实体计数 > 0 才扫"的优化：那个计数会在 `entity:SetParent(nil)`
-- 与直接赋 nil 两条路径上漂移，而漂移到 0 的后果是**漏摘**（正是这条要修的 bug）。
-- 删除是低频操作（不是每 tick），全表扫一遍更安全。计数只用于观测。
Core.DetachedOnRemove = 0

function Core.EntityMeta:Remove()
    -- 先摘子（必须在 `_removed = true` 之前：摘的过程要读 `child._parent == self`）
    for _, child in pairs(Core.Spawned) do
        if child ~= self and child._parent == self then
            child._parent = nil
            child._parententity = nil
            if child.entity ~= nil and child.entity.SetParent ~= nil then
                pcall(function() child.entity:SetParent(nil) end)
            end
            Core.DetachedOnRemove = Core.DetachedOnRemove + 1
        end
    end
    self._removed = true
    self:PushEvent("onremove")
    Core.Spawned[self._guid] = nil
end
function Core.EntityMeta:RemoveFromScene() self._inlimbo = true end
function Core.EntityMeta:ReturnToScene() self._inlimbo = false end
function Core.EntityMeta:IsAsleep() return self._asleep end
function Core.EntityMeta:SetAsleep(v) self._asleep = v end

-- ---------- 标签 ----------
function Core.EntityMeta:AddTag(tag)
    self._tags[tag] = true
    self:PushEvent("tagadded", tag)
end
function Core.EntityMeta:RemoveTag(tag)
    self._tags[tag] = nil
    self:PushEvent("tagremoved", tag)
end
function Core.EntityMeta:HasTag(tag)
    if tag == nil then return false end
    return self._tags[tag] == true
end
function Core.EntityMeta:HasOneOfTags(...)
    for i = 1, select("#", ...) do
        if self._tags[(select(i, ...))] then return true end
    end
    return false
end
function Core.EntityMeta:HasAllTags(...)
    for i = 1, select("#", ...) do
        if not self._tags[(select(i, ...))] then return false end
    end
    return true
end
function Core.EntityMeta:NumTags()
    local n = 0
    for _ in pairs(self._tags) do n = n + 1 end
    return n
end

-- ---------- 组件 ----------
--- 真实引擎的 AddComponent 会从 components/<name>.lua 加载类并实例化。
--- 宿主优先用注册表，其次尝试加载**真实** DST 组件文件（ fidelity 最高），
--- 两者都没有才记缺口。
local RealComponents = {}   -- name -> 已加载的类（false 表示不存在）
Core.RealComponents = RealComponents

-- ★★ 负缓存**不再永久**：失败只记「原因 + 次数」，之后仍重试。
--
--   为什么要改：原实现每次失败都写 `RealComponents[name] = false`，
--   那一行是**永久**的 —— 只要某组件在**环境还没就绪时**被尝试过一次
--   （Setup 早期、世界组件没装上、netvar 还没声明），
--   它就**永远**返回 nil，后续真正的调用点全都拿不到组件。
--   实测症状：`AddComponent("walkableplatform")` 返回 nil，
--   而**单独**调 `LoadRealComponent("walkableplatform")` 却能拿到类
--   —— 同一个函数、同一份文件，结果取决于**调用顺序**。
Core.RealComponentFails = Core.RealComponentFails or {}

--- 前向声明：定义在下方「组件基类转发」一节。
--- 为什么要提前 —— `LoadRealComponent` 返回前要给它注入基类方法（见下面
--- `inject_component_base(cls, nil)`），而那个函数在 1030 行之后才定义。
local inject_component_base

function Core.LoadRealComponent(name)
    local cached = RealComponents[name]
    -- 只有**成功**的缓存才直接返回；失败的每次都重试
    if cached ~= nil and cached ~= false then return cached end

    local function fail(why)
        local rec = Core.RealComponentFails[name] or { err = nil, count = 0 }
        rec.err = why
        rec.count = rec.count + 1
        Core.RealComponentFails[name] = rec
        RealComponents[name] = false       -- 保留旧字段以兼容其它读点
        return nil
    end

    local path = Core.SourceDir .. "/components/" .. name .. ".lua"
    local f = io.open(path, "r")
    if not f then return fail("文件不存在: " .. path) end
    f:close()

    local chunk, lerr = loadfile(path)
    if not chunk then return fail("语法错误: " .. tostring(lerr):sub(1, 120)) end
    local ok, cls = pcall(chunk, "@" .. path)
    if not ok then return fail("执行抛错: " .. tostring(cls):sub(1, 120)) end
    if type(cls) ~= "table" then
        return fail("未返回类（返回 " .. type(cls) .. "）")
    end
    RealComponents[name] = cls
    Core.RealComponentFails[name] = nil    -- 成功就清掉失败记录

    -- ★★★ 在这里就把「组件基类转发方法」注入类表 —— P41 实测出来的缺口。
    --
    --   原版 `entityscript.lua:157-166` 的 `LoadComponent` 在 `require` 成功后
    --   **立刻**给类表挂上 `WatchWorldState` / `StopWatchingWorldState`
    --   （用 `Components[name].WatchWorldState = ComponentWatchWorldState`）。
    --   宿主把这件事做在了 `AddComponent` 里（`inject_component_base(ctor, self)`），
    --   于是**绕过 AddComponent 的构造路径一个都没有这些方法**。
    --
    --   哪条路径会绕过？—— **世界组件**：`05_bootstrap.lua` 的
    --       local cls = Core.LoadRealComponent(cname)
    --       local okc, inst = pcall(cls, World)
    --   直接 `cls(World)`，不经过 AddComponent。实测：
    --       farming_manager.lua:626 attempt to call method 'WatchWorldState' (a nil value)
    --   （`farming_manager.lua:626` 构造末尾 `self:WatchWorldState("season", ...)`）
    --
    --   注入放这里**比放 AddComponent 更贴原版**：类表只注入一次、与 inst 无关，
    --   也顺带修好所有「直接构造组件类」的路径（14_replica.lua 就是这种）。
    --   幂等：`inject_component_base` 只补 `rawget(cls, name) == nil` 的。
    if type(inject_component_base) == "function" then
        pcall(inject_component_base, cls, nil)
    end
    return cls
end

--- 组件级 replica：真实引擎为每个可复制组件生成镜像对象。
--- ★ 结构**逐字对齐** entityscript.lua:574-576：
---     self.replica = { _ = {}, inst = self }
---     setmetatable(self.replica, replica_mt)
---   · `_` 存放真实的 replica 实例，必须用 rawget/rawset 访问（否则触发
---     __index 钩子 → 无限递归，entityscript.lua:428 的注释专门点出这一点）。
---   · `__index` 走 ValidateReplicaComponent 做惰性授权校验，
---     真正的分发/加载逻辑在 host/14_replica.lua（对齐 entityreplica.lua）。
--- ⚠️ 原先这里是一个「问什么给什么」的哑桩（__index 恒返回 function(){}），
---   它会让 `inst.replica.combat:IsValidTarget(...)` 返回 nil，
---   从而让 combat.lua:578 的目标校验恒假 —— 生物一个都追不起来。
local replica_mt = {
    __index = function(t, k)
        if k == "_" or k == "inst" then
            return rawget(t, k)
        end
        local validate = rawget(t, "inst").ValidateReplicaComponent
        if type(validate) == "function" then
            return validate(rawget(t, "inst"), k, rawget(rawget(t, "_"), k))
        end
        return rawget(rawget(t, "_"), k)
    end,
}
Core.ReplicaMeta = replica_mt

make_replica = function(inst)
    local r = { _ = {}, inst = inst }
    setmetatable(r, replica_mt)
    return r
end

--- 真实引擎的组件基类提供一组「转发到 inst」的方法。
--- 关键：这些方法在**构造函数体内就会被调用**
--- （如 burnable.lua:13 的 self.inst:AddOrRemoveTag、
---   werebeast.lua:68 的 self:WatchWorldState），
--- 所以必须注入到**类表**上，实例化时才能解析到。
local COMPONENT_BASE_METHODS = {
    WatchWorldState = function(inst, comp, state, fn)
        inst:WatchWorldState(state, function(i, data) fn(comp, data) end)
    end,
    StopWatchingWorldState = function(inst, comp, state)
        inst:StopWatchingWorldState(state)
    end,
    ListenForEvent = function(inst, comp, evt, fn)
        inst:ListenForEvent(evt, function(i, data) fn(comp, data) end)
    end,
    PushEvent = function(inst, comp, evt, data)
        inst:PushEvent(evt, data)
    end,
}

--- 在类表上注入基类转发（只注入类本身没有的）
---
--- ★ `inst` 是「兜底宿主」：优先用 `self.inst`（与原版 `ComponentWatchWorldState`
---   完全一致 —— 它写的是 `EntityWatchWorldState(self.inst, var, fn)`），
---   只有组件实例自己没设 `self.inst` 时才回退到类级捕获的那个。
---   为什么要这层兜底：`AddComponent` 里 `c.inst = c.inst or self` 是在**构造之后**
---   才补的（:1129），构造期若某组件还没设 `self.inst` 就去调这些方法，
---   单用 `self.inst` 会拿到 nil —— 而烧死在闭包里的 `inst` 一定可用。
inject_component_base = function(cls, inst)
    if type(cls) ~= "table" then return end
    for name, fn in pairs(COMPONENT_BASE_METHODS) do
        if rawget(cls, name) == nil then
            cls[name] = function(comp, ...)
                return fn(comp.inst or inst, comp, ...)
            end
        end
    end
end

--- 实体级的 AddOrRemoveTag —— 真实引擎 EntityScript 提供
function Core.EntityMeta:AddOrRemoveTag(tag, condition)
    if condition then self:AddTag(tag) else self:RemoveTag(tag) end
end

function Core.EntityMeta:AddComponent(name)
    -- ★★ 重复添加检测（entityscript.lua:610-624）
    --
    -- 真实引擎开头就是这段：若影子表里已有这个组件，**返回旧实例**，绝不新建。
    -- 重复 AddComponent 会造出**两个活着的实例**：两个都进组件更新泵
    -- ⇒ 每 tick 各跑一次 OnUpdate；若状态存在 netvar 里（clock 就是），
    -- 两者**共享同一组 netvar** 却各自维护局部变量 ⇒ 互相覆盖。
    -- 实测症状：world.lua 里不小心 AddComponent("clock") 两次 →
    --   `phasechanged` 在同一秒里来回跳
    --   （240s→dusk 240s→day 300s→dusk 420s→night 420s→dusk …）
    -- 这类 bug 极难从表象定位，所以必须按原版把闸门装上。
    if self.lower_components_shadow ~= nil then
        local lower_name = string.lower(name)
        if self.lower_components_shadow[lower_name] ~= nil then
            local existing = self.components[lower_name]
            if existing == nil then
                for k, v in pairs(self.components) do
                    if string.lower(k) == lower_name then existing = v break end
                end
            end
            if existing ~= nil then
                Core.DuplicateAdds = Core.DuplicateAdds or {}
                Core.DuplicateAdds[name] = (Core.DuplicateAdds[name] or 0) + 1
                return existing
            end
        end
    end

    local ctor = Core.ComponentRegistry[name]

    -- 回退：加载真实 DST 组件
    if not ctor then
        local cls = Core.LoadRealComponent(name)
        if cls then ctor = cls end
    end

    if not ctor then
        Core.NoteGap("component:" .. name, "AddComponent")
        return nil
    end

    -- 确保 replica 存在（health.lua:10 等会立刻访问）
    if self.replica == nil then self.replica = make_replica(self) end

    -- ★ 在实例化前注入基类转发
    inject_component_base(ctor, self)

    -- ★★ 真实引擎在**构造组件之前**就申请副本，顺序不能反：
    --     entityscript.lua:626-633
    --         local cmp = LoadComponent(name)
    --         self:ReplicateComponent(name)   -- ← 先建 replica
    --         local loadedcmp = cmp(self)     -- ← 再构造服务端组件
    --     self.components[name] = loadedcmp
    --   为什么必须先建 replica —— 服务端组件的**属性 setter 会把值推进 replica**：
    --     components/combat.lua:4-6
    --         local function onattackrange(self, attackrange)
    --             self.inst.replica.combat:SetAttackRange(attackrange)
    --         end
    --   而 combat 组件在构造期就写 `self.attackrange = 3` → 触发 setter。
    --   若 replica 尚不存在，`replica.combat:SetAttackRange` 就是「索引 nil」→
    --   整个组件构造失败（实测报错：combat.lua:5: attempt to index field 'combat'）。
    --   ★ 授权与否由 entityreplica.lua 的 19 项白名单 + ismastersim 把关。
    if type(self.ReplicateComponent) == "function" then
        local okR = pcall(self.ReplicateComponent, self, name)
        if not okR then
            Core.NoteGap("ReplicateComponent:" .. name, "AddComponent")
        end
    end

    local ok, c = pcall(ctor, self)
    if not ok then
        Core.NoteGap("component:" .. name .. " (构造失败: " .. tostring(c) .. ")",
                     "AddComponent")
        return nil
    end
    if c == nil then
        Core.NoteGap("component:" .. name .. " (返回nil)", "AddComponent")
        return nil
    end
    c.inst = c.inst or self
    self._components[name] = c
    self.components[name] = c

    -- ★★★ 补上影子表登记 —— 原版 `entityscript.lua:635`：
    --         self.lower_components_shadow[lower_name] = true
    --
    --   宿主**一直没写这一句**（只在 knownlocations 那处硬编码了一条）
    --   ⇒ 上面那道闸门（1058 行）对**所有普通组件都是死的**：
    --        `AddComponent("health")` 两次会造出**两个活着的实例**，
    --        两个都进更新泵、都跑 OnUpdate，若状态在 netvar 里就互相覆盖。
    --        这正是这条修复当初要防的 bug（clock 相位来回跳）。
    --
    --   ★★ 为什么能藏这么久：`tools/audit_fixes.py` 里那条检查只验
    --      「文件里有 `lower_components_shadow` 这个串」——**串在≠闸门有效**。
    --      抓到它的是一条**反向判据**断言
    --      （tests.lua T21「重复 AddComponent 必须返回同一实例」）。
    --      ⇒ 教训：审计条目要指向**行为**，不能指向**字符串**。
    self.lower_components_shadow = self.lower_components_shadow or {}
    self.lower_components_shadow[string.lower(name)] = true

    self:PushEvent("componentadded", { name = name, comp = c })
    return c
end
function Core.EntityMeta:RemoveComponent(name)
    local c = self._components[name]
    if c and c.OnRemoveFromEntity then c:OnRemoveFromEntity() end
    self._components[name] = nil
    self.components[name] = nil
    -- ★ 与 AddComponent 成对（原版 entityscript.lua:654）——
    --   不清掉影子标记，移除后再添加就会被闸门误判成「已存在」而返回 nil。
    if self.lower_components_shadow ~= nil then
        self.lower_components_shadow[string.lower(name)] = nil
    end
end
function Core.EntityMeta:HasComponent(name) return self._components[name] ~= nil end
function Core.EntityMeta:GetComponent(name) return self._components[name] end

-- ---------- 事件 ----------
function Core.EntityMeta:ListenForEvent(event, fn, source)
    self._listeners[event] = self._listeners[event] or {}
    table.insert(self._listeners[event], { fn = fn, source = source })
end
function Core.EntityMeta:RemoveEventCallback(event, fn, source)
    local list = self._listeners[event]
    if not list then return end
    for i = #list, 1, -1 do
        local e = list[i]
        if e.fn == fn and (source == nil or e.source == source) then
            table.remove(list, i)
        end
    end
end
function Core.EntityMeta:PushEvent(event, data)
    -- 1) 事件总线：立即派发给 ListenForEvent 注册的回调
    --    （与 stategraph 的「刻末批处理」是两条不同时间线，bug-patterns H3）
    local list = self._listeners[event]
    if list then
        self._eventcount = self._eventcount + 1
        -- 拷贝一份再遍历：回调里可能增删监听（bug-patterns A6）
        local snapshot = {}
        for i = 1, #list do snapshot[i] = list[i] end
        for _, e in ipairs(snapshot) do
            if e.source == nil or e.source:IsValid() then
                e.fn(self, data)
            end
        end
    end

    -- 2) ★ 路由到状态图（entityscript.lua:1304-1308）
    --    IsListeningForEvent + SGManager:OnPushEvent 会把休眠的实例唤醒，
    --    然后事件进 bufferedevents，等刻末 UpdateEvents 统一处理。
    --    少了这段，状态图永远收不到事件（实测：推 onattack 无反应）。
    local sg = rawget(self, "sg")
    if type(sg) == "table" and type(sg.IsListeningForEvent) == "function"
        and type(sg.PushEvent) == "function" then
        local listening = pcall(sg.IsListeningForEvent, sg, event)
        if listening then
            local SM = _G.SGManager
            local woke = true
            if SM and type(SM.OnPushEvent) == "function" then
                local ok, r = pcall(SM.OnPushEvent, SM, sg)
                if not ok then woke = false
                else woke = r ~= false end
            end
            if woke then
                pcall(sg.PushEvent, sg, event, data)
            end
        end
    end
end
function Core.EntityMeta:WatchWorldState(state, fn)
    self._worldwatchers = self._worldwatchers or {}
    self._worldwatchers[state] = fn
    if Core.World then
        Core.World.Watch(self, state, fn)
    end
end
function Core.EntityMeta:StopWatchingWorldState(state)
    if self._worldwatchers then
        self._worldwatchers[state] = nil
        if Core.World then Core.World.StopWatch(self, state) end
    end
end

-- ---------- 任务 ----------
function Core.EntityMeta:DoTaskInTime(delay, fn, ...)
    self._taskid = self._taskid + 1
    local id = self._taskid
    local t = {
        id = id, fn = fn, args = { ... },
        time = (Core.World and Core.World.time or 0) + delay,
        delay = delay, periodic = false,
    }
    self._tasks[id] = t
    return setmetatable({}, {
        __index = {
            Cancel = function() self._tasks[id] = nil end,
            NextTime = function() return t.time end,
        },
    })
end
function Core.EntityMeta:DoPeriodicTask(period, fn, delay, ...)
    self._taskid = self._taskid + 1
    local id = self._taskid
    local t = {
        id = id, fn = fn, args = { ... },
        time = (Core.World and Core.World.time or 0) + (delay or period),
        delay = period, periodic = true,
    }
    self._tasks[id] = t
    return setmetatable({}, {
        __index = {
            Cancel = function() self._tasks[id] = nil end,
            NextTime = function() return t.time end,
        },
    })
end
-- ★ 真实契约（entityscript.lua:1069）就是一行：
--       function EntityScript:StartThread(fn) return StartThread(fn, self.GUID) end
--   而全局 `StartThread` 由**真实 scheduler.lua:387** 提供，它把协程登记进
--   调度器，于是线程内部的 `Sleep(t)` / `Yield()` / `Hibernate()` 才有语义。
--
--   宿主早前把它实现成「同步直接调用 fn(self)」——看着等价，实际是错的：
--   · 线程里的 `Sleep(t)` 会走 scheduler.lua:356 的 `GetCurrentScheduler()`，
--     拿不到登记过的调度器 → `schedule` 为 nil → 索引 nil 崩（实测
--     talker.lua:222 ← wisecracker.lua:103 在生物第一次说话时崩掉整个仿真）
--   · 线程也就没有「跨 tick 暂停后继续」的能力
--   所以这里改回**委托真实调度器**，宿主的 Sim.Step 负责每 tick 调 RunScheduler。
--   真实调度器不可用时（极少数裁剪场景）退化为同步调用，并如实记录。
function Core.EntityMeta:StartThread(fn, id)
    if type(_G.StartThread) == "function" then
        local ok, res = pcall(_G.StartThread, fn, id or self.GUID)
        if ok then return res end
    end
    Core.NoteStub("EntityScript:StartThread", "sync-fallback")
    return fn(self)
end
function Core.EntityMeta:StartUpdatingComponent(c) self._updating = c end
function Core.EntityMeta:StopUpdatingComponent(c) self._updating = nil end

-- ---------- 表现层查询 ----------
--- ★ GetPosition 必须返回 **Point 对象**，不是三个数字。
--   原版 entityscript.lua:1356 `return Point(self.Transform:GetWorldPosition())`。
--   很多组件把结果当向量用：
--     · knownlocations.lua:64 读 `pos.x / pos.y / pos.z`
--     · alterguardian_phase1brain.lua:79 `RememberLocation("spawnpoint", self.inst:GetPosition())`
--   早前返回 x,y,z 三值，导致 pos 变成第一个数字，
--   报 "attempt to index local 'pos' (a number value)"。
function Core.EntityMeta:GetPosition()
    local x, y, z = 0, 0, 0
    if self.Transform then
        x, y, z = self.Transform:GetWorldPosition()
    end
    local G = require("host.03_globals")
    return G.Vector3(x or 0, y or 0, z or 0)
end
-- ★ 警告：GetPosition 返回的是**单个 Point**（向量对象），不是三个数字。
--   早前它返回 x,y,z 三值，这段代码写成 `local x1,y1,z1 = self:GetPosition()`
--   是对的；改成返回 Point 之后，y1/z1 变成 nil，
--   于是 `x1 - x2` 报 "attempt to perform arithmetic on local 'y1'"（实测撞墙探针崩在这）。
--   GetAngleToPoint 也踩过同一个坑（见 06_entityscript.lua）。
--   凡是取位置的代码，一律走 `.x / .y / .z` 或 `Transform:GetWorldPosition()`。
function Core.EntityMeta:GetDistanceSqToInst(other)
    local p1 = self:GetPosition()
    local p2 = other:GetPosition()
    local dx, dy, dz = p1.x - p2.x, p1.y - p2.y, p1.z - p2.z
    return dx * dx + dy * dy + dz * dz
end
function Core.EntityMeta:GetDistanceToInst(other)
    return math.sqrt(self:GetDistanceSqToInst(other))
end
function Core.EntityMeta:IsLightGreaterThan(v)
    -- 真实引擎查世界光照；宿主返回 false，让调用方走「自己有光源」分支
    return false
end
-- ★ entityscript.lua:783 / :789 的真实实现只是 `self.entity:Hide(false)` /
--   `self.entity:Show(false)` —— 那个 false 参数是「**不隐藏阴影**」。
--   旧实现只转发给 AnimState，实体本身（碰撞盒、光源、小地图图标等）没被隐藏，
--   与原版不符。调用点：fishable.lua:71（收鱼）、blinkstaff.lua:84（瞬移施法者）。
function Core.EntityMeta:Show() if self.AnimState then self.AnimState:Show() end end
function Core.EntityMeta:Hide() if self.AnimState then self.AnimState:Hide() end end
function Core.EntityMeta:SetMaterial(m) self._material = m end
function Core.EntityMeta:GetMaterial() return self._material end
function Core.EntityMeta:GetDisplayName() return self._name end
function Core.EntityMeta:GetBasicDisplayName() return self._name end

--=========================================================================
-- 组件注册表
--=========================================================================
Core.ComponentRegistry = {}

function Core.RegisterComponent(name, ctor)
    Core.ComponentRegistry[name] = ctor
end

--=========================================================================
-- 预制体
--=========================================================================

--- 真实引擎的 Prefab() 只登记「名字→构造函数」映射
--- 世界根预制体名集合（由 MakeWorld / MakeWorldNetwork 注册时自动登记）
--   ★ 见下面 Core.Prefab 里的**调用者反射**说明。
Core.WorldRootPrefabs = Core.WorldRootPrefabs or {}

function Core.Prefab(name, fn, assets, prefabs)
    Core.Prefabs[name] = { name = name, fn = fn, assets = assets, prefabs = prefabs }

    -- ★★ 自动识别「世界根预制体」—— 用**调用嵌套**，不用反射也不用名字清单。
    --
    --   为什么需要：`prefabs/world.lua:418` 里有一条 **Lua 层**的闸门
    --       if TheWorld ~= nil then
    --           print("You cannot spawn multiple worlds!")
    --           return
    --       end
    --   ⇒ spawn 世界根预制体**只是打印一句就返回 nil**，不抛错。
    --     所以「用错误文本判断」这条路走不通（错误是 nil）。
    --
    --   ★ 为什么不用 `debug.getinfo(2,"n").name`：
    --     在本运行时里**恒为 nil** —— 连 `_G.Prefab(n, fn)` 这种最普通的全局调用
    --     都拿不到名字（实测）。与 `nparams` 恒 nil 是同一类问题。
    --   ★ 为什么不用名字清单：本轮已**三次**被「手工列清单」坑到
    --     （sg 方法表 / prefabskin 全局表 / 渲染管理器），而且以后新增世界类型会漏。
    --
    --   ⇒ `Loader.WrapWorldMakers` 把 `MakeWorld` / `MakeWorldNetwork` 包一层，
    --     它们执行期间置 `Core._InWorldMaker`；本函数看标记登记。
    --     这两个函数是所有世界根的**唯一构造入口**，且它们内部调 `Prefab`
    --     在同一调用栈内 ⇒ 嵌套法没有漏判余地。
    if Core._InWorldMaker ~= nil then
        Core.WorldRootPrefabs[name] = Core._InWorldMaker
    end

    return name
end

function Core.CreateEntity(name)
    return Core.NewEntity(name)
end

--- SpawnPrefab —— 真实引擎的全局函数，3066 处调用
function Core.SpawnPrefab(name, skin, ...)
    -- ★ 防御：原版有代码把非字符串传进来（实测 firepit 依赖链）。
    --   不做保护会在缺口信息的字符串拼接上直接崩，掩盖真实原因。
    if type(name) ~= "string" then
        Core.NoteGap("prefab:<" .. type(name) .. ">", "SpawnPrefab-type-error")
        return nil
    end
    local def = Core.Prefabs[name]
    if not def then
        -- ★★ 按需加载 prefab 文件（对齐真实引擎）
        --
        --   真实 DST 在启动时把 prefablist.lua 里的**全部**预制体注册好，
        --   所以 `SpawnPrefab(任何名字)` 都能用。宿主为了省内存改成
        --   「按需加载」，但**只在显式 LoadPrefabFile 时才加载**——
        --   于是 `SpawnPrefab("beefaloherd")` 这类由数据驱动的生成
        --   （herdmember.lua:60 `SpawnPrefab(self.herdprefab)`，
        --     herdprefab 默认 "beefaloherd"）就找不到定义 → 记成真缺口 + 返 nil。
        --
        --   这里补上「查不到就现加载」：与 14_replica.lua 的 ensure_classified
        --   同一套路。用 Bootstrap.LoadPrefabFile（宿主自己的加载器，
        --   带依赖递归），宿主启动时把自己的引用挂在 Core 上。
        local loader = rawget(Core, "_prefab_loader")
        if loader ~= nil then
            local ok = loader(name)
            if ok then def = Core.Prefabs[name] end
        end
    end
    if not def then
        Core.NoteGap("prefab:" .. name, "SpawnPrefab")
        return nil
    end
    local inst = def.fn()
    if inst == nil then return nil end
    -- ★ prefab 字段兜底：有的 prefab 用工厂函数（如 evergreens.lua 的 tree()）
    --   内部直接 CreateEntity() 建实体，从不设 inst.prefab ——
    --   但后面的代码会 `inst.prefab.."_tall"`（evergreens.lua:861），
    --   nil 拼接直接崩。真实引擎是 Prefab 类在构造时把 name 写进实体，
    --   宿主的注册函数只存了 name，所以这里补设（nil 才设，不覆盖已有的）。
    if inst.prefab == nil then
        inst.prefab = name
    end
    return inst
end

return Core
