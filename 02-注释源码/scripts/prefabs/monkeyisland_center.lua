--============================================================
-- 文件：prefabs/monkeyisland_center.lua
-- 模块：预制体 / monkeyisland_center（建筑与容器）
-- 职责：实体「monkeyisland_center」的预制体定义。SpawnPrefab("monkeyisland_center") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function fn()
    -- this is just used during world gen and should not stick around.
    local inst = CreateEntity()
    inst.entity:AddTransform()

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    inst:DoTaskInTime(0, inst.Remove)
    return inst
end

--------------------------------------------------------------------------------

local function on_safetyarea_loaded(inst, data, newents)
    if data ~= nil then
        inst.width = data.width or 0
        inst.height = data.height or 0
    end
end

local function safetyareafn()
    local inst = CreateEntity()
    inst.entity:AddTransform()

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.persists = false

    inst.width = 0
    inst.height = 0

    inst.OnLoad = on_safetyarea_loaded

    inst:DoTaskInTime(0, inst.Remove)
    return inst
end

return Prefab("monkeyisland_center", fn),
       Prefab("monkeyisland_direction", fn),
       Prefab("monkeyisland_dockgen_safeareacenter", safetyareafn)
