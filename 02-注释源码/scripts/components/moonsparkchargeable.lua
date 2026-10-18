--============================================================
-- 文件：components/moonsparkchargeable.lua
-- 模块：组件 / moonsparkchargeable
-- 职责：组件「moonsparkchargeable」的实现。组件是挂在实体上的行为单元，通过 inst.components.moonsparkchargeable 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local MoonSparkChargeable = Class(function(self, inst)
    self.inst = inst

    self.fueled_percent = TUNING.MOONSTORM_SPARKCHARGE_DEFAULT

    --Recommended to explicitly add tag to prefab pristine state
    self.inst:AddTag("moonsparkchargeable")
end)

function MoonSparkChargeable:OnRemoveFromEntity()
    self.inst:RemoveTag("moonsparkchargeable")
end

function MoonSparkChargeable:SetFueledPercent(amount)
    self.fueled_percent = amount
end

function MoonSparkChargeable:DoSpark(doer)
    if self.fueled_percent ~= 0 and self.inst.components.fueled then
        local newpercent = math.clamp(self.inst.components.fueled:GetPercent() + self.fueled_percent, 0, 1)
        self.inst.components.fueled:SetPercent(newpercent)
    end
end

return MoonSparkChargeable
