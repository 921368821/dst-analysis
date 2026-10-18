--============================================================
-- 文件：prefabs/goose_feather.lua
-- 模块：预制体 / goose_feather（建筑与容器）
-- 职责：实体「goose_feather」的预制体定义。SpawnPrefab("goose_feather") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/goose_feather.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("goose_feather")
    inst.AnimState:SetBuild("goose_feather")
    inst.AnimState:PlayAnimation("idle")

    MakeInventoryFloatable(inst, "med", 0.05, 0.68)

	inst:AddTag("cattoy")
    inst:AddTag("birdfeather")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("inspectable")
    inst:AddComponent("inventoryitem")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_MEDITEM

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.TINY_FUEL

	inst:AddComponent("snowmandecor")

    MakeSmallBurnable(inst, TUNING.TINY_BURNTIME)
    MakeSmallPropagator(inst)
    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("goose_feather", fn, assets)