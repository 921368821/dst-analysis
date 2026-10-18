--============================================================
-- 文件：brains/boatrace_spectator_dragonlingbrain.lua
-- 模块：AI 大脑 / boatrace_spectator_dragonlingbrain
-- 职责：大脑「boatrace_spectator_dragonlingbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/follow"
require "behaviours/wander"

local BoatraceSpectatorDragonlingBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local function SpectatingBoatrace(inst)
    return inst.components.entitytracker:GetEntity("indicator")
end

local UPDATE_RATE = 0.25
function BoatraceSpectatorDragonlingBrain:OnStart()
    local function is_not_flying() return not self.inst.sg:HasStateTag("flight") end

    local root = PriorityNode({
        FailIfSuccessDecorator(ConditionWaitNode(is_not_flying, "Block While Flying")),
        -----------------------------------------------------------------------------------------
        Follow(self.inst,
            SpectatingBoatrace,
            TUNING.BOATRACE_SPECTATOR_TARGET_DISTANCE,
            TUNING.BOATRACE_SPECTATOR_MAX_DISTANCE,
            TUNING.BOATRACE_SPECTATOR_MAX_DISTANCE
        ),
        FaceEntity(self.inst, SpectatingBoatrace, SpectatingBoatrace),
    }, UPDATE_RATE)

    self.bt = BT(self.inst, root)
end

return BoatraceSpectatorDragonlingBrain