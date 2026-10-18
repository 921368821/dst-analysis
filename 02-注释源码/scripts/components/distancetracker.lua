--============================================================
-- 文件：components/distancetracker.lua
-- 模块：组件 / distancetracker
-- 职责：组件「distancetracker」的实现。组件是挂在实体上的行为单元，通过 inst.components.distancetracker 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local DistanceTracker = Class(function(self, inst)
	self.previous_pos = nil
	self.inst = inst
    inst:StartUpdatingComponent(self)
end)

function DistanceTracker:OnUpdate(dt)
	local mypos = Point(self.inst.Transform:GetWorldPosition())
	local distance = 0
	if self.previous_pos then
		distance = math.sqrt( distsq( mypos, self.previous_pos ) )
	end
	self.previous_pos = mypos

	--local meters_to_furlongs = 1.0 / 201.168
	--local furlongs_travelled = distance * meters_to_furlongs

	--TheSim:SendGameStat( "furlongs_travelled", distance )
end

return DistanceTracker

