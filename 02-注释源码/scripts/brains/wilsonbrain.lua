--============================================================
-- 文件：brains/wilsonbrain.lua
-- 模块：AI 大脑 / wilsonbrain
-- 职责：大脑「wilsonbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/chaseandattack"

local RUN_THRESH = 4.5
local MAX_CHASE_TIME = 5

local WilsonBrain = Class(Brain, function(self, inst)
    Brain._ctor(self,inst)
end)


function WilsonBrain:OnStart()
    local root = PriorityNode(
    {
    	WhileNode(function() return self.inst.components.playercontroller ~= nil and self.inst.components.playercontroller:IsControlPressed(CONTROL_PRIMARY) end, "Hold LMB", ChaseAndAttack(self.inst, MAX_CHASE_TIME)),
    	ChaseAndAttack(self.inst, MAX_CHASE_TIME, nil, 1),
    },0)

    self.bt = BT(self.inst, root)

end

return WilsonBrain