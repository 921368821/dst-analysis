--============================================================
-- 文件：scenarios/chest_cave.lua
-- 模块：剧本 / chest_cave
-- 职责：冒险剧本「chest_cave」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")


local function OnCreate(inst, scenariorunner)

	local items =
	{

		{
			item = "armorwood",
		},
		{
			item = "spear",
		},
		{
			item = "minerhat",
			count = 2
		},
		{
			item = "log",
			count = 20,
		},
		{
			item = "cutgrass",
			count = 40,
		},
		{
			item = "twigs",
			count = 40
		},
		{
			item = "flint",
			count = 40,
		},
		{
			item = "healingsalve",
			count = 10,
		},
	}

	chestfunctions.AddChestItems(inst, items)
end

return
{
	OnCreate = OnCreate
}
