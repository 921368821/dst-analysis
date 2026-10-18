--============================================================
-- 文件：components/boatrace_proximitybeacon.lua
-- 模块：组件 / boatrace_proximitybeacon
-- 职责：组件「boatrace_proximitybeacon」的实现。组件是挂在实体上的行为单元，通过 inst.components.boatrace_proximitybeacon 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

-- An object with this component can be configured alongside a boatrace_proximitychecker
-- to identify when the beacon is in range of the checker.
local BoatRace_ProximityBeacon = Class(function(self, inst)
    self.inst = inst
    --self.boatrace_started_fn = nil
    --self.boatrace_finished_fn = nil

    self.inst:AddTag("boatrace_proximitybeacon")

    self._boatrace_started_callback = function(i, data)
        if self.boatrace_started_fn then
            self.boatrace_started_fn(i, data)
        end
    end
    self.inst:ListenForEvent("boatrace_start", self._boatrace_started_callback)

    self._boatrace_finished_callback = function(i, data)
        if self.boatrace_finished_fn then
            self.boatrace_finished_fn(i, data.start, data.winner)
        end
    end
    self.inst:ListenForEvent("boatrace_finish", self._boatrace_finished_callback)
end)

function BoatRace_ProximityBeacon:OnRemoveFromEntity()
    self.inst:RemoveTag("boatrace_proximitybeacon")

    self.inst:RemoveEventCallback("boatrace_start", self._boatrace_started_callback)
    self.inst:RemoveEventCallback("boatrace_finish", self._boatrace_finished_callback)
end

function BoatRace_ProximityBeacon:SetBoatraceStartedFn(fn)
    self.boatrace_started_fn = fn
end

function BoatRace_ProximityBeacon:SetBoatraceFinishedFn(fn)
    self.boatrace_finished_fn = fn
end

return BoatRace_ProximityBeacon