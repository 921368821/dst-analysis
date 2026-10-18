--============================================================
-- 文件：03_entity.lua
-- 模块：核心框架 / 实体 + 组件 + 事件
-- 职责：实现「实体（Entity）」与「组件（Component）」框架：
--       GUID、标签、组件容器、生命周期钩子、事件总线、标签+空间查询、泄漏防护。
--
-- 【为什么 DST 用「组合」而不是「继承」来扩展实体？】
-- 一个火把需要「可点燃 + 可照明 + 可燃烧」，
-- 如果用继承就得派生 FlameTorch、LitTorch、... 组合爆炸。
-- 组件化让行为可以自由叠加：inst:AddComponent(Burnable) 就是加一块行为。
-- 【代价】没有编译期检查，调用 inst.components.xxx 前必须自己判断非 nil。
--   这是 DST 里 `if inst.components.health ~= nil then` 随处可见的原因。
--
-- 【事件总线为什么是「实体粒度」而不是全局单例？】
-- 因为实体就是天然的清理边界。当实体销毁时，
-- 所有「别人监听我」的订阅都能一次性作废，不需要维护一张全局订阅表做反向索引。
-- 原版没有 TheEventBus 这种东西，就是靠这一点。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》scripts/entityscript.lua
-- 兼容性：Lua 5.1 / 5.3 / 5.4 / LuaJIT
--============================================================

local Class = require("01_class").Class
local sched = require("02_scheduler")

local M = {}

--============================================================
-- 一、GUID 分配器
--============================================================

local next_guid = 1

function M.NextGUID()
    -- GUID 全局唯一且单调递增。
    -- 【为什么不用实体名当 key？】同名预制体可以有很多实例（火把可以有一千个），
    -- 存档里存的也是 GUID，不是名字。名字是「预制体」的身份，GUID 是「实例」的身份。
    local g = next_guid
    next_guid = next_guid + 1
    return g
end

function M.ResetGUIDs() next_guid = 1 end

--============================================================
-- 二、空间查询：标签 + 半径
--============================================================

