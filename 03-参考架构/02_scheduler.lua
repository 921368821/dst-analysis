--============================================================
-- 文件：02_scheduler.lua
-- 模块：核心框架 / 任务调度
-- 职责：基于 tick 的协程调度器。实现 DoTaskInTime / DoPeriodicTask /
--       StartThread / Sleep / Hibernate / Wake / KillThreadsWithID。
--       全游戏的协程（行为、动画、状态图）都由它驱动。
--
-- 【本模块的三个关键设计，务必理解】
--
-- 1) 绝对 tick 桶，而不是「相对延迟」
--    waitingfortick[tick] / attime[tick] 都以「绝对 tick 序号」为键。
--    为什么重要：若用「再等 N 帧」的链式相对延迟，每帧的浮点误差会
--    一层层累积，表现为周期任务越跑越偏（drift）。
--    用绝对 tick，误差永远是「定位到最近的整 tick」而非「累加」。
--
-- 2) id 自动继承（归属管理）
--    StartThread(fn) 不传 id 时，自动继承**当前协程的 id**。
--    于是「一个任务里派生的所有子任务」自动归属于同一个实体。
--    实体销毁时 KillThreadsWithID(guid) 一次全灭 —— 这是防协程泄漏的关键。
--    移植到任何引擎都必须实现等价机制。
--
-- 3) 周期任务的 drift 防护
--    ExecutePeriodic 每次执行完，是用「**当前时刻 + period**」重算下次 tick，
--    而不是「上次 nexttick + period」。
--    后果：即使某一帧卡顿 200ms 错过了几个周期，也不会追帧堆积，
--    而是保持「每 period 至多执行一次」的语义（宁可少执行，不可堆积）。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》scripts/scheduler.lua
-- 兼容性：Lua 5.1 / 5.3 / 5.4（unpack 在 5.2+ 是 table.unpack，已做兼容处理）
--============================================================

local Class = require("01_class").Class

local M = {}

--============================================================
-- 零、常量与时钟
--============================================================

-- 两个特殊的 yield 值。协程 yield 时若返回这两个常量，调度器会给特殊待遇，
-- 而不是简单地「下一帧继续」。
local HIBERNATE = "hibernate"
local SLEEP = "sleep"

-- 固定步长：30Hz，与原版 FRAMES 相同。
-- 【为什么要固定步长？】固定步长让「一 tick」成为一个确定的逻辑单位，
-- 所有周期/延迟都能用整数 tick 表达，避免浮点漂移。
local FRAMES = 1 / 30
local TICK_TIME = FRAMES

-- 当前 tick 序号（整数）与模拟时间（秒）
local cur_tick = 0
local cur_time = 0

function M.GetTick() return cur_tick end
function M.GetTime() return cur_tick * TICK_TIME end
function M.GetTickTime() return TICK_TIME end
--【GetTickTime】把秒换算成 tick 的步长。所有「秒 -> tick」的换算都要除以它。

function M.GetTimeForTick(tick) return tick * TICK_TIME end

-- 供 07_world 的主循环推进时钟用。真实 DST 里这些由 C++ 引擎驱动。
function M.AdvanceTick()
    cur_tick = cur_tick + 1
    cur_time = cur_tick * TICK_TIME
    return cur_tick
end

function M.SetTick(t) cur_tick = t end
function M.ResetTime() cur_tick = 0; cur_time = 0 end

--============================================================
-- 一、Task：协程任务
--============================================================

local taskguid = 0
local coroutine_ = coroutine
local unpack_ = table.unpack or unpack   -- 5.2+ 移到 table.unpack

local Task = Class(function(self, fn, id, param)
    self.guid = taskguid
    taskguid = taskguid + 1
    self.param = param
    --【param】传给协程首次 resume 的参数，协程里通过 COROUTINE_PARAM 拿到。
    self.id = id
    --【id】任务归属标识，用于批量管理，是防泄漏的关键。
    --      实体创建任务时传入自己的 GUID，实体销毁时 KillThreadsWithID(guid) 一次清空。
    self.fn = fn
    self.co = coroutine_.create(fn)
    --【co】真正的执行体。Lua 协程是「分段执行」：从头跑到第一个 yield 挂起，
    --       下次从 yield 处继续。所以一个 fn 可能横跨多帧。
    self.list = nil
    --【list】当前所在的集合，指向 running/waking/waitingfortick/hibernating 之一。
    --       协程在哪个集合里，决定它什么时候被调度。
end)

