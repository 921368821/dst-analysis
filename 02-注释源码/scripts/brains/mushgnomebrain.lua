--============================================================
-- 文件：brains/mushgnomebrain.lua
-- 模块：AI 大脑 / mushgnomebrain
-- 职责：大脑「mushgnomebrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/standandattack"
require "behaviours/standstill"
require "behaviours/wander"
local BrainCommon = require("brains/braincommon")

local MushGnomeBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local THREAT_PARAMS =
{
    -- We are avoiding our own target, as well as anyone targeting us.
    fn = function(candidate, inst)
        return candidate.components.combat:TargetIs(inst) or
                inst.components.combat:TargetIs(candidate)
    end,
    tags =
    {
        "_combat",
    },
    notags =
    {
        "DECOR",
        "FX",
        "INLIMBO",
    },
}

function MushGnomeBrain:OnStart()
    local root =
        PriorityNode(
        {
            WhileNode(function() return self.inst.components.combat:HasTarget() and not self.inst.components.combat:InCooldown() end, "Spray Spores",
                StandAndAttack(self.inst, nil, 7)),
			BrainCommon.PanicTrigger(self.inst),
            BrainCommon.ElectricFencePanicTrigger(self.inst),
            RunAway(self.inst, THREAT_PARAMS, 5, 10),
            Wander(self.inst),
        }, 1)

    self.bt = BT(self.inst, root)
end

return MushGnomeBrain
