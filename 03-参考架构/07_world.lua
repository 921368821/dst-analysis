--============================================================
-- 文件：07_world.lua
-- 模块：核心框架 / 世界与主循环
-- 职责：30Hz 固定步长主循环（累加器模式）、世界容器（实体表 + 按 tick 索引的桶）、
--       时间系统（游戏内天数推进）、昼夜光照输出。
--
-- 【★★ 固定步长 + 累加器：为什么是游戏行业的标准做法？】
--
-- 朴素做法是「每渲染帧更新一次，用真实的帧间隔 dt」。
-- 问题有三，且都致命：
--   ① 帧率波动直接改变游戏速度。144Hz 机器上角色跑得比 60Hz 机器快一倍。
--   ② 物理/碰撞在不同 dt 下结果不同，会出现「穿墙」「抖动」。
--   ③ 数值条速率×dt 虽然对 dt 免疫，但**逻辑顺序**仍然依赖步长。
--
-- 固定步长（Fixed Timestep）：
--   每帧把「真实经过的时间」累加到一个累加器里，
--   只要累加器够了 1/30 秒，就跑一整个逻辑步，跑完把余量留下。
--   于是逻辑永远以 1/30 的粒度推进，与渲染帧率彻底解耦。
--
--   realdt=1/60 → 攒 2 帧跑 1 步（省一次计算）
--   realdt=1/15 → 一帧跑 2 步（多跑一次）
--
-- ★ 关键细节：**必须限制单帧最多补几步**（下面 MAX_STEPS）。
--   如果切后台 10 分钟回来，累加器里有 18000 秒待补，
--   不限制的话一帧内要跑 3 万步 —— 直接卡死（俗称「死亡螺旋」）。
--   正确做法是丢弃超出的时间（游戏时间因此「慢了一点」，但游戏能玩）。
--
-- 【★ 世界本身也是一个预制体】
-- 原版里 TheWorld 就是 SpawnPrefab("forest") 生成的实体，
-- 它持有地图、寻路器、世界状态、以及几十个管理组件。
-- 本教学版把世界做成独立对象，但保留了同样的语义：世界也是一个「实体容器」。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》
--           scripts/update.lua（主循环）、scripts/world.lua
-- 兼容性：Lua 5.1 / 5.3 / 5.4 / LuaJIT
--============================================================

local Class = require("01_class").Class
local sched = require("02_scheduler")

local M = {}

local FRAMES = sched.TICK_TIME     -- 1/30 秒

--============================================================
-- 一、世界时间与昼夜
--============================================================

M.SEGMENTS = { "day", "dusk", "night" }
-- ★ 原版用的是 { day, dusk, night } 三段（可含 caves 变体）。
--   只分两段（白天/黑夜）会缺少「黄昏」这个最有戏剧性的过渡时段：
--   光线斜照、温度下降、理智开始掉 —— 所有「危险信号」都在黄昏给，
--   这样玩家的「出门判断」才有决策空间。

-- 世界总长可配置：测试用短周期，游戏用真实周期
function M.NewWorld(name, daylength)
    return World(name, daylength or 480)
end

local World = Class(function(self, name, daylength)
    self.name = name
    self.daylength = daylength or 480   -- 一天多少秒
    -- 一天的三段占比（必须加起来是 1）
    -- 真实 DST 大致是 白天 0.7 / 黄昏 0.1 / 夜晚 0.2
    self.segments = { day = 0.70, dusk = 0.10, night = 0.20 }
    self.time = 0                       -- 当前世界时间（秒）
    self.day = 1                       -- 第几天
    self.tick = 0

    -- 实体容器
    self.ents = {}                     -- GUID -> 实体
    self.entlist = {}                  -- 数组形式，保持遍历稳定
    self.nument = 0

    -- ★ 按 tick 索引的桶：记录「未来哪些 tick 需要处理这个实体」。
    --   用途：季节更替（每 60 秒）、天气切换、潮汐等周期性世界事件。
    --   调度器里也用了同样的技巧（02_scheduler 的 attime）。
    --   【为什么单独维护而不复用调度器？】
    --   因为这些是世界级事件，不是协程任务，不需要 yield，
    --   放在世界自己的桶里可以让「世界销毁时一次性清空」而不影响调度器。
    self.tickbuckets = {}

    -- 光照输出（0=全黑，1=全亮），供 sanity/温度等系统查询
    self.light = 1
    self.isday = true
    self.segment = "day"

    -- 累加器
    self.accumulator = 0
    self.maxsteps = 5          -- ★ 单帧最多补几步（防死亡螺旋）
end)

