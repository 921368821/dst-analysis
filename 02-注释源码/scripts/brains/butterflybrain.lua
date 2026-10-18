--============================================================
-- 文件：brains/butterflybrain.lua
-- 模块：AI 大脑 / butterflybrain
-- 职责：大脑「butterflybrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/runaway"
require "behaviours/wander"
require "behaviours/doaction"
require "behaviours/findflower"
local BrainCommon = require("brains/braincommon")

local RUN_AWAY_DIST = 5
local STOP_RUN_AWAY_DIST = 10
local POLLINATE_FLOWER_DIST = 10
local SEE_FLOWER_DIST = 30
local MAX_WANDER_DIST = 20

local FLOWER_TAGS = {"flower"}

local function NearestFlowerPos(inst)
    local flower = GetClosestInstWithTag(FLOWER_TAGS, inst, SEE_FLOWER_DIST)
    if flower and
       flower:IsValid() then
        return Vector3(flower.Transform:GetWorldPosition() )
    end
end

local function GoHomeAction(inst)
    local flower = GetClosestInstWithTag(FLOWER_TAGS, inst, SEE_FLOWER_DIST)
    if flower and
       flower:IsValid() then
        return BufferedAction(inst, flower, ACTIONS.GOHOME, nil, Vector3(flower.Transform:GetWorldPosition() ))
    end
end

local RUN_AWAY_PARAMS =
{
    tags = {"scarytoprey"},
    fn = function(guy)
        return not (guy.components.skilltreeupdater
                and guy.components.skilltreeupdater:IsActivated("wormwood_bugs"))
    end,
}

local ButterflyBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function ButterflyBrain:OnStart()

    local root =
        PriorityNode(
        {
			BrainCommon.PanicTrigger(self.inst),
            BrainCommon.ElectricFencePanicTrigger(self.inst),
            RunAway(self.inst, RUN_AWAY_PARAMS, RUN_AWAY_DIST, STOP_RUN_AWAY_DIST),
            IfNode(function() return not TheWorld.state.isday end, "IsNight",
                DoAction(self.inst, GoHomeAction, "go home", true )),
            IfNode(function() return self.inst.components.pollinator:HasCollectedEnough() end, "IsFullOfPollen",
                DoAction(self.inst, GoHomeAction, "go home", true )),
            FindFlower(self.inst),
            Wander(self.inst, NearestFlowerPos, MAX_WANDER_DIST)
        },1)


    self.bt = BT(self.inst, root)


end

return ButterflyBrain