--============================================================
-- 文件：components/houndedtarget.lua
-- 模块：组件 / houndedtarget
-- 职责：组件「houndedtarget」的实现。组件是挂在实体上的行为单元，通过 inst.components.houndedtarget 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require("util/sourcemodifierlist")

local HoundedTarget = Class(function(self, inst)
    self.inst = inst

	self.target_weight_mult = SourceModifierList(inst)
	self.hound_thief_sources = SourceModifierList(inst, false, SourceModifierList.boolean)

	self.hound_thief = false -- Deprecated
end)

function HoundedTarget:GetTargetWeight()
	return self.target_weight_mult:Get()
end

function HoundedTarget:IsHoundThief()
	return self.hound_thief_sources:Get() or self.hound_thief
end

return HoundedTarget
