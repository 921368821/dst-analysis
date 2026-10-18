--============================================================
-- 文件：prefabs/spidergland.lua
-- 模块：预制体 / spidergland（敌对生物）
-- 职责：实体「spidergland」的预制体定义。SpawnPrefab("spidergland") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/spider_gland.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("spider_gland")
    inst.AnimState:SetBuild("spider_gland")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("cattoy")

    MakeInventoryFloatable(inst)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    MakeSmallBurnable(inst, TUNING.TINY_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunchAndIgnite(inst)

    ---------------------

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst:AddComponent("stackable")
    inst:AddComponent("tradable")

    inst:AddComponent("healer")
    inst.components.healer:SetHealthAmount(TUNING.HEALING_MEDSMALL)

    return inst
end

return Prefab("spidergland", fn, assets)