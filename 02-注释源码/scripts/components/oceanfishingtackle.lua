--============================================================
-- 文件：components/oceanfishingtackle.lua
-- 模块：组件 / oceanfishingtackle
-- 职责：组件「oceanfishingtackle」的实现。组件是挂在实体上的行为单元，通过 inst.components.oceanfishingtackle 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================




local OceanFishingTackle = Class(function(self, inst)
    self.inst = inst


--[[
	self.projectile_prefab = nil
	self.casting_data = {
		dist_max = 5,
		max_dist_offset = 1,
		max_angle_offset = 20,
	}
]]

end)

function OceanFishingTackle:SetCastingData(data, projectile_prefab)
	self.casting_data = data
	self.projectile_prefab = projectile_prefab
end

function OceanFishingTackle:SetupLure(data)
	self.lure_data = data.lure_data
	self.lure_setup = data
end

function OceanFishingTackle:IsSingleUse()
	return self.lure_setup ~= nil and self.lure_setup.single_use or false
end

return OceanFishingTackle