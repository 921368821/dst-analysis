--============================================================
-- 文件：components/fishingnet.lua
-- 模块：组件 / fishingnet
-- 职责：组件「fishingnet」的实现。组件是挂在实体上的行为单元，通过 inst.components.fishingnet 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local FishingNet = Class(function(self, inst)
    self.inst = inst
end)

function FishingNet:CastNet(pos_x, pos_z, doer)
	local visualizer = SpawnPrefab("fishingnetvisualizer")
	visualizer.components.fishingnetvisualizer:BeginCast(doer, pos_x, pos_z)

	self.visualizer = visualizer

	return true
end

return FishingNet
