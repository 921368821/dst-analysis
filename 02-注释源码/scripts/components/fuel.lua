--============================================================
-- 文件：components/fuel.lua
-- 模块：组件 / fuel
-- 职责：组件「fuel」的实现。组件是挂在实体上的行为单元，通过 inst.components.fuel 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function onfueltype(self, fueltype, old_fueltype)
    if old_fueltype ~= nil then
        self.inst:RemoveTag(old_fueltype.."_fuel")
    end
    if fueltype ~= nil then
        self.inst:AddTag(fueltype.."_fuel")
    end
end

local Fuel = Class(function(self, inst)
    self.inst = inst
    self.fuelvalue = 1
    self.fueltype = FUELTYPE.BURNABLE
    self.ontaken = nil
end,
nil,
{
    fueltype = onfueltype,
})

function Fuel:OnRemoveFromEntity()
    if self.fueltype ~= nil then
        self.inst:RemoveTag(self.fueltype.."_fuel")
    end
end

function Fuel:SetOnTakenFn(fn)
    self.ontaken = fn
end

function Fuel:Taken(target)
    self.inst:PushEvent("fueltaken", {taker = target})
    if self.ontaken then
        self.ontaken(self.inst, target)
    end
end

return Fuel