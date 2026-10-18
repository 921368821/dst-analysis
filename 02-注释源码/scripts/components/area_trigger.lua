--============================================================
-- 文件：components/area_trigger.lua
-- 模块：组件 / area_trigger
-- 职责：组件「area_trigger」的实现。组件是挂在实体上的行为单元，通过 inst.components.area_trigger 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local AreaTrigger = Class(function(self, inst)
	--print("AreaTrigger")
    self.inst = inst
    self.stories = {}
    self.inst:ListenForEvent( "changearea", function(inst, area) self:CheckTrigger(area) end)
end)

function AreaTrigger:DoOverride(overrides)
	local retune = require("tuning_override")
	for i, override in ipairs(overrides) do
		if retune[override[1]] ~= nil then
			--print("Tuning", area.story, override[1], override[2])
			retune[override[1]](override[2])
		end
	end
end


function AreaTrigger:CheckTrigger(area)
	--print("AreaTrigger:CheckTrigger", area.story)
	if self.stories[area.story] ~= nil then
		self:DoOverride(self.stories[area.story])
	end
	if area.story_depth ~= nil and self.stories[area.story_depth] ~= nil then
		self:DoOverride(self.stories[area.story_depth])
	end
end

function AreaTrigger:RegisterTriggers(stories)
	--print("AreaTrigger:RegisterTriggers")
	self.stories = stories
end

return AreaTrigger
