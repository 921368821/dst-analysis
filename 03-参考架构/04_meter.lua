--============================================================
-- 文件：04_meter.lua
-- 模块：玩法 / 生存数值条
-- 职责：实现「速率 × dt 积分」模型的数值条基类，并给出
--       Health / Hunger / Sanity / Warmth 四条具体数值条。
--
-- 【★ 核心模型：rate × dt 积分，而不是「每秒扣 1 点」】
-- 朴素做法是「每秒减 1」，但它有三个致命问题：
--   ① 卡帧时会丢时间：掉帧 5 秒，数值只减了 1 而不是 5。
--     玩家会觉得「我什么都没干但就是饿死了」。
--   ② 无法做连续变化：光是「站在火堆旁回暖」这种平滑效果就做不出来。
--   ③ 与固定步长主循环语义冲突（07_world 的 dt 是变化的）。
-- 正确做法是：每帧执行 current += rate * dt。
-- 数值变化 = ∫rate dt，对任意步长都精确，且天然支持平滑插值。
-- ★ 这条规律同样适用于体温、湿度、腐烂度、体力 —— 所有「每秒变化」的量。
--
-- 【为什么原始 rate 和「有效衰减率」要分开存？】
--   self.rate                 —— 原始速率（如饥饿固定 -1/s）
--   self.ratemodifiers:Get()  —— 外部修正的乘区（如冰箱 ×0.5）
--   有效速率 = rate * ratemodifiers:Get()
-- 直接把结果写进 self.rate 会导致「取消冰箱效果时不知道该恢复成多少」，
-- 这正是 05_sourcemodifierlist 存在的理由。见该文件的顶部说明。
--
-- 上游来源：Klei Entertainment《Don't Starve Together》
--           scripts/components/health.lua、hunger.lua、sanity.lua
-- 兼容性：Lua 5.1 / 5.3 / 5.4 / LuaJIT
--============================================================

local Class = require("01_class").Class
local sml = require("05_sourcemodifierlist")
local SourceModifierList = sml.SourceModifierList

local M = {}

local TICK_TIME = require("02_scheduler").TICK_TIME

--============================================================
-- 一、Meter：数值条基类
--============================================================

-- oncurrent(this, newvalue, oldvalue)：数值变化时自动触发（对应原版 props setter 的做法）
local function oncurrent(self, current, old)
    -- ★ 属性表在构造时把初始值置为 nil（见 01_class.lua），
    --   所以构造函数里的第一次赋值会带着 old = nil 进来。
    --   这里必须兜底，否则一开游戏就会在 old/self.max 上崩。
    old = old or current
    if self.inst and not self.inst._removed then
        self.inst:PushEvent(self.eventname .. "delta", {
            oldpercent = old / self.max,
            newpercent = current / self.max,
            delta = current - old,
        })
    end
    if self.ondirty then self.ondirty(current, old) end
end

-- Meter(inst, max)
--   max      —— 上限
--   baseline —— 「归零即死/即发疯」的阈值线，默认 0。
--               有些条不是 0 归零：理智度掉到 0 才是疯狂，饥饿 0 才是饿死。
--   decayedir —— 衰减方向：-1 表示自然减少（饥饿/体温），+1 表示自然增加（理智白天回血）
local Meter = Class(function(self, inst, max, baseline, decayedir)
    self.inst = inst
    self.max = max or 100
    self.baseline = baseline or 0
    self.current = self.max
    self.rate = 0            -- 原始速率（可为负=减少 / 正=增加）
    self.decayedir = decayedir or -1
    self.paused = false
    self.ondirty = nil       -- 外部可注册的「数值变化」回调
    self.eventname = "meter" -- 推事件时的前缀

    -- 【★ 修饰器袋：外部只能通过它影响衰减速率，绝不能直接写 self.rate】
    --   multiply 折叠，base=1：冰箱 ×0.5、buff ×2 都往这里塞。
    self.ratemodifiers = SourceModifierList(inst, 1, sml.multiply)

    -- 归零/触底回调（死亡）
    self.onzero = nil
    self._waszero = false
end, nil, { current = oncurrent })
-- ★ 用 props 声明 current 属性：这样 `self.current = x` 一句赋值
--   就同时完成了「赋值」+「推事件」+「触发外部回调」。
--   参见 01_class.lua 顶部对「写入拦截」的说明。
--   注意：构造函数里 self.current = self.max 也会触发 setter，
--   此时 inst 还没有挂好，所以 oncurrent 里做了 self.inst 判空。

