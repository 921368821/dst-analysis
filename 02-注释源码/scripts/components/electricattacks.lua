--============================================================
-- 文件：components/electricattacks.lua
-- 模块：组件 / electricattacks
-- 职责：组件「electricattacks」的实现。组件是挂在实体上的行为单元，通过 inst.components.electricattacks 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local SourceModifierList = require("util/sourcemodifierlist")

local ElectricAttacks = Class(function(self, inst)
    self.inst = inst
    self._sources = SourceModifierList(inst, false, SourceModifierList.boolean)
end)

function ElectricAttacks:AddSource(source)
    self._sources:SetModifier(source, true)
end

function ElectricAttacks:RemoveSource(source)
    self._sources:RemoveModifier(source)
    if not self._sources:Get() then
        self.inst:RemoveComponent("electricattacks")
    end
end

return ElectricAttacks
