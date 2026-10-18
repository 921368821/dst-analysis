--============================================================
-- 文件：components/preserver.lua
-- 模块：组件 / preserver
-- 职责：组件「preserver」的实现。组件是挂在实体上的行为单元，通过 inst.components.preserver 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Preserver = Class(function(self, inst)
    self.inst = inst

    self.perish_rate_multiplier = 1
    self.temperature_rate_multiplier = 1
end)

function Preserver:SetPerishRateMultiplier(rate)
    self.perish_rate_multiplier = rate
end

function Preserver:GetPerishRateMultiplier(item)
    return FunctionOrValue(self.perish_rate_multiplier, self.inst, item) or 1
end

function Preserver:SetTemperatureRateMultiplier(rate)
    self.temperature_rate_multiplier = rate
end

function Preserver:GetTemperatureRateMultiplier(item)
    return FunctionOrValue(self.temperature_rate_multiplier, self.inst, item) or 1
end

function Preserver:GetDebugString()
    local perishrate, temperaturerate
    if self.perish_rate_multiplier == nil then
        perishrate = "1"
    elseif type(self.perish_rate_multiplier) == "number" then
        perishrate = tostring(self.perish_rate_multiplier)
    else
        perishrate = "FN"
    end
    if self.temperature_rate_multiplier == nil then
        temperaturerate = "1"
    elseif type(self.temperature_rate_multiplier) == "number" then
        temperaturerate = tostring(self.temperature_rate_multiplier)
    else
        temperaturerate = "FN"
    end

    return string.format("PerishRate: %s, TemperatureRate: %s", perishrate, temperaturerate)
end

return Preserver