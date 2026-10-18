--============================================================
-- 文件：components/planarentity.lua
-- 模块：组件 / planarentity
-- 职责：组件「planarentity」的实现。组件是挂在实体上的行为单元，通过 inst.components.planarentity 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local PlanarEntity = Class(function(self, inst)
	self.inst = inst

	--self.spawn_effect_on = nil --For centipede
end)

function PlanarEntity:AbsorbDamage(damage, attacker, weapon, spdmg)
	damage = (math.sqrt(damage * 4 + 64) - 8) * 4
	if spdmg == nil or spdmg.planar == nil then
		self:OnResistNonPlanarAttack(attacker)
	end
	return damage, spdmg
end

function PlanarEntity:OnResistNonPlanarAttack(attacker)
	local inst = self.spawn_effect_on ~= nil and self.spawn_effect_on(self.inst, attacker) or self.inst

	local fx = SpawnPrefab("planar_resist_fx")
	local radius = inst:GetPhysicsRadius(0) + .2 + math.random() * .5
	local x, y, z = inst.Transform:GetWorldPosition()
	local theta
	if attacker ~= nil then
		local x1, y1, z1 = attacker.Transform:GetWorldPosition()
		if x ~= x1 or z ~= z1 then
			theta = math.atan2(z - z1, x1 - x) + math.random() * 2 - 1
		end
	end
	if theta == nil then
		theta = math.random() * TWOPI
	end
	fx.Transform:SetPosition(
		x + radius * math.cos(theta),
		math.random(),
		z - radius * math.sin(theta)
	)
end

function PlanarEntity:OnPlanarAttackUndefended(target)
	SpawnPrefab("planar_hit_fx").entity:SetParent(target.entity)
end

return PlanarEntity
