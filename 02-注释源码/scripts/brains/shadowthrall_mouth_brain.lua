--============================================================
-- 文件：brains/shadowthrall_mouth_brain.lua
-- 模块：AI 大脑 / shadowthrall_mouth_brain
-- 职责：大脑「shadowthrall_mouth_brain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("behaviours/chaseandattack")
require("behaviours/wander")

local WANDER_DIST = 6
local COMBAT_STEALTH_DELAY = 20
local IDLE_STEALTH_DELAY = 6

local ShadowThrallMouthBrain = Class(Brain, function(self, inst)
	Brain._ctor(self, inst)
end)

local function GetHome(inst)
	return inst.components.knownlocations:GetLocation("spawnpoint")
end

function ShadowThrallMouthBrain:OnStart()
	local root = PriorityNode({
		IfNode(function() return not self.inst._stealth and self.inst.components.combat:HasTarget() and GetTime() - self.inst.components.combat:GetLastAttackedTime() > COMBAT_STEALTH_DELAY end, "combatstealth",
			ActionNode(function() self.inst:PushEvent("enterstealth") end)),
		ChaseAndAttack(self.inst),
		WhileNode(function() return not (self.inst._stealth or self.inst.components.combat:HasTarget()) end, "idlestealth",
			ParallelNode{
				SequenceNode{
					WaitNode(IDLE_STEALTH_DELAY),
					ActionNode(function() self.inst:PushEvent("enterstealth") end),
				},
				Wander(self.inst, GetHome, WANDER_DIST, { minwaittime = 4 }),
			}),
		Wander(self.inst, GetHome, WANDER_DIST, { minwaittime = 4 }),
	}, 0.5)

	self.bt = BT(self.inst, root)
end

return ShadowThrallMouthBrain
