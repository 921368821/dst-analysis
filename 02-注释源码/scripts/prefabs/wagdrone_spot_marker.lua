--============================================================
-- 文件：prefabs/wagdrone_spot_marker.lua
-- 模块：预制体 / wagdrone_spot_marker（建筑与容器）
-- 职责：实体「wagdrone_spot_marker」的预制体定义。SpawnPrefab("wagdrone_spot_marker") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    --[[Non-networked entity]]

    inst:AddTag("CLASSIFIED")

    if not TheWorld.ismastersim then
        inst:DoTaskInTime(0, inst.Remove) -- Not meant for clients.

        return inst
    end

    return inst
end

return Prefab("wagdrone_spot_marker", fn)