function Task:SetList(list)
    --【移动自己到另一个集合】调度器的核心操作。
    --   先从旧集合移除、再加入新集合，实现「改挂载」而非「复制」。
    if self.list then
        self.list[self.guid] = nil
    end
    if list then
        list[self.guid] = self
    end
    self.list = list
end

function Task:__tostring()
    return string.format("TASK %s", tostring(self.id))
end

--============================================================
-- 二、Periodic：周期任务
--============================================================

local Periodic = Class(function(self, fn, period, limit, id, nexttick, ...)
    self.fn = fn
    self.id = id
    self.period = period
    --【period】周期，单位是秒（DoPeriodicTask 的第一个参数）。
    self.limit = limit
    --【limit】剩余执行次数。nil 表示无限；每次 OnTick 后减 1，归零则结束。
    self.nexttick = nexttick
    --【nexttick】下次执行的**绝对 tick**。是「绝对时间」而非「相对延迟」，
    --             这让周期任务不会因帧耗时波动而累积漂移。
    self.list = nil
    self.onfinish = nil
    --【onfinish】周期结束（或被 Cancel）时的回调。
    --            最易错处：Cancel 会主动调 onfinish(periodic, false, ...)
    --            正常跑完则调 onfinish(periodic, true, ...)。第二参数是「是否正常完成」。
    self.arg = { ... }
end)

function Periodic:Cancel()
    --【取消周期任务】与 Cleanup 的区别：Cancel 会触发 onfinish（传 false），
    --   供业务代码做「提前中止」的清理。Cleanup 是静默清理。
    self.limit = 0
    if self.list then
        self.list[self] = nil
        self.list = nil
    end

    if self.onfinish then
        if #self.arg > 0 then
            self.onfinish(self, false, unpack_(self.arg))
        else
            self.onfinish(self, false)
        end
        self.onfinish = nil
    end

    self.fn = nil
    self.arg = nil
    self.nexttick = nil
    --【主动断引用】清掉闭包持有的引用，避免被取消的周期任务
    --   因闭包捕获了实体而阻止 GC。这是防泄漏的第二道防线。
end

function Periodic:NextTime()
    return self.nexttick and M.GetTimeForTick(self.nexttick) or nil
end

function Periodic:Cleanup()
    --【静默清理】周期自然结束后的收尾。与 Cancel 不同，不触发 onfinish。
    self.limit = 0
    if self.list then
        self.list[self] = nil
        -- 置 nil 而不是留下空表：如果外部还持有对这个 Periodic 的引用，
        -- 不希望它反过来把整个 list（可能很大）一直钉在内存里。
        self.list = nil
    end
    self.onfinish = nil
    self.fn = nil
    self.arg = nil
    self.nexttick = nil
end

function Periodic:__tostring()
    return string.format("PERIODIC %s: %f", tostring(self.id), self.period)
end

--============================================================
-- 三、桶回收池
--============================================================

local listrecycler = {}

local function GetNewList()
    --【取桶】优先从回收池拿，没有才新建。避免频繁 GC。
    local numre = #listrecycler
    if numre > 0 then
        local list = listrecycler[numre]
        table.remove(listrecycler)
        return list
    end
    return {}
end

--============================================================
-- 四、Scheduler 本体
--============================================================

local Scheduler = Class(function(self, isstatic)
    self.tasks = {}
    --【task -> Task】以协程对象为键的索引表。用来反查「这个协程属于哪个任务」，
    --            通过 coroutine.running() 可查到自己所属的 Task，从而拿到 id，
    --            实现 GetCurrentTask() 与 id 继承。
    self.running = {}
    --【本帧要跑的协程】键是 task.guid。
    self.waitingfortick = {}
    --【tick -> {task,...}】按绝对 tick 索引的睡眠中任务。
    self.waking = {}
    --【刚被唤醒，待迁移】单独一个集合是为了避免「边遍历边改」。
    self.hibernating = {}
    --【冬眠中】Hibernate() 让协程完全停摆，不参与任何调度，直到 Wake()。
    self.attime = {}
    --【tick -> {periodic -> true}】按绝对 tick 索引的周期任务。
    self.isstatic = isstatic or nil
end)
--【调度器的五个集合，构成了整个任务系统的状态机】
--   waitingfortick --(到达 tick)--> waking --> running --(yield Hibernate)--> hibernating
--                                                                --(yield Sleep(n))--> waitingfortick
--   running --(协程结束)--> 被移除
--
--   ★ 设计要点：attime 与 waitingfortick 都以「绝对 tick」为键，
--     而非「再等几帧」的相对延迟。即使某帧耗时波动，周期任务也不会
--     像 Sleep(1) 那样累积漂移。

