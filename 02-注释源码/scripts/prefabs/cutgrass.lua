--============================================================
-- 文件：prefabs/cutgrass.lua
-- 模块：预制体 / cutgrass（建筑与容器）
-- 职责：实体「cutgrass」的预制体定义。SpawnPrefab("cutgrass") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cutgrass.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("cutgrass")
    inst.AnimState:SetBuild("cutgrass")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "vegetation_grassy"

    inst:AddTag("cattoy")
    inst:AddTag("renewable")
    inst:AddTag("cutgrass")

    MakeInventoryFloatable(inst, "med", 0.05, 0.68)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.ROUGHAGE
    inst.components.edible.healthvalue = TUNING.HEALING_TINY
    inst.components.edible.hungervalue = TUNING.CALORIES_TINY/2

    inst:AddComponent("inspectable")
    inst:AddComponent("tradable")

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.SMALL_FUEL

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)

    MakeHauntableLaunchAndIgnite(inst)

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.HAY
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_CUTGRASS_HEALTH

	inst:AddComponent("snowmandecor")

    return inst
end

return Prefab("cutgrass", fn, assets)
