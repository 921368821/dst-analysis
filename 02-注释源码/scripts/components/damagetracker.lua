--============================================================
-- 文件：components/damagetracker.lua
-- 模块：组件 / damagetracker
-- 职责：组件「damagetracker」的实现。组件是挂在实体上的行为单元，通过 inst.components.damagetracker 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--Tracks damage done during the period that this component is enabled.
--Calls a fn if the damage threshold is reached.

local DamageTracker = Class(function(self, inst)
	self.inst = inst

	self.damage_done = 0
	self.damage_threshold = 2500
	self.damage_threshold_fn = nil

	self.enabled = false

	self.inst:ListenForEvent("healthdelta", function(inst, data) self:OnHealthDelta(data) end)
end)

function DamageTracker:Start()
	self.enabled = true
end

function DamageTracker:Stop()
	self.enabled = false
end

function DamageTracker:OnHealthDelta(data)
	if self.enabled then
		local old = self.damage_done
		self.damage_done = self.damage_done + math.abs(data.amount)

		if old < self.damage_threshold and self.damage_done >= self.damage_threshold then
			if self.damage_threshold_fn then
				self.damage_threshold_fn(self.inst)
			end
		end
	end
end

return DamageTracker