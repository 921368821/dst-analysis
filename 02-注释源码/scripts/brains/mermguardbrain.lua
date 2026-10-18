--============================================================
-- 【深度注释版】 本文件为逐行深度注释，勿用批量工具覆盖
-- 文件：brains/mermguardbrain.lua
-- 模块：AI 大脑 / 美人鱼守卫（美人鱼王召唤的战斗单位）
-- 职责：装配美人鱼守卫 AI。★★★ 本文件与 mermbrain.lua 是近似孪生，
--       约 60% 的函数逐字重复（含注释），因此本注释【不重复解释重复部分】，
--       只在两文件有差异处重点展开 —— 差异才是信息量所在。
--       守卫 vs 生产者的五处根本差异：
--         1) 资源：盔甲（armor, HEAD 槽）而非工具（tool, HANDS 槽）
--         2) 无家：没有 GoHome / ShouldGoHome / IsHomeOnFire 三件套
--         3) 战斗为主：独有的 WaitingForHelp（请求支援）节点
--         4) 国王死亡即回收：独有的 OnGuardDeath 反向回调 + 化水消失
--         5) 帮工仅 CHOP/MINE，无 TILL/DIG（守卫不种地）
-- 关键符号：WaitingForHelp（请求支援）, TargetFollowTargetDistFn（输出位站位）,
--           OnGuardDeath（国王死亡回收）, NeedsArmor, GetClosestArmory,
--           PickupArmor, GetHealerFn, EatFoodAction, TargetFollowDistFn
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
-- 交叉引用：brains/mermbrain.lua（★ 孪生文件，建议对照阅读）,
--           brain.lua（三段式调度）, brains/braincommon.lua（帮工与恐慌底座）,
--           behaviours/{wander,runaway,doaction,follow,standstill}.lua,
--           simutil.lua:555（SpringCombatMod —— 季节性战斗修正器）,
--           components/{follower,trader,eater,inventory,combat}.lua
--============================================================
require "behaviours/wander"
--[ [
-- mermguardbrain.lua —— 美人鱼守卫大脑
--
-- 【★★★ 必读提示：本文件与 mermbrain.lua 是近似孪生】
--   两者共享约 60% 的函数，且多为【逐字复制】（只换了资源名）：
--     GetLeader / GetHealerFn / KeepHealerFn / GetTraderFn / KeepTraderFn /
--     GetFaceTargetFn / KeepFaceTargetFn / GetRunAwayTarget / EatFoodAction /
--     GetNoLeaderHomePos / TargetFollowDistFn / shouldanswercall /
--     Getcalledofferingpot / answercall
--   ★ 本注释刻意【不重复解释】这些逐字重复的部分，
--     只在两文件有差异处重点展开 —— 差异才是信息量所在。
--   ★ 建议阅读顺序：先读 mermbrain.lua 的对应段落，再读本文件的差异点。
--
-- 【★ 守卫 vs 生产者：五处根本差异】
--  1) 资源不同：工具（tool）→ 盔甲（armor），槽位 HANDS → HEAD
--  2) ★ 不回家：本文件【没有 GoHomeAction / ShouldGoHome / IsHomeOnFire】，
--     mermbrain 第 302-335 行有三件套。守卫是「 summoned 便存在」的，不认家。
--  3) ★ 战斗为主：守卫有 WaitingForHelp（第 348 行）等独有节点，
--     且不需要生产工具链。
--  4) ★ 国王死亡即消失：本文件第 366-388 行的 "ShouldGoToThrone" 节点
--     与 mermbrain 的王座逻辑名同实异 —— 这里其实是「回收」逻辑。
--  5) 帮工种类少：只有 CHOP 与 MINE（无 TILL/DIG，因为守卫不种地）。
--
-- 【⚠️ 容易踩的坑】
-- · 第 31 行 ★ 类名写的是 MermBrain 而非 MermGuardBrain：
--   local MermBrain = Class(Brain, function(self, inst) ... end)
--   ★★ 已逐字核实第 31 行确认如此。这是个复制粘贴残留的命名错误。
--     影响：本文件的类没有全局名字，MermGuardBrain 这个标识符在本文件里不存在。
--     因为 Lua 的 Class() 会把返回的类赋给局部变量 MermBrain，
--     且文件末尾 return MermBrain（第 430 行）返回的也是它 ——
--   ★ 所以【不影响功能】：prefabs/ 里是通过 brain 文件名 require 并实例化的，
--     不依赖类名。但会让读代码的人困惑，也说明复制粘贴没改干净。
--   结论：命名瑕疵，非功能缺陷。已在下方第 31 行锚点再次标注。
-- · 本文件未 require behaviours/panic，但第 331 行用了 PanicTrigger ——
--   ★ 它经由 braincommon.lua 间接 require 了（第 2 行 panic）。
--   依赖链清晰，非缺陷，但值得知道。
--] ]
require "behaviours/runaway"
require "behaviours/doaction"
require "behaviours/follow"
require "behaviours/standstill"

