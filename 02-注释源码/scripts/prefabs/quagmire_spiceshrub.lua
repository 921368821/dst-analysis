--============================================================
-- 文件：prefabs/quagmire_spiceshrub.lua
-- 模块：预制体 / quagmire_spiceshrub（建筑与容器）
-- 职责：实体「quagmire_spiceshrub」的预制体定义。SpawnPrefab("quagmire_spiceshrub") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_spiceshrub.zip"),
    Asset("ANIM", "anim/quagmire_spotspice_sprig.zip"),
    Asset("ANIM", "anim/quagmire_spotspice_ground.zip"),
}

local prefabs =
{
    "quagmire_spotspice_sprig",
}

local prefabs_ground =
{
    "quagmire_burnt_ingredients",
}

local function shrub_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddMiniMapEntity()
    inst.entity:AddNetwork()

    inst.MiniMapEntity:SetIcon("quagmire_spotspiceshrub.png")

    inst.AnimState:SetBuild("quagmire_spiceshrub")
    inst.AnimState:SetBank("quagmire_spiceshrub")
    inst.AnimState:PlayAnimation("idle", true)

    MakeObstaclePhysics(inst, .3)

    inst:AddTag("plant")

    -- for stats tracking
    inst:AddTag("quagmire_wildplant")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_spiceshrub").master_postinit_shrub(inst)

    return inst
end

local function sprig_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_spotspice_sprig")
    inst.AnimState:SetBuild("quagmire_spotspice_sprig")
    inst.AnimState:PlayAnimation("idle")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_spiceshrub").master_postinit_sprig(inst)

    return inst
end

local function groundspice_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("quagmire_spotspice_ground")
    inst.AnimState:SetBuild("quagmire_spotspice_ground")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("quagmire_stewable")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_spiceshrub").master_postinit_ground(inst)

    return inst
end

return Prefab("quagmire_spotspice_shrub", shrub_fn, assets, prefabs),
    Prefab("quagmire_spotspice_sprig", sprig_fn, assets),
    Prefab("quagmire_spotspice_ground", groundspice_fn, assets, prefabs_ground)
