--============================================================
-- 文件：08_statemachine.lua
-- 模块：玩法 / AI 状态机（StateGraph）
-- 职责：StateGraph 的定义、AddState、条件转换、共享状态库，
--       并给出一个完整例子：hound（巡逻 → 发现 → 追击 → 攻击 → 返回）。
--
-- 【★ 为什么不用简单的 if/else 或面向继承的层次状态机？】
-- ① 继承式（每个状态是一个子类）：一个生物有 N 个状态，
--    「从 A 到 B」的所有跳转逻辑要写在 A 里。加个新状态要改 N 个类。
-- ② if/else 链：状态多了以后不可维护，且无法回答「这个生物有哪些状态」。
-- ③ 状态图（本模块）：状态是**数据**（对象），转换是**数据**（表），
--    于是可以
--      - 复用（见下面的 CommonStates 共享状态库）
--      - 动态生成（按季节/难度批量改转换条件）
--      - 序列化（存档里存「当前状态名 + 已停留时间」）
--      - 可视化（把 nextstate 表画成图，做设计工具）
--
-- 【★ 一个必须注意的坑：状态机的「每帧 Think」成本】
-- 状态机通常在协程里每帧跑（`while true do sg:Think(); Sleep(FRAMES) end`），
-- 1000 个生物就是 1000 个协程每帧被 resume。
-- 原版 DST 用「行为树 + 状态图混合」并配合距离休眠来控制这个成本：
-- 玩家看不见的生物直接 Hibernate()，完全不占 CPU。
-- 这个知识点在 02_scheduler 的 Hibernate 处已经埋好伏笔。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》scripts/stategraph.lua
-- 兼容性：Lua 5.1 / 5.3 / 5.4 / LuaJIT
--============================================================

local Class = require("01_class").Class
local sched = require("02_scheduler")

local M = {}

local SLEEP = sched.SLEEP
local HIBERNATE = sched.HIBERNATE

--============================================================
-- 一、状态基类
--============================================================

-- 一个状态是「命名 + 三个可选回调」的组合。
--   OnEnter(inst)              —— 进入时执行一次（OnUpdate 之前）
--   OnUpdate(inst, dt)         —— 每帧执行
--   ShouldTransition(inst)     —— 在 OnUpdate 之后调用，返回目标状态名
--
-- ★ 为什么用「状态自己声明我想去哪」，而不是「状态图集中一张转换表」？
--   因为分散声明时，每个状态的行为都集中在一个文件里，可读性更好；
--   而且转换条件往往需要访问状态内部的私有数据。
--   集中表的写法（Graph.transitions[from][to] = cond）在大图里更好可视化，
--   两种都常见。本实现采用前者，因为它更贴近 DST 原版。
local State = Class(function(self, name)
    self.name = name
    -- nextstate：{ [目标状态名] = 条件函数, ... }
    self.nextstate = {}
    -- nextorder：{ 状态名, ... }，保持**插入顺序**。
    -- ★ 为什么不能直接 pairs(self.nextstate) 遍历？
    --   Lua 的 pairs 顺序是未定义的，同一份代码在不同运行/不同版本下
    --   可能选到不同的转移目标 —— 这类「偶发」bug 极难复现。
    --   保留一个有序数组，转移优先级就变成确定的「先注册先生效」。
    self.nextorder = {}
end)

-- ★★ 写状态子类时**必须**写 Class(State, function(self, name) State._ctor(self, name) ... end)
--   不能写 Class(function(self, name) State._ctor(self, name) ... end)。
--   原因在 01_class.lua 里：Class 的第一个参数如果**是函数**，会被当成
--   「无基类的根类构造函数」，于是根本不会发生浅拷贝 —— 子类拿不到
--   AddTransition / OnEnter 等任何方法。
--   症状极其隐蔽：不报任何错，只是「状态类没有 AddTransition 方法」，
--   本模块开发时就在这里踩过一次。

