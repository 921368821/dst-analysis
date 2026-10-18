--============================================================
-- 文件：components/storytellingprop.lua
-- 模块：组件 / storytellingprop
-- 职责：组件「storytellingprop」的实现。组件是挂在实体上的行为单元，通过 inst.components.storytellingprop 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local StoryTellingProp = Class(function(self, inst)
    self.inst = inst

	--V2C: Recommended to explicitly add tag to prefab pristine state
	self.inst:AddTag("storytellingprop")
end)

function StoryTellingProp:OnRemoveFromEntity()
    self.inst:RemoveTag("storytellingprop")
end

return StoryTellingProp