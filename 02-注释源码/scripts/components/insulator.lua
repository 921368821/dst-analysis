--============================================================
-- 文件：components/insulator.lua
-- 模块：组件 / insulator
-- 职责：组件「insulator」的实现。组件是挂在实体上的行为单元，通过 inst.components.insulator 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Insulator = Class(function(self, inst)
    self.inst = inst
    self.insulation = 0
    self.type = SEASONS.WINTER
end)

function Insulator:SetSummer()
	self.type = SEASONS.SUMMER
end

function Insulator:SetWinter()
	self.type = SEASONS.WINTER
end

function Insulator:GetType()
	return self.type
end

function Insulator:IsType(type)
	return self.type == type
end

function Insulator:SetInsulation(val)
	self.insulation = val
end

function Insulator:GetInsulation()
	return self.insulation, self:GetType()
end

return Insulator
