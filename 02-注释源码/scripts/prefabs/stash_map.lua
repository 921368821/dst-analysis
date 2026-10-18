--============================================================
-- 文件：prefabs/stash_map.lua
-- 模块：预制体 / stash_map（建筑与容器）
-- 职责：实体「stash_map」的预制体定义。SpawnPrefab("stash_map") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/stash_map.zip"),
}

local function getrevealtargetpos(inst, doer)
    if not TheWorld.components.piratespawner or not TheWorld.components.piratespawner:GetCurrentStash() then
        return false, "STASH_MAP_NOT_FOUND"
    end

    return Vector3(TheWorld.components.piratespawner:GetCurrentStash().Transform:GetWorldPosition())
end

local function prereveal(inst, doer)

    return true
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("stash_map")
    inst.AnimState:SetBuild("stash_map")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("cattoy")

    MakeInventoryFloatable(inst, "med", nil, 0.75)

    inst.pickupsound = "paper"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("erasablepaper")
    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")
    inst:AddComponent("tradable")

    inst:AddComponent("mapspotrevealer")
    inst.components.mapspotrevealer:SetGetTargetFn(getrevealtargetpos)
    inst.components.mapspotrevealer.postreveal = function(inst) 
        inst.components.stackable:Get():Remove()
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.SMALL_FUEL

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("stash_map", fn, assets)
