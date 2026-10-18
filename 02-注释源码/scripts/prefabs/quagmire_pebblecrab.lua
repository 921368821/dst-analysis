--============================================================
-- 文件：prefabs/quagmire_pebblecrab.lua
-- 模块：预制体 / quagmire_pebblecrab（建筑与容器）
-- 职责：实体「quagmire_pebblecrab」的预制体定义。SpawnPrefab("quagmire_pebblecrab") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/quagmire_pebble_crab.zip"),
}

local prefabs =
{
    "quagmire_crabmeat",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddNetwork()

    MakeCharacterPhysics(inst, 1, .25)

    inst.DynamicShadow:SetSize(1, .75)
    inst.Transform:SetSixFaced()

    inst.AnimState:SetBank("quagmire_pebble_crab")
    inst.AnimState:SetBuild("quagmire_pebble_crab")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("animal")
    inst:AddTag("prey")
    inst:AddTag("smallcreature")
    inst:AddTag("canbetrapped")
    inst:AddTag("cattoy")
    inst:AddTag("crab")

    MakeFeedableSmallLivestockPristine(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_pebblecrab").master_postinit(inst)

    return inst
end

return Prefab("quagmire_pebblecrab", fn, assets, prefabs)
