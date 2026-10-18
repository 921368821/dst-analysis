--============================================================
-- 文件：scenarios/chest_tools.lua
-- 模块：剧本 / chest_tools
-- 职责：冒险剧本「chest_tools」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")


local function OnCreate(inst, scenariorunner)

	local items =
	{
		{
			item = "axe",
		},
		{
			item = "spear",
		},
		{
			item = "shovel",
		},
		{
			item = "hammer",
		},
		{
			item = "pickaxe",
		},
		{
			item = "backpack_blueprint",
		},
		{
			item = "bedroll_straw_blueprint",
		},
		{
			item = "diviningrod_blueprint",
		},
		{
			item = "gunpowder_blueprint",
		},
	}
	chestfunctions.AddChestItems(inst, items)
end

return
{
	OnCreate = OnCreate
}
