--============================================================
-- 文件：brains/mandrakebrain.lua
-- 模块：AI 大脑 / mandrakebrain
-- 职责：大脑「mandrakebrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/follow"
require "behaviours/wander"
local BrainCommon = require("brains/braincommon")

local MIN_FOLLOW_DIST = 2
local TARGET_FOLLOW_DIST = 3
local MAX_FOLLOW_DIST = 8

local function GetLeader(inst)
    return inst.components.follower and inst.components.follower:GetLeader()
end

local function KeepFaceTargetFn(inst, target)
    return GetLeader(inst) == target
end

local MandrakeBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function MandrakeBrain:OnStart()
    local root = PriorityNode(
    {
		BrainCommon.PanicTrigger(self.inst),
        BrainCommon.ElectricFencePanicTrigger(self.inst),
        Follow(self.inst, GetLeader, MIN_FOLLOW_DIST, TARGET_FOLLOW_DIST, MAX_FOLLOW_DIST),
        FaceEntity(self.inst, GetLeader, KeepFaceTargetFn),
        Wander(self.inst),
    }, .25)

    self.bt = BT(self.inst, root)
end

return MandrakeBrain