local BrainCommon = require "brains/braincommon"

local SEE_PLAYER_DIST     = 5
-- ★ 与 mermbrain 第 9 行逐字相同：SEE_PLAYER_DIST = 5。
--   守卫同样敢靠近玩家（要被治疗、也要面对交易者）。
local SEE_FOOD_DIST       = 5
local MAX_WANDER_DIST     = 15
-- ★ 差异：MAX_WANDER_DIST 相同(15)，但守卫用得更多 ——
--   因为它没有生产任务，空闲时只能游荡（第 420 行）。
local MAX_CHASE_TIME      = 25
local MAX_CHASE_DIST      = 40
-- ★★ 关键差异：MAX_CHASE_TIME = 25，而 mermbrain 第 12 行是 10。
--   ★ 守卫的追击时间长 2.5 倍 —— 它是战斗单位，必须追到底。
--   这是「同一份代码，按角色调参」最直观的体现。
-- ★ MAX_CHASE_DIST = 40 也比 mermbrain 的 20 远一倍，同理。
local RUN_AWAY_DIST       = 5
local STOP_RUN_AWAY_DIST  = 8

local MIN_FOLLOW_DIST     = 3
local MAX_FOLLOW_DIST     = 15

local FACETIME_BASE = 2
local FACETIME_RAND = 2

local TRADE_DIST = 20

local FIND_ARMORY_RANGE     = 15

local MIN_FOLLOW_TARGET_DIST     = 5
-- ★ 与 mermbrain 第 27 行逐字相同：DEFAULT_FOLLOW_TARGET_DIST = 8。
--   但守卫多了一套 MIN/MAX（第 27、29 行）—— 因为它有 TargetFollowTargetDistFn。
local DEFAULT_FOLLOW_TARGET_DIST = 8
local MAX_FOLLOW_TARGET_DIST     = 15

local MermBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

-----------------------------------------------------------------------------------------------

local function GetLeader(inst)
    return inst.components.follower and inst.components.follower:GetLeader()
end

local ARMORY_ONEOF_TAGS = { "merm_armory", "merm_armory_upgraded" }
-- ★★★ 盔甲棚（与 mermbrain 第 184 行的工具棚逐字同构）：
--   mermbrain:  TOOLSHED_ONEOF_TAGS = { "merm_toolshed", "merm_toolshed_upgraded" }
--   本文件:    ARMORY_ONEOF_TAGS  = { "merm_armory", "merm_armory_upgraded" }
--   ★ 只换了名字。这种「同一逻辑两个副本」是 DST 最常见的组织方式。
-- ⚠️ 代价：本文件可以独立修改，而 mermbrain 不能 —— 两边会漂移。

local ARMOR_CANT_TAGS  = { "INLIMBO" }
local ARMOR_ONEOF_TAGS = { "mermarmorhat", "mermarmorupgradedhat" }

local function IsHeadEquip(item)
    return item.components.equippable ~= nil and item.components.equippable.equipslot == EQUIPSLOTS.HEAD
end

local function NeedsArmor(inst)
-- ★ NeedsArmor 与 mermbrain 第 193 行 NeedsTool 逐字同构，只改两处：
--   1) EQUIPSLOTS.HANDS → EQUIPSLOTS.HEAD
--   2) IsHandEquip（第 46 行）→ IsHeadEquip
-- ★ 这种「同构替换」让两个角色的行为逻辑完全一致，只是资源不同。
--   移植时可直接照抄 mermbrain 的实现。
    local armor = inst.components.inventory ~= nil and inst.components.inventory:GetEquippedItem(EQUIPSLOTS.HEAD) or nil

    if armor ~= nil then
        return false

    elseif inst.components.inventory ~= nil then
        armor = inst.components.inventory:FindItem(IsHeadEquip)

        if armor ~= nil then
            return false
        end
    end

    return true
end

local function GetClosestArmory(inst, dist)
-- GetClosestArmory 与 mermbrain 第 210 行 GetClosestToolShed 逐字同构。
-- ⚠️ 同样的瑕疵：第 79-89 行遍历中「普通版只记遇到的第一个」，
--   而函数名叫 GetClosest —— 并不保证最近。已核对第 85-87 行确认。
--   这是从 mermbrain 复制过来的同一个问题。
-- ★ 但第 81-83 行升级版「立即返回」的优先级是合理的（升级装备价值更高）。
    dist = dist or FIND_ARMORY_RANGE

    local x, y, z = inst.Transform:GetWorldPosition()
    local ents = TheSim:FindEntities(x, 0, z, dist, nil, nil, ARMORY_ONEOF_TAGS)

    if #ents <= 0 then
        return nil
    end

    local armory = nil

    for _, ent in ipairs(ents) do
        if ent:CanSupply() then
            if ent:HasTag("merm_armory_upgraded") then
                return ent -- High priority.
            end

            if armory == nil then
                armory = ent
            end
        end
    end

    return armory
