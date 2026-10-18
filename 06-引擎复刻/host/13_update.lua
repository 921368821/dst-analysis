--[[
==============================================================================
 13_update.lua —— 组件 / Brain 更新泵（把「静止的世界」变成「会动的世界」）

 为什么需要它
   宿主此前只驱动了两条时间线：实体任务表（DoTaskInTime / DoPeriodicTask）
   和状态图（SGManager:Update）。**组件的 OnUpdate 从来没跑过**，
   `StartUpdatingComponent` 只是把组件塞进 `self._updating` 就算了事。

   后果是致命的，而且完全静默：
     · `locomotor:OnUpdate` 是「朝目标走 + 判断到点」的地方 —— 不跑 ⇒ 永不移动
     · `brain` 的 BehaviourTree 是「做决策」的地方 —— 不跑 ⇒ 永不思考
     两者都不报错，只是世界静止不动。

 DST 的真实更新泵（update.lua:224 `Update(dt)`）
     1. RunScheduler(i)                              —— 调度器
     2. StaticComponentUpdates                       —— 静态组件
     3. for ent in UpdatingEnts: for cmp in ent.updatecomponents: cmp:OnUpdate(dt)
     4. per tick: SGManager:Update(i); BrainManager:Update(i)

   宿主已把 1/4 的一部分放在 02_sim.Sim.Step 里，这里补 3 与 BrainManager。

 Brain 生命周期（原来也是错的）
   宿主原实现 `SetBrain = function(self, b) self.brain = b end` —— 把
   **类**当成**实例**存了起来。DST 的真实契约（entityscript.lua:1583）是：
       brainfn 是一个**工厂函数**（require("brains/pigbrain") 得到的 Class）
       → `self.brain = brainfn()` 造实例 → `brain.inst = self`
       → `brain:_Start_Internal()` 把自己登记进 BrainManager
   不造实例 ⇒ brain:OnUpdate 根本不会存在 ⇒ 生物永不决策。
   这里按原版逐行对齐重写（含 _braindisabled / _brainstopped 两个开关）。
==============================================================================
]]

local Core = require("host.01_core")

local M = {}

--=========================================================================
-- 更新泵状态
--=========================================================================
M.UpdatingEnts = {}     -- inst -> updatecomponents 表
M.ComponentTicks = 0
M.ComponentErrors = {}
M.BrainTicks = 0
M.BrainErrors = 0

--- 给一个实体表注入「真实」的组件更新登记语义
local function install_component_updating(meta)
    meta.StartUpdatingComponent = function(self, cmp)
        if cmp == nil then return end
        local uc = rawget(self, "updatecomponents")
        if uc == nil then
            uc = {}
            rawset(self, "updatecomponents", uc)
        end
        uc[cmp] = true
        M.UpdatingEnts[self] = uc
    end

    meta.StopUpdatingComponent = function(self, cmp)
        local uc = rawget(self, "updatecomponents")
        if uc == nil then return end
        if cmp ~= nil then uc[cmp] = nil end
        if next(uc) == nil then
            M.UpdatingEnts[self] = nil
        end
    end

    -- update.lua:279 用 `v:StopUpdatingComponent_Deferred(k)`。
    -- 宿主没有「刻末延迟」这一步，直接等价执行。
    meta.StopUpdatingComponent_Deferred = meta.StopUpdatingComponent
end

