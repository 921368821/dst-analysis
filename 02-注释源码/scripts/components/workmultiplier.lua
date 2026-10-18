--============================================================
-- 文件：components/workmultiplier.lua
-- 模块：组件 / workmultiplier
-- 职责：组件「workmultiplier」的实现。组件是挂在实体上的行为单元，通过 inst.components.workmultiplier 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require("util/sourcemodifierlist")

local WorkMultiplier = Class(function(self, inst)
    self.inst = inst
    self.actions = {}
	--self.specialfn = nil
end)

function WorkMultiplier:GetMultiplier(action)
    return self.actions[action] and self.actions[action]:Get() or 1
end

function WorkMultiplier:AddMultiplier(action, multiplier, source)
    if not self.actions[action] then
        self.actions[action] = SourceModifierList(self.inst)
    end

    self.actions[action]:SetModifier(source, multiplier)
end

function WorkMultiplier:RemoveMultiplier(action, source)
    if self.actions[action] then
        self.actions[action]:RemoveModifier(source)
    end
end

function WorkMultiplier:SetSpecialMultiplierFn(fn)
	self.specialfn = fn
end

function WorkMultiplier:ResolveSpecialWorkAmount(action, target, tool, numworks, recoil)
	return self.specialfn ~= nil and self.specialfn(self.inst, action, target, tool, numworks, recoil) or numworks
end

return WorkMultiplier
