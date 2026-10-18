--============================================================
-- 文件：brains/wormwood_fruitdragonbrain.lua
-- 模块：AI 大脑 / wormwood_fruitdragonbrain
-- 职责：大脑「wormwood_fruitdragonbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/wander"
require "behaviours/follow"

local BrainCommon = require("brains/braincommon")

local MAX_CHASE_DIST = 12
local MAX_WANDER_DIST = 8

local FOLLOW_DISTANCE_MIN = 0
local FOLLOW_DISTANCE_TARGET = 8
local FOLLOW_DISTANCE_MAX = 15

local FruitDragonBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function GetLeader(inst)
    return inst.components.follower and inst.components.follower:GetLeader()
end

local function GetLeaderLocation(inst)
    local leader = GetLeader(inst)
    if leader == nil then
        return nil
    end

    return leader:GetPosition()
end

local wander_timing = {minwalktime = 4, randwalktime = 4, randwaittime = 1}

function FruitDragonBrain:OnStart()
    local root = PriorityNode(
    {
		BrainCommon.PanicTrigger(self.inst),
        BrainCommon.ElectricFencePanicTrigger(self.inst),
        Follow(self.inst, GetLeader, FOLLOW_DISTANCE_MIN, FOLLOW_DISTANCE_TARGET, FOLLOW_DISTANCE_MAX),
        ChaseAndAttack(self.inst, nil, MAX_CHASE_DIST),

        Wander(self.inst, GetLeaderLocation, MAX_WANDER_DIST, wander_timing),
    }, .25)
    self.bt = BT(self.inst, root)
end


return FruitDragonBrain