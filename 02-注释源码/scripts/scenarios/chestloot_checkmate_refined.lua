--============================================================
-- 文件：scenarios/chestloot_checkmate_refined.lua
-- 模块：剧本 / chestloot_checkmate_refined
-- 职责：冒险剧本「chestloot_checkmate_refined」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")

local function OnCreate(inst, scenariorunner)
    local loot =
    {
        {
            item = "boards",
            count = math.random(5, 7),
        },
        {
            item = "cutstone",
            count = math.random(2, 4),
        },
        {
            item = "rope",
            count = math.random(4, 5),
        },
        {
            item = "goldnugget",
            count = math.random(4, 5),
        },
    }

    chestfunctions.AddChestItems(inst, loot)
end

return
{
    OnCreate = OnCreate,
}
