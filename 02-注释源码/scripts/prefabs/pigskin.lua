--============================================================
-- 文件：prefabs/pigskin.lua
-- 模块：预制体 / pigskin（建筑与容器）
-- 职责：实体「pigskin」的预制体定义。SpawnPrefab("pigskin") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/pigskin.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("pigskin")
    inst.AnimState:SetBuild("pigskin")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", nil, 0.77)

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
    inst.components.tradable.goldvalue = TUNING.GOLD_VALUES.MEAT

    inst:AddComponent("inventoryitem")

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.HORRIBLE

    return inst
end

return Prefab("pigskin", fn, assets)