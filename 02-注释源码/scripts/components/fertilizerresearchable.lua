--============================================================
-- 文件：components/fertilizerresearchable.lua
-- 模块：组件 / fertilizerresearchable
-- 职责：组件「fertilizerresearchable」的实现。组件是挂在实体上的行为单元，通过 inst.components.fertilizerresearchable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local FertilizerResearchable = Class(function(self, inst)
    self.inst = inst

    self.inst:AddTag("fertilizerresearchable")
end)

function FertilizerResearchable:SetResearchFn(fn)
    self.reasearchinfofn = fn
end

function FertilizerResearchable:GetResearchInfo()
    if self.reasearchinfofn then
        return self.reasearchinfofn(self.inst)
    end
end

function FertilizerResearchable:LearnFertilizer(doer)
    local fertilizer = self:GetResearchInfo()
    if fertilizer then
        doer:PushEvent("learnfertilizer", {fertilizer = fertilizer})
    end
end

return FertilizerResearchable