--============================================================
-- 文件：prefabs/flower_evil.lua
-- 模块：预制体 / flower_evil（自然与资源）
-- 职责：实体「flower_evil」的预制体定义。SpawnPrefab("flower_evil") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/flowers_evil.zip"),
}

local prefabs =
{
    "petals_evil",
    "nightmarefuel",
}

local names = {"f1","f2","f3","f4","f5","f6","f7","f8"}

local function onsave(inst, data)
    data.anim = inst.animname
end

local function onload(inst, data)
    if data and data.anim then
        inst.animname = data.anim
        inst.AnimState:PlayAnimation(inst.animname)
    end
end

local function onpickedfn(inst, picker)
    if picker and picker.components.sanity then
        if  picker.components.skilltreeupdater and picker.components.skilltreeupdater:IsActivated("wendy_gravestone_1") then
            picker.components.sanity:DoDelta(TUNING.SANITY_TINY)
        else
            picker.components.sanity:DoDelta(-TUNING.SANITY_TINY)
        end
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("flowers_evil")
    inst.AnimState:SetBuild("flowers_evil")
    inst.AnimState:SetRayTestOnBB(true)

    inst.scrapbook_anim = "f1"

    inst:AddTag("flower")

    inst.pickupsound = "vegetation_grassy"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.scrapbook_removedeps = { "nightmarefuel" }

    inst.animname = names[math.random(#names)]
    inst.AnimState:PlayAnimation(inst.animname)

    inst:AddComponent("inspectable")

    inst:AddComponent("sanityaura")
    inst.components.sanityaura.aura = -TUNING.SANITYAURA_SMALL

    inst:AddComponent("pickable")
    inst.components.pickable.picksound = "dontstarve/wilson/pickup_plants"
    inst.components.pickable:SetUp("petals_evil", 10)
    inst.components.pickable.onpickedfn = onpickedfn
	inst.components.pickable.remove_when_picked = true
    inst.components.pickable.quickpick = true
    inst.components.pickable.wildfirestarter = true

    --inst:AddComponent("transformer")

    MakeSmallBurnable(inst)
    MakeSmallPropagator(inst)

    MakeHauntableIgnite(inst)

    --------SaveLoad
    inst.OnSave = onsave
    inst.OnLoad = onload

    return inst
end

return Prefab("flower_evil", fn, assets, prefabs)