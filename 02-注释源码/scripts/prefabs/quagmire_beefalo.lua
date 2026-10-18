--============================================================
-- 文件：prefabs/quagmire_beefalo.lua
-- 模块：预制体 / quagmire_beefalo（建筑与容器）
-- 职责：实体「quagmire_beefalo」的预制体定义。SpawnPrefab("quagmire_beefalo") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/beefalo_basic.zip"),
    Asset("ANIM", "anim/beefalo_actions.zip"),
    Asset("ANIM", "anim/beefalo_shaved_build.zip"),
    Asset("ANIM", "anim/quagmire_beefalo_override_build.zip"),
}

local prefabs =
{
    "meat",
    "poop",
}

local function beefalo()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddNetwork()

    MakeCharacterPhysics(inst, 100, .5)

    inst.DynamicShadow:SetSize(6, 2)
    inst.Transform:SetSixFaced()

    inst.AnimState:SetBank("beefalo")
    inst.AnimState:SetBuild("beefalo_shaved_build")
    inst.AnimState:AddOverrideBuild("quagmire_beefalo_override_build")
    inst.AnimState:PlayAnimation("idle_loop", true)
    inst.AnimState:Hide("HEAT")

    inst:AddTag("beefalo")
    inst:AddTag("animal")
    inst:AddTag("largecreature")
    inst:AddTag("canbeslaughtered")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_beefalo").master_postinit(inst)

    return inst
end

return Prefab("quagmire_beefalo", beefalo, assets, prefabs)
