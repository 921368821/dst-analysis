--============================================================
-- 文件：components/plantresearchable.lua
-- 模块：组件 / plantresearchable
-- 职责：组件「plantresearchable」的实现。组件是挂在实体上的行为单元，通过 inst.components.plantresearchable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local PlantResearchable = Class(function(self, inst)
    self.inst = inst

    self.inst:AddTag("plantresearchable")
end)

function PlantResearchable:SetResearchFn(fn)
    self.reasearchinfofn = fn
end

function PlantResearchable:GetResearchInfo()
    if self.reasearchinfofn then
        return self.reasearchinfofn(self.inst)
    end
end

function PlantResearchable:IsRandomSeed()
    local plant = self:GetResearchInfo()
    return plant == nil
end

function PlantResearchable:LearnPlant(doer)
    local plant, stage = self:GetResearchInfo()
    if plant and stage then
        doer:PushEvent("learnplantstage", {plant = plant, stage = stage})
    end
end

return PlantResearchable