-- SetTransitions：给**类**批量预设转换条件。
--   ★ 为什么需要它？因为转换条件存了两张表：
--       nextstate = { 目标名 -> 条件函数 }   （查条件）
--       nextorder = { 目标名, ... }          （定优先级，保证遍历顺序确定）
--     手工只写其中一张必然出错（写了下条件查不到、或有了优先级没有条件），
--     这正是本模块开发时踩过的坑。这里用一个函数把两张表一起维护。
function State.SetTransitions(klass, destmap)
    local order = {}
    -- 用显式传入的顺序（表字面量的键顺序在 Lua 里不保证，这里按名称排序保证确定）
    local names = {}
    for k in pairs(destmap) do table.insert(names, k) end
    table.sort(names)
    for _, name in ipairs(names) do
        table.insert(order, name)
    end
    klass.nextstate = destmap
    klass.nextorder = order
    return klass
end

function State:AddTransition(destname, condition)
    -- ★ 只能在**实例**上调用。类表上没有 nextstate（它是构造时创建的实例字段），
    --   在类上调这个方法会因为 self.nextstate 为 nil 而崩溃。
    --   要给类预设转换，请直接写 `Klass.nextstate = { ... }`，见 CommonStates.idle。
    if self.nextstate == nil then
        self.nextstate = {}
        self.nextorder = {}
    end
    if self.nextstate[destname] == nil then
        table.insert(self.nextorder, destname)   -- 记录插入顺序
    end
    self.nextstate[destname] = condition
    return self
end

-- GetTransitionTarget：按插入顺序找出第一个条件为真的目标状态
--   条件函数签名 function(inst, sg)：
--   同时给实体和状态图，是为了让条件可以读「在当前状态待了多久」
--   这类只有状态图才知道的信息，而不必在实体上到处挂引用。
function State:GetTransitionTarget(inst, sg)
    local order = self.nextorder
    if order == nil then return nil end
    for i = 1, #order do
        local dest = order[i]
        local cond = self.nextstate[dest]
        if cond and cond(inst, sg) then
            return dest
        end
    end
    return nil
end

function State:OnEnter(inst) end
function State:OnUpdate(inst, dt) end
function State:ShouldTransition(inst) return nil end
function State:OnExit(inst) end

M.State = State

--============================================================
-- 二、StateGraph
--============================================================

local StateGraph = Class(function(self, name)
    self.name = name
    self.states = {}           -- 状态名 -> 状态对象
    self.initialstate = ""
    self.currentstate = nil
    self.currentstateinst = nil  -- 指向状态对象
    self.inst = nil
    self.currenttime = 0       -- 当前状态已停留时间
    self.prevstate = nil
end)

-- AddState(state)：往图里加一个状态。state 可以是 State 实例，也可以是类。
function StateGraph:AddState(state)
    self.states[state.name] = state
    return state
end

-- AddStates(...)：批量加
function StateGraph:AddStates(...)
    for i = 1, select("#", ...) do
        local s = select(i, ...)
        if s then self:AddState(s) end
    end
end

-- State(name)：按名取状态。取不到要报错，不能静默返回 nil
-- ★ 「拼错状态名」是最常见的 AI bug，症状是「AI 卡在原地不动」，
--   根因却是某个 typo 导致了状态永远无法命中。宁可崩也不要静默。
function StateGraph:State(name)
    local s = self.states[name]
    if s == nil then
        error(string.format("StateGraph '%s' 没有名为 '%s' 的状态", tostring(self.name), tostring(name)))
    end
    return s
end

function StateGraph:SetInitialState(name)
    self.initialstate = name
    return self
end

-- HasState
function StateGraph:HasState(name) return self.states[name] ~= nil end

-- 当前状态名（存档用）
function StateGraph:GetCurrentStateName() return self.currentstate end
function StateGraph:GetTimeInState() return self.currenttime end

