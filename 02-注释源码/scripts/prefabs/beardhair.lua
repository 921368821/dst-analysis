--============================================================
-- 文件：prefabs/beardhair.lua
-- 模块：预制体 / beardhair（建筑与容器）
-- 职责：实体「beardhair」的预制体定义。SpawnPrefab("beardhair") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/beardhair.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("beardhair")
    inst.AnimState:SetBuild("beardhair")
    inst.AnimState:PlayAnimation("idle")

    inst.entity:AddNetwork()

    MakeInventoryFloatable(inst, "med", nil, 0.75)

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_FUEL

	inst:AddComponent("snowmandecor")

    MakeSmallBurnable(inst, TUNING.MED_BURNTIME)
    MakeSmallPropagator(inst)

    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("beardhair", fn, assets)