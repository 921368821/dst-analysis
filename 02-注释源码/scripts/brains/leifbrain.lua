--============================================================
-- 文件：brains/leifbrain.lua
-- 模块：AI 大脑 / leifbrain
-- 职责：大脑「leifbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "behaviours/chaseandattack"
require "behaviours/runaway"
require "behaviours/wander"
require "behaviours/doaction"
require "behaviours/attackwall"


local LeifBrain = Class(Brain, function(self, inst)
    Brain._ctor(self, inst)
end)

function LeifBrain:OnStart()
    local root =
        PriorityNode(
        {
			AttackWall(self.inst),
            ChaseAndAttack(self.inst),
            Wander(self.inst)
        },1)

    self.bt = BT(self.inst, root)
end

return LeifBrain