function Scheduler:__tostring()
    local numrun, numtasks = 0, 0
    for _ in pairs(self.running) do numrun = numrun + 1 end
    for _ in pairs(self.tasks) do numtasks = numtasks + 1 end
    -- 排查协程泄漏时看这个数：如果持续增长，说明有协程没被正确 Kill。
    return string.format("Running Tasks: %d/%d", numrun, numtasks)
end

function Scheduler:KillTask(task)
    --【彻底杀死一个任务】从所有索引移除，断开协程引用。
    task:SetList(nil)
    if task.co then
        self.tasks[task.co] = nil
        task.co = nil
        --【置 nil】断开协程对象。协程一旦被 GC，其闭包捕获的实体也随之释放。
    end
end

function Scheduler:AddTask(fn, id, param)
    local task = Task(fn, id, param)
    self.tasks[task.co] = task
    task:SetList(self.running)
    --【新任务直接进 running】下次 Run() 就会执行它。
    return task
end

--============================================================
-- 五、调度器主流程
--============================================================

function Scheduler:OnTick(tick)
    --【每 tick 的第一阶段：处理定时唤醒与周期任务】

    -- 断言：不能有过去的时间桶还没被清理。
    -- 如果这个断言失败，说明某个 Sleep 的任务被遗忘了（泄漏）。
    -- 开发期极有价值的自检——能立刻暴露「任务卡在过去的 tick 里」。
    for k in pairs(self.waitingfortick) do
        assert(k >= tick, "waitingfortick has a stale bucket (leak!)")
    end

    if self.waitingfortick[tick] ~= nil then
        for _, v in pairs(self.waitingfortick[tick]) do
            v:SetList(self.waking)
        end
        --【回收空桶】这个 tick 的任务都搬走了，桶可以复用。
        table.insert(listrecycler, self.waitingfortick[tick])
        self.waitingfortick[tick] = nil
    end
    --【步骤1】处理「到点醒来」的任务：waitingfortick[tick] -> waking

    -- 执行本轮 attime 回调（DoTaskInTime / DoPeriodicTask 都在这里跑）
    if self.attime[tick] ~= nil then
        -- 先取出桶并立刻置 nil。
        -- ★ 为什么立刻置 nil？—— 回调里完全可能 Cancel 自己、或 DoTaskInTime
        --   注册新的任务挂到当前 tick。如果还持有这个桶的引用，
        --   pairs 正在遍历它时改动就会漏掉新项甚至崩溃。原版是先遍历后置 nil，
        --   但这里我们采用更安全的「先摘出再遍历」。
        local bucket = self.attime[tick]
        self.attime[tick] = nil

        for k, v in pairs(bucket) do
            -- 注意 k 是 Periodic 对象本身，v 恒为 true
            if v then
                --【already_dead】上一帧已被 Cancel（limit=0）但还挂在桶里。
                -- 必须检查，否则会对已取消的任务再调一次 fn —— 这是真实存在的坑。
                local already_dead = k.limit and k.limit == 0

                if not already_dead and k.fn then
                    if #k.arg > 0 then
                        k.fn(unpack_(k.arg))
                    else
                        k.fn()
                    end
                end
                --【步骤2】执行回调。注意此时 k 可能已被回调内部 Cancel。

                if k.limit then
                    k.limit = k.limit - 1
                end
                --【步骤3】次数递减。

                if not k.limit or k.limit > 0 then
                    --【步骤4】还有剩余次数 -> 挂到下个周期的 tick 桶
                    -- ★ 用「当前时刻 + period」重算，而非「nexttick + period」。
                    --   这样即使某帧卡顿、错过几个周期，也不会追帧堆积，
                    --   而是保持「每 period 至多执行一次」的语义。
                    local list, nexttick = self:GetListForTimeFromNow(k.period)
                    list[k] = true
                    k.list = list
                    k.nexttick = nexttick
                else
                    if k.onfinish and not already_dead then
                        if #k.arg > 0 then
                            k.onfinish(k, true, unpack_(k.arg))
                        else
                            k.onfinish(k, true)
                        end
                        k.onfinish = nil
                    end
                    k:Cleanup()
                    --【步骤5】次数耗尽 -> 触发 onfinish(true) 并静默清理
                end
            end
        end
    end
