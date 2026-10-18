--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：scheduler.lua
-- 模块：核心框架 / 任务调度
-- 职责：基于 tick 的协程调度器。实现 DoTaskInTime / DoPeriodicTask /
--       StartThread / Sleep / Hibernate 等延时与周期任务的底层机制。
--       全游戏的协程（行为、动画、状态图）都由此驱动。
-- 关键符号：Scheduler, Task, Periodic, scheduler, staticScheduler,
--           StartThread, Sleep, Hibernate, KillThreadsWithID
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("class")

HIBERNATE = "hibernate"
SLEEP = "sleep"
--【两个特殊的 yield 值】协程 yield 时若返回这两个常量，调度器会给它特殊待遇，
--   而不是简单地下一帧继续。见 Scheduler:Run()。

local function GetSchedulerTick(isstatic)
    return isstatic and GetStaticTick() or GetTick()
end
--【两个时钟】游戏有两套时间：
--   GetTick()/GetTime() —— 正常游戏时钟，受暂停、加速影响
--   GetStaticTick()/GetStaticTime() —— "静态"时钟，永远按真实时间走，
--                                    用于 UI 动画等不受游戏暂停影响的场合
--   两套调度器（scheduler / staticScheduler）因此完全独立。

local function GetSchedulerTime(isstatic)
    return isstatic and GetStaticTime() or GetTime()
end

----------------------------------------------------------------------------------
local coroutine = coroutine
local debug = debug

-------------------------------
local taskguid = 0
--【任务全局计数器】用于调试时标识任务。Lua 5.1 没有内置任务 ID。

local Task = Class( function(self, fn, id, param)
    self.guid = taskguid
    taskguid = taskguid + 1
    self.param = param
    --【param】传给协程首次 resume 的参数。即 StartThread(fn, id, param) 的 param，
    --        在协程里通过 COROUTINE_ID/COROUTINE_PARAM 或函数参数拿到。
    self.id = id
    --【id】任务的归属标识，用于批量管理。这是防泄漏的关键：
    --       实体创建任务时传入自己的 GUID（或实体 ID），
    --       实体销毁时调用 KillThreadsWithID(guid) 一次性干掉所有相关协程。
    --       参见 entityscript.lua 中 OnRemoveFromEntity 里的清理逻辑。
    self.fn = fn
    self.co = coroutine.create(fn)
    --【核心】真正的执行体。Lua 协程是"分段执行"的：
    --       从头跑到第一个 yield 挂起，下次从 yield 处继续。
    --       所以一个 fn 可能横跨多帧。
    self.list = nil
    --【当前所在的集合】指向 running/hibernating/waitingfortick/waking 之一。
    --              协程在哪个集合里，决定它什么时候被调度。
end)

function Task:__tostring()
    return string.format("TASK %s:", tostring(self.id))
end

function Task:SetList(list)
    --【移动自己到另一个集合】这是调度器的核心操作。
    --   注意先从旧集合移除、再加入新集合，实现"改挂载"而非"复制"。
    if self.list then
        self.list[self.guid] = nil
    end
    if list then
        list[self.guid] = self
    end
    self.list = list
end

-------------------------------
Periodic = Class(function(self, fn, period, limit, id, nexttick, ...)
    self.fn = fn
    self.id = id
    --【id】同样用于归属管理。DoPeriodicTask 的 onfinish 回调靠它配对。
    self.period = period
    --【period】周期，单位是 tick（1/30 秒）。period=1 表示每帧。
    self.limit = limit
    --【limit】剩余执行次数。nil 表示无限次；每次 OnTick 后减 1，归零则结束。
    self.nexttick = nexttick
    --【nexttick】下次执行的绝对 tick 值。是"绝对时间"而非"相对延迟"，
    --             这让周期任务不会因帧耗时波动而累积漂移。
    self.list = nil
    self.onfinish = nil
    --【onfinish】周期结束（或被 Cancel）时的回调。
    --            这是最容易出错的地方：Cancel 会主动调 onfinish(periodic, false, ...)，
    --            正常跑完则调 onfinish(periodic, true, ...)。第二参数是"是否正常完成"。
    self.arg = toarrayornil(...)
    --【arg】变长参数打包成数组，回调时 unpack 出来。
end)

