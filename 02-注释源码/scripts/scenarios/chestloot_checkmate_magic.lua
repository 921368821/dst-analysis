--============================================================
-- 文件：scenarios/chestloot_checkmate_magic.lua
-- 模块：剧本 / chestloot_checkmate_magic
-- 职责：冒险剧本「chestloot_checkmate_magic」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")

local function OnCreate(inst, scenariorunner)
    local loot =
    {
        {
            item = "livinglog",
            count = math.random(5, 10),
        },
        {
            item = "nightmarefuel",
            count = math.random(5, 10),
        },
        {
            item = "redgem",
            count = math.random(5, 10),
        },
        {
            item = "bluegem",
            count = math.random(5, 10),
        },
        {
            item = "purplegem",
            count = math.random(5, 10),
        },
    }

    chestfunctions.AddChestItems(inst, loot)
end

return
{
    OnCreate = OnCreate,
}