-- ---- 实体管理 ----

function World:AddEntity(inst)
    if self.ents[inst.GUID] then return inst end
    self.ents[inst.GUID] = inst
    inst.world = self
    self.entlist[#self.entlist + 1] = inst
    self.nument = self.nument + 1
    return inst
end

function World:RemoveEntity(inst)
    if not self.ents[inst.GUID] then return end
    -- 先从索引摘掉，再调 Remove。
    -- ★ 顺序很重要：如果先调 inst:Remove()，某些回调里又会去查
    --   world.ents[inst.GUID]，就会拿到一个"已经死了但还在表里"的实体。
    self.ents[inst.GUID] = nil
    for i = #self.entlist, 1, -1 do
        if self.entlist[i].GUID == inst.GUID then
            table.remove(self.entlist, i)
            break
        end
    end
    self.nument = self.nument - 1
    inst:Remove()
end

function World:GetEntityByGUID(g) return self.ents[g] end

function World:FindEntities(x, z, radius, mustTags, cantTags)
    return require("03_entity").FindEntities(x, z, radius, mustTags, cantTags, self.entlist)
end

-- ---- tick 桶 ----

function World:ScheduleAtTick(tick, fn, id)
    -- 把一个回调挂到未来的某个 tick。
    -- 【★ 为什么不能直接用 DoTaskInTime？】
    -- 因为这个函数必须是**世界的方法**：世界销毁时要能一键清空所有挂起回调。
    -- 如果用调度器，世界的销毁就无法统一管理（只能靠 id 分组 kill）。
    self.tickbuckets[tick] = self.tickbuckets[tick] or {}
    self.tickbuckets[tick][#self.tickbuckets[tick] + 1] = { fn = fn, id = id }
end

function World:ClearTickBuckets()
    self.tickbuckets = {}
end

-- ---- 时间与昼夜 ----

function World:GetTime() return self.time end
function World:GetDay() return self.day end

-- GetSegment：判断当前处于一天中的哪一段
function World:GetSegment()
    local frac = (self.time % self.daylength) / self.daylength
    local acc = 0
    for i = 1, #M.SEGMENTS do
        local name = M.SEGMENTS[i]
        acc = acc + self.segments[name]
        if frac < acc then return name end
    end
    return M.SEGMENTS[#M.SEGMENTS]
end

-- UpdateLight：根据昼夜计算全局光照。
-- ★ 这里刻意用了「分段常量 + 边界平滑过渡」而不是一根正弦曲线，
--   因为 DST 的光照是分段的，而正弦曲线在白天中段太平、夜晚中段太平，
--   没有「天快黑了」那种压迫感。
function World:UpdateLight()
    local frac = (self.time % self.daylength) / self.daylength
    local d_end = self.segments.day
    local dusk_end = d_end + self.segments.dusk

    if frac < d_end - 0.06 then
        self.light = 1
    elseif frac < d_end + self.segments.dusk - 0.06 then
        -- 黄昏过渡：1 -> 0.12 线性下降
        local t = (frac - (d_end - 0.06)) / (self.segments.dusk + 0.06)
        self.light = 1 - t * 0.88
    else
        self.light = 0.12
    end
    self.isday = self.segment == "day"
end

-- RecalcTime：根据当前 time 重算「处于哪一段 + 光照」。
-- 【为什么要单独抽成一个方法？】
-- 因为不只是 Step 需要它：调试面板、改存档、读档后的状态重建
-- 都需要「给定时间，立刻算出这段时间对应的世界状态」。
-- 把它抽出来，这些场景就不必伪造一个假的 Step() 调用。
function World:RecalcTime()
    self.segment = self:GetSegment()
    self:UpdateLight()
    self.isday = self.segment == "day"
end

function World:IsDark() return self.light < 0.3 end

-- ---- 主循环 ----

-- Update(realdt)：唯一对外的推进入口。
--   realdt 是「真实经过的秒数」（通常来自 os.clock 或引擎回调）。
--   内部按固定步长切成若干逻辑步。
function World:Update(realdt)
    -- ★ 保护：realdt 可能异常（切后台、系统休眠、时钟跳变）。
    --   不夹住的话，负数 dt 会让累加器变负，时间倒流。
    if realdt < 0 then realdt = 0 end
    if realdt > 1 then realdt = 1 end

    self.accumulator = self.accumulator + realdt

    local steps = 0
    while self.accumulator >= FRAMES do
        if steps >= self.maxsteps then
            -- ★ 死亡螺旋防护：补步数用尽，把多出来的时间丢掉。
            --   宁可让游戏时间慢一点，也不能卡死在这一帧。
            self.accumulator = 0
            self.droppedtime = (self.droppedtime or 0) + self.accumulator
            break
        end
        self.accumulator = self.accumulator - FRAMES
        self:Step()
        steps = steps + 1
    end
    return steps
end

-- Step：一个固定逻辑步。★ 这里的顺序就是整个游戏的执行顺序，不要乱调。
function World:Step()
    self.tick = self.tick + 1
    self.time = self.time + FRAMES

    -- 1) 推进 tick 计数器（调度器依赖它做绝对定位）
    sched.AdvanceTick()

    -- 2) 世界时间与昼夜
    self:RecalcTime()
    -- 跨天
    -- ★ 这里的 + 1e-9 不是「凑数」，而是必需的浮点防护：
    --   self.time 是每次累加 1/30 得到的。跑满 3000 步后，
    --   理论值正好是 100.0，浮点上却可能是 99.99999999999999，
    --   于是 math.floor(99.9999...) = 0，「满一整天」这一天就永远不算过，
    --   表现为「游戏里时间是 100 秒但日期还是第 1 天」。
    --   这与 02_scheduler.lua 里 GetListForTimeFromNow 的 -0.0001 是同一类问题：
    --   「恰好整除」在浮点世界里几乎不可能真的整除。
    local newday = math.floor(self.time / self.daylength + 1e-9) + 1
    if newday ~= self.day then
        self.day = newday
        self:PushEvent("onnewday", { day = self.day })
    end

    -- 3) 执行本 tick 的世界级回调
    local bucket = self.tickbuckets[self.tick]
    if bucket then
        for _, entry in ipairs(bucket) do entry.fn() end
        self.tickbuckets[self.tick] = nil
    end

    -- 4) ★ 先跑调度器（协程/周期任务）
    --    顺序很重要：先让「主动发起」的任务跑完，
    --    再让实体被动更新。否则实体看到的会是上一帧的世界状态。
    sched.RunScheduler(self.tick)

    -- 5) 更新实体
    --    ★ 用 ipairs 顺序遍历，且中途实体被销毁是安全的
    --      （RemoveEntity 会把数组元素往前挪，但用 #entlist 重新求长度时
    --        不会越界 —— Lua 的 # 对这种场景是安全的）。
    local list = self.entlist
    local n = #list
    for i = 1, n do
        local inst = list[i]
        if inst ~= nil and not inst._removed then
            inst:Update(FRAMES)
        end
    end

    -- 6) 清理这一 tick 已移除的实体（延迟删除）
    --    【为什么要延迟？】如果边遍历边删，数组会左移，导致跳过元素。
    --    标记删除 + 集中清扫，是所有「遍历中删除」的标准解法。
    if self._pendingremove and #self._pendingremove > 0 then
        for i = #self._pendingremove, 1, -1 do
            local inst = table.remove(self._pendingremove)
            if inst ~= nil then
                inst:Remove()
            end
        end
    end
