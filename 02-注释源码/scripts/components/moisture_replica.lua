--============================================================
-- 文件：components/moisture_replica.lua
-- 模块：组件 / moisture_replica
-- 职责：组件「moisture_replica」的实现。组件是挂在实体上的行为单元，通过 inst.components.moisture_replica 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Moisture = Class(function(self, inst)
    self.inst = inst

    self._iswet = net_bool(inst.GUID, "moisture._iswet")
end)

function Moisture:SetIsWet(iswet)
    self._iswet:set(iswet)
end

function Moisture:IsWet()
    return self._iswet:value()
end

return Moisture