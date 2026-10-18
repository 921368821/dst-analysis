--============================================================
-- 文件：components/wx78_abilitycooldowns.lua
-- 模块：组件 / wx78_abilitycooldowns
-- 职责：组件「wx78_abilitycooldowns」的实现。组件是挂在实体上的行为单元，通过 inst.components.wx78_abilitycooldowns 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Wx78_AbilityCooldowns = Class(function(self, inst)
	self.inst = inst
	self.ismastersim = TheWorld.ismastersim
	self.cooldowns = {}

	self._onremovecd = function(cd)
		local abilityname = cd:GetAbilityName()
		if abilityname == 0 then
			print("Wx78_AbilityCooldowns::_onremovecd: invalid abilityname")
		elseif self.cooldowns[abilityname] == nil then
			print("Wx78_AbilityCooldowns::_onremovecd: missing abilityname \""..(cd.dbg_abilityname or tostring(abilityname)).."\"")
		else
			self.cooldowns[abilityname] = nil
			self.inst:PushEvent("wx78_abilitycooldowns_update", { abilityname = abilityname })
		end
	end
end)

local function GetHash(abilityname)
	return type(abilityname) == "string" and hash(abilityname) or abilityname
end

--------------------------------------------------------------------------
--Common

function Wx78_AbilityCooldowns:IsInCooldown(abilityname)
	return self.cooldowns[GetHash(abilityname)] ~= nil
end

function Wx78_AbilityCooldowns:GetAbilityCooldownPercent(abilityname)
	local cd = self.cooldowns[GetHash(abilityname)]
	return cd and cd:GetPercent() or nil
end

function Wx78_AbilityCooldowns:RegisterAbilityCooldown(cd)
	local abilityname = cd:GetAbilityName()
	if abilityname == 0 then
		print("Wx78_AbilityCooldowns::RegisterAbilityCooldown: invalid abilityname")
	elseif self.cooldowns[abilityname] then
		print("Wx78_AbilityCooldowns::RegisterAbilityCooldown: duplicate abilityname \""..(cd.dbg_abilityname or tostring(abilityname)).."\"")
	else
		self.cooldowns[abilityname] = cd
		self.inst:PushEvent("wx78_abilitycooldowns_update", { abilityname = abilityname })
		self.inst:ListenForEvent("onremove", self._onremovecd, cd)
	end
end

--------------------------------------------------------------------------
--Server only

function Wx78_AbilityCooldowns:RestartAbilityCooldown(abilityname, duration)
	if self.ismastersim then
		local abilityhash = GetHash(abilityname)
		local cd = self.cooldowns[abilityhash]
		if cd then
			cd:RestartAbilityCooldown(duration)
		else
			cd = SpawnPrefab("wx78_abilitycooldown")
			cd.entity:SetParent(self.inst.entity)
			cd.Network:SetClassifiedTarget(self.inst)
			cd:InitAbilityCooldown(abilityhash, duration)
			cd.dbg_abilityname = abilityname
			self:RegisterAbilityCooldown(cd)
		end
	end
end

function Wx78_AbilityCooldowns:StopAbilityCooldown(abilityname)
	if self.ismastersim then
		abilityname = GetHash(abilityname)
		local cd = self.cooldowns[abilityname]
		if cd then
			cd:Remove()
		end
	end
end

--------------------------------------------------------------------------
--Debug

function Wx78_AbilityCooldowns:GetDebugString()
	local str
	for k, v in pairs(self.cooldowns) do
		str = (str or "")..string.format("\n[%d]%s: %.2f%% (%ds)", v:GetAbilityName(), v.dbg_abilityname and ("("..v.dbg_abilityname..")") or "", v:GetPercent() * 100, v:GetLength())
	end
	return str
end

return Wx78_AbilityCooldowns