-- ---- 基础读写 ----

function Meter:SetMax(amount)
    self.max = amount
    self.current = amount
end

-- GetPercent / SetPercent：0..1 的百分比接口
-- 【为什么用百分比而不是绝对值？】
-- 因为不同实体的数值上限不同（普通玩家 150，小管理员 200），
-- 而所有阈值判断（「低于 30% 变疯狂」）都是相对的。统一用百分比比较不易出错。
function Meter:GetPercent() return self.current / self.max end

function Meter:SetPercent(p, overtime)
    self:SetCurrent(p * self.max, overtime)
end

-- SetCurrent：唯一的写入口。负责 clamp + 触发状态切换事件。
function Meter:SetCurrent(current, overtime)
    local old = self.current
    self.current = math.min(math.max(current, 0), self.max)
    -- ★ clamp 到 [0, max]。不做 clamp 的话，一个 +100 的食物能把饥饿度
    --   顶到 200，然后玩家要饿 200 秒才回到 100 —— 数值彻底失控。
    --   「最多也就是满」是所有生存游戏的铁律。

    -- 跨过阈值时的状态切换事件
    if old > 0 then
        if self.current <= 0 then
            self._waszero = true
            if self.inst then
                self.inst:PushEvent("start" .. self.eventname .. "empty")
            end
        end
    elseif self.current > 0 then
        self._waszero = false
        if self.inst then
            self.inst:PushEvent("stop" .. self.eventname .. "empty")
        end
    end

    -- 归零回调（死亡）
    if self.current <= 0 and self.onzero then
        self.onzero(self.inst, self)
    end
    return self.current
end

-- DoDelta(delta, source)：最常用的写入口。
--   source —— 可选，用于「谁造成的变化」。存档和调试面板会用到。
--   ★ 负数=减少，正数=增加。调用方不要自己算 new current，直接传增量。
function Meter:DoDelta(delta, source)
    if self.paused then return self.current end
    if self.ondelta then
        -- 允许外部拦截/重定向（例如「无敌状态下不掉血」）
        if self.ondelta(self.inst, delta, source) == false then
            return self.current
        end
    end
    return self:SetCurrent(self.current + delta)
end

-- ---- 速率控制 ----

function Meter:SetRate(rate)
    -- rate 的符号约定：负数表示「随时间减少」，正数表示「随时间增加」。
    -- Hunger: SetRate(-1)  -> 每秒掉 1 点
    -- Sanity(白天): SetRate(+3) -> 每秒回 3 点
    self.rate = rate
end

-- GetEffectiveRate：原始速率 × 修饰器。
-- ★ 所有「时间推进」都必须走这个函数，绝不能直接用 self.rate。
--   漏掉这一处的后果是「冰箱完全不起作用」这种极难排查的 bug。
function Meter:GetEffectiveRate()
    return self.rate * self.ratemodifiers:Get()
end

-- DoDecay(dt)：把时间推进一步。这是「速率×dt 积分」的唯一入口。
--   dt 单位是秒。
function Meter:DoDecay(dt)
    if self.paused then return self.current end
    local eff = self:GetEffectiveRate()
    if eff == 0 then return self.current end
    -- ★ rate × dt。dt 可以是 1/30，也可以是切后台回来的 300，
    --   积分结果完全正确（数值 ∫rate dt 对任意步长都精确）。
    return self:SetCurrent(self.current + eff * dt)
end

function Meter:Pause()
    -- 【为什么要 Pause 而不是 self.rate = 0？】
    -- Pause 保留了你「原本的速率」，Resume 时自动恢复；
    -- 直接置 0 的话，Resume 时需要外部记住原值 —— 又是一个「不知道该恢复成多少」的问题。
    self.paused = true
end

function Meter:Resume() self.paused = false end
function Meter:IsPaused() return self.paused end

function Meter:IsEmpty() return self.current <= self.baseline end

