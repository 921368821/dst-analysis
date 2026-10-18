--============================================================
-- 文件：components/planardefense.lua
-- 模块：组件 / planardefense
-- 职责：组件「planardefense」的实现。组件是挂在实体上的行为单元，通过 inst.components.planardefense 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require("util/sourcemodifierlist")

local PlanarDefense = Class(function(self, inst)
	self.inst = inst
	self.basedefense = 0
	self.externalmultipliers = SourceModifierList(inst)
	self.externalbonuses = SourceModifierList(inst, 0, SourceModifierList.additive)
end)

function PlanarDefense:SetBaseDefense(defense)
	self.basedefense = defense
end

function PlanarDefense:GetBaseDefense()
	return self.basedefense
end

function PlanarDefense:GetDefense()
	return self.basedefense * self.externalmultipliers:Get() + self.externalbonuses:Get()
end

--------------------------------------------------------------------------

function PlanarDefense:AddMultiplier(src, mult, key)
	self.externalmultipliers:SetModifier(src, mult, key)
end

function PlanarDefense:RemoveMultiplier(src, key)
	self.externalmultipliers:RemoveModifier(src, key)
end

function PlanarDefense:GetMultiplier()
	return self.externalmultipliers:Get()
end

--------------------------------------------------------------------------

function PlanarDefense:AddBonus(src, bonus, key)
	self.externalbonuses:SetModifier(src, bonus, key)
end

function PlanarDefense:RemoveBonus(src, key)
	self.externalbonuses:RemoveModifier(src, key)
end

function PlanarDefense:GetBonus()
	return self.externalbonuses:Get()
end

--------------------------------------------------------------------------

function PlanarDefense:GetDebugString()
	return string.format("Defense=%.2f [%.2fx%.2f+%.2f]", self:GetDefense(), self:GetBaseDefense(), self:GetMultiplier(), self:GetBonus())
end

return PlanarDefense
