--============================================================
-- 文件：prefabs/lavaarena_center.lua
-- 模块：预制体 / lavaarena_center（建筑与容器）
-- 职责：实体「lavaarena_center」的预制体定义。SpawnPrefab("lavaarena_center") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local function lavaarena_center()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddNetwork()

    inst:AddTag("CLASSIFIED")

    inst:Hide()

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    TheWorld:PushEvent("ms_register_lavaarenacenter", inst)

    return inst
end

return Prefab("lavaarena_center", lavaarena_center)