-- StartThread(inst)：把状态机挂到一个协程上跑。
-- 【★ 为什么状态机跑在协程里，而不是每帧被引擎回调？】
-- 因为 OnEnter 里经常会需要「等待」：走到门口(等门开) -> 进门 -> 攻击 -> 返回。
-- 用协程就能直接写：
--     function OnEnter(inst)
--         while inst:HasTag("busy") do Sleep(FRAMES) end
--     end
-- 如果是回调式模型，就得用状态变量手写轮询状态机 —— 那就白用状态机了。
function StateGraph:StartThread(inst)
    -- id 用实体 GUID，实体销毁时 KillThreadsWithID 能一次清掉
    return inst:StartThread(function()
        if self.currentstate == nil then
            self:OnStart(inst)
        end

        -- ★★ 本帧允许的最大「不 Sleep 连续切换次数」★★
        --   Think 在发生状态转换时返回 false，表示「本帧不要再 Sleep 了，
        --   接着跑新状态」。这让「发现 -> 追击 -> 攻击」能在同一帧内完成，
        --   AI 反应是瞬时的而不是拖一帧。
        --
        --   但如果两个状态互相转移（attack -> chase -> attack -> chase ...），
        --   Think 就会永远返回 false，这个协程**永远不让出**，
        --   表现为「游戏彻底卡死」。
        --   ★ 这类「状态震荡」在游戏里非常容易发生：
        --     玩家站在猎犬身上时，咬一口 -> 退一步 -> 再咬，就是个 2 周期。
        --   所以必须给一个预算：连续切换超过 MAX_TRANSITIONS_PER_FRAME 就强制 Sleep。
        --   这既保住了瞬时反应，又杜绝了无限循环。
        local MAX_TRANSITIONS_PER_FRAME = 4
        local budget = MAX_TRANSITIONS_PER_FRAME

        while true do
            local transitioned = (self:Think(inst) == false)

            if transitioned then
                budget = budget - 1
            else
                budget = MAX_TRANSITIONS_PER_FRAME
            end

            -- 让出一帧的两种情况：
            --   ① 本帧没有发生状态转换（正常路径）
            --   ② 本帧发生了转换，但连续转换次数已用完预算（防状态震荡）
            -- ★ 两种情况都必须走到 Sleep，否则协程永不让出 -> 整个游戏卡死。
            if not transitioned or budget <= 0 then
                budget = MAX_TRANSITIONS_PER_FRAME
                sched.Sleep(1 / 30)
            end
        end
    end)
end

-- OnStart：进入初始状态
function StateGraph:OnStart(inst)
    self.inst = inst
    self:ChangeState(self.initialstate, inst)
end

-- ChangeState(name, inst)：切换状态。**所有切换都必须走这里**
function StateGraph:ChangeState(name, inst)
    if self.currentstateinst and self.currentstateinst.OnExit then
        self.currentstateinst:OnExit(inst)
    end

    self.prevstate = self.currentstate
    self.currentstate = name
    self.currentstateinst = self:State(name)   -- 状态名写错会在这里炸出来
    self.currenttime = 0

    if self.currentstateinst.OnEnter then
        self.currentstateinst:OnEnter(inst)
    end
    return true
end

-- Think：跑一帧。返回 false 表示「不要 Sleep，立即再跑一次」（用于快速连切状态）
function StateGraph:Think(inst, dt)
    if self.currentstateinst == nil then
        self:OnStart(inst)
        return false
    end

    dt = dt or (1 / 30)
    self.currenttime = self.currenttime + dt

    if self.currentstateinst.OnUpdate then
        self.currentstateinst:OnUpdate(inst, dt)
    end

    -- ★ 关键：OnUpdate 之后才判断转换。
    --   顺序很重要 —— 如果先判断转换，本帧刚设的变量（比如刚发现玩家）
    --   要等到下一帧才生效，会造成一帧延迟。
    --
    -- 两种声明转移的方式，**ShouldTransition 优先**：
    --   ① 覆写 ShouldTransition 并返回目标状态名（动态、需要复杂判断时用）
    --   ② 用 AddTransition 注册条件表（静态、声明式时用，见下方 nextstate）
    -- 之所以两种都支持：现实项目里两种风格混用得厉害，强行统一只会别扭。
    local dest = nil
    if self.currentstateinst.ShouldTransition then
        dest = self.currentstateinst:ShouldTransition(inst)
    end
    if dest == nil then
        dest = self.currentstateinst:GetTransitionTarget(inst, self)
    end

    if dest ~= nil and dest ~= self.currentstate then
        self:ChangeState(dest, inst)
        -- 切换后不 Sleep，立刻跑新状态的 OnEnter + OnUpdate
        -- ★ 这样「发现玩家 -> 追击 -> 攻击」可以在同一帧内连续完成，
        --   AI 的反应才是「瞬时」的，而不是拖一帧。
        return false
    end
    return true
