--============================================================
-- 文件：prefabs/waterplant_planter.lua
-- 模块：预制体 / waterplant_planter（建筑与容器）
-- 职责：实体「waterplant_planter」的预制体定义。SpawnPrefab("waterplant_planter") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/barnacle_root.zip"),
    Asset("INV_IMAGE", "waterplant_planter"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("barnacle_root")
    inst.AnimState:SetBuild("barnacle_root")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", 0.2, 0.85)

    inst.scrapbook_specialinfo = "PLANTABLE_SEASTACK"

    inst.entity:SetPristine()
    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_LARGEITEM

    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.LARGE_FUEL

    inst:AddComponent("upgrader")
    inst.components.upgrader.upgradetype = UPGRADETYPES.WATERPLANT

    MakeMediumBurnable(inst, TUNING.LARGE_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("waterplant_planter", fn, assets)
