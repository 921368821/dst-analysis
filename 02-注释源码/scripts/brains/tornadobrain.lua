--============================================================
-- 文件：brains/tornadobrain.lua
-- 模块：AI 大脑 / tornadobrain
-- 职责：大脑「tornadobrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/wander"
require "behaviours/leash"

local TornadoBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

local wanderTimes =
{
    minwalktime = .25,
    randwalktime = .25,
    minwaittime = .25,
    randwaittime = .25,
}

function TornadoBrain:OnStart()
    local root =
    PriorityNode(
    {
        Leash(self.inst, function() return self.inst.components.knownlocations:GetLocation("target") end, 3, 1, true),
        Wander(self.inst, function() return self.inst.components.knownlocations:GetLocation("target") end, 2, wanderTimes),
    }, .25)
    self.bt = BT(self.inst, root)
end

return TornadoBrain