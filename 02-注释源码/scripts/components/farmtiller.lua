--============================================================
-- 文件：components/farmtiller.lua
-- 模块：组件 / farmtiller
-- 职责：组件「farmtiller」的实现。组件是挂在实体上的行为单元，通过 inst.components.farmtiller 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local FarmTiller = Class(function(self, inst)
    self.inst = inst
end)

function FarmTiller:Till(pt, doer)
    if TheWorld.Map:CanTillSoilAtPoint(pt.x, 0, pt.z, false) then
		TheWorld.Map:CollapseSoilAtPoint(pt.x, 0, pt.z)
        SpawnPrefab("farm_soil").Transform:SetPosition(pt:Get())

		if doer ~= nil then
			doer:PushEvent("tilling")
		end
        return true
    end
    return false
end

return FarmTiller