end

function Scheduler:Run()
    --【每 tick 的第二阶段：真正 resume 协程】

    for k, v in pairs(self.waking) do
        v:SetList(self.running)
    end
    self.waking = {}
    --【步骤1】把刚醒的迁入 running。
    --   换新表 {} 而非清空原表，是为了不在遍历 self.waking 时改它。

    for k, v in pairs(self.running) do
        if v.co == nil or coroutine_.status(v.co) == "dead" then
            -- 任务已结束，收尸。
            -- ★ 原版此处有个笔误：写的是 `task:SetList(nil)` 但循环变量是 v，
            --   若 task 是未定义的全局(nil) 会抛异常。
            --   实际不可达（Task 由 coroutine.create 构造，resume 前状态恒为 suspended），
            --   所以从未暴露。这里写正确的 v:SetList(nil)，并注明原版问题。
            v:SetList(nil)
            self.tasks[v.co] = nil
        else
            local success, yieldtype, yieldparam = coroutine_.resume(v.co, v.param)
            --【★ 最重要的机制在这里】resume 协程，它会一直跑到下一个 yield。
            --   一个 yield 之前的代码在「同一帧」内同步执行完，
            --   所以 yield 之间的逻辑是原子的（不可被打断）。

            if success and coroutine_.status(v.co) ~= "dead" then
                if yieldtype == HIBERNATE then
                    v:SetList(self.hibernating)
                    --【冬眠】不再被调度，需 Wake() 显式唤醒。
                elseif yieldtype == SLEEP then
                    yieldparam = math.floor(yieldparam)
                    local list = self.waitingfortick[yieldparam]
                    if not list then
                        list = GetNewList()
                        self.waitingfortick[yieldparam] = list
                    end
                    v:SetList(list)
                    --【睡眠】挂到目标 tick 的桶里，等 OnTick 把它捞出来。
                end
                -- 注意：若 yieldtype 为 nil，说明是裸 yield（如 Yield()），
                -- 此时任务仍在 running 列表中，下帧继续 resume。
            else
                v:SetList(nil)
                v.retval = yieldtype
                if not success then
                    --【协程崩溃】打印完整调用栈并立即杀掉。
                    -- ★ 原版这里直接 return —— 会中断整个 Run 循环，
                    --   意味着同一帧剩余的所有任务都不执行。
                    --   移植时建议改为「记录错误后继续」，避免单点崩溃拖垮整帧。
                    --   本教学版打印错误后**继续处理其余任务**（更健壮）。
                    print("[scheduler] COROUTINE " .. tostring(v.id) .. " CRASH: " .. tostring(yieldtype))
                    if debug and debug.traceback then
                        print(debug.traceback(v.co, "\nCOROUTINE STACK:\n"))
                    end
                    self:KillTask(v)
                else
                    self:KillTask(v)
                    --【正常结束】协程已 dead，收尸。
                end
            end
        end
    end
end

function Scheduler:KillAll()
    --【清空所有任务】世界卸载、退出游戏时调用。
    self.tasks = {}
    self.hibernating = {}
    self.running = {}
    self.waitingfortick = {}
    self.waking = {}
    self.attime = {}
end

-- 按谓词批量移除。Lua 没有 filter，就自己写。
local function removeif(tab, fn)
    for k, v in pairs(tab) do
        if fn(v) then
            tab[k] = nil
        end
    end
end

--============================================================
-- 六、注册 API：ExecuteInTime / ExecutePeriodic
--============================================================

