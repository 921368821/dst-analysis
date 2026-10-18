--============================================================
-- 文件：components/gestaltcage.lua
-- 模块：组件 / gestaltcage
-- 职责：组件「gestaltcage」的实现。组件是挂在实体上的行为单元，通过 inst.components.gestaltcage 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local GestaltCage = Class(function(self, inst)
	self.inst = inst
	self.target = nil
end)

function GestaltCage:OnRemoveFromEntity()
	self:OnUntarget()
end

function GestaltCage:Capture(target, doer)
	if not target:IsValid() then
		return false, "MISSED"
	elseif not doer:IsNear(target, 1) then
		return false, "MISSED"
	elseif not (target.components.gestaltcapturable and target.components.gestaltcapturable:IsEnabled()) then
		return false, "MISSED"
	end

	local level = target.components.gestaltcapturable:GetLevel()
	local isplanar = target.components.gestaltcapturable:GetIsPlanar()
	target.components.gestaltcapturable:OnCaptured(self.inst, doer)

	local root = self.inst.components.inventoryitem and self.inst.components.inventoryitem:GetGrandOwner() or self.inst

	local x, y, z = root.Transform:GetWorldPosition()
	local rot = root.Transform:GetRotation()
	self.inst:Remove()

	local cage = SpawnPrefab("gestalt_cage_filled" .. level)
	cage.Transform:SetPosition(x, 0, z)
	cage.Transform:SetRotation(rot)
	if cage.SetIsPlanar then
		cage:SetIsPlanar(isplanar)
	end
	cage:StartCapture()

	return true
end

function GestaltCage:OnTarget(target)
	if self.target ~= target then
		self:OnUntarget()
		if target:IsValid() and target.components.gestaltcapturable then
			self.target = target
			target.components.gestaltcapturable:OnTargeted(self.inst)
		end
	end
end

function GestaltCage:OnUntarget(target)
	if self.target and (target == nil or self.target == target) then
		target = self.target
		self.target = nil
		if target:IsValid() and target.components.gestaltcapturable then
			target.components.gestaltcapturable:OnUntargeted(self.inst)
		end
	end
end

return GestaltCage
