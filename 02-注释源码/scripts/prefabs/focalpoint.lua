--============================================================
-- 文件：prefabs/focalpoint.lua
-- 模块：预制体 / focalpoint（建筑与容器）
-- 职责：实体「focalpoint」的预制体定义。SpawnPrefab("focalpoint") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

--deprecated, kept for backward compatibility
local function PushTempFocus(inst, target, minrange, maxrange, priority)
    inst.components.focalpoint:PushTempFocus(target, minrange, maxrange, priority)
end

local function AttachToEntity(inst, entity)
    inst.entity:SetParent(entity)
    inst.components.focalpoint:RemoveAllFocusSources()
end

local function fn()
    local inst = CreateEntity()

    --[[Non-networked entity]]
    inst.entity:AddTransform()
    inst.entity:AddSoundEmitter()
    inst.entity:Hide()
    inst:AddTag("CLASSIFIED")

    inst.persists = false

    inst:ListenForEvent("playeractivated", function(world, player) AttachToEntity(inst, player.entity) end, TheWorld)
    inst:ListenForEvent("playerdeactivated", function() AttachToEntity(inst, nil) end, TheWorld)

    inst:AddComponent("focalpoint")

    --deprecated, kept for backward compatibility
    inst.PushTempFocus = PushTempFocus

    return inst
end

return Prefab("focalpoint", fn)
