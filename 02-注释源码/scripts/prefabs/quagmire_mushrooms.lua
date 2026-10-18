--============================================================
-- 文件：prefabs/quagmire_mushrooms.lua
-- 模块：预制体 / quagmire_mushrooms（建筑与容器）
-- 职责：实体「quagmire_mushrooms」的预制体定义。SpawnPrefab("quagmire_mushrooms") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_mushrooms.zip"),
}

local prefabs =
{
    "quagmire_mushrooms_cooked",
}

local prefabs_cooked =
{
    "quagmire_burnt_ingredients",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_mushrooms")
    inst.AnimState:SetBuild("quagmire_mushrooms")
    inst.AnimState:PlayAnimation("raw")

    --cookable (from cookable component) added to pristine state for optimization
    inst:AddTag("cookable")

    inst:AddTag("quagmire_stewable")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_mushrooms").master_postinit(inst)

    return inst
end

local function cookedfn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_mushrooms")
    inst.AnimState:SetBuild("quagmire_mushrooms")
    inst.AnimState:PlayAnimation("cooked")

    inst:AddTag("quagmire_stewable")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_mushrooms").master_postinit_cooked(inst)

    return inst
end

return Prefab("quagmire_mushrooms", fn, assets, prefabs),
    Prefab("quagmire_mushrooms_cooked", cookedfn, assets, prefabs_cooked)
