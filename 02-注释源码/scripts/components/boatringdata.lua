--============================================================
-- 文件：components/boatringdata.lua
-- 模块：组件 / boatringdata
-- 职责：组件「boatringdata」的实现。组件是挂在实体上的行为单元，通过 inst.components.boatringdata 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local BoatRingData = Class(function(self, inst)
    self.inst = inst

    self.radius = 4
    self.segments = 8

    self._isrotating = net_bool(inst.GUID, "boatringdata._isrotating")
    self._isrotating:set(false)
end)

--------------------------------------------------------------------------
--Client & Server

function BoatRingData:GetRadius()
    return self.radius
end

function BoatRingData:SetRadius(radius)
    self.radius = radius
end

function BoatRingData:GetNumSegments()
    return self.segments
end

function BoatRingData:SetNumSegments(segments)
    self.segments = segments
end

function BoatRingData:IsRotating()
    return self._isrotating:value()
end

--------------------------------------------------------------------------
--Master Sim

function BoatRingData:SetIsRotating(isrotating)
    assert(TheWorld.ismastersim)
    self._isrotating:set(isrotating)
end

return BoatRingData
