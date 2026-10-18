--============================================================
-- 文件：prefabs/guano.lua
-- 模块：预制体 / guano（建筑与容器）
-- 职责：实体「guano」的预制体定义。SpawnPrefab("guano") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/guano.zip"),
	Asset("SCRIPT", "scripts/prefabs/fertilizer_nutrient_defs.lua"),
}

local prefabs =
{
    "flies",
    "poopcloud",
    "gridplacer_farmablesoil",
}

local FERTILIZER_DEFS = require("prefabs/fertilizer_nutrient_defs").FERTILIZER_DEFS

local function OnBurn(inst)
    DefaultBurnFn(inst)
    if inst.flies ~= nil then
        inst.flies:Remove()
        inst.flies = nil
    end
end

local function FuelTaken(inst, taker)
    SpawnPrefab("poopcloud").Transform:SetPosition(taker.Transform:GetWorldPosition())
end

local function ondropped(inst)
    if inst.flies == nil then
        inst.flies = inst:SpawnChild("flies")
    end
end

local function onputininventory(inst)
    if inst.flies ~= nil then
        inst.flies:Remove()
        inst.flies = nil
    end
end

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

    inst.AnimState:SetBank("guano")
    inst.AnimState:SetBuild("guano")
    inst.AnimState:PlayAnimation("dump")
    inst.AnimState:PushAnimation("idle")

    --inst.pickupsound = "squidgy"

    MakeInventoryFloatable(inst, "med", 0.1, 0.73)
    MakeDeployableFertilizerPristine(inst)

    inst:AddTag("fertilizerresearchable")

    inst.GetFertilizerKey = GetFertilizerKey

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst.scrapbook_anim = "idle"

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst:AddComponent("stackable")

    inst:AddComponent("fertilizerresearchable")
    inst.components.fertilizerresearchable:SetResearchFn(fertilizerresearchfn)

    inst:AddComponent("fertilizer")
    inst.components.fertilizer.fertilizervalue = TUNING.GUANO_FERTILIZE
    inst.components.fertilizer.soil_cycles = TUNING.GUANO_SOILCYCLES
    inst.components.fertilizer.withered_cycles = TUNING.GUANO_WITHEREDCYCLES
    inst.components.fertilizer:SetNutrients(FERTILIZER_DEFS.guano.nutrients)

    inst:AddComponent("smotherer")

    inst.components.inventoryitem:SetOnDroppedFn(ondropped)
    inst.components.inventoryitem:SetOnPutInInventoryFn(onputininventory)

    inst.flies = inst:SpawnChild("flies")

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL
    inst.components.fuel:SetOnTakenFn(FuelTaken)

    if TheNet:GetServerGameMode() == "quagmire" then
        inst.components.fuel:SetOnTakenFn(nil)
    end

    MakeSmallBurnable(inst, TUNING.MED_BURNTIME)
    inst.components.burnable:SetOnIgniteFn(OnBurn)
    MakeSmallPropagator(inst)

    MakeDeployableFertilizer(inst)
    MakeHauntableLaunchAndIgnite(inst)

    inst:AddComponent("savedscale")

    ---------------------

    return inst
end

return Prefab("guano", fn, assets, prefabs)
