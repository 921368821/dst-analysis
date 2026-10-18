--============================================================
-- 文件：prefabs/lavaarena_abigail.lua
-- 模块：预制体 / lavaarena_abigail（建筑与容器）
-- 职责：实体「lavaarena_abigail」的预制体定义。SpawnPrefab("lavaarena_abigail") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/player_ghost_withhat.zip"),
    Asset("ANIM", "anim/ghost_abigail_build.zip"),
    Asset("SOUND", "sound/ghost.fsb"),
}

local prefabs =
{
    "lavaarena_abigail_flower",
}

local function lavaarena_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddLight()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("ghost")
    inst.AnimState:SetBuild("ghost_abigail_build")
    inst.AnimState:PlayAnimation("idle", true)
    inst.AnimState:SetBloomEffectHandle("shaders/anim_bloom_ghost.ksh")
    inst.AnimState:SetLightOverride(TUNING.GHOST_LIGHT_OVERRIDE)
    --inst.AnimState:SetMultColour(1, 1, 1, .6)

    inst:AddTag("character")
    inst:AddTag("scarytoprey")
    inst:AddTag("girl")
    inst:AddTag("ghost")
    inst:AddTag("noauradamage")
    inst:AddTag("notraptrigger")
    inst:AddTag("abigail")
    inst:AddTag("NOBLOCK")
    inst:AddTag("companion")
    inst:AddTag("NOCLICK")

    MakeGhostPhysics(inst, 1, .5)

    inst.Light:SetIntensity(.6)
    inst.Light:SetRadius(.5)
    inst.Light:SetFalloff(.6)
    inst.Light:Enable(true)
    inst.Light:SetColour(180 / 255, 195 / 255, 225 / 255)

    --It's a loop that's always on, so we can start this in our pristine state
    inst.SoundEmitter:PlaySound("dontstarve/ghost/ghost_girl_howl_LP", "howl")

    inst:Hide()

    inst:SetPrefabNameOverride("abigail")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("lavaarena", "prefabs/lavaarena_abigail").master_postinit(inst)

    return inst
end

return Prefab("lavaarena_abigail", lavaarena_fn, assets, prefabs)
