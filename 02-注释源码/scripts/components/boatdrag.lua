--============================================================
-- 文件：components/boatdrag.lua
-- 模块：组件 / boatdrag
-- 职责：组件「boatdrag」的实现。组件是挂在实体上的行为单元，通过 inst.components.boatdrag 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local BoatDrag = Class(function(self, inst)
	self.inst = inst

	self.drag = 0
	self.max_velocity_mod = 1

	self.forcedampening = 0

	self.sailforcemodifier = 1
end,
nil,
{})

function BoatDrag:GetDebugString()
	return string.format("drag:%f,  max_velocity_mod:%f,  forcedampening:%f", self.drag, self.max_velocity_mod, self.forcedampening)
end

return BoatDrag
