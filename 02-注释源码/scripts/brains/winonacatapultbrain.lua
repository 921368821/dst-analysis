--============================================================
-- 文件：brains/winonacatapultbrain.lua
-- 模块：AI 大脑 / winonacatapultbrain
-- 职责：大脑「winonacatapultbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("behaviours/standandattack")

local WinonaCatapultBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function WinonaCatapultBrain:OnStart()
    local root = PriorityNode(
    {
        StandAndAttack(self.inst),
	}, 0.1)

    self.bt = BT(self.inst, root)
end

return WinonaCatapultBrain
