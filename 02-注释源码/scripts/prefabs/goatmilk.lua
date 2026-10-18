--============================================================
-- 文件：prefabs/goatmilk.lua
-- 模块：预制体 / goatmilk（建筑与容器）
-- 职责：实体「goatmilk」的预制体定义。SpawnPrefab("goatmilk") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/goatmilk.zip"),
}

local prefabs =
{
    "spoiled_food",
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    inst.AnimState:SetBank("goatmilk")
    inst.AnimState:SetBuild("goatmilk")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryPhysics(inst)

    inst:AddTag("catfood")
    inst:AddTag("fooddrink")

    MakeInventoryFloatable(inst, "small", 0.15, 0.6)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("edible")
    inst.components.edible.healthvalue = TUNING.HEALING_SMALL
    inst.components.edible.hungervalue = TUNING.CALORIES_SMALL
    inst.components.edible.sanityvalue = TUNING.SANITY_SMALL
    inst.components.edible.chargevalue = TUNING.WX78_CHARGE_SMALL

    inst:AddComponent("tradable")

    inst:AddComponent("perishable")
    inst.components.perishable:SetPerishTime(TUNING.PERISH_FAST)
    inst.components.perishable:StartPerishing()
    inst.components.perishable.onperishreplacement = "spoiled_food"

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("goatmilk", fn, assets, prefabs)