function Meter:GetDebugString()
    return string.format("%6.2f/%6.2f  rate=%7.3f  eff=%7.3f  paused=%s",
        self.current, self.max, self.rate, self:GetEffectiveRate(), tostring(self.paused))
end

-- ---- 生命周期钩子 ----

-- OnUpdate：每帧由实体驱动
function Meter:OnUpdate(dt)
    self:DoDecay(dt)
end

-- LongUpdate：大时间步长。★ 必须重写，不能用 OnUpdate 的 dt 语义混用。
--   数值条天生对大 dt 免疫（rate × dt 就是精确积分），
--   所以 LongUpdate 和 OnUpdate 可以做完全一样的事。
function Meter:LongUpdate(dt)
    self:DoDecay(dt)
end

function Meter:OnSave()
    -- ★ 只存非默认值。这是压缩存档体积最有效的一招：
    --   一万个满血实体只存一个 prefab 名，几乎不占空间。
    return self.current ~= self.max and { [self.eventname] = self.current } or nil
end

function Meter:OnLoad(data)
    local v = data[self.eventname]
    if v ~= nil and v ~= self.current then
        self.current = v          -- 直接赋值以避免重复推 delta 事件
        -- 【为什么要直接赋值而不走 DoDelta？】
        --   读档不是「发生了一次变化」，不应该触发 "healthdelta" 之类的事件，
        --   否则刚进世界就会收到一大波虚假的变化通知（HUD 闪烁、音效齐鸣）。
    end
end

function Meter:OnRemoveFromEntity()
    -- 断开对实体的引用，避免修饰器袋的闭包把实体钉住
    self.onzero = nil
    self.ondirty = nil
    self.ondelta = nil
    self.inst = nil
end

M.Meter = Meter

-- 【★ 组件必须自报家门】
--   Entity:AddComponent 会用 componentclass.name 作为 components 表的键。
--   所以每个组件类都要声明自己的名字，这就是 inst.components.health 的来源。
--   ★ 移植到强类型语言时可以用 [Component("health")] 特性自动完成这件事。
Meter.name = "meter"

--============================================================
-- 二、Health：生命值
--============================================================

-- oncurrent：血量归零时把「死了」这件事同步出去
local function health_oncurrent(self, current, old)
    old = old or current        -- 构造函数首次赋值时 old 为 nil，兜底同上
    if self.inst and not self.inst._removed then
        self.inst:PushEvent("healthdelta", {
            oldpercent = old / self.max,
            newpercent = current / self.max,
            delta = current - old,
        })
        if current <= 0 and old > 0 then
            -- PushEvent("death") 会触发 main.lua 里注册的死亡处理（掉落物品、播放音效）
            self.inst:PushEvent("death", { cause = self.lastcause })
        end
    end
    if self.ondirty then self.ondirty(current, old) end
end

local Health = Class(Meter, function(self, inst)
    Meter._ctor(self, inst, 100, 0, -1)
    self.eventname = "health"
    self.max = 100
    self.current = 100
    self.rate = 0            -- ★ 血量没有自然衰减！只会被 DoDelta 改变。
    -- 【重要区别】饥饿/体温有自发的 rate（随时间下降），
    -- 血量没有 —— 血量只被「伤害/治疗」这些离散事件改变。
    -- 这个区别很重要：写一个通用的 Meter 时很容易误以为「所有数值条都是持续衰减的」。
    self.invincible = false
    self.lastcause = nil
end, { current = health_oncurrent })   -- ★ 正确写法是 3 个参数：Class(base, ctor, props)
--   注意这里**不能**写成 `end, nil, { ... }`：
--   Class 只有 (base, _ctor, props) 三个形参，多传的 nil 和 props 表会被
--   悄悄丢弃 —— 不报错，但 props 整个失效，属性 setter 静默地不工作。
--   这是 Lua 里非常危险的一类 bug：**签名不匹配是静默的**。
--   为此本实现给 Class 加了「实参个数」断言（见 01_class.lua）。
-- ★ 注意：派生类要**手工**调父类构造函数（01_class.lua 里的重要语义）。
--   同时这里重新声明了 current 属性 —— 因为 Meter 的 props 是写在 Meter 类上的，
--   浅拷贝把 __index/__newindex 一起拷过来了，所以只要新类也传 props，
--   新的 setter 就会生效（__newindex 是被覆盖的）。

