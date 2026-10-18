--============================================================
-- 文件：components/shadowdominance.lua
-- 模块：组件 / shadowdominance
-- 职责：组件「shadowdominance」的实现。组件是挂在实体上的行为单元，通过 inst.components.shadowdominance 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--Works with shadowsubmissive component

local function OnEquipped(inst, data)
	if data ~= nil and data.owner ~= nil and data.owner._shadowdsubmissive_task == nil then
		data.owner:AddTag("shadowdominance")
	end
end

local function _OnUnequipped(inst, owner)
	if owner._shadowdsubmissive_task ~= nil then
		--assert(not owner:HasTag("shadowdominance"))
		return
	elseif owner.components.inventory ~= nil then
		--V2C: Can't use inventory:EquipHasTag because this item will
		--     still be in the inventory equip slot at this point.
		for k, v in pairs(owner.components.inventory.equipslots) do
			if v ~= inst and v.components.shadowdominance ~= nil then
				--ANOTHER item with shadowdominance is still equipped
				return
			end
		end
	end
	owner:RemoveTag("shadowdominance")
end

local function OnUnequipped(inst, data)
	if data ~= nil and data.owner ~= nil then
		_OnUnequipped(inst, data.owner)
	end
end

local function OnRemove(inst)
	if inst.components.equippable ~= nil and inst.components.equippable:IsEquipped() and
		inst.components.inventoryitem ~= nil and inst.components.inventoryitem:IsHeld()
		then
		_OnUnequipped(inst, inst.components.inventoryitem.owner)
	end
end

local ShadowDominance = Class(function(self, inst)
	self.inst = inst

	--V2C: Recommended to explicitly add tag to prefab pristine state
	inst:AddTag("shadowdominance")

	inst:ListenForEvent("equipped", OnEquipped)
	inst:ListenForEvent("unequipped", OnUnequipped)
	inst:ListenForEvent("onremove", OnRemove) --ShadowDomninace.OnRemoveEntity is too late
end)

function ShadowDominance:OnRemoveFromEntity()
	self.inst:RemoveTag("shadowdominance")
	self.inst:RemoveEventCallback("equipped", OnEquipped)
	self.inst:RemoveEventCallback("unequipped", OnUnequipped)
	self.inst:RemoveEventCallback("onremove", OnRemove)
	OnRemove(self.inst)
end

return ShadowDominance