function Scheduler:GetListForTimeFromNow(dt)
    --【计算未来某个 tick 的桶】
    local nowtick = M.GetTick()
    local wakeuptick = math.ceil((M.GetTime() + dt) / TICK_TIME - 0.0001)
    --【★ -0.0001 的技巧】tick 是浮点时间除以步长。
    --   如果正好整除（如 30 秒 / (1/30) = 900），不减 epsilon 会因浮点误差
    --   算出 900.0000001，ceil 后变 901 —— 任务晚一帧。
    --   减掉微小 epsilon 保证「刚好到期」时不多等一帧。
    --   ★ 这类浮点边界处理在自研调度器里必须注意，是最容易藏 bug 的地方。

    if wakeuptick <= nowtick then
        wakeuptick = nowtick + 1
        --【保底】至少下一帧，绝不在当前帧执行（否则会递归/顺序错乱）。
    end

    local list = self.attime[wakeuptick]
    if not list then
        list = {}
        self.attime[wakeuptick] = list
    end
    return list, wakeuptick
end

function Scheduler:ExecuteInTime(timefromnow, fn, id, ...)
    --【延时执行一次】本质是 limit=1 的周期任务。
    --  ★ 这就是 DoTaskInTime 的实现。
    return self:ExecutePeriodic(timefromnow, fn, 1, nil, id, ...)
end

function Scheduler:ExecutePeriodic(period, fn, limit, initialdelay, id, ...)
    --【注册周期任务】这就是 DoPeriodicTask 的实现。
    local list, nexttick = self:GetListForTimeFromNow(initialdelay or period)
    local periodic = Periodic(fn, period, limit, id, nexttick, ...)
    list[periodic] = true
    periodic.list = list
    return periodic
    --【★ 使用关键】返回 Periodic 对象。调用方应保存它，以便之后 Cancel()。
    -- ★★ 真实陷阱（原版注释的 A 类 bug）：
    --   如果回调函数内部 yield（例如调了 Sleep），协程会挂起，
    --   但 Periodic 已经挂进了下一个 tick 桶 —— 于是下次周期到点时，
    --   调度器会再次调 fn，而上一次的协程还挂着。
    --   后果：周期漂移 + 协程泄漏。
    --   规避：周期任务的回调内禁止 yield；或改用「self.nexttime = current + period」
    --   的自调度写法。
end

--============================================================
-- 七、KillThreadsWithID —— 防泄漏核心 API
--============================================================

function Scheduler:KillTasksWithID(id)
    --【★ 批量杀任务 —— 防泄漏的核心 API】
    --   实体销毁时，该实体上所有 StartThread 创建的协程都用同一个 id（实体 GUID），
    --   一次性干掉。这是 DST 处理协程归属的标准手法。
    --   ★ 移植时务必照抄这个模式（配合实体 OnRemoveFromEntity）。
    local function pred(task) return task.id == id end

    removeif(self.tasks, pred)
    removeif(self.hibernating, pred)
    removeif(self.running, pred)
    removeif(self.waking, pred)

    -- waitingfortick 的结构是 tick -> {task}，所以要多遍历一层。
    for _, v in pairs(self.waitingfortick) do
        removeif(v, pred)
    end
    -- attime 的结构是 tick -> {periodic -> true}，key 是 Periodic 本身。
    for _, v in pairs(self.attime) do
        for k, alive in pairs(v) do
            if alive and k.id == id then
                -- 周期任务要先 Cancel（触发 onfinish 的取消分支）再移除，
                -- 否则业务代码的清理逻辑不会执行。
                k:Cancel()
                v[k] = nil
            end
        end
    end
    -- 注意：这里只移除了任务，没有调 Task:SetList(nil)，
    -- 所以被移除的任务对象自身仍持有 list 引用。好在 Task 被置出后若无其他引用即可被 GC。
end

function Scheduler:GetCurrentTask()
    --【获取当前协程所属的任务】coroutine.running() 在协程内返回自身。
    --   有了它才能实现「子任务自动继承父任务 id」。
    local co = coroutine_.running()
    return self.tasks[co]
end

function Scheduler:GetTaskCount()
    local n = 0
    for _ in pairs(self.tasks) do n = n + 1 end
    return n
end

