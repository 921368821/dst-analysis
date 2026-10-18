--============================================================
-- 文件：prefabs/crumbs.lua
-- 模块：预制体 / crumbs（建筑与容器）
-- 职责：实体「crumbs」的预制体定义。SpawnPrefab("crumbs") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

require "prefabs/veggies"

local assets =
{
    Asset("ANIM", "anim/cookie_crumbs.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank ("cookie_crumbs")
    inst.AnimState:SetBuild("cookie_crumbs")
    inst.AnimState:PlayAnimation("idle")
    inst.AnimState:SetRayTestOnBB(true)

    inst:AddTag("catfood")
    inst:AddTag("crumbs")

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")
    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.GOODIES
    inst.components.edible.healthvalue = 0
    inst.components.edible.hungervalue = 1

    inst:AddComponent("bait")

    inst:AddComponent("tradable")
    inst:AddComponent("inspectable")

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunchAndPerish(inst)

    inst:AddComponent("perishable")
    inst.components.perishable:SetPerishTime(TUNING.PERISH_ONE_DAY)
    inst.components.perishable:StartPerishing()
	inst.components.perishable:SetOnPerishFn(inst.Remove)

    return inst
end

return Prefab("crumbs", fn, assets)