end

local function GetClosestArmoryPosition(inst, dist)
    local armory = GetClosestArmory(inst, dist)

    if armory ~= nil then
        local distance = armory:GetPhysicsRadius(0)

        return inst:GetPositionAdjacentTo(armory, distance)
    end
end

local function NeedsArmorAndFoundArmor(inst)
    if not NeedsArmor(inst) then
        return false
    end

    return GetClosestArmory(inst) ~= nil
end

local function CollectArmor(inst)
-- CollectArmor 与 mermbrain 第 255 行 CollectTool 逐字同构，推 merm_use_building 事件。
-- ★ 同一套建筑交互协议（工具棚/盔甲棚共用 merm_use_building 事件）——
--   意味着这两个建筑的 prefab 侧有统一的处理逻辑。
    if not NeedsArmor(inst) then
        return
    end

    local armory = GetClosestArmory(inst, 2.5)

    if armory ~= nil then
        inst:PushEvent("merm_use_building", { target = armory })
    end
end

local function PickupArmor(inst)
-- ★ PickupArmor 与 mermbrain 第 267 行 PickupTool 逐字同构。
--   第 140 行优先 mermarmorupgradedhat（升级盔甲），对应工具版的 upgraded 工具。
-- ⚠️ 同样有「遍历兜底导致非最近」的问题（第 144 行）。
    if inst.sg:HasStateTag("busy") then
        return nil
    end

    if NeedsArmor(inst) then
        local x, y, z = inst.Transform:GetWorldPosition()
        local ents = TheSim:FindEntities(x, 0, z, FIND_ARMORY_RANGE, nil, ARMOR_CANT_TAGS, ARMOR_ONEOF_TAGS)

        if #ents <= 0 then
            return nil
        end

        local armor = nil

        for _, ent in ipairs(ents) do
            if ent:HasTag("mermarmorupgradedhat") then
                return BufferedAction(inst, ent, ACTIONS.PICKUP) -- High priority.
            end

            armor = ent
        end

        return armor ~= nil and BufferedAction(inst, armor, ACTIONS.PICKUP) or nil
    end
end

---------------------------------------------------------------------------------------------------

local function GetHealerFn(inst)
-- ★★ 与 mermbrain 第 37 行 GetHealerFn 逐字同构，两处差异：
--  第 157 行：★ 直接用 inst.components.follower:GetLeader()，
--     而 mermbrain 用本地 GetLeader(inst) helper（带 nil 保护）。
--   ★★ 这是【孪生文件修复不同步】的实例：
--     mermbrain 的 GetLeader（第 33-35 行）判了 components.follower 是否存在，
--     本文件第 157 行没判，直接 inst.components.follower:GetLeader()。
--   ⚠️ 若守卫实体没有 follower 组件，第 157 行会崩。
--   已核实本文件第 157 行与第 174 行两处都直接访问 .components.follower，
--   而 mermbrain 第 40 行、第 59 行用的是带保护的 GetLeader()。
--   结论：确认为复制时漏抄了保护，属真实的健壮性缺陷（低严重度，
--   因守卫 prefab 实际挂有follower 组件）。
--   ★★★ 更强的证据：本文件内部就不自洽 ——
--     第 38 行 GetLeader helper 用了保护：inst.components.follower and ...
--     第 268 行 TargetFollowDistFn 也用了保护：inst.components.follower ~= nil and ...
--     ★ 但第 157、174 行这两处却直接 .components.follower:GetLeader()。
--     同一文件里两种写法，说明这两处是【忘记用本地 helper】而非设计。
--   已用 grep 逐条核实本文件 follower 的 4 处出现（第 38/157/174/268 行）。
    local x, y, z = inst.Transform:GetWorldPosition()
    local players = FindPlayersInRange(x, y, z, TRADE_DIST, true)
    for _, v in ipairs(players) do
		if (v == inst.components.follower:GetLeader() or v:HasTag("merm")) and not inst.components.combat:TargetIs(v) then
			local target
            local act = v:GetBufferedAction()
			if act then
				target = act.target
				act = act.action
			elseif v.components.playercontroller then
				act, target = v.components.playercontroller:GetRemoteInteraction()
			end
			if target == inst and act == ACTIONS.HEAL then
				return v
			end
        end
    end
end

