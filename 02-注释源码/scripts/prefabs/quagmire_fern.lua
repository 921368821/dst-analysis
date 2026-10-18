--============================================================
-- 文件：prefabs/quagmire_fern.lua
-- 模块：预制体 / quagmire_fern（建筑与容器）
-- 职责：实体「quagmire_fern」的预制体定义。SpawnPrefab("quagmire_fern") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cave_ferns.zip"),
}

local prefabs =
{
    "foliage",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("ferns")
    inst.AnimState:SetBuild("cave_ferns")
    inst.AnimState:SetRayTestOnBB(true)

    inst:SetPhysicsRadiusOverride(0.4)

    -- for stats tracking
    inst:AddTag("quagmire_wildplant")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_fern").master_postinit(inst)

    return inst
end

return Prefab("quagmire_fern", fn, assets, prefabs)
