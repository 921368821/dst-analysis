--============================================================
-- 文件：scenarios/chest_totaldarkness_start.lua
-- 模块：剧本 / chest_totaldarkness_start
-- 职责：冒险剧本「chest_totaldarkness_start」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")


local function OnCreate(inst, scenariorunner)

	local items =
	{
		{
			item = "cutgrass",
			count = 6,
		},
		{
			item = "flint",
			count = 3,
		},
		{
			item = "twigs",
			count = 6,
		},
		{
			item = "log",
			count = 3,
		},
		{
			item = "goldnugget",
			count = 1,
		},
		{
			item = "axe",
		},

	}
	chestfunctions.AddChestItems(inst, items)
end

return
{
	OnCreate = OnCreate
}