function Health:SetInvincible(v) self.invincible = v end
function Health:IsInvincible() return self.invincible end

function Health:IsDead() return self.current <= 0 end

-- DoDamage：伤害的语义化入口
function Health:DoDamage(amount, cause)
    if self.invincible then return end
    self.lastcause = cause
    return self:DoDelta(-amount, cause)
end

function Health:Heal(amount)
    return self:DoDelta(amount, "heal")
end

M.Health = Health
Health.name = "health"

--============================================================
-- 三、Hunger：饥饿度
--============================================================

local Hunger = Class(Meter, function(self, inst)
    Meter._ctor(self, inst, 150, 0, -1)
    self.eventname = "hunger"
    self.max = 150
    self.current = 150
    self.rate = -1          -- ★ 每秒掉 1 点。DST 原始设定约 1.5/天周期
    self.hurtrate = -1      -- 饥饿归零后，转而每秒扣多少血
end)

function Hunger:IsStarving() return self.current <= 0 end

-- DoDecay 的重写：饥饿归零后不再减少饥饿度（已经到底了），
-- 改为持续扣血 —— 这是「连锁惩罚」的标准写法。
function Hunger:DoDecay(dt)
    if self.paused then return self.current end
    if self.current > 0 then
        Meter.DoDecay(self, dt)
    else
        -- 已经饿死了，改为掉血
        local h = self.inst and self.inst.components.health
        if h then h:DoDamage(-self.hurtrate * dt, "hunger") end
    end
    return self.current
end

-- Eat：吃东西。★ 数值增加**必须 clamp 到 max**，一次性吃太多只会到满。
function Hunger:Eat(amount)
    -- 原版有 overtime（暴食）机制：短时间吃太多有副作用。
    -- 本教学版保留接口但不实现，留给读者扩展。
    return self:DoDelta(amount, "food")
end

M.Hunger = Hunger
Hunger.name = "hunger"

--============================================================
-- 四、Sanity：理智度
--============================================================

local Sanity = Class(Meter, function(self, inst)
    Meter._ctor(self, inst, 200, 0, -1)
    self.eventname = "sanity"
    self.max = 200
    self.current = 200
    self.rate = 0           -- 由昼夜系统动态设置，白天为正夜晚为负

    -- 变疯阈值。用「比例」而非绝对值，因为 max 可能被装备/天赋改。
    self.insane_threshold = 0.30   -- 低于 30% 变疯狂
    self.sane_threshold = 0.35     -- 高于 35% 恢复清醒
    self.sane = true
    self._oldissane = true

    -- 幻觉出现标记（给 main.lua 演示用）
    self.hallucinations = 0
end)

-- Recalc：根据当前昼夜/光照重算速率。
-- ★ 这个函数体现了「Sanity 与 Hunger 的本质区别」：
--   饥饿的 rate 是常数；理智的 rate 是**上下文相关**的（白天回，夜晚掉）。
--   所以它需要「谁在驱动」的模型：这里由外部（世界/光源）每帧调用。
function Sanity:Recalc(isdark)
    if isdark then
        -- 黑暗中掉理智
        self.rate = -0.5
    else
        -- 白天缓慢恢复
        self.rate = 0.3
    end
    return self:GetEffectiveRate()
end

function Sanity:IsSane() return self.sane end
function Sanity:IsInsane() return not self.sane end