-- 这是一个极简的二维空间查询（只用 x/z，忽略 y）。
-- 原版走的是 C++ 侧的物理/导航网格查询。
--
-- 【为什么标签过滤比距离过滤更重要？】
-- 因为 AOI(感兴趣区域)查询的常见模式是「我附近有哪些光源/敌人/可采集物」。
-- 先按标签把 5000 个实体缩到 50 个，再算距离，比对 5000 个实体都算平方距离快一个数量级。
-- ★ 移植到 Unity/Godot 时这对应 Query 的 mask 位：
--   Unity: Physics.OverlapSphere(pos, r, layerMask, QueryTriggerInteraction)
--   Godot: PhysicsServer3D.sphere_shape + collision_mask
function M.FindEntities(x, z, radius, mustTags, cantTags, entities)
    local out = {}
    local r2 = radius * radius

    for _, inst in pairs(entities or {}) do
        if not inst._removed then
            -- 1) 标签粗筛（最便宜）
            local ok = true
            if mustTags then
                for i = 1, #mustTags do
                    if not inst.tags[mustTags[i]] then ok = false break end
                end
            end
            if ok and cantTags then
                for i = 1, #cantTags do
                    if inst.tags[cantTags[i]] then ok = false break end
                end
            end
            if ok then
                -- 2) 距离精算（平方比较，避免开方）
                local dx, dz = inst.x - x, inst.z - z
                if dx * dx + dz * dz <= r2 then
                    out[#out + 1] = inst
                end
            end
        end
    end
    return out
end

--============================================================
-- 三、Entity
--============================================================

local Entity = Class(function(self, name)
    self.GUID = M.NextGUID()
    self.entityname = name          -- 实体名（原版叫 entityname）
    self.prefab = name
    self.x, self.z = 0, 0
    self.tags = {}                  -- 标签集合：AddTag/HasTag/RemoveTag
    self.components = {}            -- 组件容器：inst.components.health
    self._removed = false
    self._eventlisteners = {}       -- 「我监听了谁」的记录，用于泄漏防护
    self._eventcallbacks = {}       -- 「谁监听了我」的记录，用于反查
end)

-- ---- 标签 ----

function Entity:AddTag(tag)
    -- 【设计取舍】原版 AddTag 会 return 是否「新增」。
    -- 很多地方写成 `if inst:AddTag("x") then ... end` 来做「只做一次的初始化」，
    -- 免去了先 HasTag 再 AddTag 的两次查找。
    local isnew = not self.tags[tag]
    self.tags[tag] = true
    return isnew
end

function Entity:HasTag(tag) return self.tags[tag] == true end

function Entity:RemoveTag(tag) self.tags[tag] = nil end

function Entity:GetTags()
    -- 返回副本而不是内部表 —— 否则外部能直接改坏实体的标签集合。
    local t = {}
    for k in pairs(self.tags) do t[#t + 1] = k end
    return t
end

function Entity:HasAnyTag(taglist)
    for i = 1, #taglist do
        if self.tags[taglist[i]] then return true end
    end
    return false
end

function Entity:HasAllTags(taglist)
    for i = 1, #taglist do
        if not self.tags[taglist[i]] then return false end
    end
    return true
end

-- ---- 组件 ----

function Entity:AddComponent(componentclass, name)
    -- 【为什么组件里必须保存 self.inst = inst？】
    -- 因为组件经常需要反向访问实体：推事件、发指令、查其他组件。
    -- 这是「组件持有实体」的单向引用，实体销毁时会一并释放，不会成环。
    -- ★ 反过来实体绝不能保存组件的「方法闭包」，否则容易形成循环引用。
    local inst = componentclass(self)
    name = name or componentclass.name or "component"
    self.components[name] = inst
    return inst
end

function Entity:RemoveComponent(name)
    local comp = self.components[name]
    if comp then
        if comp.OnRemoveFromEntity then
            comp:OnRemoveFromEntity()
        end
        self.components[name] = nil
    end
end

function Entity:GetComponent(name) return self.components[name] end

-- ---- 事件 ----

function Entity:ListenForEvent(source, eventname, fn, listeninginst)
    -- 【事件签名说明】
    --   source        —— 事件源（某个实体）。传 self 表示监听自己。
    --   eventname     —— 事件名字符串，如 "onhit"、"healthdelta"
    --   fn            —— 回调 function(source_inst, data)
    --   listeninginst —— 「代表谁在听」。默认是自己。
    --
    -- 【★ 为什么要多一个 listeninginst 参数？】
    --   因为很多情况下「监听者」和「调用方」不是同一个对象。
    --   典型例子（见 05_sourcemodifierlist）：
    --   物品 A 的修饰器袋挂在实体 P 上，但当来源对象 B 被销毁时，
    --   需要有人负责撤销 A 的效果。那个「负责人」就是 P。
    --
    -- 【★ 泄漏防护的核心就在这里】
    --   每次监听都同时登记两份：
    --     source._eventcallbacks[eventname]  —— 别人监听我
    --     self._eventlisteners[source]       —— 我监听了谁
    --   实体销毁时反查这两张表即可完整解绑，零残留。
    listeninginst = listeninginst or self
    if source._eventcallbacks[eventname] == nil then
        source._eventcallbacks[eventname] = {}
    end
    local cb = source._eventcallbacks[eventname]
    cb[#cb + 1] = { fn = fn, inst = listeninginst }

    if self._eventlisteners[source] == nil then
        self._eventlisteners[source] = {}
    end
    local l = self._eventlisteners[source]
    l[#l + 1] = { eventname = eventname, fn = fn }
end

function Entity:UnregisterEvent(source, eventname, fn, listeninginst)
    listeninginst = listeninginst or self
    -- 从 source 侧摘掉
    local cb = source._eventcallbacks[eventname]
    if cb then
        for i = #cb, 1, -1 do
            if cb[i].fn == fn and cb[i].inst == listeninginst then
                table.remove(cb, i)
            end
        end
    end
    -- 从自己侧摘掉
    local l = self._eventlisteners[source]
    if l then
        for i = #l, 1, -1 do
            if l[i].eventname == eventname and l[i].fn == fn then
                table.remove(l, i)
            end
        end
    end
end

function Entity:RemoveEventCallback(source, eventname, fn, listeninginst)
    -- 原版里这是个独立命名的 API，语义与 UnregisterEvent 相同。
    self:UnregisterEvent(source, eventname, fn, listeninginst)
end

function Entity:PushEvent(eventname, data, source)
    source = source or self
    -- 推送前先确保监听者还活着（被 Remove 的监听者应自动失效）
    local cb = source._eventcallbacks[eventname]
    if not cb then return false end

    for i = #cb, 1, -1 do
        local entry = cb[i]
        -- 【泄漏防护】监听者已经死了，顺手清理这条订阅。
        --   没有这步的话，一个反复生灭的实体（掉落物/投射物）会在
        --   长生命周期的实体（玩家）身上堆积上万条死订阅。
        --
        -- ★★ 但 "onremove" 是**特例**，必须无条件送达 ★★
        --   因为 Entity:Remove() 的流程是「先置 _removed=true，再广播 onremove」，
        --   而 onremove 正是「通知别人把挂在我身上的状态撤干净」的信号
        --   （典型用途：05_sourcemodifierlist 的自动撤销机制）。
        --   如果这里也过滤掉，onremove 处理器根本收不到消息，
        --   于是修饰器永远撤不掉 —— 也就是「幽灵 buff」。
        --   ★ 这个坑非常隐蔽：症状是「buff 实体消失了但效果还在」，
        --     而根因藏在几十行之外的实体销毁流程里。
        if entry.inst._removed and eventname ~= "onremove" then
            table.remove(cb, i)
        else
            entry.fn(source, data)
        end
    end
    return true
end

-- ---- 任务代理 ----
-- 【为什么要代理到调度器？】
-- 因为实体上的任务必须自动带上实体 GUID 作为归属 id，
-- 实体销毁时才能 KillThreadsWithID(GUID) 一次清空。
-- 业务代码永远不需要（也不应该）自己传 id。

function Entity:DoTaskInTime(time, fn, ...)
    local periodic = sched.DoTaskInTime(time, fn, self.GUID, self, ...)
    self._tracktask(periodic)
    return periodic
end

function Entity:DoPeriodicTask(time, fn, initialdelay, ...)
    local periodic = sched.DoPeriodicTask(time, fn, nil, initialdelay, self.GUID, self, ...)
    self._tracktask(periodic)
    return periodic
end

function Entity:StartThread(fn, param)
    -- 【★ id 自动继承的关键一环】
    -- 这里显式传 self.GUID，于是该线程里再 StartThread 派生出的子线程
    -- 会因为「id 为空则继承当前协程 id」而自动继承同一个 GUID。
    -- 这就是「一整个实体的所有协程共享一个归属 id」的由来。
    return sched.StartThread(fn, self.GUID, param)
end

function Entity:_tracktask(periodic)
    self.pendingtasks = self.pendingtasks or {}
    self.pendingtasks[periodic] = true
    periodic.onfinish = function(p, completed)
        -- 无论正常结束还是被 Cancel，都要把自己从 pendingtasks 里摘掉。
        -- 【为什么要做？】否则这个表只增不减，是一处典型的缓慢内存泄漏。
        -- ★ 原版就是踩过这个坑 —— 见 EntityScript 里 task_finish 的注释。
        if self.pendingtasks then
            self.pendingtasks[p] = nil
        end
        -- 第二个参数 completed=false 表示是被取消的，
        -- 业务代码可以据此决定要不要做告警/断点。
    end
    return periodic
end

-- ---- 生命周期 ----

function Entity:OnSave()
    -- 【存档契约】每个组件返回自己的数据表，返回 nil 表示「我没状态，不用存」。
    -- 这个 nil 约定能极大压缩存档体积（满血的生命值不存）。
    local savedata = {}
    local any = false
    for name, comp in pairs(self.components) do
        if comp.OnSave then
            local d = comp:OnSave()
            if d ~= nil then
                savedata[name] = d
                any = true
            end
        end
    end
    return any and { prefab = self.prefab, components = savedata } or nil
end

function Entity:OnLoad(data)
    -- 【为什么必须先构造组件再 OnLoad？】
    -- 因为 OnLoad 里经常要用其他组件做校验（比如判断实体是否被别的系统替换过）。
    -- 所以调用顺序铁律是：AddComponent -> SetPersistData(OnLoad)，
    -- 绝不能反过来。这也是原版 SpawnSaveRecord 的顺序。
    if data == nil or data.components == nil then return end
    for name, cdata in pairs(data.components) do
        local comp = self.components[name]
        if comp and comp.OnLoad then
            comp:OnLoad(cdata)
        end
        -- 【注意】组件不存在时**静默跳过**，这是向前兼容的关键：
        -- 读一个旧存档时，如果某个组件被这个版本删掉了，
        -- 直接跳过而不是报错，玩家才能继续玩。
    end
end

function Entity:StartUpdatingComponent(comp)
    -- 【为什么要区分 OnUpdate 和 LongUpdate？】
    -- OnUpdate 每帧跑（30Hz），适合 UI、光照、输入这类必须跟手的。
    -- LongUpdate 在「大时间步长」时跑（切后台回来、掉帧后一次补很多步），
    -- 且dt 可以很大 —— 数值条用它，因为「衰减量 = 速率 × dt」天生对大 dt 免疫。
    -- 物理/动画这种不能对大 dt 稳定的，绝不能放 LongUpdate。
    self._updating = self._updating or {}
    self._updating[comp] = true
end

function Entity:StopUpdatingComponent(comp)
    if self._updating then self._updating[comp] = nil end
end

function Entity:Update(dt)
    if self._updating then
        for comp in pairs(self._updating) do
            if comp.OnUpdate then comp:OnUpdate(dt) end
        end
    end
end

function Entity:LongUpdate(dt)
    if self._updating then
        for comp in pairs(self._updating) do
            -- LongUpdate 允许 dt 很大（切后台回来时一次补很多秒）。
            -- 组件若没写 LongUpdate 就退回 OnUpdate，与原版行为一致。
            if comp.LongUpdate then
                comp:LongUpdate(dt)
            elseif comp.OnUpdate then
                comp:OnUpdate(dt)
            end
        end
    end
end

function Entity:Remove()
    --【销毁流程的顺序很重要，不能乱】
    -- 1) 先把「我要死了」标记上 —— 这样之后任何回调都能立刻查到
    if self._removed then return end
    self._removed = true

    -- 2) 通知组件收尾。组件在这里要：
    --    - Cancel 自己的周期任务
    --    - KillThreadsWithID(self.GUID) 干掉遗留协程
    --    - 解绑事件
    for name, comp in pairs(self.components) do
        if comp.OnRemoveFromEntity then
            comp:OnRemoveFromEntity()
        end
    end

    -- 3) 广播 onremove 事件。
    --    ★ 这一步必须在组件清理**之后**：因为监听者（如修饰器袋）
    --      需要组件还活着时把自己的效果撤干净。
    self:PushEvent("onremove")

    -- 4) 无条件杀掉这个实体名下的所有协程（兜底）。
    --    组件可能没清干净（业务 bug），这里是最后一道防线。
    sched.KillThreadsWithID(self.GUID)

    -- 5) 清掉所有「别人监听我」的订阅
    for eventname, cb in pairs(self._eventcallbacks) do
        for i = #cb, 1, -1 do
            local entry = cb[i]
            entry.inst:UnregisterEvent(self, eventname, entry.fn, entry.inst)
        end
        self._eventcallbacks[eventname] = nil
    end

    -- 6) 清掉「我监听了别人」的订阅
    --    【★ 这两步缺一不可。只做 5 会导致：实体死了但还挂在别人的
    --      _eventlisteners 表里，别人 PushEvent 时不断触发「已死实体」的逻辑。
    --      这是 DST 最经典的泄漏模式。】
    for source, l in pairs(self._eventlisteners) do
        if not source._removed then
            for i = #l, 1, -1 do
                self:UnregisterEvent(source, l[i].eventname, l[i].fn, self)
            end
        end
        self._eventlisteners[source] = nil
    end

    -- 7) 断引用，让 GC 能立刻回收
    self.components = {}
    self.tags = {}
    self._updating = nil
    self.pendingtasks = nil
