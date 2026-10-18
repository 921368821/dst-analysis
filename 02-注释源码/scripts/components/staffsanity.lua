--============================================================
-- 文件：components/staffsanity.lua
-- 模块：组件 / staffsanity
-- 职责：组件「staffsanity」的实现。组件是挂在实体上的行为单元，通过 inst.components.staffsanity 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local StaffSanity = Class(function(self, inst)
    self.inst = inst
end)

function StaffSanity:SetMultiplier(mult)
    self.multiplier = mult
end

function StaffSanity:DoCastingDelta(amount)
    if self.inst.components.sanity then
        self.inst.components.sanity:DoDelta(amount * (self.multiplier or 1))
    end
end

return StaffSanity