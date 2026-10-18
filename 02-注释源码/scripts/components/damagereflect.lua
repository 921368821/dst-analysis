--============================================================
-- 文件：components/damagereflect.lua
-- 模块：组件 / damagereflect
-- 职责：组件「damagereflect」的实现。组件是挂在实体上的行为单元，通过 inst.components.damagereflect 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--Damage reflect component used by combat component

local DamageReflect = Class(function(self, inst)
    self.inst = inst

    self.reflectdamagefn = nil
    self.defaultdamage = 10
end)

function DamageReflect:SetReflectDamageFn(fn)
    self.reflectdamagefn = fn
end

function DamageReflect:SetDefaultDamage(value)
    self.defaultdamage = value
end

function DamageReflect:GetReflectedDamage(attacker, damage, weapon, stimuli, spdamage)
	if self.reflectdamagefn ~= nil then
		damage, spdamage = self.reflectdamagefn(self.inst, attacker, damage, weapon, stimuli, spdamage)
		return damage or self.defaultdamage, spdamage
	end
	return self.defaultdamage
end

return DamageReflect
