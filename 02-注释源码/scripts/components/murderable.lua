--============================================================
-- 文件：components/murderable.lua
-- 模块：组件 / murderable
-- 职责：组件「murderable」的实现。组件是挂在实体上的行为单元，通过 inst.components.murderable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Murderable = Class(function(self, inst)
    self.inst = inst

	self.murdersound = nil

	self.inst:AddTag("murderable")
end)

function Murderable:OnRemoveFromEntity()
    self.inst:RemoveTag("murderable")
end

return Murderable
