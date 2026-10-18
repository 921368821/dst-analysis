--============================================================
-- 文件：prefabs/manrabbit_tail.lua
-- 模块：预制体 / manrabbit_tail（建筑与容器）
-- 职责：实体「manrabbit_tail」的预制体定义。SpawnPrefab("manrabbit_tail") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/manrabbit_tail.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("manrabbit_tail")
    inst.AnimState:SetBuild("manrabbit_tail")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "cloth"

    inst:AddTag("cattoy")

    MakeInventoryFloatable(inst, "small", 0.1, 0.85)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    MakeSmallBurnable(inst)
    MakeSmallPropagator(inst)
    MakeHauntableLaunchAndIgnite(inst)

    inst:AddComponent("tradable")
    inst.components.tradable.goldvalue = TUNING.GOLD_VALUES.MEAT * 2

    inst:AddComponent("inventoryitem")

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.HORRIBLE

    return inst
end

return Prefab("manrabbit_tail", fn, assets)