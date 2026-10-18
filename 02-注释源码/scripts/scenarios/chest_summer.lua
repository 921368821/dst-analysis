--============================================================
-- 文件：scenarios/chest_summer.lua
-- 模块：剧本 / chest_summer
-- 职责：冒险剧本「chest_summer」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")
local loot =
{
    {
        item = "firestaff",
        count = 1,
        chance = 0.33
    },
    {
        item = "cutgrass",
        count = 40,
        chance = 0.66
    },
    {
        item = "nitre",
        count = 40,
        chance = 0.66
    },
    {
        item = "rocks",
        count = 20,
        chance = 0.66
    },
    {
        item = "umbrella",
        count = 1,
        chance = 0.66
    },
    {
        item = "reflectivevest",
        count = 1,
        chance = 0.8
    },
    {
        item = "pickaxe",
        count = 1
    },
}

local function triggertrap(inst, scenariorunner)
	inst.SoundEmitter:PlaySound("dontstarve_DLC001/creatures/dragonfly/distant")
    TheWorld:PushEvent("ms_setseason", "summer")
    TheWorld:PushEvent("ms_advanceseason")
    TheWorld:PushEvent("ms_advanceseason")
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