end

-- Hibernate / Wake：远距离休眠
-- 【★ 性能关键】玩家看不见的 AI 应该完全停摆。
--   Hibernate 之后协程彻底不被调度，开销降到零。
function StateGraph:Hibernate()
    sched.Hibernate()
end

function StateGraph:Wake()
    sched.Wake()
end

--============================================================
-- 三、共享状态库
--============================================================

-- ★★ 这是状态图最大的收益所在。
--   walk / idle / attack 这类状态在几十种生物里是**完全一样**的，
--   不应该每个生物各写一份。
--   共享的方式有两种：
--     (a) 共享**类**：CommonStates.walk 是 State 的子类，各图 AddState(CommonStates.walk)
--     (b) 共享**实例**：各图 AddState(CommonStates.walk)
--   (b) 有坑：实例是共享的，若状态内部存了「上次追击的目标」这种实例变量，
--   两只 hound 会互相污染。所以有实例状态时用 (a) —— 每个图各建一个实例。
--   本实现统一用 (a)，并在 AddState 时 clone 一份。
local CommonStates = {}

local function cloneState(stateclass, name)
    -- stateclass 是一个 State 子类；调用它即得一个独立实例
    local s = stateclass(name)
    -- 把类上的 nextstate / nextorder 定义拷进实例（clone 语义）
    if stateclass.nextstate then
        for k, v in pairs(stateclass.nextstate) do
            s.nextstate[k] = v
        end
    end
    if stateclass.nextorder then
        for i = 1, #stateclass.nextorder do
            table.insert(s.nextorder, stateclass.nextorder[i])
        end
    end
    return s
end

-- idle：发呆
-- ★ 注意转换条件是**写在类上**的（下面 CommonStates.idle.nextstate = {...}），
--   而不是用 `CommonStates.idle:AddTransition(...)`。
--   原因：AddTransition 会往 self.nextstate 里写，而**类表**上的 nextstate 是 nil
--   （nextstate 是构造时才创建的实例字段）。类上调用会直接崩。
--   类上定义 + clone 时拷进实例，是这里最不容易出错的方式。
CommonStates.idle = Class(State, function(self, name)
    State._ctor(self, name)
    self.ontime = 3.0
end)
-- ★ 转换条件用 SetTransitions 一次性写全两张表（nextstate + nextorder）。
--   若只写 CommonStates.idle.nextstate = {...}，clone 时会丢掉优先级数组，
--   导致转换条件永远不被求值 —— 症状是「状态永远不切换」。
State.SetTransitions(CommonStates.idle, {
    -- 发呆满 ontime（默认 3 秒）-> 巡逻
    -- ★ 注意这里读的是 sg.currentstateinst.ontime，也就是「我自己这个状态」，
    --   而不是绕道 inst 去查。这样这个状态才能被原样复用到任何实体上。
    ["walk"] = function(inst, sg)
        return sg:GetTimeInState() >= sg.currentstateinst.ontime
    end,
})

-- walk：巡逻
CommonStates.walk = Class(State, function(self, name)
    State._ctor(self, name)
end)
function CommonStates.walk:OnUpdate(inst, dt)
    -- 巡逻：绕圈走
    inst.angle = inst.angle + 60 * dt
    
end

-- attack：攻击（共享给 hound / 牛 / 蜘蛛 等所有近战生物）
CommonStates.attack = Class(State, function(self, name)
    State._ctor(self, name)
    self.cooldown = 0
    self.windup = 0.4      -- 前摇：让玩家有反应时间
end)
function CommonStates.attack:OnEnter(inst)
    self.cooldown = 0
end
function CommonStates.attack:OnUpdate(inst, dt)
    self.cooldown = self.cooldown + dt
    -- 前摇结束后造成伤害
    if self.cooldown >= self.windup and not self.didhit then
        self.didhit = true
        if inst.target and inst.target.components and inst.target.components.health then
            inst.target.components.health:DoDamage(inst.attackdamage, inst.prefab)
        end
    end
end
function CommonStates.attack:OnExit(inst)
    self.didhit = false
end

M.StateGraph = StateGraph
M.State = State
M.CommonStates = CommonStates
M.CloneState = cloneState
M.BuildHoundGraph = buildHoundGraph
M.Distance = distance
M.test = T

