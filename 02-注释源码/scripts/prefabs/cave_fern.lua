--============================================================
-- 文件：prefabs/cave_fern.lua
-- 模块：预制体 / cave_fern（建筑与容器）
-- 职责：实体「cave_fern」的预制体定义。SpawnPrefab("cave_fern") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cave_ferns.zip"),
}

local prefabs =
{
    "foliage",
    "cave_fern_withered",
}

local names = {"f1","f2","f3","f4","f5","f6","f7","f8","f9","f10"}

local function onsave(inst, data)
    data.anim = inst.animname
end

local function onload(inst, data)
    if data and data.anim then
        inst.animname = data.anim
        inst.AnimState:PlayAnimation(inst.animname)
    end
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("ferns")
    inst.AnimState:SetBuild("cave_ferns")
    inst.AnimState:SetRayTestOnBB(true)

    inst.scrapbook_anim = "f1"

    --inst.pickupsound = "vegetation_grassy"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.animname = names[math.random(#names)]
    inst.AnimState:PlayAnimation(inst.animname)

    inst:AddComponent("inspectable")

    inst:AddComponent("pickable")
    inst.components.pickable.picksound = "dontstarve/wilson/pickup_plants"
    inst.components.pickable:SetUp("foliage", 10)
	inst.components.pickable.remove_when_picked = true
    inst.components.pickable.quickpick = true

    MakeSmallBurnable(inst)
    MakeSmallPropagator(inst)

    MakeHauntableIgnite(inst)

    --------SaveLoad
    inst.OnSave = onsave
    inst.OnLoad = onload

    return inst
end

return Prefab("cave_fern", fn, assets, prefabs)