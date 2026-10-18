--============================================================
-- 文件：components/fuelmaster.lua
-- 模块：组件 / fuelmaster
-- 职责：组件「fuelmaster」的实现。组件是挂在实体上的行为单元，通过 inst.components.fuelmaster 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local FuelMaster = Class(function(self, inst)
    self.inst = inst
    self.bonusmult = 1
    self.bonusfn = nil
end)

function FuelMaster:SetBonusMult(mult)
    self.bonusmult = mult
end

function FuelMaster:SetBonusFn(fn)
    self.bonusfn = fn
end

function FuelMaster:GetBonusMult(item, target)
    return (self.bonusfn ~= nil and self.bonusfn(self.inst, item, target) or 1) * self.bonusmult
end

return FuelMaster
