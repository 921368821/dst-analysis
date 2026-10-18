--============================================================
-- 文件：components/forgerepairable.lua
-- 模块：组件 / forgerepairable
-- 职责：组件「forgerepairable」的实现。组件是挂在实体上的行为单元，通过 inst.components.forgerepairable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function onrepairmaterial(self, repairmaterial, old_repairmaterial)
	if self.repairable then
		if old_repairmaterial ~= nil then
			self.inst:RemoveTag("forgerepairable_"..old_repairmaterial)
		end
		if repairmaterial ~= nil then
			self.inst:AddTag("forgerepairable_"..repairmaterial)
		end
	end
end

local function onrepairable(self, repairable)
	if self.repairmaterial ~= nil then
		if self.repairable then
			self.inst:AddTag("forgerepairable_"..self.repairmaterial)
		else
			self.inst:RemoveTag("forgerepairable_"..self.repairmaterial)
		end
	end
end

local ForgeRepairable = Class(function(self, inst)
	self.inst = inst
	--self.repairmaterial = nil
	--self.repairable = nil
	--self.onrepaired = nil

	if inst.components.armor ~= nil then
		self:SetRepairable(inst.components.armor:IsDamaged())
	elseif inst.components.fueled ~= nil then
		self:SetRepairable(inst.components.fueled:GetPercent() < 1)
	end
end,
nil,
{
	repairmaterial = onrepairmaterial,
	repairable = onrepairable,
})

function ForgeRepairable:OnRemoveFromEntity()
	if self.repairable and self.repairmaterial ~= nil then
		self.inst:RemoveTag("forgerepairable_"..self.repairmaterial)
	end
end

function ForgeRepairable:SetRepairMaterial(material)
	self.repairmaterial = material
end

function ForgeRepairable:SetRepairable(repairable)
	self.repairable = repairable
end

function ForgeRepairable:SetOnRepaired(fn)
	self.onrepaired = fn
end

function ForgeRepairable:Repair(doer, repair_item)
	if repair_item.components.forgerepair == nil or self.repairmaterial ~= repair_item.components.forgerepair.repairmaterial then
		--wrong material
		return false
	elseif not self.repairable then
		--not repairable
		return false
	elseif not repair_item.components.forgerepair:OnRepair(self.inst, doer) then
		return false
	end

	if self.onrepaired ~= nil then
		self.onrepaired(self.inst, doer, repair_item)
	end
	return true
end

return ForgeRepairable
