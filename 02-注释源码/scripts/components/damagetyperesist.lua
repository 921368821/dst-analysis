--============================================================
-- 文件：components/damagetyperesist.lua
-- 模块：组件 / damagetyperesist
-- 职责：组件「damagetyperesist」的实现。组件是挂在实体上的行为单元，通过 inst.components.damagetyperesist 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require("util/sourcemodifierlist")

local DamageTypeResist = Class(function(self, inst)
	self.inst = inst
	self.tags = {}
end)

function DamageTypeResist:AddResist(tag, src, pct, key)
	local modifiers = self.tags[tag]
	if modifiers == nil then
		modifiers = SourceModifierList(self.inst)
		self.tags[tag] = modifiers
	end
	modifiers:SetModifier(src, pct, key)
end

function DamageTypeResist:RemoveResist(tag, src, key)
	local modifiers = self.tags[tag]
	if modifiers ~= nil then
		modifiers:RemoveModifier(src, key)
		if modifiers:IsEmpty() then
			self.tags[tag] = nil
		end
	end
end

function DamageTypeResist:GetResistForTag(tag)
	local v = self.tags[tag]
	return v and v:Get() or 1
end

function DamageTypeResist:GetResist(attacker, weapon)
	local mult = 1
	if attacker ~= nil then
		for k, v in pairs(self.tags) do
			if attacker:HasTag(k) or (weapon ~= nil and weapon:HasTag(k)) then
				mult = mult * v:Get()
			end
		end
	end
	return mult
end

function DamageTypeResist:GetDebugString()
	local str
	for k, v in pairs(self.tags) do
		str = (str or "")..string.format("\n\t[%s] %f", k, v:Get())
	end
	return str
end

return DamageTypeResist
