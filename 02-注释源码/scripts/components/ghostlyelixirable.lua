--============================================================
-- 文件：components/ghostlyelixirable.lua
-- 模块：组件 / ghostlyelixirable
-- 职责：组件「ghostlyelixirable」的实现。组件是挂在实体上的行为单元，通过 inst.components.ghostlyelixirable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local GhostlyElixirable = Class(function(self, inst)
    self.inst = inst

	self.inst:AddTag("ghostlyelixirable")
end)

function GhostlyElixirable:GetApplyToTarget(doer, elixir)
	if self.overrideapplytotargetfn ~= nil then
		return self.overrideapplytotargetfn(self.inst, doer, elixir)
	end

	return self.inst
end

function GhostlyElixirable:OnRemoveFromEntity()
    self.inst:RemoveTag("ghostlyelixirable")
end

return GhostlyElixirable
