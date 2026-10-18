--============================================================
-- 文件：prefabs/pillow_common.lua
-- 模块：预制体 / pillow_common（建筑与容器）
-- 职责：实体「pillow_common」的预制体定义。SpawnPrefab("pillow_common") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local fn_table = {}

local NOPUSH_TAGS = {"epic", "nopush"}
fn_table.DoKnockback = function(target, source, knockback_data)
    for _, tag in ipairs(NOPUSH_TAGS) do
        if target:HasTag(tag) then
            return false
        end
    end

    local target_body_item = (target.components.inventory and target.components.inventory:GetEquippedItem(EQUIPSLOTS.BODY))
        or nil
    local knockback_defense_amount = (target_body_item and target_body_item._defense_amount) or 0

    local knockback_amount = math.max(0.025, ((knockback_data and knockback_data.amount) or 0.5))
    local knockback_strengthmult = math.max(0.5, ((knockback_data and knockback_data.strengthmult) or 1) - knockback_defense_amount)

    target:PushEvent("knockback", {
        knocker = source,
        radius = source:GetPhysicsRadius(0.5) + knockback_amount,
        strengthmult = knockback_strengthmult,
        forcelanded = (target_body_item ~= nil and target_body_item:HasTag("bodypillow")),
    })

    return true
end

return fn_table