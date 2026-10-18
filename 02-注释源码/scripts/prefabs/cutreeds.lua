--============================================================
-- 文件：prefabs/cutreeds.lua
-- 模块：预制体 / cutreeds（建筑与容器）
-- 职责：实体「cutreeds」的预制体定义。SpawnPrefab("cutreeds") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cutreeds.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("cutreeds")
    inst.AnimState:SetBuild("cutreeds")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "vegetation_grassy"

    MakeInventoryFloatable(inst, "med", nil, 0.6)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.ROUGHAGE
    inst.components.edible.healthvalue = TUNING.HEALING_TINY
    inst.components.edible.hungervalue = TUNING.CALORIES_TINY/2

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.SMALL_FUEL

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)

    MakeHauntableLaunchAndIgnite(inst)

    inst:AddComponent("inventoryitem")

    return inst
end

return Prefab("cutreeds", fn, assets)
