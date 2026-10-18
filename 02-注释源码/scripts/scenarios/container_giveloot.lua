--============================================================
-- 文件：scenarios/container_giveloot.lua
-- 模块：剧本 / container_giveloot
-- 职责：冒险剧本「container_giveloot」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")

local function OnCreate(inst, scenariorunner)
    local loot =
    {
        {
            item = "cutgrass",
            count = math.random(20, 25),
        },
        {
            item = "log",
            count = math.random(10, 14),
        },
        {
            item = "rocks",
            count = math.random(9, 13),
        }
    }

    chestfunctions.AddChestItems(inst, loot)
end

return
{
    OnCreate = OnCreate,
}
