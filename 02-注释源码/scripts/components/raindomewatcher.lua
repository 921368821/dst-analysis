--============================================================
-- 文件：components/raindomewatcher.lua
-- 模块：组件 / raindomewatcher
-- 职责：组件「raindomewatcher」的实现。组件是挂在实体上的行为单元，通过 inst.components.raindomewatcher 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local RainDomeWatcher = Class(function(self, inst)
	self.inst = inst
	self.underdome = false
	inst:StartUpdatingComponent(self)
end)

function RainDomeWatcher:IsUnderRainDome()
	return self.underdome
end

function RainDomeWatcher:OnUpdate(dt)
	local x, y, z = self.inst.Transform:GetWorldPosition()
	local domes = GetRainDomesAtXZ(x, z)
	if #domes > 0 then
		if not self.underdome then
			self.underdome = true
			self.inst:PushEvent("enterraindome")
		end
		self.inst:PushEvent("underraindomes", domes)
	elseif self.underdome then
		self.underdome = false
		self.inst:PushEvent("exitraindome")
	end
end

return RainDomeWatcher