end

function Entity:__tostring()
    return string.format("Entity[%d:%s]", self.GUID, tostring(self.entityname))
end

-- SetPristine：★ 主从架构的关键一步。
--
-- 【它到底做了什么？】
-- 原版里 SetPristine 会给这个实体的网络同步状态**拍一张快照**，
-- 拍完之后所有对实体字段的修改都会自动打包发给客户端。
-- 换句话说：pristine 之前的修改算「初始状态」，之后的算「状态变更」。
--
-- 【为什么预制体工厂第一件事就该调它？】
-- 因为工厂里的操作（打标签、挂组件）属于「构造」。
-- 如果不在这里拍快照，构造过程中的中间态也会被同步一遍 ——
-- 客户端会先收到一个没有组件的半成品实体，再收到完整的，表现为「闪一下」。
--
-- 【简化版怎么表达？】
-- 原版由 C++ 网络层实现（写脏标记、序列化差异）。
-- 本教学版没有网络层，就用一个标记 + 快照来表达同样的**语义分界**。
--
-- ★ 移植对应：
--   Unity —— Instantiate 后手动调用 NetworkVariable 的初始值设置
--   Godot —— scene.instantiate() 后由 MultiplayerSynchronizer 发送初始状态
function Entity:SetPristine()
    if self.pristine then
        error("Entity:SetPristine() 只能调用一次（已拍过快照）")
    end
    self.pristine = true
    local snap = {}
    for k in pairs(self.tags) do snap[k] = true end
    self.pristinesnap = { tags = snap, prefab = self.prefab }
