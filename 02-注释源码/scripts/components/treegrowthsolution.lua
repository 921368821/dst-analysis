--============================================================
-- 文件：components/treegrowthsolution.lua
-- 模块：组件 / treegrowthsolution
-- 职责：组件「treegrowthsolution」的实现。组件是挂在实体上的行为单元，通过 inst.components.treegrowthsolution 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local TreeGrowthSolution = Class(function(self, inst)
    self.inst = inst
    -- self.fx_prefab = nil
end)

function TreeGrowthSolution:GrowTarget(target)
    if target:HasTag("no_force_grow")
        or target:HasTag("stump")
        or target:HasTag("fire")
        or target:HasTag("burnt") then
        
        return false
    end

    if self.fx_prefab ~= nil then
        SpawnPrefab(self.fx_prefab).Transform:SetPosition(target:GetPosition():Get())
    end

    if target.override_treegrowthsolution_fn ~= nil then
        target:override_treegrowthsolution_fn(self.inst)
    elseif target.components.growable ~= nil then
        target.components.growable:DoGrowth()
    end

    if self.inst.components.stackable ~= nil and self.inst.components.stackable:IsStack() then
        self.inst.components.stackable:SetStackSize(self.inst.components.stackable:StackSize() - 1)
    else
        self.inst:Remove()
    end

    return true
end

return TreeGrowthSolution