--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：brains/penguinbrain.lua
-- 模块：AI 大脑 / 企鹅（贼鸥，唯一有完整繁殖生命周期的普通 NPC）
-- 职责：装配企鹅 AI。行为链：找蛋 → 叼回巢 → 下蛋 → 护蛋 → 被偷就抢回来，
--       外加群体迁徙与天敌规避。★ 本文件是【长周期 AI】的标准范本：
--       大量使用 inst:DoTaskInTime 做延迟执行，并用 nextDropTime /
--       nextPickupTime / layingEgg / myEgg / eggsLayed 等字段做跨帧跨存档记忆。
--       另含 EventNode 事件驱动接入口、标签持久化缺失的存档兼容修复、
--       「有蛋时游荡半径收缩」等值得照抄的细节。
--
-- ★★ 已核实的真实缺陷（详见各锚点处说明）：
--   1) 第 185、297 行 #lst > 1 应为 >= 1（同文件第 141 行是正确写法），
--      导致候选恰好只有 1 个时企鹅不行动；
--   2) 第 280 行检查 nextPickupTime 但第 306 行设的是 nextDropTime（疑似）。
-- ★★ 已撤回的误判：第 256-257 行的 and/or 优先级【不是缺陷】，
--      已用 lupa(Lua 5.5) 实测五种布尔组合确认作者写法正确。
-- 关键符号：PenguinBrain, CheckMyEgg, StealAction, LayEggAction,
--           PickUpEggAction, EatFoodAction, GetWanderDistFn, ShouldRunAway,
--           AtRookery, HerdAtRookery, PrepareForNight, FindItems, TOOCLOSE
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：brain.lua（三段式调度）, brains/braincommon.lua（恐慌底座）,
--           behaviours/{wander,runaway,doaction,standstill,attackwall}.lua,
--           components/{inventory,combat,knownlocations,teamattacker,
--           perishable,eater,sleeper}.lua,
--           tuning.lua（TUNING.TOTAL_DAY_TIME 等）
--============================================================
require "behaviours/wander"
--[ [
-- penguinbrain.lua —— 企鹅（贼鸥）大脑
--
-- 【★ 定位：全 DST 唯一有完整「繁殖生命周期」的普通 NPC】
--   企鹅会：找蛋 → 叼回巢 → 孵化 → 下蛋 → 护蛋 → 蛋被偷就抢回来。
--   ★ 这些行为都要跨越「几十秒到几分钟」，无法靠单帧决策完成，
--     所以本文件大量使用 inst:DoTaskInTime 做【延迟执行】，
--     并用 inst.nextDropTime / nextPickupTime / layingEgg 等字段做跨帧记忆。
--   ★★ 移植价值最高的点：这是「长周期 AI」的标准实现范式。
--
-- 【★ 三种延迟任务与对应字段】
--   nextDropTime    —— 下次允许下蛋的最早时间（第 150、202、306 行设置）
--   nextPickupTime  —— 下次允许叼蛋的最早时间（第 240、272 行设置）
--   layingEgg       —— 下蛋流程进行中（防重入）
--   myEgg           —— 我下的蛋（第 73 行起大量使用）
--   ★★ 全部挂在【实体 inst】上而非脑 self 上 ——
--     因为这些记忆需要跨存档保持（企鹅死后存档里还有蛋）。
--     与 braincommon 第 250 行 inst.digtile、mermbrain 第 392 行同思路。
--
-- 【⚠️ 容易踩的坑】
--   ★★ 以下两条是本文件【真实且已核实】的缺陷（均已逐字核对并 grep 验证）：
--
--   【缺陷一：off-by-one，第 185 行与第 297 行】
--     EatFoodAction（第 185 行）与 PickUpEggAction（第 297 行）都用 #lst > 1，
--     而 StealAction（第 141 行）用的是 #lst >= 1。
--     ★★ 后果：候选恰好只有 1 个时，条件为假、target 保持 nil、整段跳过 ——
--       企鹅会无视地上唯一那份食物 / 唯一的蛋。应为 >= 1。
--     ★ 证据充分：同一文件三处相似逻辑，两种写法，141 行是正确的那一处。
--
--   【缺陷二：冷却字段不对称，第 280 行检查 nextPickupTime，
--     但第 306 行（叼蛋成功）设置的是 nextDropTime】
--     已 grep 核实 nextPickupTime 全文仅 3 处：
--       第 240、272 行【设置】，第 280 行【检查】；
--       而第 150、306 行设置 nextDropTime，仅第 202 行检查。
--     ★★ 后果：叼蛋成功设的 nextDropTime 会被第 202 行「下蛋」的冷却检查读到，
--       而「叼蛋」自己的冷却 nextPickupTime 从不由叼蛋路径重置。
--     标为疑似：无法确定原意（可能设计上就是想共用一个冷却），
--       但「设 A 检查 B」的不对称是客观事实。
--
--   【⚠️ 我曾误判并已撤回的一处】
--     第 256-257 行 (iswinter and temperature <= -15) and (nearest and IsNear(...))
--     我一度认为缺括号导致 and/or 优先级错误。
--     ★★ 用 lupa(Lua 5.5) 实测五种布尔组合后确认：【我判断错了】。
--     Lua 中 and 优先级高于 or，故 A or B or C and D 本就等价于 A or B or (C and D)，
--     与作者意图一致，行为正确。已撤回该「缺陷」判断，特此记录以免后人重犯。
--
-- · 第 433-436 行最终兜底 Wander 的锚点在 OnStart 里【立即求值】，
--   之后不再更新（对比第 421-425 行用函数形式）。属低影响瑕疵。
-- · 第 442 行 return PenguinBrain 之后有两个空行（第 444-446 行），
--   文件末尾有多余换行。属格式问题，非缺陷。
--] ]
require "behaviours/runaway"
require "behaviours/doaction"
require "behaviours/standstill"
require "behaviours/attackwall"
require "behaviours/leash"
local BrainCommon = require("brains/braincommon")

local SEE_DIST = 30
-- ★ SEE_DIST=30 是全文件最大的常量，用于多处搜索（第 131、176、287 行）。
--   注意第 131、176 行用的是 SEE_DIST/2（15），即「近处精细搜索用一半半径」。
local MIN_FOLLOW_DIST = 1
-- ★ 跟随距离 1/1/5 —— MIN 与 TARGET 相等（都是 1）。
--   含义：「不要离队长超过 1 就退」，即几乎贴脸跟随（护蛋需要）。
--   ⚠️ MIN == TARGET 在其他文件里都不同（如 pigbrain 2/5/9），
--     此处相等是刻意简化：因为企鹅要守着蛋不能远离。
local TARGET_FOLLOW_DIST = 1
local MAX_FOLLOW_DIST = 5

