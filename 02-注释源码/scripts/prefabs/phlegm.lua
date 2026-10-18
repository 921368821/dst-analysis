--============================================================
-- 文件：prefabs/phlegm.lua
-- 模块：预制体 / phlegm（建筑与容器）
-- 职责：实体「phlegm」的预制体定义。SpawnPrefab("phlegm") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/phlegm.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("phlegm")
    inst.AnimState:SetBuild("phlegm")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", nil, 0.75)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("edible")
    inst.components.edible.healthvalue = 0
    inst.components.edible.hungervalue = TUNING.CALORIES_SMALL
    inst.components.edible.sanityvalue = -TUNING.SANITY_MED
    inst.components.edible.foodtype = FOODTYPE.GENERIC

    inst:AddComponent("tradable")

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("phlegm", fn, assets)