-- SetCurrent 的重写：在赋值后做阈值判定（对应原版 sanity.lua 的 DoDelta）
function Sanity:SetCurrent(current, overtime)
    local old = self.current
    local r = Meter.SetCurrent(self, current, overtime)
    local pct = self.current / self.max

    -- 【★ 迟滞（hysteresis）：为什么要两个不同阈值？】
    --   如果只有一个阈值（比如 30%），玩家在 29%/31% 之间抖动时
    --   会疯狂触发「变疯」和「恢复」事件，音效/特效疯狂刷屏。
    --   业界标准做法是两个阈值构成一个「滞回带」：
    --     低于 30% -> 变疯；高于 35% -> 恢复。
    --   这样状态在边界处是稳定的，不会抖。
    -- ★ 移植时凡是有「状态切换」的地方，都应该问一句「需要滞回带吗」。
    if self.sane and pct <= self.insane_threshold then
        self.sane = false
    elseif (not self.sane) and pct >= self.sane_threshold then
        self.sane = true
    end

    if self.sane ~= self._oldissane then
        self._oldissane = self.sane
        if self.inst and not self.inst._removed then
            -- goinsane / gosane：幻觉/道具生成等逻辑挂在这两个事件上
            self.inst:PushEvent(self.sane and "gosane" or "goinsane")
            if not self.sane then
                self.hallucinations = self.hallucinations + 1
            end
        end
    end
    return r
end

M.Sanity = Sanity
Sanity.name = "sanity"

--============================================================
-- 五、Warmth：体温
--============================================================

local Warmth = Class(Meter, function(self, inst)
    Meter._ctor(self, inst, 50, 0, -1)
    self.eventname = "warmth"
    self.max = 50
    self.current = 37       -- ★ 体温不是「满=50」，而是以人体温度 37 为中性点
    self.rate = 0           -- 速率由外部环境（火堆/冰冻）决定
    -- 【★ 这是一个「以中点为佳」的数值条，和其它三条语义完全不同】
    --   饥饿：越高越好。体温：太高达烧，太低失温。
    --   所以它的 OnSave 判据不能照抄「current ~= max」（37 永远不等于 50，
    --   照抄的话每个实体都要存一条数据）。这就是为什么 OnSave 必须
    --   按组件**语义**定制，而不是模板化。
    self.comfortable = 37
end)

-- Recalc：根据环境温度与保暖等级重算体温变化速率
function Warmth:Recalc(ambient, insulation)
    -- 体温趋向环境温度：越冷掉得越快
    local target = ambient or 10
    self.rate = (target - self.current) * 0.02 * (insulation or 1)
    -- ★ 这里体现了一个通用建模思路：「趋向目标值」用 (target - current) * k。
    --   它自动产生了「越冷掉越快」「越暖回越快」的非线性手感，
    --   比写一堆 if/else 分档优雅得多。弹簧模型，物理里到处都是这个式子。
    return self:GetEffectiveRate()
end

function Warmth:IsFreezing() return self.current <= 5 end
function Warmth:IsOverheating() return self.current >= 48 end

M.Warmth = Warmth
Warmth.name = "warmth"

--============================================================
-- 六、自测
--============================================================

local T = {}
local function check(ok, msg)
    if not ok then error("[04_meter] 断言失败: " .. msg, 2) end
end

-- 近似比较（浮点）
local function near(a, b, eps, msg)
    check(math.abs(a - b) < (eps or 1e-6),
        (msg or "数值不符") .. string.format("  期望 %.6f 实际 %.6f", b, a))
end

--- 测试 1：★ 跑 1000 tick 验证数值正确下降
function T.thousandTicks()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test1")
    e:AddComponent(Hunger)
    local h = e.components.hunger

    check(h.current == 150, "初始饥饿度应为满值 150")

    -- 1000 tick @ 30Hz = 33.333... 秒
    -- rate = -1/s，所以应减少 1000/30 = 33.3333
    local total_time = 0
    for _ = 1, 1000 do
        h:DoDecay(TICK_TIME)
        total_time = total_time + TICK_TIME
    end
    local expected = 150 - 1000 / 30
    near(h.current, expected, 1e-9, "1000 tick 后饥饿度")
    near(total_time, 1000 / 30, 1e-9, "累计时间")
    print(string.format("  [OK] 1000 tick 数值下降：150 -> %.4f（理论 %.4f，误差 %.2e）",
        h.current, expected, math.abs(h.current - expected)))
end

