--============================================================
-- 文件：prefabs/charcoal.lua
-- 模块：预制体 / charcoal（建筑与容器）
-- 职责：实体「charcoal」的预制体定义。SpawnPrefab("charcoal") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/charcoal.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("charcoal")
    inst.AnimState:SetBuild("charcoal")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "wood"

    inst:AddTag("molebait")

    MakeInventoryFloatable(inst, "med", 0.05, 0.6)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.BURNT
    inst.components.edible.hungervalue = 20
    inst.components.edible.healthvalue = 20

    inst:AddComponent("tradable")

    inst:AddComponent("bait")

    MakeMediumBurnable(inst, TUNING.MED_BURNTIME)
    MakeMediumPropagator(inst)

    MakeHauntableLaunchAndIgnite(inst)

    ---------------------

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

	inst:AddComponent("snowmandecor")

    return inst
end

return Prefab("charcoal", fn, assets)