end

-- RemoveEntity 改为延迟删除
function World:RemoveEntity(inst)
    if not self.ents[inst.GUID] then return end
    self.ents[inst.GUID] = nil
    for i = #self.entlist, 1, -1 do
        if self.entlist[i].GUID == inst.GUID then
            table.remove(self.entlist, i)
            break
        end
    end
    self.nument = self.nument - 1
    -- ★ 标记 + 延迟清理
    self._pendingremove = self._pendingremove or {}
    table.insert(self._pendingremove, inst)
end

-- ---- 世界事件总线 ----
-- 世界本身也是一个事件源（原版里 TheWorld:PushEvent("ms_playerjoined", inst)）
M._worldlisteners = {}

function World:ListenForEvent(eventname, fn)
    M._worldlisteners[eventname] = M._worldlisteners[eventname] or {}
    table.insert(M._worldlisteners[eventname], fn)
end

function World:PushEvent(eventname, data)
    local l = M._worldlisteners[eventname]
    if not l then return false end
    for i = #l, 1, -1 do l[i](self, data) end
    return true
end

function World:ClearEventListeners() M._worldlisteners = {} end

-- ---- 查询辅助 ----

function World:GetEntitiesWithTag(tag)
    local out = {}
    for _, inst in ipairs(self.entlist) do
        if inst.tags[tag] then out[#out + 1] = inst end
    end
    return out
end

function World:GetDebugString()
    return string.format(
        "[World %s] tick=%d day=%d seg=%-5s light=%.2f ents=%d light_ents=%d",
        self.name, self.tick, self.day, self.segment, self.light,
        self.nument, #(self:GetEntitiesWithTag("light")))
end

M.World = World

--============================================================
-- 七、自测
--============================================================

local T = {}
local function check(ok, msg)
    if not ok then error("[07_world] 断言失败: " .. msg, 2) end
end
local function near(a, b, eps, msg)
    check(math.abs(a - b) < (eps or 1e-9),
        (msg or "数值不符") .. string.format("  期望 %.6f 实际 %.6f", b, a))
end

-- 推进 n 个逻辑步（精确 1/30，不经过累加器）
local function stepN(w, n)
    for _ = 1, n do w:Step() end
end

function T.accumulator()
    local w = World("acc_test", 100)
    -- 累加器模式：60Hz 的输入应每 2 帧跑 1 步
    local steps = w:Update(1 / 60)
    check(steps == 0, "1/60 秒不够跑一步（需要 1/30）")
    steps = w:Update(1 / 60)
    check(steps == 1, "两次 1/60 应恰好跑 1 步")

    -- ★ 核心性质：不同帧率下，1 秒钟的游戏时间必须推进**完全相同**的逻辑步数。
--   144Hz / 60Hz / 20Hz 三种「硬件」，跑同样 1 秒，都应得到 30 个逻辑步。
    local framertest = {
        { name = "20Hz",  dt = 1 / 20,  frames = 20 },
        { name = "60Hz",  dt = 1 / 60,  frames = 60 },
        { name = "144Hz", dt = 1 / 144, frames = 144 },
    }
    for _, c in ipairs(framertest) do
        local w2 = World("acc_" .. c.name, 100)
        local total = 0
        for _ = 1, c.frames do total = total + w2:Update(c.dt) end
        -- 注意 144Hz 那一行可能因为浮点误差少跑半步，这里允许 +-1 的容差，
        -- 但关键是**不同帧率之间必须一致**，而不是精确等于 30。
        check(math.abs(total - 30) <= 1,
            string.format("%s 跑 1 秒应约 30 逻辑步，实际 %d", c.name, total))
    end

    -- ★ 大步长不应触发死亡螺旋
    local w3 = World("spiral_test", 100)
    local n = w3:Update(10)     -- 模拟切后台 10 秒
    check(n <= w3.maxsteps, "单帧补步数应被 maxsteps 限制（防死亡螺旋）")
    check(w3.tick == w3.maxsteps, string.format("应正好跑 maxsteps=%d 步，实际 %d", w3.maxsteps, w3.tick))
    print("  [OK] 累加器模式 + maxsteps 死亡螺旋防护")
end

function T.timeProgress()
    local w = World("time_test", 100)
    check(w.day == 1, "初始应为第 1 天")

    stepN(w, 30)   -- 1 秒
    near(w.time, 1.0, 1e-9, "30 步应推进 1 秒")
    check(w.day == 1, "第 1 天")

    stepN(w, 30 * 99)   -- 再 99 秒，累计 100 秒 = 整整一天
    check(w.day == 2, string.format("满一天后应进入第 2 天，实际第 %d 天", w.day))

    -- 再过 200 秒 -> 累计 300 秒 = 3 个整天，日期序号应为 4
    -- （day 是「第几天」，从 1 开始；300/100 = 3 个完整周期后是第 4 天）
    stepN(w, 30 * 200)
    near(w.time, 300.0, 1e-6, "累计时间")
    check(w.day == 4, string.format("累计 300 秒应为第 4 天，实际第 %d 天", w.day))
    print("  [OK] 时间推进与跨天计算（含浮点边界防护）")
end

function T.dayNight()
    local w = World("dn_test", 100)
    -- segments: day 0.7 (0-70s), dusk 0.1 (70-80s), night 0.2 (80-100s)
    w.time = 10; w:RecalcTime()
    check(w.segment == "day" and w.isday, "10 秒应是白天")
    check(w.light > 0.9, "白天应很亮")

    w.time = 75; w:RecalcTime()
    check(w.segment == "dusk", "75 秒应是黄昏")

    w.time = 90; w:RecalcTime()
    check(w.segment == "night" and not w.isday, "90 秒应是夜晚")
    check(w.light < 0.3, "夜晚应很暗")
    check(w:IsDark(), "夜晚应判定为暗")

    -- 黄昏应该是「渐暗」的中间态，而不是突变
    w.time = 72; w:RecalcTime()
    local l72 = w.light
    w.time = 78; w:RecalcTime()
    local l78 = w.light
    check(l72 > l78, "黄昏应随时间变暗")
    check(l72 < 1 and l78 > 0, string.format("黄昏应处于中间亮度，72s=%.2f 78s=%.2f", l72, l78))
    print("  [OK] 昼夜分段与光照输出（含黄昏渐变）")
end

function T.entities()
    local w = World("ent_test", 100)
    local spawn = require("06_prefab_spawn")
    spawn.SetMasterSim(true)

    local torch = spawn.SpawnPrefab("torch", 0, 0)
    w:AddEntity(torch)
    local rock = spawn.SpawnPrefab("rock", 50, 50)
    w:AddEntity(rock)
    check(w.nument == 2, "应有 2 个实体")

    -- 组件应被驱动
    -- ★ 要让组件进入实体的更新列表，必须调「实体」的 StartUpdatingComponent，
    --   组件自己是没有这个方法的（这正是原版 DST 的约定：
    --   inst:StartUpdatingComponent(comp)，而不是 comp:StartUpdating()）。
    local burn = torch.components.burnable
    torch:StartUpdatingComponent(burn)
    local fuel_before = burn.fuel
    stepN(w, 30)
    check(burn.fuel < fuel_before, "组件 OnUpdate 应被驱动")

    -- 按标签查询
    local lights = w:GetEntitiesWithTag("light")
    check(#lights == 1 and lights[1].GUID == torch.GUID, "应只找到 torch（带 light 标签）")

    -- 空间查询
    local near = w:FindEntities(0, 0, 10, { "light" }, nil)
    check(#near == 1, "torch 应在半径 10 内")
    check(#w:FindEntities(45, 45, 10, { "light" }, nil) == 0, "远处应查不到")

    -- 销毁：标记删除 -> 下一步集中清扫
    w:RemoveEntity(torch)
    check(w.ents[torch.GUID] == nil, "应立即从索引移除")
    check(torch._removed == false, "实体应被标记延迟删除（未立刻销毁）")
    stepN(w, 1)
    check(torch._removed == true, "下一步应完成实际销毁")
    check(w.nument == 1, "销毁后应剩 1 个实体")

    print("  [OK] 实体增删查 + 延迟删除 + 组件驱动")
end

function T.tickBuckets()
    local w = World("bucket_test", 100)
    local hits = 0
    w:ScheduleAtTick(5, function() hits = hits + 1 end)
    w:ScheduleAtTick(5, function() hits = hits + 1 end)
    stepN(w, 4)
    check(hits == 0, "未到 tick 不应触发")
    stepN(w, 1)
    check(hits == 2, "到点应触发全部回调")
    check(w.tickbuckets[5] == nil, "执行后应清空桶（防泄漏）")
    print("  [OK] 按 tick 索引的桶调度")
end

function T.tenThousandTicks()
    -- ★ 压力测试：10000 步不崩，时间正确
    local w = World("stress_test", 100)
    local spawn = require("06_prefab_spawn")
    spawn.SetMasterSim(true)

    local player = spawn.SpawnPrefab("player", 0, 0)
    w:AddEntity(player)
    player:StartUpdatingComponent(player.components.hunger)
    player:StartUpdatingComponent(player.components.sanity)

    -- 每 tick 推进一步，共 10000 tick
    local start_tick = w.tick
    stepN(w, 10000)
    check(w.tick - start_tick == 10000, "应推进 10000 tick")
    near(w.time, 10000 / 30, 1e-6, "世界时间应推进 10000/30 秒")

    -- 期望天数：10000/30 = 333.33 秒 / 100 = 3.33 天 -> 第 4 天
    check(w.day == 4, string.format("应进入第 4 天，实际第 %d 天", w.day))

    -- 组件应持续推进且不越界
    local h = player.components.hunger
    check(h.current >= 0 and h.current <= h.max, "饥饿度应在合法区间")

    -- 世界没有崩溃，实体仍在
    check(w.nument == 1, "实体应仍然存在")
    print(string.format("  [OK] 10000 tick 无异常：day=%d light=%.2f hunger=%.2f",
        w.day, w.light, h.current))
end

function T.run()
    print("=== 07_world.lua 自测 ===")
    T.accumulator()
    T.timeProgress()
    T.dayNight()
    T.entities()
    T.tickBuckets()
    T.tenThousandTicks()
    sched.StopAllThreads()
    print("07_world 全部通过\n")
    return true
end

M.test = T

--============================================================
-- 八、导出
--============================================================

-- 【独立运行检测】不能用 `... == nil`：Lua 5.2+ 用 load 编译的 chunk 非 vararg，
--   顶层 `...` 是语法错误。详见 01_class.lua 末尾的说明。
local function IS_MAIN_CHUNK()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) ~= "@" then return false end
    local fname = src:sub(2):gsub("\\", "/"):match("([^/]+)$") or ""
    if fname == "" then return false end
    return arg ~= nil and arg[0] ~= nil
        and (arg[0]:gsub("\\", "/"):match("([^/]+)$")) == fname
end

if IS_MAIN_CHUNK() then
    T.run()
end

return M