--============================================================
-- 文件：components/damagetypebonus.lua
-- 模块：组件 / damagetypebonus
-- 职责：组件「damagetypebonus」的实现。组件是挂在实体上的行为单元，通过 inst.components.damagetypebonus 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require("util/sourcemodifierlist")

local DamageTypeBonus = Class(function(self, inst)
	self.inst = inst

	self.tags = {}
	--self.bonuscallbacks = {}
end)

function DamageTypeBonus:AddBonus(tag, src, pct, key)
	local modifiers = self.tags[tag]
	if modifiers == nil then
		modifiers = SourceModifierList(self.inst)
		self.tags[tag] = modifiers
	end
	modifiers:SetModifier(src, pct, key)
end

function DamageTypeBonus:RemoveBonus(tag, src, key)
	local modifiers = self.tags[tag]
	if modifiers ~= nil then
		modifiers:RemoveModifier(src, key)
		if modifiers:IsEmpty() then
			self.tags[tag] = nil
		end
	end
end

-- add a callback to return a multiplier
function DamageTypeBonus:AddBonusCallback(fn)
    self.bonuscallbacks = self.bonuscallbacks or {}
    self:RemoveBonusCallback(fn)
    table.insert(self.bonuscallbacks, fn)
end

function DamageTypeBonus:RemoveBonusCallback(fn)
    if self.bonuscallbacks ~= nil then
        table.removearrayvalue(self.bonuscallbacks, fn)
    end
end

function DamageTypeBonus:GetBonus(target)
	local mult = 1
	if target ~= nil then
		for k, v in pairs(self.tags) do
			if target:HasTag(k) then
				mult = mult * v:Get()
			end
		end
		if self.bonuscallbacks ~= nil then
			for i, fn in ipairs(self.bonuscallbacks) do
    		    mult = mult * (fn(self.inst, target) or 1)
    		end
		end
	end
	return mult
end

function DamageTypeBonus:GetDebugString()
	local str
	for k, v in pairs(self.tags) do
		str = (str or "")..string.format("\n\t[%s] %f", k, v:Get())
	end
	return str
end

return DamageTypeBonus
