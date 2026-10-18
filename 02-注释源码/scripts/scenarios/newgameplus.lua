--============================================================
-- 文件：scenarios/newgameplus.lua
-- 模块：剧本 / newgameplus
-- 职责：冒险剧本「newgameplus」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnCreate(inst, scenariorunner)

	--make all of the spider dens scary!
	for k,v in pairs(Ents) do
		if v:HasTag("spiderden") and v.components.growable then
			v.components.growable:SetStage(math.random() < .25 and 3 or 2)
		end
	end

end

return
{
	OnCreate = OnCreate
}
