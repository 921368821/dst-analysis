--============================================================
-- 文件：prefabs/cutstone.lua
-- 模块：预制体 / cutstone（建筑与容器）
-- 职责：实体「cutstone」的预制体定义。SpawnPrefab("cutstone") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/cutstone.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("cutstone")
    inst.AnimState:SetBuild("cutstone")
    inst.AnimState:PlayAnimation("idle")

    inst:AddTag("molebait")

	inst.pickupsound = "rock"

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_LARGEITEM
    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("tradable")
    inst.components.tradable.rocktribute = 3

    inst:AddComponent("bait")

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.STONE
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_CUTSTONE_HEALTH

    MakeHauntableLaunch(inst)

    return inst
end

return Prefab("cutstone", fn, assets)