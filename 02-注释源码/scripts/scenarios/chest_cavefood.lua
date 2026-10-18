--============================================================
-- 文件：scenarios/chest_cavefood.lua
-- 模块：剧本 / chest_cavefood
-- 职责：冒险剧本「chest_cavefood」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")


local function OnCreate(inst, scenariorunner)

	local items =
	{

		{
			item = "berries",
			count = math.random(5, 9),
			initfn = function(item) item.components.perishable:SetPercent(math.random()) end
		},
		{
			item = "carrot",
			count = math.random(3, 6),
			initfn = function(item) item.components.perishable:SetPercent(math.random())end

		},
		{
			item = "lightbulb",
			count = math.random(4, 9),
			initfn = function(item) item.components.perishable:SetPercent(math.random())end

		},
		{
			item = "batwing",
			initfn = function(item) item.components.perishable:SetPercent(math.random())end

		},
		{
			item = "meat",
			count = math.random(2, 4),
			initfn = function(item) item.components.perishable:SetPercent(math.random())end

		},
		{
			item = "smallmeat",
			count = math.random(2, 5),
			initfn = function(item) item.components.perishable:SetPercent(math.random())end
		},
		{
			item = "monstermeat",
			count = math.random(2, 5),
			initfn = function(item) item.components.perishable:SetPercent(math.random())end

		},

	}

	chestfunctions.AddChestItems(inst, items, 4)
end

return
{
	OnCreate = OnCreate
}