-- ★ 必须在此处（任何引用它们的函数之前）声明 local，
--   否则下面的 GetCurrentScheduler / M.StartThread 等函数会把 scheduler
--   解析成**全局变量**而不是闭包变量。能跑但极其脆弱 —— 一旦有人
--   在 require 顺序上做调整就会静默变成 nil。
-- 两个全局调度器实例（真实 DST 也是这么做的）：
--   scheduler        —— 常规任务（受游戏暂停/加速影响）
--   staticScheduler  —— 静态任务（永远按真实时间走，用于 UI 等）
-- 这种「双时钟」设计让 UI 在游戏暂停时仍然能动，是个很实用的技巧。
local scheduler = Scheduler()
local staticScheduler = Scheduler(true)
M.scheduler = scheduler
M.staticScheduler = staticScheduler

--============================================================
-- 八、协程内的 yield 函数（只能在协程里调）
--============================================================

-- 自动识别当前协程归属哪个调度器，避免调用方自己记着区分。
local function GetCurrentScheduler()
    local co = coroutine_.running()
    if scheduler.tasks[co] then
        return scheduler
    elseif staticScheduler.tasks[co] then
        return staticScheduler
    end
end

function M.Wake()
    --【从冬眠中唤醒当前协程】
    local sch = GetCurrentScheduler()
    if not sch then return end
    local task = sch.tasks[coroutine_.running()]
    if task then
        task:SetList(sch.running)
        -- ★ 注意：Wake 后不会立即 resume，要等下一次 Run()。
        --   若在 HIBERNATE 之后紧接着写代码，逻辑会延迟到下一帧才继续。
    end
end

function M.Hibernate()
    --【让协程完全停摆】彻底停止调度，直到 Wake()。
    -- 典型用途：暂停的 AI（远离玩家时）、暂停的动画。
    coroutine_.yield(HIBERNATE)
end

function M.Yield()
    --【裸 yield】下一帧继续。
    -- 实际开发中会浪费性能，应优先用 Sleep(帧数)。
    coroutine_.yield()
end

function M.Sleep(time)
    --【睡眠指定时间】time 单位是**秒**（不是 tick）。
    local sch = GetCurrentScheduler()
    if not sch then return end
    local desttick = math.ceil((M.GetTime() + time) / TICK_TIME)
    if M.GetTick() < desttick then
        coroutine_.yield(SLEEP, desttick)
        -- 会睡：挂到目标 tick 桶
    else
        coroutine_.yield()
        -- 时间已到或已过期：退化为裸 yield（下一帧继续，不睡）
    end
end

function M.KillThread(task)
    --【杀单个任务】自动识别它在哪个调度器里。
    if scheduler.tasks[task.co] then
        scheduler:KillTask(task)
    elseif staticScheduler.tasks[task.co] then
        staticScheduler:KillTask(task)
    end
end

function M.WakeTask(task)
    --【从冬眠中唤醒指定任务】与 Wake 的区别：Wake 给「自己」用，
    --   这个给「别人」用（例如让另一个实体唤醒它的任务）。
    if task then
        if scheduler.tasks[task.co] then
            task:SetList(scheduler.running)
        elseif staticScheduler.tasks[task.co] then
            task:SetList(staticScheduler.running)
        end
    end
end

function M.StartThread(fn, id, param)
    --【★ 启动协程任务 —— 游戏里最常用的 API】
    if id == nil then
        local task = scheduler:GetCurrentTask()
        if task ~= nil then
            id = task.id
        end
        --【★ id 继承机制】若调用者没给 id，自动继承「当前协程的 id」。
        --   效果：一个任务里启动的所有子任务，都归属于同一个实体。
        --   于是实体销毁时 KillThreadsWithID(entity_guid) 能一次全灭。
        --   ★ 这正是防协程泄漏最优雅的设计，移植时务必实现等价机制。
    end
    return scheduler:AddTask(fn, id, param)
end

--============================================================
-- 九、驱动入口
--============================================================

function M.RunScheduler(tick)
    --【每 tick 调用一次：驱动常规调度器】
    scheduler:OnTick(tick)
    scheduler:Run()
end

function M.KillThreadsWithID(id)
    --【按归属批量杀任务】实体销毁时调用。
    scheduler:KillTasksWithID(id)
    staticScheduler:KillTasksWithID(id)
end

function M.StopAllThreads()
    --【停掉一切】退出游戏 / 重载世界时调用。
    scheduler:KillAll()
    staticScheduler:KillAll()
end

--============================================================
-- 十、自测
--============================================================

