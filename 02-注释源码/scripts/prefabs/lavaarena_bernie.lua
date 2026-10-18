--============================================================
-- 文件：prefabs/lavaarena_bernie.lua
-- 模块：预制体 / lavaarena_bernie（建筑与容器）
-- 职责：实体「lavaarena_bernie」的预制体定义。SpawnPrefab("lavaarena_bernie") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/bernie.zip"),
    Asset("ANIM", "anim/bernie_build.zip"),
}

local prefabs =
{
    "small_puff",
}

local function CanBeRevivedBy(inst, reviver)
    return reviver:HasTag("bernie_reviver")
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddDynamicShadow()
    inst.entity:AddNetwork()

    inst:SetPhysicsRadiusOverride(.35)
    MakeCharacterPhysics(inst, 50, inst.physicsradiusoverride)
    inst.DynamicShadow:SetSize(1.1, .55)

    inst.Transform:SetScale(TUNING.LAVAARENA_BERNIE_SCALE, TUNING.LAVAARENA_BERNIE_SCALE, TUNING.LAVAARENA_BERNIE_SCALE)
    inst.Transform:SetFourFaced()

    inst.AnimState:SetBank("bernie")
    inst.AnimState:SetBuild("bernie_build")
    inst.AnimState:PlayAnimation("idle_loop", true)

    inst:AddTag("character")
    inst:AddTag("smallcreature")
    inst:AddTag("companion")
    inst:AddTag("notarget")

    inst:AddComponent("revivablecorpse")
    inst.components.revivablecorpse:SetCanBeRevivedByFn(CanBeRevivedBy)

    inst:Hide()

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("lavaarena", "prefabs/lavaarena_bernie").master_postinit(inst)

    return inst
end

return Prefab("lavaarena_bernie", fn, assets, prefabs)
