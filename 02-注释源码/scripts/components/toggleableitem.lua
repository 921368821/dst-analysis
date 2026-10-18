--============================================================
-- 文件：components/toggleableitem.lua
-- 模块：组件 / toggleableitem
-- 职责：组件「toggleableitem」的实现。组件是挂在实体上的行为单元，通过 inst.components.toggleableitem 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local ToggleableItem = Class(function(self, inst)
	self.inst = inst
	self.onusefn = nil
	self.onstopusefn = nil
	self.on = false
	self.stopuseevents = nil
end)

function ToggleableItem:SetOnToggleFn(fn)
	self.onusefn = fn
end

function ToggleableItem:CanInteract(doer)
    return true
end

function ToggleableItem:ToggleItem()
	if self.on then 
		self.on = false
	else
		self.on = true
	end
	if self.onusefn then
		self.onusefn(self.inst,self.on)
	end
end

return ToggleableItem