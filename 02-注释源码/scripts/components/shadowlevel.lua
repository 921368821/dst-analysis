--============================================================
-- 文件：components/shadowlevel.lua
-- 模块：组件 / shadowlevel
-- 职责：组件「shadowlevel」的实现。组件是挂在实体上的行为单元，通过 inst.components.shadowlevel 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local ShadowLevel = Class(function(self, inst)
	self.inst = inst
	self.level = 1
	--self.levelfn = nil

	--V2C: Recommended to explicitly add tag to prefab pristine state
	inst:AddTag("shadowlevel")
end)

function ShadowLevel:OnRemoveFromEntity()
	self.inst:RemoveTag("shadowlevel")
end

function ShadowLevel:SetDefaultLevel(level)
	self.level = level
end

function ShadowLevel:SetLevelFn(fn)
	self.levelfn = fn
end

function ShadowLevel:GetCurrentLevel()
	return self.levelfn ~= nil and self.levelfn(self.inst) or self.level
end

return ShadowLevel
