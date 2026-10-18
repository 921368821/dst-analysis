--============================================================
-- 文件：components/ocean.lua
-- 模块：组件 / ocean
-- 职责：组件「ocean」的实现。组件是挂在实体上的行为单元，通过 inst.components.ocean 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local function set_ocean_angle(inst)
	inst.currentAngle = 45 * math.random(0, 7) + 22.5 --math.random(0, 359)
end

local Ocean = Class(function(self, inst)
	self.inst = inst
	self.currentAngle = 0
	self.currentSpeed = 1
	set_ocean_angle(self)
end)

function Ocean:OnUpdate( dt )
end

function Ocean:GetCurrentAngle()
	return self.currentAngle
end

function Ocean:GetCurrentSpeed()
	return self.currentSpeed
end

function Ocean:GetCurrentVec3()
	return self.currentSpeed * math.cos(self.currentAngle * DEGREES), 0, self.currentSpeed * math.sin(self.currentAngle * DEGREES)
end

return Ocean