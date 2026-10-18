--============================================================
-- 文件：prefabs/butterflywings.lua
-- 模块：预制体 / butterflywings（环境动画）
-- 职责：实体「butterflywings」的预制体定义。SpawnPrefab("butterflywings") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/butterfly_wings.zip"),
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

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("butterfly_wings")
    inst.AnimState:SetBuild("butterfly_wings")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "vegetation_firm"

    inst:AddTag("cattoy")

    MakeInventoryFloatable(inst, "small", 0.03)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("edible")
    inst.components.edible.healthvalue = TUNING.HEALING_MEDSMALL
    inst.components.edible.hungervalue = TUNING.CALORIES_TINY
    inst.components.edible.foodtype = FOODTYPE.VEGGIE

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("tradable")

    inst:AddComponent("perishable")
    inst.components.perishable:SetPerishTime(TUNING.PERISH_FAST)
    inst.components.perishable:StartPerishing()
    inst.components.perishable.onperishreplacement = "spoiled_food"

    MakeHauntableLaunchAndPerish(inst)

    return inst
end

return Prefab("butterflywings", fn, assets, prefabs)