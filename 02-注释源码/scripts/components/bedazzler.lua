--============================================================
-- 文件：components/bedazzler.lua
-- 模块：组件 / bedazzler
-- 职责：组件「bedazzler」的实现。组件是挂在实体上的行为单元，通过 inst.components.bedazzler 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Bedazzler = Class(function(self, inst)
    self.inst = inst
end)

function Bedazzler:SetUseAmount(use_amount)
	self.use_amount = use_amount
end

function Bedazzler:CanBedazzle(target)
	if target.components.burnable ~= nil and target.components.burnable:IsBurning() then
		return false, "BURNING"
	elseif target:HasTag("burnt") then
		return false, "BURNT"
	elseif target.components.freezable ~= nil and target.components.freezable:IsFrozen() then
		return false, "FROZEN"
	elseif target:HasTag("bedazzled") then
		return false, "ALREADY_BEDAZZLED"
	end

	return true
end

function Bedazzler:Bedazzle(target)
	target.components.bedazzlement:Start()

	if self.inst.components.finiteuses ~= nil then
		self.inst.components.finiteuses:Use(self.use_amount or 1)
	end
end

return Bedazzler