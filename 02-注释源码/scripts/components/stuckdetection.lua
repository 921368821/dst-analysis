--============================================================
-- 文件：components/stuckdetection.lua
-- 模块：组件 / stuckdetection
-- 职责：组件「stuckdetection」的实现。组件是挂在实体上的行为单元，通过 inst.components.stuckdetection 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local STUCK_DIST_SQ = .05 * .05

local StuckDetection = Class(function(self, inst)
	self.inst = inst
	self.timetostuck = 2
	--self.starttime = nil
	--self.lastx = nil
	--self.lastz = nil
end)

--How long before considering stuck
function StuckDetection:SetTimeToStuck(t)
	self.timetostuck = t
end

function StuckDetection:IsStuck()
	local x, y, z = self.inst.Transform:GetWorldPosition()
	local t = GetTime()
	if self.starttime == nil or distsq(self.lastx, self.lastz, x, z) > STUCK_DIST_SQ then
		self.lastx, self.lastz = x, z
		self.starttime = t
		return false
	end
	self.lastx, self.lastz = x, z
	return self.starttime + self.timetostuck < t
end

function StuckDetection:GetRemainingTime()
    if self.starttime == nil then
        return -1
    end

    return (self.timetostuck + self.starttime) - GetTime()
end

function StuckDetection:Reset()
	if self.starttime ~= nil then
		local y
		self.lastx, y, self.lastz = self.inst.Transform:GetWorldPosition()
		self.starttime = GetTime()
	end
end

return StuckDetection
