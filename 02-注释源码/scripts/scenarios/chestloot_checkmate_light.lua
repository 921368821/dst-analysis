--============================================================
-- 文件：scenarios/chestloot_checkmate_light.lua
-- 模块：剧本 / chestloot_checkmate_light
-- 职责：冒险剧本「chestloot_checkmate_light」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")

local function OnCreate(inst, scenariorunner)
    local loot =
    {
        {
            item = "strawhat",
            count = 1,
        },
        {
            item = "fireflies",
            count = math.random(2, 4),
        },
        {
            item = "twigs",
            count = math.random(4, 5),
        }
    }

    chestfunctions.AddChestItems(inst, loot)
end

return
{
    OnCreate = OnCreate,
}
