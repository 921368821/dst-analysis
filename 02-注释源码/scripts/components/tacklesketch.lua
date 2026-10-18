--============================================================
-- 文件：components/tacklesketch.lua
-- 模块：组件 / tacklesketch
-- 职责：组件「tacklesketch」的实现。组件是挂在实体上的行为单元，通过 inst.components.tacklesketch 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local TackleSketch = Class(function(self, inst)
    self.inst = inst

	self.inst:AddTag("tacklesketch")
end,
nil,
{})

function TackleSketch:OnRemoveFromEntity()
    self.inst:RemoveTag("tacklesketch")
end

function TackleSketch:Teach(target)
	target.components.craftingstation:LearnItem(self.inst:GetSpecificSketchPrefab(), self.inst:GetRecipeName())
	target:PushEvent("onlearnednewtacklesketch")

	self.inst:Remove()
end

return TackleSketch