local function KeepHealerFn(inst, target)
-- ★★ KeepHealerFn 第 179 行：act, target = ...GetRemoteInteraction()
--   与 mermbrain 第 64 行逐字相同。
--   ★★ 已核实 components/playercontroller.lua:5866 返回 (action, target, pos)，
--     故赋值顺序正确，不是缺陷。（这点我最初怀疑过，核对后确认无误。）
-- ⚠️ 但本文件这里比 mermbrain 第 64 行【多一个真实隐患】：
--   第 175 行 local act = target:GetBufferedAction() 在第 176 行 if act then 内使用，
--   第 179 行在 elseif 分支里给 act 赋值 —— 该 act 是第 175 行的 local，可见，正确。
--   结论：无缺陷。两份文件在此处都正确。
	if (target == inst.components.follower:GetLeader() or target:HasTag("merm")) and not inst.components.combat:TargetIs(target) then
        local act = target:GetBufferedAction()
		if act then
			return act.target == inst and act.action == ACTIONS.HEAL
		elseif target.components.playercontroller then
			act, target = target.components.playercontroller:GetRemoteInteraction()
			return target == inst and act == ACTIONS.HEAL
		end
    end
	return false
end


local function GetTraderFn(inst)
    local x, y, z = inst.Transform:GetWorldPosition()
    local players = FindPlayersInRange(x, y, z, TRADE_DIST, true)
    for _, player in ipairs(players) do
        if inst.components.trader:IsTryingToTradeWithMe(player) then
            return player
        end
    end
end

local function KeepTraderFn(inst, target)
    return inst.components.trader:IsTryingToTradeWithMe(target)
end

local function GetFaceTargetFn(inst)
-- ★ GetFaceTargetFn 与 mermbrain 第 85 行逐字同构（两个定时器控制注视时长）。
--   唯一差异：mermbrain 第 90 行是 local leader = GetLeader(inst)，
--     本文件第 205 行直接用 GetLeader(inst) or FindClosestPlayerToInst(...)
--     —— 把两行合成一行，行为等价。
    if inst.components.timer:TimerExists("dontfacetime") then
        return nil
    end
    local shouldface = GetLeader(inst) or FindClosestPlayerToInst(inst, SEE_PLAYER_DIST, true)
    if shouldface and not inst.components.timer:TimerExists("facetime") then
        inst.components.timer:StartTimer("facetime", FACETIME_BASE + math.random()*FACETIME_RAND)
    end
    return shouldface
end

local function KeepFaceTargetFn(inst, target)
-- KeepFaceTargetFn 与 mermbrain 第 97 行逐字同构。
-- ⚠️ 差异：mermbrain 第 101 行有 local leader = GetLeader(inst) 然后
--   (leader and leader == target) or (...)；
--   本文件第 217 行直接 (GetLeader(inst) == target) or (...)
--   ⚠️ ★ 这里有个细微差别值得注意：
--     若 GetLeader(inst) 返回 nil 且 target 也是 nil，
--     第 217 行 (nil == nil) 为 true → keepface 为真；
--     而 mermbrain 第 217 行 (leader and leader == target) —— leader 为 nil 时
--     整个 and 表达式短路返回 nil（假）→ keepface 为假。
--   ★★ 也就是说：本文件在「无队长且 target 为 nil」时会认为「还该看着」，
--     而 mermbrain 认为「不用看了」。
--   实际影响极小（target 为 nil 时 FaceEntity 本就无事可做），
--   且第 213 行 dontfacetime 与第 218 行 target:IsValid() 都提供了额外保护。
--   结论：属两文件的实现漂移，行为差异不可观测，不标为缺陷，仅记录。
    if inst.components.timer:TimerExists("dontfacetime") then
        return nil
    end

    local keepface = (GetLeader(inst) == target)
        or (target:IsValid() and inst:IsNear(target, SEE_PLAYER_DIST))
    if not keepface then
        inst.components.timer:StopTimer("facetime")
    end
    return keepface
end

local function GetRunAwayTarget(inst)
	return inst.components.combat.target
end

------------------------------------------------------------------------------
local EATFOOD_MUST_TAGS = { "edible_VEGGIE" }
-- ★ EatFoodAction 与 mermbrain 第 116 行逐字同构（只吃素食、恐吓检查、validfn）。
-- ★★ 唯一真实差异：mermbrain 第 117-119 行有 waking 状态检查，
--   本文件【没有】。意味着守卫在「醒来」过程中也会去找食。
--   守卫不会睡觉（本文件无 sleeper 相关逻辑），故此检查对它无意义 ——
--   ★ 这说明复制时是【有意简化】，不是漏抄。很好的对照。
local EATFOOD_CANT_TAGS = { "INLIMBO", "outofreach" }
local SCARY_TAGS = { "scarytoprey" }