end

function Entity:IsPristine() return self.pristine == true end

M.Entity = Entity

--============================================================
-- 四、EntityScript：实体脚本（游戏侧的行为层）
--============================================================

-- 【EntityScript 与 Entity 的关系是什么？】
-- 在原版里它们是同一个对象的两个视角：
--   EntityScript   = 原生实体对象（有网络、物理、动画）
--   Entity         = 纯 Lua 的包装，挂在 entity 字段上
-- 本教学版没有 C++ 侧，所以把两者合并成一个 Entity，
-- 而「实体脚本」这一层单独抽出来：它是**每个预制体自己的行为**，
-- 通过约定的一组钩子函数（OnSave/OnLoad/OnUpdate/...）被引擎回调。
--
-- ★ 这个「约定优于配置」的模式是整个 DST 架构的骨架：
--   引擎不认识任何具体玩法，只知道「我会去调 inst.XXXComponent:OnSave()」。
--   于是新增玩法 = 新增组件文件，不需要改引擎一行代码。

local EntityScript = Class(function(self, inst)
    self.entity = inst          -- 指向纯 Lua 实体
    self.inst = inst             -- 别名，原版里 inst 通常指 EntityScript 自己
end)

-- 约定钩子（子类覆写即可；这里给出空实现作为文档）
function EntityScript:OnSave() end
function EntityScript:OnLoad(data) end
function EntityScript:OnUpdate(dt) end
function EntityScript:LongUpdate(dt) end
function EntityScript:OnRemoveFromEntity() end
function EntityScript:OnEntitySleep() end
function EntityScript:OnEntityWake() end

