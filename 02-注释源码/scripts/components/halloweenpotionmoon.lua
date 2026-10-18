--============================================================
-- 文件：components/halloweenpotionmoon.lua
-- 模块：组件 / halloweenpotionmoon
-- 职责：组件「halloweenpotionmoon」的实现。组件是挂在实体上的行为单元，通过 inst.components.halloweenpotionmoon 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local HalloweenPotionMoon = Class(function(self, inst)
    self.inst = inst

	self.onusefn = nil
end)

function HalloweenPotionMoon:SetOnUseFn(fn)
	self.onusefn = fn
end

function HalloweenPotionMoon:Use(doer, target)
	local transformed_inst, container = nil, nil
	local success = false

	if target ~= nil and target.components.halloweenmoonmutable ~= nil then
		container = target.components.inventoryitem ~= nil and target.components.inventoryitem:GetContainer() or nil
		transformed_inst = target.components.halloweenmoonmutable:Mutate()
		success = true
	end

	if self.onusefn ~= nil then
		self.onusefn(self.inst, doer, target, success, transformed_inst, container)
	end

	if self.inst.components.stackable ~= nil and self.inst.components.stackable:IsStack() then
		self.inst.components.stackable:Get():Remove()
	else
		self.inst:Remove()
	end
end

return HalloweenPotionMoon
