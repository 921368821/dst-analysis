--============================================================
-- 文件：components/playermetrics.lua
-- 模块：组件 / playermetrics
-- 职责：组件「playermetrics」的实现。组件是挂在实体上的行为单元，通过 inst.components.playermetrics 访问，负责本实体的某一类状态与逻辑。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local Stats = require("stats")

local function PushEvent(id, player, values)
    Stats.PushMetricsEvent(id, player, values)
end

local function OnUnlockRecipe(inst, data)
    if data ~= nil and data.recipe ~= nil then
        PushEvent("character.prototyped", inst, { prefab = data.recipe })
    end
end

local PlayerMetrics = Class(function(self, inst)
    self.inst = inst

    inst:ListenForEvent("unlockrecipe", OnUnlockRecipe)
end)

function PlayerMetrics:OnRemoveFromEntity()
    self.inst:RemoveEventCallback("unlockrecipe", OnUnlockRecipe);
end

return PlayerMetrics