function Periodic:Cancel()
    --【取消周期任务】与 Cleanup 的区别：Cancel 会触发 onfinish（传 false），
    --   供业务代码做"提前中止"的清理。Cleanup 是静默清理。
    self.limit = 0
    if self.list then
        self.list[self] = nil
        self.list = nil
    end

    if self.onfinish then
        if self.arg then
            self.onfinish(self, false, unpack(self.arg))
        else
            self.onfinish(self, false)
        end
        self.onfinish = nil
    end

    self.fn = nil
    self.arg = nil
    self.nexttick = nil
    --【主动断引用】把闭包持有的引用清掉，避免被取消的周期任务因为
    --   闭包捕获了实体而阻止 GC 回收。这是防泄漏的第二道防线。
end

function Periodic:NextTime()
    return self.nexttick and GetTimeForTick(self.nexttick) or nil
end
--【查询下次执行时刻】换算成真实时间，供调试面板显示。

function Periodic:Cleanup()
    --【静默清理】周期自然结束后的收尾。与 Cancel 不同，不触发 onfinish。
    self.limit = 0
    --- if someone keeps a reference to us let it not be us keeping the list alive
    if self.list then
        self.list[self] = nil
    --  not even when it's empty
        self.list = nil
    end
    --【为什么要置 nil 而不是留下空表】注释说明得很清楚：
    --   如果外部还持有对这个 Periodic 的引用，不希望它反过来把整个 list 数组
    --   （可能很大）一直钉在内存里。置 nil 断开引用链。

    self.onfinish = nil

    self.fn = nil
    self.arg = nil
    self.nexttick = nil
end

function Periodic:__tostring()
    return string.format("PERIODIC %s: %f", tostring(self.id), self.period)
end
-------------------------------

local listrecycler = {}
--【桶回收池】waitingfortick 的桶用完后不直接丢弃，回收再利用，避免频繁 GC。

local function GetNewList()
    local list = nil
    local numre = #listrecycler
    if  numre > 0 then
        list = listrecycler[numre]
        table.remove(listrecycler)
    else
        list = {}
    end
    return list
end
--【取桶】优先从回收池拿，没有才新建。

-------------------------------

local Scheduler = Class( function(self, isstatic)
    self.tasks = {}
    --【task → Task】以协程对象为键的索引表。用来反查"这个协程属于哪个任务"。
    --           通过 coroutine.running() 可以查到自己所属的 Task，
    --           从而拿到 id，实现 GetCurrentTask()。
    self.running = {}
    --【本帧要跑的协程】键是 task.guid。
    self.waitingfortick = {}
    --【tick → {task,...}】按绝对 tick 索引的睡眠中任务。
    --                 Sleep(n) 把任务挂到"第 n 个 tick 醒来"的那个桶里。
    self.waking = {}
    --【刚被唤醒，待迁移】单独一个集合是为了避免"边遍历边改"——
    --           OnTick 把醒来的任务移到这里，Run 再统一迁到 running。
    self.hibernating = {}
    --【冬眠中】Hibernate() 让协程完全停摆，不参与任何调度，
    --            直到被 Wake() 显式唤醒。用于"暂停的 AI/动画"。
    self.attime = {}
    --【tick → {periodic → true}】按绝对 tick 索引的周期任务。
    --            ExecuteInTime / ExecutePeriodic 把任务挂到未来的某个 tick 上。
    self.isstatic = isstatic or nil
end)
--【调度器的五个集合，构成了整个任务系统的状态机】
--   waitingfortick --(到达 tick)--> waking --> running --(yield Hibernate)--> hibernating
--                                                                --(yield Sleep(n))--> waitingfortick
--   running --(协程结束)--> 被移除
--
--   ★ 设计要点：attime 与 waitingfortick 都以"绝对 tick"为键，
--     而非"再等几帧"的相对延迟。这样即使某帧耗时波动，
--     周期任务也不会像 Sleep(1) 那样累积漂移。

