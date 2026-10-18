--============================================================
-- 文件：prefabs/spawnpoint_multiplayer.lua
-- 模块：预制体 / spawnpoint_multiplayer（建筑与容器）
-- 职责：实体「spawnpoint_multiplayer」的预制体定义。SpawnPrefab("spawnpoint_multiplayer") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function common_fn(ismaster)
    local inst = CreateEntity()

    inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst:AddTag("CLASSIFIED")

    --NOTE: this is not mastersim, it means the master
    --      spawnpoint to be used in fixed spawn mode.
    inst.master = ismaster or nil

    TheWorld:PushEvent("ms_registerspawnpoint", inst)

    return inst
end

local function multiplayer_fn()
    return common_fn(false)
end

local function master_fn()
    return common_fn(true)
end

return Prefab("spawnpoint_multiplayer", multiplayer_fn),
    Prefab("spawnpoint_master", master_fn)