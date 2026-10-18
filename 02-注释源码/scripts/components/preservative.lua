--============================================================
-- 文件：components/preservative.lua
-- 模块：组件 / preservative
-- 职责：组件「preservative」的实现。组件是挂在实体上的行为单元，通过 inst.components.preservative 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Preservative = Class(function(self, inst)
    self.inst = inst
	self.percent_increase = 1

	self.divide_effect_by_stack_size = true
end,
nil)

return Preservative