--=========================================================================
-- Brain 生命周期（逐行对齐 entityscript.lua:1583 / 1609 / 1624 / 1640）
--=========================================================================
local function install_brain_lifecycle(meta)
    meta.SetBrain = function(self, brainfn)
        self.brainfn = brainfn
        -- -sleepstatepending 检查：防止在构造期（IsAsleep 恒假时）就启动大脑
        self._braindisabled = brainfn ~= nil
            and (self.sleepstatepending or self:IsInLimbo() or self:IsAsleep())
            or nil
        if self.brain ~= nil then
            self.brain:_Stop_Internal()
        end
        self.brain = (brainfn ~= nil and not self._braindisabled) and brainfn() or nil
        if self.brain ~= nil then
            self.brain.inst = self
            if not self._brainstopped then
                self.brain:_Start_Internal()
            end
        end
    end

    meta._DisableBrain_Internal = function(self)
        if self.brainfn == nil then return end
        self._braindisabled = true
        if self.brain ~= nil then
            self.brain:_Stop_Internal()
            self.brain = nil
        end
    end

    meta._EnableBrain_Internal = function(self)
        if not self._braindisabled then return end
        self._braindisabled = nil
        if self.brainfn == nil then return end
        self.brain = self.brainfn()
        if self.brain ~= nil then
            self.brain.inst = self
            if not self._brainstopped then
                self.brain:_Start_Internal()
            end
        end
    end

    meta.StopBrain = function(self, reason)
        reason = reason or ""
        if self._brainstopped then
            self._brainstopped[reason] = true
        else
            self._brainstopped = { [reason] = true }
            if self.brain ~= nil then
                self.brain:_Stop_Internal()
            end
        end
    end

    meta.RestartBrain = function(self, reason)
        reason = reason or ""
        if self._brainstopped ~= nil and self._brainstopped[reason] then
            self._brainstopped[reason] = nil
            if next(self._brainstopped) == nil then
                self._brainstopped = nil
                if self.brain ~= nil then
                    self.brain:_Start_Internal()
                end
            end
        end
    end

    -- 睡眠/醒来时脑的启停（DST 里由 OnEntitySleep / OnEntityWake 调用）
    meta._StartBrainOnWake = function(self)
        if self.brainfn ~= nil and not self._braindisabled and self.brain == nil then
            self.brain = self.brainfn()
            if self.brain ~= nil then
                self.brain.inst = self
                if not self._brainstopped then self.brain:_Start_Internal() end
            end
        end
    end
end

