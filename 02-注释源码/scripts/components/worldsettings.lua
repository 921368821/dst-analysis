--============================================================
-- 文件：components/worldsettings.lua
-- 模块：组件 / worldsettings
-- 职责：组件「worldsettings」的实现。组件是挂在实体上的行为单元，通过 inst.components.worldsettings 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnSetWorldSetting(world, data)
    local worldsettings = world.components.worldsettings
    if worldsettings then
        worldsettings:SetSetting(data.setting, data.value)
    end
end

local WorldSettings = Class(function(self, inst)
    self.inst = inst

    self.settings = {}

    inst:ListenForEvent("ms_setworldsetting", OnSetWorldSetting)
end)

function WorldSettings:GetSetting(setting)
    return self.settings[setting]
end

function WorldSettings:SetSetting(setting, value)
    self.settings[setting] = value
end

return WorldSettings