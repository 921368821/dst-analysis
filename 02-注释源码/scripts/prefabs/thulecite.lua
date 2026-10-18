--============================================================
-- 文件：prefabs/thulecite.lua
-- 模块：预制体 / thulecite（建筑与容器）
-- 职责：实体「thulecite」的预制体定义。SpawnPrefab("thulecite") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/thulecite.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("thulecite")
    inst.AnimState:SetBuild("thulecite")
    inst.AnimState:PlayAnimation("anim")

    inst.pickupsound = "rock"

    inst:AddTag("molebait")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    inst:AddComponent("repairer")
    inst.components.repairer.repairmaterial = MATERIALS.THULECITE
    inst.components.repairer.workrepairvalue = TUNING.REPAIR_THULECITE_WORK
    inst.components.repairer.healthrepairvalue = TUNING.REPAIR_THULECITE_HEALTH

    inst:AddComponent("edible")
    inst.components.edible.foodtype = FOODTYPE.ELEMENTAL
    inst.components.edible.hungervalue = 3

    inst:AddComponent("tradable")
    inst:AddComponent("inspectable")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

    inst:AddComponent("stackable")

    MakeHauntableLaunchAndSmash(inst)

    inst:AddComponent("bait")

    return inst
end

return Prefab("thulecite", fn, assets)