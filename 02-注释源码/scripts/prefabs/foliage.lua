--============================================================
-- 文件：prefabs/foliage.lua
-- 模块：预制体 / foliage（建筑与容器）
-- 职责：实体「foliage」的预制体定义。SpawnPrefab("foliage") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/foliage.zip"),
    Asset("ANIM", "anim/meat_rack_food_petals.zip"),
}

local prefabs =
{
    "quagmire_foliage_cooked",
    "foliage_dried",
}

local prefabs_cooked =
{
    "quagmire_burnt_ingredients",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("foliage")
    inst.AnimState:SetBuild("foliage")
    inst.AnimState:PlayAnimation("anim")

    inst.pickupsound = "vegetation_grassy"

    inst:AddTag("cattoy")
	--dryable (from dryable component) added to pristine state for optimization
	inst:AddTag("dryable")

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("tradable")

    inst:AddComponent("inspectable")

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.TINY_FUEL

    MakeSmallBurnable(inst, TUNING.TINY_BURNTIME)
    MakeSmallPropagator(inst)

    inst:AddComponent("inventoryitem")

    inst:AddComponent("edible")
    inst.components.edible.healthvalue = TUNING.HEALING_TINY
    inst.components.edible.hungervalue = 0
    inst.components.edible.foodtype = FOODTYPE.VEGGIE

    inst:AddComponent("perishable")
    inst.components.perishable:SetPerishTime(TUNING.PERISH_FAST)
    inst.components.perishable:StartPerishing()
    inst.components.perishable.onperishreplacement = "spoiled_food"

    inst:AddComponent("dryable")
    inst.components.dryable:SetProduct("foliage_dried")
    inst.components.dryable:SetDryTime(TUNING.DRY_FAST)
	inst.components.dryable:SetBuildFile("meat_rack_food_petals")
    inst.components.dryable:SetDriedBuildFile("meat_rack_food_petals")

    if TheNet:GetServerGameMode() == "quagmire" then
        event_server_data("quagmire", "prefabs/foliage").master_postinit(inst)
    end

    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

local function cooked_fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)
    MakeInventoryFloatable(inst)

    inst.AnimState:SetBank("foliage")
    inst.AnimState:SetBuild("foliage")
    inst.AnimState:PlayAnimation("cooked")

    inst:AddTag("quagmire_stewable")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    event_server_data("quagmire", "prefabs/foliage").master_postinit_cooked(inst)

    return inst
end

return Prefab("foliage", fn, assets, prefabs),
    Prefab("quagmire_foliage_cooked", cooked_fn, assets, prefabs_cooked)
