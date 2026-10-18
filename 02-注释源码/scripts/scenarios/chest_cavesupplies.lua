--============================================================
-- 文件：scenarios/chest_cavesupplies.lua
-- 模块：剧本 / chest_cavesupplies
-- 职责：冒险剧本「chest_cavesupplies」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")


local function OnCreate(inst, scenariorunner)

	local items =
	{

		{
			item = "slurtleslime",
			count = math.random(5, 12),
		},
		{
			item = "slurtle_shellpieces",
			count = math.random(3, 8),
		},
		{
			item = "lightbulb",
			count = math.random(4, 9)
		},
		{
			item = "armorsnurtleshell",
			chance = 0.05,
			initfn = function(item) item.components.armor:SetCondition(math.random(item.components.armor.maxcondition * 0.33, item.components.armor.maxcondition * 0.8))end
		},
		{
			item = "slurtlehat",
			chance = 0.05,
			initfn = function(item) item.components.armor:SetCondition(math.random(item.components.armor.maxcondition * 0.33, item.components.armor.maxcondition * 0.8))end
		},
		{
			item = "batbat",
			chance = 0.05,
			initfn = function(item) item.components.finiteuses:SetUses(math.random(item.components.finiteuses.total * 0.33, item.components.finiteuses.total * 0.8)) end
		},
		{
			item = "log",
			count = math.random(3, 10)
		},
		{
			item = "twigs",
			count = math.random(3, 10)
		},
		{
			item = "flint",
			count = math.random(3, 10)
		},
		{
			item = "healingsalve",
			count = math.random(2, 6)
		},
		{
			item = "guano",
			count = math.random(3, 10)
		},
		{
			item = "rocks",
			count = math.random(3, 10)
		},
		{
			item = "goldnugget",
			count = math.random(2,6)
		},
		{
			item = "silk",
			count = math.random(3, 10)
		},
		{
			item = "bluegem",
			chance = 0.25,
		},
		{
			item = "redgem",
			chance = 0.25,
		},
		{
			item = "bedroll_furry",
		},
	}

	chestfunctions.AddChestItems(inst, items)
end

return
{
	OnCreate = OnCreate
}
