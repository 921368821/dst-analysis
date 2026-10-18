--============================================================
-- 文件：components/fueler.lua
-- 模块：组件 / fueler
-- 职责：组件「fueler」的实现。组件是挂在实体上的行为单元，通过 inst.components.fueler 访问，负责本实体的某一类状态与逻辑。
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

local Fueler = Class(function(self, inst)
    self.inst = inst
    self.fuelvalue = 1
    self.fueltype = FUELTYPE.BURNABLE
    self.ontaken = nil
end,
nil,
{
    fueltype = onfueltype,
})

function Fueler:OnRemoveFromEntity()
    if self.fueltype ~= nil then
        self.inst:RemoveTag(self.fueltype.."_fuel")
    end
end

function Fueler:SetOnTakenFn(fn)
    self.ontaken = fn
end

function Fueler:Taken(target)
    self.inst:PushEvent("fueltaken", {taker = target})
    if self.ontaken then
        self.ontaken(self.inst, target)
    end
end

return Fueler