--============================================================
-- 文件：brains/lureplantbrain.lua
-- 模块：AI 大脑 / lureplantbrain
-- 职责：大脑「lureplantbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/controlminions"
require "behaviours/standstill"

local LureplantBrain = Class(Brain, function(self, inst)
	Brain._ctor(self, inst)
end)

function LureplantBrain:OnStart()
    local root = PriorityNode(
    {
        ControlMinions(self.inst),
        --StandStill(self.inst),
    }, .25)

    self.bt = BT(self.inst, root)
end

return LureplantBrain