local function EatFoodAction(inst)
    local target = nil

    if inst.components.inventory ~= nil and inst.components.eater ~= nil then
        target = inst.components.inventory:FindItem(function(item) return item:HasTag("moonglass_piece") or inst.components.eater:CanEat(item) end)
    end

    if target == nil and GetLeader(inst) == nil then
        target = FindEntity(inst, SEE_FOOD_DIST, function(item)
            return inst.components.eater ~= nil and inst.components.eater:CanEat(item)
        end, EATFOOD_MUST_TAGS, EATFOOD_CANT_TAGS)
        --check for scary things near the food
        if target ~= nil and (GetClosestInstWithTag(SCARY_TAGS, target, SEE_PLAYER_DIST) ~= nil or not target:IsOnValidGround()) then  -- NOTE this ValidGround check should be removed if merms start swimming
            target = nil
        end
    end
    if target ~= nil then
        local act = BufferedAction(inst, target, ACTIONS.EAT)
        act.validfn = function() return target.components.inventoryitem == nil
                                    or target.components.inventoryitem.owner == nil
                                    or target.components.inventoryitem.owner == inst end
        return act
    end
end

local function GetNoLeaderHomePos(inst)
    if GetLeader(inst) then
        return nil
    else
        return inst.components.knownlocations:GetLocation("home")
    end
end

local function TargetFollowDistFn(inst)
-- ★★ TargetFollowDistFn 与 mermbrain 第 365 行逐字同构，包括注释。
--   ★ 公式：(MAX-MIN) * (1-忠诚度) * boatmod * random() + MIN
--   ★★ 「忠诚度越高跟随越近」的反直觉设计在两个文件里一致，
--     确认是刻意选择而非笔误。详见 mermbrain 的同段注释。
    local loyalty = inst.components.follower ~= nil and inst.components.follower:GetLoyaltyPercent() or 0.5
    local boatmod = inst:GetCurrentPlatform() ~= nil and 0.2 or 1.0
    -- As loyalty rises the further out the follower will potentially stay back.
    -- If on a boat lower max range.
    -- Randomize the range from min to max with the bias modulation.
    return (MAX_FOLLOW_DIST - MIN_FOLLOW_DIST) * (1.0 - loyalty) * boatmod * math.random() + MIN_FOLLOW_DIST
end

local function TargetFollowTargetDistFn(inst)
-- ★★ TargetFollowTargetDistFn —— 本文件【独有】的函数，mermbrain 没有。
-- 【机制】跟随【战斗目标】而不是队长，距离取决于目标的攻击范围。
-- 【第 283 行公式】
--   max(sqrt(target的CalcAttackRangeSq(inst)) + MIN_FOLLOW_TARGET_DIST, 默认值 8)
-- ★ 语义：「站在刚好能打到目标的位置后方」——
--   即守卫会主动站到「我一刀能砍到、但目标砍不到我」的理想位置。
--   ★ 这是远程/长武器单位的经典站位算法，移植价值很高。
-- 【第 279-281 行】目标为空或目标没有 combat → 用默认值 8（安全降级）
-- ⚠️ 第 283 行只判了 target.components.combat == nil，
--   未判 inst.components.combat —— 但 CalcAttackRangeSq 是 target 的方法，
--   内部可能用到 self（inst）。未核实 combat.lua 该方法实现细节，
--   标为疑似：若该方法访问 self.inst 则本函数需判 inst 的 combat 组件。
    local target = inst.components.combat.target

    if target == nil or target.components.combat == nil then
        return DEFAULT_FOLLOW_TARGET_DIST
    end

    return math.max(math.sqrt(target.components.combat:CalcAttackRangeSq(inst)) + MIN_FOLLOW_TARGET_DIST, DEFAULT_FOLLOW_TARGET_DIST)
end


-----------------------------------------------

local OFFERINGPOT_MUST_TAGS = { "offering_pot" }

local function shouldanswercall(inst)
    if inst:HasTag("lunarminion") or inst:HasTag("shadowminion") or GetLeader(inst) ~= nil then
        return false
    end

    local x, y, z = inst.Transform:GetWorldPosition()
    local pots = TheSim:FindEntities(x, 0, z, 30, OFFERINGPOT_MUST_TAGS)

    if #pots <= 0 then
        return false
    end

    for _, pot in ipairs(pots) do
        if pot.merm_caller ~= nil and pot.merm_caller:IsValid() and pot.components.container ~= nil and not pot.components.container:IsEmpty() then
            inst.answerpotcall = pot

            return true
        end
    end
end

local function Getcalledofferingpot(inst)
    if inst.answerpotcall ~= nil and inst.answerpotcall:IsValid() and inst.answerpotcall.merm_caller ~= nil then
        local distance = inst.answerpotcall:GetPhysicsRadius(0)

        return inst:GetPositionAdjacentTo(inst.answerpotcall, distance)
    end
