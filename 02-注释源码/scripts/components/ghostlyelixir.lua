--============================================================
-- 文件：components/ghostlyelixir.lua
-- 模块：组件 / ghostlyelixir
-- 职责：组件「ghostlyelixir」的实现。组件是挂在实体上的行为单元，通过 inst.components.ghostlyelixir 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local GhostlyElixir = Class(function(self, inst)
    self.inst = inst

    self.inst:AddTag("ghostlyelixir")
end)

function GhostlyElixir:Apply(doer, target)
	if target:HasTag("elixir_drinker") then
		target = target.components.inventoryitem.owner
		if not target then
			return false
		end
	end
	target = target.components.ghostlyelixirable:GetApplyToTarget(doer, self.inst)

	if target ~= nil and self.doapplyelixerfn ~= nil then
		local success, reason = self.doapplyelixerfn(self.inst, doer, target)
		if success then
			if self.inst.components.stackable ~= nil then
				self.inst.components.stackable:Get():Remove()
			else
				self.inst:Remove()
			end
		end
		return success, reason
	end
	return false
end

function GhostlyElixir:OnRemoveFromEntity()
    self.inst:RemoveTag("ghostlyelixir")
end

return GhostlyElixir
