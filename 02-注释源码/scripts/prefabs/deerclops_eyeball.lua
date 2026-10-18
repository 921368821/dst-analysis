--============================================================
-- 文件：prefabs/deerclops_eyeball.lua
-- 模块：预制体 / deerclops_eyeball（建筑与容器）
-- 职责：实体「deerclops_eyeball」的预制体定义。SpawnPrefab("deerclops_eyeball") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/deerclops_eyeball.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("deerclops_eyeball")
    inst.AnimState:SetBuild("deerclops_eyeball")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "small", 0.2, 0.95)

    inst:AddTag("deerclops_eyeball")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("tradable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.MEAT
    inst.components.edible.healthvalue = TUNING.HEALING_HUGE
    inst.components.edible.hungervalue = TUNING.CALORIES_HUGE
    inst.components.edible.sanityvalue = -TUNING.SANITY_MED

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_LARGEITEM

	inst:AddComponent("snowmandecor")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("deerclops_eyeball", fn, assets)