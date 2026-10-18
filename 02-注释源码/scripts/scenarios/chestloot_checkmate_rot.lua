--============================================================
-- 文件：scenarios/chestloot_checkmate_rot.lua
-- 模块：剧本 / chestloot_checkmate_rot
-- 职责：冒险剧本「chestloot_checkmate_rot」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")

local function OnCreate(inst, scenariorunner)
    local loot =
    {
        {
            item = "spoiled_food",
            count = math.random(80, 300),
        },
    }

    chestfunctions.AddChestItems(inst, loot)
end

return
{
    OnCreate = OnCreate,
}
