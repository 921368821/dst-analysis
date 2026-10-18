--============================================================
-- 文件：components/sanityauraadjuster.lua
-- 模块：组件 / sanityauraadjuster
-- 职责：组件「sanityauraadjuster」的实现。组件是挂在实体上的行为单元，通过 inst.components.sanityauraadjuster 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SanityAuraAdjuster = Class(function(self, inst)
    self.inst = inst
   	self.adjustmentfn = nil
   	self.players = {}
end)

function SanityAuraAdjuster:StopTask()
	if self.inst.sanityAuraAdjuster_task then
		self.inst.sanityAuraAdjuster_task:Cancel()
		self.inst.sanityAuraAdjuster_task = nil
	end
end

function SanityAuraAdjuster:StartTask()
	local checkforadjustments = function()	
		if self.adjustmentfn then
			self.players = self.adjustmentfn(self.inst, self.players)
		end		
	end

	if not self.inst.sanityAuraAdjuster_task then
		self.inst.sanityAuraAdjuster_task = self.inst:DoPeriodicTask(1,checkforadjustments)
	end
end

function SanityAuraAdjuster:SetAdjustmentFn(fn)
	self.adjustmentfn = fn
end

return SanityAuraAdjuster
