--============================================================
-- 文件：scenarios/chest_labyrinth_mimic.lua
-- 模块：剧本 / chest_labyrinth_mimic
-- 职责：冒险剧本「chest_labyrinth_mimic」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

chestfunctions = require("scenarios/chestfunctions")
chest_openfunctions = require("scenarios/chest_openfunctions")

local MIMIC_CHANCE = 0.33

local function OnCreate(inst, scenariorunner)

	local items =
	{
		{
			--Body Items
			item = {"armorwood", "footballhat"},
			chance = 0.2,
			initfn = function(item)
                local armor = item.components.armor
                armor:SetCondition(math.random(0.33 * armor.maxcondition, 0.80 * armor.maxcondition))

                if math.random() < MIMIC_CHANCE then
                    item:AddComponent("itemmimic")
                end
            end,
		},
		{
			--Weapon Items
			item = "spear",
			chance = 0.2,
			initfn = function(item)
                local finiteuses = item.components.finiteuses
                finiteuses:SetUses(math.random(0.33 * finiteuses.total, 0.80 * finiteuses.total))

                if math.random() < MIMIC_CHANCE then
                    item:AddComponent("itemmimic")
                end
            end,
		},
		{
			item = "nightmarefuel",
			count = math.random(1, 3),
			chance = 0.2,
		},
		{
			item = {"redgem", "bluegem", "purplegem"},
			count = math.random(1,2),
			chance = 0.15,
		},
		{
			item = "thulecite_pieces",
			count = math.random(2, 4),
			chance = 0.2,
		},
		{
			item = "thulecite",
			count = math.random(1, 3),
			chance = 0.1,
		},
		{
			item = {"yellowgem", "orangegem", "greengem"},
			count = 1,
			chance = 0.07,
		},
		{
			--Weapon Items
			item = "batbat",
			chance = 0.05,
			initfn = function(item)
                local finiteuses = item.components.finiteuses
                finiteuses:SetUses(math.random(0.3 * finiteuses.total, 0.5 * finiteuses.total))

                if math.random() < MIMIC_CHANCE then
                    item:AddComponent("itemmimic")
                end
            end,
		},
		{
			--Weapon Items
			item = {"firestaff", "icestaff", "multitool_axe_pickaxe"},
			chance = 0.05,
			initfn = function(item)
                local finiteuses = item.components.finiteuses
                if finiteuses then
                    finiteuses:SetUses(math.random(0.3 * finiteuses.total, 0.5 * finiteuses.total))
                end

                if math.random() < MIMIC_CHANCE then
                    item:AddComponent("itemmimic")
                end
            end,
		},
	}

	chestfunctions.AddChestItems(inst, items)
end

local function OnLoad(inst, scenariorunner)
	chestfunctions.InitializeChestTrap(inst, scenariorunner, GetRandomItem(chest_openfunctions))
end

local function OnDestroy(inst)
    chestfunctions.OnDestroy(inst)
end


return
{
    OnCreate = OnCreate,
    OnLoad = OnLoad,
    OnDestroy = OnDestroy
}
