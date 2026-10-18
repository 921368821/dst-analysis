--============================================================
-- 文件：components/occupier.lua
-- 模块：组件 / occupier
-- 职责：组件「occupier」的实现。组件是挂在实体上的行为单元，通过 inst.components.occupier 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Occupier = Class(function(self, inst)
    self.inst = inst
end)

--Registered actions in componentactions.lua

function Occupier:GetOwner()
	return self.owner
end

function Occupier:SetOwner(owner)
	self.owner = owner
end

return Occupier