--=========================================================================
-- 每 tick 泵
--=========================================================================
--- 3) 组件 OnUpdate
function M.StepComponents(dt)
    if next(M.UpdatingEnts) == nil then return 0 end
    -- 先取快照：OnUpdate 里可能 StopUpdatingComponent / Remove 实体
    local snapshot = {}
    for inst in pairs(M.UpdatingEnts) do
        snapshot[#snapshot + 1] = inst
    end
    local n = 0
    local n_skipped = 0
    for _, inst in ipairs(snapshot) do
        -- ★★ 休眠的实体**不跑组件更新**。
        --   真实引擎的做法就是把休眠实体从 UpdatingEnts 里摘掉
        --   （entityscript.lua:439 的 StartUpdatingComponent 只在 awake 时才被调用，
        --    而 C++ 在实体入睡时会把它移出更新表）。
        --   宿主此前**完全没查 IsAsleep** —— `_asleep` 字段存在、`IsAsleep()` 也有，
        --   但没有任何一处读它，于是它是「声明了却没生效」的机制。
        --   这也是加了 70 个静态景物后帧率从 1285 掉到 711 的主因之一。
        if inst:IsValid() and not inst:IsInLimbo() and not inst:IsAsleep() then
            local uc = M.UpdatingEnts[inst]
            if uc ~= nil and next(uc) ~= nil then
                local list = {}
                for cmp in pairs(uc) do list[#list + 1] = cmp end
                for _, cmp in ipairs(list) do
                    if uc[cmp] and type(cmp.OnUpdate) == "function" then
                        local ok, err = pcall(cmp.OnUpdate, cmp, dt)
                        n = n + 1
                        if not ok then
                            local key = tostring(err):sub(1, 220)
                            M.ComponentErrors[key] = (M.ComponentErrors[key] or 0) + 1
                            Core.NoteStub("component.OnUpdate", "update-pump")
                        end
                    end
                end
            end
        elseif inst:IsValid() then
            n_skipped = n_skipped + 1
        end
    end
    M.ComponentTicks = M.ComponentTicks + n
    M.LastSkipped = n_skipped
    return n
end

--=========================================================================
-- ★★ 实体休眠 / 唤醒（真实引擎的「远离玩家就睡着」）
--=========================================================================
-- 真实机制（三处配合）：
--   1. `entityscript.lua:1465`
--          function EntityScript:IsAsleep() return not self.entity:IsAwake() end
--      —— `IsAsleep` 只是读 C++ Entity 层的 awake 标志。
--   2. C++ 侧按「玩家距离」把实体从更新表里摘掉，并推
--      `inst:PushEvent("entitysleep")` / `"entitywake"`
--      （组件侧几十个 OnEntitySleep / OnEntityWake 就是这么触发的，
--        如 boattrail.lua:25-26、blowinwind.lua:33-37）。
--   3. `brain.lua:137` 的 BrainWrangler 更新时查 `not k.inst:IsAsleep()`。
--
-- 宿主此前缺第 1 环的**写入方**：`_asleep` 字段有、`IsAsleep()` 也有，
-- 但没有任何一处会把它设成 true —— 于是这个机制「声明了却没生效」，
-- 远处的景物和生物每 tick 照跑全部组件。
--
-- ★ 距离用「平方距离」比较，避免 90 个实体 × sqrt 的无谓开销。
-- ★ 唤醒要重启脑与状态图（DST 的 `_EnableBrain_Internal` / `sg:Start(false)`）：
--   否则实体醒了却不会动，比不睡更糟。
function M.UpdateSleepStates(cx, cz, sleep_radius, wake_radius)
    local s2 = (sleep_radius or 40) ^ 2
    local w2 = (wake_radius or 32) ^ 2
    local ns, nw = 0, 0
    for _, inst in pairs(Core.Spawned) do
        local tr = rawget(inst, "Transform")
        if tr ~= nil then
            local x, _, z = tr:GetWorldPosition()
            local dx, dz = (x or 0) - cx, (z or 0) - cz
            local d2 = dx * dx + dz * dz
            if d2 > s2 and not inst:IsAsleep() then
                inst._asleep = true
                ns = ns + 1
                pcall(inst.PushEvent, inst, "entitysleep")
                -- 脑停掉：BrainWrangler 本来就不跑 asleep 的，这里显式停更彻底
                -- 宿主已有的方法名是 `_DisableBrain_Internal`（对齐 entityscript 的下划线风格）
                if inst.brainfn ~= nil and inst._DisableBrain_Internal then
                    pcall(inst._DisableBrain_Internal, inst)
                end
            elseif d2 < w2 and inst:IsAsleep() then
                inst._asleep = false
                nw = nw + 1
                pcall(inst.PushEvent, inst, "entitywake")
                -- 醒来：把脑和状态图重新拉起来
                if inst._StartBrainOnWake then pcall(inst._StartBrainOnWake, inst) end
                if inst.sg ~= nil and inst.sg.Start then
                    pcall(inst.sg.Start, inst.sg, false)
                end
            end
        end
    end
    M.LastSlept, M.LastWoke = ns, nw
    return ns, nw
end

--- 4b) BrainManager（真实 brain.lua 的 BrainWrangler）
function M.StepBrains(tick)
    local BM = _G.BrainManager
    if BM == nil or type(BM.Update) ~= "function" then return false end
    local ok, err = pcall(BM.Update, BM, tick)
    if not ok then
        M.BrainErrors = M.BrainErrors + 1
        if M.BrainErrors <= 3 then
            M.LastBrainError = tostring(err):sub(1, 150)
        end
        Core.NoteStub("BrainManager.Update", "update-pump")
        return false
    end
    M.BrainTicks = M.BrainTicks + 1
    return true
end

--- 诊断：当前有多少实体在更新、多少脑在跑
function M.Stats()
    local ncomp = 0
    for _, uc in pairs(M.UpdatingEnts) do
        for _ in pairs(uc) do ncomp = ncomp + 1 end
    end
    local BM = _G.BrainManager
    local nupd, nhiber, nsleep = 0, 0, 0
    if BM then
        if BM.updaters then for _ in pairs(BM.updaters) do nupd = nupd + 1 end end
        if BM.hibernaters then for _ in pairs(BM.hibernaters) do nhiber = nhiber + 1 end end
        if BM.tickwaiters then
            for _, w in pairs(BM.tickwaiters) do
                for _ in pairs(w) do nsleep = nsleep + 1 end
            end
        end
    end
    return {
        entities = (function() local n = 0 for _ in pairs(M.UpdatingEnts) do n = n + 1 end return n end)(),
        components = ncomp,
        brains_updating = nupd,
        brains_hibernating = nhiber,
        brains_sleeping = nsleep,
        component_ticks = M.ComponentTicks,
        brain_ticks = M.BrainTicks,
        brain_errors = M.BrainErrors,
        last_brain_error = M.LastBrainError,
    }
end

--=========================================================================
-- 安装
--=========================================================================
function M.Install(meta)
    install_component_updating(meta)
    install_brain_lifecycle(meta)

    -- brain.lua 用 `GetTick()`（brain.lua:68 的 tickwaiters 分桶）。
    -- 宿主 02_sim 只定义了 GetSchedulerTick，这里补上。
    if _G.GetTick == nil then
        _G.GetTick = function() return _G.TheSim and _G.TheSim:GetTick() or 0 end
    end
    M.Installed = true
    return M
end

return M
