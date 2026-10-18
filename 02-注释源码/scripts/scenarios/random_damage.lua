--============================================================
-- 文件：scenarios/random_damage.lua
-- 模块：剧本 / random_damage
-- 职责：冒险剧本「random_damage」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================


local function OnCreate(inst, scenariorunner)
	if inst then
        if inst.components.health then
            inst.components.health:DoDelta(math.random(-inst.components.health.maxhealth * .75, 0), 0, "dev")
        elseif inst.components.finiteuses then
            inst.components.finiteuses.current = math.max(math.random(inst.components.finiteuses.total * .1, inst.components.finiteuses.total * .75), 1) -- At least one use!
        elseif inst.components.condition then
            inst.components.condition.current = math.random(inst.components.condition.maxcondition * .1, inst.components.condition.maxcondition * .75)
        elseif inst.components.armor then
            inst.components.armor.condition = math.random(inst.components.armor.maxcondition * .1, inst.components.armor.maxcondition * .75)
       elseif inst.components.fueled then
            inst.components.fueled.currentfuel = math.random(inst.components.fueled.maxfuel * .1, inst.components.fueled.maxfuel * .75)
        end
    end
end

return
{
	OnCreate = OnCreate
}