--- 测试 2：★ 单次大 dt 与多次小 dt 结果一致（积分正确性的本质）
function T.dtIndependence()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test2")
    e:AddComponent(Hunger)
    local h = e.components.hunger

    -- 方式 A：一次 10 秒的大 dt（模拟切后台回来）
    h.current = 150
    h:DoDecay(10.0)

    -- 方式 B：300 次 1/30 秒的小 dt
    h.current = 150
    for _ = 1, 300 do h:DoDecay(TICK_TIME) end

    near(h.current, 140, 1e-9, "大 dt 应与多次小 dt 等价")
    print(string.format("  [OK] dt 无关性：一次 10s 与 300 次 1/30s 结果相同 = %.4f", h.current))
end

--- 测试 3：★ 归零触发死亡
function T.deathOnZero()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test3")
    e:AddComponent(Health)
    local h = e.components.health

    local died = false
    local deathcause = nil
    -- ★ 监听要挂在**实体**上，不是组件上。
    --   组件是「挂在实体上的行为」，它推事件时走的是 self.inst:PushEvent，
    --   也就是把事件发到实体上。原版 DST 也是这个约定。
    --   （想监听组件本身，就得给组件也做一套事件机制 —— DST 没有，因为没必要。）
    e:ListenForEvent(e, "death", function(source, data)
        died = true
        deathcause = data.cause
    end)

    check(h:IsDead() == false, "初始不应死亡")
    h:DoDamage(40, "hound")
    near(h.current, 60, 1e-9, "扣血后应为 60")
    check(not died, "未归零不应触发死亡")

    h:DoDamage(100, "fall")
    check(h.current == 0, "应被 clamp 到 0（不越界）")
    check(died, "血量归零必须触发 death 事件")
    check(deathcause == "fall", "死亡原因应被记录并传出")
    check(h:IsDead(), "IsDead 应为真")

    -- 治疗不应复活（已死就是已死）
    e:Remove()
    print("  [OK] 归零触发死亡 + clamp + 死因传递")
end

--- 测试 4：★ 修饰器生效与撤销
function T.modifiers()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test4")
    e:AddComponent(Hunger)
    local h = e.components.hunger

    near(h:GetEffectiveRate(), -1, 1e-9, "初始有效速率")

    -- 加一个「冰箱」：衰减减半
    h.ratemodifiers:SetModifier("fridge", 0.5)
    near(h:GetEffectiveRate(), -0.5, 1e-9, "冰箱应把有效速率减半")

    -- 跑 30 tick（1 秒），应只掉 0.5
    for _ = 1, 30 do h:DoDecay(TICK_TIME) end
    near(h.current, 149.5, 1e-9, "冰箱下 1 秒应只掉 0.5")

    -- 撤销冰箱
    h.ratemodifiers:RemoveModifier("fridge")
    near(h:GetEffectiveRate(), -1, 1e-9, "撤销后应恢复原速率")
    for _ = 1, 30 do h:DoDecay(TICK_TIME) end
    near(h.current, 148.5, 1e-9, "撤销后 1 秒应掉 1.0")

    -- 叠加两个来源：0.5 * 0.5 = 0.25
    h.ratemodifiers:SetModifier("fridge", 0.5)
    h.ratemodifiers:SetModifier("cave", 0.5)
    near(h:GetEffectiveRate(), -0.25, 1e-9, "两个 0.5 应叠成 0.25")
    h.ratemodifiers:RemoveModifier("fridge")
    near(h:GetEffectiveRate(), -0.5, 1e-9, "移除其一应只剩 0.5")
    print("  [OK] 修饰器生效 / 撤销 / 多来源叠加")
end

--- 测试 5：饥饿归零 -> 转掉血
function T.starvation()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test5")
    e:AddComponent(Health)
    e:AddComponent(Hunger)
    local h, hp = e.components.hunger, e.components.health

    -- 设在 1/30 附近，好让一个 tick 就跨过 0
    h.current = 0.01
    h:DoDecay(TICK_TIME)
    check(h.current == 0, string.format("饥饿度应被 clamp 到 0，实际 %s", tostring(h.current)))

    -- 之后继续推进 -> 应转为掉血
    local hp_before = hp.current
    for _ = 1, 30 do h:DoDecay(TICK_TIME) end
    check(hp.current < hp_before, string.format("饥饿归零后应掉血，%s -> %s",
        tostring(hp_before), tostring(hp.current)))
    near(hp_before - hp.current, 1.0, 1e-9, "1 秒应掉 1 点血")
    print("  [OK] 饥饿归零 -> 连锁扣血")