M.EntityScript = EntityScript

--============================================================
-- 五、自测：实体全流程
--============================================================

local T = {}
local function check(ok, msg)
    if not ok then error("[03_entity] 断言失败: " .. msg, 2) end
end

-- 辅助：推进调度器若干 tick
-- ★ 必须定义在使用它的测试函数**之前**：
--   Lua 的 local 是词法作用域，先用后定义会把名字解析成全局 nil。
local function runTicksFor(n)
    for _ = 1, n do
        sched.AdvanceTick()
        sched.RunScheduler(sched.GetTick())
    end
end
T._runTicks = runTicksFor

-- 测试用的组件
local Health = Class(function(self, inst)
    self.inst = inst
    self.max = 100
    self.current = 100
end)
Health.name = "health"
function Health:OnSave()
    return self.current ~= self.max and { current = self.current } or nil
end
function Health:OnLoad(d) self.current = d.current end
function Health:OnUpdate(dt) self.current = self.current - dt end
function Health:LongUpdate(dt) self.current = self.current - dt end
function Health:OnRemoveFromEntity() self.onremove_called = true end

-- 记录自己是否被正确清理的组件
local Burnable = Class(function(self, inst)
    self.inst = inst
    self.burning = true
    self.cleaned = false
end)
Burnable.name = "burnable"
function Burnable:OnRemoveFromEntity()
    -- 【典型清理职责】组件销毁时把自己持有的实体引用断开。
    -- 虽然 Lua 有 GC，但显式断引用能让「悬空引用」这类逻辑 bug 立刻暴露，
    -- 而不是悄悄读到已销毁实体的字段。
    self.cleaned = true
    self.inst = nil