--============================================================
-- 四、示例：hound 的状态图
--============================================================

-- hound 的五个状态：
--   patrol   巡逻（找玩家）      <- 初始
--   spotted  发现玩家（短暂停顿）
--   chase    追击
--   attack   咬人
--   return   放弃目标，散步回去
--
-- 【★ 注意 attack 状态是从共享库里 clone 来的】
--   它和「牛」「蜘蛛」的 attack 是同一份代码逻辑，
--   只是名字不同（名字不同才能在同一张图里区分「hound_attack」）。

local function distance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end
M.Distance = distance

local function buildHoundGraph()
    local sg = StateGraph("hound")

    -- ---- patrol：巡逻 ----
    local patrol = cloneState(CommonStates.walk, "patrol")
    function patrol:OnUpdate(inst, dt)
        inst.angle = (inst.angle or 0) + 45 * dt
        inst.x = inst.x + math.cos(inst.angle * math.pi / 180) * 1.5 * dt
        inst.z = inst.z + math.sin(inst.angle * math.pi / 180) * 1.5 * dt
        inst.state_ticks = inst.state_ticks + 1
    end
    patrol:AddTransition("spotted", function(inst)
        -- 视野范围内有玩家 -> 发现
        local target = inst.nearestplayer
        return target ~= nil and distance(inst, target) < 12
    end)
    patrol:AddTransition("return", function(inst)
        -- 巡逻太久了 -> 去换个地方
        return inst.state_ticks > 300
    end)

    -- ---- spotted：发现 ----
    local spotted = Class(State, function(self, name) State._ctor(self, name) end)("spotted")
    function spotted:OnEnter(inst)
        inst.state_ticks = 0
        inst.barking = true
    end
    spotted:AddTransition("chase", function(inst, sg)
        -- ★ 用「在 spotted 停留了多久」而不是 inst.state_ticks。
        --   原因：state_ticks 是各状态自己维护的计数器，而 spotted 并不做移动，
        --   没人会去 +1，条件就永远不成立（卡死在 spotted）。
        --   「在当前状态待了多久」是状态图自己的信息，应该问状态图。
        --   0.3 秒 = 9 帧，给玩家一个「被发现了」的预警窗口。
        return sg:GetTimeInState() > 0.3
    end)
    spotted:AddTransition("patrol", function(inst)
        -- 玩家跑了（而且还没被转到 chase 时）
        local t = inst.nearestplayer
        return t == nil or distance(inst, t) > 15
    end)

    -- ---- chase：追击 ----
    local chase = Class(State, function(self, name) State._ctor(self, name) end)("chase")
    function chase:OnEnter(inst)
        inst.state_ticks = 0
        -- ★ 在进入追击的那一刻「锁定目标」。
        --   如果等到 chase 的 OnUpdate 里才去拿目标，会出现一个隐蔽的 bug：
        --   chase 的第一条转移条件是「目标丢失 -> 放弃」，
        --   而目标此刻还没赋值，于是每帧判定「目标为 nil」-> 立刻放弃追击。
        --   AI 里这类「刚进状态就自杀」的 bug 极难定位，根因就是赋值时机晚了半拍。
        inst.target = inst.nearestplayer
    end
    function chase:OnUpdate(inst, dt)
        inst.state_ticks = inst.state_ticks + 1
        local t = inst.target
        if t then
            -- 直线冲向目标
            local dx, dz = t.x - inst.x, t.z - inst.z
            local d = math.sqrt(dx * dx + dz * dz)
            if d > 0 then
                inst.x = inst.x + dx / d * 6 * dt
                inst.z = inst.z + dz / d * 6 * dt
            end
        end
    end
    chase:AddTransition("attack", function(inst)
        local t = inst.target
        return t ~= nil and distance(inst, t) < 1.5
    end)
    chase:AddTransition("return", function(inst)
        local t = inst.target
        return t == nil or inst.state_ticks > 600   -- 追太久就放弃
    end)

    -- ---- attack：攻击（★ 来自共享库）----
    local attack = cloneState(CommonStates.attack, "attack")
    attack:AddTransition("chase", function(inst)
        -- 一次攻击持续 0.9 秒后回到追击（形成「追-咬-追-咬」的节奏）
        return sg:GetTimeInState() >= 0.9
    end)
    attack:AddTransition("return", function(inst)
        local t = inst.target
        -- ★ 放弃攻击的三种情况，逐条列出而不是笼统写「目标无效」：
        --   t == nil        —— 根本没拿到目标
        --   t._removed      —— 目标实体已从世界销毁（玩家下线/死亡）
        --   没有 player 标签 —— 目标不再是玩家（例如变成幽灵被别的逻辑接管）
        -- 写成这样的好处：将来加一种「无效目标」时，只要往这个列表里加一条即可。
        return t == nil or t._removed or not t:HasTag("player")
    end)

    -- ---- return：返回 ----
    local ret = Class(State, function(self, name) State._ctor(self, name) end)("return")
    function ret:OnUpdate(inst, dt)
        inst.state_ticks = inst.state_ticks + 1
        -- 放弃追击：清空目标
        inst.target = nil
        -- 往出生点走
        local dx, dz = inst.homex - inst.x, inst.homez - inst.z
        local d = math.sqrt(dx * dx + dz * dz)
        if d > 1 then
            inst.x = inst.x + dx / d * 3 * dt
            inst.z = inst.z + dz / d * 3 * dt
        end
    end
    ret:AddTransition("patrol", function(inst)
        return inst.state_ticks > 60
    end)

    sg:AddStates(patrol, spotted, chase, attack, ret)
    sg:SetInitialState("patrol")
    return sg
