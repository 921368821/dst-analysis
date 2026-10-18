--============================================================
-- 文件：components/carnivalhostsummon.lua
-- 模块：组件 / carnivalhostsummon
-- 职责：组件「carnivalhostsummon」的实现。组件是挂在实体上的行为单元，通过 inst.components.carnivalhostsummon 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local CarnivalHostSummon = Class(function(self, inst)
    self.inst = inst

    self.inst:AddTag("carnivalhostsummon")
end)

function CarnivalHostSummon:SetCanSummon(cansummon)
    if cansummon then
        self.inst:AddTag("carnivalhostsummon")
    else
        self.inst:RemoveTag("carnivalhostsummon")
    end
end

return CarnivalHostSummon
