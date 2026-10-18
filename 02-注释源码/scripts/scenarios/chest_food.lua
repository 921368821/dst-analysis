--============================================================
-- 文件：scenarios/chest_food.lua
-- 模块：剧本 / chest_food
-- 职责：冒险剧本「chest_food」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")


local function OnCreate(inst, scenariorunner)

	local items =
	{
		{
			item = "meat",
			count = 8,
		},
		{
			item = "berries",
			count = 8,
		},
		{
			item = "seeds",
			count = 10,
		},
		{
			item = "carrot",
			count = 2,
		},
		{
			item = "pumpkin",
			count = 2,
		},
		{
			item = "dragonfruit",
			count = 2,
		},
		{
			item = "eggplant",
			count = 2,
		},
		{
			item = "tallbirdegg",
			count = 1,
		},
	}
	chestfunctions.AddChestItems(inst, items)
end

return
{
	OnCreate = OnCreate
}
