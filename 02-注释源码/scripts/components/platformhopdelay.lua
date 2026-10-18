--============================================================
-- 文件：components/platformhopdelay.lua
-- 模块：组件 / platformhopdelay
-- 职责：组件「platformhopdelay」的实现。组件是挂在实体上的行为单元，通过 inst.components.platformhopdelay 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local PlatformHopDelay = Class(function(self, inst)
	self.inst = inst
	self.delayticks = 8
end)

function PlatformHopDelay:SetDelay(time)
	self.delayticks = math.ceil(time / FRAMES)
end

function PlatformHopDelay:SetDelayTicks(ticks)
	self.delayticks = ticks
end

function PlatformHopDelay:GetDelayTicks()
	return self.delayticks
end

return PlatformHopDelay
