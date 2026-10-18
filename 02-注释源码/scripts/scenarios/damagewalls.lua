--============================================================
-- 文件：scenarios/damagewalls.lua
-- 模块：剧本 / damagewalls
-- 职责：冒险剧本「damagewalls」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function FindWalls(inst)
    local pt = Vector3(inst.Transform:GetWorldPosition())
    local ents = TheSim:FindEntities(pt.x, pt.y, pt.z, 1000)
    local walls = {}
    for k,v in pairs(ents) do
        if v and v:HasTag("wall") then
            walls[v] = v
        end
    end
    return walls
end

local function DamageWalls(walls)
	 for k,v in pairs(walls) do
	 	if v and v.components.health then
	 		v.components.health:DoDelta(math.random(-v.components.health.maxhealth * .75, 0), 0, "dev")
	 	end
	 end
end

local function OnCreate(inst, scenariorunner)
	local walls = FindWalls(inst)
	DamageWalls(walls)
end

return
{
	OnCreate = OnCreate
}