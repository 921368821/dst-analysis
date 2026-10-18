--============================================================
-- 文件：components/powerload.lua
-- 模块：组件 / powerload
-- 职责：组件「powerload」的实现。组件是挂在实体上的行为单元，通过 inst.components.powerload 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local PowerLoad = Class(function(self, inst)
	self.inst = inst
	self.load = 1
	self.isidle = false
end)

function PowerLoad:SetLoad(_load, idle)
	self.load = _load
	self.isidle = idle == true
end

function PowerLoad:GetLoad()
	return self.load
end

function PowerLoad:IsIdle()
	return self.isidle
end

return PowerLoad
