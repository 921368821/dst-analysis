--============================================================
-- 文件：prefabs/palmcone_scale.lua
-- 模块：预制体 / palmcone_scale（建筑与容器）
-- 职责：实体「palmcone_scale」的预制体定义。SpawnPrefab("palmcone_scale") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/palmcone_scale.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("palmcone_scale")
    inst.AnimState:SetBuild("palmcone_scale")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", 0.05, 0.68)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")

    inst:AddComponent("inspectable")
    inst:AddComponent("tradable")

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL

    MakeSmallBurnable(inst, TUNING.MED_BURNTIME)
    MakeSmallPropagator(inst)

    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("palmcone_scale", fn, assets)