end

M.BuildHoundGraph = buildHoundGraph

--============================================================
-- 五、自测
--============================================================

local T = {}
local function check(ok, msg)
    if not ok then error("[08_statemachine] 断言失败: " .. msg, 2) end
end

-- 造一只假 hound
local function makeHound()
    local Entity = require("03_entity").Entity
    local h = Entity("hound_test")
    h.attackdamage = 20
    h.angle = 0
    h.state_ticks = 0
    h.x, h.z = 0, 0
    h.homex, h.homez = 0, 0
    h.target = nil
    h.nearestplayer = nil
    return h
end

-- 让图跑 n 帧
local function runSG(sg, inst, n)
    for _ = 1, n do sg:Think(inst, 1 / 30) end
end

function T.basicGraph()
    local sg = StateGraph("basic")
    local s1 = Class(State, function(self, n) State._ctor(self, n) end)("idle")
    local s2 = Class(State, function(self, n) State._ctor(self, n) end)("walk")
    sg:AddStates(s1, s2)
    sg:SetInitialState("idle")

    check(sg:HasState("idle") and sg:HasState("walk"), "应能查状态是否存在")
    check(sg:State("idle") == s1, "State(name) 应取到状态")
    -- 状态名写错必须报错（防止 typo 导致的「AI 卡住」）
    local ok = pcall(function() return sg:State("walking") end)
    check(not ok, "取不存在的状态必须报错")
    print("  [OK] 状态定义 / 查询 / 错名报错")
end

function T.transitions()
    local sg = StateGraph("trans")
    local counter = { enter1 = 0, enter2 = 0, exit1 = 0 }
    local s1 = Class(State, function(self, n) State._ctor(self, n) end)("one")
    function s1:OnEnter(inst) counter.enter1 = counter.enter1 + 1 end
    function s1:OnExit(inst) counter.exit1 = counter.exit1 + 1 end
    s1:AddTransition("two", function(inst) return inst.ready end)

    local s2 = Class(State, function(self, n) State._ctor(self, n) end)("two")
    function s2:OnEnter(inst) counter.enter2 = counter.enter2 + 1 end

    sg:AddStates(s1, s2)
    sg:SetInitialState("one")

    local inst = makeHound()
    sg:OnStart(inst)
    check(sg:GetCurrentStateName() == "one", "应进入初始状态")
    check(counter.enter1 == 1, "OnEnter 应被调用一次")

    runSG(sg, inst, 5)
    check(sg:GetCurrentStateName() == "one", "条件不满足不应转移")

    inst.ready = true
    runSG(sg, inst, 1)
    check(sg:GetCurrentStateName() == "two", "条件满足应立即转移")
    check(counter.exit1 == 1, "原状态 OnExit 应被调用")
    check(counter.enter2 == 1, "新状态 OnEnter 应被调用")
    check(sg.prevstate == "one", "应记录上一状态")

    -- TimeInState：切换瞬间应归零，随后按 dt 累加
    check(sg:GetTimeInState() == 0, "刚切换状态时停留时间应归零")
    runSG(sg, inst, 30)
    check(sg:GetTimeInState() > 0.9 and sg:GetTimeInState() < 1.1,
        string.format("30 帧后停留时间应约 1 秒，实际 %.3f", sg:GetTimeInState()))
    print("  [OK] 条件转换 + OnEnter/OnExit 生命周期 + 停留时间统计")