function Scheduler:__tostring()
    --【调试输出】显示"正在运行的任务数 / 总任务数"，排查协程泄漏时很有用。
    --   如果这个数字持续增长，就是协程没被正确 Kill。
    local numrun = 0
    local numtasks = 0

    for k, v in pairs(self.running) do
        numrun = numrun + 1
    end

    for k, v in pairs(self.tasks) do
        numtasks = numtasks + 1
    end

    local str = string.format("Running Tasks: %d/%d", numrun, numtasks)

    return str
end

function Scheduler:KillTask(task)
    --【彻底杀死一个任务】从所有索引中移除，并断开协程引用。
    task:SetList(nil)
    if task.co then
        self.tasks[task.co] = nil
        task.co = nil
        --【置 nil】断开协程对象。协程一旦被 GC，其闭包捕获的实体也随之释放。
    end
end

function Scheduler:AddTask(fn, id, param)
    local task = Task(fn, id, param)
    if task.co == nil then
        print("TASK.CO is nil!")
        for k,v in pairs(task) do
            print(k,v)
        end
    end
    self.tasks[task.co] = task
    task:SetList(self.running)
    --【新任务直接进 running】下次 Run() 就会执行它。
    return task
end

function Scheduler:OnTick(tick)
    --【每tick 的第一阶段：处理定时唤醒与周期任务】
    for k,v in pairs(self.waitingfortick) do
        assert (k >= tick)
    end
    --【断言：不能有过去的时间桶还没被清理】
    --   如果这个断言失败，说明某个 Sleep 的任务被遗忘了（泄漏）。
    --   这是开发期非常有价值的自检——它能立刻暴露"任务卡在过去的 tick 里"。

    if self.waitingfortick[tick] ~= nil then
        for k, v in pairs(self.waitingfortick[tick]) do
            v:SetList(self.waking)
        end
        local list = self.waitingfortick[tick]
        table.insert(listrecycler, list)
        --【回收空桶】这个 tick 的任务都搬走了，桶可以复用。
        self.waitingfortick[tick] = nil
    end
    --【步骤1】处理"到点醒来"的任务：waitingfortick[tick] → waking

    --do our at time callbacks!
    if self.attime[tick] ~= nil then
        for k,v in pairs(self.attime[tick]) do
            --【注意 k 是 Periodic 对象本身，v 恒为 true】
            if v then
                local already_dead = k.limit and k.limit == 0
                --【already_dead】上一帧已被 Cancel（limit=0）但还挂在桶里。
                --             必须检查，否则会对已取消的任务再调一次 fn —— 这是真实存在的坑。

                if not already_dead and k.fn then
                    if k.arg then
                        k.fn(unpack(k.arg))
                    else
                        k.fn()
                    end
                end
                --【步骤2】执行本轮回调。注意此时 k 可能已被回调内部 Cancel（limit 变 0）。

                if k.limit then
                    k.limit = k.limit - 1
                end
                --【步骤3】次数递减。

                if not k.limit or k.limit > 0 then
                    local list, nexttick = self:GetListForTimeFromNow(k.period)
                    list[k] = true
                    k.list = list
                    k.nexttick = nexttick
                    --【步骤4】还有剩余次数 → 挂到下个周期的 tick 桶
                    -- ★ 注意用的是"当前时间 + period"重新计算，而不是"nexttick + period"。
                    --   这样即使某帧卡顿、错过了几个周期，也不会追帧堆积，
                    --   而是保持"每 period 至多执行一次"的语义。
                else
                    if k.onfinish and not already_dead then
                        if k.arg then
                            k.onfinish(k, true, unpack(k.arg))
                        else
                            k.onfinish(k, true)
                        end
                        k.onfinish = nil
                    end
                    k:Cleanup()
                    --【步骤5】次数耗尽 → 触发 onfinish(true) 并静默清理
                end
            end
        end
        self.attime[tick] = nil
    end