local T = {}
local function check(ok, msg)
    if not ok then error("[02_scheduler] 断言失败: " .. msg, 2) end
end

-- 跑 N 个 tick（每个 tick 先推时钟，再驱动调度器）
local function runTicks(n)
    for _ = 1, n do
        M.AdvanceTick()
        M.RunScheduler(M.GetTick())
    end
end

--- 测试 1：DoTaskInTime 延时一次
function T.doTaskInTime()
    M.ResetTime(); M.StopAllThreads()
    local fired_at = nil
    M.DoTaskInTime(1.0, function() fired_at = M.GetTick() end, "timer1")
    -- 跑了 29 tick（还没到 1 秒 = 30 tick）不应触发
    runTicks(29)
    check(fired_at == nil, "DoTaskInTime 未到期前不应触发")
    -- 第 30 tick 时应触发
    runTicks(1)
    check(fired_at == 30, string.format("DoTaskInTime 应在 tick 30 触发，实际 %s", tostring(fired_at)))
    print("  [OK] DoTaskInTime 绝对 tick 触发")
end

--- 测试 2：DoPeriodicTask 周期性 & drift 防护
function T.doPeriodicTask()
    M.ResetTime(); M.StopAllThreads()
    local count = 0
    local fired_ticks = {}
    -- 周期 0.5 秒 = 15 tick，跑 300 tick 期望触发约 20 次
    local task = M.DoPeriodicTask(0.5, function()
        count = count + 1
        table.insert(fired_ticks, M.GetTick())
    end, nil, nil, "per1")   -- (period, fn, limit=无限, initialdelay=默认, id="per1")
    runTicks(300)
    task:Cancel()
    check(count > 0, "DoPeriodicTask 应被触发")
    -- drift 检查：每次间隔应严格等于 15 tick（相对调度会因误差逐渐偏移）
    local min_gap, max_gap = 999999, 0
    for i = 2, #fired_ticks do
        local gap = fired_ticks[i] - fired_ticks[i - 1]
        if gap < min_gap then min_gap = gap end
        if gap > max_gap then max_gap = gap end
    end
    check(min_gap == 15 and max_gap == 15,
        string.format("周期任务不应漂移，间隔应恒为 15 tick，实际 [%d..%d]", min_gap, max_gap))
    print(string.format("  [OK] DoPeriodicTask 无漂移（%d 次触发，间隔恒 15 tick）", count))
end

--- 测试 3：id 自动继承
function T.idInheritance()
    M.ResetTime(); M.StopAllThreads()
    local child_id = nil
    M.StartThread(function()
        -- 这里没有显式传 id，应该自动继承 "parent_entity"
        M.StartThread(function()
            child_id = scheduler:GetCurrentTask().id
            M.Sleep(0.1)
        end)
        M.Sleep(0.05)
    end, "parent_entity")
    runTicks(3)
    check(child_id == "parent_entity",
        string.format("子任务应继承父任务 id，实际 %s", tostring(child_id)))
    print("  [OK] StartThread 的 id 自动继承")
end

--- 测试 4：KillThreadsWithID 批量清理
function T.killThreadsWithID()
    M.ResetTime(); M.StopAllThreads()
    -- 为同一个 id 造 3 个任务：1 个运行中、1 个睡眠中、1 个冬眠中
    M.StartThread(function() while true do M.Sleep(0.1) end end, "ENT1")   -- 睡眠中
    M.StartThread(function() while true do M.Hibernate() end end, "ENT1")  -- 冬眠中
    M.StartThread(function() while true do M.Yield() end end, "ENT1")      -- 运行中
    -- 另一个 id 的任务不应被误杀
    local ent2_alive = false
    M.StartThread(function() while true do M.Sleep(0.1) end end, "ENT2")

    runTicks(3)
    check(scheduler:GetTaskCount() == 4, "应有 4 个任务")

    M.KillThreadsWithID("ENT1")  -- 一次清空 ENT1 的所有任务
    check(scheduler:GetTaskCount() == 1, string.format("KillThreadsWithID 后只剩 ENT2 的 1 个任务，实际 %d", scheduler:GetTaskCount()))

    -- 验证 ENT2 还活着
    M.StartThread(function()
        ent2_alive = (scheduler:GetTaskCount() > 0)
    end, "probe")
    runTicks(1)
    check(ent2_alive, "ENT2 的任务不应被 ENT1 的 Kill 误伤")
    M.KillThreadsWithID("ENT2")
    print("  [OK] KillThreadsWithID 批量清理（含睡眠/冬眠/运行三态）")
