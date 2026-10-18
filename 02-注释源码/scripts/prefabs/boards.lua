--============================================================
-- 文件：prefabs/boards.lua
-- 模块：预制体 / boards（建筑与容器）
-- 职责：实体「boards」的预制体定义。SpawnPrefab("boards") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/boards.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("boards")
    inst.AnimState:SetBuild("boards")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "wood"

    MakeInventoryFloatable(inst, "med", .15, {1.15, .8, 1.15})

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

	inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.WOOD
    inst.components.edible.healthvalue = 0
    inst.components.edible.hungervalue = 0

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_LARGEITEM

    inst:AddComponent("inspectable")

    MakeSmallBurnable(inst, TUNING.LARGE_BURNTIME)
    MakeSmallPropagator(inst)

    inst:AddComponent("inventoryitem")

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.WOOD
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_BOARDS_HEALTH
    inst.components.repairer.boatrepairsound = "turnoftides/common/together/boat/repair_with_wood"

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.LARGE_FUEL

    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("boards", fn, assets)