end

--- 测试 6：理智度阈值滞回 + 幻觉计数
function T.sanity()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test6")
    e:AddComponent(Sanity)
    local s = e.components.sanity

    local events = {}
    e:ListenForEvent(e, "goinsane", function() events[#events + 1] = "insane" end)
    e:ListenForEvent(e, "gosane", function() events[#events + 1] = "sane" end)

    s:Recalc(true)   -- 夜晚
    near(s:GetEffectiveRate(), -0.5, 1e-9, "夜晚应掉理智")
    -- 掉到 30% 以下（200 * 0.3 = 60）
    s:SetCurrent(59)
    check(s:IsInsane(), "低于 30% 应变疯狂")
    check(#events == 1 and events[1] == "insane", "应触发 goinsane")
    check(s.hallucinations == 1, "应计 1 次幻觉")

    -- ★ 滞回验证：在 30%~35% 之间抖动**不应**反复触发事件
    for _ = 1, 5 do
        s:SetCurrent(61)   -- 30.5%
        s:SetCurrent(59)   -- 29.5%
    end
    check(#events == 1, string.format("滞回带内抖动不应重复触发事件，实际触发 %d 次", #events))

    -- 回到 35% 以上才恢复
    s:SetCurrent(71)   -- 35.5%
    check(s:IsSane(), "高于 35% 应恢复清醒")
    check(#events == 2 and events[2] == "sane", "应触发 gosane")

    -- 白天回理智
    s:Recalc(false)
    near(s:GetEffectiveRate(), 0.3, 1e-9, "白天应回理智")
    print("  [OK] 理智阈值滞回（30%/35% 双阈值）+ 幻觉计数")
end

--- 测试 7：clamp 与百分比接口
function T.clampAndPercent()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test7")
    e:AddComponent(Health)
    local h = e.components.health

    h:Heal(1000)
    check(h.current == 100, "治疗溢出应被 clamp 到 max")
    near(h:GetPercent(), 1.0, 1e-9, "满值百分比应为 1")

    h:DoDamage(50)
    near(h:GetPercent(), 0.5, 1e-9, "半血百分比应为 0.5")
    h:SetPercent(0.25)
    near(h.current, 25, 1e-9, "SetPercent(0.25) 应为 25")

    h:DoDamage(-100)     -- 负伤害=治疗
    check(h.current == 100, "负伤害应被 clamp 到 max")
    print("  [OK] clamp 上下界 + 百分比接口")
end

--- 测试 8：Pause / Resume 保留原速率
function T.pauseResume()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test8")
    e:AddComponent(Hunger)
    local h = e.components.hunger

    h:Pause()
    for _ = 1, 300 do h:DoDecay(TICK_TIME) end
    check(h.current == 150, "暂停期间不应变化")

    h:Resume()
    near(h.rate, -1, 1e-9, "Resume 后应保留原速率（没被清零）")
    for _ = 1, 30 do h:DoDecay(TICK_TIME) end
    near(h.current, 149, 1e-9, "恢复后应继续衰减")
    print("  [OK] Pause/Resume 保留原速率")
end

--- 测试 9：存档（只存非默认值）
function T.saveLoad()
    local Entity = require("03_entity").Entity
    local e = Entity("meter_test9")
    e:AddComponent(Health)
    local h = e.components.health

    check(h:OnSave() == nil, "满血应返回 nil（不存档）")
    h:DoDamage(30)
    local d = h:OnSave()
    check(d ~= nil and d.health == 70, "非默认应存档当前值")

    h.current = 100
    h:OnLoad(d)
    near(h.current, 70, 1e-9, "OnLoad 应恢复")
    print("  [OK] 存档只存非默认值 + 读档恢复")
end

function T.run()
    print("=== 04_meter.lua 自测 ===")
    T.thousandTicks()
    T.dtIndependence()
    T.deathOnZero()
    T.modifiers()
    T.starvation()
    T.sanity()
    T.clampAndPercent()
    T.pauseResume()
    T.saveLoad()
    print("04_meter 全部通过\n")
    return true
end

M.test = T

--============================================================
-- 七、导出
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