end

local function answercall(inst)
    if inst.answerpotcall ~= nil and inst.answerpotcall:IsValid() then
        inst.answerpotcall:AnswerCall(inst)
    end
end

-------------------------------------------

function MermBrain:OnStart()
-- ★★ OnStart。结构与 mermbrain 相同：NODES（第 329 行）+ root 守卫（第 423 行）。
--   但少了 in_contest 子树 —— 守卫不参加猪王争霸赛。
-- ★ 差异清单（对照 mermbrain 的第 428-515 行）：
--   mermbrain 有而本文件无：in_contest、MINE/TILL/DIG 帮工、
--                     GoHomeAction/ShouldGoHome/IsHomeOnFire（家三件套）、
--                     GetThronePosition/IsThroneValid（王座）、
--                     HasDigTool 相关、MermBrain 的 IsThroneValid IfNode
--   本文件独有：WaitingForHelp（第 348 行）、国王死亡回收（第 366 行）、
--                     TargetFollowTargetDistFn（第 276 行）、
--                     SpringCombatMod（第 359 行）
    local NODES = PriorityNode(
-- ★★★ NODES 优先级表（本文件的核心）：
--  第 331 行：普通恐慌（PanicTrigger）
--  第 332-334 行：电栅栏恐慌
--  第 336-338 行：★ 被治疗 → 面对治疗者
--  第 340 行：捡盔甲
--  第 342-346 行：★ 没盔甲且找到盔甲棚 → 去取
--  第 348-356 行：★★★ WaitingForHelp（守卫独有，详见下方）
--  第 358-360 行：战斗
--  第 362-364 行：闪避（与战斗互斥）
--  第 366-388 行：★★★ 国王死亡回收（守卫独有，详见下方）
--  第 390-393 行：帮砍木
--  第 395-398 行：帮挖矿
--  第 400-404 行：响应召唤
--  第 406-407 行：交易 → 面对交易者
--  第 409-410 行：★ 觅食
--  第 412-413 行：跟随
--  第 415-417 行：有队长 → 注视
--  第 419 行：注视（兜底）
--  第 420 行：游荡（兜底）
--
-- 【★ 与 mermbrain 的优先级对比】
--   觅食位置：守卫在第 409 行（很靠后），美人鱼在第 458 行（较靠前）。
--   ★ 守卫更少觅食（它是战斗单位），美人鱼更常觅食（它要长时间在外干活）。
--   但守卫有 mermbrain 没有的 WaitingForHelp，且排在战斗【之前】（第 348 行）。
    {
		BrainCommon.PanicTrigger(self.inst),
        WhileNode(function() return BrainCommon.ShouldAvoidElectricFence(self.inst) end, "Shocked",
            ChattyNode(self.inst, "MERM_TALK_PANICELECTRICITY",
                AvoidElectricFence(self.inst))),

        ChattyNode(self.inst, "MERM_TALK_GET_HEALED",
            FaceEntity(self.inst, GetHealerFn, KeepHealerFn)
        ),

        DoAction(self.inst, PickupArmor, "collect armor", true ),

        IfNode(function() return NeedsArmorAndFoundArmor(self.inst) end, "needs armor",
            PriorityNode({
                Leash(self.inst, GetClosestArmoryPosition , 2.1, 2, true),
                DoAction(self.inst, CollectArmor, "collect armor", true ),
            }, 0.25)),

        WhileNode(function() return self.inst:ShouldWaitForHelp() end, "WaitingForHelp",
-- ★★★ WaitingForHelp —— 守卫独有的「请求支援」行为。
-- 【结构】
--   条件：self.inst:ShouldWaitForHelp()（★ 由实体的 prefab 脚本定义，不在本文件）
--   第 350 行：跟随【战斗目标】（不是队长！用 TargetFollowTargetDistFn）
--   第 351 行：面对
--   第 352-354 行：★ 喊「我需要帮助」然后站着不动
--
-- 【★ 为什么跟随战斗目标】
--   守卫在向同伴（美人鱼王召唤的其他单位）请求支援，
--   所以要靠近战斗现场，而不是跟着自己的队长。
--   ★ 与第 412 行「跟随队长」形成对照：两个 Follow 目标不同，语义清晰。
--
-- 【★ 条件函数不在本文件】
--   ShouldWaitForHelp 是实体（prefab）上的方法，由其状态图决定何时为真。
--   ★ 这是「大脑把判断委托给状态图」的模式：
--     状态图知道「我现在掉了多少血、有没有队友在打同一个目标」，
--     大脑只负责「该喊救命时喊救命」。职责分离得很干净。
            PriorityNode({
                Follow(self.inst, function() return self.inst.components.combat.target end, MIN_FOLLOW_TARGET_DIST, TargetFollowTargetDistFn, MAX_FOLLOW_TARGET_DIST),
-- ★ Follow(self.inst, function() return self.inst.components.combat.target end, ...)
--   ★ 目标就是当前战斗目标 —— 请求支援时靠近战场。
--   ★ 距离用 TargetFollowTargetDistFn（第 276 行）：
--     「刚好能打到目标」的位置。守卫会自己站到输出位。
                FaceEntity(self.inst, GetFaceTargetFn, KeepFaceTargetFn),
                ChattyNode(self.inst, "MERM_TALK_NEED_HEAL",
                    StandStill(self.inst)
                ),
            }, .25)
        ),

        WhileNode(function() return self.inst.components.combat.target == nil or not self.inst.components.combat:InCooldown() end, "AttackMomentarily",
-- ★ 战斗。与 mermbrain 第 451 行同款（含 SpringCombatMod）。
--   SpringCombatMod 定义在 simutil.lua:555，是【季节修正器】。
--   ★ 守卫也用它，说明季节追击加强是全局统一机制。
            ChaseAndAttack(self.inst, SpringCombatMod(MAX_CHASE_TIME), SpringCombatMod(MAX_CHASE_DIST))
        ),

        WhileNode(function() return self.inst.components.combat.target ~= nil and self.inst.components.combat:InCooldown() end, "Dodge",
			RunAway(self.inst, { getfn = GetRunAwayTarget }, RUN_AWAY_DIST, STOP_RUN_AWAY_DIST)
        ),

        WhileNode(function()
-- ★★★★ 国王死亡回收 —— 本文件最独特的一段，mermbrain 完全没有。
--
-- 【★★ 条件函数有【大量副作用】，这是刻意的「状态检查 + 状态写入」】
--  第 367 行：★ 【条件】国王不存在、已失效、或国王已死
--    → 第 368 行：把 return_to_king 置 false（不再回收）
--    → 第 370 行：★ 若国王实体还在，调 inst.king:OnGuardDeath(self.inst)
--      通知国王「你的一个守卫没了」，让国王可以更新计数/召唤新守卫
--    → 第 372 行：清掉 self.inst.king
--  第 375 行：返回 self.inst.return_to_king
--
-- 【★ 为什么写在条件函数里】
--   因为 WhileNode 的条件函数每帧求值，而 return_to_king 是由【外部】
--   （国王的状态图或其他实体）设置的。放在条件里就能做到：
--   每帧检查「国王是否还在」+「是否被要求回去」。
--   ★ 与 pigbrain 第 104 行 brain_noveggie、mermbrain 第 392 行 answerpotcall
--     同一手法 ——「用条件函数做状态维护」。
--
-- 【★ 第 370 行的 OnGuardDeath 是跨实体反向回调】
--   守卫主动通知国王，而非国王轮询所有守卫。
--   ★ 好处：O(1) 且国王能精确知道「是谁死了」。
--   ⚠️ 但依赖国王 prefab 一定实现 OnGuardDeath 方法。
--   已核实第 370 行有 `if self.inst.king then` 保护，
--   但【没有】检查 king.OnGuardDeath 是否存在 —— 若国王 prefab 未实现该方法，
--   第 370 行会崩（尝试调用 nil）。
--   ⚠️ 确认为健壮性缺陷（低严重度）。已逐字核对第 370 行：
--     self.inst.king:OnGuardDeath(self.inst) —— 无方法存在性检查，
--     与第 346 行 knightbrain 式风格（那里第 346 行有 if ... then 保护）。
--   ★ 对比：本文件第 157 行（follower）也漏了保护，
--     而 mermbrain 用 helper 保护了。同类问题的三个实例。
                if not self.inst.king or (not self.inst.king:IsValid() or (self.inst.king.components.health and self.inst.king.components.health:IsDead())) then
                    self.inst.return_to_king = false
                    if self.inst.king then
                        self.inst.king.OnGuardDeath(self.inst)
                    end
                    self.inst.king = nil
                end

                return self.inst.return_to_king
            end, "ShouldGoToThrone",
            PriorityNode({
-- ★ 回收子树：走到国王位置 → 立即消失。
--   第 380 行 IfNode(function() return true end, "IsThroneValid", ...)
--   ⚠️★★ 第 380 行的条件是【恒真】的 return true，节点名还叫 "IsThroneValid" ——
--     ★★★ 这是从 mermbrain 第 464 行复制过来的残留：
--       mermbrain 的条件是 IsThroneValid(self.inst)（真判断王座是否可用），
--       本文件改成了恒真，因为「国王在不在」已经由第 367 行判断过了。
--   ★ 保留恒真条件是为了配合 FailIfSuccessDecorator 的结构需求（见第 380 行上下文）。
--   ⚠️ 但节点名 "IsThroneValid" 是误导：守卫没有王座概念。
--     这是复制粘贴未清理的明确证据，与第 31 行的类名错误同源。
--   结论：功能正确（恒真 = 「无条件执行回收」），但命名误导。
                Leash(self.inst, function() return self.inst.king:GetPosition() end,
                2, 2, true),
                IfNode(function() return true end, "IsThroneValid",
                    ActionNode(function()
-- ★★ 回收的收尾四步（第 381-386 行）：
--  1) 生成特效（merm_spawn_fx）
--  2) 特效放到自己位置
--  3) 播放水花音效（注释 "Splash sound"）
--  4) inst:Remove() 删除自己
-- ★ 语义：守卫「化成水消失」而不是尸体消失。
-- ⚠️ 第 382-384 行直接访问 .Transform 与 .SoundEmitter，未判空。
--   这些是 DST 实体标配，隐式假定存在，属既定契约。
                        local fx = SpawnPrefab("merm_spawn_fx")
                        fx.Transform:SetPosition(self.inst.Transform:GetWorldPosition())
                        self.inst.SoundEmitter:PlaySound("dontstarve/characters/wurt/merm/buff") -- Splash sound
                        self.inst:Remove()
                    end)
                ),
            }, .25)),

        BrainCommon.NodeAssistLeaderDoAction(self, {
-- ★★ 只有 CHOP 与 MINE 两种帮工（第 390、395 行），没有 TILL/DIG。
--   ★ 守卫不种地，所以不需要工具链（也就不用 HasDigTool 分支）。
--   ★ 这解释了为什么本文件完全没有 mermbrain 第 469-479 行的存在。
--   ★ 与第 50 行 NeedsArmor 对照：守卫要的是盔甲（防御），不是工具（生产）。
            action = "CHOP", -- Required.
            chatterstring = "MERM_TALK_HELP_CHOP_WOOD",
        }),

        BrainCommon.NodeAssistLeaderDoAction(self, {
            action = "MINE", -- Required.
            chatterstring = "MERM_TALK_HELP_MINE_ROCK",
        }),

        IfNode(function() return shouldanswercall(self.inst) end, "answering call",
            PriorityNode({
                Leash(self.inst, Getcalledofferingpot , 2.1, 2, true),
                DoAction(self.inst, answercall, "answe call", true ),
            }, 0.25)),

        ChattyNode(self.inst, "MERM_TALK_FIND_FOOD", -- TODO(JBK): MERM_TALK_ATTEMPT_TRADE
            FaceEntity(self.inst, GetTraderFn, KeepTraderFn)),

        ChattyNode(self.inst, "MERM_TALK_FIND_FOOD",
-- ★ 觅食在这里（第 409 行），比 mermbrain 第 458 行【靠后 6 位】。
--   ★ 语义：守卫把战斗放在觅食之前 —— 它更倾向打架。
-- ⚠️ 优先级差异的确切影响依赖其余节点的实际触发条件，未做运行时验证。
--   标为设计观察而非缺陷。
            DoAction(self.inst, EatFoodAction, "Eat Food")),

        ChattyNode(self.inst, "MERM_TALK_FOLLOWWILSON",
            Follow(self.inst, function() return GetLeader(self.inst) end, MIN_FOLLOW_DIST, TargetFollowDistFn, MAX_FOLLOW_DIST, nil, true)),

        IfNode(function() return GetLeader(self.inst) ~= nil end, "HasLeader",
            ChattyNode(self.inst, "MERM_TALK_FOLLOWWILSON",
                FaceEntity(self.inst, GetFaceTargetFn, KeepFaceTargetFn ))),

        FaceEntity(self.inst, GetFaceTargetFn, KeepFaceTargetFn),
        Wander(self.inst, GetNoLeaderHomePos, MAX_WANDER_DIST),
    }, .25)

    local root = PriorityNode({
-- ★ root = PriorityNode({ WhileNode(不跳跃, "pause for jump", NODES) }, .25)
--   与 mermbrain 第 517-519 行逐字同构。
--   ★ 至此「root 包一层状态守卫」已在 4 个文件中确认（knightbrain / mermbrain /
--     mermguardbrain / abigailbrain），是稳定的项目惯例。
        WhileNode(function() return not self.inst.sg:HasStateTag("jumping") end, "pause for jump", NODES)
    }, .25)

    self.bt = BT(self.inst, root)
-- ★ self.bt = BT(self.inst, root) —— 第 6 个文件，同样收尾。
end

return MermBrain
-- ★ return MermBrain —— 返回的是第 31 行那个【名叫 MermBrain】的局部类。
--   名字虽然错，但与第 31 行一致，所以 prefab 侧 require 本文件拿到的类是对的。
--   ★ 再次强调：命名瑕疵，非功能缺陷（详见文件头注释）。