--============================================================
-- 文件：brains/glommerbrain.lua
-- 模块：AI 大脑 / glommerbrain
-- 职责：大脑「glommerbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/follow"
require "behaviours/wander"
require "behaviours/faceentity"
local BrainCommon = require("brains/braincommon")

local MIN_FOLLOW_DIST = 0
local MAX_FOLLOW_DIST = 6
local TARGET_FOLLOW_DIST = 4

local MAX_WANDER_DIST = 10

local function GetLeader(inst)
    return inst.components.follower and inst.components.follower:GetLeader()
end

local function GetFaceTargetFn(inst)
    return GetLeader(inst)
end

local function KeepFaceTargetFn(inst, target)
    return GetLeader(inst) == target
end

local function GetFollowPos(inst)
    local leader = GetLeader(inst)
    return leader and leader:GetPosition() or
        inst:GetPosition()
end

local function WanderOff(inst)
    if inst.ShouldLeaveWorld then
        return BufferedAction(inst, nil, ACTIONS.GOHOME)
    end
end

local GlommerBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function GlommerBrain:OnStart()
    local root =
    PriorityNode(
    {
		BrainCommon.PanicTrigger(self.inst),
        BrainCommon.ElectricFencePanicTrigger(self.inst),
        DoAction(self.inst, WanderOff),
        Follow(self.inst, function() return GetLeader(self.inst) end, MIN_FOLLOW_DIST, TARGET_FOLLOW_DIST, MAX_FOLLOW_DIST),
        FaceEntity(self.inst, GetFaceTargetFn, KeepFaceTargetFn),
        Wander(self.inst, GetFollowPos, MAX_WANDER_DIST),
    }, .25)
    self.bt = BT(self.inst, root)
end

return GlommerBrain