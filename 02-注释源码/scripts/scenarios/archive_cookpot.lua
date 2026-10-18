--============================================================
-- 文件：scenarios/archive_cookpot.lua
-- 模块：剧本 / archive_cookpot
-- 职责：冒险剧本「archive_cookpot」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")
chest_openfunctions = require("scenarios/chest_openfunctions")

local function OnCreate(inst, scenariorunner)

	local items =
	{
		{
			item = "refined_dust",
			chance = 1,
		},
	}

	chestfunctions.AddChestItems(inst, items)
end

return
{
    OnCreate = OnCreate,

}
