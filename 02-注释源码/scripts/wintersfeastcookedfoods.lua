--============================================================
-- 文件：wintersfeastcookedfoods.lua
-- 模块： / wintersfeastcookedfoods
-- 职责：模块中的「wintersfeastcookedfoods」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local foods =
{
	berrysauce =
	{
		cooktime = 0.8,
		-- Overrides
		--uses = 180,
		--wet_prefix = nil,
		--floater = {"med", nil, 0.65},
	},
	bibingka =
	{
		cooktime = 1,
	},
	cabbagerolls =
	{
		cooktime = 0.8,
	},
	festivefish =
	{
		cooktime = 1,
	},
	gravy =
	{
		cooktime = 1,
	},
	latkes =
	{
		cooktime = 0.8,
	},
	lutefisk =
	{
		cooktime = 1.4,
	},
	mulleddrink =
	{
		cooktime = 1,
	},
	panettone =
	{
		cooktime = 1,
	},
	pavlova =
	{
		cooktime = 1,
	},
	pickledherring =
	{
		cooktime = 1.2,
	},
	polishcookie =
	{
		cooktime = 1,
	},
	pumpkinpie =
	{
		cooktime = 1,
	},
	roastturkey =
	{
		cooktime = 1.2,
	},
	stuffing =
	{
		cooktime = 1,
	},
	sweetpotato =
	{
		cooktime = 1,
	},
	tamales =
	{
		cooktime = 1,
	},
	tourtiere =
	{
		cooktime = 1,
	},
}

for k, v in pairs(foods) do
    v.name = k
end

return { foods = foods }
