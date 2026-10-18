--============================================================
-- 文件：scenarios/chest_presummer.lua
-- 模块：剧本 / chest_presummer
-- 职责：冒险剧本「chest_presummer」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")
local loot =
{
    {
        item = "log",
        count = 7
    },
    {
        item = "winterhat",
        count = 1
    },
    {
        item = "flint",
        count = 3
    },
}

local function OnCreate(inst, scenariorunner)
    chestfunctions.AddChestItems(inst, loot)
end

return
{
    OnCreate = OnCreate,
}
