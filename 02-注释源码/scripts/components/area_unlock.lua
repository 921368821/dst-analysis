--============================================================
-- 文件：components/area_unlock.lua
-- 模块：组件 / area_unlock
-- 职责：组件「area_unlock」的实现。组件是挂在实体上的行为单元，通过 inst.components.area_unlock 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local AreaUnlock = Class(function(self, inst)
    self.inst = inst
    self.stories = {}
    self.inst:ListenForEvent( "changearea", function(inst, area) self:CheckUnlock(area) end)
end)


function AreaUnlock:CheckUnlock(area)
	if self.stories[area.story] ~= nil and self.stories[area.story] == false then
		--print("Unlocking", area.story)
		self.stories[area.story] = true
	end
end

function AreaUnlock:RegisterStory(story)
	self.stories[story] = false
end

function AreaUnlock:GetUnlocked()
	local unlocked = {}
	for k,v in pairs(self.stories) do
		if v == true then
			table.insert(unlocked, k)
		end
	end
	return unlocked
end

return AreaUnlock