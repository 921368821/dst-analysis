--============================================================
-- 文件：components/aoediminishingreturns.lua
-- 模块：组件 / aoediminishingreturns
-- 职责：组件「aoediminishingreturns」的实现。组件是挂在实体上的行为单元，通过 inst.components.aoediminishingreturns 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require("util/sourcemodifierlist")

local AoeDiminishingReturns = Class(function(self, inst)
	self.inst = inst
	self.mult = SourceModifierList(inst)
end)

function AoeDiminishingReturns:OnRemoveFromEntity()
	self.mult:Reset()
end

return AoeDiminishingReturns