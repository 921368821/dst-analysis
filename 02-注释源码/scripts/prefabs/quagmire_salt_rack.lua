--============================================================
-- 文件：prefabs/quagmire_salt_rack.lua
-- 模块：预制体 / quagmire_salt_rack（建筑与容器）
-- 职责：实体「quagmire_salt_rack」的预制体定义。SpawnPrefab("quagmire_salt_rack") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_salt_rack.zip"),
}

local prefabs =
{
    "quagmire_salt_rack_item",
    "quagmire_saltrock",
    "collapse_small",
    "splash",
}

local prefabs_item =
{
    "quagmire_salt_rack",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("quagmire_salt_rack")
    inst.AnimState:SetBuild("quagmire_salt_rack")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:Hide("salt")

    MakeObstaclePhysics(inst, 1.95)

    MakeSnowCoveredPristine(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_salt_rack").master_postinit(inst)

    return inst
end

local function itemfn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_pot_hanger")
    inst.AnimState:SetBuild("quagmire_pot_hanger")
    inst.AnimState:PlayAnimation("item")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_salt_rack").master_postinit_item(inst)

    return inst
end

return Prefab("quagmire_salt_rack", fn, assets, prefabs),
    Prefab("quagmire_salt_rack_item", itemfn, assets, prefabs_item)
