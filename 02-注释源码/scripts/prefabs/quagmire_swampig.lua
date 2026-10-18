--============================================================
-- 文件：prefabs/quagmire_swampig.lua
-- 模块：预制体 / quagmire_swampig（建筑与容器）
-- 职责：实体「quagmire_swampig」的预制体定义。SpawnPrefab("quagmire_swampig") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/ds_pig_basic.zip"),
    Asset("ANIM", "anim/ds_pig_actions.zip"),
    Asset("ANIM", "anim/ds_pig_attacks.zip"),
    Asset("ANIM", "anim/quagmire_swampig_build.zip"),
    Asset("ANIM", "anim/quagmire_swampig_extras.zip"),
    Asset("SOUND", "sound/pig.fsb"),
}

local prefabs =
{
    "meat",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddNetwork()

    MakeCharacterPhysics(inst, 50, .4)

    inst.DynamicShadow:SetSize(1.5, .75)
    inst.Transform:SetFourFaced()

    inst.AnimState:SetBank("pigman")
    inst.AnimState:SetBuild("quagmire_swampig_build")
    inst.AnimState:PlayAnimation("idle_loop", true)
    inst.AnimState:Hide("hat")
    inst.AnimState:Hide("ARM_carry_up")

    inst:AddTag("character")
    inst:AddTag("pig")
    inst:AddTag("scarytoprey")

    --Sneak these into pristine state for optimization
    inst:AddTag("_named")

    inst:AddComponent("talker")
    inst.components.talker.fontsize = 28
    inst.components.talker.font = TALKINGFONT
    inst.components.talker.offset = Vector3(0, -400, 0)
    inst.components.talker:MakeChatter()

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/quagmire_swampig").master_postinit(inst)

    return inst
end

return Prefab("quagmire_swampig", fn, assets, prefabs)