end

function T.tags()
    local e = Entity("test_tag_ent")
    check(e:AddTag("FX"), "首次 AddTag 应返回 true")
    check(not e:AddTag("FX"), "重复 AddTag 应返回 false")
    check(e:HasTag("FX"), "HasTag 应为真")
    check(e:HasAnyTag({ "NOPE", "FX" }), "HasAnyTag 应为真")
    check(not e:HasAllTags({ "FX", "NOPE" }), "HasAllTags 应为假")
    e:RemoveTag("FX")
    check(not e:HasTag("FX"), "RemoveTag 后应不存在")

    -- 标签表不能被外部直接改坏
    local tags = e:GetTags()
    tags[1] = "hacked"
    check(#e:GetTags() == 0, "GetTags 应返回副本")
    print("  [OK] 标签增删查 + 副本保护")
end

function T.components()
    local e = Entity("test_comp_ent")
    local h = e:AddComponent(Health)
    e:AddComponent(Burnable)
    check(e:GetComponent("health") ~= nil, "应能取到组件")
    check(e.components.burnable ~= nil, "组件应在容器里")
    check(h.inst == e, "组件应反向持有实体引用")

    e.components.health.current = 50
    check(e.components.health.current == 50, "应能直接访问组件字段")

    -- 移除组件应触发它的 OnRemoveFromEntity（组件自己负责 Cancel 任务等）
    local b = e.components.burnable
    e:RemoveComponent("burnable")
    check(e.components.burnable == nil, "移除后组件应为空")
    check(b.cleaned == true, "移除组件应触发 OnRemoveFromEntity 清理")
    print("  [OK] 组件 Add/Get/Remove")
end

function T.events()
    local src = Entity("evt_src")
    local listener = Entity("evt_listener")
    local got = {}
    local fn = function(source, data) got[#got + 1] = data end

    listener:ListenForEvent(src, "onhit", fn)
    src:PushEvent("onhit", { dmg = 10 })
    check(#got == 1 and got[1].dmg == 10, "应收到事件")
    check(got[1].dmg == 10, "事件数据应原样传递")

    listener:UnregisterEvent(src, "onhit", fn)
    src:PushEvent("onhit", { dmg = 20 })
    check(#got == 1, "解绑后不应再收到")

    -- 重复解绑不应崩
    listener:UnregisterEvent(src, "onhit", fn)

    -- 监听者先死 -> 源实体再推事件时，死订阅应被自动清理
    listener:ListenForEvent(src, "onhit", fn)
    check(#src._eventcallbacks.onhit == 1, "应记录 1 条订阅")
    listener:Remove()
    check(#src._eventcallbacks.onhit == 0, "监听者死后订阅应被移除（泄漏防护）")
    print("  [OK] 事件推送/解绑 + 泄漏防护（死监听者自动清理）")
end

function T.lifecycleAndSave()
    local e = Entity("test_life_ent")
    e:AddComponent(Health)
    e.components.health.current = 42

    -- OnSave：只有非默认状态才存
    local d = e:OnSave()
    check(d ~= nil and d.components.health.current == 42, "应存下非默认状态")
    check(d.prefab == "test_life_ent", "应记录 prefab 名")

    -- 满血时应返回 nil（省体积）
    e.components.health.current = 100
    check(e:OnSave() == nil, "默认状态不应存（OnSave 返回 nil 的约定）")

    -- OnLoad
    e:OnLoad({ components = { health = { current = 42 } } })
    check(e.components.health.current == 42, "OnLoad 应恢复状态")

    -- OnLoad 时组件不存在应静默跳过（旧存档兼容）
    local ok = pcall(function()
        e:OnLoad({ components = { removedcomponent = { x = 1 } } })
    end)
    check(ok, "读到已删除组件的数据时不应崩溃（向前兼容）")

    -- OnUpdate
    e.components.health.current = 100
    e:AddComponent(Burnable)
    local burn = e.components.burnable
    -- 让 health 进入 updating 集合
    local updater = e.components.health
    e:StartUpdatingComponent(updater)
    e:Update(10)
    check(updater.current == 90, "OnUpdate 应被调用并按 dt 推进")

    -- LongUpdate 走同一批组件，但允许很大的 dt（切后台回来一次补 5 秒）
    e:LongUpdate(5)
    check(updater.current == 85, "LongUpdate 应被调用（大时间步长）")
    check(burn.cleaned == false, "未移除的组件不应被清理")

    e:StopUpdatingComponent(updater)
    e:Update(10)
    check(updater.current == 85, "StopUpdatingComponent 后不应再更新")

    -- Remove 应触发所有组件的清理
    e:Remove()
    check(burn.cleaned == true, "实体销毁应触发组件 OnRemoveFromEntity")
    print("  [OK] 生命周期钩子 + 存档契约（nil 省略 / 缺组件静默跳过）")
end

function T.removeCleanup()
    -- 全流程：创建 -> 加组件 -> 发事件 -> 销毁
    local e = Entity("flow_ent")
    e:AddComponent(Health)

    local other = Entity("flow_other")
    local hits = 0
    e:ListenForEvent(other, "ping", function() hits = hits + 1 end)
    other:PushEvent("ping")
    check(hits == 1, "销毁前应能收到事件")

    -- 起一个属于该实体的协程，验证 Remove 会清掉它
    local tid = 0
    e:StartThread(function()
        while true do sched.Sleep(0.1) end
    end)
    runTicksFor(1)
    tid = sched.scheduler:GetTaskCount()
    check(tid > 0, "应有活跃协程")

    e:Remove()
    check(e._removed, "应标记为已移除")
    check(e.components.health == nil, "组件容器应被清空")
    check(sched.scheduler:GetTaskCount() == 0,
        string.format("Remove 后协程应被清空，实际剩 %d", sched.scheduler:GetTaskCount()))
    check(#other._eventcallbacks.ping == 0, "实体死后不应残留在别人的订阅表里")

    other:PushEvent("ping")
    check(hits == 1, "死后不应再收到事件")
    print("  [OK] 销毁全流程：清组件 / 清协程 / 清双向订阅")
end

function T.spatialQuery()
    local ents = {}
    local function mk(name, x, z, tag)
        local e = Entity(name)
        e.x, e.z = x, z
        if tag then e:AddTag(tag) end
        ents[#ents + 1] = e
        return e
    end
    mk("light1", 0, 0, "light")
    mk("light2", 5, 0, "light")
    mk("rock1", 0, 5, "rock")
    mk("far_light", 1000, 1000, "light")

    local r = M.FindEntities(0, 0, 10, { "light" }, nil, ents)
    check(#r == 2, string.format("半径10内的light 应有 2 个，实际 %d", #r))

    r = M.FindEntities(0, 0, 10, nil, { "light" }, ents)
    check(#r == 1, "排除 light 后应只剩 rock")

    r = M.FindEntities(0, 0, 10000, { "light" }, { "light" }, ents)
    check(#r == 0, "同时 require + exclude 应为 0")

    -- 已移除的实体必须被排除
    ents[1]:Remove()
    r = M.FindEntities(0, 0, 10, { "light" }, nil, ents)
    check(#r == 1, "已移除实体不应被查到")
    print("  [OK] 标签 + 半径空间查询（含已移除实体排除）")
end

-- 辅助：推进调度器若干 tick（定义见本节顶部）
T._runTicks = runTicksFor

function T.run()
    print("=== 03_entity.lua 自测 ===")
    T.tags()
    T.components()
    T.events()
    T.lifecycleAndSave()
    T.removeCleanup()
    T.spatialQuery()
    print("03_entity 全部通过\n")
    return true
end

M.test = T

--============================================================
-- 六、导出
--============================================================

-- 【独立运行检测】详见 01_class.lua 末尾的说明：
-- 不能用 `... == nil`（Lua 5.2+ 的 chunk 非 vararg，顶层 `...` 是语法错误）。
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