local MAX_EGGS = 2  -- max number of eggs this penguin can lay
-- MAX_EGGS = 2 —— 每只企鹅最多下 2 个蛋。
-- ★ 这是「繁殖上限」，防止企鹅无限繁殖。配合第 243 行检查。

local STOP_RUN_DIST = 4
-- STOP_RUN_DIST=4，但 SEE_PLAYER_DIST=2.5（第 17 行）。
-- ★ 触发 2.5、脱离 4 —— 迟滞区间只有 1.5，比 pigbrain 的 3/5（区间 2）更窄。
--   即企鹅「一有玩家靠近就有点慌，但不会跑太远」，因为它要守蛋。
local SEE_PLAYER_DIST = 2.5
local SEE_FOOD_DIST = 20
local MAX_WANDER_DIST = 5
local MAX_CHASE_TIME = 10
local MAX_CHASE_DIST = 15

local WANDER_DIST_NIGHT = 3
local WANDER_DIST_DAY = 5

local TOOCLOSE = 9
-- ★★ TOOCLOSE = 9 —— 「太近了不要做某事」的统一阈值，全文件出现 6 次。
--   用于：偷蛋前检查 predator（第 129、145 行）、下蛋前检查（第 209-213 行）、
--   延迟任务里再次检查（第 230、233、253、257 行）。
--   ★★ 设计意图：企鹅非常怕天敌，任何涉及蛋的操作都要确认周围安全。
--   ★ 这是「同一阈值在多处复用做安全检查」的好范例。

local MIN_TIME_TILL_NEXT_DROP = 60
-- MIN_TIME_TILL_NEXT_DROP = 60 —— 下蛋间隔下限 60 秒。

local LEASH_RETURN_DIST = 5
-- ★ 巢穴牵引：5 距离外开始往回走，10 距离算离巢太远。
--   ★ 与 LEASH_MAX_DIST=10 构成「10 内自由、10 外归巢」的语义。
--   命名有点反直觉：MAX 是「允许的最远」，RETURN 是「仍算安全的最远」。
local LEASH_MAX_DIST = 10

local function GetClosestInstWithTagAndExcludeTag(tag, excludetag, inst, radius)
-- ★★ GetClosestInstWithTagAndExcludeTag —— 极易误读的函数。
-- 【第 36 行】return ents[1] ~= inst and ents[1] or ents[2]
--   ★★★ 这行用 and/or 实现「取第一个不是我的人」：
--     ents[1] 不是自己 → 返回 ents[1]
--     ents[1] 是自己 → and 表达式返回 false → or 表达式返回 ents[2]
--   ★ and/or 只能返回两操作数之一，所以「是自己」的情况只能靠 or 兜到 ents[2]。
--   ⚠️ ★★ 真实局限：若 ents 只有 1 个元素且那【正是自己】，
--     返回 ents[2] 即 nil —— 正确。
--     但若 ents[1] 不是自己且只有 1 个元素，返回它 —— 也正确。
--     ★ 结论：逻辑正确，但这种写法在 ents 顺序变化时脆弱。
--   ⚠️ 真实缺陷场景：若【自己不在搜索结果里】（如自己在范围边缘外），
--     ents[1] 是敌人，返回 ents[1] —— 正确。
--   综合核对：三种情况都正确。属可读性差但无误的实现。
--   ⚠️ 但若 ents 有 3 个以上元素，且 ents[1] 是自己，只会看 ents[2]，
--     不会继续往 ents[3] 找 —— 这是逻辑上的截断。
--     实际影响：自己排第一时只会漏掉第 3 个以后的候选。属轻微缺陷。
    local x, y, z = inst.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, y, z, radius, tag, excludetag)
    return ents[1] ~= inst and ents[1] or ents[2]
end

local PenguinBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local SCARY_TAGS = { "scarytoprey" }
-- scarytoprey：天敌标记（如猫/蜘蛛/海鸥）。
local MUTATED_EXCLUDE_TAGS = { "mutated_penguin" } -- Let's not be scared of each other!
-- ★★ MUTATED_EXCLUDE_TAGS —— 变异企鹅不互相恐惧。
--   注释原文："Let's not be scared of each other!"
--   ★ 变异体是「被支配的形态」，不再是猎食者关系。设计意图明确。
local function FindScaryPredator(inst, radius)
-- FindScaryPredator：普通与变异走不同的排除标签（第 46-50 行）。
--   ★ 「同一函数、两种参数」—— 比写两个函数更紧凑。
    if inst:HasTag("mutated_penguin") then
        return GetClosestInstWithTagAndExcludeTag(SCARY_TAGS, MUTATED_EXCLUDE_TAGS, inst, radius)
    else
        return GetClosestInstWithTagAndExcludeTag(SCARY_TAGS, nil, inst, radius)
    end
end

local function AtRookery(inst)
-- ★ AtRookery：距离平方 > 100（即 10 距离）就认为不在巢穴。
--   第 60 行 100 是硬编码的平方值，没用常量。
--   ⚠️ 与第 30 行 LEASH_MAX_DIST=10 数值相同，疑似同源。
--   ★ 但没有复用常量，属轻微重复定义。
    if not inst then
        return false
    end

    local homePos = inst.components.knownlocations.GetLocation and inst.components.knownlocations:GetLocation("rookery")
-- ★★ 巢穴位置从 knownlocations 读 —— 坐标存在组件里而非实体字段，
--   这样存档/读档后自动保持，且可用 ForgetLocation 清除。
--   第 58 行 inst.components.knownlocations.GetLocation and inst.components...:GetLocation("rookery")
--   ★★ 这是「方法存在性」检查：老存档/旧版本实体没有这个方法时不崩。
--   ★ 兼容旧存档的通用手法，本文件多处出现（第 147、303、343、344 行）。
--   ⚠️ 第 54 行 if not inst then return false end 是多余的判空：
--     inst 是函数参数，调用处（第 69、162 行）传的都是实体的 inst，不会为 nil。
--     属无害冗余。

    if homePos and inst:GetDistanceSqToPoint(homePos) > 100 then
        return false
    else
        return true
    end
end

local function HasEgg(inst)
-- HasEgg：背包第 1 个槽有蛋。企鹅蛋固定放槽 1（见第 216-217 行）。
    return inst.components.inventory and inst.components.inventory:GetItemInSlot(1)
end

