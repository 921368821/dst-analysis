--============================================================
-- 文件：prefabs/waxpaper.lua
-- 模块：预制体 / waxpaper（建筑与容器）
-- 职责：实体「waxpaper」的预制体定义。SpawnPrefab("waxpaper") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/wax_paper.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBuild("wax_paper")
    inst.AnimState:SetBank("wax_paper")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "paper"

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
    inst.components.fuel.fuelvalue = TUNING.SMALL_FUEL

    inst:AddComponent("tradable")

    MakeSmallBurnable(inst, TUNING.SMALL_BURNTIME)
    MakeSmallPropagator(inst)
    inst.components.propagator.flashpoint = 10 + math.random() * 5
    MakeHauntableLaunchAndIgnite(inst)

    return inst
end

return Prefab("waxpaper", fn, assets)
