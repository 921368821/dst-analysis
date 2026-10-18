--============================================================
-- 文件：scenarios/chest_crafting.lua
-- 模块：剧本 / chest_crafting
-- 职责：冒险剧本「chest_crafting」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")


local function OnCreate(inst, scenariorunner)

	local items =
	{
		{
			item = "cutgrass",
			count = 30,
		},
		{
			item = "log",
			count = 20,
		},
		{
			item = "flint",
			count = 10,
		},
		{
			item = "twigs",
			count = 30,
		},
		{
			item = "rocks",
			count = 20,
		},
		{
			item = "goldnugget",
			count = 10,
		},
		{
			item = "gunpowder",
			count = 2,
		},
		{
			item = "silk",
			count = 6,
		},

	}
	chestfunctions.AddChestItems(inst, items)
end

return
{
	OnCreate = OnCreate
}