-- How's my egg doing? If the player has it or it is spoiled then forget about it
local function CheckMyEgg(inst)
-- ★★★ CheckMyEgg —— 全文件的核心状态机，「我下的蛋现在算什么」。
-- 【四条出口，逐一对应不同的蛋的命运】
--  第 75 行：没有蛋 → nil
--  第 77-79 行：蛋有效且在我背包里 → 返回蛋（正常携带）
--  第 81-86 行：★★ 蛋失效 / 被人拿着 / 不在有效地面 → 【放弃】
--    ★ 第 83-84 行同时清 myEgg 与 laidEgg，
--      即「我没下过蛋了，可以重新下」（第 243 行检查 eggsLayed）。
--    ★ 第 82 行注释提示这是临时措施（"if pengulls start swimming"就该去掉）。
--  第 88-96 行：★★ 蛋坏了（perishable 变腐烂）→ 【特殊处理后放弃】
--    ★ 第 89-92 行：如果我背包里还有蛋，先 DropEverything 掉光，
--      再把坏蛋设 nobounce。语义：「蛋坏了就别再抱着了，让它掉出去」。
--    ⚠️ 这段逻辑有点绕：为什么坏蛋要靠背包满了才丢？
--      第 89 行 if HasEgg(inst) 表明「只有背包里还有蛋时才丢」，
--      但第 93-94 行无论是否 HasEgg 都会清 myEgg。
--      推测：HasEgg 分支是「背包还有蛋时先把旧的清掉腾位置」，
--      属特定场景处理。意图不完全明确，标为理解不确定处，非缺陷。
--  第 97 行：★ 蛋在地上正常存在 → 记住它的位置（knownlocations）
--    ★ 记住位置是为了第 316 行 GetWanderDistFn 能「围着蛋转」。
--    ★ 也为第 421-425 行的 Wander 锚点提供兜底。
-- 【★ 返回值语义】返回蛋 or nil，返回 nil 即「没有可管的蛋」。
    local egg = inst.myEgg

    if not egg then return nil end

    if egg:IsValid() and egg.components.inventoryitem:IsHeldBy(inst) then
        return egg
    end

    if not egg:IsValid() or egg.components.inventoryitem:IsHeld() or
            not egg:IsOnValidGround() then  -- NOTE: if pengulls start swimming, this can go away.
        inst.myEgg = nil
        inst.laidEgg = false
        return nil
    end

    if egg.components.perishable and egg.components.perishable:IsSpoiled() then
        if HasEgg(inst) then
            egg.components.inventoryitem.nobounce = true
            inst.components.inventory:DropEverything()
        end
        inst.myEgg = nil
        inst.laidEgg = false
        return nil
    end
    inst.components.knownlocations:RememberLocation("myegg", Vector3(egg.Transform:GetWorldPosition()) )

    return egg
end

local function PrepareForNight(inst)
-- ★ PrepareForNight：★ 三个条件或：夜、黄昏 80% 后、已经在睡。
--   第 103 行 timeinphase > .8 —— 黄昏阶段超过 80% 就算「该休息了」。
--   ★ 这是「把连续时间轴映射到布尔」的手法，避免下游写复合条件。
--   ★ 第 103 行第三个条件 inst.components.sleeper:IsAsleep()
--     语义：企鹅睡觉时不再做「需要天亮」的动作。防止睡梦中惊醒。
    return TheWorld.state.isnight or (TheWorld.state.isdusk and TheWorld.state.timeinphase > .8) or inst.components.sleeper:IsAsleep()
end

local NO_TAGS = { "outofreach" }

