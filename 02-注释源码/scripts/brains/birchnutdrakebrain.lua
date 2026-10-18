--============================================================
-- 文件：brains/birchnutdrakebrain.lua
-- 模块：AI 大脑 / birchnutdrakebrain
-- 职责：大脑「birchnutdrakebrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/chaseandattack"
require "behaviours/leash"
local BrainCommon = require("brains/braincommon")

local BirchNutDrakeBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local MAX_WANDER_DIST = 5

local function GetHomePos(inst)
    return inst.components.knownlocations:GetLocation("spawnpoint")
end

function BirchNutDrakeBrain:OnStart()
    local root = PriorityNode(
    {
		BrainCommon.PanicTrigger(self.inst),
        BrainCommon.ElectricFencePanicTrigger(self.inst),
        Leash(self.inst, GetHomePos, 20, 5),
        ChaseAndAttack(self.inst, 12, 21),
        ActionNode(function() self.inst:PushEvent("exit", { force = true, idleanim = true }) end),
    }, .25)

    self.bt = BT(self.inst, root)
end

function BirchNutDrakeBrain:OnInitializationComplete()
    self.inst.components.knownlocations:RememberLocation("spawnpoint", self.inst:GetPosition())
end

return BirchNutDrakeBrain
