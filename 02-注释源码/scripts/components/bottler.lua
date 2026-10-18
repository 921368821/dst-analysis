--============================================================
-- 文件：components/bottler.lua
-- 模块：组件 / bottler
-- 职责：组件「bottler」的实现。组件是挂在实体上的行为单元，通过 inst.components.bottler 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Bottler = Class(function(self, inst)
	self.inst = inst
	self.onbottlefn = nil
end)

function Bottler:SetOnBottleFn(fn)
	self.onbottlefn = fn
end

function Bottler:Bottle(target, doer)
	if self.onbottlefn and target and target:IsValid() and target:HasTag("canbebottled") then
		return self.onbottlefn(self.inst, target, doer)
	end
	return false
end

return Bottler
