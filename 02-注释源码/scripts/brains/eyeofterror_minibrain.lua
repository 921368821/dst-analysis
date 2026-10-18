--============================================================
-- 文件：brains/eyeofterror_minibrain.lua
-- 模块：AI 大脑 / eyeofterror_minibrain
-- 职责：大脑「eyeofterror_minibrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/attackwall"
require "behaviours/chaseandattack"
require "behaviours/doaction"
require "behaviours/wander"
local BrainCommon = require("brains/braincommon")

local EyeOfTerrorMiniBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local FOOD_DISTANCE = 20
local EATFOOD_CANT_TAGS = { "outofreach", "INLIMBO" }
local function EatFoodAction(inst)
    if inst.sg:HasStateTag("busy") then
        return nil
    end

	local food = FindEntity(inst,
		FOOD_DISTANCE,
		function(item)
			return inst.components.eater:CanEat(item) and item:IsOnPassablePoint(true)
		end,
		nil,
		EATFOOD_CANT_TAGS)

    return (food ~= nil and BufferedAction(inst, food, ACTIONS.EAT))
        or nil
end

local function GetSpawnPoint(inst)
    return inst.components.knownlocations:GetLocation("spawnpoint")
end

function EyeOfTerrorMiniBrain:OnStart()
    local root = PriorityNode(
    {
        WhileNode(function() return not self.inst.sg:HasStateTag("charge") end, "Not Attacking",
            PriorityNode({
				BrainCommon.PanicTrigger(self.inst),
                BrainCommon.ElectricFencePanicTrigger(self.inst),
                AttackWall(self.inst),
                ChaseAndAttack(self.inst),
                DoAction(self.inst, EatFoodAction, "Find And Eat Food"),
                Wander(self.inst, GetSpawnPoint, 25),
            }, 0.5)
        ),
    }, 0.5)

    self.bt = BT(self.inst, root)
end

function EyeOfTerrorMiniBrain:OnInitializationComplete()
    local pos = self.inst:GetPosition()
    pos.y = 0

    self.inst.components.knownlocations:RememberLocation("spawnpoint", pos, true)
end

return EyeOfTerrorMiniBrain
