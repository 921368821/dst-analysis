--============================================================
-- 文件：components/researchpointconverter.lua
-- 模块：组件 / researchpointconverter
-- 职责：组件「researchpointconverter」的实现。组件是挂在实体上的行为单元，通过 inst.components.researchpointconverter 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--DON'T USE THIS! Use prototyper.lua instead.

local ResearchPointConverter = Class(function(self, inst)
    self.inst = inst
	self.val = 0
	self.active = false
	self.level = 1
	self.on = false
end)

function ResearchPointConverter:TurnOn()
	if not self.on and self.onturnon then
		self.onturnon(self.inst)
		self.on = true
	end
end

function ResearchPointConverter:TurnOff()
	if self.on and self.onturnoff then
		self.onturnoff(self.inst)
		self.on = false
	end
end


function ResearchPointConverter:Activate()
	if self.onactivate then
		self.onactivate()
	end
end


return ResearchPointConverter