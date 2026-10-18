--============================================================
-- 文件：prefabs/nitre.lua
-- 模块：预制体 / nitre（建筑与容器）
-- 职责：实体「nitre」的预制体定义。SpawnPrefab("nitre") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。
--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。
-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本
--============================================================

local assets =
{
    Asset("ANIM", "anim/nitre.zip"),
}

local function fn()
    local inst = CreateEntity()

    inst.entity:AddTransform()
    inst.entity:AddAnimState()
    inst.entity:AddSoundEmitter()
    inst.entity:AddNetwork()

    MakeInventoryPhysics(inst)

    inst.AnimState:SetBank("nitre")
    inst.AnimState:SetBuild("nitre")
    inst.AnimState:PlayAnimation("idle")

    inst.pickupsound = "rock"

    inst:AddTag("molebait")
    inst:AddTag("quakedebris")

    inst.entity:SetPristine()

    if not TheWorld.ismastersim then
        return inst
    end

    local edible = inst:AddComponent("edible")
    edible.foodtype = FOODTYPE.ELEMENTAL
    edible.secondaryfoodtype = FOODTYPE.NITRE
    edible.hungervalue = 2

    inst:AddComponent("tradable")

    inst:AddComponent("stackable")
    inst.components.stackable.maxsize = TUNING.STACK_SIZE_SMALLITEM

    inst:AddComponent("fuel")
    inst.components.fuel.fuelvalue = TUNING.MED_LARGE_FUEL
    inst.components.fuel.fueltype = FUELTYPE.CHEMICAL

    inst:AddComponent("inspectable")

    inst:AddComponent("bait")

    inst:AddComponent("inventoryitem")
    inst.components.inventoryitem:SetSinks(true)

	inst:AddComponent("snowmandecor")

    MakeHauntableLaunchAndSmash(inst)

    return inst
end

return Prefab("nitre", fn, assets)