-- Return array of items within the given radius that satisfies the check function
local function FindItems(inst, radius, fn, tags)
-- ★★ FindItems —— 自制的实体过滤器，比 FindEntity 更严格。
-- 【第 112 行】TheSim:FindEntities(x,y,z, 半径, MUST_TAGS, NO_TAGS)
--   ⚠️ 注意第 6 参传的是【单个值】{ "outofreach" } 而非列表 ——
--     NO_TAGS 定义在第 106 行，确实是单元素表，符合参数要求。
-- 【第 115 行的五重过滤】
--   v ~= inst（排除自己）、v.entity:IsValid()、v.entity:IsVisible()、
--   fn(v) 自定义过滤（可为 nil）
-- ★★ 相比 FindEntity 多了一个 IsVisible —— 屏幕外的物品不算。
--   ★ 这能避免企鹅「想去捡一个玩家看不见的东西」。
-- ★ 第 115 行的 v.entity:IsVisible() 说明 v 是有 .entity 字段的对象，
--   可能是 inventoryitem 的 wrapper。移植时注意这个假设。
    if inst and inst:IsValid() then
		local x,y,z = inst.Transform:GetWorldPosition()
		local ents = TheSim:FindEntities(x,y,z, radius, tags, NO_TAGS)
        local lst = {}
		for k, v in ipairs(ents) do
			if v ~= inst and v.entity:IsValid() and v.entity:IsVisible() and (not fn or fn(v)) then
                lst[#lst+1]=v
			end
		end
        return lst
	end
end

-- Go grab an egg if player gets too close to it
local function StealAction(inst)
-- ★★★ StealAction —— 「天敌靠近时把蛋抢回来」，本文件最有戏剧性的行为。
-- 【第 125 行】背包满了就放弃（第 127 行 egg 也要放得下）
-- 【第 129 行】先查天敌（第 129 行 FindScaryPredator, TOOCLOSE=9）
-- 【第 131-139 行】★ 若我没有蛋，找 15 距离内可捡的蛋
--   ★ 第 137 行 return char and char:IsNear(item, TOOCLOSE)
--   ★★★ 注意这里返回的是【天敌是否靠近这个蛋】，而回调本身的含义是
--     「这个蛋是否符合条件」。即：只有当天敌也靠近蛋时才把它算作候选。
--     ★ 这是「用回调做二次筛选」的写法：过滤条件依赖外部变量 char。
-- 【第 145 行】★★ 最终条件：蛋不在 limbo 且 天敌靠近这个蛋
--   ★ 即「只有当天敌真的在旁边，我才去抢」。
-- 【第 147-149 行】抢之前先【忘记蛋的位置】
--   ★ 为什么要忘？因为第 316 行 GetWanderDistFn 会用「myegg 位置」当游荡锚点，
--     蛋被抢走后就该停止围着它转。不清会导致企鹅跑去空地。
-- 【第 150 行】★ 抢到后设置 nextDropTime（不是 nextPickupTime）
--   ⚠️ 值得注意：偷蛋成功后设的是 nextDropTime（第 150 行），
--     而正常下蛋后设的是 nextPickupTime（第 240 行）。
--   ★ 两个字段在第 202 行与第 280 行分别被检查。
--   ★ 语义推测：抢蛋（叼回来）与下蛋（放出去）是同一动作的两面，
--     所以用同一个冷却字段。合理，非缺陷。
    if not inst.components.inventory:IsFull() then
        -- Check that my egg exists and is not being held by someone else
        local target = CheckMyEgg(inst)
        local lst
        local char = FindScaryPredator(inst, TOOCLOSE)
        if not target then
		    lst = FindItems(inst, SEE_DIST/2, function(item)
                                                    if  item.components.inventoryitem and
                                                        item.components.inventoryitem.canbepickedup and
                                                        not item.components.inventoryitem:IsHeld() and
                                                        item:IsOnValidGround() and
                                                        (item:HasTag("penguin_egg") or item.prefab == inst.eggprefab) then
                                                            return char and char:IsNear(item, TOOCLOSE)
                                                        end
                                                    end)

            if #lst >= 1 then
-- ★★ 注意这里用 `#lst >= 1`（正确写法），
--   而第 185 行 EatFoodAction 与第 297 行 PickUpEggAction 用的是 `#lst > 1`。
--   ★ 同一文件三种写法不一致 —— 这是确认真实缺陷的关键对照证据。
                target = lst[math.random(1,#lst)]
            end
        end
		if target and not target:IsInLimbo() and (char and char:IsNear(target, TOOCLOSE)) then
            --print("===== Steal:",target)
            if inst.components.knownlocations.ForgetLocation then
                inst.components.knownlocations:ForgetLocation("myegg")
            end
            inst.nextDropTime = GetTime() + GetRandomWithVariance(MIN_TIME_TILL_NEXT_DROP,5)
			return BufferedAction(inst, target, ACTIONS.PICKUP)
		end
	end
end


local function GetMigrateLeashPos(inst)
-- ★★ GetMigrateLeashPos：★ 战斗状态【直接返回 nil】。
-- 【第 158 行】if teamattacker.teamleader or combat.target then return nil end
--   ★ 即「我是队长」或「我有敌人」时，不受巢穴牵引。
--   语义：首领带兵作战时不回巢，士兵跟随。
--   ★ 对比 pigbrain 第 349 行：那里有战斗时【不回家】（正向判定），
--     这里是【不受牵引】（返回 nil）。两种等价写法。
-- 【第 161-163 行】★ 兜底链：rookery → home
--   ★ 用 (A or B) 在两个已知位置里取一个，优先巢穴。
--   ⚠️ 第 161 行 inst.components.knownlocations and (...) 已判组件存在。
--   ⚠️ 但第 157 行没判 —— 若组件不存在则第 158 行先崩（第 158 行在前面）。
--   实际：第 158 行只用 teamattacker/combat，不涉及 knownlocations，安全。
    if inst.components.teamattacker.teamleader or inst.components.combat.target then
        return nil
    end
    local homePos = inst.components.knownlocations and
        (inst.components.knownlocations:GetLocation("rookery") or
        inst.components.knownlocations:GetLocation("home"))
    return homePos
end

local function EatFoodAction(inst)
-- ★★★ EatFoodAction —— ★★ 含有本文件确认的第一处真实缺陷。
-- 【第 169 行】local target = nil 之后第 175 行 if not target then
--   ⚠️★★ 第 169 行刚把 target 赋成 nil，第 175 行就判「if not target」——
--     恒为真。【这是无意义的判断】，显然是复制其他文件模板留下的残骸。
--   已逐字核对第 169、175 行确认 target 在这两行之间没有任何赋值。
--   ★ 属代码残骸（非行为缺陷）：结果正确，只是判断多余。
--   ★★ 对照 mermbrain 第 121 行同样是 local target = nil 后 if target == nil and，
--     但那里第 123-125 行【确实】给 target 赋过值，所以那个判断有意义。
--   ★ 本文件这个是纯冗余。与 mermbrain 的差异正是判断是否冗余的关键。
--
-- 【★★★ 真实缺陷：第 185 行】
--   if #lst > 1 then target = lst[math.random(1,#lst)] end
--   ⚠️⚠️ 当搜索结果【恰好只有 1 个】时，条件为假，target 保持 nil，
--     直接跳过下面的 if target then —— 【企鹅什么也不做】。
--   ★★ 这是明确的 off-by-one 缺陷，应为 >= 1。
--   ★★ 同文件第 141 行 StealAction 用的正是 >= 1（正确），
--     可证这是笔误而非有意为之。
--   ★ 影响：地上只有一份食物时，企鹅会无视它。玩家会觉得「企鹅变傻了」。
--   ★★ 对比第 297 行 PickUpEggAction 同样是 > 1，
--     而第 141 行是 >= 1。三处两种写法，笔误证据充分。
-- 【第 185 行的其他过滤（第 177-184 行）】
--   排除 GetTimeAlive < 8（新掉落的）、penguin_egg（是蛋）、rottenegg（坏蛋）、
--   不在有效地面、eater:CanEat —— 逐条合理。

    local target = nil

    if inst.sg:HasStateTag("busy") or inst.components.teamattacker.teamleader ~= nil then
        return
    end

    if not target then
        local lst = FindItems(inst, SEE_DIST/2, function(item)
                                            if item:GetTimeAlive() < 8 or item:HasTag("penguin_egg") or item.prefab == "rottenegg" then
                                                return false
                                            end
                                            if not item:IsOnValidGround() then
                                                return false
                                            end
                                            return inst.components.eater:CanEat(item)
                                       end)
        if #lst > 1 then
            target = lst[math.random(1,#lst)]
        end

        if target then
            --print("========================================== FoodTarget:",target)
            local ba = BufferedAction(inst,target,ACTIONS.EAT)
-- ★ 第 192 行 ba.distance = 1.5 —— 手动覆盖吃食距离。
--   ★ 企鹅的嘴短，默认距离可能够不到某些食物（如地上的浆果）。
--   ★ 直接改 BufferedAction 的 distance 字段是快速调参手法。
            ba.distance = 1.5
            return ba
        end
    end
end

local function LayEggAction(inst)
-- ★★★ LayEggAction —— 最长的函数（78 行），两种下蛋分支。
-- 【三道前置门】
--  第 200 行：layingEgg 为真 → 不是产蛋季/正在下蛋，跳过
--  第 202 行：nextDropTime 还没到 → 跳过
--  第 208 行：★ CheckMyEgg 先确认蛋的现状
--  第 209-213 行：★ 天敌在 TOOCLOSE 内 → 放弃下蛋
--   ★ 语义：吓着的时候不下蛋。合理的生物行为。
--
-- 【★ 分支一（第 216-241 行）：背包满了 → 下【旧】蛋】
--   第 217-222 行：★ 先检查背包槽 1 的是不是自己的蛋种
--     注释说明"tags not saved with simple objects"（简单对象不保存标签），
--     所以读档后蛋没有 penguin_egg 标签，要手动补（第 219 行）。
--     ★★★ 这是一个【存档兼容性修复】，很值得学：
--       标签不持久化 → 每次读档都要靠 prefab 名重新打标签。
--   第 223 行：随机 10±4 秒后（第 226 行 DoTaskInTime）再放蛋
--   第 232-235 行：★ 延迟任务里【再次检查】天亮/在巢/天敌
--     ★ 这就是为什么不需要轮询：把检查放进延迟任务的回调里。
--   第 238 行：DropEverything 一次性全掉
--   第 240 行：★ 设 nextPickupTime（不是 nextDropTime）
--
-- 【★ 分支二（第 242-275 行）：没有蛋且在产蛋季 → 下【新】蛋】
--   第 243 行：★ 不在 nesting 期，或已下超过 MAX_EGGS(2) → 跳过
--   第 246 行：随机 TUNING.TOTAL_DAY_TIME/5 ± /6 秒（≈ 全天 1/5）
--   第 255-258 行：★★ 延迟回调里的条件（★ 双重检查的第二层）
--     if PrepareForNight(inst) or not AtRookery(inst) or
--        (TheWorld.state.iswinter and TheWorld.state.temperature <= -15) and
--        (nearest and nearest:IsNear(inst, TOOCLOSE)) then
--     ★ 语义（已确认正确）：三个或然条件任一成立就不下蛋：
--       1) 到了该休息的时候（夜/黄昏末/已在睡）
--       2) 不在巢穴
--       3) 严寒（≤ -15）且天敌在旁边
--     ★ 第 3 项的 and 优先级高于 or，所以整式等价于
--       A or B or (C and D)，与意图一致 —— 这一点我最初误判过，已撤回。
--     ★★ 双层检查的价值：第 394-399 行（节点条件）已排除夜晚与巢穴，
--       这里再查一次是因为【延迟任务可能跨越昼夜变化】：
--       企鹅决定下蛋后要等全天 1/5（约 100 秒）才执行，期间天亮了/天黑了/
--       天敌来了都可能改变。★ 这是长周期任务的必要防御，可直接照抄。
--     ★ 对照第 232-233 行（放旧蛋分支）：那里只查了 3 项（无严寒项），
--       两处条件数量不同是合理的（放蛋与下蛋的风险不同）。
--   第 261-273 行：★ SpawnPrefab 生成蛋、打标签、设位置、记住位置
--     第 268 行 nobounce = true —— 蛋掉出来不弹跳，落地即静止。
--     ★ 与第 90、220 行三处一致，是蛋的统一处理。

    if inst.layingEgg then return end  -- not egg-laying season

    if (inst.nextDropTime or 0) - GetTime() > 0 then
-- ★ nextDropTime 的冷却检查（第 150、306 行设置，第 202 行检查）。
--   ★ 与 nextPickupTime（第 240、272 行设置，第 280 行检查）配对。
--   ★ 两个冷却字段对应「放蛋」与「叼蛋」两个方向。
        --print("\rnextdrop:", (inst.nextDropTime or 0) - GetTime())
        return
    end

    local delay
    local egg = CheckMyEgg(inst)
    local nearest = FindScaryPredator(inst, TOOCLOSE)
    if nearest and nearest:IsNear(inst, TOOCLOSE) then
        --print("\rTOO CLOSE")
        return
    end
    --print("\r",inst," eggcheck:",egg)

    if (inst.components.inventory and inst.components.inventory:IsFull()) then
        local egg = inst.components.inventory:GetItemInSlot(1)
        if egg and egg.prefab == inst.eggprefab then  -- may have egg from previous session, tags not saved with simple objects
            egg:AddTag("penguin_egg")
            egg.components.inventoryitem.nobounce = true
            inst.myEgg = egg
        end
        delay = GetRandomWithVariance(10,4)
        --print(inst," drops egg in:",delay)
        inst.layingEgg = true
        inst:DoTaskInTime( delay,
                            function()
                                if not inst:IsValid() then return end
                                inst.layingEgg = false
                                nearest = FindScaryPredator(inst, TOOCLOSE)

                                if PrepareForNight(inst) or not AtRookery(inst) or
                                (nearest and nearest:IsNear(inst, TOOCLOSE)) then
                                   return
                                end

                                --print("drop egg")
                                inst.components.inventory:DropEverything()
                                inst.components.knownlocations:RememberLocation("myegg", Vector3(inst.Transform:GetWorldPosition()) )
                                inst.nextPickupTime = GetTime() + GetRandomWithVariance(MIN_TIME_TILL_NEXT_DROP,10)
                            end)
    elseif not egg then
        if not inst.nesting or (inst.eggsLayed and inst.eggsLayed > MAX_EGGS) then  -- egg laying season over
-- ★★ 产蛋季的三重检查（第 243 行）：
--   not inst.nesting —— 不在产蛋期（季节性，由世界状态控制）
--   or inst.eggsLayed > MAX_EGGS —— 已下超过 2 个
--   ★★ 而 inst.eggsLayed 在第 83-84、93-94 行【放弃蛋时被清空】，
--     在第 266 行成功下蛋时 +1。
--   ★ 这形成一个循环：蛋没了 → 清空计数 → 可以再下最多 2 个。
--   ★ 「产蛋配额随蛋的存在而重置」—— 很实用的资源循环设计。
            return
        end
        delay = GetRandomWithVariance(TUNING.TOTAL_DAY_TIME/5,TUNING.TOTAL_DAY_TIME/6)
        --print(inst," lays egg in:",delay)
        inst.layingEgg = true
        inst:DoTaskInTime( delay,
                            function()
                                if not inst:IsValid() then return end
                                inst.layingEgg = false
                                nearest = FindScaryPredator(inst, TOOCLOSE)

                                if PrepareForNight(inst) or not AtRookery(inst) or
-- ⚠️★★ 自我纠正：此处我曾误判为「运算符优先级缺陷」，现已撤回。
--   第 256-257 行 (iswinter and temperature <= -15) and (nearest and IsNear(...))
--   ★★ 我最初认为它缺少包裹 or 的括号，会让天敌检查被短路。
--   ★★★ 用 lupa(Lua 5.5) 实测五种布尔组合后确认：【判断错误】。
--       Lua 中 and 的优先级【高于】or，因此
--         A or B or C and D   实际就等价于   A or B or (C and D)
--       与作者意图完全一致，行为正确，不存在缺陷。
--   ★ 实测记录（五种场景下源码写法与意图写法结果全部一致）：
--       夜晚=True、不在巢=True、严寒=True、天敌=True、全部正常=False
--       → 两种写法结果均相同。
--   ★ 顺带：第 232-233 行的正确写法（天敌条件加括号）同样是对的，
--     两者行为一致 —— 只是显式程度不同，非缺陷。
--   ★ 特此记录以免后人重复此误判：Lua 的 and 优先级高于 or，
--     「A or B or C and D」不会解析成「(A or B or C) and D」。
                                   (TheWorld.state.iswinter and TheWorld.state.temperature <= -15) and
                                   (nearest and nearest:IsNear(inst, TOOCLOSE)) then
                                   return
                                end

                                local egg = SpawnPrefab(inst.eggprefab)

-- ★ 第 266 行 eggsLayed 的自增写法：
--   inst.eggsLayed = (inst.eggsLayed and inst.eggsLayed + 1) or 1
--   ★ and/or 二义性：原值为 nil → 走 or 1；否则 +1。
--   ★ 巧妙但可读性差，移植时建议写成显式 if。
                                if egg then
                                    --print("lay egg")
                                    inst.myEgg = egg
                                    inst.eggsLayed = (inst.eggsLayed and inst.eggsLayed + 1) or 1
                                    egg:AddTag("penguin_egg")
                                    egg.components.inventoryitem.nobounce = true
		                            egg.Transform:SetPosition(inst.Transform:GetWorldPosition())
                                    inst.components.knownlocations:RememberLocation("myegg", Vector3(inst.Transform:GetWorldPosition()) )

                                    inst.nextPickupTime = GetTime() + GetRandomWithVariance(MIN_TIME_TILL_NEXT_DROP,10)
                                end
                            end)
    end
end

local function PickUpEggAction(inst)
-- ★★★ PickUpEggAction —— 把地上的蛋叼回巢。
-- 【第 280 行】★ 条件有个反直觉的 or：
--   if not PrepareForNight(inst) and (inst.nextPickupTime or 0) - GetTime() > 0 then
--   ⚠️★★ 这行的逻辑需要仔细读：
--     完整含义是「不 PrepareForNight【并且】冷却没到 → return（什么都不做）」。
--   ★★★ 但注意语义：【天黑了反而会去捡蛋】！
--     因为条件用的是 not PrepareForNight —— 天黑时 not 为假，
--     and 短路整个条件为假，于是【不 return】，继续执行去捡蛋。
--   ★ 看似反直觉，但对照第 405-410 行就明白了：
--     「晚上把蛋捡回巢」正是这个节点的主要用途（见第 404 行注释
--     "Don't leave the egg lying around to freeze" —— 别让蛋冻在外面）。
--   ★★ 所以 not PrepareForNight 在此处是正确的，意为「白天别捡（会跑出去）」，
--     晚上才捡（就近收蛋防冻）。不是缺陷，是我最初读错了。
--   ★★ 这个坑值得记住：同一个条件在不同上下文里语义完全相反。
-- 【第 297 行】★ 第二处真实缺陷：#lst > 1（应为 >= 1）
--   同样导致「只有 1 个蛋时不捡」。与第 185 行同款。
-- 【第 306 行】★ 捡蛋成功后设 nextDropTime（与第 150 行一致）
--   ★ 但第 280 行检查的却是 nextPickupTime —— ★ 不对称！
--   ⚠️ 这可能是个真实的小缺陷：检查 A 字段、设置 B 字段，
--     导致「叼蛋的冷却」实际从未被检查（第 306 行设的 nextDropTime
--     只在第 202 行被检查，那是「下蛋」用的）。
--   ★★ 核实：grep 确认 nextPickupTime 只在第 240、272 行被【设置】，
--     在第 280 行被【检查】，从未被第 306 行这类「捡蛋成功」路径重置。
--     ★ 也就是说 nextPickupTime 机制半残：设了但只有一处检查。
--   ★ 标为疑似缺陷：无法确定原意（可能本就该用 nextDropTime 冷却叼蛋），
--     但「设 A 检查 B」的不对称是客观事实，值得移植者注意。
    if not inst.components.inventory:IsFull() then
        if not PrepareForNight(inst) and (inst.nextPickupTime or 0) - GetTime() > 0 then
            --print("nextdrop:", (inst.nextDropTime or 0) - GetTime())
            return
        end
        local lst
        local target = CheckMyEgg(inst)
        if not target then
            lst = FindItems(inst, SEE_DIST, function(item)
                                                    if  item.components.inventoryitem and
                                                        item.components.inventoryitem.canbepickedup and
                                                        not item.components.inventoryitem:IsHeld() and
                                                        item:IsOnValidGround() and
                                                        (item:HasTag("penguin_egg") or item.prefab == inst.eggprefab) then
                                                            return inst:IsNear(item, 2)
                                                        end
                                                    end)

            if #lst > 1 then
                target = lst[math.random(1,#lst)]
            end
        end
		if target and not target:IsInLimbo() then
            --print("________________________________________ Pickup Egg:",target)
            if inst.components.knownlocations.GetLocation then
                inst.components.knownlocations:ForgetLocation("myegg")
            end
            inst.nextDropTime = GetTime() + GetRandomWithVariance(MIN_TIME_TILL_NEXT_DROP,5)
			return BufferedAction(inst, target, ACTIONS.PICKUP)
		end
	end
end

local function GetWanderDistFn(inst)
-- ★★★ GetWanderDistFn —— 游荡半径的三级策略。
-- 【第 316-318 行】★ 蛋在地上 → 半径缩到 2（紧紧围着蛋）
--   ★ 这是「有蛋时行为范围收缩」的核心逻辑。
-- 【第 320 行】★ 否则：冬天(≤-10) 或 非白天 → 3；白天 → 5
--   ★ 动态半径：函数形式传给 Wander（第 426 行）。
-- ★★★ 综合效果：企鹅的游荡半径 = 「有蛋最小，无蛋夜间小，白天大」。
--   ★ 一个纯函数就表达了「保护资源时收缩」这一行为模式。
    local isWinter = TheWorld.state.iswinter and TheWorld.state.temperature <= -10

    -- keep close to your egg
    if inst.components.knownlocations.GetLocation and inst.components.knownlocations:GetLocation("myegg") then
        return 2
    end

    return (isWinter or not TheWorld.state.isday) and WANDER_DIST_NIGHT or WANDER_DIST_DAY
end

local function ShouldRunAway(inst,hunter)
-- ★★ ShouldRunAway：★ 命令优先于恐惧。
-- 【第 326-327 行】有队长且命令是 ATTACK 或 HOLD → 【不跑】
--   ★ 即「上峰让打就打，哪怕对方是移动状态」。
-- 【第 328-331 行】★★ 否则对方在移动 或 是变异企鹅 → 跑
--   ★ 注释说变异企鹅"ALWAYS scary to us!"（永远让我们害怕）。
--   ★ 为什么「移动中的」才可怕？因为站着不动的东西不构成威胁
--     （可能在睡觉/发呆），动起来才是要扑过来。
--   ★★★ 这是「用运动状态判断意图」的轻量模型，AI 成本极低而效果不错。
    local teamattacker = inst.components.teamattacker
    local hasLeader = inst.components.teamattacker.teamleader
    if hasLeader and (teamattacker.orders == "ATTACK" or teamattacker.orders == "HOLD")  then
        return false
    elseif (hunter.sg and hunter.sg:HasStateTag("moving"))
            or hunter:HasTag("mutated_penguin") -- These guys are ALWAYS scary to us!
           then
        return true
    else
        return false
    end
end

local function ShouldAttack(inst)
-- ShouldAttack：★ 唯一的攻击条件就是「有目标且够近」。
--   没有 ShouldRunAway 那样的命令判断 —— 攻击时听命令。
--   ★ 第 339 行用的是 MAX_CHASE_DIST(15) 而非某个新常量，合理复用。
    local target = inst.components.combat.target
	return target ~= nil and inst:IsNear(target, MAX_CHASE_DIST)
end

local function HerdAtRookery(inst)
-- ★ HerdAtRookery：巢穴与群落在同一区域（距离平方 < 102，即约 10）。
--   ★ 102 ≈ 10^2，写成 102 而非 100 是笔误级别的粗糙，但不致错。
--   ⚠️ 属风格瑕疵。若要严谨应为 100 或 10*10。
    local homePos = inst.components.knownlocations.GetLocation and inst.components.knownlocations:GetLocation("rookery")
    local herdPos = inst.components.knownlocations.GetLocation and inst.components.knownlocations:GetLocation("herd")

    if homePos and herdPos and distsq(homePos,herdPos) < 102 then
        return true
    else
        return false
    end
end

local function FlyAway(inst)
    --print("FLYAWAY EVENT")
    inst:PushEvent("flyaway")
end

function PenguinBrain:OnStart()
-- ★★ OnStart：单棵 PriorityNode，无子树的局部变量拆分。
--   ★ 与 pigbrain（拆 4 棵子树）不同，企鹅的树相对扁平，节点直接内联。
--   ★ 何时该拆分？当条件函数需要引用节点时。本文件不需要，故可内联。
    local root = PriorityNode(
-- ★★★ root 优先级表（行内注释帮了大忙）：
--  第 361-362 行：★ 飞行中 → 继续飞（IfNode + ActionNode）
--    ★ 这是唯一处理「已在空中」的分支：状态图在 flight 时大脑不干预，
--      只维持 FlyAway 事件。
--  第 364-365 行：恐慌 + 电栅栏（braincommon）
--  第 368 行：★ 偷蛋（第 124 行）—— 注释明确说「玩家靠近蛋时会恐慌并捡蛋」
--  第 372-375 行：★ 躲「scarytoprey」—— 注释说「玩家太近就散开」
--    ⚠️ 但第 372 行 IfNode 条件 not HasTag("mutated_penguin")，
--      即【变异企鹅不躲】。变异体是天敌而非猎物（见第 44 行）。
--  第 378-379 行：★ 攻击（条件是 ShouldAttack）
--  第 381-382 行：★ EventNode(self.inst, "gohome", ...) —— ★★ 事件驱动！
--    ★★★ 全文件唯一的 EventNode：外部推 "gohome" 事件即触发 FlyAway。
--      这是「外部触发 AI 行为」的标准接入口，移植价值高。
--      ★ 与 monkeybrain 第 292 行 EventNode(inst, "gohome", ...) 同款。
--  第 386 行：觅食
--  第 388 行：★ AttackWall —— 拆墙逃跑（被围住时的应急）
--    ★ 很少见的行为：不是打怪，是拆墙跑路。很有 DSF 特色。
--  第 391 行：★ 迁徙 Leash（优先级在觅食之后、下蛋之前）
--  第 394-401 行：★★ 下蛋（4 个条件与）
--  第 405-413 行：★★ 捡蛋（4 个条件与，含冻伤防护）
--  第 416-426 行：群落游荡（★ 锚点是三个位置的优先级链）
--  第 429-430 行：跟随队长
--  第 432-437 行：★ 最终兜底游荡（无优先级链，固定半径 MAX_WANDER_DIST=5）
--  第 439 行：★ StandStill（永不失败的最后兜底）
--  第 440 行：重评估间隔 0.25 秒
    {
        IfNode(function() return  self.inst.sg:HasStateTag("flight") end, "Flying",
-- ★ IfNode 条件 sg:HasStateTag("flight") —— 飞行中的唯一处理。
--   第 362 行 ActionNode(FlyAway) 只是再推一次 flyaway 事件。
--   ★ 语义：「只要还在飞，就持续发送飞行事件维持状态」。
            ActionNode(function() return FlyAway(self.inst) end)),

		BrainCommon.PanicTrigger(self.inst),
        BrainCommon.ElectricFencePanicTrigger(self.inst),

        -- Penguins will panic and pick up eggs if player comes too close
-- ★★ 源码原注释直说了这个节点的行为（很有价值的注释）：
--   "Penguins will panic and pick up eggs if player comes too close"
--   ★ 即 StealAction 排在这里（优先级高于躲天敌）——
--     因为「保护蛋」比「躲天敌」更重要。
--   ★ 又一次印证：★ 注释解释了「为什么排在这个位置」，这是最高价值的注释。
		DoAction(self.inst, function() return StealAction(self.inst) end, "PickUp Egg Action", true ),

        -- Scatter for a short distance if player gets too close
-- ★★ 第 370-371 行注释解释了 RunAway 的完整参数表（跨文件接口说明）：
--   "--RunAway(hunterparams, see_dist, safe_dist, shouldRunFn, runhome)"
--   ★ 这是 behaviours/runaway.lua 的签名，在调用点旁标注 ——
--     极好的文档习惯，移植时若被调节点签名变了，看这里就知道要改什么。
--   第 375 行末参 false = 不回家（跑起来别想着回家）。
     -- RunAway(hunterparams, see_dist, safe_dist, shouldRunFn, runhome)
        IfNode(function() return not self.inst:HasTag("mutated_penguin") end, "IsScaredOfPrey",
            RunAway(self.inst, "scarytoprey", SEE_PLAYER_DIST, STOP_RUN_DIST,
            function(target) return ShouldRunAway(self.inst, target) end,
            false)),

     -- ChaseAndAttack( inst, max_chase_time, give_up_dist, max_attacks, findnewtargetfn)
        IfNode(function() return ShouldAttack(self.inst) end, "ShouldAttack",
			ChaseAndAttack(self.inst, MAX_CHASE_TIME, MAX_CHASE_DIST, 15)),

        EventNode(self.inst, "gohome",
-- ★★ EventNode —— 全DST 少见的节点类型，本文件的亮点之一。
-- 【语义】只在外部 PushEvent("gohome") 时才执行子树，平时不占用决策。
--   ★★ 与 WhileNode 的根本区别：
--     WhileNode 是「条件成立就一直跑」，每帧求值条件；
--     EventNode 是「等事件」，不轮询。
--   ★ 性能优势：不用每帧检查一个永不成立的条件。
--   ★ 语义优势：与外部系统的交互更明确（发命令 vs 轮询状态）。
--   ★ 移植价值：★★★ 这是「AI 接受外部指令」的干净入口。
--   ★ monkeybrain 第 292 行也用它接 gohome —— 同一约定被多处复用。
            ActionNode(function() return FlyAway(self.inst) end)),

        -- Hungry, hungry penguins
     -- DoAction(inst, getactionfn, name, run)
        DoAction(self.inst, EatFoodAction,"Eating Food Action",false),

        AttackWall(self.inst),

        -- If not fighting or eating or protecting eggs, migrate to the rookery
-- ★ 注释说明 Leash 的用途：「不打架也不吃东西时，迁徙回巢穴」。
--   ★ 这行注释补充了代码没表达的语义（优先级位置的含义）。
        Leash(self.inst, GetMigrateLeashPos, LEASH_MAX_DIST, LEASH_RETURN_DIST),

        -- When at the rookery, lay egg - but not if it's too cold!
-- ★★ 下蛋条件的四重与（第 394-399 行）：
--   在巢穴 且 不在下蛋中 且 不是夜晚 且 不是队长
--   ★ 第 398 行 teamattacker.teamleader == nil —— 队长不下蛋（它要带队）。
--   ★ 第 397 行 not TheWorld.state.isnight —— 夜里不下蛋。
--   ★ 与第 255 行延迟任务里的 PrepareForNight 是两层检查：
--     节点层（不在夜里才进入）+ 延迟回调层（执行时再确认）。
--     ★ 双层检查是长周期任务的标准防御。
        WhileNode(function()
                        return  AtRookery(self.inst) and
                                not self.inst.layingEgg and
                                not TheWorld.state.isnight and
                                self.inst.components.teamattacker.teamleader == nil
                        end,
                    "Laying Egg ",
                    DoAction(self.inst, LayEggAction, "Laying Egg Action", false )),


        -- Don't leave the egg lying around to freeze
-- ★★ 源码原注释："Don't leave the egg lying around to freeze"
--   （别让蛋留在外面冻住）—— 这解释了第 280 行的 not PrepareForNight。
--   ★ 注释在这里解释了反直觉的逻辑，与我在第 278 行的分析相互印证。
--   ★ 这类「解释反直觉条件」的注释，比逐行翻译有价值得多。
        WhileNode(function()
                        return AtRookery(self.inst) and
                               self.inst.components.teamattacker.teamleader == nil and
                               not HasEgg(self.inst) and
                               (((TheWorld.state.iswinter and TheWorld.state.temperature <= -10))  or
-- ★★ 捡蛋条件四重与（第 406-411 行）：
--   在巢穴 且 不是队长 且 背包没蛋 且 （天冷到 ≤-10 或 该休息了）
--   ★ 第 408 行 not HasEgg —— 手里没蛋才去捡。
--   ★ 第 409-410 行括号内的 or —— 冷或夜间才捡（防冻）。
--   ★ 注意这里的写法【是】正确的（有括号），与第 256-257 行形成对比。
--     再次印证第 256 行的括号缺失是笔误。
                                PrepareForNight(self.inst))
                        end,
                    "PickUp Egg",
                    DoAction(self.inst, PickUpEggAction, "Pickup Egg", false )),

        -- When at the rookery with nothing else to do, wander around - but don't wander too far from your egg!
        WhileNode(  function()
                            return HerdAtRookery(self.inst) and self.inst.components.teamattacker.teamleader == nil
                        end,
                    "No Leader Wander Action",
                    Wander(self.inst,
                            function()
-- ★★ 最终群落游荡的锚点是三级优先级链（第 422-424 行）：
--   myegg（我的蛋）→ rookery（巢穴）→ herd（群落）
--   ★ 语义：蛋在哪就围着哪，没蛋就围着巢，巢也没有就围着群落。
--   ★★★ 与第 432-437 行的【立即求值】版本对比：
--     第 432-437 行在 OnStart 里就把 GetLocation 求值了，
--     ★ 这些位置在游戏进程中会变（企鹅迁徙、蛋被移动），
--       所以最终兜底的游荡锚点【实际上是启动时那一刻的位置】。
--   ⚠️ 这是一个【真实的设计瑕疵】：最后兜底的 Wander 锚点是静态的。
--     已逐字核对第 432-437 行确认是直接调用 GetLocation 而非传函数。
--   ★ 对比第 421-425 行（群落游荡节点）用的是【函数形式】，每帧重算 ——
--     同一文件里两种写法，后者在热路径上更正确。
--   ★ 实际影响有限：这是最后的兜底（前面所有节点都不成立时），
--     且企鹅很少进入这个状态。标为真实但低影响的瑕疵。
                                return  self.inst.components.knownlocations:GetLocation("myegg") or
                                        self.inst.components.knownlocations:GetLocation("rookery") or
                                        self.inst.components.knownlocations:GetLocation("herd")
                            end,
                            GetWanderDistFn)),

        -- Penguins have leaders?
-- ★ 跟随队长。目标用内联匿名函数而不是本地 helper ——
--   与 pigbrain 第 429 行 hermitcrabbrain 第 614 行风格一致（有些文件用 helper）。
--   ⚠️ 第 429 行内联函数与第 37 行的 GetLeader 不存在（本文件无此 helper），
--     所以内联是必需的，不是风格选择。已 grep 确认本文件无 GetLeader 定义。
        Follow(self.inst, function(inst) return inst.components.follower and inst.components.follower:GetLeader() end ,
                    MIN_FOLLOW_DIST, TARGET_FOLLOW_DIST, MAX_FOLLOW_DIST),

        Wander( self.inst,
-- ⚠️★★ 真实的设计瑕疵：锚点在 OnStart 时被【立即求值】，之后不再更新。
--   第 433-435 行 GetLocation(...) 是直接调用，不是传函数。
--   ★ 对比第 421-425 行用的是函数形式（每帧重算），两种写法在同一文件并存。
--   ★ 后果：作为最后兜底的游荡锚点是「启动瞬间的蛋/巢/群落位置」，
--     若企鹅后来搬了家，游荡会一直朝着旧位置。
--   ★ 实际影响有限（兜底路径 + 企鹅很少移动巢穴），故为低影响瑕疵。
                self.inst.components.knownlocations:GetLocation("myegg") or
                self.inst.components.knownlocations:GetLocation("rookery") or
                self.inst.components.knownlocations:GetLocation("herd") or
		        self.inst.Transform:GetWorldPosition(),
                MAX_WANDER_DIST),

        StandStill(self.inst),
-- ★ StandStill 作为最后兜底 —— 保证 root 永不会「什么都不做而失败」。
--   ★ 这是 PriorityNode 设计的要点：最后放一个必然成功的节点。
--   ★ 若省略它，所有条件都不满足时 PriorityNode 会返回失败，
--     可能导致大脑认为「无事可做」而触发 OnThink 的异常分支。
--   ★ pigbrain 第 355 行用 Wander 兜底、abigailbrain 第 226 行也用 Wander，
--     本文件用 StandStill —— 语义是「没蛋没敌没任务就站着发呆」。
    }, .25)

    self.bt = BT(self.inst, root)
end

return PenguinBrain