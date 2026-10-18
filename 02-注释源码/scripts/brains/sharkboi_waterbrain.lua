--============================================================
-- 文件：brains/sharkboi_waterbrain.lua
-- 模块：AI 大脑 / sharkboi_waterbrain
-- 职责：大脑「sharkboi_waterbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("behaviours/wander")

local SharkboiWaterBrain = Class(Brain, function(self, inst)
	Brain._ctor(self, inst)
end)

function SharkboiWaterBrain:OnStart()
	local root = PriorityNode({
		Wander(self.inst),
	}, 0.5)

	self.bt = BT(self.inst, root)
end

return SharkboiWaterBrain