end

function Scheduler:Run()
    --【每 tick 的第二阶段：真正 resume 协程】
    for k, v in pairs(self.waking) do
        v:SetList(self.running)
    end
    self.waking = {}
    --【步骤1】把刚醒的迁入 running。
    --   这里换成新表 {} 而非清空原表，是为了不在遍历 self.waking 时改它。

    for k, v in pairs(self.running) do
        if coroutine.status(v.co) == "dead" then
            --The task is finished. kill it!
            task:SetList(nil)
            self.tasks[v.co] = nil
            --【变量名笔误】此处用了 task，循环变量其实是 v。
            --   若 task 是未定义的全局（nil），调nil:SetList() 会抛异常。
            --   ★ 但该分支实际不可达：Task 由 coroutine.create 构造，
            --     状态恒为 suspended；而此判断发生在 resume 之前。
            --     故这是防御性代码 / 死分支，笔误从未暴露。
            --   移植到强类型语言时建议直接修正为 v:SetList(nil)。
        else
            local success, yieldtype, yieldparam = coroutine.resume(v.co, v.param)
            --【★ 最重要的机制在这里】resume 协程，它会一直跑到下一个 yield。
            --   一个 yield 之前的代码在"同一帧"内同步执行完，
            --   所以 yield 之间的逻辑是原子的。

            if success and coroutine.status(v.co) ~= "dead" then
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
                --【注意】若 yieldtype 为 nil，说明是裸 yield（如 Yield()），
                --   此时任务仍在 running 列表中，下帧继续 resume。
            else
                v:SetList(nil)
                v.retval = yieldtype
                if not success then
                    print (debug.traceback(v.co, "\nCOROUTINE "..tostring(v.id).." SCRIPT CRASH:\n".. tostring(yieldtype)))
                    self:KillTask(v)
                    return
                    --【协程崩溃】打印完整调用栈并立即杀掉。
                    --   ★ 注意这里 return —— 会中断整个 Run 循环，
                    --   意味着同一帧剩余的所有任务都不执行。
                    --   移植时建议改为 continue 或记录后继续，避免单点崩溃拖垮整帧。
                end
                self:KillTask(v)
                --【正常结束】协程已 dead，收尸。
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

local function removeif(tab, fn)
    for k, v in pairs(tab) do
        if fn(v) then
            tab[k] = nil
        end
    end
end
--【按谓词批量移除】Lua 里没有 filter，就自己写。

function Scheduler:ExecuteInTime(timefromnow, fn, id, ...)
    --【延时执行一次】本质是 limit=1 的周期任务。
    return self:ExecutePeriodic(timefromnow, fn, 1, nil, id, ...)
end
--  ★ 这就是 DoTaskInTime 的实现。

function Scheduler:GetListForTimeFromNow(dt)
    --【计算未来某个 tick 的桶】
    local nowtick = GetSchedulerTick(self.isstatic)
    local wakeuptick = math.ceil((GetSchedulerTime(self.isstatic) + dt) / GetTickTime() - 0.0001) --epsilon for floating point error when used with FRAMES
    --【★ -0.0001 的技巧】tick 是浮点时间除以步长。
    --   如果正好整除（如 30 秒 / (1/30) = 900），不减去 epsilon 会因
    --   浮点误差算出 900.0000001，ceil 后变成 901 —— 任务晚了一帧。
    --   减掉微小 epsilon 保证"刚好到期"时不会多等一帧。
    --   这类浮点边界处理在自研调度器里必须注意。

    if wakeuptick <= nowtick then
        wakeuptick = nowtick+1
        --【保底】至少是下一帧，绝不在当前帧执行（否则会递归/顺序错乱）。
    end

    local list = self.attime[wakeuptick]
    if not list then
        list = {}
        self.attime[wakeuptick] = list
    end
    return list, wakeuptick
