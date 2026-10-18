--============================================================
-- 文件：prefabs/antchovies_group.lua
-- 模块：预制体 / antchovies_group（建筑与容器）
-- 职责：实体「antchovies_group」的预制体定义。SpawnPrefab("antchovies_group") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/water_antchovies.zip"),
}

local prefabs =
{
    "antchovies",
}

local function fn()

   local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst:AddTag("ignorewalkableplatforms")

    inst.AnimState:SetBank("antchovies")
    inst.AnimState:SetBuild("water_antchovies")
    inst.AnimState:SetLayer(LAYER_BACKGROUND)
    inst.AnimState:SetSortOrder(1)
    inst.AnimState:SetMultColour(0.4,0.4,0.4,1)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    --inst:SetStateGraph("SGantchovies")
    inst:AddComponent("fishschool")
    inst.components.fishschool:SetNettedPrefab("antchovies")
    inst.components.fishschool:StartReplenish(10)

    return inst
end

return Prefab("antchovies_group", fn, assets, prefabs)