end

function T.sharedStates()
    -- ★ 共享状态的核心验证：两个图用同一个类，实例互不干扰
    local a = cloneState(CommonStates.attack, "attack_a")
    local b = cloneState(CommonStates.attack, "attack_b")
    check(a ~= b, "每次 clone 应得到独立实例")
    check(a.name ~= b.name, "名字可以不同")
    check(type(a.OnUpdate) == "function", "clone 后行为应保留")

    -- 实例状态互不污染
    local hound = makeHound()
    local spider = makeHound()
    a:OnUpdate(hound, 1)     -- a.cooldown = 1
    check(a.cooldown == 1, "a 应被更新")
    check(b.cooldown == 0, "★ b 不应被 a 的更新影响（实例状态隔离）")

    -- idle 的自动转移
    local sg = StateGraph("shared_idle")
    local idle = cloneState(CommonStates.idle, "idle")
    local walk = cloneState(CommonStates.walk, "walk")
    sg:AddStates(idle, walk)
    sg:SetInitialState("idle")
    local inst = makeHound()
    sg:OnStart(inst)
    runSG(sg, inst, 100)   -- 超过 ontime=3 秒（90 帧）
    check(sg:GetCurrentStateName() == "walk",
        string.format("共享 idle 状态超时后应转到 walk，实际 %s", sg:GetCurrentStateName()))
    print("  [OK] 共享状态库：一份代码，多处复用且状态隔离")
end

function T.houndAI()
    local sg = buildHoundGraph()
    local hound = makeHound()
    local player = require("03_entity").Entity("player_test")
    player:AddTag("player")     -- ★ hound 的攻击放弃条件会检查这个标签
    player.x, player.z = 100, 100    -- 先放远处

    sg:OnStart(hound)
    check(sg:GetCurrentStateName() == "patrol", "初始状态应为 patrol")

    -- 玩家在远处 -> 保持巡逻
    hound.nearestplayer = player
    runSG(sg, hound, 20)
    check(sg:GetCurrentStateName() == "patrol", "远处不应发现玩家")

    -- ★ 把玩家放到视野内 -> 发现
    player.x, player.z = hound.x + 3, hound.z
    hound.state_ticks = 0
    runSG(sg, hound, 2)
    check(sg:GetCurrentStateName() == "spotted",
        string.format("玩家靠近应进入 spotted，实际 %s", sg:GetCurrentStateName()))
    check(hound.barking == true, "进入 spotted 应有「叫」的表现")

    -- spotted 停留一会 -> chase
    runSG(sg, hound, 15)
    check(sg:GetCurrentStateName() == "chase",
        string.format("愣一会后应进入 chase，实际 %s", sg:GetCurrentStateName()))

    -- 追到近处 -> attack
    hound.target = player
    player.x, player.z = hound.x + 1, hound.z     -- 距离 < 1.5
    runSG(sg, hound, 1)
    check(sg:GetCurrentStateName() == "attack",
        string.format("靠近应进入 attack，实际 %s", sg:GetCurrentStateName()))

    -- 攻击应造成伤害
    player:AddComponent(require("04_meter").Health)
    local hp = player.components.health.current
    runSG(sg, hound, 35)     -- 35 帧 = 1.17 秒，足够完成前摇
    check(player.components.health.current < hp,
        string.format("attack 应造成伤害，%s -> %s",
            tostring(hp), tostring(player.components.health.current)))

    -- ★ 注意：咬完会回到 chase，而玩家还贴在身上 -> chase 又立刻转回 attack。
    --   这就是设计中的「追-咬-追-咬」节奏，不是一次性打完就站桩。
    --   所以这里断言的是「状态循环出现过 chase」，而不是「当前状态必须是 chase」。
    local seen = { [sg:GetCurrentStateName()] = true }
    for _ = 1, 60 do
        runSG(sg, hound, 1)
        seen[sg:GetCurrentStateName()] = true
    end
    check(seen.chase, "咬完后应回到 chase（形成循环）")
    check(seen.attack, "应反复进入 attack")

    -- ★ 玩家消失 -> 放弃追击，进入 return
    hound.nearestplayer = nil
    hound.target = nil
    runSG(sg, hound, 2)
    check(sg:GetCurrentStateName() == "return",
        string.format("目标丢失应进入 return，实际 %s", sg:GetCurrentStateName()))

    -- return 停留后 -> patrol
    runSG(sg, hound, 70)
    check(sg:GetCurrentStateName() == "patrol",
        string.format("返回后应回到 patrol，实际 %s", sg:GetCurrentStateName()))

    print("  [OK] hound 五状态完整流转：patrol→spotted→chase→attack→return→patrol")