end

--- 测试 5：Hibernate / Wake
function T.hibernateWake()
    M.ResetTime(); M.StopAllThreads()
    local steps = 0
    M.StartThread(function()
        steps = 1
        M.Hibernate()      -- 冬眠
        steps = 2          -- 被 Wake 后继续
        M.Sleep(0.1)
    end, "hib")
    runTicks(2)
    check(steps == 1, "Hibernate 后应停在 yield 处")

    -- 从外部唤醒这个任务：按 id 在 scheduler.tasks 里找到它
    local found
    for _, t in pairs(scheduler.tasks) do
        if t.id == "hib" then found = t end
    end
    check(found ~= nil, "应能按 id 找到冬眠中的任务")
    M.WakeTask(found)
    runTicks(1)
    check(steps == 2, "Wake 后任务应恢复执行")
    print("  [OK] Hibernate / Wake 停摆与恢复")
end

--- 统一入口
function T.run()
    print("=== 02_scheduler.lua 自测 ===")
    T.doTaskInTime()
    T.doPeriodicTask()
    T.idInheritance()
    T.killThreadsWithID()
    T.hibernateWake()
    M.StopAllThreads()
    print("02_scheduler 全部通过\n")
    return true
end

M.test = T

--============================================================
-- 十一、导出
--============================================================

-- 把调度器实例挂到全局，便于测试与其它模块引用
_G.scheduler = scheduler
_G.staticScheduler = staticScheduler

-- 全局风格的 API（与原版一致，便于对照阅读）
-- 【全局风格 API（与原版 scheduler.ExecutePeriodic 签名完全一致）】
-- ★ 参数位置容易踩坑，这里写清楚：
--     DoPeriodicTask(period, fn, limit, initialdelay, id, ...)
--        period       —— 周期，单位秒
--        limit        —— 执行次数上限，nil = 无限次
--        initialdelay —— 首次延迟，默认等于 period
--        id           —— 归属标识，省略时自动继承当前协程的 id
--     注意「实体上的 API」签名是不同的：inst:DoPeriodicTask(time, fn, initialdelay, ...)
--     —— 它没有 limit/id 参数，id 由实体自动填成自己的 GUID（见 03_entity）。
_G.DoTaskInTime = function(time, fn, id, ...)
    -- DoTaskInTime(time, fn, id, ...)：延时一次，等价于 limit=1 的周期任务
    return scheduler:ExecuteInTime(time, fn, id, ...)
end
_G.DoPeriodicTask = function(period, fn, limit, initialdelay, id, ...)
    return scheduler:ExecutePeriodic(period, fn, limit, initialdelay, id, ...)
end
_G.StartThread = M.StartThread
_G.Sleep = M.Sleep
_G.Hibernate = M.Hibernate
_G.Wake = M.Wake
_G.Yield = M.Yield
_G.KillThread = M.KillThread
_G.WakeTask = M.WakeTask
_G.KillThreadsWithID = M.KillThreadsWithID

M.DoTaskInTime = _G.DoTaskInTime
M.DoPeriodicTask = _G.DoPeriodicTask
M.StartThread = M.StartThread
M.Sleep = M.Sleep
M.Hibernate = M.Hibernate
M.Wake = M.Wake
M.Yield = M.Yield
M.KillThreadsWithID = M.KillThreadsWithID

M.TICK_TIME = TICK_TIME   -- ★ 推荐用这个名字（语义明确）
M.T = TICK_TIME           -- 原版里的别名，保留以便对照
M.FRAMES = FRAMES
M.HIBERNATE = HIBERNATE
M.SLEEP = SLEEP
M.Scheduler = Scheduler
M.Task = Task
M.Periodic = Periodic
M.test = T

-- 【独立运行检测】
--   不能用 `... == nil`：Lua 5.1 的主 chunk 是 vararg 函数，顶层 `...` 合法；
--   但 5.2+ 用 load 编译的 chunk 不是 vararg 函数，顶层 `...` 是**语法错误**。
--   改用「源文件名 == 命令行入口参数」判断，兼容 5.1 ~ 5.5。
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