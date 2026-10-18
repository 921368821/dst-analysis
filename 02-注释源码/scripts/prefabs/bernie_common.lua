--============================================================
-- 文件：prefabs/bernie_common.lua
-- 模块：预制体 / bernie_common（建筑与容器）
-- 职责：实体「bernie_common」的预制体定义。SpawnPrefab("bernie_common") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local fn = {}
fn.isleadercrazy = function(inst,leader)

    if ( leader.components.sanity:IsCrazy() or
        (leader.components.sanity:GetPercent() < TUNING.SKILLS.WILLOW_BERNIESANITY_1 and leader.components.skilltreeupdater:IsActivated("willow_berniesanity_1") ) or 
        (leader.components.sanity:GetPercent() < TUNING.SKILLS.WILLOW_BERNIESANITY_2 and leader.components.skilltreeupdater:IsActivated("willow_berniesanity_2") ) ) then
        return true
    end

end

local HOTHEAD_ACTIVTE_DIST = 20
local HOTHEAD_MUST_TAGS = { "_combat", "hostile" }
local HOTHEAD_CANT_TAGS = { "INLIMBO", "player", "companion" }
local HOTHEAD_ONEOF_TAGS = { "brightmare", "lunar_aligned", "shadow_aligned", "shadow" }
fn.hotheaded = function(inst,player)
    local x, y, z = inst.Transform:GetWorldPosition()
    if player.components.skilltreeupdater:IsActivated("willow_bernieai") then
        local targets = TheSim:FindEntities(x, y, z, HOTHEAD_ACTIVTE_DIST, HOTHEAD_MUST_TAGS, HOTHEAD_CANT_TAGS, HOTHEAD_ONEOF_TAGS)        
        if #targets > 0 then
            return true
        end
    end
end

return fn