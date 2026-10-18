--============================================================
-- 文件：brains/vault_crawlerbrain.lua
-- 模块：AI 大脑 / vault_crawlerbrain
-- 职责：大脑「vault_crawlerbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("behaviours/chaseandattack")
require("behaviours/wander")

local Vault_CrawlerBrain = Class(Brain, function(self, inst)
	Brain._ctor(self, inst)
end)

local function GetHomePos(inst)
	return inst.components.knownlocations:GetLocation("spawnpoint")
end

function Vault_CrawlerBrain:OnStart()
	local root = PriorityNode({
		WhileNode(
			function() return self.inst.sg and not self.inst.sg:HasStateTag("hiding") end,
			"<busy state guard>",
			PriorityNode({
				ChaseAndAttack(self.inst),
				Wander(self.inst, GetHomePos, 8, {
					minwalktime = 2,
					randwalktime = 1.5,
					minwaittime = 2.5,
					randwaittime = 2,
				}),
			}, 0.5)),
	}, 0.5)

	self.bt = BT(self.inst, root)
end

function Vault_CrawlerBrain:OnInitializationComplete()
	self.inst.components.knownlocations:RememberLocation("spawnpoint", self.inst:GetPosition(), true)
end

return Vault_CrawlerBrain
