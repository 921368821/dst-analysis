--============================================================
-- 文件：prefabs/milkywhites.lua
-- 模块：预制体 / milkywhites（建筑与容器）
-- 职责：实体「milkywhites」的预制体定义。SpawnPrefab("milkywhites") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/milkywhites.zip"),
    Asset("INV_IMAGE", "milkywhites"),
}

local prefabs = nil

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("milkywhites")
    inst.AnimState:SetBuild("milkywhites")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst)

    inst:AddTag("catfood")

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("edible")
    inst.components.edible.healthvalue = TUNING.HEALING_MEDSMALL
    inst.components.edible.hungervalue = TUNING.CALORIES_SMALL
    inst.components.edible.sanityvalue = -TUNING.SANITY_MEDLARGE

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("perishable")
    inst.components.perishable:SetPerishTime(TUNING.PERISH_MED)
    inst.components.perishable:StartPerishing()
    inst.components.perishable.onperishreplacement = "spoiled_food"

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("tradable")

    MakeHauntableLaunchAndPerish(inst)

    return inst
end

return Prefab("milkywhites", fn, assets, prefabs)
