--============================================================
-- 文件：prefabs/treegrowthsolution.lua
-- 模块：预制体 / treegrowthsolution（建筑与容器）
-- 职责：实体「treegrowthsolution」的预制体定义。SpawnPrefab("treegrowthsolution") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/treegrowthsolution.zip"),
}

local prefabs =
{
    "treegrowthsolution_use_fx",
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
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("treegrowthsolution")
    inst.AnimState:SetBuild("treegrowthsolution")
    inst.AnimState:PlayAnimation("item")

    inst:AddTag("allow_action_on_impassable")
    inst:AddTag("boat_patch")

    MakeInventoryFloatable(inst, "med", 0.1)
    MakeDeployableFertilizerPristine(inst)

    inst:AddTag("fertilizerresearchable")
    inst.GetFertilizerKey = GetFertilizerKey

    inst.scrapbook_anim = "item"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    local fertilizerresearchable = inst:AddComponent("fertilizerresearchable")
    fertilizerresearchable:SetResearchFn(fertilizerresearchfn)

    local fertilizer = inst:AddComponent("fertilizer")
    fertilizer.fertilizervalue = TUNING.TREEGROWTH_FERTILIZE
    fertilizer.soil_cycles = TUNING.TREEGROWTH_SOILCYCLES
    fertilizer.withered_cycles = TUNING.TREEGROWTH_WITHEREDCYCLES
    fertilizer:SetNutrients(FERTILIZER_DEFS.treegrowthsolution.nutrients)

    local treegrowthsolution = inst:AddComponent("treegrowthsolution")
    treegrowthsolution.fx_prefab = "treegrowthsolution_use_fx"

    local stackable = inst:AddComponent("stackable")
    stackable.maxsize = TUNING.STACK_SIZE_LARGEITEM

    inst:AddComponent("inspectable")

    local inventoryitem = inst:AddComponent("inventoryitem")
    inventoryitem:SetSinks(false)

    local boatpatch = inst:AddComponent("boatpatch")
    boatpatch.patch_type = "treegrowth"

    local repairer = inst:AddComponent("repairer")
    repairer.repairmaterial = MATERIALS.WOOD
    repairer.healthrepairvalue = TUNING.REPAIR_TREEGROWTH_HEALTH
    repairer.boatrepairsound = "waterlogged1/common/use_figjam"

    MakeDeployableFertilizer(inst)
    MakeHauntableLaunchAndSmash(inst)

    return inst
end

return Prefab("treegrowthsolution", fn, assets, prefabs)
