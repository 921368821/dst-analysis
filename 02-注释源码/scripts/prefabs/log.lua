--============================================================
-- 文件：prefabs/log.lua
-- 模块：预制体 / log（建筑与容器）
-- 职责：实体「log」的预制体定义。SpawnPrefab("log") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/log.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("log")
    inst.AnimState:SetBuild("log")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("log")

    inst.pickupsound = "wood"

    MakeInventoryFloatable(inst, "med", 0.1, 0.75)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("tradable")

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

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.WOOD
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_LOGS_HEALTH

    return inst
end

return Prefab("log", fn, assets)
