--============================================================
-- 文件：brains/shadow_leechbrain.lua
-- 模块：AI 大脑 / shadow_leechbrain
-- 职责：大脑「shadow_leechbrain」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require("behaviours/leash")
require("behaviours/faceentity")
require("behaviours/wander")

local JUMP_DIST = 6

local Shadow_LeechBrain = Class(Brain, function(self, inst)
	Brain._ctor(self, inst)
end)

local function GetTarget(inst)
	return inst.components.entitytracker:GetEntity("daywalker")
end

local function GetTargetPos(inst)
	local target = GetTarget(inst)
	return target ~= nil and target:GetPosition() or nil
end

local function KeepTarget(inst, target)
	return target:IsValid()
end

local function ShouldJump(inst)
	local target = GetTarget(inst)
	return inst:IsNear(target, JUMP_DIST)
end

function Shadow_LeechBrain:OnStart()
	local root = PriorityNode(
	{
		WhileNode(function() return not self.inst.sg:HasStateTag("jumping") end, "<jump guard>",
			PriorityNode({
				WhileNode(function() return ShouldJump(self.inst) end, "Jump",
					ActionNode(function()
						local target = GetTarget(self.inst)
						if target ~= nil then
							self.inst:PushEvent("jump", target)
							target:PushEvent("incoming_jump", self.inst)
						end
					end)),
				Leash(self.inst, GetTargetPos, 0, 0, true),
				FaceEntity(self.inst, GetTarget, KeepTarget),
				Wander(self.inst),
			}, .5)),
	}, .5)

	self.bt = BT(self.inst, root)
end

return Shadow_LeechBrain
