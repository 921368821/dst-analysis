--============================================================
-- 文件：components/waterproofer.lua
-- 模块：组件 / waterproofer
-- 职责：组件「waterproofer」的实现。组件是挂在实体上的行为单元，通过 inst.components.waterproofer 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local WaterProofer = Class(function(self, inst)
    self.inst = inst

    self.effectiveness = 1

    --V2C: Recommended to explicitly add tag to prefab pristine state
    inst:AddTag("waterproofer")

    if inst.components.inventoryitem ~= nil then
        inst.components.inventoryitem:EnableMoisture(false)
    end
end)

function WaterProofer:OnRemoveFromEntity()
    self.inst:RemoveTag("waterproofer")

    if self.inst.components.inventoryitem ~= nil then
        self.inst.components.inventoryitem:EnableMoisture(true)
    end
end

function WaterProofer:GetEffectiveness()
    return self.effectiveness
end

function WaterProofer:SetEffectiveness(val)
    self.effectiveness = val
end

return WaterProofer