end

function Scheduler:ExecutePeriodic(period, fn, limit, initialdelay, id, ...)
    --【注册周期任务】这是 DoPeriodicTask 的实现。
    local list, nexttick = self:GetListForTimeFromNow(initialdelay or period)
    local periodic = Periodic(fn, period, limit, id, nexttick, ...)
    list[periodic] = true
    periodic.list = list
    return periodic
    --【★ 使用方式的关键】返回 Periodic 对象。
    --   调用方应保存它，以便之后调 Cancel()。
    --   ★★ 真实陷阱（见 Skill 的 bug-patterns.md A 类）：
    --   如果回调函数内部 yield（例如调用了 Sleep），协程会挂起，
    --   但 Periodic 已经挂进了下一个 tick 桶 —— 于是下次周期到点时，
    --   调度器会再次调用 fn，而此时上一次的协程还挂着。
    --   后果：周期漂移 + 协程泄漏。
    --   规避：周期任务的回调函数内禁止 yield，或改用「self.nexttime = current + period」
    --   的自调度写法（参见 components/*.lua 中的常见做法）。
end

function Scheduler:KillTasksWithID(id)
    --【★ 批量杀任务 —— 防泄漏的核心 API】
    --   实体销毁时，实体上所有 StartThread 创建的协程都用同一个 id（实体 GUID），
    --   一次性干掉。这是 DST 处理协程归属问题的标准手法，
    --   移植时务必照抄这个模式（配合 entityscript.lua 的 OnRemoveFromEntity）。
    local function pred(task) return task.id == id end

    removeif(self.tasks, pred)
    removeif(self.hibernating, pred)
    removeif(self.running, pred)
    removeif(self.waking, pred)

    for k, v in pairs( self.waitingfortick ) do
        removeif(v, pred)
    end
    --【注意】waitingfortick 的结构是 tick → {task}，所以要多遍历一层。
    -- ★ 这里只移除了任务，没有调 Periodic:Cleanup / Task:SetList(nil)，
    --   所以被移除的任务对象自身仍持有 list 引用。
    --   好在 Task 被置出后若无其他引用即可被 GC。
end

function Scheduler:GetCurrentTask()
    --【获取当前协程所属的任务】Lua 的 coroutine.running() 在协程内返回自身。
    --   有了它才能实现"子任务自动继承父任务 id"（见 StartThread）。
    local co = coroutine.running ()
    local task = self.tasks[co]
    return task
end

------------------------------------------------------------------------------------

scheduler = Scheduler()
staticScheduler = Scheduler(true)
--【两个全局调度器实例】
--   scheduler        —— 常规任务（受游戏暂停/加速影响）
--   staticScheduler  —— 静态任务（永远按真实时间走，用于 UI 等）
--   这种"双时钟"设计让 UI 在游戏暂停时仍然能动，是个很实用的技巧。

------------------------------------------------------------------------------------

--These are to be called from within a thread
--【以下函数只能在协程内部调用】

local function GetCurrentScheduler()
    local co = coroutine.running()
    if scheduler.tasks[co] then
        return scheduler
    elseif staticScheduler.tasks[co] then
        return staticScheduler
    end
end
--【自动识别当前协程归属哪个调度器】避免调用方自己记着区分。

function Wake()
    --【从冬眠中唤醒当前协程】
    local schedule = GetCurrentScheduler()
    local task = schedule.tasks[coroutine.running()]
    if task then
        task:SetList(schedule.running)
        -- ★ 注意：Wake 后不会立即 resume，要等下一次 Run()。
        --   若在 HIBERNATE 之后紧接着写代码，逻辑会延迟到下一帧才继续。
    end
end

function Hibernate()
    coroutine.yield(HIBERNATE)
    --【让协程完全停摆】彻底停止调度，直到 Wake()。
    -- 典型用途：暂停的 AI（远离玩家时）、暂停的动画。
end

function Yield()
    coroutine.yield()
    --【裸 yield】下一帧继续。若永不使用，理论上可实现"每帧轮转"，
    --   但实际开发中会浪费大量性能，应优先用 Sleep(帧数)。
end

function Sleep(time)
    --【睡眠指定时间】time 单位是秒（不是 tick）。
    local schedule = GetCurrentScheduler()
    local desttick = math.ceil((GetSchedulerTime(schedule.isstatic) + time)/GetTickTime())
    if GetSchedulerTick(schedule.isstatic) < desttick then
        coroutine.yield(SLEEP, desttick)
        --【会睡】挂到目标 tick 桶
    else
        coroutine.yield()
        --【时间已到或已过期】退化为裸 yield（下一帧继续，不睡）
    end
    -- ★ 注意这里没有 -0.0001 补偿，与 GetListForTimeFromNow 不同。
    --   可能导致 Sleep(0.5) 实际睡 0.533 秒这类偏差，属可接受的误差。
end

function KillThread(task)
    --【杀单个任务】自动识别它在哪个调度器里。
    if scheduler.tasks[task.co] then
        scheduler:KillTask(task)
    elseif staticScheduler.tasks[task.co] then
        staticScheduler:KillTask(task)
    end
end

------
function WakeTask(task)
    --【从冬眠中唤醒指定任务】与 Wake() 的区别：Wake 是给"自己"用的，
    --   这个是给"别人"用的（例如让另一个实体唤醒自己的任务）。
    if task then
        if scheduler.tasks[task.co] then
            task:SetList(scheduler.running)
        elseif staticScheduler.tasks[task.co] then
            task:SetList(staticScheduler.running)
        end
    end
end

--This is to start a thread
function StartThread(fn, id, param)
    --【★ 启动协程任务 —— 游戏里最常用的 API】
    if id == nil then
        local task = scheduler:GetCurrentTask()
        if task ~= nil then
            id = task.id
        end
        --【★ id 继承机制】若调用者没给 id，自动继承"当前协程的 id"。
        --   效果：一个任务里启动的所有子任务，都归属于同一个实体。
        --   于是实体销毁时 KillThreadsWithID(entity_guid) 能一次全灭。
        --   ★ 这正是防止协程泄漏最优雅的设计，移植时务必实现等价机制。
    end
    return scheduler:AddTask(fn, id, param)
end

function StartStaticThread(fn, id, param)
    --【启动静态线程】同 StartThread，但走 staticScheduler（不受游戏暂停影响）。
    if id == nil then
        local task = staticScheduler:GetCurrentTask()
        if task ~= nil then
            id = task.id
        end
    end
    return staticScheduler:AddTask(fn, id, param)
end

function RunScheduler(tick)
    --【每 tick 调用一次：驱动常规调度器】
    TheSim:ProfilerPush("scheduler:OnTick")
    scheduler:OnTick(tick)
    TheSim:ProfilerPop()
    --【性能剖析标记】C++ 侧的性能分析器会记录这段时间开销。
    --   ★ 自研引擎移植时，这类 profiling 标记应保留，
    --     否则后期性能问题无从下手。Scheduling 往往是协程多时的性能热点。

    TheSim:ProfilerPush("scheduler:Run")
    scheduler:Run()
    TheSim:ProfilerPop()
end

function RunStaticScheduler(tick)
    --【驱动静态调度器】在 update.lua 中被独立调用。
    TheSim:ProfilerPush("staticScheduler:OnTick")
    staticScheduler:OnTick(tick)
    TheSim:ProfilerPop()

    TheSim:ProfilerPush("staticScheduler:Run")
    staticScheduler:Run()
    TheSim:ProfilerPop()
end

function KillThreadsWithID(id)
    --【按归属批量杀任务】实体销毁时调用。
    scheduler:KillTasksWithID(id)
    staticScheduler:KillTasksWithID(id)
end

function StopAllThreads()
    --【停掉一切】退出游戏 / 重载世界时调用。
    scheduler:KillAll()
    staticScheduler:KillAll()
end