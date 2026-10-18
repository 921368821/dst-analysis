--============================================================
-- 文件：scenarios/chest_minotaur.lua
-- 模块：剧本 / chest_minotaur
-- 职责：冒险剧本「chest_minotaur」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")


local function OnCreate(inst, scenariorunner)

	local items =
	{

		{
			--Body Items
			item = "armorruins",
			chance = 0.33,
			initfn = function(item) item.components.armor:SetCondition(math.random(item.components.armor.maxcondition * 0.7, item.components.armor.maxcondition))end
		},
		{
			--Body Items
			item = "ruinshat",
			chance = 0.33,
			initfn = function(item) item.components.armor:SetCondition(math.random(item.components.armor.maxcondition * 0.7, item.components.armor.maxcondition))end
		},
		{
			--Weapon Items
			item = {"ruins_bat", "orangestaff", "yellowstaff"},
			chance = 0.25,
			initfn = function(item) item.components.finiteuses:SetUses(math.random(item.components.finiteuses.total * 0.7, item.components.finiteuses.total)) end
		},
		{
			--Weapon Items
			item = {"firestaff", "icestaff", "telestaff", "multitool_axe_pickaxe"},
			chance = 0.5,
		},
		{
			item = "thulecite",
			count = math.random(7, 14),
			chance = 0.75,
		},
		{
			item = "thulecite_pieces",
			count = math.random(7, 14),
			chance = 0.5,
		},
		{
			item = "nightmarefuel",
			count = math.random(5, 10),
			chance = 0.75,
		},
		{
			item = {"redgem", "bluegem", "purplegem"},
			count = math.random(3, 6),
			chance = 0.66,
		},
		{
			item = {"yellowgem", "orangegem", "greengem"},
			count = math.random(3, 6),
			chance = 0.45,
		},
		{
			item = "gears",
			count = math.random(3, 6),
			chance = 0.33,
		},
	}

	chestfunctions.AddChestItems(inst, {{item = "atrium_key"}})
	chestfunctions.AddChestItems(inst, items)
end

return
{
	OnCreate = OnCreate
}
