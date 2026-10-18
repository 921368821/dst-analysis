--============================================================
-- 文件：prefabs/slurperpelt.lua
-- 模块：预制体 / slurperpelt（建筑与容器）
-- 职责：实体「slurperpelt」的预制体定义。SpawnPrefab("slurperpelt") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/slurper_pelt.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("slurper_pelt")
    inst.AnimState:SetBuild("slurper_pelt")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("inspectable")

    MakeSmallBurnable(inst)
    MakeSmallPropagator(inst)

    inst:AddComponent("tradable")
    inst.components.tradable.goldvalue = TUNING.GOLD_VALUES.MEAT

    inst:AddComponent("inventoryitem")

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.HORRIBLE

    return inst
end

return Prefab("slurper_pelt", fn, assets)