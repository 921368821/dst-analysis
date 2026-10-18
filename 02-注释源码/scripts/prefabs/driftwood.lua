--============================================================
-- 文件：prefabs/driftwood.lua
-- 模块：预制体 / driftwood（建筑与容器）
-- 职责：实体「driftwood」的预制体定义。SpawnPrefab("driftwood") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/driftwood_log.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    -- TODO replace with real driftwood bank/build
    inst.AnimState:SetBank("driftwood_log")
    inst.AnimState:SetBuild("driftwood_log")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "wood"

	--waterproofer (from waterproofer component) added to pristine state for optimization
    inst:AddTag("waterproofer")

    MakeInventoryFloatable(inst, "med", 0.03, 0.65)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

	inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.WOOD
    inst.components.edible.healthvalue = 0
    inst.components.edible.hungervalue = 0

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL

    MakeSmallBurnable(inst, TUNING.MED_BURNTIME)
    MakeSmallPropagator(inst)

    MakeHauntableLaunchAndIgnite(inst)

    ---------------------

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst:AddComponent("stackable")

    inst:AddComponent("waterproofer")
    inst.components.waterproofer:SetEffectiveness(0)

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.WOOD
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_LOGS_HEALTH
    inst.components.repairer.boatrepairsound = "turnoftides/common/together/boat/repair_with_wood"

    return inst
end

return Prefab("driftwood_log", fn, assets)
