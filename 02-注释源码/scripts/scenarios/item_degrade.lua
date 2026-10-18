--============================================================
-- 文件：scenarios/item_degrade.lua
-- 模块：剧本 / item_degrade
-- 职责：冒险剧本「item_degrade」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnCreate(inst, scenariorunner)
	if inst.components.fueled then
		local maxfuel = inst.components.fueled.maxfuel
		inst.components.fueled:InitializeFuelLevel(math.random(maxfuel * 0.4, maxfuel * 0.6))
	end
	--Anything that needs to happen only once. IE: Putting loot in a chest.
end


local function OnLoad(inst, scenariorunner)
--Anything that needs to happen every time the game loads.
end


local function OnDestroy(inst)
--Stop any event listeners here.
end

return
{
	OnCreate = OnCreate,
	OnLoad = OnLoad,
	OnDestroy = OnDestroy
}