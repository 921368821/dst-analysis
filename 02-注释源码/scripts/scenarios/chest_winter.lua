--============================================================
-- 文件：scenarios/chest_winter.lua
-- 模块：剧本 / chest_winter
-- 职责：冒险剧本「chest_winter」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")
local loot =
{
    {
        item = "icestaff",
        count = 1,
        chance = 0.33
    },
    {
        item = "cutgrass",
        count = 40,
        chance = 0.66
    },
    {
        item = "twigs",
        count = 40,
        chance = 0.66
    },
    {
        item = "log",
        count = 20,
        chance = 0.66
    },
    {
        item = "winterhat",
        count = 1,
        chance = 0.8
    },
    {
        item = "trunkvest_summer",
        count = 1,
        chance = 0.8
    },
    {
        item = "axe",
        count = 1
    },
}

local function triggertrap(inst, scenariorunner)
    inst.SoundEmitter:PlaySound("dontstarve/creatures/deerclops/distant")
    TheWorld:PushEvent("ms_setseason", "winter")
    TheWorld:PushEvent("ms_advanceseason")
    TheWorld:PushEvent("ms_advanceseason")
    TheWorld:PushEvent("ms_forceprecipitation", true)
end

local function OnCreate(inst, scenariorunner)
    chestfunctions.AddChestItems(inst, loot)
end

local function OnLoad(inst, scenariorunner)
    chestfunctions.InitializeChestTrap(inst, scenariorunner, triggertrap)
end

local function OnDestroy(inst)
    chestfunctions.OnDestroy(inst)
end

return
{
    OnCreate = OnCreate,
    OnLoad = OnLoad,
    OnDestroy = OnDestroy
}
