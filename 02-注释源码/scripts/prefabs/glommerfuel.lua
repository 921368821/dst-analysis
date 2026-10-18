--============================================================
-- 文件：prefabs/glommerfuel.lua
-- 模块：预制体 / glommerfuel（建筑与容器）
-- 职责：实体「glommerfuel」的预制体定义。SpawnPrefab("glommerfuel") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/glommer_fuel.zip"),
	Asset("SCRIPT", "scripts/prefabs/fertilizer_nutrient_defs.lua"),
}

local prefabs =
{
    "gridplacer_farmablesoil",
}

local FERTILIZER_DEFS = require("prefabs/fertilizer_nutrient_defs").FERTILIZER_DEFS

local function GetFertilizerKey(inst)
    return inst.prefab
end

local function fertilizerresearchfn(inst)
    return inst:GetFertilizerKey()
end

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("glommer_fuel")
    inst.AnimState:SetBuild("glommer_fuel")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst)
    MakeDeployableFertilizerPristine(inst)

    inst:AddTag("fertilizerresearchable")

    inst.GetFertilizerKey = GetFertilizerKey

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")
    inst:AddComponent("stackable")

    inst:AddComponent("fertilizerresearchable")
    inst.components.fertilizerresearchable:SetResearchFn(fertilizerresearchfn)

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.LARGE_FUEL

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)

    inst:AddComponent("fertilizer")
    inst.components.fertilizer.fertilizervalue = TUNING.GLOMMERFUEL_FERTILIZE
    inst.components.fertilizer.soil_cycles = TUNING.GLOMMERFUEL_SOILCYCLES
    inst.components.fertilizer:SetNutrients(FERTILIZER_DEFS.glommerfuel.nutrients)

    MakeDeployableFertilizer(inst)
    MakeHauntableLaunch(inst)

    inst:AddComponent("edible")
    inst.components.edible.healthvalue = TUNING.HEALING_LARGE
    inst.components.edible.hungervalue = TUNING.CALORIES_TINY
    inst.components.edible.sanityvalue = -TUNING.SANITY_HUGE

    return inst
end

return Prefab("glommerfuel", fn, assets, prefabs)