end

function T.inWorld()
    -- ★ 在真实世界主循环里跑 AI（状态机 + 协程 + 世界三者集成）
    local schedM = sched
    schedM.StopAllThreads()
    schedM.ResetTime()

    local World = require("07_world").World
    local spawn = require("06_prefab_spawn")
    spawn.SetMasterSim(true)

    local w = World("ai_world", 100)
    local hound = spawn.SpawnPrefab("hound", 0, 0)
    w:AddEntity(hound)

    local sg = buildHoundGraph()
    hound.sg = sg
    hound.homex, hound.homez = 0, 0
    hound.state_ticks = 0
    hound.angle = 0
    hound.attackdamage = 20

    local player = spawn.SpawnPrefab("player", 50, 50)
    w:AddEntity(player)
    hound.nearestplayer = player

    sg:StartThread(hound)   -- ★ 用协程驱动而不是手动 Think

    -- 玩家放近，让它进入视野
    player.x, player.z = 5, 0

    local seen = { [sg.initialstate] = true }   -- 初始状态先记上
    for i = 1, 600 do
        w:Step()                     -- 跑 20 秒
        local st = sg:GetCurrentStateName()
        seen[st] = true
        -- ★ 还要记录「上一状态」：状态机在**同一帧内**可以连切多次
        --   （Think 切换后返回 false 表示不 Sleep，本帧会立刻再跑一次），
        --   所以只在每步末尾采样一次，是会漏掉中间状态的。
        if sg.prevstate then seen[sg.prevstate] = true end
    end

    check(seen.patrol ~= nil, "应经历过 patrol")
    check(seen.spotted ~= nil, "应经历过 spotted")
    check(seen.chase ~= nil, "应经历过 chase")
    -- ★ scheduler.tasks 是「协程 -> Task」的**哈希表**（键是协程对象），
    --   所以不能用 # 取长度（对非数组表 # 结果无意义，通常是 0），必须自己数。
    local running = 0
    for _ in pairs(schedM.scheduler.tasks) do running = running + 1 end
    check(running >= 1, string.format("AI 协程应仍在运行，实际 %d 个", running))

    -- 实体销毁后 AI 协程应被一并清掉（防泄漏：KillThreadsWithID 按 GUID 归��）
    w:RemoveEntity(hound)
    w:Step()
    check(hound._removed, "hound 应被销毁")
    local left = 0
    for _ in pairs(schedM.scheduler.tasks) do left = left + 1 end
    check(left == 0,
        string.format("实体销毁后 AI 协程应被清除，实际剩 %d 个", left))

    schedM.StopAllThreads()
    print("  [OK] 状态机在世界主循环中运行 + 销毁时协程自动回收")
end

function T.run()
    print("=== 08_statemachine.lua 自测 ===")
    T.basicGraph()
    T.transitions()
    T.sharedStates()
    T.houndAI()
    T.inWorld()
    sched.StopAllThreads()
    print("08_statemachine 全部通过\n")
    return true
end

M.test = T

--============================================================
-- 六、导出
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