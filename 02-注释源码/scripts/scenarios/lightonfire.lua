--============================================================
-- 文件：scenarios/lightonfire.lua
-- 模块：剧本 / lightonfire
-- 职责：冒险剧本「lightonfire」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function OnCreate(inst, scenariorunner)
	if inst.components.burnable then
		inst.components.burnable:Ignite()
	end
end

--local function OnLoad(inst, scenariorunner)
--end

return {
	    OnCreate=OnCreate,
        --OnLoad=OnLoad
	   }

