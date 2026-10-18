--============================================================
-- 文件：brains/eyeturretbrain.lua
-- 模块：AI 大脑 / eyeturretbrain
-- 职责：大脑「eyeturretbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/standandattack"
require "behaviours/faceentity"

local START_FACE_DIST = 10
local KEEP_FACE_DIST = 15

local EyeTurretBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function GetFaceTargetFn(inst)
    local target = FindClosestPlayerToInst(inst, START_FACE_DIST)
    return target ~= nil and not target:HasTag("notarget") and target or nil
end

local function KeepFaceTargetFn(inst, target)
    return not target:HasTag("notarget") and inst:IsNear(target, KEEP_FACE_DIST)
end

function EyeTurretBrain:OnStart()
    local root = PriorityNode(
    {
        StandAndAttack(self.inst),
        FaceEntity(self.inst, GetFaceTargetFn, KeepFaceTargetFn),
    }, .25)

    self.bt = BT(self.inst, root)
end

return EyeTurretBrain
